#!/usr/bin/env bash
# build-recovery.sh — build a minimal recovery.img for the Huawei Mate 20 Lite (Kirin 710)
# Flash with: fastboot flash recovery recovery.img
set -euo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$WORK_DIR"

HALIUM_BIN="halium-initramfs/bin"
HALIUM_SBIN="halium-initramfs/sbin"
HALIUM_LIB="halium-initramfs/lib"
RD="recovery-initramfs"

# ── Locate adbd binary ────────────────────────────────────────────────────────
# adbd must be an arm64 Linux binary. Source options (in order):
#   1. Pre-placed at halium-initramfs/sbin/adbd
#   2. Extracted from rootfs.img (Linux only — requires loop mount)
ADBD_SRC=""
if [ -f "$HALIUM_SBIN/adbd" ]; then
    ADBD_SRC="$HALIUM_SBIN/adbd"
    echo "[*] Using pre-placed adbd: $ADBD_SRC"
elif [ "$(uname)" = "Linux" ] && [ -f rootfs.img ]; then
    echo "[*] Extracting adbd from rootfs.img (requires sudo)..."
    _ROOTFS_MNT=$(mktemp -d)
    sudo mount -o loop,ro rootfs.img "$_ROOTFS_MNT"
    if [ -f "$_ROOTFS_MNT/usr/lib/android-sdk/platform-tools/adbd" ]; then
        cp "$_ROOTFS_MNT/usr/lib/android-sdk/platform-tools/adbd" "$HALIUM_SBIN/adbd"
        chmod 755 "$HALIUM_SBIN/adbd"
        ADBD_SRC="$HALIUM_SBIN/adbd"
        echo "[OK] adbd extracted and cached at $HALIUM_SBIN/adbd"
    else
        echo "[WARN] adbd not found in rootfs.img — building without ADB"
    fi
    sudo umount "$_ROOTFS_MNT"
    rmdir "$_ROOTFS_MNT"
else
    echo "[WARN] adbd not available. Building without ADB support."
    echo "       To enable ADB in recovery, place an arm64 adbd binary at:"
    echo "       $HALIUM_SBIN/adbd"
fi

# Boot image parameters (same as halium-boot)
# Recovery.img on Kirin 710 has kernel_size=0 — bootloader loads its own kernel.
# We match the same header format as LineageOS recovery.img (header_version=0, page_size=2048).
PAGE_SIZE=2048
RAMDISK_ADDR="0x11000000"

# ── Build minimal recovery ramdisk ───────────────────────────────────────────
echo "[*] Building recovery ramdisk at ${RD}/..."
rm -rf "$RD"
mkdir -p "$RD"/{bin,sbin,dev,proc,sys,tmp,cache,run}
mkdir -p "$RD/dev/usb-ffs/adb"

# Copy busybox and create essential symlinks
cp "$HALIUM_BIN/busybox" "$RD/bin/busybox"
chmod 755 "$RD/bin/busybox"
for tool in sh ash echo cat ls sleep mount umount mkdir rm cp mv ln chmod \
            seq od dd wc awk sed grep head tail cut sort uniq \
            dmesg date uptime; do
  ln -sf busybox "$RD/bin/$tool"
done

# reboot wrapper — busybox reboot signals PID1 which ignores it; use sysrq instead
cat > "$RD/bin/reboot" << 'REBOOT_EOF'
#!/bin/sh
# Write BCB if rebooting to bootloader
if [ "$1" = "bootloader" ]; then
  # Android BCB: first 32 bytes = command ("boot-bootloader\0")
  printf 'boot-bootloader\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0' | dd of=/dev/mmcblk0p27 bs=32 count=1 2>/dev/null || true
fi
sync
echo b > /proc/sysrq-trigger
REBOOT_EOF
chmod 755 "$RD/bin/reboot"
for tool in ip telnetd; do
  ln -sf ../bin/busybox "$RD/sbin/$tool"
