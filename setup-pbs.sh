#!/usr/bin/env bash
# Configure the PBS LXC: disable the enterprise repository, install Tailscale and sign in.
# Run as root inside the LXC.
set -euo pipefail

TITLE="Share PBS"
LOG=/var/log/share-pbs.log
# The output is hidden: an apt prompt would wait for an answer that nobody can see.
export DEBIAN_FRONTEND=noninteractive

# whiptail leaves the dialog on the screen: clear it.
msg() { whiptail --title "$TITLE" --msgbox "$1" 0 0; clear; }
die() { msg "$1"; exit 1; }
# Print the text after the dialog: a closed dialog leaves nothing in the terminal to copy.
finish() { msg "$1"; echo "$1"; }
# Run a step with its output in $LOG. The console shows the step, then a check mark.
run() {
  local text=$1; shift
  printf '⏳ %s...' "$text"
  "$@" </dev/null >>"$LOG" 2>&1 || { echo; die "$text did not complete. Last lines of $LOG:

$(tail -n 8 "$LOG")"; }
  printf '\r\033[2K✔ %s\n' "$text"
}

[ "$(id -u)" -eq 0 ] || die "Run this script as root."
[ -c /dev/net/tun ] || die "/dev/net/tun is missing. Pass it to this LXC from the Proxmox host."

# Without a subscription the enterprise repository returns 401 and apt-get update fails.
enterprise=/etc/apt/sources.list.d/pbs-enterprise.sources
[ ! -f "$enterprise" ] || mv "$enterprise" "$enterprise.disabled"

: >"$LOG"
run "Updating package lists" apt-get update
command -v curl >/dev/null || run "Installing curl" apt-get install -y curl
run "Installing Tailscale" bash -o pipefail -c 'curl -fsSL https://tailscale.com/install.sh | sh'
run "Starting Tailscale" systemctl enable --now tailscaled

# tailscale up prints a login link and waits for the sign-in.
tailscale ip -4 >/dev/null 2>&1 || tailscale up

finish "Next: disable key expiry for this node in the Tailscale admin console. Do not tag this node."
