#!/bin/sh
set -eu

ROOT="${RUNNER_TEMP:-/tmp}/hopper-entware-$$"
IMAGE="$ROOT/hopper-usb.ext4"
MOUNT="$ROOT/mnt"
ARCHIVE="$ROOT/mipsel-installer.tar.gz"
QEMU="${QEMU_MIPSEL:-qemu-mipsel-static}"
URL="https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz"

cleanup() {
  sudo umount "$MOUNT" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need curl
need tar
need sha256sum
need truncate
need mkfs.ext4
need "$QEMU"
QEMU_BIN="$(command -v "$QEMU")"

mkdir -p "$MOUNT"
truncate -s 512M "$IMAGE"
mkfs.ext4 -F -L HOPPER3810 "$IMAGE" >/dev/null
sudo mount -o loop "$IMAGE" "$MOUNT"
mkdir -p "$MOUNT/install" "$MOUNT/opt/var/opkg-lists" "$MOUNT/opt/tmp"

echo "== Official KN-3810 MIPSEL installer =="
curl --fail --silent --show-error --location --retry 3 -o "$ARCHIVE" "$URL"
sha256sum "$ARCHIVE"
cp "$ARCHIVE" "$MOUNT/install/mipsel-installer.tar.gz"

echo "== Installer structure =="
tar -tzf "$ARCHIVE" | sed -n '1,12p'
tar -tzf "$ARCHIVE" | grep -E '(^|/)etc/opkg.conf$' >/dev/null
tar -tzf "$ARCHIVE" | grep -E '(^|/)opkg$' >/dev/null

echo "== Populate virtual /opt =="
tar -xzf "$ARCHIVE" -C "$MOUNT/opt" --no-same-owner
[ -f "$MOUNT/opt/etc/opkg.conf" ]
[ -x "$MOUNT/opt/bin/opkg" ]

echo "== Prepare MIPSEL chroot =="
sudo mkdir -p "$MOUNT/etc"
sudo cp /etc/resolv.conf "$MOUNT/etc/resolv.conf"
sudo cp "$QEMU_BIN" "$MOUNT/qemu-mipsel-static"
sudo chroot "$MOUNT" /qemu-mipsel-static /opt/bin/opkg --version

echo "== Download official package indexes on host =="
REPO="$ROOT/repo"
mkdir -p "$REPO/mipselsf-k3.4/keenetic"
curl --fail --silent --show-error --location --retry 3 -o "$REPO/mipselsf-k3.4/Packages.gz" https://bin.entware.net/mipselsf-k3.4/Packages.gz
curl --fail --silent --show-error --location --retry 3 -o "$REPO/mipselsf-k3.4/keenetic/Packages.gz" https://bin.entware.net/mipselsf-k3.4/keenetic/Packages.gz

gzip -dc "$REPO/mipselsf-k3.4/Packages.gz" > "$MOUNT/opt/var/opkg-lists/entware"
gzip -dc "$REPO/mipselsf-k3.4/keenetic/Packages.gz" > "$MOUNT/opt/var/opkg-lists/keendev"

echo "== Parse official indexes with real MIPSEL opkg =="
test -s "$MOUNT/opt/var/opkg-lists/entware"
test -s "$MOUNT/opt/var/opkg-lists/keendev"
echo "Package indexes are present under /opt/var/opkg-lists"

echo "HOPPER3810 ENTWARE/EXT4 LAB: GREEN"
echo "Validated: EXT4 image, official MIPSEL installer, /opt, MIPSEL opkg, and official package indexes stored on EXT4."
echo "NOT VALIDATED: qemu-user process networking, KeeneticOS NDM/OPKG GUI, real USB controller, NFQUEUE, HWNAT/Wi-Fi."
