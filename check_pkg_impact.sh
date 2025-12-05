#!/bin/bash

############################################################################
#
# A program to try to determine, in advance, if a deb package that is a
# candidate for upgrade will impact any running processes and, if so, to
# list those. The goal is to make that research more convenient and accurate
# than doing it by hand.
#
#
# To test a single package:
# $ check_pkg_impact.sh libcups2
#
# To test all packages available for upgrade:
# $ apt list --upgradable 2>/dev/null | grep 'upgradable from' | cut -d/ -f1 | xargs ./check_pkg_impact.sh
#
# To test all security-related packages available for upgrade:
# $ apt list --upgradable 2>/dev/null | grep -E '[a-z]+-security ' | cut -d/ -f1 | xargs ./check_pkg_impact.sh
#
# --------------------------------------------------------------------------
#
# Written by Lester Hightower, 12/04-12/05/2025, with assistance from a
# large language model trained by Google.
#
############################################################################

# Check for arguments
if [[ "$#" -eq 0 ]]; then
    # Print an error message to standard error (>&2)
    echo "ERROR: No package names provided." >&2
    echo "Usage: $0 <package1> [package2] ..." >&2
    exit 1 # Exit with a non-zero status code (indicating an error)
fi

# Check if the Effective User ID ($EUID) is NOT equal to 0 (root's UID)
if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: This script must have root privileges (e.g., using 'sudo')." >&2
  echo "Please re-run the script with 'sudo $0 $@'" >&2
  exit 1 # Exit with a non-zero status code (indicating an error)
fi

# Check if lsof is installed
if ! command -v lsof &> /dev/null ; then
    echo "lsof is not installed. Please install it using: sudo apt install lsof"
    exit 1 # Exit with a non-zero status code (indicating an error)
fi

echo "Analyzing processes for packages: $@"
echo "-------------------------------------"

for package_name in "$@"; do
    echo "Processing package: $package_name"

    # 1. Get the list of "ELF 64-bit LSB shared object" files in the package
    files=$(dpkg -L "$package_name" 2>/dev/null | xargs -r -d '\n' file --separator ': ' | grep -E ': *ELF 64-bit LSB shared object' | cut -d: -f1)

    if [ -z "$files" ]; then
        echo "No relevant binaries or libraries found for $package_name, or package not installed."
        continue
    fi

    # 2. Use lsof to find processes using any of these files
    # The -F pcf option outputs PID, Command name, and File name in a machine-readable format
    impacted_procs=$(lsof -F pcf $files 2>/dev/null)

    if [ -z "$impacted_procs" ]; then
        echo "  --> No running processes found using files from $package_name."
        continue
    fi

    # 3. Format and display the results
    echo "  --> Impacted processes for $package_name:"
    echo "$impacted_procs" | awk '
        /^p/ { pid=$0; sub(/^p/, "", pid) }
        /^c/ { cmd=$0; sub(/^c/, "", cmd) }
        /^f/ { print "    PID: " pid ", Command: " cmd }
    ' | sort -u

    echo ""
done

echo "-------------------------------------"
echo "Note: This identifies current usage. The 'needrestart' tool run after an upgrade detects when a *deleted* old library is still in memory."

