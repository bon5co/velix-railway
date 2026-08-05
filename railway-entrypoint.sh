#!/bin/sh
# Velix API on Railway.
#
# Three things happen here that upstream's own image cannot do for itself,
# because it ships distroless (no shell) and runs as uid 65532:
#
#   1. Repair the volume's ownership. Railway mounts volumes owned by uid 0, and
#      the app runs as 65532, so the stock image boots HEALTHY and then fails
#      every single instance creation with
#        register in engine: create store dir: mkdir /data/instances: permission denied
#      The healthcheck never notices — /health only answers from the HTTP server.
#   2. Create the workspace and its admin user on first boot, from the
#      environment, so the deployer gets credentials they control instead of
#      having to be the first stranger to find the URL.
#   3. Put a gateway in front, which is where signup is closed and where the
#      login endpoint gets a throttle (upstream has neither).
set -eu

log() { echo "[railway-entrypoint] $*"; }

PORT="${PORT:-8080}"
HTTP_PORT="${HTTP_PORT:-8090}"
HTTP_HOST="${HTTP_HOST:-127.0.0.1}"
DATA_DIR="${VELIX_DATA_DIR:-/data}"
VELIX_UID="${VELIX_UID:-65532}"
export PORT HTTP_PORT HTTP_HOST

# --- 1. volume ------------------------------------------------------------
mkdir -p "$DATA_DIR"
owner="$(stat -c %u "$DATA_DIR")"
if [ "$owner" != "$VELIX_UID" ]; then
    log "volume $DATA_DIR owned by uid $owner, repairing to $VELIX_UID"
    chown -R "$VELIX_UID:$VELIX_UID" "$DATA_DIR"
fi
mkdir -p "${ENGINE_STORE_PATH:-$DATA_DIR/instances}" "${MEDIA_STORAGE_PATH:-$DATA_DIR/media}"
chown "$VELIX_UID:$VELIX_UID" "${ENGINE_STORE_PATH:-$DATA_DIR/instances}" "${MEDIA_STORAGE_PATH:-$DATA_DIR/media}"
log "volume ready owner=$(stat -c %u:%g "$DATA_DIR") store=${ENGINE_STORE_PATH:-$DATA_DIR/instances}"

# --- 2. wait for Postgres and Redis --------------------------------------
# The app calls log.Fatal when either is unreachable, and on a template deploy
# all three services start together, so without this the first boot always dies
# once and waits out a restart backoff before it can migrate.
wait_for() {
    name="$1"; url="$2"
    [ -n "$url" ] || return 0
    hostport="${url#*://}"; hostport="${hostport#*@}"; hostport="${hostport%%/*}"; hostport="${hostport%%\?*}"
    host="${hostport%%:*}"; port="${hostport##*:}"
    case "$port" in ''|*[!0-9]*) port="$3" ;; esac
    n=0
    while [ "$n" -lt 60 ]; do
        nc -z "$host" "$port" 2>/dev/null && { log "$name reachable at $host:$port"; return 0; }
        sleep 2
        n=$((n + 1))
    done
    log "WARNING: $name still unreachable at $host:$port after 120s, starting anyway"
}
wait_for postgres "${DATABASE_URL:-}" 5432
wait_for redis "${REDIS_URL:-}" 6379

# --- 3. app ---------------------------------------------------------------
su-exec "$VELIX_UID:$VELIX_UID" /usr/local/bin/velix-api &
VELIX_PID=$!

ready=0
i=0
while [ "$i" -lt 120 ]; do
    if ! kill -0 "$VELIX_PID" 2>/dev/null; then
        log "velix-api exited during startup"
        wait "$VELIX_PID" || exit $?
        exit 1
    fi
    if curl -fsS -o /dev/null "http://127.0.0.1:${HTTP_PORT}/health" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
[ "$ready" = 1 ] && log "velix-api healthy on 127.0.0.1:${HTTP_PORT}" \
    || log "velix-api did not answer /health in 120s, continuing anyway"

