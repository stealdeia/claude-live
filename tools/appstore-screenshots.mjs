/**
 * Carica su App Store Connect le schermate della scheda.
 *
 * Le schermate stanno nel repo, come i testi, e per lo stesso motivo: sono
 * prodotto, non contorno. E perché si rifanno — l'app cambia — e senza un posto
 * da cui rifarle si finisce a ritagliare a mano quello che si trova sul disco.
 *
 * Il caricamento è in tre atti, e non è una complicazione di Apple senza motivo:
 * si **prenota** un posto dicendo nome e dimensione, si manda il contenuto agli
 * indirizzi che Apple risponde, e si **conferma** con l'impronta MD5 del file.
 * Se la conferma non arriva, o l'impronta non torna, la schermata resta lì in
 * stato di caricamento a metà e non compare da nessuna parte: vale la pena
 * sapere che il terzo atto esiste, perché il secondo riesce anche senza.
 *
 * Uso:
 *   node tools/appstore-screenshots.mjs            mostra cosa farebbe
 *   node tools/appstore-screenshots.mjs --apply    lo carica
 *
 * Le immagini vengono da `iOS/AppStore/screenshots/<tipo>/`, in ordine di nome:
 * `1-home.png`, `2-glow.png`… Il numero davanti serve a quello, l'ordine sulla
 * scheda è l'ordine dei file.
 */
import { createHash } from 'node:crypto'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { api, app as findApp } from './asc-client.mjs'

const APPLY = process.argv.includes('--apply')
const LOCALE = 'it'
const ROOT = new URL('../iOS/AppStore/screenshots/', import.meta.url)

/// I tipi di schermo che Apple accetta, con la misura che ci mettiamo.
///
/// **Non esiste un `APP_IPHONE_69`**, e costa un tentativo scoprirlo: l'API si
/// è fermata a `APP_IPHONE_67`, e il riquadro da 6,7 pollici accetta sia il
/// 1290×2796 di quella misura sia il 1320×2868 del 6,9. È l'unico riquadro
/// obbligatorio per un'app solo iPhone — Apple riusa queste immagini per tutti
/// gli schermi più piccoli.
const DISPLAY_TYPES = {
  APP_IPHONE_67: '1320x2868 (o 1290x2796)',
  APP_IPHONE_65: '1242x2688',
}

const app = await findApp()
const versions = await api(`/v1/apps/${app.id}/appStoreVersions?limit=1`)
const version = versions.data[0]
if (!version) {
  console.error('Nessuna versione su cui lavorare.')
  process.exit(1)
}
console.log(`App: ${app.attributes.name} — versione ${version.attributes.versionString} (${version.attributes.appStoreState})`)
if (!APPLY) console.log('(prova: niente verrà caricato — aggiungi --apply)\n')

const locs = await api(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)
const loc = locs.data.find((l) => l.attributes.locale === LOCALE)
if (!loc) {
  console.error(`Nessuna scheda in lingua ${LOCALE}.`)
  process.exit(1)
}

/// Le schermate già caricate, per tipo di schermo.
const existing = await api(`/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets`)

for (const [type, size] of Object.entries(DISPLAY_TYPES)) {
  const dir = new URL(`${type}/`, ROOT)
  if (!existsSync(dir)) continue

  const files = readdirSync(dir).filter((f) => f.endsWith('.png')).sort()
  if (files.length === 0) continue

  console.log(`\n${type} (${size}) — ${files.length} schermate`)

  let set = existing.data.find((s) => s.attributes.screenshotDisplayType === type)

  // Un insieme già pieno non viene svuotato di nascosto: cancellare roba
  // pubblicata perché uno script è stato lanciato due volte è il genere di
  // servizio che nessuno ha chiesto.
  if (set) {
    const already = await api(`/v1/appScreenshotSets/${set.id}/appScreenshots?limit=20`)
    if (already.data.length > 0) {
      console.log(`  già ${already.data.length} caricate: le lascio stare.`)
      console.log('  (per rifarle, svuota il riquadro su App Store Connect e rilancia)')
      continue
    }
  }

  if (!APPLY) {
    for (const f of files) console.log(`  + ${f}`)
    continue
  }

  if (!set) {
    const created = await api('/v1/appScreenshotSets', {
      method: 'POST',
      body: JSON.stringify({
        data: {
          type: 'appScreenshotSets',
          attributes: { screenshotDisplayType: type },
          relationships: {
            appStoreVersionLocalization: {
              data: { type: 'appStoreVersionLocalizations', id: loc.id },
            },
          },
        },
      }),
    })
    set = created.data
  }

  for (const name of files) {
    const bytes = readFileSync(new URL(name, dir))

    // Atto primo: la prenotazione. Apple risponde con gli indirizzi a cui
    // mandare il contenuto, che sono firmati e scadono.
    const reserved = await api('/v1/appScreenshots', {
      method: 'POST',
      body: JSON.stringify({
        data: {
          type: 'appScreenshots',
          attributes: { fileSize: bytes.length, fileName: name },
          relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set.id } } },
        },
      }),
    })
    const shot = reserved.data

    // Atto secondo: il contenuto, a pezzi se Apple lo chiede. Gli header
    // arrivano da lei e vanno rispediti parola per parola — è lì dentro che sta
    // l'autorizzazione a scrivere in quel posto.
    for (const op of shot.attributes.uploadOperations) {
      const chunk = bytes.subarray(op.offset, op.offset + op.length)
      const headers = Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value]))
      const response = await fetch(op.url, { method: op.method, headers, body: chunk })
      if (!response.ok) {
        console.error(`  ✗ ${name}: il pezzo a ${op.offset} non è salito (${response.status})`)
        process.exit(1)
      }
    }

    // Atto terzo: la conferma. Senza, resta a metà e non si vede.
    const md5 = createHash('md5').update(bytes).digest('hex')
    await api(`/v1/appScreenshots/${shot.id}`, {
      method: 'PATCH',
      body: JSON.stringify({
        data: {
          type: 'appScreenshots',
          id: shot.id,
          attributes: { uploaded: true, sourceFileChecksum: md5 },
        },
      }),
    })
    console.log(`  ✓ ${name}`)
  }
}

console.log('\nFatto.')
