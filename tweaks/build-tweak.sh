#!/bin/bash
# build-tweak.sh <tweak folder> [framework...]: builds <Name>.m into a fat arm64 + arm64e dylib
# (Cellblock's home runs arm64, a real roothide SpringBoard arm64e), ad-hoc signed, and packs
# the folder's layout/ with dpkg-deb into debs/. macOS + Xcode (GitHub's macOS runner).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(cd "$1" && pwd)"; shift
control="$dir/layout/DEBIAN/control"
name=$(sed -n 's/^Name: //p' "$control")
package=$(sed -n 's/^Package: //p' "$control")
version=$(sed -n 's/^Version: //p' "$control")
frameworks=(-framework UIKit -framework Foundation)
for f in "$@"; do frameworks+=(-framework "$f"); done
out="$dir/build/root"
rm -rf "$dir/build" && mkdir -p "$out"
cp -R "$dir/layout/." "$out/"
dylib="$out/Library/MobileSubstrate/DynamicLibraries/$name.dylib"
xcrun -sdk iphoneos clang -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -fobjc-arc -O2 -Wall \
    -dynamiclib -install_name "@rpath/$name.dylib" "${frameworks[@]}" -o "$dylib" "$dir/$name.m"
codesign -f -s - "$dylib"
plutil -convert binary1 "$out/Library/MobileSubstrate/DynamicLibraries/$name.plist"
find "$out" -name .DS_Store -delete
command -v dpkg-deb >/dev/null || brew install dpkg
mkdir -p "$here/../debs"
rm -f "$here/../debs/${package}_"*.deb
dpkg-deb -Zxz --root-owner-group -b "$out" "$here/../debs/${package}_${version}_iphoneos-arm64e.deb"
rm -rf "$dir/build"
