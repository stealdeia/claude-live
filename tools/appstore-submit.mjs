/**
 * Manda in revisione la versione in bozza, e sa rimandarla dopo un rifiuto.
 *
 * ## Le due cose che non sono ovvie
 *
 * **1. Dopo un rifiuto, l'elemento va segnato risolto.** Una pratica rifiutata
 * resta in `UNRESOLVED_ISSUES` con dentro un `reviewSubmissionItem` in stato
 * `REJECTED`, e la versione **resta agganciata a quella pratica**. Finché è
 * così, ogni tentativo di reinvio risponde:
 *
 *     Version is not ready to be submitted yet, please try again later.
 *
 * Che è un messaggio bugiardo: non è questione di tempo, e aspettare non serve a
 * niente — il 2026-09-21 ci ho lasciato quattordici tentativi in quattordici
 * minuti convinto che fosse una coda di Apple. Il passo che manca è dichiarare
 * risolto il problema: `PATCH /v1/reviewSubmissionItems/<id> { resolved: true }`.
 * L'elemento torna `READY_FOR_REVIEW` e l'invio passa.
 *
 * **2. Non aprire una pratica nuova prima di sapere che la versione è libera.**
 * Una versione può stare in una pratica sola. Se se ne apre una seconda e poi
 * l'aggiunta della versione fallisce, resta lì una pratica vuota che **non si
 * può né annullare né cancellare** — l'API non permette `DELETE`, e
 * `canceled: true` risponde «resource is not in cancellable state». Ne è rimasta
 * una, innocua ma indelebile. Quindi qui si cerca *prima* una pratica riusabile.
 *
 * Uso:
 *   node tools/appstore-submit.mjs            dice cosa farebbe
 *   node tools/appstore-submit.mjs --apply    la manda
 */
import { api, app as findApp } from './asc-client.mjs'

const APPLY = process.argv.includes('--apply')

/// I motivi veri di un rifiuto dell'API, che stanno dentro
/// `meta.associatedErrors`: quello di primo livello dice sempre e solo «check
/// associated errors to see why».
function motivi(errore) {
  const testo = errore.body ?? String(errore.message)
  const blocco = testo.match(/\{[\s\S]*\}/)
  if (!blocco) return [testo.split('\n')[0]]
  let corpo
  try {
    corpo = JSON.parse(blocco[0])
  } catch {
    return [testo.split('\n')[0]]
  }
  const elenco = []
  for (const err of corpo.errors ?? []) {
    const dentro = Object.values(err.meta?.associatedErrors ?? {}).flat()
    if (dentro.length === 0) elenco.push(err.detail ?? err.title)
    else for (const e of dentro) elenco.push(e.detail ?? e.title)
  }
  return elenco.length ? elenco : [testo.split('\n')[0]]
}

const app = await findApp()
const version = (await api(`/v1/apps/${app.id}/appStoreVersions?limit=1`)).data[0]
if (!version) {
  console.error('Nessuna versione su cui lavorare.')
  process.exit(1)
}
console.log(`${app.attributes.name} ${version.attributes.versionString} — ${version.attributes.appStoreState}`)

if (version.attributes.appStoreState === 'WAITING_FOR_REVIEW' ||
    version.attributes.appStoreState === 'IN_REVIEW') {
  console.log('Già in revisione: non c\'è niente da mandare.')
  process.exit(0)
}

const build = (await api(`/v1/appStoreVersions/${version.id}/build`)).data
if (!build) {
  console.error('✗ Nessuna build agganciata alla versione.')
  process.exit(1)
}
if (build.attributes.expired) {
  console.error(`✗ La build ${build.attributes.version} è scaduta: aggancia una valida prima di mandare.`)
  process.exit(1)
}
console.log(`  build ${build.attributes.version}`)

