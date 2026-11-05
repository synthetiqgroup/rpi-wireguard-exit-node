#!/bin/bash
# =============================================================================
# setup.sh — Full Raspberry Pi setup for WireGuard VPN exit node
# Run as root on a fresh Raspberry Pi OS Lite (64-bit):
#   sudo bash setup.sh
#
# USE CASE:
#   You leave the RPi at home connected to your ISP router.
#   When travelling abroad, some content may be geo-restricted or unavailable.
#   By connecting a WireGuard client to this RPi, all your traffic exits through
#   your home IP — accessing content as if you were at home.
#   Example client: GL.iNet GL-MT3000 (Beryl AX) travel router, but any
#   WireGuard-compatible device or app works (phone, laptop, other router...).
#
# WHAT THIS SCRIPT DOES (in order):
#   1.  Refreshes package lists (apt update)
#   2.  Creates a dedicated VPN user (vpnuser) with sudo rights
#   3.  Installs dependencies (curl, cron, iptables-persistent, unattended-upgrades)
#   4.  Configures dynv6 update script (dynamic DNS)
#   5.  Enables IP forwarding (required for WireGuard to route traffic)
#       and disables IPv6 on all interfaces (permanent, this setup is IPv4-only)
#   6.  Installs PiVPN / WireGuard in unattended mode
#   7.  Fixes the iptables NAT rule for WireGuard (PiVPN bug workaround)
#       and makes iptables rules persistent across reboots
#   8.  Creates the WireGuard client profile(s)
#   9.  Configures logrotate for dynv6 logs + limits journald to 100MB
#   10. Schedules dynv6 cron job (every 5 min, optional)
#   11. Runs utils.sh (optional, ENABLE_EXTRA_HARDENING=true by default):
#       full apt upgrade, fail2ban, daily apt update + reboot cron, reboot.
#
# WHAT THIS SCRIPT DOES NOT DO:
#   - Configure the WireGuard client device (paste the generated .conf manually)
#   - Configure your ISP router (DHCP reservation + port forwarding — see below)
#
# ROUTER CONFIGURATION (manual):
#   (Router admin is often at 192.168.1.1 or 192.168.0.1 — check your
#    router's documentation if you're unsure of the address)
#   1. DHCP static lease — so the RPi always gets the same local IP:
#      Router admin -> DHCP settings
#      -> Add a static lease for the RPi MAC address -> <RPi_LOCAL_IP>
#
#   2. NAT/PAT port forwarding — so traffic from the internet reaches the RPi:
#      Router admin -> NAT / Port forwarding
#      -> WireGuard : 51820 UDP (external) -> <RPi_LOCAL_IP>:51820 (internal)
#      (Adjust the port number if you changed WG_PORT above)
#
# HOW TO GET YOUR DYNV6 HOSTNAME AND TOKEN:
#   1. Go to https://dynv6.com and sign in
#   2. Create a zone (e.g. "my-rpi" under one of the free domains such as
#      dynv6.net or dns.navy) -> you get my-rpi.dynv6.net
#   3. Get your HTTP token at https://dynv6.com/keys (section "HTTP Tokens")
#   4. Replace DYNV6_TOKEN and DYNV6_HOSTNAME below with your values
#
# TO RENEW / REPLACE TOKEN:
#   - Create a new token at https://dynv6.com/keys
#   - Run: sudo bash manage.sh dynv6-token <new-token>
#     (or update DYNV6_TOKEN below and re-run this script)
#
# PIVPN UNATTENDED MODE:
#   PiVPN supports --unattended with a setupVars.conf file (discovered from
#   https://github.com/pivpn/pivpn/blob/master/auto_install/install.sh).
#   This script generates /tmp/pivpn-unattended.conf automatically.
#   WireGuard subnet is randomised by PiVPN and auto-detected after install.
# =============================================================================

set -e

# Log all output to file while still displaying on screen
LOG_FILE="/var/log/setup-rpi.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "--- Setup started: $(date) ---"

# =============================================================================
# CONFIGURATION -- update these values before running
# =============================================================================

# dynv6 -- get token at https://dynv6.com/keys
DYNV6_TOKEN="YOUR-DYNV6-TOKEN-HERE"            # HTTP token from https://dynv6.com/keys
DYNV6_HOSTNAME="your-zone.dynv6.net"           # full hostname, e.g. "my-rpi.dns.navy"

# VPN user -- owns dynv6 scripts and WireGuard config
# PiVPN will also be installed under this user
VPN_USER="vpnuser"

# WireGuard port
WG_PORT=51820

