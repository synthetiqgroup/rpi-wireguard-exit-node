# GL.iNet GL-MT3000 — Provisioning

Provisioning and verification scripts for the **GL.iNet GL-MT3000 (Beryl AX)**.

Target environment:

* **Device:** GL.iNet GL-MT3000 / Beryl AX
* **Firmware:** 4.9.0
* **OpenWrt:** 21.02-SNAPSHOT
* **Kernel:** 5.4.211
* **Architecture:** aarch64_cortex-a53
* **Router IP:** `192.168.8.1`

## Repository structure

```text
.
├── README.md
├── provisioning.sh
└── verification.sh
```

Keep these files outside the router. A factory reset removes the scripts stored under `/root`.

---

## 1. Connect to the router

The router must be reachable at:

```text
192.168.8.1
```

Connect over SSH:

```bash
ssh root@192.168.8.1
```

The default/root password is the password configured on the router.

> No package installation is required. In particular, `nano` is not required: after a factory reset the router may not have Internet access.

---

## 2. Copy the provisioning script

First, edit `provisioning.sh` and replace the `WIFI_PASSWORD='CHANGE_ME'` placeholder with your Wi-Fi password (and adjust `WIFI_SSID` if needed). Do not commit the real password.

From the Mac, in the repository directory:

```bash
scp -O provisioning.sh root@192.168.8.1:/root/
```

The `-O` option is important.

Recent versions of OpenSSH on macOS use SFTP by default for `scp`. The GL-MT3000 firmware does not provide `/usr/libexec/sftp-server`, so standard `scp` fails with:

```text
ash: /usr/libexec/sftp-server: not found
scp: Connection closed
```

`-O` forces the legacy SCP protocol supported by the router.

---

## 3. Run the provisioning

SSH into the router:

```bash
ssh root@192.168.8.1
```

Make sure the script is present:

```bash
ls -l /root/provisioning.sh
```

Run it:

```bash
sh /root/provisioning.sh
```

The script configures:

### Wi-Fi

* Same SSID on 2.4 GHz and 5 GHz
* Same Wi-Fi password on both bands
* Existing WPA2 configuration is preserved
* Main Wi-Fi remains on the `lan` network

### IPv6

IPv6 is disabled as far as possible through the router configuration:

* No IPv6 prefix delegation on LAN
* No IPv6 router advertisements
* No IPv6 DHCP service
* No NDP service
* IPv6 WAN interface disabled
* IPv6 WWAN interface disabled
* IPv6 tethering interface disabled
* Modem IPv6 interfaces disabled
* DNSMasq configured to filter AAAA records

The objective is to prevent IPv6 connectivity/leaks when the router is intended to operate exclusively over IPv4.

---

## 4. Verify the configuration

Copy the verification script from the Mac:

```bash
scp -O verification.sh root@192.168.8.1:/root/
```

SSH into the router:

```bash
ssh root@192.168.8.1
```

Run:

```bash
sh /root/verification.sh
```

---

## 5. Expected Wi-Fi state

The verification should show both main radios as active.

Expected configuration:

```text
2.4 GHz → SSID: Skynet Global Network
5 GHz   → SSID: Skynet Global Network
```

Both should be:

```text
up: true
disabled: false
autostart: true
```

The exact channel may vary because the radios use automatic channel selection.

---

## 6. Expected IPv6 state

Check IPv6 addresses:

```bash
ip -6 addr
```

The router should have no global IPv6 address.

A loopback address such as:

```text
::1/128
```

is normal.

Check IPv6 routes:

```bash
ip -6 route
```

There should be no usable IPv6 default route.

The configuration can also be inspected with:

```bash
uci show network | grep -E "ip6|delegate|wan6|wwan6|tethering6|modem.*6"
```

and:

```bash
uci show dhcp | grep -E "dhcpv6|ra|ndp|filter_aaaa"
```

---

## 7. Check for unsaved UCI changes

Run:

```bash
uci changes
```

Expected result:

```text
```

An empty result means there are no uncommitted UCI changes.

---

## 8. Client-side IPv4 / IPv6 test

From a client connected to the router:

### IPv4

```bash
curl -4 https://ifconfig.co
```

This should return the public IPv4 address.

### IPv6

```bash
curl -6 https://ifconfig.co
```

This should fail because IPv6 connectivity is disabled.

You can also check DNS behavior:

```bash
nslookup google.com
```

The router should not provide IPv6 connectivity even if a DNS response contains IPv6 information.

---

## 9. Factory reset considerations

A factory reset restores the router's configuration to its factory state.

It also removes files stored under:

```text
/root/
```

Therefore:

```text
/root/provisioning.sh
/root/verification.sh
```

should **not** be considered persistent configuration.

The scripts should remain stored in this Git repository and be copied back to the router after a reset.

Recommended workflow after a factory reset:

```bash
scp -O provisioning.sh root@192.168.8.1:/root/
scp -O verification.sh root@192.168.8.1:/root/
```

Then:

```bash
ssh root@192.168.8.1
```

and:

```bash
sh /root/provisioning.sh
```

followed by:

```bash
sh /root/verification.sh
```

No Internet connection is required to restore or execute these scripts.

---

## 10. Reprovisioning from the repository

From the Mac:

```bash
scp -O provisioning.sh root@192.168.8.1:/root/
scp -O verification.sh root@192.168.8.1:/root/
```

Then:

```bash
ssh root@192.168.8.1
```

Run:

```bash
sh /root/provisioning.sh
```

Verify:

```bash
sh /root/verification.sh
```

This provides a reproducible provisioning workflow independently of the router's persistent filesystem.

---

## 11. Important note about `scp`

Always use:

```bash
scp -O
```

rather than:

```bash
scp
```

with this firmware.

The router's SSH server supports the legacy SCP protocol but does not include the SFTP server expected by modern OpenSSH clients.

The warning:

```text
WARNING: connection is not using a post-quantum key exchange algorithm.
```

comes from the modern OpenSSH client on the Mac. It is separate from the SCP failure and does not prevent the transfer.

---

## 12. Future configuration

The provisioning script is intended to remain the source of truth for router configuration.

Additional configuration can be added to it over time, for example:

* WireGuard
* VPN kill switch
* IPv4-only firewall policy
* DNS configuration
* firewall hardening
* routing policy
* monitoring

Any change should ideally be:

1. Added to `provisioning.sh`
2. Committed to Git
3. Applied to the router
4. Added to `verification.sh` where appropriate
5. Tested after a clean reset when practical

This keeps the router reproducible rather than relying on undocumented manual changes.