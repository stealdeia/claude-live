#!/bin/bash
# Publishes a release: DMG → GitHub Releases → Sparkle appcast.
#
# Everything already-installed copies need in order to update themselves is the
# appcast, so that is the last thing written: if an earlier step fails, no client
# is ever pointed at a download that does not exist.
#
# Usage:
#   ./release.sh                 release the version in VERSION
#   ./release.sh --dry-run       build and sign, but publish nothing
#
# Requirements: gh (authenticated), the Sparkle private key in the login keychain,
# and RELEASE_NOTES.md describing this version.
set -euo pipefail

cd "$(dirname "$0")"
source ./release.conf
VERSION="$(tr -d ' \n\r' < VERSION)"
TAG="v${VERSION}"
DMG="dist/Claude Live ${VERSION}.dmg"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

fail() { echo "✗ $*" >&2; exit 1; }

DRY_RUN_LABEL=""
[[ "${DRY_RUN}" == "1" ]] && DRY_RUN_LABEL=" (dry run)"
echo "==> Rilascio Claude Live ${VERSION}${DRY_RUN_LABEL}"

# --- Pre-flight -------------------------------------------------------------
[[ -s RELEASE_NOTES.md ]] || fail "RELEASE_NOTES.md è vuoto: descrivi cosa cambia in questa versione."
command -v gh >/dev/null || fail "gh non installato."
gh auth status >/dev/null 2>&1 || fail "gh non autenticato: esegui 'gh auth login'."

SIGN_UPDATE="$(find .build/artifacts -type f -name sign_update | head -1)"
[[ -n "${SIGN_UPDATE}" ]] || fail "sign_update non trovato: esegui 'swift package resolve'."

# Che la chiave privata di Sparkle ci sia va verificato **qui**, non quando
# serve. La firma EdDSA è l'ultimo passo prima della pubblicazione, e senza
# questo controllo la sua assenza si scopre dopo build e notarizzazione: venti
# minuti di attesa su Apple per poi fallire. È già capitato una volta, su una
# macchina nuova dove la chiave non era stata reimportata.
GENERATE_KEYS="$(find .build/artifacts -type f -name generate_keys | head -1)"
if [[ -n "${GENERATE_KEYS}" ]]; then
  FOUND_ED_KEY="$("${GENERATE_KEYS}" -p 2>/dev/null | tail -1 | tr -d ' \n\r')"
  [[ -n "${FOUND_ED_KEY}" ]] || fail "Chiave privata Sparkle assente dal portachiavi: gli aggiornamenti non sarebbero firmabili. Reimportala con 'generate_keys -f <file>' — il file deve contenere solo il seme base64 su una riga, senza la riga 'Pub' (vedi README)."
  # E che sia *quella giusta*: una chiave diversa produce firme che le copie già
  # installate rifiutano, perché verificano contro la pubblica nel loro Info.plist.
  [[ "${FOUND_ED_KEY}" == "${SU_PUBLIC_ED_KEY}" ]] || \
    fail "La chiave Sparkle nel portachiavi non è quella distribuita.
    nel portachiavi: ${FOUND_ED_KEY}
    attesa:          ${SU_PUBLIC_ED_KEY}
  Firmare con questa renderebbe l'aggiornamento ininstallabile per tutti."
fi

if [[ "${DRY_RUN}" == "0" ]]; then
  # Il codice sorgente deve essere committato *prima* di pubblicare il binario, e
  # questo va verificato prima di interrogare GitHub: sono controlli locali,
  # istantanei, e in un test il controllo della release mascherava questo.
  #
  # Esiste per un errore realmente accaduto quattro volte di fila: le versioni
  # 0.3.0 → 0.4.0 sono finite su GitHub con i sorgenti solo sul disco locale. Lo
  # script non poteva accorgersene perché aggiorna l'appcast da un clone temporaneo
  # e non guarda mai il repo di lavoro: l'app che gli utenti scaricano risultava
  # aggiornata mentre il codice che la produce non era tracciato da nessuna parte.
  if git rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "$(git status --porcelain)" ]]; then
      git status --short >&2
      fail "Ci sono modifiche non committate. Committale prima di pubblicare: il binario finirebbe online con sorgenti che esistono solo qui."
    fi
    # Committato ma non spinto è lo stesso problema con un passaggio in meno.
    if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
      if [[ -n "$(git log '@{upstream}..HEAD' --oneline)" ]]; then
        git log '@{upstream}..HEAD' --oneline >&2
        fail "Ci sono commit non spinti. Esegui 'git push' prima di pubblicare."
      fi
    fi
  fi

  if gh release view "${TAG}" --repo "${GH_OWNER}/${GH_RELEASES_REPO}" >/dev/null 2>&1; then
    fail "La release ${TAG} esiste già. Aumenta VERSION oppure eliminala prima."
  fi
