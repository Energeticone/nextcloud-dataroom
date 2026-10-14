#!/usr/bin/env bash
# One command, after `docker compose up -d` has finished installing.
# Turns on the full admin_audit trail, records real client IPs,
# and locks sharing to named accounts (no public links).
# Safe to run again. It will not truncate an existing audit.log.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "Missing .env. Run: cp .env.example .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${DOMAIN:?DOMAIN is empty in .env}"
: "${DEFAULT_PHONE_REGION:=AE}"

dc() { docker compose exec -T -u www-data nextcloud php occ "$@"; }

echo "Waiting until Nextcloud reports installed: true ..."
ready=0
for _ in $(seq 1 60); do
  if dc status 2>/dev/null | grep -q "installed: true"; then
    ready=1
    break
  fi
  sleep 5
done
if [[ "$ready" != 1 ]]; then
  echo "Nextcloud is not installed yet. Check: docker compose logs nextcloud" >&2
  exit 1
fi

echo "Audit log (INFO for admin_audit only; main log stays at WARN)..."
dc app:enable admin_audit
dc config:system:set log_type --value=file
dc config:system:set logfile --value=/var/www/html/data/nextcloud.log
dc config:system:set log_type_audit --value=file
dc config:system:set logfile_audit --value=/var/www/html/data/audit.log
dc config:system:set loglevel --type=integer --value=2
dc config:system:set log.condition apps 0 --value=admin_audit
dc config:system:set log_rotate_size --type=integer --value=104857600
dc config:system:set logtimezone --value=UTC

echo "Client IP, HTTPS, phone region..."
dc config:system:set trusted_proxies 0 --value=172.28.14.0/24
dc config:system:set forwarded_for_headers 0 --value=HTTP_X_FORWARDED_FOR
dc config:system:set overwriteprotocol --value=https
dc config:system:set overwritehost --value="${DOMAIN}"
dc config:system:set overwrite.cli.url --value="https://${DOMAIN}"
dc config:system:set default_phone_region --value="${DEFAULT_PHONE_REGION}"

echo "Named accounts only. No public links, no self-service password reset..."
dc config:app:set core shareapi_allow_links --value=no
dc config:app:set core shareapi_allow_share_dialog_user_enumeration --value=no
dc config:system:set auth.bruteforce.protection.enabled --type=boolean --value=true
dc config:system:set lost_password_link --value=disabled
dc config:system:set versions_retention_obligation --value="auto, 365"
dc config:system:set trashbin_retention_obligation --value="auto, 365"
dc app:enable twofactor_totp
dc background:cron

# Create the file Promtail is waiting for. Do not use install on an existing log:
# that truncates it.
docker compose exec -T -u root nextcloud bash -lc \
  'if [ ! -e /var/www/html/data/audit.log ]; then install -o www-data -g www-data -m 0640 /dev/null /var/www/html/data/audit.log; else chown www-data:www-data /var/www/html/data/audit.log; fi'

echo
echo "Done."
echo "  Audit file : ./nc-data/audit.log"
echo "  Phrase     : File with id \"…\" accessed: \"/path\""
echo "  Grafana    : ssh -L 3000:localhost:3000 root@<server>  then  http://localhost:3000"
echo "  2FA        : enroll TOTP in the Nextcloud UI before you enforce it. This script does not enforce it."
