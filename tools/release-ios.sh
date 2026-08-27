#!/bin/bash
# Pubblica l'app iPhone su TestFlight: archivio → IPA → caricamento → scadenza
# delle build precedenti.
#
# Il gemello di ./release.sh per il Mac, e con la stessa idea: i passi che si
# possono sbagliare in silenzio vengono controllati prima, non dopo venti minuti.
#
# Il numero di build viene alzato da sé. App Store Connect rifiuta due volte lo
# stesso numero, e ricordarselo a mano è esattamente il genere di cosa che non si
# ricorda: l'errore arriva a caricamento finito, senza spiegare che bastava un +1.
#
# Uso:
#   tools/release-ios.sh                pubblica
#   tools/release-ios.sh --dry-run      archivia e verifica, senza caricare
set -euo pipefail

cd "$(dirname "$0")/.."
source ./release.conf

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

fail() { echo "✗ $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- Pre-flight -------------------------------------------------------------
command -v xcodegen >/dev/null || fail "xcodegen non installato: brew install xcodegen."
[[ -f "${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" ]] || \
  fail "Chiave App Store Connect assente da ~/.appstoreconnect/private_keys/. Apple la fa scaricare una volta sola: cercala fra le copie di riserva."

if [[ "${DRY_RUN}" == "0" ]]; then
  # Stessa ragione di release.sh: il binario che la gente installa non deve
  # esistere senza i sorgenti che l'hanno prodotto.
  if [[ -n "$(git status --porcelain)" ]]; then
    git status --short >&2
    fail "Ci sono modifiche non committate."
  fi
  if git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    [[ -z "$(git log '@{upstream}..HEAD' --oneline)" ]] || fail "Ci sono commit non spinti."
  fi
fi

# --- Numero di build --------------------------------------------------------
# Da quando esiste anche il bersaglio dell'isola dinamica, queste chiavi
# compaiono due volte. `sort -u` non serve a scegliere: serve a *pretendere* che
# le due copie siano d'accordo. App Store Connect rifiuta un archivio in cui
# l'estensione e l'app che la contiene dichiarano versioni diverse, e l'errore
# arriva a caricamento finito senza dire quale delle due sia sbagliata.
CURRENT="$(grep -oE 'CURRENT_PROJECT_VERSION: "[0-9]+"' iOS/project.yml | grep -oE '[0-9]+' | sort -u)"
[[ -n "${CURRENT}" ]] || fail "Non riesco a leggere CURRENT_PROJECT_VERSION da iOS/project.yml."
[[ "$(echo "${CURRENT}" | wc -l | tr -d ' ')" == "1" ]] || \
  fail "app ed estensione dichiarano numeri di build diversi: $(echo ${CURRENT} | tr '\n' ' ')"
NEXT=$((CURRENT + 1))

MARKETING="$(grep -oE 'MARKETING_VERSION: "[^"]+"' iOS/project.yml | sed 's/.*"\(.*\)"/\1/' | sort -u)"
[[ "$(echo "${MARKETING}" | wc -l | tr -d ' ')" == "1" ]] || \
  fail "app ed estensione dichiarano versioni diverse: $(echo ${MARKETING} | tr '\n' ' ')"
echo "==> Claude Live iPhone ${MARKETING} (${NEXT})"

if [[ "${DRY_RUN}" == "0" ]]; then
  sed -i '' "s/CURRENT_PROJECT_VERSION: \"${CURRENT}\"/CURRENT_PROJECT_VERSION: \"${NEXT}\"/" iOS/project.yml
fi

cd iOS
xcodegen generate >/dev/null
echo "==> Archivio"
xcodebuild -project ClaudeLiveMobile.xcodeproj -scheme ClaudeLiveMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "${WORK}/app.xcarchive" -allowProvisioningUpdates archive >"${WORK}/archive.log" 2>&1 \
  || { tail -30 "${WORK}/archive.log" >&2; fail "Archivio fallito."; }

# L'ambiente delle notifiche è la cosa che sbaglia in silenzio: una build
# firmata `development` che arriva da TestFlight non riceve nulla, e APNs
# risponde BadDeviceToken senza spiegare niente a nessuno.
APS="$(codesign -d --entitlements - --xml "${WORK}/app.xcarchive/Products/Applications/ClaudeLiveMobile.app" 2>/dev/null | plutil -p - | grep -A0 'aps-environment' | sed 's/.*=> "\(.*\)"/\1/')"
echo "    aps-environment nell'archivio: ${APS}"

echo "==> IPA firmato per l'App Store"
cat > "${WORK}/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "${WORK}/app.xcarchive" \
  -exportOptionsPlist "${WORK}/export.plist" -exportPath "${WORK}/export" \
  -allowProvisioningUpdates >"${WORK}/export.log" 2>&1 \
  || { tail -30 "${WORK}/export.log" >&2; fail "Esportazione fallita."; }

IPA="${WORK}/export/ClaudeLiveMobile.ipa"
[[ -f "${IPA}" ]] || fail "IPA non prodotto."

cd ..
echo "==> Verifica presso Apple"
xcrun altool --validate-app -f "${IPA}" -t ios \
  --apiKey "${ASC_KEY_ID}" --apiIssuer "${ASC_ISSUER_ID}" 2>&1 | grep -E "VERIFY|ERROR" || true

if [[ "${DRY_RUN}" == "1" ]]; then
  echo ""
  echo "✓ Dry run: archivio e IPA prodotti, niente caricato."
  exit 0
fi

echo "==> Caricamento"
xcrun altool --upload-app -f "${IPA}" -t ios \
  --apiKey "${ASC_KEY_ID}" --apiIssuer "${ASC_ISSUER_ID}" 2>&1 | grep -E "UPLOAD|ERROR" \
  || fail "Caricamento fallito."

echo "==> Attendo che Apple registri la build"
for _ in $(seq 1 40); do
  if node tools/testflight.mjs list 2>/dev/null | grep -q "build ${NEXT} "; then break; fi
  sleep 15
done

# Prima di tutto il resto: una build senza dichiarazione non è installabile da
# nessuno, e nessuno viene avvisato.
echo "==> Dichiarazione sull'esportazione"
node tools/testflight.mjs compliance

echo "==> Faccio scadere le precedenti"
node tools/testflight.mjs expire-old

echo ""
echo "✓ Claude Live iPhone ${MARKETING} (${NEXT}) su TestFlight."
echo "  Ricordati di committare il numero di build alzato in iOS/project.yml."
