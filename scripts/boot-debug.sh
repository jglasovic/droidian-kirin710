#!/bin/sh
LOG="/var/log/boot-debug.log"
exec > "$LOG" 2>&1
echo "=== boot-debug $(date) ==="

echo ""; echo "--- systemctl failed units ---"
systemctl --no-pager list-units --state=failed 2>/dev/null || true

echo ""; echo "--- systemctl all custom units ---"
for svc in usb-gadget-trigger usb-rndis adbd android-mount android-system-vendor.mount \
           hisi-wifi-init wpa_supplicant-wlan0 wifi-dhcp display-off package-sideload; do
    echo ""
    echo ">> $svc:"
    systemctl status "$svc" --no-pager -l 2>/dev/null || echo "  (not found)"
done

echo ""; echo "--- journalctl for USB ---"
journalctl -u usb-gadget-trigger -u usb-rndis --no-pager -n 50 2>/dev/null || true

echo ""; echo "--- journalctl for WiFi ---"
journalctl -u hisi-wifi-init -u wpa_supplicant-wlan0 -u wifi-dhcp --no-pager -n 50 2>/dev/null || true

echo ""; echo "--- journalctl for sshd ---"
journalctl -u ssh -u sshd --no-pager -n 30 2>/dev/null || true

echo ""; echo "--- journalctl for adbd ---"
journalctl -u adbd --no-pager -n 30 2>/dev/null || true

echo ""; echo "--- journalctl for package-sideload ---"
journalctl -u package-sideload --no-pager -n 30 2>/dev/null || true

echo ""; echo "--- network interfaces ---"
ip addr 2>/dev/null || ifconfig 2>/dev/null || true

echo ""; echo "--- USB gadget state ---"
ls -la /sys/class/udc/ 2>/dev/null || echo "no UDC"
cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null || echo "no gadget UDC"
ls -la /sys/kernel/config/usb_gadget/g1/configs/c.1/ 2>/dev/null || true

echo ""; echo "--- wlan state ---"
ip link show wlan0 2>/dev/null || echo "no wlan0"
wpa_cli -i wlan0 status 2>/dev/null || true
wpa_cli -i wlan0 scan_results 2>/dev/null || true

echo ""; echo "--- listening ports ---"
ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true

echo ""; echo "--- usb-rndis log ---"
cat /var/log/usb-rndis.log 2>/dev/null || echo "(no usb-rndis log)"

echo ""; echo "--- dmesg USB/NCM/gadget ---"
dmesg 2>/dev/null | grep -iE 'usb|ncm|gadget|dwc3|udc' | tail -30 || true

echo ""; echo "--- dmesg wifi/wlan ---"
dmesg 2>/dev/null | grep -iE 'wifi|wlan|hi110|hisi' | tail -30 || true

echo ""; echo "--- journal errors ---"
journalctl -p err --no-pager -n 30 2>/dev/null || true

echo ""; echo "=== boot-debug done ==="
