#!/bin/bash

############################################################################
#
# check_pkg_impact-universal.sh
#
# A program to try to determine, in advance, if a package that is a
# candidate for upgrade will impact any running processes and, if so,
# to list those, and to do that on many types of Linux distributions.
#
# Supports:
#   - Debian/Ubuntu (apt/dpkg)
#   - RHEL/CentOS/Fedora (dnf/yum/rpm)
#   - Arch Linux (pacman)
#
# Usage:
#   sudo ./check_pkg_impact-universal.sh <package1> [package2] ...
#
# --------------------------------------------------------------------------
#
# Written by Lester Hightower on 12/19/2025, with assistance from a
# large language model trained by Google.
#
# IMPORTANT NOTE:
#  This program was written almost entirely by Google Antigravity,
#  with check_pkg_impact.sh as a starting point. Lester Hightower
#  prompted Antigravity and did the (limited) testing necessary on
#  the three Linux OS types listed above to get it to work. However,
#  this program has not been heavily tested and Lester Hightower uses
#  Debian/Ubuntu-based distros almost exclusively, and so this program
#  won't get much testing from him personally. And so, please use with
#  caution, and pull requests are welcomed.
#
############################################################################

# ANSI Color Codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- ERROR HANDLING & CLEANUP ---
# Ensure we clean up temp files if they are ever used (none currently, but good practice)
cleanup() {
    # Placeholder for cleanup
    :
}
trap cleanup EXIT

# --- OS / PACKAGE MANAGER DETECTION ---
PM_CMD=""
PM_TYPE=""

if command -v apt-get &> /dev/null; then
    PM_TYPE="deb"
    PM_CMD="apt-get"
elif command -v dnf &> /dev/null; then
    PM_TYPE="rpm"
    PM_CMD="dnf"
elif command -v yum &> /dev/null; then
    PM_TYPE="rpm"
    PM_CMD="yum"
elif command -v pacman &> /dev/null; then
    PM_TYPE="arch"
    PM_CMD="pacman"
else
    echo -e "${RED}ERROR: Unsupported system. Could not find apt, dnf, yum, or pacman.${NC}" >&2
    exit 1
fi

# --- ARGUMENT CHECK ---
if [[ "$#" -eq 0 ]]; then
    echo -e "${RED}ERROR: No package names provided.${NC}" >&2
    echo "Usage: $0 <package1> [package2] ..." >&2
    exit 1
fi

# --- PRIVILEGE CHECK ---
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}ERROR: This script must have root privileges.${NC}" >&2
    echo "Please re-run with 'sudo $0 $@'" >&2
    exit 1
fi

# --- DEPENDENCY CHECK ---
# We generally need 'lsof' and 'file'
MISSING_DEPS=()
if ! command -v lsof &> /dev/null; then MISSING_DEPS+=("lsof"); fi
if ! command -v file &> /dev/null; then MISSING_DEPS+=("file"); fi

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo -e "${RED}ERROR: Missing required dependencies: ${MISSING_DEPS[*]}${NC}" >&2
    echo "Please install them using your package manager." >&2
    exit 1
fi

# --- MAIN LOGIC ---

requested_packages="$*"

echo -e "${BOLD}Detecting system type: ${YELLOW}$PM_TYPE${NC} (using $PM_CMD)"
echo -e "${BOLD}Calculating full impact including dependencies...${NC}"

# 1. Calculate Dependencies (SIMULATION)
simulated_deps=""

