#!/bin/sh
# Builds DEDO.app from the SwiftPM package. Drag it to /Applications.
set -e
swift build -c release
rm -rf DEDO.app && mkdir -p DEDO.app/Contents/MacOS
cp .build/release/DEDOApp DEDO.app/Contents/MacOS/DEDO
cp -R .build/release/DEDO_DEDOApp.bundle DEDO.app/ # where SwiftPM's Bundle.module looks
# App icon: icon.png (1024px, already on the macOS icon grid) -> AppIcon.icns
mkdir -p DEDO.app/Contents/Resources .build/AppIcon.iconset
for n in 16 32 128 256 512; do
  sips -z $n $n icon.png --out .build/AppIcon.iconset/icon_${n}x${n}.png >/dev/null
  sips -z $((n * 2)) $((n * 2)) icon.png --out .build/AppIcon.iconset/icon_${n}x${n}@2x.png >/dev/null
done
iconutil -c icns .build/AppIcon.iconset -o DEDO.app/Contents/Resources/AppIcon.icns
cat > DEDO.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>DEDO</string>
  <key>CFBundleIdentifier</key><string>local.dedo</string>
  <key>CFBundleName</key><string>DEDO</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
# The command line tool, linked so rebuilding updates it.
mkdir -p ~/.local/bin && ln -sf "$PWD/.build/release/dedo" ~/.local/bin/dedo
echo "Built DEDO.app and linked ~/.local/bin/dedo"
