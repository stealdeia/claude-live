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
 * Credenziali e firma stanno in `asc-client.mjs`.
 */
import { api, app as findApp } from './asc-client.mjs'

const app = await findApp()
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
