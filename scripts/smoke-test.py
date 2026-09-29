#!/usr/bin/env python3
"""Boot a built bundle with 2 vCPUs and 1 GiB, and run one guest command over the vsock mailbox."""

import json
import pathlib
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

MEMORY_MIB = 1024
CPUS = 2
MAILBOX_PORT = 1024
MARKER = "activity-vm-firecracker-store"


def frame(name, data):
    name = name.encode()
    return struct.pack("<HQ", len(name), len(data)) + name + data


def read_exact(connection, length):
    data = b""
    while len(data) < length:
        chunk = connection.recv(length - len(data))
        if not chunk:
            raise RuntimeError("guest mailbox closed")
        data += chunk
    return data


def read_frame(connection):
    name_length, data_length = struct.unpack("<HQ", read_exact(connection, 10))
    return read_exact(connection, name_length).decode(), read_exact(connection, data_length)


def main(bundle):
    bundle = pathlib.Path(bundle).resolve()
    guest = bundle / "guest"
    machine = json.loads((guest / "machine.json").read_text())
    # Obelisk runs both from PATH; a cold boot does not need the exact build version.
    firecracker = shutil.which("firecracker") or sys.exit("firecracker is not on PATH")
    mkfs_erofs = shutil.which("mkfs.erofs") or sys.exit("mkfs.erofs is not on PATH")
    version = subprocess.run([firecracker, "--version"], check=True, capture_output=True,
                             text=True).stdout.splitlines()[0]
    expected = (bundle / "firecracker-version.txt").read_text().strip()
    if version != expected:
        print(f"warning: bundle built with {expected}, running {version}", file=sys.stderr)
    with tempfile.TemporaryDirectory() as work:
        work = pathlib.Path(work)
        store = work / "share" / "nix" / "store"
        store.mkdir(parents=True)
        (store / "marker").write_text(MARKER + "\n")
        image = work / "store.img"
        subprocess.run([mkfs_erofs, "--all-root", "-T0", str(image), str(work / "share")],
                       check=True, stdout=subprocess.DEVNULL)
        vsock = work / "v.sock"
        config = {
            "boot-source": {
                "kernel_image_path": str(guest / "vmlinux"),
                "initrd_path": str(guest / "initramfs.cpio.gz"),
                "boot_args": machine["boot_args"],
            },
            "drives": [{"drive_id": "store", "path_on_host": str(image),
                        "is_root_device": False, "is_read_only": True}],
            "machine-config": {"vcpu_count": CPUS, "mem_size_mib": MEMORY_MIB},
            "vsock": {"guest_cid": 3, "uds_path": str(vsock)},
        }
        (work / "vm.json").write_text(json.dumps(config))
        run = (
            "#!/bin/sh\n"
            "q=/obelisk-activity-vm-http\n"
            "echo activity-vm-firecracker-ready $(date +%s)"
            " $(cat /nix/store/marker)"
            " $(grep MemTotal /proc/meminfo | tr -s ' ' | cut -d ' ' -f 2)"
            " $(nproc)"
            " $(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
            " $(cat /proc/sys/kernel/random/entropy_avail)"
            " > $q/smoke-result.tmp\n"
            "mv $q/smoke-result.tmp $q/smoke-result\n"
        )
        started = time.monotonic()
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(f"{vsock}_{MAILBOX_PORT}")
            listener.listen(1)
            listener.settimeout(15)
            serial = (work / "serial.log").open("wb")
            vm = subprocess.Popen(
                [firecracker, "--no-api", "--config-file", str(work / "vm.json"), "--level", "Error"],
                cwd=work, stdin=subprocess.DEVNULL, stdout=serial, stderr=subprocess.STDOUT,
            )
            try:
                try:
                    connection, _ = listener.accept()
                except TimeoutError:
                    raise RuntimeError("guest mailbox did not connect") from None
                with connection:
                    connection.settimeout(20)
                    connection.sendall(frame("run.sh", run.encode()))
                    name, data = read_frame(connection)
                    while name != "smoke-result":
                        name, data = read_frame(connection)
                elapsed = time.monotonic() - started
            except Exception:
                serial.flush()
                sys.stderr.write((work / "serial.log").read_text(errors="replace")[-4000:])
                raise
            finally:
                vm.kill()
                vm.wait()
                serial.close()
        actual = data.decode().split()
        if len(actual) != 7 or actual[0] != "activity-vm-firecracker-ready":
            raise RuntimeError(f"unexpected guest output: {actual!r}")
        if actual[2] != MARKER:
            raise RuntimeError(f"store image read {actual[2]!r}")
        mem_kib = int(actual[3])
        if mem_kib < (MEMORY_MIB - 128) << 10:
            raise RuntimeError(f"guest has MemTotal {mem_kib} KiB, expected about {MEMORY_MIB} MiB")
        if int(actual[4]) != CPUS:
            raise RuntimeError(f"guest has {actual[4]} vCPUs, expected {CPUS}")
        skew = int(actual[1]) - time.time()
        if abs(skew) > 5:
            raise RuntimeError(f"guest clock is off by {skew:.1f} s")
        print(f"{actual[0]} in {elapsed * 1000:.0f} ms (clock skew {skew:.1f} s, "
              f"MemTotal {mem_kib >> 10} MiB, {CPUS} vCPUs, {actual[5]}, entropy {actual[6]})")


if __name__ == "__main__":
    main(sys.argv[1])
