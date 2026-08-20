/**
 * Elenca e fa scadere le build su TestFlight.
 *
 * `altool` sa solo caricare. Far scadere una build vecchia richiede l'API REST di
 * App Store Connect, e serve: senza, nel gruppo dei tester restano tutte le
 * versioni caricate e qualcuno finirà per installare quella sbagliata — che in un
 * progetto dove ogni build cambia il protocollo di accoppiamento significa
 * un'app che non funziona e nessuna spiegazione.
 *
 * La firma è la stessa tecnica che il relay usa per APNs: ES256, chiave P-256 in
 * PKCS#8, firma grezza r‖s. Qui però l'`aud` è fisso e la validità è breve,
 * perché Apple rifiuta un token dell'API più vecchio di venti minuti.
 *
 * Uso:
 *   node tools/testflight.mjs list
 *   node tools/testflight.mjs expire-old     fa scadere tutte tranne la più recente
 *   node tools/testflight.mjs compliance     dichiara la crittografia se manca
 *
 * Serve la chiave in ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 e le due
 * variabili ASC_KEY_ID e ASC_ISSUER_ID.
 */
import { createSign } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'

/// Le stesse impostazioni che usa `release.sh`, lette dallo stesso file: né
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

const KEY_ID = process.env.ASC_KEY_ID ?? fromReleaseConf('ASC_KEY_ID')
const ISSUER = process.env.ASC_ISSUER_ID ?? fromReleaseConf('ASC_ISSUER_ID')
const BUNDLE = process.env.ASC_BUNDLE_ID ?? fromReleaseConf('ASC_BUNDLE_ID') ?? 'it.aldeialab.ClaudeLiveMobile'

if (!KEY_ID || !ISSUER) {
  console.error('Mancano ASC_KEY_ID e ASC_ISSUER_ID: né nell\'ambiente né in release.conf.')
  process.exit(2)
}

function token() {
  const pem = readFileSync(`${homedir()}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`, 'utf8')
  const b64 = (v) => Buffer.from(JSON.stringify(v)).toString('base64url')
  const now = Math.floor(Date.now() / 1000)
  const input = `${b64({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' })}.${b64({
    iss: ISSUER,
    iat: now,
    // Venti minuti è il massimo che Apple accetta; dieci lasciano margine
    // all'orologio senza che il token viva più del necessario.
    exp: now + 600,
    aud: 'appstoreconnect-v1',
  })}`
  const signer = createSign('sha256')
  signer.update(input)
  const sig = signer.sign({ key: pem, dsaEncoding: 'ieee-p1363' })
  return `${input}.${sig.toString('base64url')}`
}

async function api(path, options = {}) {
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

const apps = await api(`/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE)}`)
const app = apps.data[0]
if (!app) {
  console.error(`Nessuna app con bundle id ${BUNDLE}. Va creata su App Store Connect.`)
  process.exit(1)
}
console.log(`App: ${app.attributes.name} (${app.id})`)

const builds = await api(
  `/v1/builds?filter[app]=${app.id}` +
    '&fields[builds]=version,processingState,expired,uploadedDate,expirationDate' +
    '&sort=-uploadedDate&limit=20'
)

const rows = builds.data.map((b) => ({
  id: b.id,
  version: b.attributes.version,
  state: b.attributes.processingState,
  expired: b.attributes.expired,
  uploaded: b.attributes.uploadedDate,
}))

for (const row of rows) {
  const flags = [row.state, row.expired ? 'SCADUTA' : 'attiva'].join(', ')
  console.log(`  build ${row.version.padEnd(4)} ${flags.padEnd(24)} ${row.uploaded}`)
}

if (process.argv[2] === 'compliance') {
  // Rete di sicurezza per una build arrivata senza `ITSAppUsesNonExemptEncryption`
  // nell'Info.plist. Ripete la dichiarazione scritta là, non ne prende una nuova:
  // senza, la build resta bloccata su «Missing Compliance» e i tester non vedono
  // niente, senza che nessuno riceva un avviso.
  const pending = builds.data.filter((b) => b.attributes.usesNonExemptEncryption === null)
  if (pending.length === 0) {
    console.log('\nNessuna build in attesa di dichiarazione.')
  }
  for (const b of pending) {
    await api(`/v1/builds/${b.id}`, {
      method: 'PATCH',
      body: JSON.stringify({
        data: { type: 'builds', id: b.id, attributes: { usesNonExemptEncryption: false } },
      }),
    })
    console.log(`  build ${b.attributes.version}: dichiarazione registrata`)
  }
}

if (process.argv[2] === 'expire-old') {
  // La più recente resta, tutte le altre scadono. Ordinato per data di
  // caricamento e non per numero: il numero è una stringa, e "10" verrebbe prima
  // di "9".
  const [newest, ...older] = rows
  if (!newest) process.exit(0)
  console.log(`\nResta la build ${newest.version}.`)
  for (const row of older.filter((r) => !r.expired)) {
    await api(`/v1/builds/${row.id}`, {
      method: 'PATCH',
      body: JSON.stringify({
        data: { type: 'builds', id: row.id, attributes: { expired: true } },
      }),
    })
    console.log(`  build ${row.version}: fatta scadere`)
  }
}
