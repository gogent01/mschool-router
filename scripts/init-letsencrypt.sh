#!/usr/bin/env bash
# One-time bootstrap: obtain SSL certificates via Let's Encrypt.
#
# Usage:
#   cd /opt/infra
#   bash scripts/init-letsencrypt.sh [--staging]
#
# Pass --staging to use Let's Encrypt staging environment (for testing).

set -euo pipefail

DOMAINS=(app.mishurovsky.school teach.mishurovsky.school)
EMAIL="admin@mishurovsky.school"     # change if needed
INFRA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERTBOT_DIR="$INFRA_DIR/certbot"
CONF_DIR="$INFRA_DIR/nginx/conf.d"

STAGING_FLAG=""
if [[ "${1:-}" == "--staging" ]]; then
  STAGING_FLAG="--staging"
  echo ">>> Using Let's Encrypt STAGING environment"
fi

echo ">>> Creating directories..."
mkdir -p "$CERTBOT_DIR/www" "$CERTBOT_DIR/conf"

# ─── Download recommended TLS parameters ───
if [ ! -f "$CERTBOT_DIR/conf/options-ssl-nginx.conf" ]; then
  echo ">>> Downloading recommended TLS parameters..."
  curl -sSL https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
    -o "$CERTBOT_DIR/conf/options-ssl-nginx.conf"
fi

if [ ! -f "$CERTBOT_DIR/conf/ssl-dhparams.pem" ]; then
  echo ">>> Downloading DH parameters..."
  curl -sSL https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem \
    -o "$CERTBOT_DIR/conf/ssl-dhparams.pem"
fi

# ─── Step 1: temporarily use the HTTP-only bootstrap config ───
# nginx reads all *.conf files, so we swap fc.conf → fc.conf.ssl,
# copy the nossl version in as fc.conf, then swap back after getting certs.
echo ">>> Activating HTTP-only bootstrap config..."
mv "$CONF_DIR/fc.conf" "$CONF_DIR/fc.conf.ssl"
cp "$CONF_DIR/fc.conf.nossl" "$CONF_DIR/fc.conf"

# ─── Step 2: start nginx (HTTP only, no backends needed) ───
echo ">>> Starting nginx-proxy..."
cd "$INFRA_DIR"
docker compose up -d nginx-proxy
sleep 5

# ─── Step 3: request certificates ───
echo ">>> Requesting certificates for: ${DOMAINS[*]}"
DOMAIN_ARGS=""
for domain in "${DOMAINS[@]}"; do
  DOMAIN_ARGS="$DOMAIN_ARGS -d $domain"
done

docker compose run --rm certbot certonly \
  --webroot \
  --webroot-path=/var/www/certbot \
  --email "$EMAIL" \
  --agree-tos \
  --no-eff-email \
  $STAGING_FLAG \
  $DOMAIN_ARGS

# ─── Step 4: restore the full SSL config and reload ───
echo ">>> Switching to SSL config..."
mv "$CONF_DIR/fc.conf.ssl" "$CONF_DIR/fc.conf"
docker compose exec nginx-proxy nginx -s reload

echo ""
echo "=== SSL certificates obtained successfully! ==="
echo "Now start your app services:  cd /opt/fc/deploy && docker compose up -d --build"
