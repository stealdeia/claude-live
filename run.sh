#!/bin/bash
# Rebuild, replace any running copy, relaunch.
#
# Usage: ./run.sh [debug|release] [--install]
# With --install the app is launched from /Applications instead of build/.
set -euo pipefail

cd "$(dirname "$0")"

./build.sh "$@"

APP="build/Claude Live.app"
for arg in "$@"; do
  [[ "$arg" == "--install" ]] && APP="/Applications/Claude Live.app"
done

if pgrep -x ClaudeLive >/dev/null; then
  echo "==> Chiudo l'istanza in esecuzione"
  pkill -x ClaudeLive || true
  # Give the status item time to disappear before the new one appears.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x ClaudeLive >/dev/null || break
    /bin/sleep 0.2
  done
fi

echo "==> Avvio"
open "${APP}"
echo "Claude Live è nella barra dei menu (cerca l'icona ✦ con la percentuale)."
