# switch-xray

Switch port diagnostics and documentation via SNMP.

[![Latest Release](https://img.shields.io/github/v/release/ciroiriarte/switch-xray)](https://github.com/ciroiriarte/switch-xray/releases)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

## Table of Contents

- [Description](#-description)
- [Requirements](#%EF%B8%8F-requirements)
- [Installation](#-installation)
- [Usage](#-usage)
- [Configuration](#-configuration)
- [Output Examples](#-output-examples)
- [Supported Platforms](#-supported-platforms)
- [License](#-license)
- [Contributing](#-contributing)
- [Authors](#%EF%B8%8F-authors)

## Description

`switch-xray.sh` is a diagnostic tool that provides a snapshot of switch port
configuration and cabling via SNMP. It is the **switch-side counterpart** to
[nic-xray](https://github.com/ciroiriarte/nic-xray), designed for implementation
documentation and ad-hoc troubleshooting.

For each switch port it displays:

- Port name and description (ifAlias)
- LAG membership (ae/Port-Channel) with member count
- Administrative and operational status (color-coded)
- Negotiated speed (color-coded by tier)
- MTU
- LLDP neighbor system name and remote port
- Optionally: LLDP remote system description, PVID/VLAN info, switch model

When querying multiple switches, **cross-switch LAG detection** (ESI-LAG / MCLAG)
identifies hosts with LAG members spanning different switches, common in
EVPN/VXLAN IP Fabric and traditional MCLAG deployments.

Supports multiple output formats: **table** (default, with dynamic column widths),
**CSV**, **JSON**, and **network topology diagrams** (DOT/SVG/PNG).

Although LibreNMS is recommended for day-to-day operations with live diagrams,
switch-xray provides a "one-shot" snapshot for implementation documentation and
troubleshooting.

## Requirements

- Required tools:
  - `snmpbulkwalk` or `snmpwalk`, and `snmpget` (from the **net-snmp** package)
- Optional tools:
  - `graphviz` (`dot` command) -- required for `--output svg` and `--output png`
- Switch configuration:
  - SNMP v2c or v3 access enabled on target switches
  - LLDP enabled on the switch for neighbor discovery

## Installation

### Script

Copy to `/usr/local/sbin` for easy access:

```bash
sudo cp switch-xray.sh /usr/local/sbin/
sudo chmod +x /usr/local/sbin/switch-xray.sh
```

### Man page

A man page is available under `man/man8/` for detailed reference (section 8: system administration commands).

**Preview locally** (no installation required):

```bash
man -l man/man8/switch-xray.8
```

**Install system-wide:**

```bash
sudo make install-man
```

After installation, use `man switch-xray` to view the man page.

**Uninstall:**

```bash
sudo make uninstall-man
```

## Usage

### Basic

```bash
switch-xray.sh --switch 10.0.0.1 -c public                # Single switch, SNMPv2c
switch-xray.sh --switch sw1 --switch sw2 -c public         # Multiple switches
switch-xray.sh -h                                           # Display help
switch-xray.sh -v                                           # Display version
```

### SNMPv3

```bash
switch-xray.sh --switch 10.0.0.1 --snmp-version 3 \
  -u myuser -l authPriv -a SHA -A authpass -x AES -X privpass
```

### Optional columns

```bash
switch-xray.sh --switch sw1 -c public --lldp-detail   # Show LLDP system description
switch-xray.sh --switch sw1 -c public --vlans          # Show PVID/VLAN info
switch-xray.sh --switch sw1 -c public --all            # All optional columns
```

### Filtering and sorting

```bash
switch-xray.sh --switch sw1 -c public --filter-status up          # Only operationally up ports
switch-xray.sh --switch sw1 -c public --filter-status admin-down   # Only admin-disabled ports
switch-xray.sh --switch sw1 -c public --filter-port "xe-0/0/*"    # Glob filter on port name
switch-xray.sh --switch sw1 --switch sw2 -c public --group-switch  # Group rows by switch
```

### Output formats

```bash
switch-xray.sh --switch sw1 -c public --output csv              # CSV output
switch-xray.sh --switch sw1 -c public --output csv -s'|'        # Pipe-delimited CSV
switch-xray.sh --switch sw1 -c public --output json             # JSON output
switch-xray.sh --switch sw1 -c public --output json --all       # JSON with all fields
```

### Topology diagrams

```bash
switch-xray.sh --switch sw1 -c public --output dot > topology.dot         # DOT source
switch-xray.sh --switch sw1 -c public --output svg                        # SVG diagram
switch-xray.sh --switch sw1 -c public --output png --diagram-out net.png  # PNG with custom path
switch-xray.sh --switch sw1 --switch sw2 -c public --output svg \
  --diagram-style network                                                   # Network map style
```

### Formatting

```bash
switch-xray.sh --switch sw1 -c public -s            # Table with | column separators
switch-xray.sh --switch sw1 -c public --no-color    # Disable color output
```

## Configuration

### Config file

switch-xray reads configuration from (in order of precedence):
1. `--config FILE` (CLI flag)
2. `~/.switch-xray.conf`
3. `/etc/switch-xray.conf`

CLI arguments override config file values. See `switch-xray.conf.example` for all options.

### Environment variables

| Variable | Description |
|---|---|
| `SWITCH_XRAY_SWITCHES` | Comma-separated list of switch hostnames/IPs |
| `SWITCH_XRAY_COMMUNITY` | SNMPv2c community string |
| `SWITCH_XRAY_VERSION` | SNMP version (`2c` or `3`) |
| `SWITCH_XRAY_USER` | SNMPv3 username |
| `SWITCH_XRAY_SEC_LEVEL` | SNMPv3 security level |
| `SWITCH_XRAY_AUTH_PROTO` | SNMPv3 auth protocol |
| `SWITCH_XRAY_AUTH_PASS` | SNMPv3 auth passphrase |
| `SWITCH_XRAY_PRIV_PROTO` | SNMPv3 privacy protocol |
| `SWITCH_XRAY_PRIV_PASS` | SNMPv3 privacy passphrase |

Priority: CLI > environment variables > config file.

## Output Examples

> Hostnames and details below are examples. Full sample files are available in [`samples/`](samples/).

### Default table (single switch)

```
Switch: qfx-leaf-01

Port       LAG        Description      Admin   Oper   Speed   MTU    LLDP Neighbor          Remote Port
---------------------------------------------------------------------------------------------------------
xe-0/0/0   ae0        server-01 eth0   up      up     10G     9216   server-01.example.net   eno1np0
xe-0/0/1   ae0        server-01 eth1   up      up     10G     9216   server-01.example.net   eno2np1
xe-0/0/2   ae1        server-02 eth0   up      up     10G     9216   server-02.example.net   ens3f0np0
xe-0/0/3   -          unused           up      down   N/A     1500   -                       -
et-0/0/48  -          uplink-spine-01  up      up     100G    9216   spine-01.example.net    et-0/0/0
ae0        2 members  server-01 LAG    up      up     10G     9216   server-01.example.net   bond0
ae1        1 members  server-02 LAG    up      up     10G     9216   server-02.example.net   bond0
```

### Multi-switch with group separators

```
switch-xray.sh --switch leaf-01 --switch leaf-02 -c public --group-switch -s
```

### CSV output

```
Port,LAG,Description,Admin,Oper,Speed,MTU,LLDP Neighbor,Remote Port
xe-0/0/0,ae0,server-01 eth0,up,up,10G,9216,server-01.example.net,eno1np0
xe-0/0/1,ae0,server-01 eth1,up,up,10G,9216,server-01.example.net,eno2np1
...
```

### JSON output

```json
[
  {
    "port": "xe-0/0/0",
    "lag": "ae0",
    "description": "server-01 eth0",
    "admin_status": "up",
    "oper_status": "up",
    "speed": "10G",
    "mtu": 9216,
    "lldp_neighbor": "server-01.example.net",
    "remote_port": "eno1np0"
  },
  ...
]
```

### Topology diagram

```bash
switch-xray.sh --switch leaf-01 -c public --output svg
```

The diagram shows switch ports grouped inside switch clusters, connected to LLDP
neighbors. Port status is color-coded (green=up, red=down, gray=admin-down), edge
thickness scales with link speed, and LAG membership is shown inside each port node.
Cross-switch LAGs (ESI/MCLAG) are rendered with dashed edges.

Two diagram styles are available:
- `switch` (default): Switch-centric view with switch clusters and port sub-nodes
- `network`: Network-centric view showing the full mesh topology

## Supported Platforms

| Platform | Status | Interface Filter |
|---|---|---|
| JunOS (QFX, EX, MX) | Primary | `xe-*`, `et-*`, `ge-*`, `mge-*`, `ae*` |
| Arista EOS | Supported | `Ethernet*`, `Port-Channel*` |
| Generic (any SNMP device) | Fallback | ifType 6 (ethernet) and 161 (LAG) |

Platform detection is automatic via `sysDescr.0`. Use `--platform` to override.
New platforms can be added by implementing a `filter_interfaces_<platform>()` function.

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Authors

**Ciro Iriarte**

- **Created**: 2026-03-01
