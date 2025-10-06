#!/usr/bin/env bash
set -euo pipefail

# Default settings if not provided
DEFAULT_BASE_IP="192.168.250.11"
DEFAULT_PREFIX="24"
DEFAULT_GW_DEFAULT_NET=".1"   # will use x.x.x.1 as default gateway
DEFAULT_DNS="1.1.1.1,8.8.8.8"
SCAN_MAX=200   # max attempts when auto-searching for a free IP

# Colors
BOLD="$(tput bold || true)"; NORM="$(tput sgr0 || true)"

log()  { echo -e "${BOLD}[*]${NORM} $*"; }
ok()   { echo -e "${BOLD}[+]${NORM} $*"; }
warn() { echo -e "${BOLD}[!]${NORM} $*"; }
err()  { echo -e "${BOLD}[-]${NORM} $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Required command '$1' not found."; exit 1; }
}

usage() {
  cat <<EOF
Usage: sudo $0 [-i <iface>] [-a <ip>] [-p <prefix>] [-g <gateway>] [-d <dns>]

Options:
  -i  Network interface (e.g. ens27f0). If omitted, you'll be prompted.
  -a  Static IPv4 address to set (e.g. 192.168.250.50). If omitted, script tries ${DEFAULT_BASE_IP} and increments.
  -p  Prefix length (CIDR), default ${DEFAULT_PREFIX}.
  -g  IPv4 gateway (defaults to x.x.x${DEFAULT_GW_DEFAULT_NET} based on chosen IP).
  -d  DNS servers comma-separated (default "${DEFAULT_DNS}").

Examples:
  sudo $0 -i ens27f0                         # choose IP automatically
  sudo $0 -i ens27f0 -a 192.168.250.50       # set specific IP (checked for availability)
  sudo $0 -a 10.0.0.20 -p 24 -g 10.0.0.1 -d 9.9.9.9,1.1.1.1
EOF
}

# --- Parse args ---
IFACE=""
ADDR=""
PREFIX="${DEFAULT_PREFIX}"
GATEWAY=""
DNS="${DEFAULT_DNS}"

while getopts ":i:a:p:g:d:h" opt; do
  case "$opt" in
    i) IFACE="$OPTARG" ;;
    a) ADDR="$OPTARG" ;;
    p) PREFIX="$OPTARG" ;;
    g) GATEWAY="$OPTARG" ;;
    d) DNS="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) err "Invalid option: -$OPTARG"; usage; exit 1 ;;
    :)  err "Option -$OPTARG requires an argument."; usage; exit 1 ;;
  esac
done

# --- Preconditions ---
[ "$EUID" -eq 0 ] || { err "Please run as root (sudo)."; exit 1; }
need_cmd nmcli
need_cmd ip
need_cmd awk
need_cmd sed

# Optional OS sanity check
if [ -r /etc/os-release ]; then
  . /etc/os-release
  if [[ "${ID_LIKE:-}" != *"rhel"* ]] && [[ "${ID:-}" != "rocky" ]]; then
    warn "This script is designed for RHEL-like systems (Rocky/Alma/RHEL). Detected: ${PRETTY_NAME:-unknown}."
  else
    ok "Detected ${PRETTY_NAME:-Rocky Linux}."
  fi
fi

# --- Helper functions ---
has_cmd() { command -v "$1" >/dev/null 2>&1; }

ip_in_use() {
  # Prefer arping duplicate address detection, fall back to ping
  local iface="$1"; local ip="$2"
  if has_cmd arping; then
    if arping -I "$iface" -D -c 2 -w 2 "$ip" >/dev/null 2>&1; then
      if arping -I "$iface" -c 2 -w 2 "$ip" 2>/dev/null | grep -qi "reply from"; then
        return 0  # in use
      else
        return 1  # free
      fi
    else
      if arping -I "$iface" -c 2 -w 2 "$ip" 2>/dev/null | grep -qi "reply from"; then
        return 0 # in use
      else
        return 1 # free
      fi
    fi
  else
    if ping -c 1 -W 1 -I "$iface" "$ip" >/dev/null 2>&1; then
      return 0 # in use
    else
      return 1 # free
    fi
  fi
}

