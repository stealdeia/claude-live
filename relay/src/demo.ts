/**
 * L'accoppiamento dimostrativo: un Mac che non esiste.
 *
 * ## Perché
 *
 * Il 2026-09-22 Apple ha respinto l'app sulla 2.1(a) chiedendo «a demo QR code
 * to fully assess the app features». È una richiesta ragionevole e il video non
 * bastava: questa app senza un Mac accoppiato non mostra niente, per scelta, e
 * il revisore un Mac con Claude Code sopra non ce l'ha.
 *
 * L'alternativa era lasciare acceso un Mac vero per tutta la revisione. Se
 * quello si addormenta alle tre di notte, il revisore vede «Mac non
 * raggiungibile» e il rifiuto arriva per una ragione che non c'entra col
 * prodotto. Questo invece non dorme.
 *
 * ## Come
 *
 * Il telefono non sa di essere in una dimostrazione, e **non deve saperlo**: si
 * accoppia con un QR come con qualunque Mac, legge da `/state` una scatola
 * sigillata e la apre con la chiave del QR. Quella scatola qui la prepara il
 * relay invece di un Mac, e la prepara **a ogni richiesta**, con gli orari
 * rifatti su adesso — altrimenti dopo due minuti l'app direbbe «dal Mac 3 ore
 * fa», che è esattamente il guasto che l'app esiste per rendere visibile.
 *
 * Le due fotografie stanno in `demo-snapshots.json` e **le ha scritte Swift**,
 * con i tipi veri e il vero encoder: la forma del JSON è decisa dai `Codable`
 * sintetizzati, e per esempio lo stato «in attesa» si serializza `waitingInput`
 * in camelCase, non `waiting_input` come nei file dell'hook. A mano si
 * sbaglierebbe, e il guasto si vedrebbe solo come «il telefono non apre la
 * scatola».
 *
 * ## Cosa succede premendo Consenti
 *
 * Il comando arriva su `/command` come per un Mac vero. Qui nessuno lo
 * raccoglie, quindi lo raccoglie questo: da quel momento e per novanta secondi
 * le fotografie sono quelle del lavoro ripreso — il permesso sparito, la chat
 * con una riga in più, i test che passano. Poi si torna in attesa, così la
 * dimostrazione si può rifare quante volte si vuole.
 *
 * ## L'identificativo e la chiave stanno in chiaro, ed è voluto
 *
 * Questo file è in un repository pubblico. Chi legge può accoppiarsi alla
 * dimostrazione e vedere quattro progetti inventati e una conversazione su un
 * carrello: non c'è niente da proteggere, e anzi il giorno che il sito volesse
 * offrire «provala senza installare niente», il QR è già questo.
 */
import { chacha20poly1305 } from '@noble/ciphers/chacha.js'
import snapshots from './demo-snapshots.json'

/** L'identificativo dell'accoppiamento dimostrativo. Trentadue esadecimali, come ogni altro. */
export const DEMO_PAIR_ID = '19e1027d802fa979999e727957c1364c'

/** La chiave con cui il telefono apre le scatole della dimostrazione. */
export const DEMO_KEY_B64 = 'gKS8U2od40zXY5UYzNKThI2Cqfxol0qQXxtAn3Zqg+A='

/** L'istante su cui sono scritte le fotografie: tutte le date sono scarti da qui. */
const TEMPLATE_EPOCH = 1_800_000_000

/** Per quanto, dopo una risposta, si vede il lavoro ripreso. */
const RESUMED_MS = 90_000

/**
 * I campi che contengono una data, ovunque si trovino.
 *
 * Per nome e non per posizione: le date stanno annidate a profondità diverse —
 * dentro le sessioni, dentro i messaggi, dentro le finestre d'utilizzo — e un
 * elenco di percorsi sarebbe un elenco da tenere in pari a ogni campo aggiunto.
 * Il nome invece segue il campo dovunque vada.
 */
const DATE_FIELDS = new Set(['generatedAt', 'updatedAt', 'raisedAt', 'at', 'fetchedAt', 'resetAt'])

/** Rifà tutte le date come scarti da adesso invece che dall'istante del modello. */
function rebase(value: unknown, nowSeconds: number): unknown {
  if (Array.isArray(value)) return value.map((v) => rebase(v, nowSeconds))
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const [key, v] of Object.entries(value as Record<string, unknown>)) {
      out[key] =
        DATE_FIELDS.has(key) && typeof v === 'number'
          ? Math.round(nowSeconds + (v - TEMPLATE_EPOCH))
          : rebase(v, nowSeconds)
    }
    return out
  }
  return value
}

function keyBytes(): Uint8Array {
  const raw = atob(DEMO_KEY_B64)
  const bytes = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i)
  return bytes
}

/**
 * Sigilla come fa il Mac: `ChaChaPoly.seal(...).combined`, cioè
 * **nonce ‖ testo cifrato ‖ tag**, in base64.
 *
 * `@noble/ciphers` è l'unica dipendenza a runtime di questo Worker, e vale la
 * pena dire perché: la Web Crypto di Workers non offre ChaCha20-Poly1305 — ha
 * AES-GCM — e l'app apre solo ChaChaPoly. Le alternative erano scriverselo a
 * mano, che per una cifratura è la cosa da non fare, o cambiare l'algoritmo su
 * entrambi i lati per una dimostrazione.
 */
function seal(plaintext: string): string {
  const nonce = crypto.getRandomValues(new Uint8Array(12))
  const sealed = chacha20poly1305(keyBytes(), nonce).encrypt(new TextEncoder().encode(plaintext))
  const combined = new Uint8Array(nonce.length + sealed.length)
  combined.set(nonce, 0)
  combined.set(sealed, nonce.length)
  let binary = ''
  for (const b of combined) binary += String.fromCharCode(b)
  return btoa(binary)
}

/**
 * La fotografia da consegnare adesso.
 *
 * `decidedAt` è quando il telefono ha risposto, se ha risposto: entro
 * novanta secondi si vede il lavoro ripreso, dopo si torna in attesa.
 */
export function demoPayload(decidedAt: number | null, now = Date.now()): string {
  const resumed = decidedAt !== null && now - decidedAt < RESUMED_MS
  const template = resumed ? snapshots.consentito : snapshots.inAttesa
  const fresh = rebase(template, Math.floor(now / 1000))
  return seal(JSON.stringify(fresh))
}

/** Se questa risposta è ancora quella del lavoro ripreso. */
export function demoIsResumed(decidedAt: number | null, now = Date.now()): boolean {
  return decidedAt !== null && now - decidedAt < RESUMED_MS
}
