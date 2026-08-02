#!/bin/sh
# Builds the macOS disk image (K-252): a release build, the Homebrew FFmpeg
# dylibs bundled INTO the .app (so the image runs on machines without
# Homebrew), an ad-hoc re-sign, then a compressed DMG with an Applications
# shortcut. macOS only.
#
#   packaging/macos/make-dmg.sh [version]
#
# Needs: flutter, rust, and `brew install ffmpeg@7 dylibbundler`.
#
# The bundling is the same move the Windows installer makes with the FFmpeg
# DLLs: the bridge links the shared FFmpeg, so the libraries must travel with
# the app. dylibbundler copies every Homebrew-linked dylib (transitive deps
# included) into Contents/Frameworks and rewrites the install names; the
# ad-hoc codesign afterwards is mandatory - macOS kills a process whose
# binaries changed after signing.
#
# Ad-hoc means unsigned in Gatekeeper's eyes: a downloaded copy still warns
# until the notarisation work in the macOS pass (K-033, docs/TODO.md).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
version="${1:-$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$root/flutter_ui/pubspec.yaml")}"
arch="$(uname -m)"

command -v dylibbundler >/dev/null || {
    echo "dylibbundler not found - brew install dylibbundler" >&2
    exit 1
}
ffprefix="$(brew --prefix ffmpeg@7 2>/dev/null)" || {
    echo "ffmpeg@7 not found - brew install ffmpeg@7" >&2
    exit 1
}

(cd "$root/flutter_ui" && flutter build macos --release)

app="$root/flutter_ui/build/macos/Build/Products/Release/lumit_flutter.app"
[ -d "$app" ] || { echo "No app at $app" >&2; exit 1; }

# Every Mach-O in the app that still links a Homebrew path gets handed to
# dylibbundler. The bridge dylib is the expected hit; the loop rather than a
# hardcoded path so a renamed framework cannot silently ship keg links.
fixups=""
for bin in $(find "$app/Contents" -type f ! -name "*.png" ! -name "*.json" ! -name "*.plist"); do
    if otool -L "$bin" 2>/dev/null | tail -n +2 | grep -Eq '/opt/homebrew/|/usr/local/(opt|Cellar)/'; then
        fixups="$fixups -x $bin"
    fi
done
if [ -n "$fixups" ]; then
    # shellcheck disable=SC2086 # word-splitting the -x list is the point
    dylibbundler -od -b $fixups \
        -d "$app/Contents/Frameworks/" \
        -p "@executable_path/../Frameworks/" \
        -s "$ffprefix/lib"
else
    echo "warning: nothing in the app links Homebrew - is the media feature on?" >&2
fi

# Re-sign everything ad hoc; the install-name rewrites invalidated the
# existing signatures.
codesign --force --deep --sign - "$app"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/Lumit.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$here/dist"
out="$here/dist/lumit-$version-macos-$arch.dmg"
rm -f "$out"
hdiutil create -volname "Lumit" -srcfolder "$stage" -ov -format UDZO "$out"
echo "Wrote $out"
