# velix-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/velix-api-v100-or-self-hosted-whatsapp-r?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [Velix API template](https://railway.com/deploy/velix-api-v100-or-self-hosted-whatsapp-r?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

Wrapper image for running [Velix API](https://docs.dokploy.com/docs/templates/velix-api) — a
self-hosted, multi-instance WhatsApp REST API — on [Railway](https://railway.com).

`ghcr.io/bon5co/velix-railway:latest` — built from `ghcr.io/paulolinder/velix-api:1.0.0`.

The upstream binary is copied in unmodified. What this image adds is the three things the
stock image cannot do for itself: it ships distroless (no shell, so no start command can fix
anything) and runs as uid 65532.

Every claim below was reproduced against the upstream image with the exact configuration the
two competing Railway listings publish (`velix-api` by codestorm, `velix-whatsapp-api` by
SilverBanana — both are the same Dokploy blueprint, so their defects are the category's).

## 1. The volume makes the app unusable, and the healthcheck says it is fine

Railway mounts volumes owned by uid 0. Velix runs as uid 65532. Neither listing sets a start
command or an entrypoint of its own, so nothing ever repairs the mount.

The service still deploys, still logs `WhatsApp engine started`, and still answers `/health`
with 200 — the engine only *records* its store path at boot. The failure lands on the first
thing anyone does with a WhatsApp gateway:

```
POST /v1/instances                      -> 500 INTERNAL_ERROR
{"level":"error","error":"register in engine: create store dir:
  mkdir /data/instances: permission denied","path":"/v1/instances"}
```

You cannot connect a number. Not one. Reproduced on `ghcr.io/paulolinder/velix-api:1.0.0`
with their variables and a root-owned `/data`, and the mounted volume stayed empty
throughout.

This image repairs ownership before the app starts and then drops back to 65532 with
`su-exec`, echoing the result so it can be read back from the deploy log:

```
[railway-entrypoint] volume /data owned by uid 0, repairing to 65532
[railway-entrypoint] volume ready owner=65532:65532 store=/data/instances
POST /v1/instances                      -> 201  {"status":"disconnected"}
```

Second boot finds the mount already correct, skips the chown, and the instances are still
there (`21` instances, 3.2 MB of session stores, across a container recreate).

## 2. `REGISTRATION_ENABLED` does not exist

Both listings publish `REGISTRATION_ENABLED=false` on the deploy form. The string appears
nowhere in the v1.0.0 binary — not as an env lookup, not in any config struct, not in any
casing. `POST /v1/auth/register` is open to anyone who finds the URL, and it hands out
`role: admin` on a fresh workspace:

```
POST /v1/auth/register  {"email":"stranger@evil.com", ...}   -> 200
{"user":{"email":"stranger@evil.com","role":"admin"}, "token":"eyJ..."}
```

A stranger's workspace runs WhatsApp instances on your container, writes to your volume and
bills to your Railway account.

Since upstream has no switch, this image puts the gate in front of the app: the gateway
answers `/v1/auth/register` with 403 unless `VELIX_PUBLIC_REGISTRATION=true`, and the
deployment's own workspace is created on first boot by calling `127.0.0.1` directly, from
`VELIX_ADMIN_EMAIL` + `VELIX_ADMIN_PASSWORD`. That bootstrap is idempotent — a later boot
gets `CONFLICT` on the workspace slug and leaves the existing workspace alone.

```
[railway-entrypoint] workspace 'default' created, admin admin@velix.local   (first boot)
[railway-entrypoint] workspace 'default' already exists, keeping it         (every boot after)
POST /v1/auth/register (from the internet)                                  -> 403
```

## 3. The login endpoint has no throttle

80 consecutive wrong-password POSTs to `/v1/auth/login` on the stock image: **80 × 401**, no
backoff, no lockout, no 429.

The gateway rate-limits `/v1/auth/login` and `/v1/auth/register` (default `10r/m`, burst 10).
The key is the client address from `X-Forwarded-For`, **not** `$remote_addr` — on Railway
every request arrives from the edge (`100.64.0.0/10`), so a `$remote_addr` limiter would give
the entire internet one shared bucket. Railway replaces any inbound `X-Forwarded-For`, so the
header cannot be forged from outside.

Measured through the gateway, same 80 requests: **11 × 401 then 69 × 429**, while a request
from a different client address still got its own 401.

## Ports

`PORT` is left alone. Railway's HTTP healthcheck dials the *injected* port, so on a public
service the app must not pin it. nginx listens on `$PORT` and the app is pinned to
`HTTP_PORT=8090` on `127.0.0.1`, where only the gateway can reach it.

## Environment

Baked into the image (not template variables — `templateGenerate` drops a literal default and
publishes the variable as a blank required field):

| Variable | Default | Purpose |
| --- | --- | --- |
| `HTTP_HOST` / `HTTP_PORT` | `127.0.0.1` / `8090` | app bind, behind the gateway |
| `ENGINE_STORE_PATH` | `/data/instances` | WhatsApp session stores, on the volume |
| `MEDIA_STORAGE_PATH` | `/data/media` | uploaded/received media, on the volume |
| `ENGINE_AUTO_RECONNECT` | `true` | reconnect paired numbers after a redeploy |
| `VELIX_ADMIN_EMAIL` | `admin@velix.local` | first-boot admin login |
| `VELIX_WORKSPACE_SLUG` / `_NAME` | `default` / `Default` | first-boot workspace |
| `VELIX_PUBLIC_REGISTRATION` | `false` | set `true` to reopen public signup |
| `VELIX_AUTH_RATE` / `VELIX_AUTH_BURST` | `10r/m` / `10` | login + register limiter |
| `VELIX_MAX_BODY_SIZE` | `100m` | media upload ceiling at the gateway |
| `VELIX_UID` | `65532` | uid the app runs as |

Supplied by the template, all as Railway expressions so their defaults survive publication:
`DATABASE_URL`, `REDIS_URL`, `JWT_SECRET` (`${{secret(64)}}`), `VELIX_ADMIN_PASSWORD`
(`${{secret(24)}}`).

`ENGINE_MAX_INSTANCES` is deliberately not set: upstream's own default is already 200, the
same number both listings spell out. A ceiling sized from the container's memory was
considered and dropped — 21 instances holding live WhatsApp sockets measured 34 MiB total
(≈0.75 MiB each at that stage), which is not enough evidence to lower anyone's ceiling.

Both `DATABASE_URL` and `REDIS_URL` are required by the app (`REDIS_URL is required` is a
fatal config error), and the entrypoint waits for both to accept TCP before starting, so a
template deploy does not burn a restart cycle losing the race with its own Postgres.
