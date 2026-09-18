/**
 * Allega alla pratica di revisione il video dimostrativo.
 *
 * Perché un allegato e non un indirizzo dentro le note: questa app non si può
 * provare senza un Mac con Claude Code sopra, quindi il video **è** la
 * dimostrazione — e un video che vive su un servizio esterno può sparire,
 * diventare privato o richiedere un login proprio mentre il revisore lo apre.
 * Dentro la pratica ci resta.
 *
 * Stesso caricamento in tre atti delle schermate: si prenota, si manda, si
 * conferma con l'MD5. Il terzo atto è quello che si dimentica, e senza l'
 * allegato resta invisibile pur essendo stato trasferito per intero.
 *
 * Uso:
 *   node tools/appstore-review-video.mjs <file>            mostra cosa farebbe
 *   node tools/appstore-review-video.mjs <file> --apply    lo carica
 */
import { createHash } from 'node:crypto'
import { readFileSync, statSync } from 'node:fs'
import { basename } from 'node:path'
import { api, app as findApp } from './asc-client.mjs'

const APPLY = process.argv.includes('--apply')
const file = process.argv.slice(2).find((a) => !a.startsWith('--'))
if (!file) {
  console.error('Uso: node tools/appstore-review-video.mjs <file> [--apply]')
  process.exit(2)
}

const bytes = readFileSync(file)
const name = basename(file)
console.log(`${name} — ${(statSync(file).size / 1024 / 1024).toFixed(1)} MB`)

const app = await findApp()
const versions = await api(`/v1/apps/${app.id}/appStoreVersions?limit=1`)
const version = versions.data[0]
const detail = await api(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`)
if (!detail.data) {
  console.error('Non ci sono ancora le note per il revisore: carica prima quelle.')
  process.exit(1)
}

const existing = await api(`/v1/appStoreReviewDetails/${detail.data.id}/appStoreReviewAttachments`)
if (existing.data.length > 0) {
  console.log(`  c'è già un allegato (${existing.data[0].attributes.fileName}): lo lascio stare.`)
  process.exit(0)
}

if (!APPLY) {
  console.log('  (prova: niente verrà caricato — aggiungi --apply)')
  process.exit(0)
}

const reserved = await api('/v1/appStoreReviewAttachments', {
  method: 'POST',
  body: JSON.stringify({
    data: {
      type: 'appStoreReviewAttachments',
      attributes: { fileSize: bytes.length, fileName: name },
      relationships: {
        appStoreReviewDetail: { data: { type: 'appStoreReviewDetails', id: detail.data.id } },
      },
    },
  }),
})

for (const op of reserved.data.attributes.uploadOperations) {
  const chunk = bytes.subarray(op.offset, op.offset + op.length)
  const headers = Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value]))
  const response = await fetch(op.url, { method: op.method, headers, body: chunk })
  if (!response.ok) {
    console.error(`  ✗ il pezzo a ${op.offset} non è salito (${response.status})`)
    process.exit(1)
  }
  process.stdout.write('.')
}
process.stdout.write('\n')

await api(`/v1/appStoreReviewAttachments/${reserved.data.id}`, {
  method: 'PATCH',
  body: JSON.stringify({
    data: {
      type: 'appStoreReviewAttachments',
      id: reserved.data.id,
      attributes: { uploaded: true, sourceFileChecksum: createHash('md5').update(bytes).digest('hex') },
    },
  }),
})
console.log('✓ Allegato.')
