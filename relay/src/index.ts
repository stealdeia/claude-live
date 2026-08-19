/**
 * Claude Live relay — Fase 0 skeleton.
 *
 * The single question this has to answer: can a permission request raised on the
 * Mac reach the phone, be answered, and get back, inside the window the hook is
 * willing to wait? Everything else about the companion depends on that number,
 * so it is measured before anything is built on top of it.
 *
 * Deliberately stateless apart from the device token. A latency measurement must
 * not be distorted by the storage it runs through, and KV's eventual consistency
 * would do exactly that — so the round trip carries its own timestamps and the
 * phone computes the number. KV holds the token, written once at pairing and read
 * minutes later, where eventual consistency costs nothing.
 *
 * That choice also keeps this on the Workers free plan: no Durable Objects yet.
 * They become a question in phase 2, when the panel wants a live connection.
 */

export interface Env {
  /** Device tokens and the latest snapshot, keyed by pair id. */
  DEVICES: KVNamespace
  /** Contents of the AuthKey_*.p8 downloaded from Apple. A secret. */
  APNS_KEY: string
  /** The 10-character key id shown next to the key in App Store Connect. */
  APNS_KEY_ID: string
  /** Apple developer team id. */
  APNS_TEAM_ID: string
  /** The app's bundle id — APNs calls it the topic. */
  APNS_TOPIC: string
  /** "sandbox" for builds installed from Xcode, "production" for TestFlight. */
  APNS_ENV: string
  /** Shared secret: proves a request came from our Mac or our phone. */
  PAIR_SECRET: string
}

/** One pair of devices. A single one for now; phase 2 gives it a real identity. */
const PAIR_ID = 'default'

// ---------------------------------------------------------------- APNs

/**
 * APNs authentication token.
 *
 * Apple accepts it for an hour and refuses more than one refresh every 20
 * minutes, so it is cached in module scope. A Worker isolate is recycled freely,
 * which only means the next request mints a new one — never a problem, because
 * the limit is on refresh *rate* and an isolate does not live long enough to
 * approach it.
 */
let cachedToken: { jwt: string; mintedAt: number } | null = null

const TOKEN_MAX_AGE_MS = 45 * 60 * 1000

function base64url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  let binary = ''
  for (const byte of view) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/** Strips the PEM armour and returns the DER bytes. */
function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, '')
    .replace(/-----END [^-]+-----/, '')
    .replace(/\s+/g, '')
  const binary = atob(body)
  const der = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) der[i] = binary.charCodeAt(i)
  return der
}

async function apnsToken(env: Env): Promise<string> {
  const now = Date.now()
  if (cachedToken && now - cachedToken.mintedAt < TOKEN_MAX_AGE_MS) {
    return cachedToken.jwt
  }

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(env.APNS_KEY),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  )

  const header = base64url(
    new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: env.APNS_KEY_ID }))
  )
  const payload = base64url(
    new TextEncoder().encode(
      JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) })
    )
  )
  const signingInput = `${header}.${payload}`

  // WebCrypto returns the raw r‖s pair, which is exactly what JWS wants — no
  // DER unwrapping, unlike most server-side crypto libraries.
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(signingInput)
  )

  const jwt = `${signingInput}.${base64url(signature)}`
  cachedToken = { jwt, mintedAt: now }
  return jwt
}

/**
 * Sends one alert push.
 *
 * The environment matters more than it looks: a build installed straight from
 * Xcode is registered with the *sandbox*, and sending it to the production host
 * fails with `BadDeviceToken` — the single most common way this silently does
 * nothing. TestFlight and the App Store use production.
 */