# Return 0 if exact IP is configured on ANY local interface
ip_assigned_locally() {
  local ip="$1"
  ip -o -4 addr show | awk '{print $4}' | awk -F/ '{print $1}' | grep -qx "$ip"
}

# Return 0 if the same /24 exists on another interface
# Args: <iface> <ip> <prefix>
subnet_exists_elsewhere() {
  local iface="$1" ip="$2" prefix="$3"
  # Simple /24 compare (sufficient for lab /24 use): compare first 3 octets
  local base1
  base1="$(echo "$ip" | awk -F. '{print $1"."$2"."$3}')"
  ip -o -4 addr show | awk -v IF="$iface" '$2!=IF {print $2,$4}' \
    | awk -F'[ /.]' '{printf "%s %s.%s.%s\n",$1,$2,$3,$4}' \
    | awk -v B="$base1" '$2==B {print $0}' | grep -q .
}

inc_ip_last_octet() {
  # naive: only for /24-style local ranges; increments last octet
  local ip="$1"
  local base="${ip%.*}"
  local last="${ip##*.}"
  last=$((last + 1))
  # keep in sane host range, avoid .0, .1 (gw), .255
  if (( last <= 1 )); then last=2; fi
  if (( last >= 255 )); then last=254; fi
  echo "${base}.${last}"
}

default_gateway_for_ip() {
  local ip="$1"
  echo "${ip%.*}${DEFAULT_GW_DEFAULT_NET}"
}

list_interfaces() {
  # Show devices that are ethernet or infiniband and managed by NM
  nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev status \
    | awk -F: '$2 ~ /ethernet|infiniband/ {print}'
}

iface_details() {
  local dev="$1"
  # brief details: state, current IPs
  local state ip4
  state="$(nmcli -g GENERAL.STATE dev show "$dev" 2>/dev/null || true)"
  ip4="$(nmcli -g IP4.ADDRESS dev show "$dev" 2>/dev/null | tr '\n' ' ' || true)"
  echo "state=${state:-unknown} ip4=${ip4:-none}"
}

choose_interface_interactive() {
  log "No interface specified. Scanning available interfaces…"
  mapfile -t rows < <(list_interfaces)
  if [ "${#rows[@]}" -eq 0 ]; then
    err "No suitable interfaces managed by NetworkManager were found."
    exit 1
  fi
  echo
  echo "${BOLD}Available interfaces:${NORM}"
  local i=1
  declare -A dev_by_idx
  for line in "${rows[@]}"; do
    IFS=: read -r dev type state conn <<<"$line"
    details="$(iface_details "$dev")"
    printf "  %2d) %-12s type=%-9s state=%-10s conn=%s  (%s)\n" "$i" "$dev" "$type" "$state" "${conn:---}" "$details"
    dev_by_idx["$i"]="$dev"
    i=$((i+1))
  done
  echo
  read -rp "Choose an interface [1-${#rows[@]}]: " pick
  IFACE="${dev_by_idx[$pick]:-}"
  if [ -z "$IFACE" ]; then
    err "Invalid selection."
    exit 1
  fi
  ok "Selected interface: $IFACE"
}

ensure_connection_profile() {
  local dev="$1"
  local existing
  existing="$(nmcli -g GENERAL.CONNECTION dev show "$dev" 2>/dev/null || echo "--")"
  if [[ "$existing" == "--" || -z "$existing" ]]; then
    local con_name="static-$dev"
    log "No active connection profile for $dev. Creating '$con_name'…"
    nmcli con add type ethernet ifname "$dev" con-name "$con_name" autoconnect yes >/dev/null
    echo "$con_name"
  else
    echo "$existing"
  fi
}

confirm_or_exit() {
  echo
  read -rp "Apply these settings? [y/N]: " ans
  case "${ans,,}" in
    y|yes) ;;
    *) err "Aborted by user."; exit 1 ;;
  esac
}

# --- Main flow ---

# Pick/validate interface
if [ -z "$IFACE" ]; then
  choose_interface_interactive