case $PM_TYPE in
    deb)
        # apt-get install -s outputs lines starting with "Inst " for installs
        simulated_deps=$($PM_CMD install -s $requested_packages 2>/dev/null | grep '^Inst' | awk '{print $2}')
        ;;
    rpm)
        # dnf/yum install --assumeno.
        # Fallback mechanism: 'dnf install' sometimes reports "Nothing to do" for upgrades on some systems.
        # If 'install' yields no transaction, we try 'upgrade'.

        get_rpm_transaction() {
            local action=$1
            $PM_CMD $action --assumeno $requested_packages 2>/dev/null
        }

        # Try install first (handles new packages + most upgrades)
        raw_output=$(get_rpm_transaction "install")

        # If "Nothing to do", try upgrade (handles stubborn upgrades)
        if echo "$raw_output" | grep -q "Nothing to do"; then
            raw_output=$(get_rpm_transaction "upgrade")
        fi

        # Attempt to grab package names from the "Installing:", "Upgrading:", "Reinstalling:" sections
        simulated_deps=$(echo "$raw_output" | awk '/^[[:space:]]*(Installing|Upgrading|Reinstalling):/ {flag=1; next} /Transaction Summary/ {flag=0} flag {print $1}' | grep -v '^$')
        ;;
    arch)
        # pacman -Sp prints URLs. -S --print-format %n prints names only.
        # "Smart Conflict Resolution":
        # pacman fails on partial upgrades. We parse the error "required by packageX" and auto-add packageX.

        candidates="$requested_packages"
        for i in {1..3}; do
            # Capture both stdout and stderr (pacman prints errors to stderr, sometimes stdout depending on config)
            # We use a temp file or just capture everything.
            raw_output=$(pacman -Sp $candidates --print-format %n 2>&1)
            exit_code=$?

            if [ $exit_code -eq 0 ]; then
                # Success! Filter output.
                simulated_deps=$(echo "$raw_output" | grep -v '^::' | awk 'NF==1 {print $1}')
                break
            else
                # Failure. Look for specific broken dependency error.
                # Error format: "installing pkgA (ver) breaks dependency 'pkgA=oldver' required by pkgB"
                # We want 'pkgB'.
                broken_req=$(echo "$raw_output" | grep -o "required by [^ ]*" | awk '{print $3}' | head -n 1)

                if [ -n "$broken_req" ]; then
                     # Found a resolution candidate
                     # Avoid infinite loops if it suggests the same thing (though unlikely if we append)
                     if [[ " $candidates " =~ " $broken_req " ]]; then
                         # Already tried adding this, something else is wrong.
                         break
                     fi

                     echo -e "${YELLOW}  [Auto-Resolving] Adding '$broken_req' to transaction to fix partial upgrade conflict...${NC}" >&2
                     candidates="$candidates $broken_req"
                     # Continue loop to retry
                else
                     # Unknown error, stop trying
                     break
                fi
            fi
        done
        ;;
esac

# Merge and uniquify
# We treat all inputs as potential packages.
all_packages=$(echo "$requested_packages $simulated_deps" | tr ' ' '\n' | sort -u | grep -v '^$')
total_count=$(echo "$all_packages" | wc -w)

if [ "$total_count" -eq 0 ]; then
    echo -e "${YELLOW}Warning: No packages found or invalid package names.${NC}"
fi

echo "Total packages to be analyzed: $total_count"
echo "-------------------------------------"

