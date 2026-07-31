#!/bin/bash
# Builds the app and wraps it in a DMG ready to hand to someone.
#
# The DMG contains the app, an Applications symlink to drag it onto, and a short
# text file explaining the one manual step a self-signed app requires.
#
# Usage: ./package.sh
# Output: dist/Claude Live <version>.dmg
set -euo pipefail

cd "$(dirname "$0")"
source ./release.conf
VERSION="$(tr -d ' \n\r' < VERSION)"

APP_NAME="Claude Live"
DMG_NAME="Claude Live ${VERSION}"
STAGING="build/dmg-root"
DMG_PATH="dist/${DMG_NAME}.dmg"

./build.sh release

echo "==> Preparo il contenuto del DMG"
rm -rf "${STAGING}" "${DMG_PATH}"
mkdir -p "${STAGING}" dist

cp -R "build/${APP_NAME}.app" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

# Self-signed builds are blocked by Gatekeeper on first launch, and since
# macOS 15 the old Control-click → Open shortcut no longer works. Shipping the
# instructions inside the DMG means the recipient reads them at the exact moment
# they hit the problem.
cat > "${STAGING}/COME APRIRE L'APP.txt" <<'TXT'
Claude Live — installazione
===========================

1. Trascina «Claude Live» nella cartella Applicazioni (l'alias qui accanto).

2. Apri Applicazioni e fai doppio clic su Claude Live.

3. macOS dirà che l'app non può essere aperta perché proviene da uno
   sviluppatore non identificato. È normale: l'app non è registrata presso
   Apple. Non è un errore e non significa che ci sia qualcosa che non va.

   Per autorizzarla, una volta sola:

     • apri  Impostazioni di Sistema → Privacy e Sicurezza
     • scorri fino in fondo: trovi «Claude Live è stata bloccata...»
     • premi  «Apri comunque»  e conferma con Touch ID o password

4. Al primo avvio parte una procedura guidata che controlla i requisiti e
   chiede i permessi necessari. Segui i passaggi.

   IMPORTANTE: quando macOS chiede l'accesso al Keychain, scegli
   «Consenti sempre» e non «Consenti». Con «Consenti» la richiesta
   ricomparirà ogni pochi minuti.

5. Claude Live vive nella barra dei menu: cerca l'icona ✦ con la percentuale.
   Non ha icona nel Dock.

Requisiti
---------
  • macOS 14 o successivo
  • Claude Code installato e con login effettuato (comando `claude`)
  • Visual Studio Code (opzionale: serve solo per la lista progetti)

Gli aggiornamenti successivi sono automatici: l'app li scarica e li propone
da sola, senza ripetere questa procedura.
TXT

echo "==> Creo ${DMG_PATH}"
hdiutil create \
  -volname "${DMG_NAME}" \
  -srcfolder "${STAGING}" \
  -ov -format UDZO \
  "${DMG_PATH}" >/dev/null

rm -rf "${STAGING}"

SIZE="$(du -h "${DMG_PATH}" | cut -f1 | tr -d ' ')"
echo
echo "Fatto: ${PWD}/${DMG_PATH} (${SIZE})"
