# Network Status Check Utility

## Overview

`net_status.sh` is a **Bash utility** for **Rocky Linux 9.3 (Blue Onyx)** and other RHEL-like distributions.  
It provides a **readable overview of all network interfaces**, including type, state, IPs, throughput, and errors.  
The script works in both **snapshot mode** (one-time) and **watch mode** (continuous updates).
It is designed to help system administrators and lab users quickly assess the network health of servers.

## Features

- **Interface Overview**
  - Lists all network interfaces except `lo` (loopback).
  - Displays interface name, type, state, link status, speed, duplex, IPs (IPv4 + IPv6), traffic counters, and errors.

- **Watch Mode**
  - Continuously refreshes the view at a user-defined interval (`--watch N`).
  - Provides a terminal dashboard feel (like `top` for networks).

- **Wide Mode**
  - Adds extra columns: MAC address, duplex mode, error counters
  - Displays system-wide default gateway and DNS servers at the footer.

- **Interface Filtering**
  - Show only one specific interface with `-i <iface>`.

- **Graceful Fallbacks**
  - If `nmcli` or `ethtool` is available → provides richer info (connection profile, speed, duplex).
  - If not → falls back to `/sys/class/net` and `ip` commands.

## Dependencies

The script requires only standard Linux tools:

**Required** (should already be installed):

- `ip` (from `iproute2`)

- `awk`, `sed`, `cat`, `tput`

**Optional** (for richer output):

- `nmcli` (from `NetworkManager`) → provides type, state, and profile info

- `ethtool` → provides link speed and duplex info

### Dependency Check

Run this to verify:

```bash
for cmd in ip awk sed cat tput; do command -v "$cmd" >/dev/null 2>&1 || echo "Missing: $cmd"; done
```

Install missing optional tools:

```bash
sudo dnf install -y NetworkManager ethtool
```

## Usage

```bash
./net_status.sh [options]
```

### Options

|Flag|Description|Example|
|---|---|---|
|`--watch N`|Refresh view every **N seconds**.|`./net_status.sh --watch 2`|
|`--wide`|Show extended columns (MAC, duplex, error count, DNS, GW).|`./net_status.sh --wide`|
|`-i IFACE`|Filter output to one specific interface.|`./net_status.sh -i ens27f0`|
|`-h` / `--help`|Show usage help.|`./net_status.sh -h`|

## Examples

1. **Simple snapshot** (default mode):

    ```bash
    ./net_status.sh
    ```

2. **Watch mode** (refresh every 2 seconds):

    ```bash
    ./net_status.sh --watch 2
    ```

3. **Wide mode with extra info**:

    ```bash
    ./net_status.sh --wide
    ```

4. **Single interface monitoring**:

    ```bash
    ./net_status.sh -i ens27f0 --watch 1
    ```

## Output Example

### Default mode

```
Network Status — 2025-09-18 16:45:12
IFACE       TYPE      STATE      LINK SPEED DPLX IPv4                 IPv6                 RX        TX
---------------------------------------------------------------------------------------------------------
ens27f0     ethernet  connected  UP   1000  full 192.168.1.50/24      fe80::a00:27ff:fe00  12MB      8MB
wlp2s0      wifi      disconnected DOWN -   -    -                    -                    0B        0B
```

### Wide mode

```
Network Status — 2025-09-18 16:45:12
IFACE       TYPE      STATE      LINK SPEED DPLX MAC               IPv4              IPv6                 RX        TX        ERR
---------------------------------------------------------------------------------------------------------
ens27f0     ethernet  connected  UP   1000  full 08:00:27:aa:bb:cc 192.168.1.50/24   fe80::a00:27ff:fe00  12MB      8MB       0

Default GW: 192.168.1.1
DNS:        1.1.1.1, 8.8.8.8
```

## Notes

- **Run without sudo** for general monitoring; use `sudo` only if your system requires extra permissions to query network state.

- **Loopback (`lo`) is excluded** by default.

- **Color coding:**

  - `UP` = green

  - `DOWN` = red

## Troubleshooting

- **Missing fields (speed/duplex)** → Install `ethtool`.

- **No TYPE/STATE/PROFILE** → Install `NetworkManager` for `nmcli`.

- **No interfaces shown** → Check with `ip link show` if your NICs are recognized.


# Auto-IP with Dynamic Check and Assignment

## Program Overview

`assign_static_ip.sh` is a Bash utility for **Rocky Linux 9.3 (Blue Onyx)** and other RHEL-like systems.  
It simplifies assigning a **persistent static IPv4 address** to a server network interface, using **NetworkManager (`nmcli`)**.

The script is designed for laboratory servers where:

- IP addresses must remain fixed across reboots,
- multiple interfaces may exist (and should be selectable interactively),
- collisions with existing IPs should be avoided automatically,
- lab-only networks may not have a valid gateway (and should not add a default route).

## Features

### Interactive Interface Selection

