#!/bin/sh
set -eu

# Safe KN-3810 Entware/USB lab.
# Models the real installation substrate without touching a physical router:
# EXT4 -> /opt -> official MIPSEL Entware installer -> opkg -> package index.
# It deliberately does NOT emulate KeeneticOS/NDM/NFQUEUE kernel integration.

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

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "entware-lab: missing $1" >&2
    exit 1
  }
}

need curl
need tar
need sha256sum
need truncate
need mkfs.ext4
need mount
need "$QEMU"
QEMU_BIN="$(command -v "$QEMU")"

mkdir -p "$MOUNT"
truncate -s 512M "$IMAGE"
mkfs.ext4 -F -L HOPPER3810 "$IMAGE" >/dev/null
sudo mount -o loop "$IMAGE" "$MOUNT"
mkdir -p "$MOUNT/install"

echo "== Download official KN-3810 MIPSEL installer =="
curl --fail --silent --show-error --location --retry 3 -o "$ARCHIVE" "$URL"
sha256sum "$ARCHIVE"
cp "$ARCHIVE" "$MOUNT/install/mipsel-installer.tar.gz"

echo "== Validate installer archive =="
tar -tzf "$ARCHIVE" >/dev/null
tar -tzf "$ARCHIVE" | grep -E '(^|/)etc/opkg.conf$' >/dev/null
tar -tzf "$ARCHIVE" | grep -E '(^|/)opkg$' >/dev/null

echo "== Reconstruct Entware /opt from the official archive =="
mkdir -p "$MOUNT/opt"
tar -xzf "$ARCHIVE" -C "$MOUNT/opt" --no-same-owner

echo "== Verify Keenetic-compatible Entware layout =="
[ -f "$MOUNT/opt/etc/opkg.conf" ]
[ -d "$MOUNT/opt/etc/init.d" ]
[ -d "$MOUNT/opt/var/opkg-lists" ] || mkdir -p "$MOUNT/opt/var/opkg-lists"
sudo mkdir -p "$MOUNT/opt/tmp"

grep -Eq 'mipselsf-k3\.4' "$MOUNT/opt/etc/opkg.conf"

OPKG="$MOUNT/opt/bin/opkg"
[ -x "$OPKG" ] || OPKG="$MOUNT/opt/usr/bin/opkg"
[ -x "$OPKG" ] || {
  echo "opkg binary not found in official installer" >&2
  exit 1
}

echo "== Execute real MIPSEL opkg in an EXT4 chroot under QEMU =="
sudo cp "$QEMU_BIN" "$MOUNT/qemu-mipsel-static"
sudo mkdir -p "$MOUNT/etc"
sudo cp /etc/resolv.conf "$MOUNT/etc/resolv.conf"
sudo chroot "$MOUNT" /qemu-mipsel-static /opt/bin/opkg --version

echo "== Prepare official Entware package indexes on isolated local HTTP =="
REPO="$ROOT/repo"
mkdir -p "$REPO/mipselsf-k3.4/keenetic"
curl --fail --silent --show-error --location --retry 3 -o "$REPO/mipselsf-k3.4/Packages.gz" https://bin.entware.net/mipselsf-k3.4/Packages.gz
curl --fail --silent --show-error --location --retry 3 -o "$REPO/mipselsf-k3.4/keenetic/Packages.gz" https://bin.entware.net/mipselsf-k3.4/keenetic/Packages.gz
python3 -m http.server 18080 --bind 127.0.0.1 --directory "$REPO" >"$ROOT/repo-http.log" 2>&1 &
REPO_PID=$!
trap 'kill "$REPO_PID" 2>/dev/null || true' EXIT INT TERM
sudo sed -i 's#http://bin.entware.net/mipselsf-k3.4#http://127.0.0.1:18080/mipselsf-k3.4#g' "$MOUNT/opt/etc/opkg.conf"
echo "== Refresh MIPSEL Entware package indexes through isolated local HTTP =="
sudo chroot "$MOUNT" /qemu-mipsel-static /opt/bin/opkg update
echo "== Check package metadata =="
test -s "$MOUNT/opt/var/opkg-lists/entware"

echo "== Storage tree =="
find "$MOUNT/opt" -maxdepth 2 -type d | sort | head -n 80

echo "HOPPER3810 ENTWARE/EXT4 LAB: GREEN"
echo "Validated: EXT4 USB image, /opt layout, official MIPSEL installer, opkg execution, live package index."
echo "NOT VALIDATED: KeeneticOS NDM, OPKG GUI binding, real USB controller, NFQUEUE kernel hooks, HWNAT/Wi-Fi."
