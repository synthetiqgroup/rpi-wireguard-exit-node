#!/bin/bash
# =============================================================================
# manage.sh — Manage WireGuard client profiles on the RPi
# Run as root:
#   sudo bash manage.sh <command> [options]
#
# COMMANDS:
#   status                    Health check: WireGuard, DuckDNS, public IP, disk, uptime
#   list                      List all client profiles and their connection status
#   show <name>               Display a profile's .conf and QR code
#   add  <name> [name2] ...   Create one or more client profiles
#   remove <name> [name2] ... Remove one or more client profiles (-y to skip confirmation)
#   duckdns-token <token>     Update the DuckDNS token and test it immediately
#
# EXAMPLES:
#   sudo bash manage.sh status
#   sudo bash manage.sh list
#   sudo bash manage.sh show phone
#   sudo bash manage.sh add phone laptop
#   sudo bash manage.sh remove phone laptop
#   sudo bash manage.sh remove phone -y
#   sudo bash manage.sh duckdns-token a1b2c3d4-e5f6-7890-abcd-ef1234567890
#
# CONSTRAINTS:
#   - Profile names must be 15 characters or less (WireGuard interface name limit)
#   - Profile names must contain only letters, digits, underscores, or hyphens
#   - 1 profile = 1 device at a time (sharing causes disconnects)
# =============================================================================

set -e

VPN_USER="vpnuser"
CONFIGS_DIR="/home/${VPN_USER}/configs"

# --- colours (disabled if not a terminal) ------------------------------------
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' CYAN='' BOLD='' NC=''
fi

# =============================================================================
# Helpers
# =============================================================================

usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC}  sudo bash manage.sh <command> [options]"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  status                      Health check (WireGuard, DuckDNS, IP...)"
    echo "  list                        List all client profiles"
    echo "  show <name>                 Display a profile (.conf + QR code)"
    echo "  add  <name> [name2] ...     Create one or more profiles"
    echo "  remove <name> [name2] ...   Remove one or more profiles"
    echo "  duckdns-token <token>       Update the DuckDNS token"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  -y, --yes                   Skip confirmation on remove"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  sudo bash manage.sh status"
    echo "  sudo bash manage.sh list"
    echo "  sudo bash manage.sh show phone"
    echo "  sudo bash manage.sh add phone laptop"
    echo "  sudo bash manage.sh remove phone -y"
    echo "  sudo bash manage.sh duckdns-token a1b2c3d4-..."
    echo ""
    exit 1
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Error: this script must be run as root (sudo bash manage.sh ...)${NC}"
        exit 1
    fi
}

check_pivpn() {
    if ! command -v pivpn &>/dev/null; then
        echo -e "${RED}Error: PiVPN is not installed. Run setup.sh first.${NC}"
        exit 1
    fi
}