// --- La pratica: riusare la sua, non aprirne una seconda --------------------
const pratiche = (await api(`/v1/reviewSubmissions?filter[app]=${app.id}&limit=20`)).data
let pratica = null
let elemento = null
/// Una pratica aperta e vuota, da riusare invece di aprirne un'altra.
let vuota = null
for (const p of pratiche) {
  // `include=appStoreVersion` non è un ornamento: senza, gli elementi arrivano
  // con `attributes.state` e **nient'altro** — niente relazioni — e cercare la
  // versione lì dentro trova sempre niente. È così che il 2026-09-22 questo
  // strumento ha concluso «nessuna pratica contiene questa versione» mentre una
  // ce l'aveva, e ne ha aperta una seconda che non si può più cancellare.
  const items = (await api(`/v1/reviewSubmissions/${p.id}/items?include=appStoreVersion`)).data
  const mio = items.find((i) => i.relationships?.appStoreVersion?.data?.id === version.id)
  if (mio) {
    pratica = p
    elemento = mio
    break
  }
  if (items.length === 0 && p.attributes.state === 'READY_FOR_REVIEW') vuota = p
}

if (pratica) {
  console.log(`  pratica ${pratica.id.slice(0, 8)} (${pratica.attributes.state}), elemento ${elemento.attributes.state}`)
} else {
  console.log('  nessuna pratica contiene questa versione: ne serve una nuova')
}

if (!APPLY) {
  if (elemento?.attributes.state === 'REJECTED') {
    console.log('\nFarei: segno risolto l\'elemento rifiutato, poi invio.')
  } else {
    console.log('\nFarei: invio.')
  }
  console.log('(prova: niente è stato mandato — aggiungi --apply)')
  process.exit(0)
}

// Il passo che manca dopo un rifiuto, e senza il quale l'invio risponde per
// sempre «not ready to be submitted yet».
if (elemento?.attributes.state === 'REJECTED') {
  const r = await api(`/v1/reviewSubmissionItems/${elemento.id}`, {
    method: 'PATCH',
    body: JSON.stringify({
      data: { type: 'reviewSubmissionItems', id: elemento.id, attributes: { resolved: true } },
    }),
  })
  console.log(`  elemento segnato risolto → ${r.data.attributes.state}`)
}

if (!pratica && vuota) {
  // Riusare quella vuota invece di aprirne un'altra: ogni pratica aperta per
  // sbaglio resta lì per sempre — l'API non permette `DELETE` e `canceled: true`
  // risponde «resource is not in cancellable state».
  console.log(`  riuso la pratica vuota ${vuota.id.slice(0, 8)}`)
  pratica = vuota
}

if (!pratica) {
  const creata = await api('/v1/reviewSubmissions', {
    method: 'POST',
    body: JSON.stringify({
      data: {
        type: 'reviewSubmissions',
        attributes: { platform: 'IOS' },
        relationships: { app: { data: { type: 'apps', id: app.id } } },
      },
    }),
  })
  pratica = creata.data
}

if (pratica && !elemento) {
  try {
    await api('/v1/reviewSubmissionItems', {
      method: 'POST',
      body: JSON.stringify({
        data: {
          type: 'reviewSubmissionItems',
          relationships: {
            reviewSubmission: { data: { type: 'reviewSubmissions', id: pratica.id } },
            appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } },
          },
        },
      }),
    })
  } catch (error) {
    console.error(`✗ La versione non è entrata nella pratica ${pratica.id.slice(0, 8)}:`)
    for (const m of motivi(error)) console.error(`  • ${m}`)
    process.exit(1)
  }
}

try {
  const sent = await api(`/v1/reviewSubmissions/${pratica.id}`, {
    method: 'PATCH',
    body: JSON.stringify({
      data: { type: 'reviewSubmissions', id: pratica.id, attributes: { submitted: true } },
    }),
  })
  console.log(`\n✓ Inviata: ${sent.data.attributes.state}, ${sent.data.attributes.submittedDate}`)
} catch (error) {
  console.error('\n✗ Non è partita:')
  for (const m of motivi(error)) console.error(`  • ${m}`)
  process.exit(1)
}