for package_name in $all_packages; do
    # Display Status
    is_requested=0
    # Check if package_name is in requested_packages.
    # Simple grep check (adding spaces to match exact words)
    if [[ " $requested_packages " =~ " $package_name " ]]; then
        is_requested=1
        printf "Processing package: %s\n" "$package_name"
    else
        printf "Processing package: %s ${YELLOW}(dependency)${NC}\n" "$package_name"
    fi

    # --- REBOOT/INITRAMFS CHECKS ---
    IS_KERNEL=0
    IS_SYSTEMD=0
    HAS_REBOOT_TRIGGER=0
    HAS_INIT_TRIGGER=0

    case $PM_TYPE in
        deb)
            [[ "$package_name" =~ ^linux-image- ]] && IS_KERNEL=1
            [[ "$package_name" == "systemd" ]] && IS_SYSTEMD=1
            if grep -qs "reboot-notifier" /var/lib/dpkg/info/"$package_name".{triggers,postinst} 2>/dev/null; then HAS_REBOOT_TRIGGER=1; fi
            if grep -qs "update-initramfs" /var/lib/dpkg/info/"$package_name".{triggers,postinst} 2>/dev/null; then HAS_INIT_TRIGGER=1; fi
            ;;
        rpm)
            [[ "$package_name" =~ ^kernel ]] && IS_KERNEL=1
            [[ "$package_name" == "systemd" ]] && IS_SYSTEMD=1
            # rpm scripts can be viewed. We grep for likely keywords.
            if rpm -q --scripts "$package_name" 2>/dev/null | grep -Eiq "reboot|restart-required"; then HAS_REBOOT_TRIGGER=1; fi
            if rpm -q --scripts "$package_name" 2>/dev/null | grep -Eiq "dracut|initramfs"; then HAS_INIT_TRIGGER=1; fi
            ;;
        arch)
            [[ "$package_name" =~ ^linux ]] && IS_KERNEL=1
            [[ "$package_name" == "systemd" ]] && IS_SYSTEMD=1
            # Arch hooks are often in /usr/share/libalpm/hooks/ but verifying per-package trigger is hard.
            # We check if the package *contains* initcpio related files which usually implies it regenerates it.
            if pacman -Ql "$package_name" 2>/dev/null | grep -Eq "/usr/lib/initcpio/|mkinitcpio"; then HAS_INIT_TRIGGER=1; fi
            ;;
    esac

    if [ "$IS_KERNEL" -eq 1 ] || [ "$IS_SYSTEMD" -eq 1 ] || [ "$HAS_REBOOT_TRIGGER" -eq 1 ]; then
        printf "  ${RED}${BOLD}[!] REBOOT RECOMMENDED:${NC} %s affects core system state.\n" "$package_name"
    fi
    if [ "$HAS_INIT_TRIGGER" -eq 1 ]; then
        printf "  ${YELLOW}${BOLD}[!] WARNING:${NC} This package likely triggers an initramfs/initrd update.\n"
    fi

    # --- FILE & PROCESS CHECKS ---

    # 1. Get List of Files
    raw_files=""
    case $PM_TYPE in
        deb)
            raw_files=$(dpkg -L "$package_name" 2>/dev/null)
            ;;
        rpm)
            raw_files=$(rpm -ql "$package_name" 2>/dev/null)
            ;;
        arch)
            # -Ql outputs "pkgname /path/to/file". -q suppresses pkgname? No, -Ql is query list.
            # pacman -Qlq outputs just file paths.
            raw_files=$(pacman -Qlq "$package_name" 2>/dev/null)
            ;;
    esac

    if [ -z "$raw_files" ]; then
        # If no files found, package might not be installed (only available for upgrade/install).
        # We can't check impact of a not-yet-installed package's *current* files,
        # BUT if it's an UPGRADE, the previous version is installed.
        #
        # NOTE: logic assumption: 'check_pkg_impact' assumes checking against currently installed files
        # to see what processes are holding them.
        # If 'package_name' is not installed, dpkg -L/rpm -ql fails.
        echo "  --> No installed files found (Package not installed or has no files)."
        continue
    fi

    # 2. Filter for Binaries/Libraries (ELF)
    # Using xargs to batch process 'file' command is efficient.
    # Handling filnames with spaces is tricky with simple xargs, but standard package files usually don't have crazy names.
    # We use -d '\n' for xargs to safely handle lines.

    # pipe raw_files into file command
    # Filter for ELF executable or shared object
    # cut -d: -f1 to get filename back
    relevant_files=$(echo "$raw_files" | tr '\n' '\0' | xargs -r -0 file --separator ': ' | grep -E ': +ELF .*(executable|shared object)' | cut -d: -f1)

    if [ -z "$relevant_files" ]; then
        echo "  --> No relevant binaries/libraries found in this package."
        continue
    fi

    # 3. Check Processes with lsof
    # -F pcf: output Pid, Command, File (machine readable)
    impacted_procs=$(lsof -F pcf $relevant_files 2>/dev/null)

    if [ -z "$impacted_procs" ]; then
        echo "  --> No running processes found using files from $package_name."
        continue
    fi

    # --- FORMAT OUTPUT ---
    echo "  --> Impacted processes:"
    COMM_WIDTH="30"
    comm_underline=$(printf '%*s' "$COMM_WIDTH" '' | tr ' ' '-')

    printf "    %-8s %-${COMM_WIDTH}s %s\n" "PID" "Command" "Recommended Restart"
    printf "    %-8s %-${COMM_WIDTH}s %s\n" "-------" "$comm_underline" "-------------------"

    # unique PIDs
    pids=$(echo "$impacted_procs" | awk '/^p/ {print substr($0, 2)}' | sort -u)

    for pid in $pids; do
        # Get Command Name
        full_cmd=$(ps -p "$pid" -o args= 2>/dev/null | awk '{print $1}')

        if [ -z "$full_cmd" ]; then
             # Process might have died
             continue
        fi

        comm=$(basename -- "$full_cmd")
        # Truncate if too long
        if [ "${#comm}" -gt "$COMM_WIDTH" ]; then
            comm="${comm:0:$COMM_WIDTH}"
        fi

        # Get Systemd Unit
        unit=$(ps -p "$pid" -o unit= 2>/dev/null | grep ".service" | sed 's/\.service.*//' | xargs)

        if [ -n "$unit" ] && [ "$unit" != "-" ]; then
            repro="systemctl restart $unit"
        else
            repro="[Manual]"
        fi

        printf "    %-8s %-${COMM_WIDTH}s %s\n" "$pid" "$comm" "$repro"
    done
    echo ""

done

echo "-------------------------------------"
echo "Note: This identifies current usage. 'needrestart' (if available) can detect deleted libraries."

