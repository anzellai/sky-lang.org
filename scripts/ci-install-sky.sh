#!/usr/bin/env bash
set -euo pipefail
version=0.29.5
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
base="https://github.com/anzellai/sky/releases/download/v${version}"
curl -fsSL "$base/sky-linux-x64.tar.gz" -o "$dir/sky-linux-x64.tar.gz"
curl -fsSL "$base/checksums.txt" -o "$dir/checksums.txt"
(cd "$dir"; grep ' sky-linux-x64.tar.gz$' checksums.txt | sha256sum -c -)
tar -xzf "$dir/sky-linux-x64.tar.gz" -C "$dir"
test -x "$dir/sky-linux-x64"
if [ "$#" -gt 0 ]; then
 [[ "$1" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid optional compiler digest'; exit 1; }
 test "$(sha256sum "$dir/sky-linux-x64" | cut -d' ' -f1)" = "$1"
fi
sudo install -m0755 "$dir/sky-linux-x64" /usr/local/bin/sky
sky --version | grep -Eq '(^|[^0-9])0\.29\.5([^0-9]|$)'
mkdir -p ci-results
sha256sum /usr/local/bin/sky > ci-results/compiler.sha256
cp "$dir/checksums.txt" ci-results/release-checksums.txt
sha256sum "$dir/sky-linux-x64.tar.gz" > ci-results/release-archive.sha256