# WireGuard client profile names (used by pivpn add)
# Add as many as you need, space-separated: ("router" "laptop" "phone")
# In our use case we use a GL.iNet GL-MT3000 (Beryl AX) travel router as the
# primary client — paste the generated .conf into its WireGuard client settings.
# 1 profile = 1 device at a time (each profile has a unique key pair;
# sharing a profile between devices will cause disconnects)
# Profile names must be 15 characters or less (WireGuard interface name limit)
WG_CLIENT_NAMES=("client1")

# DNS servers pushed to VPN clients
VPN_DNS1="1.1.1.1"
VPN_DNS2="1.0.0.1"

# Network interface facing the internet (eth0 on wired RPi)
WAN_IFACE="eth0"

# dynv6 cron -- set to false if another service on this machine already
# updates the SAME dynv6 hostname (e.g. rpi-docker-webhost).
# The update script is always created (for manual testing via manage.sh).
# Only the cron job is skipped when set to false.
DYNV6_CRON=true

# Extra hardening -- runs utils.sh at the end of setup (full apt upgrade,
# fail2ban, daily apt update + reboot cron, and a final reboot).
# Set to false to keep this script strictly VPN-exit-node scoped.
ENABLE_EXTRA_HARDENING=true

# =============================================================================
# END OF CONFIGURATION
# =============================================================================

DYNV6_DIR="/home/${VPN_USER}/dynv6"
WG_SUBNET=""   # populated automatically after PiVPN install in step 7

echo "=============================================="
echo "  RPi VPN Setup"
echo "=============================================="
echo "  dynv6 hostname  : ${DYNV6_HOSTNAME}"
echo "  VPN user        : ${VPN_USER}"
echo "  Client profiles : ${WG_CLIENT_NAMES[*]}"
echo "  WireGuard subnet: (auto-detected after install)"
echo "=============================================="

# ------------------------------------------------------------------------------
# 1. Refresh package lists
# ------------------------------------------------------------------------------
echo ""
echo "[1/10] Refreshing package lists..."
apt update -qq
UPDATES_AVAILABLE=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
echo "  ✓ Package lists updated"

# ------------------------------------------------------------------------------
# 2. Create dedicated VPN user
#    - Owns all VPN-related scripts and config
#    - Has sudo rights (needed to manage WireGuard)
#    - No password login (access via SSH key or su from another user)
# ------------------------------------------------------------------------------
echo ""
echo "[2/10] Creating VPN user '${VPN_USER}'..."

if id "${VPN_USER}" &>/dev/null; then
    echo "  User ${VPN_USER} already exists, skipping creation"
else
    useradd -m -s /bin/bash "${VPN_USER}"
    usermod -aG sudo "${VPN_USER}"
    # Lock password login -- SSH key access only
    passwd -l "${VPN_USER}"
    echo "  ✓ User ${VPN_USER} created (sudo, no password login)"
fi

# ------------------------------------------------------------------------------
# 3. Install dependencies
# ------------------------------------------------------------------------------
echo ""
echo "[3/10] Installing dependencies..."
# Pre-answer iptables-persistent debconf prompts to avoid interactive dialogs
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
apt install -y curl cron iptables-persistent unattended-upgrades -qq
echo "  ✓ Dependencies installed"

# ------------------------------------------------------------------------------
# 4. dynv6
#    Updates the public IPv4 on dynv6 every 5 minutes via cron.
#    curl -4 + ipv4=auto: dynv6 records the source address of the request,
#    forced over IPv4 so it is the home IPv4 even if the RPi has IPv6.
#    Script (contains the token, mode 700) and logs are owned by VPN_USER.
# ------------------------------------------------------------------------------
echo ""
echo "[4/10] Configuring dynv6..."

mkdir -p "${DYNV6_DIR}"

cat > "${DYNV6_DIR}/dynv6.sh" << EOF
#!/bin/bash
DYNV6_HOSTNAME="${DYNV6_HOSTNAME}"
DYNV6_TOKEN="${DYNV6_TOKEN}"
curl -4 -s --max-time 30 "https://dynv6.com/api/update?hostname=\${DYNV6_HOSTNAME}&token=\${DYNV6_TOKEN}&ipv4=auto" > ${DYNV6_DIR}/dynv6.log 2>&1
EOF

chmod 700 "${DYNV6_DIR}/dynv6.sh"
chown -R "${VPN_USER}:${VPN_USER}" "${DYNV6_DIR}"

# Test immediately -- dynv6 answers "addresses updated" or "addresses unchanged"
sudo -u "${VPN_USER}" "${DYNV6_DIR}/dynv6.sh"
RESULT=$(cat "${DYNV6_DIR}/dynv6.log")

