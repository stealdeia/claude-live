L'app non si «spegne» più il giorno dopo.

Il problema che si vedeva: numeri sbiaditi, dati fermi a ore prima, nessuna
spiegazione. Nel log di una notte ci sono tre cause distinte, tutte corrette qui.

- **Non rinuncia più a provare per colpa dell'orologio.** Prima, se il token
  risultava scaduto, l'app non inviava nemmeno la richiesta: in un caso reale ha
  rifiutato un token ancora valido per 4 minuti e poi è rimasta ferma 30 minuti,
  leggendo il portachiavi ogni 5 minuti senza mai chiedere niente al server. Ora
  prova, e se un token viene davvero rifiutato aspetta in silenzio che Claude Code
  ne scriva uno nuovo — poi riparte da sé, entro un ciclo.
- **Un dialogo del portachiavi senza risposta non blocca più l'aggiornamento.**
  Poteva tenerlo fermo quanto restava aperto: in un caso 55 minuti, con dieci
  aggiornamenti consecutivi saltati.
- **Di notte non tenta più letture impossibili.** Quando il Mac si sveglia da solo
  per la manutenzione lo schermo è spento e il portachiavi non può chiedere nulla:
  cinque errori in una notte, ognuno dei quali cancellava i numeri dal pannello.
  Ora gli aggiornamenti automatici si fermano a schermo spento.
- **Quando i numeri sono sbiaditi, il pannello dice perché.** Una riga arancione con
  la causa: token rifiutato, connessione assente, errore HTTP. Prima lo sbiadito era
  l'unico segnale, e sembrava che l'app fosse disattivata.

Come effetto collaterale, il portachiavi viene letto molto meno: una volta per
rinnovo del token invece di una volta ogni cinque minuti. Chi ancora vedeva comparire
la richiesta della password dovrebbe vederla molto più raramente.