done
# Also put ip/telnetd in bin for convenience
ln -sf busybox "$RD/bin/ip"
ln -sf busybox "$RD/bin/telnetd"

# Minimal /etc needed by busybox telnetd
mkdir -p "$RD/etc"
printf 'root::0:0:root:/:/bin/sh\n' > "$RD/etc/passwd"
printf 'root:x:0:\n' > "$RD/etc/group"
printf '#!/bin/sh\nexec /bin/sh\n' > "$RD/etc/profile"
chmod 644 "$RD/etc/passwd" "$RD/etc/group" "$RD/etc/profile"

# /default.prop — makes adbd run in insecure/root mode (no auth prompt)
cat > "$RD/default.prop" << 'PROP_EOF'
ro.secure=0
ro.debuggable=1
persist.sys.usb.config=adb
PROP_EOF

# /adb_keys — authorized host public key (allows passwordless adb connect)
# Embed the developer's key if present; adbd falls back to auth prompt otherwise.
ADB_PUBKEY="${HOME}/.android/adbkey.pub"
if [ -f "$ADB_PUBKEY" ]; then
    cp "$ADB_PUBKEY" "$RD/adb_keys"
    chmod 640 "$RD/adb_keys"
    echo "[*] Embedded ADB public key from $ADB_PUBKEY"
else
    touch "$RD/adb_keys"
    echo "[WARN] ~/.android/adbkey.pub not found — ADB auth will be required"
    echo "       Run 'adb devices' once on the host to generate the key pair, then rebuild"
fi

# adbd binary
if [ -n "$ADBD_SRC" ]; then
    cp "$ADBD_SRC" "$RD/sbin/adbd"
    chmod 755 "$RD/sbin/adbd"
    echo "[*] adbd included in recovery"
fi

# ── Write /init ──────────────────────────────────────────────────────────────
cat > "$RD/init" << 'INITEOF'
#!/bin/sh
# Droidian recovery init — boots directly into recovery mode
# Persistent log: /cache/recovery-debug.log (ext4 on mmcblk0p65)

export PATH=/bin:/sbin

# ── STEP 1: mount virtual filesystems ────────────────────────────────────────
mount -t proc  proc  /proc  2>/dev/null || true
mount -t sysfs sysfs /sys   2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts
mount -t devpts -o gid=5,mode=620 devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true

# ── STEP 2: mount cache partition for persistent logging ──────────────────────
mkdir -p /cache
mount -t ext4 /dev/mmcblk0p65 /cache 2>/dev/null || \
  mount -t ext4 /dev/block/mmcblk0p65 /cache 2>/dev/null || true

LOG=/cache/recovery-debug.log

log() {
  local ts
  ts=$(cat /proc/uptime 2>/dev/null | cut -d' ' -f1)
  echo "$ts RECOVERY: $*" >> "$LOG" 2>/dev/null || true
  echo "$ts RECOVERY: $*" > /dev/kmsg 2>/dev/null || true
}

log "=== RECOVERY INIT STARTED ==="
log "cmdline: $(cat /proc/cmdline 2>/dev/null)"
log "uptime:  $(cat /proc/uptime 2>/dev/null)"

# ── STEP 3: log kernel messages so far ───────────────────────────────────────
dmesg 2>/dev/null >> "$LOG" || true
log "--- dmesg above ---"

# ── STEP 4: log input devices ────────────────────────────────────────────────
log "input devices: $(ls /dev/input/ 2>/dev/null || echo 'none')"
log "block devices: $(ls /dev/block/ 2>/dev/null | head -20 || ls /dev/mmcblk* 2>/dev/null || echo 'none')"

# ── STEP 5: feed watchdog ─────────────────────────────────────────────────────
(
  while true; do
    echo 1 > /dev/watchdog 2>/dev/null || true
    sleep 5
  done
) &
log "STEP5: watchdog feeder started (pid=$!)"