if [[ "$RESULT" =~ ^addresses\ (updated|unchanged) ]]; then
    echo "  ✓ dynv6 OK -- ${DYNV6_HOSTNAME} points to $(curl -4 -s https://api.ipify.org)"
else
    echo "  error dynv6 error: $RESULT"
    echo "  Check DYNV6_TOKEN and DYNV6_HOSTNAME, then re-run."
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. IP forwarding + disable IPv6
#    IP forwarding required for WireGuard to forward packets from VPN clients
#    to the internet. Must be done BEFORE PiVPN install so it is in place when
#    PiVPN configures wg0.
#    IPv6 is disabled on all interfaces to prevent IPv6 leaks: this setup is
#    IPv4-only end to end (WireGuard, dynv6, DNS servers, port forwarding),
#    so any IPv6 traffic would otherwise bypass the tunnel entirely.
#    Settings go to /etc/sysctl.d/: Debian 13 (trixie) no longer reads
#    /etc/sysctl.conf at boot. Lines left there by older versions are removed.
#    NetworkManager profiles are also set to ipv6.method=disabled (see below).
# ------------------------------------------------------------------------------
echo ""
echo "[5/10] Enabling IP forwarding and disabling IPv6..."

SYSCTL_CONF="/etc/sysctl.d/99-wireguard-exit-node.conf"
cat > "${SYSCTL_CONF}" << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

if [ -f /etc/sysctl.conf ]; then
    sed -i -E '/^net\.ipv4\.ip_forward=1$/d; /^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6=1$/d' /etc/sysctl.conf
fi

sysctl -p "${SYSCTL_CONF}" > /dev/null

# NetworkManager (default on Raspberry Pi OS since bookworm) re-enables IPv6
# on the interfaces it manages (ipv6.method=auto), overriding the sysctl above.
# Disable IPv6 on every ethernet / Wi-Fi connection profile it knows.
if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager; then
    while IFS=: read -r NM_UUID NM_TYPE; do
        case "${NM_TYPE}" in
            802-3-ethernet|802-11-wireless) ;;
            *) continue ;;
        esac
        if [ "$(nmcli -g ipv6.method connection show "${NM_UUID}")" != "disabled" ]; then
            nmcli connection modify "${NM_UUID}" ipv6.method disabled
            echo "  ✓ IPv6 disabled in NetworkManager profile $(nmcli -g connection.id connection show "${NM_UUID}")"
        fi
    done < <(nmcli -g UUID,TYPE connection show)
    # Apply now on the WAN interface (IPv4 settings unchanged, no disconnect)
    nmcli device reapply "${WAN_IFACE}" > /dev/null 2>&1 || true
fi
echo "  ✓ IP forwarding enabled"
echo "  ✓ IPv6 disabled on all interfaces (permanent)"

# ------------------------------------------------------------------------------
# 6. PiVPN / WireGuard -- unattended install
#    PiVPN supports --unattended mode via a setupVars.conf file.
#    Source: https://github.com/pivpn/pivpn/blob/master/auto_install/install.sh
#
#    Key variables:
#      VPN          : "wireguard" or "openvpn"
#      install_user : user that will own the VPN config
#      IPv4dev      : network interface (eth0)
#      pivpnPORT    : WireGuard listen port
#      pivpnDNS1/2  : DNS servers pushed to clients
#      pivpnHOST    : public DNS name or IP clients use to reach this server
#
#    PiVPN randomises the WireGuard subnet automatically -- no need to set it here.
#    The subnet is auto-detected in step 7 after install.
# ------------------------------------------------------------------------------
echo ""
echo "[6/10] Installing PiVPN / WireGuard (unattended)..."

if [ -f /etc/wireguard/wg0.conf ]; then
    echo "  WireGuard already installed, skipping PiVPN install."
    # Keep the hostname used for new profiles in sync with DYNV6_HOSTNAME
    PIVPN_VARS="/etc/pivpn/wireguard/setupVars.conf"
    if [ -f "${PIVPN_VARS}" ] && ! grep -q "^pivpnHOST=${DYNV6_HOSTNAME}$" "${PIVPN_VARS}"; then
        sed -i "s|^pivpnHOST=.*|pivpnHOST=${DYNV6_HOSTNAME}|" "${PIVPN_VARS}"
        echo "  ✓ PiVPN hostname updated to ${DYNV6_HOSTNAME} (new profiles only)"
    fi
else
    cat > /tmp/pivpn-unattended.conf << EOF
