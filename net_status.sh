#!/usr/bin/env bash
# net_status.sh — Friendly network interface overview for Rocky/RHEL-family
# Usage:
#   ./net_status.sh                # one-time snapshot (compact)
#   ./net_status.sh --wide         # more columns
#   ./net_status.sh --watch 2      # refresh every 2 seconds
#   ./net_status.sh -i ens27f0     # show only given interface
#
# Notes:
# - Uses NetworkManager (nmcli) if available for richer info, but falls back to /sys/ip tools.
# - Shows TYPE, STATE, LINK, SPEED, DUPLEX, MTU, MAC, IPv4, IPv6, RX/TX, ERR.
# - Works well on Rocky Linux 9.x (and RHEL-like distros).

set -euo pipefail

# -------- Config / Defaults --------
WATCH_INTERVAL=0
WIDE=0
IFACE_FILTER=""

BOLD="$(tput bold 2>/dev/null || true)"; NORM="$(tput sgr0 2>/dev/null || true)"
GREY="\033[90m"; RED="\033[31m"; GRN="\033[32m"; YEL="\033[33m"; BLU="\033[34m"; NC="\033[0m"

has() { command -v "$1" >/dev/null 2>&1; }

# -------- Parse Args --------
usage() {
  cat <<EOF
Usage: $0 [--watch N] [--wide] [-i IFACE]

Options:
  --watch N     Refresh every N seconds (Ctrl+C to stop).
  --wide        Show extended columns (Duplex, Gateway, DNS).
  -i IFACE      Filter to a single interface.
  -h, --help    Show this help.

Examples:
  $0
  $0 --wide
  $0 --watch 2
  $0 -i ens27f0 --watch 1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch) WATCH_INTERVAL="${2:-}"; shift 2 ;;
    --wide)  WIDE=1; shift ;;
    -i)      IFACE_FILTER="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

# Validate watch interval
if [[ -n "${WATCH_INTERVAL}" && ! "${WATCH_INTERVAL}" =~ ^[0-9]+$ ]]; then
  echo "Invalid --watch value: ${WATCH_INTERVAL}" >&2
  exit 1
fi

# -------- Dependency Check (soft where possible) --------
for cmd in ip awk sed cat; do
  has "$cmd" || { echo "Missing required dependency: $cmd" >&2; exit 1; }
done
# Optional enrichers
NMCLI=0; ETHTOOL=0
has nmcli && NMCLI=1
has ethtool && ETHTOOL=1

