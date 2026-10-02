/**
 * Quanti accoppiamenti sono vivi, giorno per giorno.
 *
 * ## Cosa misura, e cosa di proposito non misura
 *
 * Un accoppiamento è una coppia Mac–telefono che si è presentata al relay. Il
 * conteggio lo fa il relay stesso: ogni coppia, alla **prima pubblicazione
 * della giornata**, incrementa un numero e basta. Una volta al giorno e non a
 * ogni pubblicazione, perché la domanda è quante ce ne sono, non quanto
 * lavorano.
 *
 * Non viaggia nessun identificativo, e qui non arriva nessun elenco: non c'è
 * modo di sapere chi, da dove, con che versione, né di seguire qualcuno nel
 * tempo. Solo «mercoledì erano sei, di cui uno nuovo». Era la condizione per
 * farlo: il sito non ha tracciatori per scelta, e non ha senso rimediare
 * mettendoli nel relay.
 *
 * I numeri valgono novanta giorni, poi il relay li butta: più indietro non li
 * guarderebbe nessuno, e tenerli sarebbe conservare qualcosa per niente.
 *
 * ## Come leggerli
 *
 * «Attivi» è quante coppie hanno pubblicato almeno una volta quel giorno —
 * quindi un Mac acceso con la pubblicazione accesa. Un Mac spento per una
 * settimana non compare per una settimana e poi torna: non è una disiscrizione,
 * è una persona in ferie.
 *
 * «Nuovi» è quante di quelle non si erano mai viste prima. È l'unico numero che
 * dice se l'app sta crescendo invece che essere solo usata.
 *
 * Uso:
 *   node tools/stats.mjs            gli ultimi quattordici giorni
 *   node tools/stats.mjs --tutti    tutto quello che il relay ha
 */
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'

const TUTTI = process.argv.includes('--tutti')
const RELAY = process.env.RELAY_URL ?? 'https://claude-live-relay.purpleheads.workers.dev'

/// Il segreto sta fuori dal repository, che è pubblico.
function token() {
  if (process.env.STATS_TOKEN) return process.env.STATS_TOKEN
  const path = `${homedir()}/.config/vibingcodelive/stats-token`
  try {
    return readFileSync(path, 'utf8').trim()
  } catch {
    console.error(`Manca il token in ${path}, e non c'è STATS_TOKEN nell'ambiente.`)
    console.error('È lo stesso che sta nel Worker come secret STATS_TOKEN.')
    process.exit(2)
  }
}

const risposta = await fetch(`${RELAY}/stats`, { headers: { 'x-stats-token': token() } })
if (!risposta.ok) {
  console.error(`Il relay ha risposto ${risposta.status}: ${(await risposta.text()).slice(0, 200)}`)
  process.exit(1)
}

const { giorni } = await risposta.json()
if (!giorni?.length) {
  console.log('Ancora nessun giorno registrato: il conteggio parte dalla prossima pubblicazione.')
  process.exit(0)
}

giorni.sort((a, b) => a.giorno.localeCompare(b.giorno))
const mostrati = TUTTI ? giorni : giorni.slice(-14)

console.log('\n  giorno        attivi   nuovi')
console.log('  ' + '─'.repeat(30))
const massimo = Math.max(...mostrati.map((g) => g.attivi), 1)
for (const g of mostrati) {
  const barra = '█'.repeat(Math.round((g.attivi / massimo) * 12))
  console.log(`  ${g.giorno}   ${String(g.attivi).padStart(5)}   ${String(g.nuovi).padStart(5)}  ${barra}`)
}

const totaleNuovi = giorni.reduce((n, g) => n + g.nuovi, 0)
const ultimo = giorni[giorni.length - 1]
console.log('  ' + '─'.repeat(30))
console.log(`  ${ultimo.giorno}: ${ultimo.attivi} attivi, ${ultimo.nuovi} nuovi`)
console.log(`  accoppiamenti mai visti, in tutto il periodo: ${totaleNuovi}`)
console.log(`  giorni registrati: ${giorni.length}\n`)
