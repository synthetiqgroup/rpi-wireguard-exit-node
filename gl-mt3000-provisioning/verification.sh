#!/bin/sh

echo "========================================"
echo " GL-MT3000 - PROVISIONING CHECK"
echo "========================================"

echo
echo "=== 1. FIRMWARE ==="
cat /etc/glversion 2>/dev/null || true
ubus call system board 2>/dev/null | grep -E '"model"|"release"|"revision"' || true

echo
echo "=== 2. WIFI STATUS ==="
wifi status

echo
echo "=== 3. WIFI INFO ==="
iwinfo

echo
echo "=== 4. WIFI CONFIG - SSID / SECURITY ==="
uci show wireless | grep -E "wifi2g\.(ssid|encryption|hidden)|wifi5g\.(ssid|encryption|hidden)"

echo
echo "=== 5. IPV6 ADDRESSES - ROUTER ==="
ip -6 addr

echo
echo "=== 6. IPV6 ROUTES - ROUTER ==="
ip -6 route

echo
echo "=== 7. NETWORK IPV6 CONFIG ==="
uci show network | grep -E "ip6|delegate|wan6|wwan6|tethering6|modem.*6"

echo
echo "=== 8. DHCP / RA / NDP / DNSMASQ ==="
uci show dhcp | grep -E "dhcpv6|ra|ndp|filter_aaaa"

echo
echo "=== 9. WAN STATUS ==="
ifstatus wan

echo
echo "=== 10. WAN6 STATUS ==="
ifstatus wan6

echo
echo "=== 11. UNSAVED UCI CHANGES ==="
uci changes

echo
echo "========================================"
echo " CHECK COMPLETE"
echo "========================================"