VPN=wireguard
install_user=${VPN_USER}
IPv4dev=${WAN_IFACE}
pivpnPORT=${WG_PORT}
pivpnDNS1=${VPN_DNS1}
pivpnDNS2=${VPN_DNS2}
pivpnHOST=${DYNV6_HOSTNAME}
pivpnPERSISTENTKEEPALIVE=25
EOF

    curl -sSfL https://install.pivpn.io | bash /dev/stdin \
        --unattended /tmp/pivpn-unattended.conf

    rm -f /tmp/pivpn-unattended.conf
    echo "  ✓ PiVPN / WireGuard installed"
fi

# ------------------------------------------------------------------------------
# 7. iptables NAT rule
#    PiVPN has a known bug: it generates a MASQUERADE rule with a hardcoded
#    subnet (e.g. 10.116.54.0/24) that does not match the actual wg0 subnet.
#    This section auto-detects the correct subnet from wg0.conf, removes any
#    wrong rule, and installs the correct one.
#    Safe to re-run after PiVPN install.
# ------------------------------------------------------------------------------
echo ""
echo "[7/10] Fixing iptables NAT rule for WireGuard..."

# Auto-detect subnet from wg0.conf if not set manually
if [ -z "${WG_SUBNET}" ]; then
    if [ -f /etc/wireguard/wg0.conf ]; then
        # Extract the Address line (e.g. "Address = 10.198.60.1/24,...")
        # Take only the IPv4 part, then convert host address to network address
        WG_ADDR=$(grep "^Address" /etc/wireguard/wg0.conf | head -1 \
            | awk '{print $3}' | cut -d',' -f1 | grep -v ':')
        # Convert e.g. 10.198.60.1/24 -> 10.198.60.0/24
        WG_SUBNET=$(python3 -c \
            "import ipaddress; print(str(ipaddress.ip_interface('${WG_ADDR}').network))")
        echo "  Auto-detected WireGuard subnet: ${WG_SUBNET}"
    else
        echo "  WireGuard not installed yet — skipping iptables rule."
        echo "  Re-run this script after PiVPN install to apply the NAT rule."
        WG_SUBNET=""
    fi
fi

if [ -n "${WG_SUBNET}" ]; then
    # Remove any existing MASQUERADE rule that does not match the correct subnet
    WRONG_LINE=$(iptables -t nat -L POSTROUTING --line-numbers 2>/dev/null \
        | grep MASQUERADE | grep -v "${WG_SUBNET}" | awk '{print $1}' | head -1)
    if [ -n "$WRONG_LINE" ]; then
        iptables -t nat -D POSTROUTING "$WRONG_LINE"
        echo "  Removed incorrect MASQUERADE rule (line ${WRONG_LINE})"
    fi

    # Add correct rule if not already present
    if ! iptables -t nat -C POSTROUTING -s "${WG_SUBNET}" -o "${WAN_IFACE}" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "${WG_SUBNET}" -o "${WAN_IFACE}" -j MASQUERADE
        echo "  ✓ MASQUERADE rule added for ${WG_SUBNET} via ${WAN_IFACE}"
    else
        echo "  ✓ Correct MASQUERADE rule already present"
    fi

    # Persist rules across reboots
    netfilter-persistent save > /dev/null
    echo "  ✓ iptables rules saved (persistent across reboots)"
fi

# ------------------------------------------------------------------------------
# 8. WireGuard client profiles
#    Generates .conf files to paste into the WireGuard clients.
#    Profiles: WG_CLIENT_NAMES array. Client IP: first available in the WireGuard subnet.
#    AllowedIPs also covers ::/0 so IPv6 traffic is tunneled (and dropped, not
#    leaked) instead of bypassing the VPN over the client's native IPv6.
# ------------------------------------------------------------------------------
echo ""
echo "[8/10] Creating WireGuard client profiles..."

for CLIENT_NAME in "${WG_CLIENT_NAMES[@]}"; do
    CLIENT_CONF="/home/${VPN_USER}/configs/${CLIENT_NAME}.conf"
    if [ -f "${CLIENT_CONF}" ]; then
        echo "  Profile already exists: ${CLIENT_CONF}, skipping."
    else
        if command -v pivpn &>/dev/null; then
            pivpn add -n "${CLIENT_NAME}" -ip auto
            # Force IPv6 traffic through the tunnel too (server drops it, IPv6
            # is disabled) so the client can't leak it outside the VPN.
            if ! grep -q "::/0" "${CLIENT_CONF}"; then
                sed -i "s/^AllowedIPs = 0.0.0.0\/0$/AllowedIPs = 0.0.0.0\/0, ::\/0/" "${CLIENT_CONF}"
            fi
            echo "  ✓ Profile created: ${CLIENT_CONF}"
            echo ""
            echo "  --- ${CLIENT_NAME} config (paste into VPN -> WireGuard Client -> Add Profiles -> Manually) ---"
            cat "${CLIENT_CONF}"
            echo "  ---------------------------------------------------------------------------------------"
        else
            echo "  PiVPN not found, skipping profile creation."
        fi
    fi
