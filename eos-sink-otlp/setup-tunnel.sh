#!/usr/bin/env bash
# Sets up an SSH tunnel so eos-sink-otlp can reach an OTLP collector on a
# different host while only ever dialing 127.0.0.1. Run this on the side
# that will INITIATE the SSH connection:
#   --direction local   (default): run on the eos/service host, tunnels out
#                         to a collector on another VPS (-L).
#   --direction reverse : run on the collector host (e.g. your home
#                         machine, behind NAT), dials out to the VPS
#                         running eos so the VPS's loopback reaches back
#                         to this machine's collector (-R).
#
# Requires root (creates a dedicated system user + systemd unit). Prints
# the authorized_keys line YOU must add on the OTHER host before
# continuing — this script never touches the remote host's key/user setup.
set -euo pipefail

DIRECTION="local"
REMOTE_HOST=""
REMOTE_USER="otlp-tunnel"
REMOTE_SSH_PORT="22"
OTLP_PORT="4317"
LOCAL_USER="eos-otlp-tunnel"
SERVICE_NAME="eos-otlp-tunnel"
ASSUME_YES="no"

usage() {
	cat <<EOF
Usage: $0 --remote-host HOST [options]

Required:
  --remote-host HOST       Hostname/IP of the other side of the tunnel.

Options:
  --direction local|reverse   local = -L, this host dials out to a remote
                               collector (default). reverse = -R, this host
                               dials out to a remote eos host so a collector
                               running HERE receives its traffic (e.g. this
                               host is behind NAT and can't accept inbound).
  --remote-user USER          SSH login user for the tunnel on the far side.
                               Default: otlp-tunnel
  --remote-ssh-port PORT      Default: 22
  --port PORT                 OTLP port forwarded on both ends. Default: 4317
  --local-user USER           Dedicated local system user that owns the key
                               and runs the tunnel. Default: eos-otlp-tunnel
  --service-name NAME         systemd unit name. Default: eos-otlp-tunnel
  -y, --yes                   Don't pause for confirmation before continuing
                               past the "add this key" step.
  -h, --help                  Show this help.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--direction) DIRECTION="$2"; shift 2 ;;
	--remote-host) REMOTE_HOST="$2"; shift 2 ;;
	--remote-user) REMOTE_USER="$2"; shift 2 ;;
	--remote-ssh-port) REMOTE_SSH_PORT="$2"; shift 2 ;;
	--port) OTLP_PORT="$2"; shift 2 ;;
	--local-user) LOCAL_USER="$2"; shift 2 ;;
	--service-name) SERVICE_NAME="$2"; shift 2 ;;
	-y | --yes) ASSUME_YES="yes"; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	echo "must run as root (creates a system user + systemd unit)" >&2
	exit 1
fi
if [ -z "$REMOTE_HOST" ]; then
	echo "--remote-host is required" >&2
	exit 1
fi
if [ "$DIRECTION" != "local" ] && [ "$DIRECTION" != "reverse" ]; then
	echo "--direction must be 'local' or 'reverse'" >&2
	exit 1
fi

HOME_DIR="/var/lib/${LOCAL_USER}"
KEY_PATH="${HOME_DIR}/.ssh/otlp_tunnel_key"
KNOWN_HOSTS="${HOME_DIR}/.ssh/known_hosts"

echo "== 1/6: dedicated local user =="
if ! id "$LOCAL_USER" >/dev/null 2>&1; then
	useradd -r -m -d "$HOME_DIR" -s /usr/sbin/nologin "$LOCAL_USER"
	echo "created system user $LOCAL_USER"
else
	echo "user $LOCAL_USER already exists, reusing"
fi
install -d -o "$LOCAL_USER" -g "$LOCAL_USER" -m 700 "${HOME_DIR}/.ssh"

echo "== 2/6: tunnel keypair =="
if [ ! -f "$KEY_PATH" ]; then
	sudo -u "$LOCAL_USER" ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "${LOCAL_USER}@$(hostname)" -q
	echo "generated $KEY_PATH"
else
	echo "$KEY_PATH already exists, reusing"
fi
PUBKEY="$(cat "${KEY_PATH}.pub")"

echo
echo "== 3/6: add this to the OTHER host =="
echo
if [ "$DIRECTION" = "local" ]; then
	# This host dials OUT (-L); the far end is the ssh SERVER and must
	# allow this key to open a connection TO 127.0.0.1:$OTLP_PORT.
	# 'restrict' alone does NOT let 'permitopen' re-enable forwarding —
	# needs the explicit 'port-forwarding' flag too, or sshd silently
	# refuses every channel-open while still reporting the local listener
	# as up. Confirmed on OpenSSH 10.2 despite sshd(8)'s own example
	# implying permitopen is sufficient on its own.
	RESTRICTION="restrict,port-forwarding,permitopen=\"127.0.0.1:${OTLP_PORT}\""
