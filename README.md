# Data room — Nextcloud + audit dashboard

Self-hosted kit for a small named-user room (about ten files, a handful of people).

Nextcloud serves the files. Caddy gets the certificate. MariaDB and Redis sit behind it. Loki, Promtail and Grafana turn the audit log into a dashboard of who signed in and which file they opened.

About an hour, end to end, on a fresh Ubuntu 24.04 VPS. You upload the files in the web UI afterwards.

This is not a commercial virtual data room. Nextcloud will not watermark a PDF, and it cannot stop a person who can open a file from downloading it. A view and a download are the same audit line. If counsel needs view-only or dynamic watermarking, use a commercial VDR. This kit is the private, self-hosted version of "named accounts, HTTPS, and a record of every open."

## What the dashboard actually counts

Checked against Nextcloud **34.0.4** `admin_audit` (the image this compose file pins).

| Panel | Audit line it matches |
|---|---|
| Logins | `Login successful: "…"` |
| Failed logins | `Login failed: "…"` |
| File opens | `File with id "…" accessed: "/path"` |
| People active | Distinct usernames with any audit event in 15 minutes |
| Shares created | `has been shared` |
| Link opens | `has been accessed` |
| Opens by file | Path parsed out of the accessed-line |
| Audit trail | The raw JSON line, filterable by user |

There is no `File downloaded` event. Do not look for one. Previews (`Preview accessed:`) are excluded from the open counts so paging through a folder does not look like ten downloads.

A user's time in the room is the gap between their first and last line in the audit trail. Nextcloud does not record a session length.

## What you need before you start

- A domain you control. Caddy cannot get a certificate from an IP address.
- DNS **only** (grey cloud if the DNS host is Cloudflare). An orange-cloud proxy will put Cloudflare's address in every audit line.
- Ubuntu 24.04, 2 vCPU, 4 GB RAM. Toronto if the readers are in Canada (DigitalOcean, Vultr, AWS ca-central-1, Azure Canada Central). UAE North or AWS me-central-1 if the readers are in the Gulf. Same commands either way.
- Ports 22, 80 and 443 open. On DigitalOcean that is both `ufw` and the cloud firewall.

## Step 0 — Server

Create the VPS, add your SSH key, note the public IP.

## Step 1 — Domain

```
files.yourdomain.com.   A   <SERVER IP>
```

Check from your own machine. Do not continue until this prints the server IP.

```
dig +short files.yourdomain.com
```

## Step 2 — Docker and the firewall

```
ssh root@<SERVER IP>
curl -fsSL https://get.docker.com | sh
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw enable
```

## Step 3 — Put the kit on the server

From your own machine, in the directory that contains this folder:

```
scp -r nextcloud-dataroom root@<SERVER IP>:/root/
ssh root@<SERVER IP>
cd /root/nextcloud-dataroom
```

## Step 4 — Secrets

Passwords are letters and digits only. A `$` or a quote breaks Compose or Redis.

```
cp .env.example .env
openssl rand -hex 24   # run this once per secret
nano .env
```

Set:

- `DOMAIN` — the name from step 1, no `https://`
- `ACME_EMAIL` — a real mailbox, used only for certificate expiry notices
- `ADMIN_USER` — not the word `admin`
- `ADMIN_PASSWORD`, `DB_PASSWORD`, `DB_ROOT_PASSWORD`, `REDIS_PASSWORD`, `GRAFANA_PASSWORD`
- `DEFAULT_PHONE_REGION` — `AE` or `CA`

```
mkdir -p nc-data
```

## Step 5 — Start

```
docker compose up -d
docker compose logs -f nextcloud
```

Wait until the log stops moving (first install is several minutes). Ctrl-C leaves the containers running. Then:

```
docker compose ps
```

`db` and `redis` should be healthy. `nextcloud` should be up. Then open `https://files.yourdomain.com` and sign in as `ADMIN_USER`. There is no setup wizard — the admin account is created from `.env`.

If the browser times out on TLS, DNS is not pointing here yet or 80/443 is still closed. Caddy retries the certificate on its own once both are true.

## Step 6 — Turn on the audit trail

```
bash scripts/enable-audit.sh
```

That one command:

- enables `admin_audit`
- writes it to `nc-data/audit.log` (JSON, one event per line)
- keeps the main Nextcloud log at WARN, and forces INFO for `admin_audit` only
- trusts the Docker network `172.28.14.0/24` so the IP in the log is the visitor, not Caddy
- turns off public links and the share-dialog user list
- turns off the "forgot password" link (you reset passwords)
- keeps versions and trash for up to a year
- enables the TOTP app, but does **not** enforce it
- switches background jobs to cron (the `cron` container is already in the compose file — do not also add a host crontab)

Sign in once, open one file, then:

```
docker compose exec -u root nextcloud tail -n 5 /var/www/html/data/audit.log
```

You want a line containing `"app":"admin_audit"` and `accessed:`.

## Step 7 — Dashboard

Grafana is on the server only. From your own machine:

```
ssh -L 3000:localhost:3000 root@<SERVER IP>
```

Leave that session open. Browse to `http://localhost:3000`.

- User: `GRAFANA_USER` from `.env` (default `admin`)
- Password: `GRAFANA_PASSWORD`

Open **Data Room → Data Room — Access & Usage**. The user dropdown filters every panel. New lines show up within about 30 seconds of the action.

## Step 8 — People and files

In Nextcloud: avatar menu → Users. Create one account per person. Send the password by a channel you already trust. Do not put two readers on one login or the audit trail is useless.

Upload the files. Share the folder with those users (right click → Share → type the exact username). Public link sharing is off, and the share dialog will not offer a list of other people. Typing the full username still works, so one reader cannot browse who else is in the room.

