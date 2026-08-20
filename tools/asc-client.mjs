/**
 * Il pezzo comune per parlare con App Store Connect: la firma e la chiamata.
 *
 * Estratto perché era ricopiato in ogni script, e una firma JWT ricopiata è una
 * firma che prima o poi divergerà in un posto solo.
 *
 * La firma è la stessa tecnica che il relay usa per APNs: ES256, chiave P-256 in
 * PKCS#8, firma grezza r‖s. Qui l'`aud` è fisso e la validità breve, perché Apple
 * rifiuta un token più vecchio di venti minuti.
 */
import { createSign } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'

/// Le stesse impostazioni che usa `release.sh`, dallo stesso file: né
/// l'identificativo della chiave né quello dell'emittente sono segreti — il
/// segreto è il `.p8`, che sta fuori dal repo.
function fromReleaseConf(name) {
  try {
    const conf = readFileSync(new URL('../release.conf', import.meta.url), 'utf8')
    return conf.match(new RegExp(`^${name}="([^"]*)"`, 'm'))?.[1]
  } catch {
    return undefined
  }
}

export const KEY_ID = process.env.ASC_KEY_ID ?? fromReleaseConf('ASC_KEY_ID')
export const ISSUER = process.env.ASC_ISSUER_ID ?? fromReleaseConf('ASC_ISSUER_ID')
export const BUNDLE =
  process.env.ASC_BUNDLE_ID ?? fromReleaseConf('ASC_BUNDLE_ID') ?? 'it.aldeialab.ClaudeLiveMobile'

if (!KEY_ID || !ISSUER) {
  console.error("Mancano ASC_KEY_ID e ASC_ISSUER_ID: né nell'ambiente né in release.conf.")
  process.exit(2)
}

function token() {
  const path = `${homedir()}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`
  let pem
  try {
    pem = readFileSync(path, 'utf8')
  } catch {
    console.error(`Chiave assente da ${path}. Apple la fa scaricare una volta sola: cercala fra le copie di riserva.`)
    process.exit(2)
  }
  const b64 = (v) => Buffer.from(JSON.stringify(v)).toString('base64url')
  const now = Math.floor(Date.now() / 1000)
  const input = `${b64({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })}.${b64({
    iss: ISSUER,
    iat: now,
    exp: now + 600,
    aud: 'appstoreconnect-v1',
  })}`
  const signer = createSign('sha256')
  signer.update(input)
  return `${input}.${signer.sign({ key: pem, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`
}

export async function api(path, options = {}) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    ...options,
    headers: {
      authorization: `Bearer ${token()}`,
      'content-type': 'application/json',
      ...(options.headers ?? {}),
    },
  })
  const text = await response.text()
  if (!response.ok) {
    throw new Error(`${response.status} su ${path}: ${text.slice(0, 400)}`)
  }
  return text ? JSON.parse(text) : null
}

/// L'app, cercata per bundle id: l'identificativo numerico cambia fra account e
/// non vale la pena scriverlo in due posti.
export async function app() {
  const found = await api(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE)}`)
  const app = found.data[0]
  if (!app) {
    console.error(`Nessuna app con bundle id ${BUNDLE} su App Store Connect.`)
    process.exit(1)
  }
  return app
}
