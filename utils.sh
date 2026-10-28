#!/bin/bash
# =============================================================================
# utils.sh — Optional hardening extras for the WireGuard exit node
# Run by setup.sh when ENABLE_EXTRA_HARDENING=true (default). Not meant to be
# run standalone before setup.sh, since it relies on packages/users it creates.
#
# WHAT THIS SCRIPT DOES:
#   H1. Full system upgrade (apt full-upgrade + autoremove)
#   H2. Installs and configures fail2ban (progressive SSH banning)
#   H3. Schedules daily apt update + reboot at 3:00 AM
#   H4. Reboots the RPi at the end (5s delay, Ctrl+C to cancel)
#
# These were part of the original setup.sh and were split out here because
# they go beyond strict VPN-exit-node scope (SSH hardening, unattended
# reboots). Set ENABLE_EXTRA_HARDENING=false in setup.sh to skip this file.
# =============================================================================

set -e

echo ""
echo "=============================================="
echo "  Extra hardening (utils.sh)"
echo "=============================================="

# -----------------------------------------------------------------------------
# H1. Full system upgrade
# -----------------------------------------------------------------------------
echo ""
echo "[H1/H4] Full system upgrade..."
apt full-upgrade -y -qq
apt autoremove -y -qq
echo "  ✓ System fully upgraded"

# -----------------------------------------------------------------------------
# H2. fail2ban
#     Progressive SSH banning after 3 failed attempts:
#     1min -> 5min -> 25min -> ~2h -> up to 24h max
#     Covers both port 22 (LAN) and port 2222 (internet-facing via router NAT)
# -----------------------------------------------------------------------------
echo ""
echo "[H2/H4] Installing and configuring fail2ban..."

apt install -y fail2ban -qq

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1m
findtime = 10m
maxretry = 3

# Each subsequent ban multiplies duration by 5, up to 24h
bantime.increment  = true
bantime.multiplier = 5
bantime.maxtime    = 24h

[sshd]
enabled  = true
port     = 22,2222
filter   = sshd
backend  = systemd
maxretry = 3
EOF

systemctl enable fail2ban > /dev/null
systemctl restart fail2ban
echo "  ✓ fail2ban configured (3 attempts -> progressive ban up to 24h)"

# -----------------------------------------------------------------------------
# H3. Cron jobs -- apt update + reboot
#     Root cron -- refresh package list then reboot 5 minutes later so the
#     new kernel/libs/services from the daily upgrade take effect.
# -----------------------------------------------------------------------------
echo ""
echo "[H3/H4] Scheduling daily apt update + reboot..."

(crontab -l 2>/dev/null | grep -v "apt update" | grep -v "/sbin/reboot" || true; \
 echo "0 3 * * * apt update -qq"; \
 echo "5 3 * * * /sbin/reboot") | crontab -

echo "  ✓ apt update : daily at 3:00 AM"
echo "  ✓ reboot     : daily at 3:05 AM"

# -----------------------------------------------------------------------------
# H4. Reboot
#     Clean state after apt full-upgrade (new kernel, libs, services).
#     Verifies iptables rules and WireGuard survive a reboot.
# -----------------------------------------------------------------------------
echo ""
echo "[H4/H4] Rebooting in 5 seconds... (Ctrl+C to cancel)"
sleep 5
reboot