On that share you can clear "allow download". That only changes the browser UI. It is not a watermark and it is not DRM. The audit line is still `accessed`.

After each person has signed in on their own, enroll TOTP under Settings → Security. Only then, if you want it mandatory:

```
docker compose exec -T -u www-data nextcloud php occ twofactorauth:enforce --on
```

Do not run that until your own token works. To undo a lockout:

```
docker compose exec -T -u www-data nextcloud php occ twofactorauth:disable USERNAME totp
```

## Step 9 — One login from mainland China before you invite the rest

Hosted in Canada or the UAE, with no ICP licence, a reader inside mainland China may get through, or they may not, depending on the carrier and the week. Have one person try the real URL first.

If it is unusable, move the same folder to a Hong Kong VPS (Alibaba Cloud or Tencent Cloud Hong Kong — no ICP). The commands do not change. A commercial VDR is the other option.

If readers are in mainland China, the audit log holds IP addresses and names. That is personal information under PIPL. Keep it for the deal, say so in the terms you send them, and delete the room when the deal is over (step "Tear down" below).

## Day-two

**Backup** — files, audit log, and the databases are separate.

```
cd /root/nextcloud-dataroom
docker compose exec -T db sh -c 'exec mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction nextcloud' > nextcloud.sql
tar -C /root -czf dataroom-files.tgz nextcloud-dataroom/nc-data
```

The database password is already inside the `db` container. You do not put it on the host command line.

Also snapshot the VPS. The named volumes (`db_data`, `nc_html`, `caddy_data`, `loki_data`) are not inside `nc-data`. A droplet snapshot covers them. `nc-data` is the files and `audit.log`.

**Update** — read the Nextcloud release notes. Do not switch the image to `latest` or `apache`; those tags are Nextcloud 35 and will jump a major on the next pull.

```
docker compose pull
docker compose up -d
```

**Certificate** — Caddy renews it. Nothing to cron.

**Disk** — `audit.log` rotates at 100 MB. Loki keeps a year, then drops it. A ten-file room will not fill a 4 GB disk; the database binary logs expire after three days.

**Tear down** — when the deal is over and you have copied anything you must keep:

```
cd /root/nextcloud-dataroom
docker compose down -v
rm -rf nc-data
```

`-v` deletes the database and the log index. Without it, the audit trail is still on the disk.

## Troubleshooting

| What you see | Cause |
|---|---|
| 502 for a few minutes after `up` | Nextcloud is still installing. `docker compose ps` |
| TLS error, or a Caddy certificate error | `dig +short` is not the server IP, or 80 is closed. Fix DNS, wait. Do not delete `caddy_data` unless the error tells you the account is broken. |
| "Access through untrusted domain" | `DOMAIN` in `.env` does not match the browser. Re-run `bash scripts/enable-audit.sh` after correcting `.env`, or `docker compose exec -T -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=files.yourdomain.com` |
| Every IP in Grafana is `172.28.14.x` | Trusted proxies were not applied. Re-run `bash scripts/enable-audit.sh`. Confirm `.env` was loaded on the **first** `up` (Redis password and admin user are first-boot only). |
| Dashboard is empty | `audit.log` missing or Promtail cannot read it. Re-run the script. Then `docker compose logs promtail`. |
| Panels exist but file opens stay at 0 | You are looking for a download. Open a file while logged in as a normal user, wait 30 seconds. Directory listings and previews are not counted. |
| Grafana refuses the connection from your laptop | It is bound to `127.0.0.1` on the server. Use the SSH tunnel in step 7. |
| `network room ... Pool overlaps` | The host already uses `172.28.14.0/24`. Change the subnet in `docker-compose.yml` (the `room` network) and the same CIDR in `scripts/enable-audit.sh`, then `docker compose up -d` and re-run the script. |
| Permission denied under `nc-data` | `docker compose exec -u root nextcloud chown -R www-data:www-data /var/www/html/data` |
| Locked out by 2FA | `docker compose exec -T -u www-data nextcloud php occ twofactorauth:disable USERNAME totp` |

## Files

| File | Role |
|---|---|
| `docker-compose.yml` | Nextcloud, cron, MariaDB, Redis, Caddy, Loki, Promtail, Grafana |
| `Caddyfile` | Automatic HTTPS, 1 GB request cap, the usual security headers |
| `.env.example` | Every secret. Copy to `.env`. Never commit `.env`. |
| `scripts/enable-audit.sh` | The one audit command |
| `loki-config.yaml` | Single-node Loki, one-year retention, no usage pings home |
| `promtail-config.yaml` | Tails `audit.log` only. Remembers its position across restarts. |
| `grafana/dashboards/dataroom.json` | The dashboard |
| `grafana/provisioning/` | Datasource uid `loki`, so the dashboard actually binds |

## Images

| Service | Image | Why this tag |
|---|---|---|
| Nextcloud | `nextcloud:34.0.4-apache` | Production line on 14 Oct 2026. `latest` is 35. |
| MariaDB | `mariadb:10.11` | LTS. utf8mb4 / `utf8mb4_general_ci`, which Nextcloud still expects. |
| Redis | `redis:7.4-alpine` | Password, AOF, no eviction (it also stores file locks). |
| Caddy | `caddy:2.10-alpine` | Certificate from Let's Encrypt. |
| Loki | `grafana/loki:3.6.11` | Same release line as Promtail. |
| Promtail | `grafana/promtail:3.6.11` | You asked for Promtail. Grafana's successor is Alloy; this image is the last 3.6 release. |
| Grafana | `grafana/grafana:12.4.13` | Listens on localhost only. |
