#!/bin/zsh
# Build Mochi.app.   ./build.sh          → build/Mochi.app (universal: Apple Silicon + Intel)
#                    ./build.sh install  → also copy to ~/Applications and (re)launch it
#                    ./build.sh release  → also zip it to build/Mochi.zip for a GitHub release
#                    ./build.sh fast     → this Mac's architecture only, for a quicker loop
set -euo pipefail
cd "${0:A:h}"

APP=build/Mochi.app
if [[ "${1:-}" == "fast" ]]; then
  swift build -c release
  BIN=$(swift build -c release --show-bin-path)
else
  swift build -c release --arch arm64 --arch x86_64
  BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
fi

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Mochi" "$APP/Contents/MacOS/Mochi"
# ptydrive sits beside the app's binary; UsageFetcher looks for it there.
cp "$BIN/ptydrive" "$APP/Contents/MacOS/ptydrive"
cp Info.plist "$APP/Contents/"
rsync -a --exclude preview.html web/ "$APP/Contents/Resources/web/"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Sign the nested helper first: Gatekeeper rejects a bundle whose inner executable isn't signed itself.
codesign --force --sign - "$APP/Contents/MacOS/ptydrive"
codesign --force --deep --sign - "$APP" >/dev/null
echo "built $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x Mochi 2>/dev/null || true
  sleep 0.5
  rm -rf ~/Applications/Mochi.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Mochi.app
  echo "installed ~/Applications/Mochi.app"
fi

if [[ "${1:-}" == "release" ]]; then
  ditto -c -k --norsrc --noextattr --keepParent "$APP" build/Mochi.zip
  echo "zipped build/Mochi.zip"
fi
