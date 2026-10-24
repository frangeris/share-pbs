#!/usr/bin/env bash
# Configure the PBS LXC: disable the enterprise repository and join Tailscale.
# Run as root inside the LXC.
set -euo pipefail

TITLE="Share PBS"

msg() { whiptail --title "$TITLE" --msgbox "$1" 0 0; }
die() { msg "$1"; exit 1; }
# Print the text after the dialog: a closed dialog leaves nothing in the terminal to copy.
finish() { msg "$1"; echo "$1"; }

[ "$(id -u)" -eq 0 ] || die "Run this script as root."
[ -c /dev/net/tun ] || die "/dev/net/tun is missing. Pass it to this LXC from the Proxmox host."

# Without a subscription the enterprise repository returns 401 and apt-get update fails.
enterprise=/etc/apt/sources.list.d/pbs-enterprise.sources
[ ! -f "$enterprise" ] || mv "$enterprise" "$enterprise.disabled"

apt-get update
command -v curl >/dev/null || apt-get install -y curl
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

# Do not add --accept-routes: it sends LAN traffic through the subnet router.
tailscale ip -4 >/dev/null 2>&1 || tailscale up

finish "Tailscale IP: $(tailscale ip -4)
Next: disable key expiry for this node in the Tailscale admin console. Do not tag this node."
