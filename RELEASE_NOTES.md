Al 100% dei token il pannello mostrava 1%.

- **Corretto il calcolo dell'utilizzo a limite raggiunto.** Quando la sessione 5h si esaurisce l'API riporta un valore poco sopra 1 (l'ultima richiesta sfonda il tetto, quindi 102%): un controllo «difensivo» lo interpretava come una percentuale già in centesimi e lo divideva per 100, mostrando **1% invece di 100%**. Ora il 100% si vede, in rosso, con la barra piena — e una finestra che l'API dichiara esaurita viene mostrata piena anche se il numero fosse appena sotto.
- **Il polling non si blocca più dietro un dialogo del portachiavi.** La lettura veloce che controlla se le credenziali sono cambiate non aveva un limite di tempo: con un dialogo aperto sullo schermo l'intero portachiavi si mette in coda dietro di esso, e l'aggiornamento dei numeri restava fermo fino alla risposta. Ora, se quella lettura non arriva in pochi secondi, l'app continua con le credenziali che ha già.

Il primo difetto era invisibile senza esaurire davvero la quota: ho aggiunto un modo per
forzare qualsiasi valore di utilizzo, così il caso «limite raggiunto» si può provare
in qualsiasi momento invece di aspettare di incontrarlo.
