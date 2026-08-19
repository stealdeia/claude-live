# Relay di Claude Live

Il programmino sempre acceso che sta in mezzo fra il Mac e l'iPhone.

Serve perché iOS spegne le app quando non le guardi: un'app chiusa non può
controllare niente da sola, e l'unica cosa che può svegliarla è una notifica
push — che per forza deve partire da un computer sempre acceso su Internet, non
dal Mac che dorme.

## Cosa fa oggi

Solo una cosa, e di proposito: **misura quanto tempo ci mette un avviso ad
andare dal Mac al telefono**. È la domanda da cui dipende tutto il resto, perché
quando Claude chiede un permesso l'hook resta in attesa per un tempo limitato.
Se il giro non sta dentro quella finestra, l'idea di rispondere dal telefono va
ripensata — e tanto vale scoprirlo adesso che dopo aver costruito l'app intera.

Non tiene niente in memoria a parte l'indirizzo del telefono. I tempi viaggiano
dentro il messaggio e il conto lo fa il telefono, così la misura non viene
sporcata dal magazzino che attraversa.

Gira sul piano **gratuito** di Cloudflare Workers: 100.000 richieste al giorno,
noi ne useremo qualche centinaio.

## Preparazione — si fa una volta sola

Tutti i comandi vanno dati stando dentro la cartella `relay/`.

### 1. Collegare l'account Cloudflare

```sh
npx wrangler login
```

Si apre il browser dove sei già connesso: clicca **Allow**. Nessuna password
viene digitata qui, e il permesso lo revochi quando vuoi dal pannello di
Cloudflare.

### 2. Creare il magazzino per l'indirizzo del telefono

```sh
npx wrangler kv namespace create DEVICES
```

Stampa un `id` fra virgolette. Copialo dentro `wrangler.jsonc`, al posto di
`DA_COMPILARE`.

### 3. Consegnare la chiave APNs a Cloudflare

```sh
npx wrangler secret put APNS_KEY < "$HOME/Documents/Chiavi Apple/AuthKey_2JZXN9U87K.p8"
```

Il `<` fa passare il file direttamente a Cloudflare: il contenuto non compare a
schermo e non finisce nella cronologia del terminale. Da qui in avanti la chiave
vive su Cloudflare e il file locale serve solo come copia di riserva.

### 4. Inventare una parola d'ordine fra Mac e telefono

```sh
openssl rand -hex 32
npx wrangler secret put PAIR_SECRET
```

Il primo comando stampa una stringa lunga a caso; incollala quando il secondo la
chiede. Serve a evitare che un estraneo che indovini l'indirizzo del relay possa
mandare notifiche al tuo telefono. Tienila da parte: servirà anche al Mac e
all'app.

### 5. Mandarlo online

```sh
npx wrangler deploy
```

Stampa l'indirizzo, del tipo
`https://claude-live-relay.<tuo-nome>.workers.dev`.

Verifica che risponda:

```sh
curl https://claude-live-relay.<tuo-nome>.workers.dev/health
```

## Sandbox o produzione

In `wrangler.jsonc` c'è `APNS_ENV`. **Va tenuto su `sandbox`** finché l'app la
installi collegando l'iPhone al Mac con Xcode. Diventa `production` solo quando
l'app arriva da TestFlight.

Sbagliarlo è il modo più comune di non ricevere niente senza capire perché:
Apple risponde `BadDeviceToken` e la notifica sparisce in silenzio.

## Misurare

Con l'app installata sul telefono e registrata:

```sh
curl -X POST https://<indirizzo>/ping \
  -H "authorization: Bearer <PAIR_SECRET>"
```

Sul telefono compare la notifica. Il numero che conta è quello che l'app
mostra: quanti millisecondi sono passati fra la partenza dal relay e l'arrivo.

Un'avvertenza sulla lettura del risultato: Mac e iPhone hanno orologi diversi,
allineati entrambi via Internet ma non identici. Su una finestra di decine di
secondi lo scarto è irrilevante; se un giorno dovessimo misurare millisecondi
andrebbe tolto di mezzo.

## Se qualcosa non funziona

Per vedere in diretta cosa succede dentro il relay:

```sh
npx wrangler tail
```

Gli errori di APNs arrivano con la spiegazione di Apple dentro il campo
`reason`, che è l'unica cosa che rende diagnosticabile un rifiuto.
