#!/bin/bash
# Builds the app and wraps it in a DMG ready to hand to someone.
#
# With a Developer ID identity the app and the DMG are also notarised by Apple
# and the tickets stapled into both, so recipients get no Gatekeeper prompt at
# all. Notarisation lives here rather than in build.sh on purpose: build.sh runs
# on every code change, and waiting on Apple for each dev build would be absurd.
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

fail() { echo "✗ $*" >&2; exit 1; }

NOTARIZE=0
[[ "${SIGN_IDENTITY}" == "Developer ID Application:"* ]] && NOTARIZE=1

# --- Pre-flight -------------------------------------------------------------
# Checked before the build, not after: the build takes a while and a missing
# certificate is instant to detect.
if [[ "${NOTARIZE}" == "1" ]]; then
  [[ "${SIGN_IDENTITY}" != *CHANGEME* ]] || \
    fail "SIGN_IDENTITY in release.conf è ancora il segnaposto. Mettici la stringa esatta di 'security find-identity -v -p codesigning'."
  security find-identity -v -p codesigning 2>/dev/null | grep -qF "${SIGN_IDENTITY}" || \
    fail "L'identità «${SIGN_IDENTITY}» non è nel portachiavi. Creala in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application."
  security find-generic-password -s "com.apple.gs.appleid.auth" >/dev/null 2>&1 || true
  xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 || \
    fail "Profilo notarytool «${NOTARY_PROFILE}» assente o non valido. Creane uno con 'xcrun notarytool store-credentials' — vedi release.conf."
fi

# Submits one artefact and blocks until Apple has ruled on it. `--wait` alone is
# not enough: a submission can come back "Invalid" with a zero exit status, so
# the verdict is parsed, and on failure the full log is printed — without it the
# only thing you get is an opaque UUID.
submit_and_wait() {
  local target="$1" out id
  echo "    invio $(basename "${target}") ad Apple, attendo il verdetto…"
  out="$(xcrun notarytool submit "${target}" \
           --keychain-profile "${NOTARY_PROFILE}" --wait 2>&1)" || true
  sed 's/^/    /' <<< "${out}"
  if ! grep -q 'status: Accepted' <<< "${out}"; then
    id="$(sed -n 's/.*[[:space:]]id: \([0-9a-f-]\{36\}\).*/\1/p' <<< "${out}" | head -1)"
    if [[ -n "${id}" ]]; then
      echo "==> Log di notarizzazione ${id}" >&2
      xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" >&2 2>&1 || true
    fi
    fail "Notarizzazione non accettata per $(basename "${target}")."
  fi
}

./build.sh release

# The app is notarised and stapled *before* going into the DMG. Notarising only
# the DMG would also work online, but the app dragged out of it would carry no
# ticket of its own and a first launch without network could still be blocked.
if [[ "${NOTARIZE}" == "1" ]]; then
  echo "==> Notarizzo l'app"
  NOTARY_ZIP="build/notarize-app.zip"
  rm -f "${NOTARY_ZIP}"
  # ditto, not zip: only ditto preserves the bundle's symlinks and metadata, and
  # a zip-mangled bundle is rejected.
  /usr/bin/ditto -c -k --keepParent "build/${APP_NAME}.app" "${NOTARY_ZIP}"
  submit_and_wait "${NOTARY_ZIP}"
  rm -f "${NOTARY_ZIP}"
  xcrun stapler staple "build/${APP_NAME}.app"
fi

echo "==> Preparo il contenuto del DMG"
rm -rf "${STAGING}" "${DMG_PATH}"
mkdir -p "${STAGING}" dist

cp -R "build/${APP_NAME}.app" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

# A notarised build just opens, so the instructions shrink to the steps that are
# actually still there. An unsigned/self-signed one is blocked by Gatekeeper on
# first launch — and since macOS 15 the old Control-click → Open shortcut no
# longer works — so it keeps the "Open Anyway" walkthrough. Shipping the text
# inside the DMG means the recipient reads it at the moment they hit the problem.
if [[ "${NOTARIZE}" == "1" ]]; then
cat > "${STAGING}/LEGGIMI.txt" <<'TXT'
Claude Live — installazione
===========================

1. Trascina «Claude Live» nella cartella Applicazioni (l'alias qui accanto).

2. Apri Applicazioni e fai doppio clic su Claude Live. Si apre e basta:
   l'app è firmata e registrata presso Apple.

3. Al primo avvio parte una procedura guidata che controlla i requisiti e
   chiede i permessi necessari. Segui i passaggi.

   IMPORTANTE: quando macOS chiede l'accesso al Keychain, scegli
   «Consenti sempre» e non «Consenti». Con «Consenti» la richiesta
   ricomparirà ogni pochi minuti. Con «Consenti sempre» non la rivedrai
   più, nemmeno dopo gli aggiornamenti.

4. Claude Live vive nella barra dei menu: cerca l'icona ✦ con la percentuale.
   Non ha icona nel Dock.

Requisiti
---------
  • macOS 14 o successivo
  • Claude Code installato e con login effettuato (comando `claude`)
  • Visual Studio Code (opzionale: serve solo per la lista progetti)

Gli aggiornamenti successivi sono automatici: l'app li scarica e li propone
da sola.
TXT
else
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
fi

echo "==> Creo ${DMG_PATH}"
hdiutil create \
  -volname "${DMG_NAME}" \
  -srcfolder "${STAGING}" \
  -ov -format UDZO \
  "${DMG_PATH}" >/dev/null

rm -rf "${STAGING}"

# The DMG is notarised too, and separately from the app: the ticket stapled into
# the app does not cover the container the user actually downloads, and it is the
# download that Gatekeeper checks first.
if [[ "${NOTARIZE}" == "1" ]]; then
  # The DMG is signed *before* being notarised, and the order is not arbitrary:
  # notarisation only attaches a ticket, it does not create a signature, so an
  # unsigned disk image ends up with a valid ticket and still no primary
  # signature for Gatekeeper to assess. Signing after stapling would instead
  # rewrite the image and throw the ticket away.
  echo "==> Firmo il DMG"
  codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG_PATH}"

  echo "==> Notarizzo il DMG"
  submit_and_wait "${DMG_PATH}"
  xcrun stapler staple "${DMG_PATH}"

  # The verdict that matters: the same evaluation Gatekeeper performs on the
  # recipient's machine, so a pass here means it opens there.
  #
  # `-t open --context context:primary-signature` is the assessment type for a
  # disk image. Do not use `-t install`: that one is for installer packages, and
  # on a DMG it reports the misleading "rejected / no usable signature" even when
  # the image is signed, notarised and stapled correctly.
  echo "==> Verifica Gatekeeper (DMG)"
  spctl -a -vvv -t open --context context:primary-signature "${DMG_PATH}" 2>&1 | sed 's/^/    /'

  # And the app itself, as Gatekeeper sees it once dragged out of the image.
  # Expect "source=Notarized Developer ID".
  echo "==> Verifica Gatekeeper (app)"
  spctl -a -vvv "build/${APP_NAME}.app" 2>&1 | sed 's/^/    /'
fi

SIZE="$(du -h "${DMG_PATH}" | cut -f1 | tr -d ' ')"
echo
echo "Fatto: ${PWD}/${DMG_PATH} (${SIZE})"
