FROM ghcr.io/paulolinder/velix-api:1.0.0 AS upstream

FROM nginx:1.27-alpine

# curl for the first-boot bootstrap call and for anyone debugging the container;
# su-exec to drop back to the upstream image's uid after the volume is repaired.
RUN apk add --no-cache curl su-exec

# The upstream binary, unmodified. It is a static Go binary with the migrations,
# the admin UI and the whatsmeow engine embedded, so it needs nothing else from
# the distroless base it normally ships in.
COPY --from=upstream /velix-api /usr/local/bin/velix-api

# Baked, NOT published as template variables. templateGenerate drops a variable
# whose default is a literal, so anything shipped that way publishes as a blank
# REQUIRED field on the deploy form. Only values that genuinely belong to the
# deployer stay variables, and those are expressions (${{secret(n)}},
# ${{Postgres.DATABASE_URL}}), whose defaults do survive.
ENV APP_ENV=production \
    LOG_LEVEL=info \
    HTTP_HOST=127.0.0.1 \
    HTTP_PORT=8090 \
    ENGINE_STORE_PATH=/data/instances \
    MEDIA_STORAGE_PATH=/data/media \
    ENGINE_AUTO_RECONNECT=true \
    VELIX_DATA_DIR=/data \
    VELIX_UID=65532 \
    VELIX_ADMIN_EMAIL=admin@velix.local \
    VELIX_WORKSPACE_NAME=Default \
    VELIX_WORKSPACE_SLUG=default \
    VELIX_PUBLIC_REGISTRATION=false \
    VELIX_AUTH_RATE=10r/m \
    VELIX_AUTH_BURST=10 \
    VELIX_MAX_BODY_SIZE=100m

COPY nginx.conf.template /etc/velix/nginx.conf.template
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

# Railway injects PORT and the edge healthcheck dials the INJECTED port, so the
# gateway honours $PORT and the app is pinned to the private HTTP_PORT above.
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
