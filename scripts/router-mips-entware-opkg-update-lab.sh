#!/bin/sh
set -eu
ROOT="${RUNNER_TEMP:-/tmp}/hopper-mips-entware-opkg-update-$$"
BR_TAR="$ROOT/buildroot.tar.xz"
BR_URL="https://buildroot.org/downloads/buildroot-2026.08.tar.xz"
OPT_IMAGE="$ROOT/hopper-opt.ext4"
INSTALLER="$ROOT/mipsel-installer.tar.gz"
ENTWARE_URL="https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz"
ROOTFS_MOUNT="$ROOT/rootfs"
OPT_MOUNT="$ROOT/opt"
QEMU_LOG="$ROOT/qemu.log"

cleanup() {
  sudo umount "$OPT_MOUNT" 2>/dev/null || true
  sudo umount "$ROOTFS_MOUNT" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT INT TERM

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
for x in curl tar truncate mkfs.ext4 mount timeout qemu-system-mipsel; do need "$x"; done
mkdir -p "$ROOT" "$ROOTFS_MOUNT" "$OPT_MOUNT"

curl --fail --silent --show-error --location --retry 3 -o "$BR_TAR" "$BR_URL"
tar -xf "$BR_TAR" -C "$ROOT"
BR="$(find "$ROOT" -maxdepth 1 -type d -name "buildroot-*" | head -n 1)"
cd "$BR"
make qemu_mips32r2el_malta_defconfig
make -j"$(nproc)"
[ -x output/images/vmlinux ]
[ -s output/images/rootfs.ext2 ]

echo "== Build real Entware EXT4 /opt disk =="
truncate -s 768M "$OPT_IMAGE"
mkfs.ext4 -F -L HOPPEROPT "$OPT_IMAGE" >/dev/null
sudo mount -o loop "$OPT_IMAGE" "$OPT_MOUNT"
curl --fail --silent --show-error --location --retry 3 -o "$INSTALLER" "$ENTWARE_URL"
tar -xzf "$INSTALLER" -C "$OPT_MOUNT" --no-same-owner
[ -x "$OPT_MOUNT/opt/bin/opkg" ]
[ -f "$OPT_MOUNT/opt/etc/opkg.conf" ]

echo "== Inject network + opkg-update boot gate =="
sudo mount -o loop "$BR/output/images/rootfs.ext2" "$ROOTFS_MOUNT"
sudo mkdir -p "$ROOTFS_MOUNT/opt" "$ROOTFS_MOUNT/etc/init.d"
sudo sh -c 'cat > "$1/etc/init.d/S20hopper-opkg-update"' sh "$ROOTFS_MOUNT" <<'EOF'
#!/bin/sh
echo "HOPPER_NET_GATE: starting"
printf '%s\n' 'nameserver 10.0.2.3' > /etc/resolv.conf
if ! command -v udhcpc >/dev/null 2>&1; then
  echo "HOPPER_NET_GATE: FAIL no udhcpc" >&2
  exit 1
fi
udhcpc -i eth0 -n -q -t 5 -T 3
ip addr show dev eth0
ip route show
if ! ip addr show dev eth0 | grep -q 'inet '; then
  echo "HOPPER_NET_GATE: FAIL no IPv4 address" >&2
  exit 1
fi
echo "HOPPER_NET_GATE: GREEN"
echo "HOPPER_OPKG_UPDATE: starting"
set +e
timeout 60 /opt/bin/opkg update
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
  echo "HOPPER_OPKG_UPDATE: FAIL rc=$RC" >&2
  exit "$RC"
fi
COUNT="$(find /opt/var/opkg-lists -type f -size +0c 2>/dev/null | wc -l)"
echo "HOPPER_OPKG_UPDATE: GREEN lists=$COUNT"
if [ "$COUNT" -lt 1 ]; then
  echo "HOPPER_OPKG_UPDATE: FAIL no package lists" >&2
  exit 1
fi
EOF
sudo chmod 755 "$ROOTFS_MOUNT/etc/init.d/S20hopper-opkg-update"
sudo umount "$ROOTFS_MOUNT"

echo "== Boot Malta and require real network + opkg update =="
set +e
timeout 120s qemu-system-mipsel -M malta -m 256 -kernel output/images/vmlinux \
  -drive file=output/images/rootfs.ext2,format=raw,if=ide,index=0 \
  -drive file="$OPT_IMAGE",format=raw,if=ide,index=1 \
  -append "rootwait root=/dev/sda console=ttyS0" \
  -net nic,model=pcnet -net user -nographic -no-reboot > "$QEMU_LOG" 2>&1
RC=$?
set -e

grep -q "HOPPER_NET_GATE: GREEN" "$QEMU_LOG"
grep -q "HOPPER_OPKG_UPDATE: GREEN" "$QEMU_LOG"
sed -n '/HOPPER_NET_GATE/p;/HOPPER_OPKG_UPDATE/p;/eth0/p;/inet /p;/default/p' "$QEMU_LOG" | head -n 120
if [ "$RC" -ne 0 ] && [ "$RC" -ne 124 ]; then exit "$RC"; fi
echo "HOPPER3810 MIPS ENTWARE OPKG UPDATE LAB: GREEN"
echo "Validated: MIPS Linux, PCnet32, real EXT4 /opt, official MIPSEL Entware, DHCP, DNS path, and opkg update inside the VM."
echo "NOT VALIDATED: KeeneticOS, EN7528DU, real USB controller, NFQUEUE, HWNAT/Wi-Fi, D2K/QUIC."