# ── STEP 6: USB device mode trigger ──────────────────────────────────────────
if [ -f /sys/class/dual_role_usb/otg_default/mode ]; then
  echo device > /sys/class/dual_role_usb/otg_default/mode 2>/dev/null && \
    log "STEP6: USB device mode set" || \
    log "STEP6: USB device mode write failed (non-fatal)"
else
  log "STEP6: dual_role_usb not found, skipping"
fi

# ── STEP 7: wait for UDC (up to 130s) ─────────────────────────────────────────
log "STEP7: waiting for UDC..."
UDC=""
for i in $(seq 1 66); do
  UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
  if [ -n "$UDC" ]; then
    log "STEP7: UDC found after $((i*2))s: $UDC"
    break
  fi
  if [ $((i % 5)) -eq 0 ]; then
    log "STEP7: still waiting... $((i*2))s elapsed, udc=$(ls /sys/class/udc/ 2>/dev/null | tr '\n' ' ')"
    log "STEP7: sys/kernel/config exists=$(ls /sys/kernel/config 2>/dev/null && echo yes || echo no)"
  fi
  sleep 2
done

if [ -z "$UDC" ]; then
  log "STEP7: ERROR: no UDC after 132s — USB unavailable"
else
  # ── STEP 8: composite ADB (FFS) + NCM gadget setup ─────────────────────────
  log "STEP8: setting up composite ADB+NCM gadget on $UDC..."
  mount -t configfs none /sys/kernel/config 2>/dev/null || true
  GADGET=/sys/kernel/config/usb_gadget/g1

  for g in /sys/kernel/config/usb_gadget/g_debug /sys/kernel/config/usb_gadget/g1; do
    if [ -d "$g" ]; then
      log "STEP8: tearing down existing gadget $g"
      echo "" > "$g/UDC" 2>/dev/null || true
      rm -f "$g/configs/c.1/ffs.adb"   2>/dev/null || true
      rm -f "$g/configs/c.1/ncm.usb0"  2>/dev/null || true
      rmdir "$g/configs/c.1/strings/0x409" 2>/dev/null || true
      rmdir "$g/configs/c.1" 2>/dev/null || true
      rmdir "$g/functions/ffs.adb"  2>/dev/null || true
      rmdir "$g/functions/ncm.usb0" 2>/dev/null || true
      rmdir "$g/strings/0x409" 2>/dev/null || true
      rmdir "$g" 2>/dev/null || true
    fi
  done

  mkdir -p "$GADGET" || { log "STEP8: ERROR: cannot mkdir gadget"; }
  echo 0x18d1 > "$GADGET/idVendor"   # Google — recognized as ADB by host
  echo 0xd001 > "$GADGET/idProduct"
  mkdir -p "$GADGET/strings/0x409"
  echo "droidian-recovery" > "$GADGET/strings/0x409/serialnumber"
  echo "Droidian"          > "$GADGET/strings/0x409/manufacturer"
  echo "Recovery"          > "$GADGET/strings/0x409/product"

  # ADB function — FunctionFS (adbd writes descriptors before UDC bind)
  HAVE_ADB=0
  if [ -x /sbin/adbd ]; then
    mkdir -p "$GADGET/functions/ffs.adb"
    mkdir -p /dev/usb-ffs/adb
    if mount -t functionfs adb /dev/usb-ffs/adb 2>/dev/null; then
      log "STEP8: FFS mounted at /dev/usb-ffs/adb"
      # Start adbd — writes USB descriptors to ep0; must happen before UDC bind
      ADB_KEYS=/adb_keys /sbin/adbd &
      ADBD_PID=$!
      log "STEP8: adbd started (pid=$ADBD_PID), waiting for FFS descriptors..."
      # Poll ep0 for descriptor write (adbd signals ready when ep0 becomes writable)
      _i=0
      while [ $_i -lt 20 ]; do
        [ -e /dev/usb-ffs/adb/ep1 ] && break
        sleep 0.5 2>/dev/null || sleep 1
        _i=$((_i + 1))
      done
      if [ -e /dev/usb-ffs/adb/ep1 ]; then
        log "STEP8: FFS descriptors written — ADB ready"
        HAVE_ADB=1
      else
        log "STEP8: WARNING: adbd did not write FFS descriptors in time"
      fi
    else
      log "STEP8: WARNING: FFS mount failed — ADB unavailable"
    fi
  else
    log "STEP8: adbd not found — skipping ADB"
  fi

  # NCM function — for network / telnet fallback
  mkdir -p "$GADGET/functions/ncm.usb0"
  echo "DE:AD:BE:EF:00:01" > "$GADGET/functions/ncm.usb0/host_addr"
  echo "DE:AD:BE:EF:00:02" > "$GADGET/functions/ncm.usb0/dev_addr"

  mkdir -p "$GADGET/configs/c.1/strings/0x409"
  echo "ADB+NCM"           > "$GADGET/configs/c.1/strings/0x409/configuration"
  echo 500                 > "$GADGET/configs/c.1/MaxPower"
  [ $HAVE_ADB -eq 1 ] && ln -s "$GADGET/functions/ffs.adb"  "$GADGET/configs/c.1/"
  ln -s "$GADGET/functions/ncm.usb0" "$GADGET/configs/c.1/"
  echo "$UDC"              > "$GADGET/UDC"
  log "STEP8: gadget enabled on $UDC (ADB=$HAVE_ADB)"
  log "STEP8: gadget UDC=$(cat $GADGET/UDC 2>/dev/null)"

  # ── STEP 9: find NCM interface and assign IP ──────────────────────────────
  log "STEP9: waiting for NCM network interface..."
  sleep 2
  IFACE=""
  for i in $(seq 1 15); do
    IFACE=$(ip link show 2>/dev/null | grep -i "de:ad:be:ef:00:02" -B1 | head -1 | sed "s/^[0-9]*: \([^:@]*\).*/\1/")
    if [ -n "$IFACE" ]; then
      log "STEP9: interface found after ${i}s: $IFACE"
      break
    fi
    log "STEP9: waiting... ${i}s, links: $(ip link show 2>/dev/null | grep -E '^[0-9]' | tr '\n' ' ')"
    sleep 1
  done

  if [ -n "$IFACE" ]; then
    ip link set "$IFACE" up
    ip addr flush dev "$IFACE" 2>/dev/null || true
    ip addr add 10.15.19.82/24 dev "$IFACE"
    log "STEP9: $IFACE configured at 10.15.19.82/24"
    log "STEP9: ip addr: $(ip addr show dev $IFACE 2>/dev/null)"
  else
    log "STEP9: WARNING: no NCM interface found"
    log "STEP9: all interfaces: $(ip link show 2>/dev/null)"
  fi

  # ── STEP 10: start telnetd (interactive) + nc command server (scripted) ────
  if command -v telnetd >/dev/null 2>&1; then
    telnetd -l /bin/sh -p 23 2>/dev/null &
    log "STEP10: telnetd started on :23 (pid=$!)"
  else
    log "STEP10: WARNING: telnetd not found"
  fi

  # nc -e command server on port 9999: each connection gets a plain sh session
  # Usage from host: printf "CMD\nexit\n" | nc 10.15.19.82 9999
  (while true; do nc -l -p 9999 -e /bin/sh 2>/dev/null; done) &
  log "STEP10: nc command server started on :9999 (pid=$!)"