done

# ------------------------------------------------------------------------------
# 9. Log management
#    - logrotate: rotate dynv6.log daily, keep 7 days compressed
#    - journald: cap total log size at 100MB (default is 10% of disk)
# ------------------------------------------------------------------------------
echo ""
echo "[9/10] Configuring log rotation..."

cat > /etc/logrotate.d/dynv6 << EOF
${DYNV6_DIR}/dynv6.log {
    su ${VPN_USER} ${VPN_USER}
    rotate 7
    daily
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

# Cap journald at 100MB
if grep -q "^SystemMaxUse=" /etc/systemd/journald.conf; then
    sed -i "s/^SystemMaxUse=.*/SystemMaxUse=100M/" /etc/systemd/journald.conf
else
    sed -i 's/#SystemMaxUse=/SystemMaxUse=100M/' /etc/systemd/journald.conf
fi
systemctl restart systemd-journald

echo "  ✓ logrotate configured for dynv6 logs (7 days, compressed)"
echo "  ✓ journald capped at 100MB"

# ------------------------------------------------------------------------------
# 10. Cron job
#     dynv6 runs as VPN_USER for proper file ownership.
#     Skipped if DYNV6_CRON=false (another service already updates the hostname).
# ------------------------------------------------------------------------------
echo ""
echo "[10/10] Configuring dynv6 cron job..."

if [ "${DYNV6_CRON}" = "true" ]; then
    # dynv6 cron -- runs as VPN_USER
    (crontab -u "${VPN_USER}" -l 2>/dev/null | grep -v "dynv6.sh" || true; \
     echo "*/5 * * * * ${DYNV6_DIR}/dynv6.sh") | crontab -u "${VPN_USER}" -
    echo "  ✓ dynv6 update : every 5 minutes (runs as ${VPN_USER})"
else
    echo "  ⏭ dynv6 cron skipped (DYNV6_CRON=false)"
    echo "    Another service on this machine already updates ${DYNV6_HOSTNAME}"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "=============================================="
echo "  SETUP COMPLETE"
echo "=============================================="
echo ""
echo "  VPN user        : ${VPN_USER}"
echo "  dynv6 hostname  : ${DYNV6_HOSTNAME}"
echo "  Public IP       : $(curl -4 -s https://api.ipify.org)"
echo "  RPi local IP    : ${LOCAL_IP}"
echo "  WireGuard subnet: ${WG_SUBNET}"
echo ""
if [ "${UPDATES_AVAILABLE}" -gt 0 ] 2>/dev/null; then
    echo "  ⚠ ${UPDATES_AVAILABLE} package update(s) available."
    echo "    Run 'sudo apt upgrade' to install them."
    echo ""
fi
echo "  REMAINING MANUAL STEPS:"
echo ""
echo "  1. On your router admin panel -> NAT/PAT (port forwarding), add:"
echo "       ${WG_PORT} UDP -> ${LOCAL_IP}  (WireGuard)"
if [ "${ENABLE_EXTRA_HARDENING}" = "true" ]; then
    echo "       2222  TCP -> ${LOCAL_IP}  (SSH, protected by fail2ban)"
fi
echo ""
echo "  2. Client profiles:"
for CLIENT_NAME in "${WG_CLIENT_NAMES[@]}"; do
    CLIENT_CONF="/home/${VPN_USER}/configs/${CLIENT_NAME}.conf"
    if [ -f "${CLIENT_CONF}" ]; then
        echo "     ✓ ${CLIENT_NAME} -- ready (paste the config shown above into your WireGuard client)"
    else
        echo "     ✗ ${CLIENT_NAME} -- not created. Run: pivpn add -n ${CLIENT_NAME} -ip auto"
    fi
done
echo ""
if [ "${ENABLE_EXTRA_HARDENING}" != "true" ]; then
    echo "  It is strongly recommended you reboot to verify that"
    echo "  WireGuard and iptables rules persist across reboots."
fi
echo "=============================================="

# -----------------------------------------------------------------------------
# Extra hardening (optional)
#   Runs after the summary since it ends with a reboot.
# -----------------------------------------------------------------------------
if [ "${ENABLE_EXTRA_HARDENING}" = "true" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "${SCRIPT_DIR}/utils.sh"
fi
