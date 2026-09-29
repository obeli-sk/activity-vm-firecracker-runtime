#!/usr/bin/env bash
set -euo pipefail

if (( $# != 6 )); then
  echo 'usage: build-bundle.sh FIRECRACKER KERNEL ROOTFS_ISO MAILBOX MKFS_EROFS OUTPUT_DIR' >&2
  exit 2
fi
firecracker=$1
kernel=$2
rootfs=$3
mailbox=$4
mkfs_erofs=$5
output=$6
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$output/guest"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
bsdtar -C "$root" -xf "$rootfs"
cp "$source_dir/init" "$root/init"
chmod 755 "$root/init"
install -m 755 "$mailbox" "$root/bin/mailbox"
mkdir -p "$root/share"
# Processes without CAP_DAC_OVERRIDE (e.g. Chromium's children) must traverse / and write /tmp.
chmod 755 "$root"
chmod 1777 "$root/tmp"
(
  cd "$root"
  bsdtar --format=newc --uid 0 --gid 0 -cf - . | gzip -1 > "$output/guest/initramfs.cpio.gz"
)
cp -f "$kernel" "$output/guest/vmlinux"
cp "$source_dir/machine.json" "$output/guest/machine.json"
printf '%s\n' "$firecracker" > "$output/firecracker-path"
printf '%s\n' "$mkfs_erofs" > "$output/mkfs-erofs-path"
"$firecracker" --version | head -1 > "$output/firecracker-version.txt"
