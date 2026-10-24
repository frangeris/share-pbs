#!/usr/bin/env bash
# Configure the rclone LXC: join Tailscale and serve a folder as S3 over HTTPS.
# Run as root inside the LXC. Dialogs ask for DATA_DIR, the folder for the backups
# (/srv/s3), BUCKET (pbs) and PORT (8443).
# A variable in the environment changes the value that a dialog shows. ACCESS_KEY
# and SECRET_KEY have no dialog: set them in the environment, or the script makes
# random values.
set -euo pipefail

CONF=/etc/rclone-s3
TITLE="Share PBS"

msg() { whiptail --title "$TITLE" --msgbox "$1" 0 0; }
die() { msg "$1"; exit 1; }
# whiptail draws on stdout and writes the answer to stderr: swap them to catch the answer.
ask() { whiptail --title "$TITLE" --inputbox "$1" 10 70 "$2" 3>&1 1>&2 2>&3; }
# Print the text after the dialog: a closed dialog leaves nothing in the terminal to copy.
finish() { msg "$1"; echo "$1"; }

[ "$(id -u)" -eq 0 ] || die "Run this script as root."
[ -c /dev/net/tun ] || die "/dev/net/tun is missing. Pass it to this LXC from the Proxmox host."
RCLONE=
# /opt/rclone/rclone is where the Proxmox community script installs it, outside of PATH.
for p in "$(command -v rclone || true)" /usr/local/bin/rclone /usr/bin/rclone /opt/rclone/rclone; do
  [ -x "$p" ] && { RCLONE=$p; break; }
done
[ -n "$RCLONE" ] || die "rclone is not installed. Install it in this LXC first."
"$RCLONE" serve s3 --help >/dev/null 2>&1 || die "This rclone is too old for serve s3. Install a newer version."

if [ -f "$CONF/env" ]; then
  # Second start: keep the stored settings.
  # shellcheck disable=SC1091
  . "$CONF/env"
  BUCKET=${BUCKET:-pbs}
else
  DATA_DIR=$(ask "Folder for the backups" "${DATA_DIR:-/srv/s3}")
  BUCKET=$(ask "Bucket name" "${BUCKET:-pbs}")
  PORT=$(ask "HTTPS port" "${PORT:-8443}")
fi

[ -n "$BUCKET" ] || die "The bucket name is empty."
[[ $PORT =~ ^[0-9]+$ ]] || die "The port must be a number."
# Without a mount, rclone writes to the disk of the LXC and can fill it.
if ! mountpoint -q "$DATA_DIR"; then
  whiptail --title "$TITLE" --defaultno --yesno "$DATA_DIR is not a mount point.

rclone will write the backups to the disk of this LXC. A full disk stops the LXC.
Mount a folder at $DATA_DIR instead.

Continue?" 13 70 || exit 1
fi

apt-get update
command -v curl >/dev/null || apt-get install -y curl
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

# Do not add --accept-routes: it sends LAN traffic through the subnet router.
tailscale ip -4 >/dev/null 2>&1 || tailscale up

apt-get install -y jq openssl nftables

mkdir -p "$DATA_DIR/$BUCKET" "$CONF"
fqdn=$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')

# shortcut: the keys appear in the rclone command line, fine for a single-purpose LXC.
if [ ! -f "$CONF/env" ]; then
  (
    umask 077
    cat > "$CONF/env" <<EOF
DATA_DIR=$DATA_DIR
PORT=$PORT
ACCESS_KEY=${ACCESS_KEY:-$(openssl rand -hex 12)}
SECRET_KEY=${SECRET_KEY:-$(openssl rand -hex 24)}
EOF
  )
fi

if [ ! -f "$CONF/cert.pem" ]; then
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -keyout "$CONF/key.pem" -out "$CONF/cert.pem" -subj "/CN=rclone" \
    -addext "subjectAltName=DNS:$fqdn"
  chmod 600 "$CONF/key.pem"
fi

# Block new connections from this LXC to the LAN. Replies to LAN hosts, DNS and DHCP stay open.
# shortcut: IPv4 private ranges and IPv6 ULA only, a LAN host with a public IPv6 address stays reachable.
cat > "$CONF/lan-block.nft" <<'EOF'
table inet pbsshare
delete table inet pbsshare
table inet pbsshare {
  chain out {
    type filter hook output priority 0; policy accept;
    ct state established,related accept
    udp dport { 53, 67 } accept
    tcp dport 53 accept
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } drop
    ip6 daddr fc00::/7 drop
  }
}
EOF

cat > /etc/systemd/system/rclone-s3.service <<EOF
[Unit]
Description=rclone S3 server
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
EnvironmentFile=$CONF/env
ExecStartPre=$(command -v nft) -f $CONF/lan-block.nft
ExecStart=$RCLONE serve s3 \${DATA_DIR} --addr :\${PORT} --cert $CONF/cert.pem --key $CONF/key.pem --auth-key \${ACCESS_KEY},\${SECRET_KEY}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now rclone-s3
sleep 2
systemctl is-active --quiet rclone-s3 || { journalctl -u rclone-s3 -n 20 --no-pager >&2; exit 1; }

# shellcheck disable=SC1091
. "$CONF/env"
finish "Endpoint:    $fqdn:$PORT
Bucket:      $BUCKET
Access key:  $ACCESS_KEY
Secret key:  $SECRET_KEY
Fingerprint: $(openssl x509 -in "$CONF/cert.pem" -noout -fingerprint -sha256)
Next: disable key expiry for this node, tag it with tag:shared, and share it with the other person."
