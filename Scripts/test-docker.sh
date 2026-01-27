#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DOCKER_BIN="${DOCKER_BIN:-docker}"
SSH_KEYGEN_BIN="/usr/bin/ssh-keygen"

if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
	echo "error: docker not found" >&2
	exit 1
fi

if [[ ! -x "$SSH_KEYGEN_BIN" ]]; then
	echo "error: ssh-keygen not found or not executable at $SSH_KEYGEN_BIN" >&2
	exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nsremoteshell-docker-XXXXXX")"
IMAGE_TAG="nsremoteshell-test-sshd:$(date +%s)-$$"
CONTAINER_NAME="nsremoteshell-test-sshd-$$"

cleanup() {
	if [[ -n "${CONTAINER_NAME:-}" ]]; then
		"$DOCKER_BIN" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
	fi
	if [[ -n "${IMAGE_TAG:-}" ]]; then
		"$DOCKER_BIN" image rm -f "$IMAGE_TAG" >/dev/null 2>&1 || true
	fi
	rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

CLIENT_KEY="$TMP_DIR/client_ed25519_key"
AUTHORIZED_KEYS="$TMP_DIR/authorized_keys"
DOCKER_CONTEXT="$TMP_DIR/context"
DOCKERFILE_PATH="$DOCKER_CONTEXT/Dockerfile"

mkdir -p "$DOCKER_CONTEXT"
"$SSH_KEYGEN_BIN" -t ed25519 -f "$CLIENT_KEY" -N "" >/dev/null
cp "${CLIENT_KEY}.pub" "$AUTHORIZED_KEYS"
cp "$AUTHORIZED_KEYS" "$DOCKER_CONTEXT/authorized_keys"

cat > "$DOCKERFILE_PATH" <<'EOF'
FROM ubuntu:24.04

RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server bash ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash nsremote \
	&& echo 'nsremote:nsremote' | chpasswd \
	&& mkdir -p /var/run/sshd /home/nsremote/.ssh \
	&& chown -R nsremote:nsremote /home/nsremote/.ssh \
	&& chmod 700 /home/nsremote/.ssh

COPY authorized_keys /home/nsremote/.ssh/authorized_keys

RUN chown nsremote:nsremote /home/nsremote/.ssh/authorized_keys \
	&& chmod 600 /home/nsremote/.ssh/authorized_keys \
	&& printf '%s\n' \
		'PasswordAuthentication no' \
		'KbdInteractiveAuthentication no' \
		'ChallengeResponseAuthentication no' \
		'UsePAM no' \
		'PermitRootLogin no' \
		'PubkeyAuthentication yes' \
		'AuthorizedKeysFile .ssh/authorized_keys' \
		'Subsystem sftp internal-sftp' \
		> /etc/ssh/sshd_config.d/nsremoteshell.conf

EXPOSE 22

CMD ["/bin/bash", "-lc", "ssh-keygen -A && exec /usr/sbin/sshd -D -e"]
EOF

"$DOCKER_BIN" build -t "$IMAGE_TAG" "$DOCKER_CONTEXT" >/dev/null
"$DOCKER_BIN" run -d --rm --name "$CONTAINER_NAME" -p 127.0.0.1::22 "$IMAGE_TAG" >/dev/null

PORT="$("$DOCKER_BIN" inspect --format '{{(index (index .NetworkSettings.Ports "22/tcp") 0).HostPort}}' "$CONTAINER_NAME")"
if [[ -z "$PORT" ]]; then
	echo "error: failed to determine mapped SSH port" >&2
	exit 1
fi

DEADLINE=$((SECONDS + 20))
while (( SECONDS < DEADLINE )); do
	if ! "$DOCKER_BIN" ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
		echo "error: ssh container exited early" >&2
		"$DOCKER_BIN" logs "$CONTAINER_NAME" >&2 || true
		exit 1
	fi

	if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
		break
	fi

	sleep 0.2
done

if (( SECONDS >= DEADLINE )); then
	echo "error: timed out waiting for container sshd on 127.0.0.1:$PORT" >&2
	"$DOCKER_BIN" logs "$CONTAINER_NAME" >&2 || true
	exit 1
fi

echo "docker sshd started: 127.0.0.1:$PORT container=$CONTAINER_NAME"

export NSREMOTE_SSH_HOST="127.0.0.1"
export NSREMOTE_SSH_PORT="$PORT"
export NSREMOTE_SSH_USERNAME="nsremote"
export NSREMOTE_SSH_TIMEOUT="8"
export NSREMOTE_SSH_PRIVATE_KEY="$CLIENT_KEY"
export NSREMOTE_SSH_PUBLIC_KEY="${CLIENT_KEY}.pub"

cd "$ROOT_DIR"
exec swift test "$@"
