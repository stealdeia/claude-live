/**
 * Relay di Claude Live: il programmino sempre acceso fra il Mac e l'iPhone.
 *
 * Esiste perché iOS spegne le app che non guardi, e l'unica cosa che può
 * svegliarne una è una notifica push — che deve partire da un computer sempre
 * acceso su Internet, non dal Mac che dorme.
 *
 * ## Perché Durable Object e non KV
 *
 * Prima lo snapshot stava in KV, e il piano gratuito concede **mille scritture
 * al giorno**. Ogni pubblicazione ne faceva due, e il battito di presenza
 * pubblica ogni sessanta secondi per non far apparire sul telefono l'avviso «il
 * Mac è scollegato»: 1.440 pubblicazioni al giorno, 2.880 scritture — quasi il
 * triplo del limite, con il Mac completamente fermo. Il sistema era destinato a
 * spegnersi al primo giorno di uso reale, con un solo utente. Accaduto il
 * 2026-08-20, con `KV put() limit exceeded for the day`.
 *
 * Il piano a pagamento avrebbe solo spostato il muro: un milione di scritture al
 * mese sono trentamila al giorno, che finiscono a una trentina di utenti.
 *
 * Uno snapshot vale sessanta secondi, quindi non è un dato da conservare: è un
 * dato da *tenere*. Un Durable Object per coppia lo tiene in memoria, dove la
 * durata è quella giusta e le scritture non esistono. Su disco finisce solo il
 * token del telefono, scritto una volta all'accoppiamento.
 *
 * E si sposa con l'identificativo per coppia: un oggetto per identificativo,
 * separazione per costruzione, e scala senza che nessuno debba pubblicare un
 * relay per sé.
 */

export interface Env {
  /** Uno stato per coppia di dispositivi. */
  PAIR: DurableObjectNamespace
  /** Chiave APNs (.p8), messa con `wrangler secret put`. */
  APNS_KEY: string
  /** Identificativo della chiave APNs. */
  APNS_KEY_ID: string
  /** Il team Apple. */
  APNS_TEAM_ID: string
  /** L'id del pacchetto dell'app — APNs lo chiama topic. */
  APNS_TOPIC: string
  /** Ambiente di ripiego, per un token registrato prima che il telefono lo dichiarasse. */
  APNS_ENV: string
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

// ---------------------------------------------------------------- APNs

/**
 * Token di autenticazione APNs.
 *
 * Apple lo accetta per un'ora e rifiuta più di un rinnovo ogni venti minuti,
 * quindi resta in cache. La cache è per isolate: un Durable Object ne ha uno
 * suo, e vivendo più a lungo di un isolate qualunque la sfrutta meglio.
 *
 * Viene buttata quando Apple risponde 403. Cambiando la chiave, le istanze già
 * calde continuerebbero a presentare la firma vecchia per quarantacinque minuti,
 * con lo stesso errore identico di una chiave sbagliata e nessun indizio che si
 * tratti di una copia stantia — mezz'ora di diagnosi il 2026-08-20.
 */
let cachedToken: { jwt: string; mintedAt: number } | null = null

const TOKEN_MAX_AGE_MS = 45 * 60 * 1000

function base64url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
  let binary = ''
  for (const byte of view) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/** Toglie l'armatura PEM e restituisce i byte DER. */
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

/**
 * I tipi di avviso che il telefono può accendere o spegnere.
 *
 * Sono i tre stati per cui il Mac chiama qui, e nient'altro: l'elenco è chiuso
 * di proposito, così una chiave inventata non finisce nello spazio conservato.
 */
const NOTIFY_KINDS = ['waiting', 'done', 'failed'] as const

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