fi

# --- Build ------------------------------------------------------------------
./package.sh
[[ -f "${DMG}" ]] || fail "DMG non prodotto: ${DMG}"

# --- Sign the update --------------------------------------------------------
# This EdDSA signature — not Apple's notarisation — is what makes an update
# trustworthy: the app refuses any download that does not verify against the
# public key baked into its Info.plist.
echo "==> Firmo l'aggiornamento (EdDSA)"
SIGN_OUTPUT="$("${SIGN_UPDATE}" "${DMG}")"
ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "${SIGN_OUTPUT}")"
LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<< "${SIGN_OUTPUT}")"
[[ -n "${ED_SIGNATURE}" && -n "${LENGTH}" ]] || fail "Firma non riuscita: ${SIGN_OUTPUT}"
echo "    firma ok (${LENGTH} byte)"

# GitHub replaces spaces with dots in asset names; the appcast must point at the
# name GitHub actually serves, not at the local file name.
ASSET_NAME="$(basename "${DMG}" | tr ' ' '.')"
DOWNLOAD_URL="https://github.com/${GH_OWNER}/${GH_RELEASES_REPO}/releases/download/${TAG}/${ASSET_NAME}"

if [[ "${DRY_RUN}" == "1" ]]; then
  echo
  echo "Dry run: nulla è stato pubblicato."
  echo "  DMG:       ${DMG}"
  echo "  URL che sarebbe usata: ${DOWNLOAD_URL}"
  echo "  firma:     ${ED_SIGNATURE}"
  exit 0
fi

# --- Publish the DMG --------------------------------------------------------
echo "==> Creo la release ${TAG} su ${GH_OWNER}/${GH_RELEASES_REPO}"
UPLOAD="dist/${ASSET_NAME}"
cp "${DMG}" "${UPLOAD}"
gh release create "${TAG}" "${UPLOAD}" \
  --repo "${GH_OWNER}/${GH_RELEASES_REPO}" \
  --title "Claude Live ${VERSION}" \
  --notes-file RELEASE_NOTES.md
rm -f "${UPLOAD}"

# --- Publish the appcast ----------------------------------------------------
# Done last and from a fresh clone, so a stale local copy can never drop items
# that another machine published.
echo "==> Aggiorno l'appcast"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
gh repo clone "${GH_OWNER}/${GH_RELEASES_REPO}" "${WORK}/repo" -- --depth 1 >/dev/null 2>&1

tools/update-appcast.py \
  --appcast "${WORK}/repo/appcast.xml" \
  --version "${VERSION}" \
  --url "${DOWNLOAD_URL}" \
  --signature "${ED_SIGNATURE}" \
  --length "${LENGTH}" \
  --notes RELEASE_NOTES.md

git -C "${WORK}/repo" add appcast.xml
# Identità di comodo per il commit dell'appcast, che finisce nella cronologia
# pubblica del repo delle release. `.invalid` è il TLD che l'IANA riserva proprio
# a questo: un indirizzo che per costruzione non esiste e non recapita nulla.
git -C "${WORK}/repo" -c user.name="Purple Heads release" \
    -c user.email="noreply@purpleheads.invalid" \
    commit -m "Claude Live ${VERSION}" >/dev/null
git -C "${WORK}/repo" push >/dev/null

echo
echo "✓ Claude Live ${VERSION} pubblicata."
echo "  Download:  ${DOWNLOAD_URL}"
echo "  Appcast:   ${SU_FEED_URL}"
echo
echo "Le copie già installate lo vedranno al prossimo controllo (entro 24h),"
echo "o subito con «Cerca aggiornamenti…» dal menu."
