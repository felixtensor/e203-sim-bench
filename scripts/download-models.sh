#!/usr/bin/env bash
# Download a published release asset. No executables are committed to Git.
set -euo pipefail
cd "$(dirname "$0")/.."
url=${1:?usage: download-models.sh URL SHA256}
sha=${2:?usage: download-models.sh URL SHA256}
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'models require Apple Silicon macOS' >&2; exit 1; }
mkdir -p build/reference
archive=build/reference/models.tar.gz
curl --fail --location "$url" --output "$archive"
printf '%s  %s\n' "$sha" "$archive" | shasum -a 256 -c -
# Permit only the four files produced by `make package-models`.
if tar -tzf "$archive" | grep -Ev '^(sim-arcilator|sim-verilator|bench-itcm-dtcm.bin|SHA256SUMS)$'; then
  echo 'unexpected archive entry' >&2; exit 1
fi
tar -xzf "$archive" -C build/reference
(cd build/reference && shasum -a 256 -c SHA256SUMS)
