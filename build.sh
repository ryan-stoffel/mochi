#!/bin/zsh
# Build Mochi.app.   ./build.sh          → build/Mochi.app (universal: Apple Silicon + Intel)
#                    ./build.sh install  → also copy to ~/Applications and (re)launch it
#                    ./build.sh release  → also zip it to build/Mochi.zip for a GitHub release
set -euo pipefail
cd "${0:A:h}"

APP=build/Mochi.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O -target $arch-apple-macos13.0 Sources/*.swift \
    -o build/Mochi-$arch -framework AppKit -framework WebKit -framework ServiceManagement -framework Network -framework JavaScriptCore
done
lipo -create build/Mochi-arm64 build/Mochi-x86_64 -output "$APP/Contents/MacOS/Mochi"
rm build/Mochi-arm64 build/Mochi-x86_64
cp Info.plist "$APP/Contents/"
rsync -a --exclude preview.html web/ "$APP/Contents/Resources/web/"
[[ -f assets/AppIcon.icns ]] && cp assets/AppIcon.icns "$APP/Contents/Resources/"
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
