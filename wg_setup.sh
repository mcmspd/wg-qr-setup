#!/usr/bin/env bash
#
# Automated WireGuard QR Code Configurator for CachyOS / Arch Linux
# Interactive + CLI:
#   sudo ./wg_setup.sh                  (interactive menu)
#   sudo ./wg_setup.sh menu             (interactive menu)
#   sudo ./wg_setup.sh <qr_image> [iface] (legacy import)
#   sudo ./wg_setup.sh import <qr_image> [iface]
#   sudo ./wg_setup.sh start [iface]
#   sudo ./wg_setup.sh stop [iface]
#   sudo ./wg_setup.sh restart [iface]
#   sudo ./wg_setup.sh delete [iface] [--yes]
#   sudo ./wg_setup.sh status [iface]
#   sudo ./wg_setup.sh list

set -euo pipefail

WG_DIR="/etc/wireguard"
DEFAULT_IFACE="wg0"
PICKED_IFACE=""
RESOLVED_IFACE=""

require_root() {
    if [[ $EUID -ne 0 ]]; then
       echo "[!] Error: This command must be run as root or with sudo." >&2
       exit 1
    fi
}

usage() {
    cat <<EOF
Usage: sudo $0 [command] [args]

No args launches the interactive menu.

Commands:
  menu                          Open interactive menu
  import <qr_image> [interface]  Import WireGuard config from QR image (default: ${DEFAULT_IFACE})
  start [interface]               Start connection (prompts if omitted)
  stop [interface]                Stop connection (prompts if omitted)
  restart [interface]             Restart connection (prompts if omitted)
  delete [interface] [--yes]      Delete connection (prompts if omitted)
  status [interface]              Show status (prompts if omitted)
  list                            List installed connections

Legacy:
  sudo $0 <qr_image> [interface]

Examples:
  sudo $0
  sudo $0 import ~/Downloads/vpn-qr.png wg0
  sudo $0 start wg0
  sudo $0 stop wg0
  sudo $0 delete wg0
EOF
}

