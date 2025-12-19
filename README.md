# check_pkg_impact

A "pre-flight" audit tool for Debian/Ubuntu systems to determine the impact of package upgrades, in advance.

## Overview

While `apt upgrade` shows a list of packages, you won't necessarily know which running services will be disrupted by applying those upgrades. `check_pkg_impact` bridges that gap by:
1. **Simulating the upgrade** to find all recursive dependencies.
2. **Scanning for ELF binaries and shared objects** within those packages.
3. **Cross-referencing with `lsof`** to identify every running Process ID (PID) currently using those files.
4. **Flagging critical system impacts** like Kernel updates or Initramfs triggers.

This script is designed for sysadmins who want to know if an update requires no further actions, one or more simple service restarts, or a full maintenance window for a reboot.

## Key Features

| Feature | Description |
| :--- | :--- |
| **Dependency Expansion** | Analyzes the packages you specify plus any recursive dependencies that `apt` would pull in. |
| **Reboot Detection** | Flags `linux-image-*` and `systemd` updates that cannot be handled by service restarts. |
| **Initramfs Alerts** | Flags triggers that will rebuild the boot ramdisk via `update-initramfs`. |
| **Service Mapping** | Maps PIDs to their `systemd` units and provides copy-pasteable `systemctl restart` commands. |
| **Color-Coded Output** | Highlights warnings in Red/Bold for easy scanning in busy terminal environments. |

## Installation & Usage

### Prerequisites
- Debian-based distribution (Ubuntu, Mint, etc.)
- Root/sudo privileges

### Quick Start
```bash
# Clone the repository
git clone [https://github.com/hightowe/check_pkg_impact.git](https://github.com/hightowe/check_pkg_impact.git)
cd check_pkg_impact

# Run against a package you are considering upgrading
sudo ./check_pkg_impact.sh libc6

