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

### 2. Niente magazzino da creare

Lo stato di ogni coppia sta in un **Durable Object**, uno per identificativo, e
il binding è già dichiarato in `wrangler.jsonc`. Non c'è nulla da creare a mano.

Prima stava in KV, e il piano gratuito concede mille scritture al giorno: il solo
battito di presenza — una pubblicazione ogni sessanta secondi, per non far
apparire sul telefono l'avviso «il Mac è scollegato» — ne chiedeva 2.880. Il
relay si spegneva al primo giorno di uso reale, con un solo utente.


### 3. Consegnare la chiave APNs a Cloudflare

```sh
npx wrangler secret put APNS_KEY < "$HOME/Documents/Chiavi Apple/AuthKey_HCJSWTZ9L4.p8"
```

Il `<` fa passare il file direttamente a Cloudflare: il contenuto non compare a
schermo e non finisce nella cronologia del terminale. Da qui in avanti la chiave
vive su Cloudflare e il file locale serve solo come copia di riserva.

### 4. Nessuna parola d'ordine da inventare

Ogni Mac si genera il suo identificativo al primo avvio, lo tiene nel portachiavi
e lo mostra solo dentro il QR. È insieme l'indirizzo dei suoi dati sul relay e il
permesso di toccarli, e il relay non conserva alcun segreto condiviso.

Una password comune non poteva essere nessuna delle due cose: autorizza tutti a
tutto, e deve pure arrivare da qualche parte — digitata a mano, cosa che nessuno
farà, o spedita dentro l'app, dove chiunque la estrae. Con l'identificativo, un
relay serve quante coppie vuoi e nessuna vede le altre.


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
  -H "authorization: Bearer <identificativo della coppia>"
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
