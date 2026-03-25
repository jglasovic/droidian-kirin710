#!/bin/sh
# Performance tuning for headless server — battery life is not a concern

# ── CPU: force performance governor on all cores ──
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$cpu" 2>/dev/null
done

# ── CPU: ensure all cores stay online ──
for cpu in /sys/devices/system/cpu/cpu*/online; do
    echo 1 > "$cpu" 2>/dev/null
done

# ── I/O scheduler: deadline for better throughput ──
for dev in /sys/block/*/queue/scheduler; do
    echo deadline > "$dev" 2>/dev/null
done

# ── VM: optimize for server workload ──
echo 10 > /proc/sys/vm/swappiness                 # prefer keeping processes in RAM
echo 40 > /proc/sys/vm/dirty_ratio                 # buffer up to 40% RAM before sync
echo 20 > /proc/sys/vm/dirty_background_ratio      # start background flush at 20%
echo 50 > /proc/sys/vm/vfs_cache_pressure          # keep filesystem metadata cached longer

# ── Network: larger TCP buffers for WireGuard/file serving ──
echo "4096 87380 6291456" > /proc/sys/net/ipv4/tcp_rmem      # min default max (6MB)
echo "4096 65536 6291456" > /proc/sys/net/ipv4/tcp_wmem      # min default max (6MB)
echo 6291456 > /proc/sys/net/core/rmem_max
echo 6291456 > /proc/sys/net/core/wmem_max
echo 1 > /proc/sys/net/ipv4/tcp_window_scaling
echo 1 > /proc/sys/net/ipv4/tcp_timestamps
echo 1 > /proc/sys/net/ipv4/tcp_sack

echo "Performance tuning applied" > /dev/kmsg 2>/dev/null || true
