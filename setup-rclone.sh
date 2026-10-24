#!/usr/bin/env bash
# Configure the rclone LXC: install Tailscale and serve a folder as S3 over HTTPS.
# Run as root inside the LXC. Dialogs ask for DATA_DIR, the folder for the backups
# (/srv/backups-s3), BUCKET (pbs) and PORT (8443).
# A variable in the environment changes the value that a dialog shows. ACCESS_KEY
# and SECRET_KEY have no dialog: set them in the environment, or the script keeps
# the values of an earlier run, or makes random values.
set -euo pipefail

CONF=/etc/rclone-s3
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
# Loading bar: one whiptail --gauge stays open on fd 4 while the steps run.
gauge_stop() {
  exec 4>&-
  [ -z "${GAUGE_PID:-}" ] || { wait "$GAUGE_PID" 2>/dev/null || true; GAUGE_PID=; }
}
# Run a step with its output in $LOG. The dialog shows the percent and the text.
run() {
  local pct=$1 text=$2; shift 2
  if [ -z "${GAUGE_PID:-}" ]; then
    exec 4> >(whiptail --title "$TITLE" --gauge "" 7 64 0)
    GAUGE_PID=$!
  fi
  printf 'XXX\n%s\n%s...\nXXX\n' "$pct" "$text" >&4
  "$@" </dev/null >>"$LOG" 2>&1 || die "$text did not complete. Last lines of $LOG:

$(tail -n 8 "$LOG")"
}

[ "$(id -u)" -eq 0 ] || die "Run this script as root."
[ -c /dev/net/tun ] || die "/dev/net/tun is missing. Pass it to this LXC from the Proxmox host."
RCLONE=
# /opt/rclone/rclone is where the Proxmox community script installs it, outside of PATH.
for p in "$(command -v rclone || true)" /usr/local/bin/rclone /usr/bin/rclone /opt/rclone/rclone; do
  [ -x "$p" ] && { RCLONE=$p; break; }
done
[ -n "$RCLONE" ] || die "rclone is not installed. Install it in this LXC first."
"$RCLONE" serve s3 --help >/dev/null 2>&1 || die "This rclone is too old for serve s3. Install a newer version."

# The values of an earlier run are the defaults of the dialogs and the keys stay the same.
# A variable in the environment wins.
if [ -f "$CONF/env" ]; then
  while IFS== read -r k v; do [ -n "${!k:-}" ] || printf -v "$k" %s "$v"; done < "$CONF/env"
fi
DATA_DIR=$(ask "Folder for the backups" "${DATA_DIR:-/srv/backups-s3}")
BUCKET=$(ask "Bucket name" "${BUCKET:-pbs}")
PORT=$(ask "HTTPS port" "${PORT:-8443}")

[ -n "$BUCKET" ] || die "The bucket name is empty."
[[ $PORT =~ ^[0-9]+$ ]] || die "The port must be a number."
# Without a mount, rclone writes to the disk of the LXC and can fill it.
if ! mountpoint -q "$DATA_DIR"; then
  wt --defaultno --yesno "Warning!

$DATA_DIR is a simple folder in this container, not a mounted folder.

rclone saves the backups on the disk of this LXC. If this disk is full, the LXC stops.

Continue anyway?" 13 70 || exit 1
fi

: >"$LOG"
run 10 "Updating package lists" apt-get update
run 25 "Installing curl, jq, openssl and nftables" apt-get install -y curl jq openssl nftables
command -v tailscale >/dev/null || run 40 "Installing Tailscale" bash -o pipefail -c 'curl -fsSL https://tailscale.com/install.sh | sh'
run 50 "Starting Tailscale" systemctl enable --now tailscaled
gauge_stop
# tailscale up prints a login link and waits for the sign-in. It needs the terminal, not the gauge.
tailscale ip -4 >/dev/null 2>&1 || tailscale up

mkdir -p "$DATA_DIR/$BUCKET" "$CONF"
fqdn=$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')

# shortcut: the keys appear in the rclone command line, fine for a single-purpose LXC.
(
  umask 077
  cat > "$CONF/env" <<EOF
DATA_DIR=$DATA_DIR
BUCKET=$BUCKET
PORT=$PORT
ACCESS_KEY=${ACCESS_KEY:-$(openssl rand -hex 12)}
SECRET_KEY=${SECRET_KEY:-$(openssl rand -hex 24)}
EOF
)

if [ ! -f "$CONF/cert.pem" ]; then
  run 60 "Generating certificate" openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
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
run 85 "Starting rclone" bash -c 'systemctl enable rclone-s3 && systemctl restart rclone-s3'
sleep 2
systemctl is-active --quiet rclone-s3 || { gauge_stop; journalctl -u rclone-s3 -n 20 --no-pager >&2; exit 1; }
gauge_stop

# shellcheck disable=SC1091
. "$CONF/env"
creds=$HOME/endpoint-s3.creds
(
  umask 077
  cat > "$creds" <<EOF
Endpoint:    $fqdn:$PORT
Bucket:      $BUCKET
Access key:  $ACCESS_KEY
Secret key:  $SECRET_KEY
Fingerprint: $(openssl x509 -in "$CONF/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)
EOF
)
msg "S3 endpoint details:

$(cat "$creds")

Saved in ~/endpoint-s3.creds"
