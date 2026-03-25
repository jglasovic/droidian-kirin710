#!/bin/sh
# led-status.sh — LED status indicator for headless Kirin 710
#
# Boot sequence (started at basic.target):
#   phase 1: BLUE solid      — basic.target reached
#   phase 2: BLUE blink      — services loading (waiting for multi-user.target)
#   phase 3: GREEN blink     — services up, waiting for WiFi (min 5s)
#   phase 4: GREEN solid     — WiFi connected
#            YELLOW blink    — no WiFi / no IP
#
#   shutdown: RED solid (via ExecStop)
set -eu

LED=/sys/class/leds
BLINK_PID=""

_led_set() {
    echo "$1" > "$LED/red/brightness"
    echo "$2" > "$LED/green/brightness"
    echo "$3" > "$LED/blue/brightness"
}

stop_blink() {
    if [ -n "$BLINK_PID" ]; then
        kill "$BLINK_PID" 2>/dev/null || true
        BLINK_PID=""
    fi
}

led_off() {
    stop_blink
    for c in red green blue; do
        echo none > "$LED/$c/trigger"
        echo 0    > "$LED/$c/brightness"
    done
}

# led_solid R G B
led_solid() {
    stop_blink
    _led_set "$1" "$2" "$3"
}

# led_blink R G B ON_SECS OFF_SECS
led_blink() {
    local r=$1 g=$2 b=$3 on=$4 off=$5
    stop_blink
    _led_set 0 0 0
    (
        while true; do
            _led_set "$r" "$g" "$b"
            sleep "$on"
            _led_set 0 0 0
            sleep "$off"
        done
    ) &
    BLINK_PID=$!
}

wifi_connected() {
    ip addr show wlan0 2>/dev/null | grep -q 'inet ' && \
    wpa_cli -i wlan0 status 2>/dev/null | grep -q 'wpa_state=COMPLETED'
}

case "${1:-}" in
    stop)
        led_solid 255 0 0
        sleep 1
        led_off
        exit 0
        ;;
esac

# ── Phase 1: solid blue — basic.target reached ────────────────────────────────
led_solid 0 0 255
sleep 3

# ── Phase 2: blue blink — services loading ────────────────────────────────────
led_blink 0 0 255 1 0.3

while ! systemctl is-active --quiet multi-user.target 2>/dev/null; do
    sleep 1
done

# ── Phase 3: green blink — services up, waiting for WiFi (min 5s) ────────────
led_blink 0 255 0 1 0.3
sleep 5

# ── Phase 4: event-driven WiFi status via netlink ────────────────────────────
update_wifi_led() {
    if wifi_connected; then
        led_solid 0 255 0
    else
        led_blink 255 255 0 1 0.3
    fi
}

update_wifi_led

ip monitor address link dev wlan0 | while IFS= read -r _line; do
    update_wifi_led
done
