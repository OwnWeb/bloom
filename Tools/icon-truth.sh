#!/bin/zsh
# Renders Bloom's icon the way the system renders it, into a PNG, so a drawing of the icon can be
# held against the real thing.
#
# This compiles `Resources/Bloom.icon` with actool as `Tools/build.sh` does, then asks the
# system for the icon from a throwaway bundle. Nothing is installed or launched.
#
#     ./Tools/icon-truth.sh [output.png] [size]
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-/tmp/bloom-icon-truth.png}"
size="${2:-512}"
work="$(mktemp -d "${TMPDIR:-/tmp}/bloom-icon-truth.XXXXXX")"
app="$work/Bloom Icon Truth.app"
mkdir -p "$app/Contents/Resources" "$app/Contents/MacOS"
# An executable, because a bundle without one is drawn with the system's "cannot be opened" badge
# across it, which is a picture of the badge rather than of the icon.
cp /bin/echo "$app/Contents/MacOS/BloomIconTruth"

deployment="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
xcrun actool "$PWD/Resources/Bloom.icon" "$PWD/Resources/Assets.xcassets" \
  --compile "$app/Contents/Resources" \
  --app-icon Bloom \
  --output-partial-info-plist "$work/Bloom.icon.plist" \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target "$deployment" \
  --errors --warnings >/dev/null

[[ -f "$app/Contents/Resources/Assets.car" ]] || { echo "actool produced no Assets.car" >&2; exit 1 }

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>be.spatie.bloom.icon-truth</string>
  <key>CFBundleName</key><string>Bloom Icon Truth</string>
  <key>CFBundleExecutable</key><string>BloomIconTruth</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconName</key><string>Bloom</string>
  <key>LSMinimumSystemVersion</key><string>$deployment</string>
</dict></plist>
PLIST

# NSWorkspace renders the compiled catalogue the way the Dock does, which is the point: the answer
# has the system's own glass, shadow and shape passes on it rather than ours.
cat > "$work/render.swift" <<'SWIFT'
import AppKit
let arguments = CommandLine.arguments
let icon = NSWorkspace.shared.icon(forFile: arguments[1])
let size = Int(arguments[3]) ?? 512
icon.size = NSSize(width: size, height: size)
guard let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: NSAffineTransform()]),
      let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}
try data.write(to: URL(filePath: arguments[2]))
SWIFT

xcrun swift "$work/render.swift" "$app" "$out" "$size"
echo "$out"
