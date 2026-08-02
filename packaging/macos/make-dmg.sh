#!/bin/sh
# Builds the macOS disk image (K-252): a release build, then a compressed DMG
# holding the .app and an Applications shortcut. macOS only (hdiutil).
#
#   packaging/macos/make-dmg.sh
#
# Unsigned and un-notarised for now — that work is the macOS pass (K-033,
# docs/TODO.md). Gatekeeper will warn accordingly.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
version="$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$root/flutter_ui/pubspec.yaml")"

(cd "$root/flutter_ui" && flutter build macos --release)

app="$root/flutter_ui/build/macos/Build/Products/Release/lumit_flutter.app"
[ -d "$app" ] || { echo "No app at $app" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/Lumit.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$here/dist"
out="$here/dist/lumit-$version-macos.dmg"
rm -f "$out"
hdiutil create -volname "Lumit" -srcfolder "$stage" -ov -format UDZO "$out"
echo "Wrote $out"