validate_interface() {
    local iface="${1:-}"
    if [[ ! "$iface" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "[!] Error: Invalid interface name '$iface'. Use only [a-zA-Z0-9_-]." >&2
        return 1
    fi
    if [[ ${#iface} -gt 15 ]]; then
        echo "[!] Error: Interface name '$iface' too long (max 15 chars)." >&2
        return 1
    fi
}

config_path_for() {
    local iface="$1"
    printf '%s/%s.conf' "$WG_DIR" "$iface"
}

# MTU blackhole fix: WireGuard overhead + reduced path MTU drops large
# TLS flights (server hello / cert blob ~1.2-1.8KB), surfacing as cert
# verification errors. 1280 (IPv6 minimum) fits everywhere.
ensure_mtu_in_config() {
    local CONFIG_PATH="$1"
    if grep -qi '^MTU\s*=' "$CONFIG_PATH"; then
        sed -i -E 's/^MTU\s*=.*/MTU = 1280/i' "$CONFIG_PATH"
    else
        sed -i '0,/^\[Interface\]/s//[Interface]\nMTU = 1280/' "$CONFIG_PATH"
    fi
}

is_up() {
    local iface="$1"
    ip link show "$iface" &>/dev/null
}

is_enabled_on_boot() {
    local iface="$1"
    systemctl is-enabled "wg-quick@${iface}" &>/dev/null
}

ensure_deps() {
    echo "[+] Checking and installing required packages..."
    local REQUIRED_PKGS=("wireguard-tools" "zbar")
    local MISSING_PKGS=()

    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! pacman -Qs "^${pkg}$" &>/dev/null; then
            MISSING_PKGS+=("$pkg")
        fi
    done

    if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
        echo "    Installing missing packages via pacman: ${MISSING_PKGS[*]}..."
        pacman -Sy --noconfirm --needed "${MISSING_PKGS[@]}"
    else
        echo "    All dependencies are already installed."
    fi
}

import_connection() {
    local QR_IMAGE="${1:?missing qr image path}"
    local INTERFACE="${2:-$DEFAULT_IFACE}"
    validate_interface "$INTERFACE" || return 1
    local CONFIG_PATH
    CONFIG_PATH=$(config_path_for "$INTERFACE")

    if [[ ! -f "$QR_IMAGE" ]]; then
        echo "[!] Error: File '$QR_IMAGE' not found." >&2
        return 1
    fi

    ensure_deps

    echo "[+] Decoding QR code from '$QR_IMAGE'..."
    local DECODED_CONF
    DECODED_CONF=$(zbarimg --raw -q "$QR_IMAGE" 2>/dev/null || true)

    if [[ -z "$DECODED_CONF" ]]; then
        echo "[!] Error: Failed to read QR code from '$QR_IMAGE'. Ensure the image is clear." >&2
        return 1
    fi

    if ! echo "$DECODED_CONF" | grep -q "\[Interface\]"; then
        echo "[!] Error: The QR code was read, but it does not appear to contain a valid WireGuard configuration." >&2
        return 1
    fi

    mkdir -p "$WG_DIR"

    if [[ -f "$CONFIG_PATH" ]] && [[ -t 0 ]]; then
        local OVERWRITE=""
        read -rp "Config '$CONFIG_PATH' exists. Overwrite? [y/N]: " OVERWRITE || true
        if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
            echo "[*] Import cancelled."
            return 0
        fi
    fi

    echo "$DECODED_CONF" > "$CONFIG_PATH"
    ensure_mtu_in_config "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
    echo "[+] Saved configuration to $CONFIG_PATH with secure permissions (600)."
    echo "[+] Enforced MTU = 1280 (prevents TLS/cert failures on restricted paths)."

    start_connection "$INTERFACE"

    echo ""
    echo "=== WireGuard Connection Status ==="
    wg show "$INTERFACE" || true

    echo ""
    if [[ -t 0 ]]; then
        local AUTOSTART=""
        read -rp "Start '$INTERFACE' automatically on boot? (y/N): " AUTOSTART || true
        if [[ "$AUTOSTART" =~ ^[Yy]$ ]]; then
            systemctl enable "wg-quick@${INTERFACE}"
            echo "[+] Enabled auto-start on boot via systemd (wg-quick@${INTERFACE})."
        fi
    fi

    echo ""
    echo "[+] Setup complete for '$INTERFACE'."
}

start_connection() {
    local INTERFACE="${1:-$DEFAULT_IFACE}"
    validate_interface "$INTERFACE" || return 1
    local CONFIG_PATH
    CONFIG_PATH=$(config_path_for "$INTERFACE")

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo "[!] Error: Config '$CONFIG_PATH' not found. Import it first (menu option 1)." >&2
        return 1
    fi

    if is_up "$INTERFACE"; then
        echo "[*] Interface $INTERFACE is already up. Restarting..."
        wg-quick down "$INTERFACE" || true
    fi

    echo "[+] Starting WireGuard connection '$INTERFACE'..."
    ensure_mtu_in_config "$CONFIG_PATH"
    wg-quick up "$INTERFACE"
    ip link set "$INTERFACE" mtu 1280 || true
    echo "[+] Interface $INTERFACE is up (MTU 1280)."
    wg show "$INTERFACE" || true
}

stop_connection() {
    local INTERFACE="${1:-$DEFAULT_IFACE}"
    validate_interface "$INTERFACE" || return 1

    if ! is_up "$INTERFACE"; then
        echo "[*] Interface $INTERFACE is already down (nothing to do)."
        return 0
    fi

    echo "[+] Stopping WireGuard connection '$INTERFACE'..."
    wg-quick down "$INTERFACE"
    echo "[+] Interface $INTERFACE is down."
}

delete_connection() {
    local INTERFACE="${1:-$DEFAULT_IFACE}"
    validate_interface "$INTERFACE" || return 1
    local CONFIG_PATH
    CONFIG_PATH=$(config_path_for "$INTERFACE")

    if [[ ! -f "$CONFIG_PATH" ]] && ! is_up "$INTERFACE"; then
        echo "[!] Error: No connection '$INTERFACE' found ($CONFIG_PATH missing, interface down)." >&2
        return 1
    fi

    local ASSUME_YES="${2:-}"
    if [[ "$ASSUME_YES" != "--yes" && "$ASSUME_YES" != "-y" ]]; then
        local CONFIRM=""
        echo "This will stop '$INTERFACE', disable autostart, and delete $CONFIG_PATH."
        read -rp "Delete connection '$INTERFACE'? [y/N]: " CONFIRM || true
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "[*] Delete cancelled."
            return 0
        fi
    fi

    if is_up "$INTERFACE"; then
        echo "[+] Stopping '$INTERFACE'..."
        wg-quick down "$INTERFACE" || true
    else
        echo "[*] Interface $INTERFACE already down."
    fi

    if is_enabled_on_boot "$INTERFACE"; then
        echo "[+] Disabling autostart (wg-quick@${INTERFACE})..."
        systemctl disable "wg-quick@${INTERFACE}" || true
    fi

    if [[ -f "$CONFIG_PATH" ]]; then
        rm -f -- "$CONFIG_PATH"
        echo "[+] Deleted $CONFIG_PATH."
    else
        echo "[*] No config file to delete at $CONFIG_PATH."
    fi

    echo "[+] Connection '$INTERFACE' deleted."
}

status_connection() {
    local INTERFACE="${1:-}"
    if [[ -n "$INTERFACE" ]]; then
        validate_interface "$INTERFACE" || return 1
        if is_up "$INTERFACE"; then
            echo "[+] $INTERFACE: UP"
        else
            echo "[*] $INTERFACE: DOWN"
        fi
        wg show "$INTERFACE" || echo "[*] No live WireGuard state for $INTERFACE."
    else
        wg show || echo "[*] No WireGuard interfaces up."
    fi
}

list_connections() {
    echo "Installed configs in $WG_DIR:"
    local found=0
    if [[ -d "$WG_DIR" ]]; then
        for conf in "$WG_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            found=1
            local iface
            iface=$(basename "$conf" .conf)
            local state="DOWN"
            if is_up "$iface"; then
                state="UP"
            fi
            local boot="disabled"
            if is_enabled_on_boot "$iface"; then
                boot="enabled"
            fi
            printf '  - %-12s %-4s autostart=%s  (%s)\n' "$iface" "$state" "$boot" "$conf"
        done
    fi
    if [[ $found -eq 0 ]]; then
        echo "  (none)"
    fi
}

# --- Interactive helpers ---

list_interface_names() {
    [[ -d "$WG_DIR" ]] || return 0
    local conf
    for conf in "$WG_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        basename "$conf" .conf
    done | sort
}

pause() {
    [[ -t 0 ]] || return 0
    read -rp "Press Enter to continue..." _ || true
}

pick_existing_interface() {
    PICKED_IFACE=""
    local prompt="${1:-Select connection}"
    local names=()
    mapfile -t names < <(list_interface_names)
    if [[ ${#names[@]} -eq 0 ]]; then
        echo "[!] No WireGuard connections found in $WG_DIR." >&2
        echo "    Import one first (menu option 1)." >&2
        return 1
    fi
    echo "Available connections:" >&2
    local i
    for i in "${!names[@]}"; do
        local state="DOWN"
        if is_up "${names[$i]}"; then
            state="UP"
        fi
        printf '  %d) %-12s [%s]\n' "$((i+1))" "${names[$i]}" "$state" >&2
    done
    local choice=""
    read -rp "$prompt [1-${#names[@]} or name]: " choice || return 1
    [[ -z "$choice" ]] && { echo "[*] Cancelled." >&2; return 1; }
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
        PICKED_IFACE="${names[$((choice-1))]}"
    else
        validate_interface "$choice" || return 1
        PICKED_IFACE="$choice"
    fi
    return 0
}

resolve_iface_or_pick() {
    RESOLVED_IFACE=""
    if [[ $# -ge 1 && -n "${1:-}" ]]; then
        RESOLVED_IFACE="$1"
        return 0
    fi
    if [[ -t 0 ]]; then
        pick_existing_interface "Select connection" || return 1
        RESOLVED_IFACE="$PICKED_IFACE"
        return 0
    fi
    RESOLVED_IFACE="$DEFAULT_IFACE"
}

interactive_import() {
    local qr="" iface=""
    if [[ -t 0 ]] && command -v find >/dev/null 2>&1; then
        echo "Tip: drag-and-drop the QR image into this terminal, or type the path." >&2
    fi
    read -rp "Path to QR image: " qr || { echo "[*] Cancelled."; return 1; }
    [[ -z "$qr" ]] && { echo "[*] Cancelled."; return 1; }
    # Expand leading ~ and strip surrounding quotes from drag-and-drop.
    qr="${qr%\"}"; qr="${qr#\"}"
    qr="${qr%\'}"; qr="${qr#\'}"
    qr="${qr/#\~/$HOME}"
    read -rp "Interface name [$DEFAULT_IFACE]: " iface || true
    iface="${iface:-$DEFAULT_IFACE}"
    import_connection "$qr" "$iface"
}

interactive_start() {
    pick_existing_interface "Start which connection?" || return 1
    start_connection "$PICKED_IFACE"
}

interactive_stop() {
    pick_existing_interface "Stop which connection?" || return 1
    stop_connection "$PICKED_IFACE"
}

interactive_restart() {
    pick_existing_interface "Restart which connection?" || return 1
    stop_connection "$PICKED_IFACE" || true
    start_connection "$PICKED_IFACE"
}

interactive_delete() {
    pick_existing_interface "Delete which connection?" || return 1
    delete_connection "$PICKED_IFACE"
}

interactive_status() {
    pick_existing_interface "Show status for which connection?" || return 1
    status_connection "$PICKED_IFACE"
}

show_menu() {
    clear || true
    echo "=================================="
    echo " WireGuard Connection Manager"
    echo "=================================="
    list_connections
    echo "----------------------------------"
    echo "1) Import from QR code"
    echo "2) Start connection"
    echo "3) Stop connection"
    echo "4) Restart connection"
    echo "5) Delete connection"
    echo "6) Status / details"
    echo "7) Exit"
    echo "----------------------------------"
}

interactive_menu() {
    require_root
    while true; do
        show_menu
        local choice=""
        read -rp "Choose [1-7]: " choice || break
        case "$choice" in
            1) interactive_import; pause ;;
            2) interactive_start; pause ;;
            3) interactive_stop; pause ;;
            4) interactive_restart; pause ;;
            5) interactive_delete; pause ;;
            6) interactive_status; pause ;;
            7|q|quit|exit) echo "Bye."; break ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}

# --- CLI dispatch ---
if [[ $# -lt 1 ]]; then
    if [[ -t 0 ]]; then
        interactive_menu
        exit $?
    fi
    usage
    exit 1
fi

CMD="$1"
shift || true

case "$CMD" in
    -h|--help|help)
        usage
        ;;
    menu|interactive|tui)
        interactive_menu
        ;;
    import)
        require_root
        if [[ $# -lt 1 ]]; then
            if [[ -t 0 ]]; then
                interactive_import
            else
                echo "[!] Error: 'import' needs <qr_image> [interface]." >&2
                usage >&2
                exit 1
            fi
        else
            import_connection "$1" "${2:-$DEFAULT_IFACE}"
        fi
        ;;
    start|up)
        require_root
        if [[ $# -ge 1 ]]; then
            start_connection "$1"
        else
            resolve_iface_or_pick || exit 1
            start_connection "$RESOLVED_IFACE"
        fi
        ;;
    stop|down)
        require_root
        if [[ $# -ge 1 ]]; then
            stop_connection "$1"
        else
            resolve_iface_or_pick || exit 1
            stop_connection "$RESOLVED_IFACE"
        fi
        ;;
    restart|reload)
        require_root
        if [[ $# -ge 1 ]]; then
            RESOLVED_IFACE="$1"
        else
            resolve_iface_or_pick || exit 1
        fi
        stop_connection "$RESOLVED_IFACE" || true
        start_connection "$RESOLVED_IFACE"
        ;;
    delete|remove|rm|del)
        require_root
        if [[ $# -eq 0 ]]; then
            interactive_delete
        else
            IFACE="$DEFAULT_IFACE"
            FORCE=""
            for arg in "$@"; do
                case "$arg" in
                    -y|--yes) FORCE="--yes" ;;
                    *) IFACE="$arg" ;;
                esac
            done
            # Single bare --yes means: prompt for iface, skip confirm.
            if [[ "$IFACE" == "$DEFAULT_IFACE" && "$FORCE" == "--yes" && $# -eq 1 ]]; then
                pick_existing_interface "Delete which connection?" || exit 1
                IFACE="$PICKED_IFACE"
            fi
            delete_connection "$IFACE" "$FORCE"
        fi
        ;;
    status|show)
        if [[ $# -ge 1 ]]; then
            status_connection "$1"
        else
            if [[ -t 0 ]]; then
                interactive_status
            else
                status_connection ""
            fi
        fi
        ;;
    list|ls)
        list_connections
        ;;
    -*)
        echo "[!] Error: Unknown option '$CMD'." >&2
        usage >&2
        exit 1
        ;;
    *)
        if [[ -f "$CMD" ]]; then
            require_root
            import_connection "$CMD" "${1:-$DEFAULT_IFACE}"
        else
            echo "[!] Error: Unknown command '$CMD' (and not a file)." >&2
            usage >&2
            exit 1
        fi
        ;;
esac