# --- 4. first-boot workspace ----------------------------------------------
# Idempotent: a second boot gets CONFLICT from the unique constraint on the
# workspace slug and leaves the existing workspace alone.
# Upstream rejects a password that is not >=8 chars with an uppercase, a lowercase
# and a digit, and it rejects it AFTER the request, so a weak value would show up
# only as a 422 in the deploy log. Checked here so the message names the rule.
password_ok() {
    p="$1"
    [ "${#p}" -ge 8 ] || return 1
    case "$p" in *[A-Z]*) ;; *) return 1 ;; esac
    case "$p" in *[a-z]*) ;; *) return 1 ;; esac
    case "$p" in *[0-9]*) ;; *) return 1 ;; esac
    return 0
}
if [ -n "${VELIX_ADMIN_PASSWORD:-}" ] && ! password_ok "$VELIX_ADMIN_PASSWORD"; then
    log "ERROR: VELIX_ADMIN_PASSWORD must be at least 8 characters with an uppercase letter, a lowercase letter and a digit. Skipping workspace bootstrap; fix the variable and redeploy."
    VELIX_ADMIN_PASSWORD=""
fi

if [ "$ready" = 1 ] && [ -n "${VELIX_ADMIN_PASSWORD:-}" ]; then
    body=$(printf '{"email":"%s","password":"%s","name":"%s","slug":"%s","workspace_name":"%s"}' \
        "${VELIX_ADMIN_EMAIL:-admin@velix.local}" "$VELIX_ADMIN_PASSWORD" \
        "${VELIX_ADMIN_NAME:-Admin}" "${VELIX_WORKSPACE_SLUG:-default}" \
        "${VELIX_WORKSPACE_NAME:-Default}")
    code=$(curl -s -o /tmp/velix-bootstrap.json -w '%{http_code}' \
        -X POST "http://127.0.0.1:${HTTP_PORT}/v1/auth/register" \
        -H 'Content-Type: application/json' -d "$body" || echo 000)
    case "$code" in
        200|201)
            log "workspace '${VELIX_WORKSPACE_SLUG:-default}' created, admin ${VELIX_ADMIN_EMAIL:-admin@velix.local}" ;;
        409)
            log "workspace '${VELIX_WORKSPACE_SLUG:-default}' already exists, keeping it"
            lcode=$(curl -s -o /dev/null -w '%{http_code}' \
                -X POST "http://127.0.0.1:${HTTP_PORT}/v1/auth/login" \
                -H 'Content-Type: application/json' \
                -d "$(printf '{"email":"%s","password":"%s"}' \
                    "${VELIX_ADMIN_EMAIL:-admin@velix.local}" "$VELIX_ADMIN_PASSWORD")" || echo 000)
            [ "$lcode" = 200 ] || log "WARNING: VELIX_ADMIN_PASSWORD does not match the stored admin password (login $lcode). The password is only applied when the workspace is first created; change it from the admin UI instead."
            ;;
        *)
            log "workspace bootstrap returned $code: $(head -c 300 /tmp/velix-bootstrap.json 2>/dev/null)" ;;
    esac
elif [ -z "${VELIX_ADMIN_PASSWORD:-}" ]; then
    log "VELIX_ADMIN_PASSWORD unset, skipping workspace bootstrap"
fi

# --- 5. gateway -----------------------------------------------------------
envsubst '${PORT} ${HTTP_PORT} ${VELIX_MAX_BODY_SIZE} ${VELIX_AUTH_RATE} ${VELIX_AUTH_BURST} ${VELIX_PUBLIC_REGISTRATION}' \
    < /etc/velix/nginx.conf.template > /tmp/nginx.conf
log "gateway listening on ${PORT}, registration_open=${VELIX_PUBLIC_REGISTRATION:-false}"

# nginx becomes pid 1 below, so if the app dies the container must die with it —
# otherwise the healthcheck keeps passing against a gateway with nothing behind it.
(
    while kill -0 "$VELIX_PID" 2>/dev/null; do sleep 5; done
    echo "[railway-entrypoint] velix-api exited, stopping gateway"
    kill 1 2>/dev/null || true
) &

exec nginx -c /tmp/nginx.conf -g 'daemon off;'