async function sendPush(
  env: Env,
  deviceToken: string,
  body: Record<string, unknown>
): Promise<{ ok: boolean; status: number; reason?: string }> {
  const host =
    env.APNS_ENV === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com'

  const response = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${await apnsToken(env)}`,
      'apns-topic': env.APNS_TOPIC,
      'apns-push-type': 'alert',
      // 10 is "deliver now". Anything lower lets iOS batch it, which would
      // measure Apple's discretion rather than our round trip.
      'apns-priority': '10',
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  })

  if (response.ok) return { ok: true, status: response.status }

  // APNs explains refusals in the body, and the reason is the only thing that
  // makes a failure diagnosable — surface it rather than just the status.
  let reason: string | undefined
  try {
    reason = ((await response.json()) as { reason?: string }).reason
  } catch {
    reason = await response.text().catch(() => undefined)
  }
  return { ok: false, status: response.status, reason }
}

// ---------------------------------------------------------------- HTTP

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function authorised(request: Request, env: Env): boolean {
  const header = request.headers.get('authorization') ?? ''
  const provided = header.replace(/^Bearer\s+/i, '')
  if (provided.length === 0 || provided.length !== env.PAIR_SECRET.length) return false

  // Constant time: a length-independent comparison would leak the secret one
  // character at a time to anyone willing to measure.
  let diff = 0
  for (let i = 0; i < provided.length; i++) {
    diff |= provided.charCodeAt(i) ^ env.PAIR_SECRET.charCodeAt(i)
  }
  return diff === 0
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)

    // Answers before the authorisation check, so it can be used to tell "the
    // relay is down" from "the password is wrong" — and therefore says only
    // that it is alive. It used to report the APNs environment and the bundle
    // id, which is free information for anyone who guesses the address.
    if (url.pathname === '/health') {
      return json({ ok: true })
    }

    if (!authorised(request, env)) {
      return json({ error: 'non autorizzato' }, 401)
    }

    // The phone hands over the token APNs gave it. Called once at pairing.
    if (url.pathname === '/register' && request.method === 'POST') {
      const { deviceToken } = (await request.json()) as { deviceToken?: string }
      if (!deviceToken || !/^[0-9a-fA-F]{64}$/.test(deviceToken)) {
        return json({ error: 'deviceToken mancante o malformato' }, 400)
      }
      await env.DEVICES.put(PAIR_ID, deviceToken)
      return json({ ok: true })
    }

    // The Mac starts a measurement. `sentAt` travels inside the push so the
    // phone can subtract without either side trusting the other's clock more
    // than it has to.
    if (url.pathname === '/ping' && request.method === 'POST') {
      const deviceToken = await env.DEVICES.get(PAIR_ID)
      if (!deviceToken) return json({ error: 'nessun telefono registrato' }, 409)

      const sentAt = Date.now()
      const result = await sendPush(env, deviceToken, {
        aps: {
          alert: { title: 'Claude Live', body: 'Prova di velocità' },
          sound: 'default',
        },
        sentAt,
      })

      if (!result.ok) {
        return json({ error: 'APNs ha rifiutato', ...result }, 502)
      }
      return json({ ok: true, sentAt, acceptedInMs: Date.now() - sentAt })
    }

    // The Mac publishes what it knows. The body is a sealed box: this Worker
    // stores and forwards it without being able to read it, which is the whole
    // reason it can be somebody else's computer.
    if (url.pathname === '/publish' && request.method === 'POST') {
      const body = (await request.json()) as { payload?: string; notify?: string }
      if (typeof body.payload !== 'string' || body.payload.length === 0) {
        return json({ error: 'payload mancante' }, 400)
      }
      // A snapshot is worthless once superseded, so it is stored with a short
      // life: if the Mac stops publishing, the record expires instead of sitting
      // there looking current.
      await env.DEVICES.put(`${PAIR_ID}:snapshot`, body.payload, { expirationTtl: 600 })
      await env.DEVICES.put(`${PAIR_ID}:snapshotAt`, String(Date.now()), { expirationTtl: 600 })

      let pushed: unknown = null
      if (body.notify) {
        const deviceToken = await env.DEVICES.get(PAIR_ID)
        if (deviceToken) {
          // Deliberately generic wording. The alert text is visible to Apple and
          // to this Worker, so naming the project here would undo the encryption
          // for exactly the field a passer-by would find most interesting. The
          // app says what happened once it has decrypted the snapshot.
          pushed = await sendPush(env, deviceToken, {
            aps: {
              alert: { title: 'Claude Live', body: body.notify },
              sound: 'default',
            },
          })
        }
      }

      return json({ ok: true, pushed })
    }

    // The phone asks for the latest picture.
    if (url.pathname === '/state' && request.method === 'GET') {
      const payload = await env.DEVICES.get(`${PAIR_ID}:snapshot`)
      if (!payload) return json({ error: 'nessuno snapshot' }, 404)
      const storedAt = await env.DEVICES.get(`${PAIR_ID}:snapshotAt`)
      return json({ payload, storedAt: storedAt ? Number(storedAt) : null })
    }

    // The phone answers a permission request. Sealed like everything else: the
    // id travels in the clear only so the Mac can address and delete it, and an
    // opaque identifier discloses nothing about what was decided.
    if (url.pathname === '/command' && request.method === 'POST') {
      const body = (await request.json()) as { id?: string; payload?: string }
      if (typeof body.id !== 'string' || !/^[0-9A-Fa-f-]{8,64}$/.test(body.id)) {
        return json({ error: 'id mancante o malformato' }, 400)
      }
      if (typeof body.payload !== 'string' || body.payload.length === 0) {
        return json({ error: 'payload mancante' }, 400)
      }
      // Five minutes: far longer than any hook will wait, short enough that a
      // command nobody collected disappears instead of being obeyed much later.
      await env.DEVICES.put(`${PAIR_ID}:cmd:${body.id}`, body.payload, { expirationTtl: 300 })
      return json({ ok: true })
    }

    // The Mac collects what is waiting for it.
    if (url.pathname === '/commands' && request.method === 'GET') {
      const listed = await env.DEVICES.list({ prefix: `${PAIR_ID}:cmd:` })
      const commands = await Promise.all(
        listed.keys.map(async (entry) => ({
          id: entry.name.slice(`${PAIR_ID}:cmd:`.length),
          payload: await env.DEVICES.get(entry.name),
        }))
      )
      return json({ commands: commands.filter((c) => c.payload !== null) })
    }

    // …and says it has dealt with one, so it is not carried out twice.
    if (url.pathname === '/commands' && request.method === 'DELETE') {
      const id = url.searchParams.get('id')
      if (!id) return json({ error: 'id mancante' }, 400)
      await env.DEVICES.delete(`${PAIR_ID}:cmd:${id}`)
      return json({ ok: true })
    }

    // The phone reports what it saw. Nothing is stored: the number is the point,
    // and it is already in the response the Mac is waiting on.
    if (url.pathname === '/ack' && request.method === 'POST') {
      const { sentAt, receivedAt } = (await request.json()) as {
        sentAt?: number
        receivedAt?: number
      }
      if (typeof sentAt !== 'number' || typeof receivedAt !== 'number') {
        return json({ error: 'sentAt e receivedAt devono essere numeri' }, 400)
      }
      return json({ ok: true, oneWayMs: receivedAt - sentAt })
    }

    return json({ error: 'non trovato' }, 404)
  },
}
