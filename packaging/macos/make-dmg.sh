#!/bin/sh
# Builds the macOS disk image (K-252): a release build, the Homebrew FFmpeg
# dylibs bundled INTO the .app (so the image runs on machines without
# Homebrew), an ad-hoc re-sign, then a compressed DMG with an Applications
# shortcut. macOS only.
#
#   packaging/macos/make-dmg.sh [version]
#
# Needs: flutter, rust, and `brew install ffmpeg@7 dylibbundler create-dmg`
# (create-dmg optional - without it the image has no drag-to-Applications
# window dressing).
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

# Flutter forces a universal build on the xcodebuild command line
# (ARCHS="arm64 x86_64", ONLY_ACTIVE_ARCH=NO), which out-ranks every project
# and Podfile setting — cargokit then cross-compiles the bridge for the
# architecture Homebrew has no FFmpeg for, and rusty_ffmpeg's pkg-config
# probe dies. FLUTTER_XCODE_* variables are Flutter's own escape hatch:
# they are appended as build settings AFTER Flutter's, and the last ARCHS
# wins. One architecture per machine until K-033 takes on universal builds.
FLUTTER_XCODE_ARCHS="$arch"
export FLUTTER_XCODE_ARCHS

(cd "$root/flutter_ui" && flutter build macos --release)

app="$root/flutter_ui/build/macos/Build/Products/Release/lumit_flutter.app"
[ -d "$app" ] || { echo "No app at $app" >&2; exit 1; }

# Every Mach-O in the app that still links a Homebrew path gets handed to
# dylibbundler. The bridge dylib is the expected hit; the loop rather than a
# hardcoded path so a renamed framework cannot silently ship keg links.
fixups=""
fixlist=""
for bin in $(find "$app/Contents" -type f ! -name "*.png" ! -name "*.json" ! -name "*.plist"); do
    if otool -L "$bin" 2>/dev/null | tail -n +2 | grep -Eq '/opt/homebrew/|/usr/local/(opt|Cellar)/'; then
        fixups="$fixups -x $bin"
        fixlist="$fixlist $bin"
    fi
done
if [ -n "$fixups" ]; then
    # -cd creates the destination if missing; -of overwrites dylibs a
    # previous run already copied, so reruns are idempotent. NEVER -od here —
    # that flag OVERWRITES the directory, i.e. deletes Contents/Frameworks
    # and every framework already embedded in it.
    # shellcheck disable=SC2086 # word-splitting the -x list is the point
    dylibbundler -cd -of -b $fixups \
        -d "$app/Contents/Frameworks/" \
        -p "@executable_path/../Frameworks/" \
        -s "$ffprefix/lib"
else
    echo "warning: nothing in the app links Homebrew - is the media feature on?" >&2
fi

# Homebrew's libSDL2 is the sdl2-compat shim: its module initializer dlopens
# SDL3, and when that fails the process aborts before main() ever runs — and
# a dlopen is invisible to otool, so no bundler can ship its target. Nothing
# in Lumit calls SDL; it rides in through libavdevice's output devices, and
# libavdevice cannot leave (the bridge imports its version symbols). So the
# bundled libSDL2 is replaced with a generated stub: a dylib exporting no-op
# versions of exactly the symbols the other bundled binaries import from it.
# No initializer, no SDL3, no abort.
sdl="$(find "$app/Contents/Frameworks" -maxdepth 1 -name 'libSDL2*.dylib' | head -1)"
if [ -n "$sdl" ]; then
    sdlbase="$(basename "$sdl")"
    stub="$(mktemp -d)"
    # nm -m names the source library of every undefined symbol under the
    # two-level namespace, so this is the exact import list to satisfy.
    find "$app/Contents/Frameworks" -maxdepth 1 -type f ! -name "$sdlbase" \
        -exec nm -m {} + 2>/dev/null \
        | awk '/from libSDL2/{print $(NF-2)}' | sort -u > "$stub/syms"
    if [ -s "$stub/syms" ]; then
        while read -r s; do
            printf 'void %s(void) {}\n' "${s#_}"
        done < "$stub/syms" > "$stub/stub.c"
        # dyld checks the compatibility version the importers were linked
        # against; carry the real library's numbers over to the stub.
        line="$(otool -L "$app/Contents/Frameworks/"libavdevice.*.dylib 2>/dev/null | grep "$sdlbase" | head -1)"
        compat="$(printf '%s' "$line" | sed -n 's/.*compatibility version \([0-9.]*\).*/\1/p')"
        curr="$(printf '%s' "$line" | sed -n 's/.*current version \([0-9.]*\).*/\1/p')"
        cc -dynamiclib -o "$sdl" "$stub/stub.c" \
            -install_name "@executable_path/../Frameworks/$sdlbase" \
            -compatibility_version "${compat:-1.0}" \
            -current_version "${curr:-1.0}"
        echo "Stubbed $sdlbase ($(wc -l < "$stub/syms" | tr -d ' ') symbols)"
    else
        # nothing imports from it: it has no reason to ship at all
        rm -f "$sdl"
    fi
    rm -rf "$stub"
fi

# dyld (macOS 15+) refuses to launch a binary carrying duplicate LC_RPATH
# entries, and dylibbundler adds its -p path as an rpath on each binary it
# fixes — on top of Xcode's default '@executable_path/../Frameworks'. Every
# binary in the app gets the sweep (a rerun of this script must clean marks
# the previous run left, so the set cannot be limited to freshly-fixed
# files): drop the slashed twin outright, collapse exact duplicates to one.
for bin in "$app/Contents/MacOS/lumit_flutter" $(find "$app/Contents/Frameworks" -type f); do
    while install_name_tool -delete_rpath "@executable_path/../Frameworks/" "$bin" 2>/dev/null; do :; done
    for rp in $(otool -l "$bin" 2>/dev/null | awk '$1=="path"{print $2}' | sort | uniq -d); do
        while install_name_tool -delete_rpath "$rp" "$bin" 2>/dev/null; do :; done
        install_name_tool -add_rpath "$rp" "$bin"
    done
done

# Re-sign everything ad hoc; the install-name rewrites invalidated the
# existing signatures.
codesign --force --deep --sign - "$app"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/Lumit.app"

mkdir -p "$here/dist"
out="$here/dist/lumit-$version-macos-$arch.dmg"
rm -f "$out"
if command -v create-dmg >/dev/null; then
    # The proper drag-into-Applications window (brew install create-dmg).
    create-dmg --volname "Lumit" \
        --window-size 540 380 --icon-size 128 \
        --icon "Lumit.app" 140 185 --app-drop-link 400 185 \
        --hide-extension "Lumit.app" \
        "$out" "$stage"
else
    # Plain image: app + Applications shortcut, no window dressing.
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "Lumit" -srcfolder "$stage" -ov -format UDZO "$out"
fi
echo "Wrote $out"