If no interface is specified, the script lists available interfaces with brief details (type, state, active profile, current IPs).  
The user can then select the desired interface from a numbered list.

### Automatic or User-Specified IP Assignment

- If an IP is provided (`-a`), the script checks availability.
- If not provided, the script starts at a base (`192.168.250.11`) and increments the last octet until it finds a free address.

### Reassign Mode (`-r`)

- Shows the current IPv4 address of the interface.
- Replaces it with either:
  - a user-provided IP (`-a`), or
  - a dynamically selected free IP (if `-a` is omitted).

### Collision Check

Ensures the chosen IP is not already in use via `arping` (preferred) or `ping` fallback.

### Lab-Only Mode

- If the gateway is unreachable or not needed, you can clear it and mark the interface as `never-default`.
- This prevents the lab NIC from installing a broken default route while keeping the static IP for local use.

### Persistent Configuration

- Uses `nmcli` to create or modify a NetworkManager connection profile for the interface.
- The settings survive reboots.

### Safe & Verbose

- Backs up the existing `.nmconnection` file before making changes.
- Prints a summary of the chosen settings before applying.
- Asks for user confirmation before applying changes.

## Dependencies

The following must be installed:

- `nmcli` (NetworkManager CLI)
- `ip` (from iproute2)
- `awk`, `sed`
- `ping` (for fallback checks)
- `arping` (recommended for accurate duplicate-address detection)

Quick check:

```bash
for cmd in nmcli ip awk sed ping arping; do \
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing: $cmd"; exit 1; }; \
done
```

Install missing tools on Rocky Linux:

```bash
sudo dnf install -y NetworkManager iproute awk sed iputils arping
```

## Usage

```bash
sudo ./assign_static_ip.sh [options]
```

### Options

|Flag|Description|Example|
|---|---|---|
|`-i <iface>`|Interface (e.g., `ens27f0`). If omitted, script prompts interactively.|`-i ens27f0`|
|`-a <ip>`|IPv4 address to assign. If omitted, script starts from `192.168.250.11` and auto-increments.|`-a 192.168.250.50`|
|`-p <prefix>`|CIDR prefix length (default: `24`).|`-p 24`|
|`-g <gateway>`|Gateway IP (default: `.1` of the chosen subnet). Omit if lab-only.|`-g 192.168.250.254`|
|`-d <dns>`|DNS servers (comma-separated). Default: `1.1.1.1,8.8.8.8`.|`-d 9.9.9.9,1.1.1.1`|
|`-r`|Reassign mode — replace current IP with a new one (manual or dynamic).|`-r`|
|`-h`|Show help message.|—|

## Examples

### Interactive mode (choose interface, auto-pick free IP)

```bash
sudo ./assign_static_ip.sh
```

### Set static IP on a specific interface

```bash
sudo ./assign_static_ip.sh -i ens27f0 -a 192.168.250.50
```

### Reassign current IP to a new one dynamically

```bash
sudo ./assign_static_ip.sh -i ens27f0 -r
```

### Reassign current IP to a specific one

```bash
sudo ./assign_static_ip.sh -i ens27f0 -r -a 192.168.250.77
```

### Lab-only assignment (no gateway/default route)

```bash
sudo ./assign_static_ip.sh -i ens27f0 -a 192.168.250.33 -g "" 
sudo nmcli con mod static-ens27f0 ipv4.never-default yes
```

## Behavior

1. **Interface selection**
    - If `-i` not given, lists interfaces managed by NetworkManager.
    - Displays type, state, connection profile, and current IPs.
    - Prompts user to select one.

2. **IP allocation**
    - If `-a` provided: verifies it is free.
    - If not: starts at `192.168.250.11`, increments last octet until free.

3. **Reassignment (`-r`)**
    - Displays current IP.
    - Applies new IP (manual or auto).

4. **Configuration**
    - Backs up existing connection file (`/etc/NetworkManager/system-connections/<conn>.nmconnection`).
    - Applies new static IPv4 settings via `nmcli`.
    - Enables autoconnect.
    - Restarts the connection.

5. **Final output**
    - Prints the current IP address with `ip -4 addr show`.

## Safety Notes

- Always run with **sudo** (requires root).
- The script modifies **NetworkManager connection profiles**.
- A backup is created automatically:

```
/etc/NetworkManager/system-connections/<profile>.nmconnection.bak.YYYYMMDDHHMMSS
```

- If something breaks, restore the backup and reload NetworkManager:

```bash
sudo cp <backupfile> /etc/NetworkManager/system-connections/<profile>.nmconnection
sudo nmcli connection reload
sudo nmcli connection up <profile>
```

## Troubleshooting

- **"Interface not found"**  
Ensure the NIC is managed by NetworkManager:

```bash
nmcli device status
```

- **No internet after static assignment**  
If this is a lab-only NIC, remove the gateway and set `never-default`.  
If it should route, verify the correct gateway IP exists and responds to ARP.

- **IP conflict still occurs**  
Install `arping` for better detection instead of relying only on `ping`.