else
  if ! nmcli -t -f DEVICE dev status | awk -F: '{print $1}' | grep -qx "$IFACE"; then
    err "Interface '$IFACE' not found via NetworkManager."
    exit 1
  fi
  ok "Using interface: $IFACE"
fi

# Determine target IP
if [ -n "$ADDR" ]; then
  CAND="$ADDR"

  # Prevent using an IP already bound on this host
  if ip_assigned_locally "$CAND"; then
    err "IP $CAND is already assigned on this host. Choose another."
    exit 1
  fi

  log "Checking availability of requested IP $CAND…"
  if ip_in_use "$IFACE" "$CAND"; then
    err "IP $CAND appears to be in use on the network."
    exit 1
  else
    ok "IP $CAND looks free."
  fi
else
  log "No IP provided. Attempting to find a free address starting at ${DEFAULT_BASE_IP}…"
  CAND="$DEFAULT_BASE_IP"
  tries=0
  while :; do
    # 1) Don't reuse an IP already on this host
    if ip_assigned_locally "$CAND"; then
      warn "$CAND is already assigned on this host; trying next…"
      CAND="$(inc_ip_last_octet "$CAND")"
      tries=$((tries+1)); [ "$tries" -gt "$SCAN_MAX" ] && { err "Could not find a free IP near ${DEFAULT_BASE_IP}."; exit 1; }
      continue
    fi
    # 2) Skip IPs in use on the wire
    if ip_in_use "$IFACE" "$CAND"; then
      warn "$CAND is in use on the network; trying next…"
      CAND="$(inc_ip_last_octet "$CAND")"
      tries=$((tries+1)); [ "$tries" -gt "$SCAN_MAX" ] && { err "Could not find a free IP near ${DEFAULT_BASE_IP}."; exit 1; }
      continue
    fi
    break
  done
  ok "Selected free IP: $CAND"
fi

# Warn if placing same /24 on multiple NICs
if subnet_exists_elsewhere "$IFACE" "$CAND" "$PREFIX"; then
  warn "The subnet for ${CAND}/${PREFIX} appears to already exist on another interface."
  warn "Running the same /24 on multiple NICs is usually problematic."
  read -rp "Proceed anyway? [y/N]: " ans
  case "${ans,,}" in
    y|yes) ;;
    *) err "Aborting to avoid subnet clash."; exit 1 ;;
  esac
fi

# Gateway default (if not set)
if [ -z "$GATEWAY" ]; then
  GATEWAY="$(default_gateway_for_ip "$CAND")"
  log "No gateway provided; defaulting to $GATEWAY"
fi

# Show summary
echo
echo "${BOLD}Summary${NORM}"
echo "  Interface : $IFACE"
echo "  IPv4      : $CAND/$PREFIX"
echo "  Gateway   : $GATEWAY"
echo "  DNS       : $DNS"

confirm_or_exit

# Obtain or create a connection profile
CONN="$(ensure_connection_profile "$IFACE")"
ok "Using connection profile: $CONN"

# Backup existing profile file if present
CON_FILE="/etc/NetworkManager/system-connections/${CONN}.nmconnection"
if [ -f "$CON_FILE" ]; then
  cp -a "$CON_FILE" "${CON_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  ok "Backed up existing profile to ${CON_FILE}.bak.*"
fi

# Apply settings
log "Applying static IPv4 settings with nmcli…"
nmcli con mod "$CONN" ipv4.addresses "${CAND}/${PREFIX}"
nmcli con mod "$CONN" ipv4.gateway "$GATEWAY"
nmcli con mod "$CONN" ipv4.dns "$DNS"
nmcli con mod "$CONN" ipv4.method manual
nmcli con mod "$CONN" connection.autoconnect yes

# (Optional) Leave IPv6 as-is. To disable IPv6 uncomment:
# nmcli con mod "$CONN" ipv6.method "ignore"

# Bring connection up
log "Bringing the connection up…"
nmcli con down "$CONN" >/dev/null 2>&1 || true
nmcli con up "$CONN"

ok "Done. Current IPv4 on $IFACE:"
ip -4 addr show dev "$IFACE" | sed 's/^/  /'
theres 
