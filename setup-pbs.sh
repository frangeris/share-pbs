#!/usr/bin/env bash
# Configure the PBS LXC: make the datastore folders, disable the enterprise repository,
# install Tailscale and sign in. Run as root inside the LXC.
# Dialogs ask for LOCAL_DIR and INCOMING_DIR. A variable in the environment changes
# the value that a dialog shows.
set -euo pipefail

TITLE="Share PBS"
LOG=/var/log/share-pbs.log
# The output is hidden: an apt prompt would wait for an answer that nobody can see.
export DEBIAN_FRONTEND=noninteractive

# whiptail leaves the dialog on the screen: clear it and keep the exit status.
wt() { local rc=0; whiptail --title "$TITLE" "$@" || rc=$?; clear; return "$rc"; }
msg() { wt --msgbox "$1" 0 0; }
die() { gauge_stop; msg "$1"; exit 1; }
# whiptail draws on stdout and writes the answer to stderr: swap them to catch the answer.
ask() { wt --inputbox "$1" 10 70 "$2" 3>&1 1>&2 2>&3; }
# Print the text after the dialog: a closed dialog leaves nothing in the terminal to copy.
finish() { msg "$1"; echo "$1"; }
# Loading bar: one whiptail --gauge stays open on fd 4 while the steps run.
gauge_stop() {
  exec 4>&-
  [ -z "${GAUGE_PID:-}" ] || { wait "$GAUGE_PID" 2>/dev/null || true; GAUGE_PID=; clear; }
}
# Run a step with its output in $LOG. The dialog shows the percent and the text.
run() {
  local pct=$1 text=$2; shift 2
  if [ -z "${GAUGE_PID:-}" ]; then
    exec 4> >(whiptail --title "$TITLE" --gauge "Starting..." 7 64 0)
    GAUGE_PID=$!
  fi
  printf 'XXX\n%s\n%s...\nXXX\n' "$pct" "$text" >&4
  "$@" </dev/null >>"$LOG" 2>&1 || die "$text did not complete. Last lines of $LOG:

$(tail -n 8 "$LOG")"
}

[ "$(id -u)" -eq 0 ] || die "Run this script as root."
[ -c /dev/net/tun ] || die "/dev/net/tun is missing. Pass it to this LXC from the Proxmox host."

LOCAL_DIR=$(ask "Enter the folder for your backups" "${LOCAL_DIR:-/mnt/local}")
INCOMING_DIR=$(ask "Enter the folder for incoming backups" "${INCOMING_DIR:-/mnt/incoming}")
for d in "$LOCAL_DIR" "$INCOMING_DIR"; do
  [[ $d == /* ]] || die "\"$d\" is not a full path."
  mkdir -p "$d" || die "Cannot make the folder $d."
done

# Without a subscription the enterprise repository returns 401 and apt-get update fails.
enterprise=/etc/apt/sources.list.d/pbs-enterprise.sources
[ ! -f "$enterprise" ] || mv "$enterprise" "$enterprise.disabled"

: >"$LOG"
run 10 "Updating package lists" apt-get update
command -v curl >/dev/null || run 30 "Installing curl" apt-get install -y curl
run 50 "Installing Tailscale" bash -o pipefail -c 'curl -fsSL https://tailscale.com/install.sh | sh'
run 90 "Starting Tailscale" systemctl enable --now tailscaled
gauge_stop

# tailscale up prints a login link and waits for the sign-in. It needs the terminal, not the gauge.
tailscale ip -4 >/dev/null 2>&1 || tailscale up

finish "Next: disable key expiry for this node in the Tailscale admin console. Do not tag this node."
