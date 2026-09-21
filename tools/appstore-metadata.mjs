/**
 * Carica su App Store Connect i testi di `iOS/AppStore/metadata.json`.
 *
 * I testi stanno nel repo e non solo nel pannello di Apple perché una
 * descrizione è testo del prodotto: va riletta, corretta e versionata come il
 * resto. E perché il pannello non ha una cronologia — una frase peggiorata per
 * sbaglio non si recupera.
 *
 * Uso:
 *   node tools/appstore-metadata.mjs            mostra cosa cambierebbe
 *   node tools/appstore-metadata.mjs --apply    lo carica
 */
import { readFileSync } from 'node:fs'
import { api, app as findApp } from './asc-client.mjs'

const meta = JSON.parse(readFileSync(new URL('../iOS/AppStore/metadata.json', import.meta.url), 'utf8'))
const LOCALE = meta.locale ?? 'it'
const APPLY = process.argv.includes('--apply')

const app = await findApp()
console.log(`App: ${app.attributes.name} — lingua ${app.attributes.primaryLocale}`)
if (!APPLY) console.log('(prova: niente verrà scritto — aggiungi --apply)\n')

/// I limiti di Apple, controllati qui e non scoperti a metà caricamento: un
/// campo rifiutato lascia gli altri già scritti, e lo stato a metà è peggio di
/// nessuno stato.
const LIMITS = { subtitle: 30, promotionalText: 170, keywords: 100, description: 4000 }
for (const [field, limit] of Object.entries(LIMITS)) {
  const value = meta[field]
  if (typeof value === 'string' && value.length > limit) {
    console.error(`✗ ${field}: ${value.length} caratteri, il massimo è ${limit}.`)
    process.exit(1)
  }
}

async function patch(type, id, attributes, label) {
  const present = Object.fromEntries(Object.entries(attributes).filter(([, v]) => v != null))
  if (Object.keys(present).length === 0) return
  console.log(`  ${label}: ${Object.keys(present).join(', ')}`)
  if (!APPLY) return
  await api(`/v1/${type}/${id}`, {
    method: 'PATCH',
    body: JSON.stringify({ data: { type, id, attributes: present } }),
  })
}

// --- Nome, sottotitolo, privacy: vivono sull'«app info», non sulla versione ---
const infos = await api(`/v1/apps/${app.id}/appInfos?fields[appInfos]=state`)
// Quella modificabile: le versioni già pubblicate hanno il loro appInfo congelato.
const info = infos.data.find((i) => i.attributes.state !== 'READY_FOR_DISTRIBUTION') ?? infos.data[0]
const infoLocs = await api(
  `/v1/appInfos/${info.id}/appInfoLocalizations?fields[appInfoLocalizations]=locale`
)
const infoLoc = infoLocs.data.find((l) => l.attributes.locale === LOCALE)
if (infoLoc) {
  await patch('appInfoLocalizations', infoLoc.id, {
    subtitle: meta.subtitle,
    privacyPolicyUrl: meta.privacyPolicyUrl,
  }, 'scheda')
} else {
  console.log(`  scheda: nessuna localizzazione ${LOCALE}, salto`)
}

// --- Categoria -------------------------------------------------------------
if (meta.primaryCategory) {
  console.log(`  categoria: ${meta.primaryCategory}`)
  if (APPLY) {
    await api(`/v1/appInfos/${info.id}`, {
      method: 'PATCH',
      body: JSON.stringify({
        data: {
          type: 'appInfos',
          id: info.id,
          relationships: {
            primaryCategory: { data: { type: 'appCategories', id: meta.primaryCategory } },
          },
        },
      }),
    })
  }
}

// --- Diritti sul contenuto, che vive sull'app -------------------------------
/// App Store Connect non lo segnala come mancante da nessuna parte: si scopre
/// quando la pratica viene rifiutata in blocco al momento dell'invio.
if (meta.contentRightsDeclaration) {
  console.log(`  diritti sul contenuto: ${meta.contentRightsDeclaration}`)
  if (APPLY) {
    await api(`/v1/apps/${app.id}`, {
      method: 'PATCH',
      body: JSON.stringify({
        data: {
          type: 'apps',
          id: app.id,
          attributes: { contentRightsDeclaration: meta.contentRightsDeclaration },
        },
      }),
    })
  }
}

