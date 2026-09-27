#!/bin/zsh
# Shared bundle assembly for headless UI probes. Source this after changing to the repo root.

bloom_prepare_probe_app() {
  local app="$1" bundle_id="$2" name="$3"
  local bin_dir framework
  bin_dir="$(swift build --show-bin-path)"
  framework="$(find .build/artifacts -path '*Sparkle.xcframework/macos*/Sparkle.framework' -type d | head -1)"
  [[ -n "$framework" ]] || { print -ru2 -- "Sparkle.framework is missing. Build Bloom first."; return 1; }

  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks"
  cp "$bin_dir/Bloom" "$app/Contents/MacOS/Bloom"
  cp Resources/Info.plist "$app/Contents/Info.plist"
  ditto Resources "$app/Contents/Resources"
  ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$app/Contents/Info.plist"
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/Bloom"
  codesign --force --deep --sign - "$app" >/dev/null 2>&1
}
