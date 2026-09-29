#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  echo 'usage: install-release.sh RELEASE_DIR OUTPUT_DIR' >&2
  exit 2
fi

release=$1
output=$2
(
  cd "$release"
  sha256sum -c SHA256SUMS
)
mkdir -p "$output"
zstd -dc "$release/activity-vm-firecracker.tar.zst" | tar -C "$output" -xf -
if [[ "$(cat "$output/firecracker-version.txt")" != "$(cat "$release/firecracker-version.txt")" ]]; then
  echo "Firecracker version in bundle does not match release metadata" >&2
  exit 1
fi
for file in guest/vmlinux guest/initramfs.cpio.gz guest/machine.json; do
  test -f "$output/$file"
done
printf '%s\n' "$output"