// --- Classificazione per età ------------------------------------------------
/// Compila solo i campi ancora vuoti, mai quelli già risposti: una risposta data
/// da una persona non va sovrascritta da uno script.
///
/// I tipi si scoprono dagli errori invece di essere scritti a mano. Alcuni campi
/// vogliono una stringa e altri un booleano, la divisione non segue nessuna
/// logica visibile, e Apple la cambia: l'errore però dice quale campo e quale
/// tipo si aspetta, quindi correggersi da soli è più solido che indovinare — e
/// non va riscoperto al prossimo cambio.
if (meta.ageRating?.tuttoNegativo) {
  const declaration = await api(`/v1/appInfos/${info.id}/ageRatingDeclaration`)
  const skip = new Set(['kidsAgeBand', 'developerAgeRatingInfoUrl', 'ageRatingOverrideV2', 'koreaAgeRatingOverride'])
  const attributes = {}
  for (const [key, value] of Object.entries(declaration.data.attributes)) {
    if (value === null && !skip.has(key)) attributes[key] = 'NONE'
  }
  const count = Object.keys(attributes).length
  console.log(`  classificazione per età: ${count === 0 ? 'già compilata' : `${count} campi da dichiarare`}`)
  if (APPLY && count > 0) {
    for (let round = 1; round <= 40; round++) {
      try {
        await api(`/v1/ageRatingDeclarations/${info.id}`, {
          method: 'PATCH',
          body: JSON.stringify({ data: { type: 'ageRatingDeclarations', id: info.id, attributes } }),
        })
        break
      } catch (error) {
        const message = String(error.message)
        const field = message.match(/attribute '([^']+)'/)?.[1]
        const wants = message.match(/Expected a (\w+)/)?.[1]
        if (!field || !wants) throw error
        if (wants === 'BOOLEAN') attributes[field] = false
        else if (wants === 'STRING') attributes[field] = 'NONE'
        else delete attributes[field]
      }
    }
  }
}

// --- Descrizione, parole chiave, URL: vivono sulla versione ------------------
const versions = await api(
  `/v1/apps/${app.id}/appStoreVersions?fields[appStoreVersions]=versionString,appStoreState&limit=10`
)
const editable = versions.data.find((v) =>
  ['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED'].includes(
    v.attributes.appStoreState
  )
)
if (editable) {
  const locs = await api(
    `/v1/appStoreVersions/${editable.id}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale`
  )
  if (meta.copyright) {
    await patch('appStoreVersions', editable.id, { copyright: meta.copyright }, 'copyright')
  }
  const loc = locs.data.find((l) => l.attributes.locale === LOCALE)
  if (loc) {
    await patch('appStoreVersionLocalizations', loc.id, {
      description: meta.description,
      keywords: meta.keywords,
      promotionalText: meta.promotionalText,
      supportUrl: meta.supportUrl,
      marketingUrl: meta.marketingUrl,
    }, `versione ${editable.attributes.versionString}`)
  }
} else {
  console.log('  versione: nessuna bozza modificabile')
}

