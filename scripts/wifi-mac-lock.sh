#!/bin/sh
MAC_FILE="/etc/wlan0-mac"
IFACE="wlan0"

if [ -f "$MAC_FILE" ]; then
    # Apply saved MAC
    MAC=$(cat "$MAC_FILE")
    ip link set "$IFACE" down
    ip link set "$IFACE" address "$MAC"
    ip link set "$IFACE" up
    echo "wlan0 MAC locked to $MAC" > /dev/kmsg 2>/dev/null || true
else
    # First boot — capture current MAC and save it
    MAC=$(ip link show "$IFACE" 2>/dev/null | grep -o 'link/ether [^ ]*' | awk '{print $2}')
    if [ -n "$MAC" ] && [ "$MAC" != "00:00:00:00:00:00" ]; then
        echo "$MAC" > "$MAC_FILE"
        echo "wlan0 MAC saved: $MAC" > /dev/kmsg 2>/dev/null || true
    else
        echo "wlan0 MAC not available yet" > /dev/kmsg 2>/dev/null || true
        exit 1
    fi
fi
