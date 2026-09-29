#!/usr/bin/env bash
set -euo pipefail

if (( $# != 3 )); then
  echo 'usage: stage-release.sh RUNTIME_PATH FLAKE_LOCK OUTPUT_DIR' >&2
  exit 2
fi

runtime=$(readlink -f "$1")
lock=$2
output=$3
mkdir -p "$output"
nixpkgs_node=$(jq -er '.nodes.root.inputs.nixpkgs' "$lock")
revision=$(jq -er --arg node "$nixpkgs_node" '.nodes[$node].locked.rev' "$lock")
printf 'github:NixOS/nixpkgs/%s#firecracker\n' "$revision" > "$output/firecracker-source.txt"
cp "$runtime/firecracker-version.txt" "$output/firecracker-version.txt"
tar -C "$runtime" -cf - guest firecracker-version.txt | zstd -T0 -q -f -o "$output/activity-vm-firecracker.tar.zst"
(
  cd "$output"
  sha256sum firecracker-source.txt firecracker-version.txt activity-vm-firecracker.tar.zst > SHA256SUMS
)
