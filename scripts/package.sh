#!/bin/bash
set -euo pipefail

if [[ $# != 1 ]]; then
    echo "Usage: $0 OUTPUT_DIRECTORY" >&2
    exit 2
fi
mkdir -p "$1"
output=$(cd "$1" && pwd)
cd "$(dirname "$0")/.."
app="$PWD/.build/Xcode/Build/Products/Release/Aster.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Expected a three-part release version in the built app." >&2
    exit 1
fi
verify_app() {
    local bundle=$1 executable architectures
    codesign --verify --deep --strict --all-architectures "$bundle"
    for executable in "$bundle/Contents/MacOS/Aster" "$bundle"/Contents/PlugIns/*.appex/Contents/MacOS/*; do
        architectures=$(lipo -archs "$executable")
        if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
            echo "$executable is missing a required architecture." >&2
            return 1
        fi
    done
}
verify_app "$app"

scratch=$(mktemp -d "$output/.aster-package.XXXXXXXX")
mounted=false
cleanup() {
    if "$mounted"; then hdiutil detach "$scratch/mount" -quiet || return; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
mkdir "$scratch/stage" "$scratch/mount"
ditto "$app" "$scratch/stage/Aster.app"
ln -s /Applications "$scratch/stage/Applications"

dmg="Aster-$version.dmg"
zip="Aster-$version-macOS.zip"
hdiutil create -quiet -srcfolder "$scratch/stage" -volname Aster -fs HFS+ -format UDZO "$scratch/$dmg"
hdiutil verify -quiet "$scratch/$dmg"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$scratch/mount" "$scratch/$dmg"
mounted=true
test "$(readlink "$scratch/mount/Applications")" = /Applications
verify_app "$scratch/mount/Aster.app"
diff -qr "$app" "$scratch/mount/Aster.app"
hdiutil detach -quiet "$scratch/mount"
mounted=false

ditto -c -k --sequesterRsrc --keepParent "$app" "$scratch/$zip"
unzip -tq "$scratch/$zip"
mkdir "$scratch/unzipped"
ditto -x -k "$scratch/$zip" "$scratch/unzipped"
verify_app "$scratch/unzipped/Aster.app"
diff -qr "$app" "$scratch/unzipped/Aster.app"
(cd "$scratch" && shasum -a 256 "$dmg" "$zip" > SHA256SUMS && shasum -a 256 -c SHA256SUMS)
mv "$scratch/$dmg" "$scratch/$zip" "$scratch/SHA256SUMS" "$output/"