# -------- Helpers --------
fmt_bytes() {
  # human-readable bytes
  local b=$1
  local u=(B KB MB GB TB)
  local i=0
  while (( b >= 1024 && i < ${#u[@]}-1 )); do
    b=$(( b/1024 ))
    i=$(( i+1 ))
  done
  printf "%d%s" "$b" "${u[$i]}"
}

get_default_route() {
  ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

get_dns() {
  awk '/^nameserver/ {printf (NR>1?", ":"") $2} END{print ""}' /etc/resolv.conf 2>/dev/null || true
}

get_type_state_conn() {
  local dev="$1"
  local type="-" state="-" conn="-"
  if (( NMCLI )); then
    # DEVICE:TYPE:STATE:CONNECTION
    local line
    line="$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status 2>/dev/null | awk -F: -v d="$dev" '$1==d{print;exit}')"
    if [[ -n "$line" ]]; then
      IFS=: read -r _ type state conn <<<"$line"
    fi
  else
    # Fallback heuristics
    if [[ -e "/sys/class/net/$dev/wireless" ]]; then type="wifi"; else type="ethernet"; fi
    state="$(cat "/sys/class/net/$dev/operstate" 2>/dev/null || echo "-")"
  fi
  printf "%s;%s;%s" "${type:-"-"}" "${state:-"-"}" "${conn:-"-"}"
}

get_speed_duplex() {
  local dev="$1"
  local speed="-"; local duplex="-"
  if (( ETHTOOL )); then
    # Parse ethtool output if supported by the device
    if ethtool "$dev" >/dev/null 2>&1; then
      speed="$(ethtool "$dev" 2>/dev/null | awk -F': ' '/Speed:/ {gsub(/Mb\/s/,"");print $2;exit}')"
      duplex="$(ethtool "$dev" 2>/dev/null | awk -F': ' '/Duplex:/ {print $2;exit}')"
      [[ -z "$speed" ]] && speed="-"
      [[ -z "$duplex" ]] && duplex="-"
    fi
  fi
  printf "%s;%s" "$speed" "$duplex"
}

get_ipv4_list() {
  local dev="$1"
  if (( NMCLI )); then
    nmcli -g IP4.ADDRESS dev show "$dev" 2>/dev/null | paste -sd',' - || true
  else
    ip -4 addr show dev "$dev" | awk '/inet /{print $2}' | paste -sd',' - || true
  fi
}

get_ipv6_list() {
  local dev="$1"
  if (( NMCLI )); then
    nmcli -g IP6.ADDRESS dev show "$dev" 2>/dev/null | paste -sd',' - || true
  else
    ip -6 addr show dev "$dev" | awk '/inet6 /{print $2}' | paste -sd',' - || true
  fi
}

get_rx_tx_err() {
  local dev="$1"
  local rx_b tx_b rx_p tx_p rx_e tx_e
  rx_b=$(cat "/sys/class/net/$dev/statistics/rx_bytes" 2>/dev/null || echo 0)
  tx_b=$(cat "/sys/class/net/$dev/statistics/tx_bytes" 2>/dev/null || echo 0)
  rx_p=$(cat "/sys/class/net/$dev/statistics/rx_packets" 2>/dev/null || echo 0)
  tx_p=$(cat "/sys/class/net/$dev/statistics/tx_packets" 2>/dev/null || echo 0)
  rx_e=$(cat "/sys/class/net/$dev/statistics/rx_errors" 2>/dev/null || echo 0)
  tx_e=$(cat "/sys/class/net/$dev/statistics/tx_errors" 2>/dev/null || echo 0)
  printf "%s;%s;%s;%s;%s;%s" "$rx_b" "$tx_b" "$rx_p" "$tx_p" "$rx_e" "$tx_e"
}

get_link_flag() {
  local dev="$1"
  # carrier: 1=up, 0=down (not always present on virtual ifaces)
  if [[ -r "/sys/class/net/$dev/carrier" ]]; then
    if [[ "$(cat "/sys/class/net/$dev/carrier")" == "1" ]]; then
      printf "${GRN}UP${NC}"
    else
      printf "${RED}DOWN${NC}"
    fi
  else
    # fallback: operstate
    local st
    st="$(cat "/sys/class/net/$dev/operstate" 2>/dev/null || echo "unknown")"
    if [[ "$st" == "up" ]]; then printf "${GRN}UP${NC}"; else printf "${RED}%s${NC}" "$st"; fi
  fi
}

draw_header() {
  local now
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${BOLD}Network Status — ${now}${NORM}"
  if (( WIDE )); then
    printf "%-12s %-9s %-10s %-4s %-6s %-5s %-18s %-20s %-24s %-11s %-11s %-7s\n" \
      "IFACE" "TYPE" "STATE" "LINK" "SPEED" "DPLX" "MAC" "IPv4" "IPv6" "RX" "TX" "ERR"
  else
    printf "%-12s %-9s %-10s %-4s %-6s %-5s %-20s %-20s %-10s %-10s\n" \
      "IFACE" "TYPE" "STATE" "LINK" "SPEED" "DPLX" "IPv4" "IPv6" "RX" "TX"
  fi
  echo -e "${GREY}---------------------------------------------------------------------------------------------${NC}"
}

draw_row() {
  local dev="$1"
  local mtu mac link type state conn speed duplex v4 v6 rx_b tx_b rx_p tx_p rx_e tx_e

  mtu="$(ip link show dev "$dev" 2>/dev/null | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); break}}')"
  mac="$(cat "/sys/class/net/$dev/address" 2>/dev/null || echo "-")"
  link="$(get_link_flag "$dev")"

  IFS=';' read -r type state conn <<<"$(get_type_state_conn "$dev")"
  IFS=';' read -r speed duplex <<<"$(get_speed_duplex "$dev")"
  v4="$(get_ipv4_list "$dev")"; [[ -z "$v4" ]] && v4="-"
  v6="$(get_ipv6_list "$dev")"; [[ -z "$v6" ]] && v6="-"
  IFS=';' read -r rx_b tx_b rx_p tx_p rx_e tx_e <<<"$(get_rx_tx_err "$dev")"

  # Compact numbers
  local RX TX
  RX="$(fmt_bytes "$rx_b")"
  TX="$(fmt_bytes "$tx_b")"

  if (( WIDE )); then
    printf "%-12s %-9s %-10s %-4s %-6s %-5s %-18s %-20s %-24s %-11s %-11s %-7s\n" \
      "$dev" "$type" "$state" "$link" "${speed:-"-"}" "${duplex:-"-"}" "$mac" "${v4:0:20}" "${v6:0:24}" "$RX" "$TX" "$((rx_e+tx_e))"
  else
    printf "%-12s %-9s %-10s %-4s %-6s %-5s %-20s %-20s %-10s %-10s\n" \
      "$dev" "$type" "$state" "$link" "${speed:-"-"}" "${duplex:-"-"}" "${v4:0:20}" "${v6:0:20}" "$RX" "$TX"
  fi
}

footer_extras() {
  if (( WIDE )); then
    local gw dns
    gw="$(get_default_route)"; dns="$(get_dns)"
    echo
    echo -e "${BLU}Default GW:${NC} ${gw:--}"
    echo -e "${BLU}DNS:      ${NC} ${dns:--}"
  fi
}

list_ifaces() {
  # Prefer nmcli device list; fall back to kernel view
  local devs
  if (( NMCLI )); then
    devs=()
    while IFS=: read -r dev _; do
      [[ -z "$dev" ]] && continue
      devs+=("$dev")
    done < <(nmcli -t -f DEVICE,STATE dev status | awk -F: '$1!="" {print $0}')
    printf "%s\n" "${devs[@]}"
  else
    ls -1 /sys/class/net | grep -vE 'lo' || true
  fi
}

render_once() {
  clear
  draw_header
  local count=0
  while read -r dev; do
    [[ -z "$dev" ]] && continue
    local name="${dev%%:*}"  # strip trailing state if nmcli present
    [[ -n "$IFACE_FILTER" && "$name" != "$IFACE_FILTER" ]] && continue
    draw_row "$name"
    count=$((count+1))
  done < <(list_ifaces)
  (( count==0 )) && echo "No interfaces matched."
  footer_extras
}

# -------- Main --------
if [[ -n "$WATCH_INTERVAL" && "$WATCH_INTERVAL" -gt 0 ]]; then
  trap 'tput cnorm 2>/dev/null || true; exit 0' INT TERM
  tput civis 2>/dev/null || true
  while :; do
    render_once
    sleep "$WATCH_INTERVAL"
  done
else
  render_once
fi