else
	# This host dials OUT (-R) so a collector running HERE receives
	# traffic; the far end (running eos) is the ssh SERVER and must
	# allow this key to LISTEN on its own 127.0.0.1:$OTLP_PORT.
	RESTRICTION="restrict,port-forwarding,permitlisten=\"127.0.0.1:${OTLP_PORT}\""
fi
echo "On ${REMOTE_HOST}, as the ${REMOTE_USER} user, append to ~${REMOTE_USER}/.ssh/authorized_keys:"
echo
echo "  ${RESTRICTION} ${PUBKEY}"
echo
echo "(that user should exist with a non-interactive shell — e.g. 'useradd -r -m -s /usr/sbin/nologin ${REMOTE_USER}'"
echo " — and the collector on that side, if this is --direction local, must itself bind only 127.0.0.1:${OTLP_PORT}, never 0.0.0.0)"
echo

if [ "$ASSUME_YES" != "yes" ]; then
	read -r -p "Press enter once that's done (Ctrl-C to abort)... " _
fi

echo "== 4/6: pin the remote host key =="
SCAN_LINE="$(ssh-keyscan -t ed25519 -p "$REMOTE_SSH_PORT" "$REMOTE_HOST" 2>/dev/null || true)"
if [ -z "$SCAN_LINE" ]; then
	echo "could not reach ${REMOTE_HOST}:${REMOTE_SSH_PORT} to scan its host key" >&2
	exit 1
fi
FINGERPRINT="$(ssh-keygen -lf <(echo "$SCAN_LINE" | cut -d' ' -f2-))"
echo "Host key for ${REMOTE_HOST}: ${FINGERPRINT}"
echo "Verify this out-of-band (your VPS provider's console/API, or a channel you already trust) before continuing."
if [ "$ASSUME_YES" != "yes" ]; then
	read -r -p "Matches? [y/N] " CONFIRM
	if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
		echo "aborting — fingerprint not confirmed" >&2
		exit 1
	fi
fi
echo "$SCAN_LINE" | sudo -u "$LOCAL_USER" tee -a "$KNOWN_HOSTS" >/dev/null
chmod 600 "$KNOWN_HOSTS"

echo "== 5/6: systemd unit =="
if [ "$DIRECTION" = "local" ]; then
	FORWARD_FLAG="-L 127.0.0.1:${OTLP_PORT}:127.0.0.1:${OTLP_PORT}"
else
	FORWARD_FLAG="-R 127.0.0.1:${OTLP_PORT}:127.0.0.1:${OTLP_PORT}"
fi
cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=SSH tunnel (${DIRECTION}) for eos-sink-otlp: 127.0.0.1:${OTLP_PORT} <-> ${REMOTE_HOST}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${LOCAL_USER}
ExecStart=/usr/bin/ssh -N \\
  -p ${REMOTE_SSH_PORT} \\
  -o ExitOnForwardFailure=yes \\
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \\
  -o StrictHostKeyChecking=yes \\
  -o BatchMode=yes \\
  -i ${KEY_PATH} \\
  ${FORWARD_FLAG} \\
  ${REMOTE_USER}@${REMOTE_HOST}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"
echo "started ${SERVICE_NAME}.service"

echo "== 6/6: self-test =="
sleep 2
if [ "$DIRECTION" = "local" ]; then
	if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${OTLP_PORT}" 2>/dev/null; then
		echo "OK: 127.0.0.1:${OTLP_PORT} reachable locally through the tunnel."
		echo "eos-sink-otlp on this host can now use address: \"127.0.0.1:${OTLP_PORT}\", insecure: true"
	else
		echo "FAILED: could not reach 127.0.0.1:${OTLP_PORT} through the tunnel." >&2
		echo "Check: 'systemctl status ${SERVICE_NAME}', and that the authorized_keys line" >&2
		echo "on ${REMOTE_HOST} matches EXACTLY what was printed above (the port-forwarding flag" >&2
		echo "is easy to drop and fails silently — the tunnel process stays up either way)." >&2
		exit 1
	fi
else
	echo "Tunnel started. This host can't self-test the far end (that's on ${REMOTE_HOST})."
	echo "On ${REMOTE_HOST}, verify with:"
	echo "  timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/${OTLP_PORT}' && echo OK || echo FAIL"
	echo "eos-sink-otlp on ${REMOTE_HOST} can then use address: \"127.0.0.1:${OTLP_PORT}\", insecure: true"
fi