validate_name() {
    local name="$1"
    if [ ${#name} -gt 15 ]; then
        echo -e "${RED}Error: profile name '${name}' exceeds 15 characters.${NC}"
        return 1
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}Error: profile name '${name}' contains invalid characters (use letters, digits, _, -).${NC}"
        return 1
    fi
    return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_status() {
    echo ""
    echo -e "${BOLD}System status${NC}"
    echo "═════════════════════════════════════════"

    # Uptime
    echo -e "${CYAN}Uptime:${NC}         $(uptime -p 2>/dev/null || uptime)"

    # Disk usage
    local disk_usage
    disk_usage=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}')
    echo -e "${CYAN}Disk:${NC}           ${disk_usage}"

    # Public IP
    local pub_ip
    pub_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unreachable")
    echo -e "${CYAN}Public IP:${NC}      ${pub_ip}"

    echo ""
    echo -e "${BOLD}WireGuard${NC}"
    echo "─────────────────────────────────────────"

    # WireGuard service
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        echo -e "  Service:        ${GREEN}active${NC}"
    else
        echo -e "  Service:        ${RED}inactive${NC}"
    fi

    # Connected peers
    local peers
    peers=$(wg show wg0 2>/dev/null | grep -c "latest handshake" || echo "0")
    echo -e "  Connected:      ${peers} peer(s)"

    # WireGuard interface details — annotate peers with client names
    if command -v wg &>/dev/null; then
        echo ""

        # Build a map of public_key -> client_name from wg0.conf
        # PiVPN adds: ### begin <name> ### ... PublicKey = <key> ... ### end <name> ###
        declare -A peer_names
        local current_name=""
        if [ -f /etc/wireguard/wg0.conf ]; then
            while IFS= read -r line; do
                if [[ "$line" =~ ^###\ begin\ (.+)\ ### ]]; then
                    current_name="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^PublicKey\ *=\ *(.+) ]] && [ -n "$current_name" ]; then
                    peer_names["${BASH_REMATCH[1]}"]="$current_name"
                    current_name=""
                fi
            done < /etc/wireguard/wg0.conf
        fi

        # Display wg show, injecting client names after peer lines
        while IFS= read -r line; do
            echo "$line"
            if [[ "$line" =~ ^peer:\ (.+) ]]; then
                local pk="${BASH_REMATCH[1]}"
                if [ -n "${peer_names[$pk]+x}" ]; then
                    echo -e "  ${CYAN}name: ${peer_names[$pk]}${NC}"
                fi
            fi
        done < <(wg show wg0 2>/dev/null)
    fi

    echo ""
    echo -e "${BOLD}DuckDNS${NC}"
    echo "─────────────────────────────────────────"

    local duck_log="/home/${VPN_USER}/duckdns/duck.log"
    if [ -f "$duck_log" ]; then
        local duck_result
        duck_result=$(cat "$duck_log")
        if [ "$duck_result" = "OK" ]; then
            echo -e "  Last update:    ${GREEN}OK${NC}"
        else
            echo -e "  Last update:    ${RED}${duck_result}${NC}"
        fi
    else
        echo -e "  Last update:    ${YELLOW}no log found${NC}"
    fi

    # DuckDNS resolved IP vs actual public IP
    local duck_script="/home/${VPN_USER}/duckdns/duck.sh"
    if [ -f "$duck_script" ]; then
        local domain
        domain=$(grep -oP 'domains=\K[^&]+' "$duck_script" 2>/dev/null)
        if [ -n "$domain" ]; then
            local dns_ip
            dns_ip=$(dig +short "${domain}.duckdns.org" 2>/dev/null | head -1)
            echo -e "  DNS resolves:   ${domain}.duckdns.org → ${dns_ip:-unknown}"
            if [ "$dns_ip" = "$pub_ip" ]; then
                echo -e "  DNS match:      ${GREEN}✓ matches public IP${NC}"
            elif [ -n "$dns_ip" ]; then
                echo -e "  DNS match:      ${YELLOW}✗ DNS=${dns_ip} vs IP=${pub_ip}${NC}"
            fi
        fi
    fi

    echo ""
    echo -e "${BOLD}fail2ban${NC}"
    echo "─────────────────────────────────────────"

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "  Service:        ${GREEN}active${NC}"
        local banned
        banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
        echo -e "  Banned IPs:     ${banned:-0}"
    else
        echo -e "  Service:        ${RED}inactive${NC}"
    fi

    echo ""
}

cmd_show() {
    local name="$1"

    if [ -z "$name" ]; then
        # No name given — show interactive picker
        if [ ! -d "${CONFIGS_DIR}" ]; then
            echo -e "${RED}Error: no profiles found. Run 'manage.sh add' first.${NC}"
            exit 1
        fi

        local profiles=()
        for f in "${CONFIGS_DIR}"/*.conf; do
            [ -f "$f" ] || continue
            profiles+=("$(basename "$f" .conf)")
        done

        if [ ${#profiles[@]} -eq 0 ]; then
            echo -e "${RED}Error: no profiles found. Run 'manage.sh add' first.${NC}"
            exit 1
        fi

        echo ""
        echo -e "${BOLD}Available profiles:${NC}"
        local i=1
        for p in "${profiles[@]}"; do
            echo "  ${i}) ${p}"
            ((i++))
        done
        echo ""
        read -r -p "Select a profile [1-${#profiles[@]}]: " choice

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#profiles[@]} ]; then
            echo -e "${RED}Invalid selection.${NC}"
            exit 1
        fi

        name="${profiles[$((choice - 1))]}"
    fi

    local conf="${CONFIGS_DIR}/${name}.conf"

    if [ ! -f "$conf" ]; then
        echo -e "${RED}Error: profile '${name}' not found at ${conf}${NC}"
        exit 1
    fi

    # Display .conf
    echo ""
    echo -e "${BOLD}── ${name}.conf ──────────────────────────────${NC}"
    echo ""
    cat "$conf"
    echo ""
    echo -e "${BOLD}──────────────────────────────────────────────${NC}"

    # Display QR code
    echo ""
    echo -e "${BOLD}── QR code (scan with WireGuard app) ─────────${NC}"
    echo ""
    pivpn -qr "$name"
    echo ""
}

cmd_list() {
    echo ""
    echo -e "${BOLD}WireGuard client profiles${NC}"
    echo "─────────────────────────────────────────"
    pivpn -l
    echo ""

    # Also show config files on disk
    if [ -d "${CONFIGS_DIR}" ]; then
        local count
        count=$(find "${CONFIGS_DIR}" -maxdepth 1 -name "*.conf" 2>/dev/null | wc -l)
        echo -e "${CYAN}Config files in ${CONFIGS_DIR}: ${count}${NC}"
        if [ "$count" -gt 0 ]; then
            for f in "${CONFIGS_DIR}"/*.conf; do
                echo "  ${f}"
            done
        fi
    fi
    echo ""
}

cmd_add() {
    local names=("$@")

    if [ ${#names[@]} -eq 0 ]; then
        echo -e "${RED}Error: provide at least one profile name.${NC}"
        echo "  Usage: sudo bash manage.sh add <name> [name2] ..."
        exit 1
    fi

    local failed=0

    for name in "${names[@]}"; do
        echo ""
        if ! validate_name "$name"; then
            failed=1
            continue
        fi

        local conf="${CONFIGS_DIR}/${name}.conf"

        if [ -f "$conf" ]; then
            echo -e "${YELLOW}Profile '${name}' already exists, skipping.${NC}"
            continue
        fi

        echo -e "${CYAN}Creating profile '${name}'...${NC}"
        pivpn add -n "$name" -ip auto

        if [ -f "$conf" ]; then
            echo -e "${GREEN}✓ Profile '${name}' created.${NC}"
            echo ""
            echo -e "${BOLD}--- ${name}.conf (paste into your WireGuard client) ---${NC}"
            cat "$conf"
            echo -e "${BOLD}------------------------------------------------------${NC}"
        else
            echo -e "${RED}✗ Failed to create profile '${name}'.${NC}"
            failed=1
        fi
    done

    echo ""
    if [ "$failed" -ne 0 ]; then
        echo -e "${YELLOW}Some profiles could not be created — see errors above.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Done.${NC}"
}

cmd_remove() {
    local skip_confirm=false
    local names=()

    # Parse arguments: separate -y/--yes from profile names
    for arg in "$@"; do
        case "$arg" in
            -y|--yes) skip_confirm=true ;;
            -*) echo -e "${RED}Unknown option: ${arg}${NC}"; usage ;;
            *) names+=("$arg") ;;
        esac
    done

    if [ ${#names[@]} -eq 0 ]; then
        echo -e "${RED}Error: provide at least one profile name.${NC}"
        echo "  Usage: sudo bash manage.sh remove <name> [name2] ... [-y]"
        exit 1
    fi

    # Confirmation prompt (unless -y)
    if [ "$skip_confirm" = false ]; then
        echo ""
        echo -e "${YELLOW}The following profiles will be permanently removed:${NC}"
        for name in "${names[@]}"; do
            echo "  - ${name}"
        done
        echo ""
        read -r -p "Are you sure? [y/N] " answer
        case "$answer" in
            [yY]|[yY][eE][sS]) ;;
            *)
                echo "Aborted."
                exit 0
                ;;
        esac
    fi

    local failed=0

    for name in "${names[@]}"; do
        echo ""
        local conf="${CONFIGS_DIR}/${name}.conf"

        if [ ! -f "$conf" ]; then
            echo -e "${YELLOW}Profile '${name}' does not exist, skipping.${NC}"
            continue
        fi

        echo -e "${CYAN}Removing profile '${name}'...${NC}"
        echo "y" | pivpn remove "$name"

        if [ ! -f "$conf" ]; then
            echo -e "${GREEN}✓ Profile '${name}' removed.${NC}"
        else
            echo -e "${RED}✗ Failed to remove profile '${name}'.${NC}"
            failed=1
        fi
    done

    echo ""
    if [ "$failed" -ne 0 ]; then
        echo -e "${YELLOW}Some profiles could not be removed — see errors above.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Done.${NC}"
}

cmd_duckdns_token() {
    local new_token="$1"
    local duck_script="/home/${VPN_USER}/duckdns/duck.sh"

    if [ -z "$new_token" ]; then
        echo -e "${RED}Error: provide the new DuckDNS token.${NC}"
        echo "  Usage: sudo bash manage.sh duckdns-token <token>"
        exit 1
    fi

    if [ ! -f "$duck_script" ]; then
        echo -e "${RED}Error: ${duck_script} not found. Run setup.sh first.${NC}"
        exit 1
    fi

    # Replace the token in duck.sh
    sed -i "s|token=[^&]*&|token=${new_token}\&|" "$duck_script"
    echo -e "${GREEN}✓ Token updated in ${duck_script}${NC}"

    # Test immediately
    echo -e "${CYAN}Testing DuckDNS update...${NC}"
    sudo -u "${VPN_USER}" "$duck_script"
    local result
    result=$(cat /home/${VPN_USER}/duckdns/duck.log)

    if [ "$result" = "OK" ]; then
        echo -e "${GREEN}✓ DuckDNS responded OK — token is valid.${NC}"
    else
        echo -e "${RED}✗ DuckDNS responded: ${result}${NC}"
        echo -e "${YELLOW}Double-check your token at https://www.duckdns.org${NC}"
        exit 1
    fi
}

# =============================================================================
# Main
# =============================================================================

check_root
check_pivpn

case "${1:-}" in
    status)          cmd_status ;;
    list|ls)         cmd_list ;;
    show)            shift; cmd_show "$@" ;;
    add)             shift; cmd_add "$@" ;;
    remove|rm|del)   shift; cmd_remove "$@" ;;
    duckdns-token)   shift; cmd_duckdns_token "$@" ;;
    -h|--help|help)  usage ;;
    *)               usage ;;
esac