fi

log "=== RECOVERY READY ==="
log "=== ADB:    adb shell / adb push  (if adbd started successfully) ==="
log "=== Telnet: 10.15.19.82:23  (set host IP: sudo ifconfig en0 10.15.19.1/24) ==="
log "=== NC:     printf 'CMD\nexit\n' | nc 10.15.19.82 9999 ==="

# ── Keep alive: log every 30s, reboot after 30 minutes ────────────────────────
N=0
while [ $N -lt 60 ]; do
  sleep 30
  N=$((N+1))
  log "alive tick $N ($((N*30))s) — telnetd=$(ls /proc/${TELNET_PID:-0} 2>/dev/null && echo running || echo gone) adbd=$(ls /proc/${ADBD_PID:-0} 2>/dev/null && echo running || echo gone)"
  # Re-log IP state in case something changed
  if [ -n "${IFACE:-}" ]; then
    log "ip state: $(ip addr show dev $IFACE 2>/dev/null | tr '\n' ' ')"
  fi
done

log "=== RECOVERY TIMEOUT (30min) — rebooting ==="
reboot
INITEOF

chmod 755 "$RD/init"

# ── Pack ramdisk ─────────────────────────────────────────────────────────────
echo "[*] Packing recovery ramdisk..."
cd "$RD"
find . | sort | cpio -o -H newc -R 0:0 2>/dev/null | gzip > "$WORK_DIR/recovery-ramdisk.img"
cd "$WORK_DIR"
echo "[OK] recovery-ramdisk.img: $(du -sh recovery-ramdisk.img | cut -f1)"