  // WebCrypto restituisce la coppia r‖s grezza, che è esattamente ciò che vuole
  // JWS — nessuno svolgimento DER, al contrario di quasi tutte le librerie.
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
 * Manda una notifica.
 *
 * L'ambiente conta più di quanto sembri: una build installata col cavo è
 * registrata nel *sandbox*, e mandarla all'host di produzione fallisce con
 * `BadDeviceToken` — il modo più comune in cui tutto questo non fa niente in
 * silenzio. TestFlight e l'App Store usano produzione. Viaggia col dispositivo,
 * non con questo Worker: due build della stessa app possono essere accoppiate in
 * momenti diversi, e un solo valore qui sarebbe sbagliato per una delle due.
 *
 * Ritenta una volta sola, e solo su 403: quello è l'errore della firma, e la
 * seconda firma è nuova per costruzione.
 */
/**
 * Il tipo di notifica, che decide anche l'argomento.
 *
 * Le Live Activity non si aggiornano con una notifica normale: vogliono il tipo
 * `liveactivity` e un argomento con un suffisso proprio. Sbagliare uno dei due
 * dà un rifiuto che parla d'altro, quindi stanno insieme in un posto solo.
 */
type PushKind = 'alert' | 'liveactivity'

async function sendPush(
  env: Env,
  deviceToken: string,
  body: Record<string, unknown>,
  environment?: string,
  retrying = false,
  kind: PushKind = 'alert'
): Promise<{ ok: boolean; status: number; reason?: string }> {
  const world = environment ?? env.APNS_ENV
  const host = world === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com'

  const response = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${await apnsToken(env)}`,
      'apns-topic':
        kind === 'liveactivity' ? `${env.APNS_TOPIC}.push-type.liveactivity` : env.APNS_TOPIC,
      'apns-push-type': kind,
      // 10 è «consegna adesso». Meno lascia a iOS la facoltà di accorpare, che
      // misurerebbe la discrezione di Apple invece del nostro giro.
      'apns-priority': '10',
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  })

  if (response.status === 403 && !retrying) {
    // La firma non è stata accettata. Se è solo stantia, buttarla e ripetere
    // risolve; se la chiave è davvero sbagliata, il secondo tentativo fallisce
    // identico e non abbiamo perso nulla.
    cachedToken = null
    return sendPush(env, deviceToken, body, environment, true, kind)
  }

  if (response.ok) return { ok: true, status: response.status }

  // APNs spiega i rifiuti nel corpo, e la spiegazione è l'unica cosa che rende
  // diagnosticabile un no.
  let reason: string | undefined
  try {
    reason = ((await response.json()) as { reason?: string }).reason
  } catch {
    reason = undefined
  }
  return { ok: false, status: response.status, reason }
}

// ---------------------------------------------------------------- Lo stato di una coppia

/** Durate: quanto vale uno snapshot, e quanto resta in giro una risposta. */
const SNAPSHOT_LIFE_MS = 600_000
const COMMAND_LIFE_MS = 300_000

/**
 * Tutto quello che riguarda una coppia Mac–iPhone, e nient'altro.
 *
 * Tutto sta nello storage dell'oggetto, non nella sua memoria. Tenere lo
 * snapshot in memoria era il primo tentativo, ed era sbagliato: un Durable
 * Object viene sfrattato dopo pochi secondi di inattività e la memoria se ne va
 * con lui — due richieste a distanza di un secondo l'una dall'altra e la seconda
 * non trovava più niente.
 *
 * Una riga per pubblicazione, dove KV ne scriveva due, e con un limite
 * giornaliero cento volte più alto. Le scadenze qui non esistono, quindi
 * snapshot e risposte vengono potati alla lettura.
 */
export class PairState {
  constructor(private ctx: DurableObjectState, private env: Env) {}

  private async device(): Promise<{ token: string | null; environment?: string }> {
    const token = (await this.ctx.storage.get<string>('deviceToken')) ?? null
    const environment = await this.ctx.storage.get<string>('deviceEnv')
    return { token, environment }
  }

  /// Butta ciò che è scaduto, invece di lasciarlo sembrare attuale.
  ///
  /// Non c'è una scadenza automatica come in KV, quindi si fa alla lettura: uno
  /// snapshot vecchio di dieci minuti descrive un Mac che potrebbe essere
  /// tutt'altro, e una risposta raccolta molto dopo verrebbe obbedita fuori
  /// tempo.
  private async prune() {
    const now = Date.now()
    const at = (await this.ctx.storage.get<number>('snapshotAt')) ?? 0
    if (at && now - at > SNAPSHOT_LIFE_MS) {
      await this.ctx.storage.delete(['snapshot', 'snapshotAt'])
    }
    const commands = await this.ctx.storage.list<{ payload: string; at: number }>({
      prefix: 'cmd:',
    })
    const stale = [...commands].filter(([, e]) => now - e.at > COMMAND_LIFE_MS).map(([k]) => k)
    if (stale.length > 0) await this.ctx.storage.delete(stale)
  }

  /**
   * Se questo avviso va spinto al telefono.
   *
   * Due silenzi valgono «manda»: un Mac più vecchio che non dice di che tipo sia
   * l'avviso, e un telefono che non ha mai espresso preferenze. Il valore
   * predefinito deve essere il comportamento di prima, altrimenti un
   * aggiornamento del relay spegnerebbe le notifiche a chi non ha chiesto
   * niente — e una notifica che non arriva è un guasto che nessuno collega a un
   * campo nuovo.
   */
  private async wantsPush(kind: string | undefined): Promise<boolean> {
    if (!kind) return true
    const prefs = await this.ctx.storage.get<Record<string, boolean>>('notifyPrefs')
    if (!prefs) return true
    return prefs[kind] !== false
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url)
    await this.prune()

    // Il telefono consegna il token che gli ha dato APNs, e dice in quale mondo
    // APNs vive. Chiamata una volta all'accoppiamento, e a ogni avvio: iOS può
    // cambiare token dopo una reinstallazione, e uno stantio qui è una notifica
    // che non arriva.
    if (url.pathname === '/register' && request.method === 'POST') {
      const { deviceToken, environment } = (await request.json()) as {
        deviceToken?: string
        environment?: string
      }
      if (!deviceToken || !/^[0-9a-fA-F]{64}$/.test(deviceToken)) {
        return json({ error: 'deviceToken mancante o malformato' }, 400)
      }
      await this.ctx.storage.put('deviceToken', deviceToken)
      // Solo le due parole che APNs conosce: un ambiente sbagliato fallisce con
      // `BadDeviceToken`, che non spiega niente.
      if (environment === 'sandbox' || environment === 'production') {
        await this.ctx.storage.put('deviceEnv', environment)
      }
      return json({ ok: true, environment: environment ?? this.env.APNS_ENV })
    }

    // Il Mac misura quanto ci mette un avviso ad arrivare. `sentAt` viaggia
    // dentro la notifica, così il conto lo fa il telefono e nessuno dei due deve
    // fidarsi dell'orologio dell'altro.
    if (url.pathname === '/ping' && request.method === 'POST') {
      const { token, environment } = await this.device()
      if (!token) return json({ error: 'nessun telefono registrato' }, 409)

      const sentAt = Date.now()
      const result = await sendPush(this.env, token, {
        aps: { alert: { title: 'Vibing Code Live', body: 'Prova di velocità' }, sound: 'default' },
        sentAt,
      }, environment)

      if (!result.ok) return json({ error: 'APNs ha rifiutato', ...result }, 502)
      return json({ ok: true, sentAt, acceptedInMs: Date.now() - sentAt })
    }

    // Il Mac pubblica quello che sa. Il corpo è una scatola sigillata: questo
    // Worker la tiene e la inoltra senza poterla leggere, che è la ragione per
    // cui può essere il computer di qualcun altro.
    if (url.pathname === '/publish' && request.method === 'POST') {
      const body = (await request.json()) as {
        payload?: string
        notify?: string
        notifyKind?: string
        activity?: string
      }
      if (typeof body.payload !== 'string' || body.payload.length === 0) {
        return json({ error: 'payload mancante' }, 400)
      }
      // Su disco, non in memoria. La memoria di un Durable Object non sopravvive
      // allo sfratto per inattività — pochi secondi bastano — e uno snapshot
      // perso è il telefono che dice «il Mac è scollegato» mentre il Mac sta
      // benissimo. Una riga per pubblicazione, dove KV ne scriveva due.
      await this.ctx.storage.put({ snapshot: body.payload, snapshotAt: Date.now() })

      let pushed: unknown = null
      if (body.notify && (await this.wantsPush(body.notifyKind))) {
        const { token, environment } = await this.device()
        if (token) {
          // Testo volutamente generico. L'avviso è visibile ad Apple e a questo
          // Worker, quindi nominare il progetto qui disferebbe la cifratura per
          // il campo che a un estraneo interesserebbe di più. Il dettaglio lo
          // mette l'app, dopo aver aperto lo snapshot.
          pushed = await sendPush(this.env, token, {
            aps: { alert: { title: 'Vibing Code Live', body: body.notify }, sound: 'default' },
          }, environment)
        }
      }
      // L'isola dinamica, se il Mac ha mandato il suo contenuto.
      //
      // Il contenuto è una scatola sigillata: questo Worker la mette dentro la
      // notifica senza poterla aprire, e l'estensione dell'isola la apre sul
      // telefono. È il motivo per cui l'isola può mostrare i nomi dei progetti
      // senza che passino leggibili da qui né da Apple.
      let island: unknown = null
      if (body.activity) {
        const token = await this.ctx.storage.get<string>('activityToken')
        const { environment } = await this.device()
        if (token) {
          const now = Math.floor(Date.now() / 1000)
          island = await sendPush(
            this.env,
            token,
            {
              aps: {
                timestamp: now,
                event: 'update',
                'content-state': { sealed: body.activity },
                // La stessa scadenza che l'app mette quando aggiorna da sé: dopo,
                // iOS sbiadisce l'isola invece di mostrare numeri vecchi come se
                // fossero di adesso.
                'stale-date': now + 600,
              },
            },
            environment,
            false,
            'liveactivity'
          )
        }
      }

      return json({ ok: true, pushed, island })
    }

    // Il telefono chiede l'ultima fotografia.
    // Il telefono consegna il token di una Live Activity in corso.
    //
    // Diverso da quello di `/register`: quello indirizza il telefono, questo
    // indirizza *una singola attività*. Cambia mentre l'attività vive, e uno
    // stantio è una notifica che Apple accetta e consegna a nessuno.
    if (url.pathname === '/activity-token' && request.method === 'POST') {
      const { token } = (await request.json()) as { token?: string }
      if (!token || !/^[0-9a-fA-F]{64,200}$/.test(token)) {
        return json({ error: 'token mancante o malformato' }, 400)
      }
      await this.ctx.storage.put('activityToken', token)
      return json({ ok: true })
    }

    // Quali avvisi il telefono vuole ricevere.
    //
    // Deciso qui e non sul Mac perché il Mac interroga questo Worker *solo*
    // mentre c'è qualcosa da rispondere: una preferenza cambiata a metà
    // pomeriggio gli resterebbe non letta per ore. Questo Worker invece è chi
    // decide se spingere, e lo decide ogni volta.
    if (url.pathname === '/prefs' && request.method === 'POST') {
      const body = (await request.json()) as Record<string, unknown>
      const prefs: Record<string, boolean> = {}
      for (const kind of NOTIFY_KINDS) {
        if (typeof body[kind] === 'boolean') prefs[kind] = body[kind] as boolean
      }
      if (Object.keys(prefs).length === 0) {
        return json({ error: 'nessuna preferenza riconosciuta' }, 400)
      }
      await this.ctx.storage.put('notifyPrefs', prefs)
      return json({ ok: true, prefs })
    }

    if (url.pathname === '/prefs' && request.method === 'GET') {
      const prefs = (await this.ctx.storage.get<Record<string, boolean>>('notifyPrefs')) ?? null
      return json({ prefs })
    }

    if (url.pathname === '/state' && request.method === 'GET') {
      const payload = await this.ctx.storage.get<string>('snapshot')
      if (!payload) return json({ error: 'nessuno snapshot' }, 404)
      const storedAt = (await this.ctx.storage.get<number>('snapshotAt')) ?? null
      return json({ payload, storedAt })
    }

    // Il telefono risponde a una richiesta di permesso. Sigillata come tutto il
    // resto: l'id viaggia in chiaro solo perché il Mac possa indirizzarla e
    // cancellarla, e non rivela nulla di ciò che è stato deciso.
    if (url.pathname === '/command' && request.method === 'POST') {
      const body = (await request.json()) as { id?: string; payload?: string }
      if (typeof body.id !== 'string' || !/^[0-9A-Fa-f-]{8,64}$/.test(body.id)) {
        return json({ error: 'id mancante o malformato' }, 400)
      }
      if (typeof body.payload !== 'string' || body.payload.length === 0) {
        return json({ error: 'payload mancante' }, 400)
      }
      await this.ctx.storage.put(`cmd:${body.id}`, { payload: body.payload, at: Date.now() })
      return json({ ok: true })
    }

    // Il Mac raccoglie quello che lo aspetta.
    if (url.pathname === '/commands' && request.method === 'GET') {
      const stored = await this.ctx.storage.list<{ payload: string; at: number }>({
        prefix: 'cmd:',
      })
      const commands = [...stored].map(([key, entry]) => ({
        id: key.slice('cmd:'.length),
        payload: entry.payload,
      }))
      return json({ commands })
    }

    // …e dice di averne gestita una, così non viene eseguita due volte.
    if (url.pathname === '/commands' && request.method === 'DELETE') {
      const id = url.searchParams.get('id')
      if (!id) return json({ error: 'id mancante' }, 400)
      await this.ctx.storage.delete(`cmd:${id}`)
      return json({ ok: true })
    }

    // Il telefono riferisce cosa ha visto. Niente viene conservato: il numero è
    // il punto, ed è già nella risposta che il Mac sta aspettando.
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
  }
}

// ---------------------------------------------------------------- Instradamento

/**
 * Quale coppia sta chiamando: l'identificativo è insieme l'indirizzo dei suoi
 * dati qui e il permesso di toccarli.
 *
 * Sostituisce un'unica password condivisa, che non poteva essere né l'uno né
 * l'altro. Un segreto in mano a ogni installazione autorizza tutti a tutto, e
 * deve pure *arrivare* da qualche parte — digitato a mano, cosa che nessuno farà,
 * o spedito dentro l'app, dove chiunque lo estrae. Un identificativo che ogni
 * Mac si fa da sé non ha bisogno di essere distribuito: viaggia nel QR, una
 * volta, e tiene separati i dati di ognuno.
 *
 * 128 bit di casualità, quindi non si indovina. È controllata la *forma*, non
 * confrontato un segreto: qui non c'è niente da far filtrare a tempo.
 *
 * Quello che non fa è proteggere i contenuti, e niente qui potrebbe: i payload
 * sono sigillati con una chiave che a questo Worker non arriva mai. Un
 * identificativo rubato permetterebbe di mandare una notifica a quel telefono e
 * di sovrascrivere uno snapshot — non di leggerne uno.
 */
function pairIdFrom(request: Request): string | null {
  const provided = (request.headers.get('authorization') ?? '')
    .replace(/^Bearer\s+/i, '')
    .trim()
  return /^[0-9a-f]{32}$/i.test(provided) ? provided.toLowerCase() : null
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)

    // Risponde prima del controllo di autorizzazione, così serve a distinguere
    // «il relay è giù» da «l'identificativo è sbagliato» — e per questo dice solo
    // che è vivo. Riportava l'ambiente APNs e l'id del pacchetto, informazione
    // gratuita per chiunque indovini l'indirizzo.
    if (url.pathname === '/health') {
      return json({ ok: true })
    }

    const pairId = pairIdFrom(request)
    if (!pairId) {
      return json({ error: 'non autorizzato' }, 401)
    }

    // Un oggetto per identificativo. `idFromName` è deterministico, quindi Mac e
    // telefono che presentano lo stesso identificativo finiscono nello stesso
    // stato senza doversi accordare su altro.
    return env.PAIR.get(env.PAIR.idFromName(pairId)).fetch(request)
  },
}
