#!/bin/bash
# Rebuilds the APT index from debs/*.deb: Packages(.gz/.bz2/.xz/.zst) + Release.
# Runs in GitHub Actions on every push (Linux, needs dpkg-dev); works locally too.
set -euo pipefail
cd "$(dirname "$0")"
dpkg-scanpackages --multiversion debs /dev/null > Packages 2>/dev/null
gzip -9kf Packages
bzip2 -9kf Packages
xz -9kf Packages
zstd -19 -qf Packages -o Packages.zst
{
    echo "Origin: Cellblock"
    echo "Label: Cellblock"
    echo "Suite: stable"
    echo "Version: 1.0"
    echo "Codename: cellblock"
    echo "Architectures: iphoneos-arm64e iphoneos-arm64"
    echo "Components: main"
    echo "Description: Cellblock's own tweaks (roothide)"
    apt-ftparchive release . 2>/dev/null | sed -n '/^MD5Sum:/,$p' | grep -vE ' (Release|build-repo.sh|README.md|index.html|CydiaIcon.png|icon.png)$'
} > Release
echo "$(grep -c '^Package:' Packages || true) packages"