# ── Build recovery.img (kernel_size=0, header_version=0, same as LineageOS) ───
# The bootloader provides its own recovery kernel from erecovery_kernel_a.
# We only need: ANDROID! header + ramdisk data.
BUILD_TAG="$(date +%Y%m%d-%H%M%S)"
mkdir -p out
OUT="out/recovery-${BUILD_TAG}.img"

echo "[*] Building ${OUT} (ramdisk-only, kernel_size=0)..."
python3 - "$OUT" recovery-ramdisk.img "$PAGE_SIZE" "$RAMDISK_ADDR" << 'PYEOF'
import sys, struct, os, hashlib

out_path   = sys.argv[1]
rd_path    = sys.argv[2]
page_size  = int(sys.argv[3])
rd_addr    = int(sys.argv[4], 16)

rd_data = open(rd_path, 'rb').read()
rd_size = len(rd_data)

# Android boot header v0 (matching LineageOS recovery.img format)
# Ref: https://source.android.com/docs/core/architecture/bootloader/boot-image-header
MAGIC        = b'ANDROID!'
kernel_size  = 0
kernel_addr  = 0x00100000
second_size  = 0
second_addr  = 0x00f00000
tags_addr    = 0x00000100
os_version   = 0
name         = b'\x00' * 16
cmdline      = b'\x00' * 512
extra_cmdline= b'\x00' * 1024

# id = SHA1 over kernel+ramdisk+second (kernel is empty here)
sha = hashlib.sha1()
sha.update(rd_data)
sha.update(struct.pack('<I', rd_size))
img_id = sha.digest() + b'\x00' * (32 - len(sha.digest()))

header = struct.pack('<8sIIIIIIIII',
    MAGIC, kernel_size, kernel_addr, rd_size, rd_addr,
    second_size, second_addr, tags_addr, page_size, 0)  # 0 = header_version
header += struct.pack('<I', os_version)
header += name
header += cmdline
header += img_id
header += extra_cmdline

# Pad header to page_size
assert len(header) <= page_size, f"header too large: {len(header)}"
header = header.ljust(page_size, b'\x00')

# Pad ramdisk to page boundary
def pad(data, ps):
    r = len(data) % ps
    return data + b'\x00' * (ps - r) if r else data

with open(out_path, 'wb') as f:
    f.write(header)
    f.write(pad(rd_data, page_size))

size = os.path.getsize(out_path)
print(f'[OK] {out_path}: {size//1024}K (header={len(header)}B ramdisk={rd_size}B)')
PYEOF

ln -sf "out/recovery-${BUILD_TAG}.img" recovery.img

echo "[OK] recovery.img -> out/recovery-${BUILD_TAG}.img"
echo ""
echo "Flash with:"
echo "  fastboot flash recovery recovery.img"
