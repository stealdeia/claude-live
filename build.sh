#!/bin/bash
# Builds Sources/ into a real .app bundle.
#
# SwiftPM alone can't produce an app bundle, and LSUIElement / notifications /
# the keychain ACL / Sparkle all need one — so we compile the executable and
# assemble the bundle by hand.
#
# Usage:
#   ./build.sh [debug|release] [--install]
#
#   --install      copy the result to /Applications
#
# Settings come from VERSION and release.conf. SIGN_IDENTITY from the environment
# overrides the one in release.conf.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install) INSTALL=1 ;;
    *) echo "Argomento non riconosciuto: $arg" >&2; exit 1 ;;
  esac
done

# Captured before sourcing, because release.conf would otherwise overwrite it.
SIGN_IDENTITY_FROM_ENV="${SIGN_IDENTITY:-}"
# shellcheck source=release.conf
source ./release.conf
[[ -n "${SIGN_IDENTITY_FROM_ENV}" ]] && SIGN_IDENTITY="${SIGN_IDENTITY_FROM_ENV}"

VERSION="$(tr -d ' \n\r' < VERSION)"

APP_NAME="Claude Live"
BUNDLE="build/${APP_NAME}.app"

echo "==> Claude Live ${VERSION} (${CONFIG})"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)"
BINARY="${BIN_PATH}/ClaudeLive"
if [[ ! -x "${BINARY}" ]]; then
  echo "Binario non trovato: ${BINARY}" >&2
  exit 1
fi

echo "==> Assemblo ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources" "${BUNDLE}/Contents/Frameworks"

cp "${BINARY}" "${BUNDLE}/Contents/MacOS/ClaudeLive"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

# Info.plist is a template: version and update-feed settings are injected here so
# they are declared once, in VERSION and release.conf.
sed -e "s|__VERSION__|${VERSION}|g" \
    -e "s|__FEED_URL__|${SU_FEED_URL}|g" \
    -e "s|__ED_KEY__|${SU_PUBLIC_ED_KEY}|g" \
    Resources/Info.plist > "${BUNDLE}/Contents/Info.plist"

# The hook scripts ship inside the bundle so the app can install them itself.
for script in claude-hub-status.py install-claude-hooks.py; do
  cp "Resources/${script}" "${BUNDLE}/Contents/Resources/${script}"
  chmod +x "${BUNDLE}/Contents/Resources/${script}"
done

[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"

# Sparkle ships as an XCFramework; SwiftPM links it but does not embed it. The
# executable carries an @executable_path/../Frameworks rpath (see Package.swift),
# so copying it here is what makes it loadable at runtime.
SPARKLE_FRAMEWORK="$(find .build/artifacts -type d -name 'Sparkle.framework' -path '*macos*' | head -1)"
if [[ -z "${SPARKLE_FRAMEWORK}" ]]; then
  echo "Sparkle.framework non trovato: esegui 'swift package resolve'" >&2
  exit 1
fi
echo "==> Incorporo Sparkle"
rm -rf "${BUNDLE}/Contents/Frameworks/Sparkle.framework"
cp -R "${SPARKLE_FRAMEWORK}" "${BUNDLE}/Contents/Frameworks/Sparkle.framework"

if [[ -n "${SIGN_IDENTITY}" ]]; then
  echo "==> Firma con «${SIGN_IDENTITY}»"

  # Deliberately WITHOUT --options runtime.
  #
  # The hardened runtime enables library validation, which requires every loaded
  # library to carry the same Team ID as the main binary. A self-signed
  # certificate has no Team ID at all, so Sparkle.framework could never be
  # loaded: dyld refused it with "mapping process and mapped file (non-platform)
  # have different Team IDs" and the app died at launch.
  #
  # The hardened runtime is only a requirement for Apple notarisation, which we
  # are not doing. If a real Developer ID is adopted later, add back
  # `--options runtime`: both app and framework then share a Team ID and library
  # validation passes on its own.
  local_sign() { codesign --force --timestamp=none --sign "${SIGN_IDENTITY}" "$1"; }

  # Inside-out order matters: nested code must be signed before its container, or
  # the outer signature seals an unsigned framework and macOS rejects it.
  # Sparkle's XPC services and its updater app are nested code of their own.
  find "${BUNDLE}/Contents/Frameworks/Sparkle.framework" \
       \( -name '*.xpc' -o -name 'Updater.app' -o -name 'Autoupdate' \) -print | while read -r nested; do
    codesign --force --timestamp=none --sign "${SIGN_IDENTITY}" "${nested}"
  done
  local_sign "${BUNDLE}/Contents/Frameworks/Sparkle.framework"
  local_sign "${BUNDLE}"

  echo "==> Verifica firma"
  codesign --verify --deep --strict "${BUNDLE}" && echo "    firma valida"
else
  echo "==> Firma ad-hoc (nessuna SIGN_IDENTITY)"
  codesign --force --deep --sign - "${BUNDLE}" >/dev/null 2>&1 || true
fi

TARGET="${PWD}/${BUNDLE}"

if [[ "${INSTALL}" == "1" ]]; then
  DEST="/Applications/${APP_NAME}.app"
  echo "==> Installo in ${DEST}"
  rm -rf "${DEST}"
  cp -R "${BUNDLE}" "${DEST}"
  TARGET="${DEST}"
fi

echo
echo "Fatto: ${TARGET}"
echo "Avvio:  open \"${TARGET}\""
