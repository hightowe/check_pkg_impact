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

# Run against one or more packages that you are considering upgrading
sudo ./check_pkg_impact.sh libssl3
sudo ./check_pkg_impact.sh libc6 lvm2 systemd  # Expect a lot of results on most systems
```

# check_pkg_impact-universal.sh

A "pre-flight" audit tool for Linux systems to determine the impact of package upgrades, in advance.
It is to be used in exactly the same way that the Debian-only check_pkg_impact.sh is, but it is
designed to work on:
 * Debian/Ubuntu (apt/dpkg)
 * RHEL/CentOS/Fedora (dnf/yum/rpm)
 * Arch Linux (pacman)

## IMPORTANT NOTE:
This program was written almost entirely by Google Antigravity,
with check_pkg_impact.sh as a starting point. Lester Hightower
prompted Antigravity and did the (limited) testing necessary on
the three Linux OS types listed above to get it to work. However,
this program has not been extensively tested and Lester Hightower uses
Debian/Ubuntu-based distros almost exclusively, and so this program
won't get much testing from him personally. And so, please use with
caution, and pull requests are welcomed.



