Due correzioni importanti segnalate dall'uso reale.

- **Basta richieste di password ripetute.** L'app rileggeva le credenziali dal Keychain a ogni controllo dei limiti, cioè ogni 5 minuti: su un Mac dove l'autorizzazione «Consenti sempre» non viene memorizzata, questo significava un prompt ogni 5 minuti. Ora le credenziali restano in memoria e il Keychain viene letto una volta per durata del token, circa ogni 10 ore. Verificato: 5 controlli dei limiti, 1 sola lettura.
- **VS Code non lampeggia più nel Dock.** L'app si aggiornava a ogni scrittura di VS Code nella propria cartella di stato, e ogni aggiornamento fa comparire per un istante una seconda icona di VS Code. Ora si aggiorna solo quando l'insieme dei progetti cambia davvero.

Inoltre: la lettura consulta solo la voce principale del Keychain, e ricorre alle
varianti solo se quella manca — meno occasioni per far comparire il dialogo.