// --- Le note per il revisore di Apple ---------------------------------------
/// Quello che Apple legge prima di aprire l'app, e per questa app conta più del
/// solito: senza un Mac acceso con Claude Code sopra, il revisore vede la
/// schermata di benvenuto e niente altro. Un'app companion che non si spiega
/// viene rifiutata sulla 2.1, e il rifiuto costa un giro completo.
// Le note NON sono legate alla bozza, ed è la differenza che conta: la versione
// più recente va bene anche se è già in coda per la revisione. Erano dentro il
// ramo `editable` e venivano **saltate in silenzio** con la versione in
// `WAITING_FOR_REVIEW` — il 2026-09-21 è servito scriverle proprio in quel
// momento, perché dopo un reinvio il Centro risoluzioni non accetta più
// risposte e le note sono l'unico posto che il revisore legge comunque.
const versionForReview = editable ?? versions.data[0]
if (meta.review && versionForReview) {
  const r = meta.review
  // Il segnaposto del video non deve arrivare ad Apple. Il controllo sta qui e
  // non nella testa di chi lancia il comando: è esattamente il genere di cosa
  // che si nota dopo l'invio.
  if (typeof r.notes === 'string' && r.notes.includes('<<')) {
    console.error("\n✗ Le note per il revisore contengono ancora un segnaposto (<<…>>): sostituiscilo prima di caricarle.")
    process.exit(1)
  }
  if (!r.contactPhone) {
    console.error('\n✗ Manca il telefono del contatto per la revisione: Apple lo pretende e rifiuta la richiesta senza.')
    process.exit(1)
  }
  const attributes = {
    contactFirstName: r.contactFirstName,
    contactLastName: r.contactLastName,
    contactEmail: r.contactEmail,
    contactPhone: r.contactPhone,
    demoAccountRequired: r.demoAccountRequired ?? false,
    notes: r.notes,
  }
  const current = await api(`/v1/appStoreVersions/${versionForReview.id}/appStoreReviewDetail`)
  if (current.data) {
    await patch('appStoreReviewDetails', current.data.id, attributes, 'note per il revisore')
  } else {
    console.log('  note per il revisore: le creo')
    if (APPLY) {
      await api('/v1/appStoreReviewDetails', {
        method: 'POST',
        body: JSON.stringify({
          data: {
            type: 'appStoreReviewDetails',
            attributes,
            relationships: {
              appStoreVersion: { data: { type: 'appStoreVersions', id: versionForReview.id } },
            },
          },
        }),
      })
    }
  }
}

// --- TestFlight: quello che i tester leggono prima di installare -------------
if (meta.beta) {
  const existing = await api(
    `/v1/apps/${app.id}/betaAppLocalizations?fields[betaAppLocalizations]=locale`
  )
  const found = existing.data.find((l) => l.attributes.locale === LOCALE)
  const attributes = {
    description: meta.beta.description,
    feedbackEmail: meta.beta.feedbackEmail,
    marketingUrl: meta.beta.marketingUrl,
    privacyPolicyUrl: meta.beta.privacyPolicyUrl,
  }
  if (found) {
    await patch('betaAppLocalizations', found.id, attributes, 'TestFlight')
  } else {
    console.log(`  TestFlight: creo la localizzazione ${LOCALE}`)
    if (APPLY) {
      await api('/v1/betaAppLocalizations', {
        method: 'POST',
        body: JSON.stringify({
          data: {
            type: 'betaAppLocalizations',
            attributes: { locale: LOCALE, ...Object.fromEntries(Object.entries(attributes).filter(([, v]) => v != null)) },
            relationships: { app: { data: { type: 'apps', id: app.id } } },
          },
        }),
      })
    }
  }
}

// --- «Cosa provare», che è per build e non per app --------------------------
if (meta.buildWhatsNew) {
  const builds = await api(
    `/v1/builds?filter[app]=${app.id}&fields[builds]=version,expired&sort=-uploadedDate&limit=5`
  )
  const newest = builds.data.find((b) => !b.attributes.expired)
  if (newest) {
    const locs = await api(
      `/v1/builds/${newest.id}/betaBuildLocalizations?fields[betaBuildLocalizations]=locale`
    )
    const loc = locs.data.find((l) => l.attributes.locale === LOCALE)
    if (loc) {
      await patch('betaBuildLocalizations', loc.id, { whatsNew: meta.buildWhatsNew }, `cosa provare (build ${newest.attributes.version})`)
    } else {
      console.log(`  cosa provare (build ${newest.attributes.version}): creo la localizzazione`)
      if (APPLY) {
        await api('/v1/betaBuildLocalizations', {
          method: 'POST',
          body: JSON.stringify({
            data: {
              type: 'betaBuildLocalizations',
              attributes: { locale: LOCALE, whatsNew: meta.buildWhatsNew },
              relationships: { build: { data: { type: 'builds', id: newest.id } } },
            },
          }),
        })
      }
    }
  }
}

console.log(APPLY ? '\n✓ Caricato.' : '\nNiente scritto.')
