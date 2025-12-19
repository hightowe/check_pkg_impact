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

# ANSI Color Codes used to attract the user's attention
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color (Reset)

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

echo "Analyzing packages: $@"
echo "-------------------------------------"

# Get dependencies from simulation, merge requested packages with
# simulated dependencies, and get a unique list in all_packages.
requested_packages="$*"  # Packages that the user requested
echo "Calculating full impact including dependencies..."
simulated_deps=$(apt-get install -s $requested_packages 2>/dev/null | grep '^Inst' | awk '{print $2}')
all_packages=$(echo "$requested_packages $simulated_deps" | tr ' ' '\n' | sort -u)

echo "Total packages to be analyzed: $(echo "$all_packages" | wc -w)"
echo "-------------------------------------"

for package_name in $all_packages; do
    if [[ ! " $@ " =~ " $package_name " ]]; then
      printf "Processing package: %s ${YELLOW}(dependency)${NC}\n" "$package_name"
    else
      echo "Processing package: $package_name"
    fi

    # Check if this package is known to trigger an initramfs update
    if grep -qs "update-initramfs" /var/lib/dpkg/info/"$package_name".{triggers,postinst} 2>/dev/null; then
      printf "  ${RED}${BOLD}[!] WARNING:${NC} This package likely triggers an initramfs update.\n"
    fi

    # 1. Get the list of ELF binaries and libraries in the package
    files=$(dpkg -L "$package_name" 2>/dev/null | xargs -r -d '\n' file --separator ': ' | grep -E ': +ELF .*(executable|shared object)' | cut -d: -f1)

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

    # Header Line - Using the variable in the format string
    COMM_WIDTH="30" # The width for the Command column
    comm_underline=$(printf '%*s' "$COMM_WIDTH" '' | tr ' ' '-')
    printf "    %-8s %-${COMM_WIDTH}s %s\n" "PID" "Command" "Recommended Restart"
    printf "    %-8s %-${COMM_WIDTH}s %s\n" "-------" "$comm_underline" "-------------------"

    echo "$impacted_procs" | awk '/^p/ {print substr($0, 2)}' | sort -u | while read -r pid; do
        # Get the command name
        full_cmd=$(ps -p "$pid" -o args= 2>/dev/null | awk '{print $1}')

        # Trim the command using the COMM_WIDTH variable
        comm=$(basename -- "$full_cmd" | cut -c1-"$COMM_WIDTH")

        # Use -- to prevent strings starting with '-' from being read as options
        # If full_cmd is empty (process ended), we provide a fallback
        if [ -n "$full_cmd" ]; then
            comm=$(basename -- "$full_cmd")
        else
            comm="<defunct/ended>"
        fi

        # Get the systemd unit
        unit=$(ps -p "$pid" -o unit= 2>/dev/null | grep ".service" | sed 's/\.service.*//' | xargs)

        if [ -n "$unit" ]; then
            repro="systemctl restart $unit"
        else
            repro="[Manual]"
        fi

        # Print the formatted row using the variable
        printf "    %-8s %-${COMM_WIDTH}.${COMM_WIDTH}s %s\n" "$pid" "$comm" "$repro"
    done

    echo ""
done

echo "-------------------------------------"
echo "Note: This identifies current usage. The 'needrestart' tool run after an upgrade detects when a *deleted* old library is still in memory."

