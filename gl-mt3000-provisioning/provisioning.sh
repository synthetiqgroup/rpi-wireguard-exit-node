#!/bin/sh

set -e

# ============================================================
# GL.iNet GL-MT3000 / Beryl AX
# Firmware 4.9.0
# ============================================================

WIFI_SSID="Skynet Global Network"
WIFI_PASSWORD='CHANGE_ME'  # set your Wi-Fi password before running

# ============================================================
# Wi-Fi
# ============================================================

echo "=== Wi-Fi ==="

uci set wireless.wifi2g.ssid="$WIFI_SSID"
uci set wireless.wifi2g.key="$WIFI_PASSWORD"

uci set wireless.wifi5g.ssid="$WIFI_SSID"
uci set wireless.wifi5g.key="$WIFI_PASSWORD"

# ============================================================
# IPv6 — désactivation complète
# ============================================================

echo "=== IPv6 ==="

# LAN
uci set network.lan.ip6assign='0'
uci set network.lan.delegate='0'

uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.ndp='disabled'

# WAN
uci set network.wan.ipv6='0'

# Interfaces IPv6
uci set network.wan6.disabled='1'
uci set network.wwan6.disabled='1'
uci set network.tethering6.disabled='1'

# Modem
uci set network.modem_1_1_s1_6.disabled='1'
uci set network.modem_2_1_s1_6.disabled='1'

# DNS : ne pas fournir d'AAAA aux clients
uci set dhcp.@dnsmasq[0].filter_aaaa='1'

# ============================================================
# Sauvegarde
# ============================================================

echo "=== Commit ==="

uci commit wireless
uci commit network
uci commit dhcp

# ============================================================
# Application
# ============================================================

echo "=== Applying ==="

wifi reload
/etc/init.d/dnsmasq restart
/etc/init.d/network restart

sleep 3

# ============================================================
# Vérification
# ============================================================

echo
echo "=== IPv6 addresses ==="
ip -6 addr

echo
echo "=== IPv6 routes ==="
ip -6 route

echo
echo "=== Provisioning complete ==="
