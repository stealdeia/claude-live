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
  # A real Developer ID gets the hardened runtime and a secure timestamp; both
  # are hard requirements for Apple notarisation (see package.sh). Anything else
  # — a self-signed identity — must not get them, and this is not a style
  # preference:
  #
  # the hardened runtime enables library validation, which requires every loaded
  # library to carry the same Team ID as the main binary. A self-signed
  # certificate has no Team ID at all, so Sparkle.framework could never be
  # loaded: dyld refused it with "mapping process and mapped file (non-platform)
  # have different Team IDs" and the app died at launch. With a Developer ID the
  # app and the framework share a Team ID, so library validation passes on its
  # own and no entitlement is needed to relax it.
  #
  # Note there is deliberately no entitlements file. Non-sandboxed, the app needs
  # none: reading another app's Keychain item is governed by the item's ACL, and
  # spawning `code`/`python3` is not something the hardened runtime restricts.
  # Declaring entitlements "just in case" would only weaken the runtime.
  if [[ "${SIGN_IDENTITY}" == "Developer ID Application:"* ]]; then
    SIGN_OPTS=(--options runtime --timestamp)
    echo "==> Firma Developer ID con «${SIGN_IDENTITY}» (hardened runtime)"
  else
    SIGN_OPTS=(--timestamp=none)
    echo "==> Firma con «${SIGN_IDENTITY}» (senza hardened runtime)"
  fi

  # Inside-out order matters: nested code must be signed before its container, or
  # the outer signature seals an unsigned framework and macOS rejects it.
  # Sparkle's XPC services and its updater app are nested code of their own, and
  # they ship with entitlements of their own — --preserve-metadata keeps those,
  # since re-signing without them breaks the updater.
  find "${BUNDLE}/Contents/Frameworks/Sparkle.framework" \
       \( -name '*.xpc' -o -name 'Updater.app' -o -name 'Autoupdate' \) -print | while read -r nested; do
    codesign --force "${SIGN_OPTS[@]}" --preserve-metadata=entitlements \
             --sign "${SIGN_IDENTITY}" "${nested}"
  done
  codesign --force "${SIGN_OPTS[@]}" --sign "${SIGN_IDENTITY}" \
           "${BUNDLE}/Contents/Frameworks/Sparkle.framework"
  codesign --force "${SIGN_OPTS[@]}" --sign "${SIGN_IDENTITY}" "${BUNDLE}"

  # --strict without --deep: --deep is what Apple tells you not to use for
  # verification of a shipped bundle, and the nested code was signed explicitly
  # above anyway.
  echo "==> Verifica firma"
  codesign --verify --strict --verbose=2 "${BUNDLE}" 2>&1 | sed 's/^/    /'
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
