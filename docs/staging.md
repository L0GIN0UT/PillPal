# Personal staging (field test)

A one-region (RU) stack on your own VPS for testing the Android app on your own devices for a few
weeks before any store release. Files: `infra/staging/` (compose, `.env.example`, `Caddyfile`,
`backup.sh`), workflow `.github/workflows/deploy-staging.yml`, mail: `backend/README.md` "E-mail".

```
phone (APK) --https--> reverse proxy (your nginx, or the bundled Caddy)
                          --> 127.0.0.1:8080 api (uvicorn)  <-- worker (push, missed-dose detector, erase job)
                                        |                          |
                                    postgres 16 (volume)       redis 7 (password)      nothing but the proxy is public
```

Deploys are manual only: Actions -> `deploy-staging` -> Run workflow. The button exists once the
workflow file is on `main` (merge the PR first).

The catalog service (public medicine reference data) is part of the stack: section 12.

Test data only (privacy rules apply even here): use made-up medication names; the database is a
real PostgreSQL on the server and is dumped by `backup.sh`; keep dumps on the same server or in
Russia.

## 1. What you need

- A VPS in Russia with Docker and the compose plugin (`docker compose version`), ports 80/443
  reachable from the internet, an SSH user that may run `docker` (the `docker` group is
  root-equivalent: use a dedicated user, not your personal one).
- A domain you control. Use a subdomain, e.g. `staging.example.com`. One host serves the API,
  the invite links and the Android App Links file.
- A GitHub account that owns the repository, a Google account (Firebase), a mailbox at Yandex 360
  or Mail.ru.

## 2. DNS

Create an `A` record `staging.example.com -> <VPS IPv4>` (and `AAAA` only if the proxy listens on
IPv6). Check: `dig +short staging.example.com`.

## 3. Firebase (push to Android)

1. <https://console.firebase.google.com> -> Add project (analytics can be off).
2. Project overview -> Add app -> Android, package name **`com.pillpal.pillpal`**, any nickname. The
   debug SHA-1 is not needed for FCM. Skip the SDK steps and do not add `google-services.json`:
   the app takes the values below from build variables.
3. Project settings -> General (Your apps -> the Android app) gives:
   - **Project ID** -> `PILLPAL_FCM_PROJECT_ID` (and `FCM_PROJECT_ID` on the server),
   - **Project number** (Cloud Messaging tab: "Sender ID") -> `PILLPAL_FCM_SENDER_ID`,
   - **App ID** (`1:123456789:android:abc...`) -> `PILLPAL_FCM_APP_ID`,
   - **Web API key** (General tab; it is `current_key` in `google-services.json`) -> `PILLPAL_FCM_API_KEY`.
   These identify the app and are not secrets, so they go into GitHub *variables*.
4. Server key: Google Cloud console (same project) -> IAM & Admin -> Service accounts -> Create
   service account (`pillpal-fcm`) -> grant only the role **Firebase Cloud Messaging API Admin**
   (`roles/firebasecloudmessaging.admin`), nothing else -> Keys -> Add key -> JSON. This file is
   `secrets/fcm_service_account.json` on the server. Do not reuse the default
   `firebase-adminsdk-...` account (it has far wider roles). Keep the key out of git and chat.
5. Check that "Firebase Cloud Messaging API (V1)" is enabled (Project settings -> Cloud Messaging).

Devices need Google Play services to receive FCM. An alert is "a dose was missed" to a relative,
it carries no medication names.

## 4. SMTP mailbox

Mails: e-mail confirmation code, password reset, account deletion/restore. Use a mailbox
you own; the sender address must be that mailbox.

- **Yandex 360 / Yandex Mail:** id.yandex.ru -> Security -> App passwords -> create one for "Mail".
  In Mail settings -> "Mail clients" ("Почтовые клиенты") allow access from mail clients. Host `smtp.yandex.ru`, `465`, `ssl`, user = full address.
- **Mail.ru:** Account -> Security -> "Passwords for external apps" -> create one with access to
  mail. Host `smtp.mail.ru`, `465`, `ssl`, user = full address.
- STARTTLS instead: `SMTP_PORT=587`, `SMTP_SECURITY=starttls` (never a downgrade: the server
  must offer STARTTLS or sending fails).

The app password goes into `secrets/smtp_password` (below), never the account password.

Mails are multipart (text and HTML, Russian then English in one body). Sign-up, resend and password
reset answer `202` first and send afterwards (background task, then a detached SMTP send), so a slow
or broken mailbox never changes a response; a failed send shows only as `smtp_send_failed` in the log.

## 5. Android signing key and the certificate fingerprint

Release APKs are signed with an upload keystore. Create it once, on your machine, and **back it up
outside the repository** (losing it means reinstalling the app from scratch; a leaked one must be
replaced):

```bash
keytool -genkeypair -v -keystore pillpal-upload.jks -alias pillpal-upload \
  -keyalg RSA -keysize 2048 -validity 10000
# asks for a store password, a key password and your name; remember both passwords
```

Base64 for the GitHub secret (one line, no wrapping):

```bash
base64 -w0 pillpal-upload.jks            # Linux (macOS: base64 -i pillpal-upload.jks | tr -d '\n')
```
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("pillpal-upload.jks"))   # Windows PowerShell
```

SHA-256 of the signing certificate for `ANDROID_CERT_SHA256S` (needed for App Links, i.e. invite
links opening the app):

```bash
keytool -list -v -keystore pillpal-upload.jks -alias pillpal-upload | grep 'SHA256:'
# SHA256: AA:BB:...:FF   <- 32 upper-case hex pairs separated by colons
```

On the server it is a JSON list: `ANDROID_CERT_SHA256S=["AA:BB:...:FF"]`.

## 6. GitHub: secrets and variables

Create the environment `staging` (Settings -> Environments), set **Deployment branches: Selected
branches -> `main`**, and put the `STAGING_SSH_*` secrets **in that environment only** (not
repository secrets: any workflow could read those). The `PILLPAL_*` variables and the `ANDROID_*`
secrets must be **repository** ones (the app build does not use the environment).

| Kind | Name | Value |
|---|---|---|
| env secret | `STAGING_SSH_HOST` | VPS host or IP |
| env secret | `STAGING_SSH_PORT` | optional, default 22 |
| env secret | `STAGING_SSH_USER` | the deploy user |
| env secret | `STAGING_SSH_KEY` | private key of the deploy key (below), whole file |
| env secret | `STAGING_SSH_KNOWN_HOSTS` | verified `ssh-keyscan` line(s) of the server (below) |
| env variable | `STAGING_PUBLIC_URL` | `https://staging.example.com` |
| env variable | `STAGING_CATALOG_URL` | `https://catalog-staging.example.com` (section 12) |
| env variable | `STAGING_DIR` | optional, default `~/pillpal` |
| repo variable | `PILLPAL_API_BASE_URL_RU` | `https://staging.example.com` (no path, no slash) |
| repo variable | `PILLPAL_LINK_HOST_RU` | `staging.example.com` (host only) |
| repo variable | `PILLPAL_FCM_API_KEY`, `PILLPAL_FCM_APP_ID`, `PILLPAL_FCM_SENDER_ID`, `PILLPAL_FCM_PROJECT_ID` | from step 3 (all four or none) |
| repo secret | `ANDROID_KEYSTORE_BASE64` | step 5 |
| repo secret | `ANDROID_KEY_ALIAS` | `pillpal-upload` |
| repo secret | `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD` | the passwords you chose |

Leave `PILLPAL_RUSTORE_PROJECT_ID` unset (RuStore push stays off until verified on a device).

Deploy key and host key (on your machine):

```bash
ssh-keygen -t ed25519 -f pillpal-staging-deploy -C pillpal-staging-deploy -N ''
ssh-copy-id -i pillpal-staging-deploy.pub -p 22 deploy@<host>     # or append the .pub to ~/.ssh/authorized_keys
# STAGING_SSH_KEY = content of ./pillpal-staging-deploy (then delete the local copy)
ssh-keyscan -p 22 -t ed25519 <host>                               # STAGING_SSH_KNOWN_HOSTS = this output
# VERIFY it, otherwise strict checking only trusts whoever answered the scan:
ssh deploy@<host> 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'   # must show the same fingerprint
ssh-keygen -lf <(ssh-keyscan -p 22 -t ed25519 <host> 2>/dev/null)
```

The workflow uses `StrictHostKeyChecking=yes` with that file only.

## 7. Server preparation (once)

Log in as the deploy user. `~/pillpal` is the default `STAGING_DIR`.

```bash
umask 077
mkdir -p ~/pillpal && mkdir -m 700 ~/pillpal/secrets && cd ~/pillpal
```

**`.env`** - copy `infra/staging/.env.example` there (`scp infra/staging/.env.example deploy@<host>:pillpal/.env`)
and fill every `CHANGE_ME`: `PILLPAL_IMAGE=ghcr.io/<your github login in lower case>/pillpal-backend`,
`PUBLIC_DOMAIN`, `JWT_SECRET`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, the catalog block (section 12) (generators are in the file; URL-safe
characters, no `$`), `ANDROID_CERT_SHA256S`, `FCM_PROJECT_ID`, `SMTP_*`. `chmod 600 .env`.

**Secret files** (mounted read-only as Docker secrets; the container user has uid 10001):

```bash
read -rs -p 'SMTP app password: ' smtp_pw && printf '%s' "$smtp_pw" > secrets/smtp_password; unset smtp_pw; echo
# paste the service account JSON of step 3.4 into secrets/fcm_service_account.json (or scp it)
sudo chown 10001:10001 secrets/smtp_password secrets/fcm_service_account.json
sudo chmod 400 secrets/smtp_password secrets/fcm_service_account.json
```

`docker-compose.yml`, `Caddyfile`, `backup.sh` and the landing page folder `site/` are uploaded by
every deploy from the deployed commit (local edits there are overwritten: use `.env`).

**Image pull (GHCR).** The package is private by default. Either:

- (recommended) a read-only login on the server: GitHub -> Settings -> Developer settings ->
  Personal access tokens -> *Tokens (classic)* -> scope **`read:packages`** only (fine-grained
  tokens do not support the container registry). Then
  `echo '<token>' | docker login ghcr.io -u <github login> --password-stdin`. The token stays in
  `~/.docker/config.json` on the server (mode 600) and is never put into an image or sent by the
  workflow. Give the token an expiry (e.g. 90 days) and calendar the renewal: when it expires the
  deploy fails at `docker compose pull`; repeat the `docker login` with a new token; or
- make the `pillpal-backend` package public (Package settings -> Change visibility). It holds no secrets.

**Reverse proxy.** Pick one.

### (a) The host already runs nginx (another app on 80/443)

Add `/etc/nginx/conf.d/pillpal-staging.conf` (or a `sites-available` file), then get the certificate:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name staging.example.com;

    # The API limits `POST /v1/me/purchases` itself (PAYMENTS_MAX_BODY_BYTES, 16 KiB by default);
    # keep the proxy limit in front of it as the first line.
    client_max_body_size 1m;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    # Overwrite, never append: the API trusts this header for rate limiting.
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_read_timeout 60s;
    add_header Strict-Transport-Security "max-age=2592000" always;

    # The landing page ("Landing page" below): exactly / and /site/*, static, from the folder the
    # deploy uploads ($STAGING_DIR/site; the path below assumes STAGING_DIR=pillpal of user deploy).
    # add_header in a location drops the server-level ones, so HSTS is repeated here.
    location = / {
        root /home/deploy/pillpal/site;
        rewrite ^ /index.html break;
        include /etc/nginx/snippets/pillpal-site-headers.conf;
        add_header Cache-Control "public, max-age=300" always;
    }
    location ^~ /site/ {
        root /home/deploy/pillpal/site;
        include /etc/nginx/snippets/pillpal-site-headers.conf;
        add_header Cache-Control "public, max-age=86400" always;
    }

    # Everything else goes to the API; the two paths below matter for invite links and must answer
    # 200 directly on https (no redirect), because Google fetches the verification file.
    location = /.well-known/assetlinks.json { proxy_pass http://127.0.0.1:8080; }
    location = /i                            { proxy_pass http://127.0.0.1:8080; }
    location /                               { proxy_pass http://127.0.0.1:8080; }
}
```

and `/etc/nginx/snippets/pillpal-site-headers.conf` (the same headers the Caddyfile sends):

```nginx
add_header Strict-Transport-Security "max-age=2592000" always;
add_header Content-Security-Policy "default-src 'none'; style-src 'self'; script-src 'self'; font-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" always;
add_header X-Content-Type-Options nosniff always;
add_header Referrer-Policy no-referrer always;
```

nginx must be able to read the folder: the worker user (`www-data`) needs `x` on every directory of
the path (e.g. `chmod o+x /home/deploy /home/deploy/pillpal`) and `r` on the files (the deploy's
default umask gives it). An nginx in a container needs the folder mounted read-only, e.g.
`-v /home/deploy/pillpal/site:/srv/pillpal-site:ro`, and that path as `root`. No `access_log` is
added for these locations; keep whatever the server already does.

```bash
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d staging.example.com        # adds the 443 block, the redirect and renewal
curl -fsS https://staging.example.com/healthz     # after the first deploy
```

If that nginx **runs in a container**, `127.0.0.1` inside it is the container itself. Take the
gateway address of the Docker network the nginx container is on,
`docker network inspect <network> --format '{{(index .IPAM.Config 0).Gateway}}'` (e.g. `172.18.0.1`), put
`API_BIND=172.18.0.1` into `.env` and use `proxy_pass http://172.18.0.1:8080;`. That address is
internal to the host; never use `API_BIND=0.0.0.0`. Issue the certificate the way your existing
setup does.

Redis runs as the `redis` user (uid 999). A volume created by an earlier version of the stack is
owned by root; fix it once before the first start of this version:
`docker run --rm -v pillpal-staging_redisdata:/data redis:7 chown -R 999:999 /data` (a fresh install needs nothing).

Redis **7.0 or newer** is required (`EXPIRE ... NX` in the rate limiters and the promo guard); the stack pins `redis:7`.

### (b) No proxy yet: bundled Caddy (automatic HTTPS)

Ports 80 and 443 must be free. Add `COMPOSE_PROFILES=caddy` to `.env`. The deploy then also starts
Caddy, which obtains and renews the certificate for `PUBLIC_DOMAIN` by itself (the DNS record must
already point to the server). Nothing else to configure: the Caddyfile already serves the landing
page (below) from `./site`, mounted read-only at `/srv/site`.

### Landing page

The root of the API host shows the PillPal landing page; there is no separate domain or DNS record.
Files: `infra/staging/site/` (`index.html`, and `site/` with `site.css`, `site.js`, `favicon.svg` and
the self-hosted fonts with their SIL OFL licences), uploaded to `$STAGING_DIR/site` by every deploy.
The proxy serves exactly `/` and `/site/*` from that folder; everything else (`/v1/*`, `/healthz`,
`/readyz`, `/i`, `/.well-known/*`) still goes to the API, which has no route at either path.

- Same-origin only: no Google Fonts, CDN, analytics or any other third-party request, so no visitor
  address goes to another host. The CSP (`default-src 'none'`, `'self'` for styles, scripts, fonts
  and images) forbids inline code: styles and the copy-button script live in `site/`.
- Headers on these two routes only: the CSP, `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: no-referrer`, HSTS; `Cache-Control` 5 minutes for the page, 1 day for `/site/*`
  (the assets are not fingerprinted: a changed file is picked up within a day).
- No access log is added. The Caddy error-log filter above still applies.
- CI (`repo.yml`): `caddy validate` of the Caddyfile and `.github/scripts/check_landing_site.py`
  (no absolute URLs, no inline code, every referenced asset exists).
- The deploy only adds and overwrites files in `$STAGING_DIR/site`; delete a file removed from the
  repository there by hand.
- Follow-up: a separate SITE_DOMAIN for the landing page if the owner later wants the API on a subdomain.

## 8. First deployment

1. Merge the PR so that `deploy-staging.yml` is on `main`; set the secrets/variables of step 6.
2. Actions -> `deploy-staging` -> Run workflow (ref `main`). It builds and pushes the image
   (`:<sha>` and `:staging`), uploads the compose files, runs
   `docker compose pull && docker compose run --rm api alembic upgrade head && docker compose up -d`
   and waits for `https://<domain>/readyz`.
3. Check by hand: `curl https://staging.example.com/.well-known/assetlinks.json` returns your
   package name and fingerprint.

The server runs the immutable `:<commit sha>` tag: the deploy writes `PILLPAL_IMAGE_TAG=<sha>` into
`.env`, so a manual `docker compose up -d` later keeps that commit (`:staging` is only a pointer for
humans). Pull request refs and commits that are on no branch or tag of this repository are refused.

Later deploys: the same button, any ref. A rollback is a deploy of an older ref (migrations are not
undone; a downgrade is a deliberate manual `docker compose run --rm api alembic downgrade <rev>`).

## 9. The APK

Set the variables and secrets of step 6 first, then: Actions -> `app-release` -> Run workflow on
`main` -> when green, download the `android-release` artifact (zip) -> `app-release.apk`. Its
summary shows the API URL, the signing key (upload key, not debug) and the push state. Install:
`adb install -r app-release.apk`, or copy the file to the phone and allow installation from
that source. After a domain change, rebuild and reinstall.

Invite links: `adb shell pm get-app-links com.pillpal.pillpal` shows `staging.example.com: verified`
once Android has fetched `assetlinks.json` (`adb shell pm verify-app-links --re-verify com.pillpal.pillpal`
forces it). The fingerprint must belong to the key that signed the installed APK.

Order matters: deploy the backend (it has `GET`/`POST /v1/me/consents`) **before** the app
update. The app asks `GET /v1/me/consents` on every sync run and when it starts; against an older
server that is a 404 and the sync fails until the backend is updated. An account without consents
(created before them) sees the blocking consent screen after the update, and its medical sync
stays paused until it agrees (reminders keep working).

Smoke test: register in the app (the code arrives by mail), add a medication, wait for the
reminder, invite a second device as a relative, and check that a missed dose reaches the relative.

## 10. Logs, status, backups

```bash
cd ~/pillpal
docker compose ps                                  # health of api, worker, postgres, redis
docker compose logs -f --tail=100 api worker       # JSON lines; rotated at 5 x 10 MB per service
docker compose logs --since 1h api | grep smtp_send_failed
```

Logs hold opaque ids and error codes only (never medical data, addresses or codes). A mail that
could not be sent shows `smtp_send_failed` with the exception class as `reason`: wrong app password
(`SMTPAuthenticationError`), blocked port or host (`SMTPConnectError`, `TimeoutError`).

Backups (PostgreSQL volume, daily dump, 14 days):

```bash
~/pillpal/backup.sh                                  # once by hand: creates backups/pillpal-<time>.sql.gz
crontab -e
17 3 * * * /home/deploy/pillpal/backup.sh >> /home/deploy/pillpal/backups/backup.log 2>&1
```

The dump excludes the data of `data_exports` (encrypted account exports): they are transient, up to
64 MiB each, and a restore must not bring back a downloaded or expired archive.

**Erased accounts live on in backups.** A dump holds every account that existed when it was taken,
including ones erased afterwards (deletion has a 30-day grace, the erase job runs hourly). Therefore
`backup.sh` refuses `KEEP_DAYS` above 14 and deletes older dumps: an erased account is gone from
backups at most 14 days after erasure. Do not copy dumps anywhere that outlives that. Restoring an
old dump resurrects erased accounts: erase them again. The retention question is on the legal
review list (`docs/phase3-plan.md`).
Legal document drafts (policy, consents, terms, processors): `docs/legal/README.md`.

Restore into an empty database: stop the stack (`docker compose stop api worker`), then
`gunzip -c backups/<file>.sql.gz | docker compose exec -T postgres psql -U pillpal -d pillpal`,
start again. Copy dumps to another machine only inside Russia (152-FZ).

## 11. Variables of the stack (`infra/staging/.env`)

See `infra/staging/.env.example`. The compose file fixes `ENVIRONMENT=staging`, `REGION=ru`,
`DETECTOR_ENABLED=true`, `EMAIL_BACKEND=smtp`; staging refuses to start with `LOG_EMAIL_CODES`, a
non-SMTP e-mail backend, a short `JWT_SECRET` or a half-configured push provider.

### 11.1 Consent pause (backend and app together)

The backend pauses a profile whose owner and guardians have no active `health_data` consent
(`CONSENT_SERVER_PAUSE_ENABLED`, default `true`; ADR 0016 section 5): no missed-dose alerts or
pushes, and relatives are not served. Field-test accounts created before consent records existed
have none, so deploy the backend and the app with the consent gate **together**; testers then
accept the consent screen in the app and everything resumes. Until the app ships, set
`CONSENT_SERVER_PAUSE_ENABLED=false` in `.env`. **Never backfill consent records** by SQL: a record
nobody accepted is not a consent.

Registration also requires the consents on staging (`CONSENT_REQUIRED_AT_REGISTRATION`, default `true`,
milestone 5.11): an APK without the consent step gets 422 `consent_required` on sign-up. Set it to
`false` in `.env` only while testers still run such a build. Both variables are passed by
`infra/staging/docker-compose.yml`.

Optional: `SENTRY_DSN` (and `SENTRY_RELEASE`) in `.env` turn on error tracking in the API and the worker.
Use a **self-hosted Sentry in Russia** (a processor of the RU deployment: RU data stays in RU, so the
hosted sentry.io is refused at startup (in every region), and the DSN must be `https`). Never share a project with an EU
server. In the Sentry project turn on "Prevent storing of IP addresses" and server-side data scrubbing.
Events carry the error type and stack frames only: no exception text, request bodies, query strings,
local variables, breadcrumbs or user data; tracing is not available here. Empty or unset = nothing is
sent. After changing `.env`: `docker compose up -d api worker`.

## 12. The catalog (Phase 4)

The global medicine catalog (`catalog/`, public reference data: product search, GTIN lookup, product cards)
runs in the same stack. It has **no accounts**: the app calls it without credentials, and it keeps no
record of what was searched or scanned.

```
phone --https--> proxy (catalog host)  --> 127.0.0.1:8081 catalog (public routes only)
                                              |
backend worker (later, https) --> catalog-private:8001 (compose network only: /internal, /admin)
                                              |
                              catalog-postgres 16 (own volume, own roles)    catalog-redis (own, no disk)
```

- **Isolation.** Its own PostgreSQL container and volume; the services connect as the non-superuser role
  `catalog` that owns only `pillpal_catalog` (`infra/catalog-db/init.sh`, run by the one-shot `catalog-db`
  service on every `up`). The public service connects as a second, **read-only** role (`catalog_reader`: SELECT
  on the catalog tables, no write, no inheritance); migrations, importers and the private listener use the
  owner role. PostgreSQL logs no statements, parameters or error statements. The rate limiter has its **own
  Redis** (`catalog-redis`: its own password, no published port, no volume, no snapshots, no append file: a
  restart forgets every bucket); bucket names are keyed hashes whose key changes every UTC day, and the
  backend's Redis is never shared with it. The services receive only `CATALOG_*`, `ENVIRONMENT`, `LOG_LEVEL`
  (from `CATALOG_LOG_LEVEL`) and `FORWARDED_ALLOW_IPS`, never the backend's secrets. The token digests go to the
  private listener only: the public service holds none and answers no `/docs`. Containers run as uid 10001.
- **Not backed up.** `backup.sh` does not dump it: the data is public and the importers rebuild it, the aggregate
  counts return within an hour. A lost volume costs only the admin decisions (`lock`/`reject`) and the audit
  trail. It holds no personal data, so the 14-day retention rule does not apply to it.
- **Same host, separate name.** `CATALOG_DOMAIN` (for example `catalog-staging.example.com`) is a second
  DNS `A` record to the same server and its own certificate.

### 12.1 One-time setup

**Order matters: do steps 1 and 2 before the first deploy that contains the catalog.** The deploy uploads a
compose file that interpolates the catalog variables; on a server whose `.env` lacks them, every compose command
(`pull`, `run`, the `backup.sh` cron) fails, and the deploy stops at its own check. Also set the GitHub
environment variable `STAGING_CATALOG_URL`: the deploy refuses to run without it.

1. DNS: `A` record for `CATALOG_DOMAIN`. GitHub environment variable `STAGING_CATALOG_URL`
   (`https://catalog-staging.example.com`); the deploy checks `<url>/readyz` after the backend's, in its own step
   with a longer window (the first certificate is issued then).
2. `.env`: copy the catalog block of `infra/staging/.env.example` (`CATALOG_IMAGE`, `CATALOG_DOMAIN`,
   `CATALOG_POSTGRES_ADMIN_PASSWORD`, `CATALOG_DB_PASSWORD`, `CATALOG_READER_PASSWORD`, `CATALOG_REDIS_PASSWORD`,
   the two token lists, `CATALOG_RATE_LIMIT_SALT`). Tokens: the catalog stores only SHA-256 digests. Generate a
   secret and its digest with the one-liner in the file, keep the secret in a password manager, put
   `name:digest` in `.env`. **Name tokens by role (`ops`, `oncall`), never by a person**: the name is written to
   `admin_audit` and kept for 730 days. If you change `STAGING_SUBNET`, also set `CADDY_IPV4` and
   `STAGING_GATEWAY` inside it: they are the only addresses whose `X-Forwarded-For` the public catalog believes.
3. Directory for importer files (the importer container runs as uid 10001):

   ```bash
   cd ~/pillpal && mkdir -p catalog-import && sudo chown 10001:10001 catalog-import && chmod 700 catalog-import
   ```
4. Image pull: the `pillpal-catalog` package on GHCR is private by default; the server's read-only login of
   section 7 covers it (same owner), or make the package public (it holds no secrets).
5. Proxy. **Bundled Caddy** (`COMPOSE_PROFILES=caddy`): nothing more, the Caddyfile has the catalog block. It
   proxies exactly `POST /v1/search`, `POST /v1/gtins/lookup`, `POST /v1/products/get`, `GET /v1/sources`,
   `GET /healthz`, `GET /readyz`; everything else (`/admin*`, `/internal*`, `/docs`) is a 404 that never reaches
   the service. Caddy has no access log, and its error log is filtered to drop the URI, client address and
   headers (a global option, so it also applies to the API host). **Own nginx**: a second `server` block with
   logging off and the same allow-list:

   ```nginx
   server {
       listen 80;
       server_name catalog-staging.example.com;
       access_log off;                      # no URI, no address, ever
       error_log /dev/null crit;            # an upstream error line holds the URI and the client address
       client_max_body_size 8k;
       add_header Strict-Transport-Security "max-age=2592000" always;
       proxy_http_version 1.1;
       proxy_set_header Host $host;
       proxy_set_header X-Forwarded-For $remote_addr;   # overwrite, never append
       location = /v1/search        { limit_except POST { deny all; } proxy_pass http://127.0.0.1:8081; }
       location = /v1/gtins/lookup  { limit_except POST { deny all; } proxy_pass http://127.0.0.1:8081; }
       location = /v1/products/get  { limit_except POST { deny all; } proxy_pass http://127.0.0.1:8081; }
       location = /v1/sources       { limit_except GET { deny all; } proxy_pass http://127.0.0.1:8081; }
       location = /healthz          { limit_except GET { deny all; } proxy_pass http://127.0.0.1:8081; }
       location = /readyz           { limit_except GET { deny all; } proxy_pass http://127.0.0.1:8081; }
       location / { return 404; }
   }
   ```

   then `certbot --nginx -d catalog-staging.example.com`. With `error_log /dev/null crit` an upstream failure is
   visible only in the catalog's own JSON log (`docker compose logs catalog`), not in nginx. Put the same
   `error_log` line into the certbot-generated `443` block if certbot copied the server block instead of
   extending it.
   Never publish port 8001 and never add a route to `catalog-private`: it carries `/internal` and `/admin`.
6. Run the deploy. It builds both images, runs `alembic upgrade head` for the backend and then for the
   catalog (`docker compose run --rm catalog-tools alembic upgrade head`, as the owner role), starts everything and
   checks both `/readyz`, one step each.
7. The app: set the **repository variable** `PILLPAL_CATALOG_URLS` to `ru=https://<CATALOG_DOMAIN>` (a
   comma-separated list of `region=https-origin`). `app-release.yml` passes it as a `--dart-define` and refuses
   anything that is not https. Unset or empty: the build has no catalog (no search, no scan, no product card).

An empty catalog answers searches with no results. Import data as below.

### 12.2 Importing data (on demand, never automatic)

The importers run as one-off containers of the `tools` profile (not started by `up`):

```bash
cd ~/pillpal
T="docker compose run --rm catalog-tools"        # /data is ./catalog-import on the host
```

Each source: `fetch` (network sources) into `/data/<dir>` (it refuses a non-empty directory), then `run`.
A run records its counts and a SHA-256 in `import_runs`, never the records. A successful run enables the
source row, so its attribution then appears in `GET /v1/sources` (Settings -> About). Attribution and terms
per source: `catalog/LICENSES.md`. Write each command as `$T python -m catalog.importers <fetch|run> ...`.

| Order | Source | Arguments | Flag | Attribution / terms |
|---|---|---|---|---|
| 1 | RxNorm (US, NLM) | `fetch --source rxnorm --out /data/rxnorm`, then `run --source rxnorm --snapshot /data/rxnorm` | none | NLM terms: attribution and disclaimer; keep the printed `sha256` and pass it as `--expect-sha256` next time |
| 2 | openFDA NDC (US) | `fetch --source openfda_ndc --out /data/openfda`, `run --source openfda_ndc --snapshot /data/openfda` | none | CC0; "not for clinical decisions". Re-run after every new RxNorm release |
| 3 | EMA (EU) | `fetch --source ema --out /data/ema [--url <xlsx>]`, `run --source ema --snapshot /data/ema` | none | EMA legal notice: reuse with acknowledgement. Smoke-import first (format verified on fixtures only) |
| 4 | ЕСКЛП (RU) | `fetch --source esklp --out /data/esklp --url <file url>`, `run --source esklp --snapshot /data/esklp` | `CATALOG_IMPORTER_ESKLP_ENABLED=true` | No published license text: only after the owner checklist (below) |
| 5 | Росздравнадзор recall flags (RU) | `fetch --source ru_roszdravnadzor --out /data/rzn --url <csv url>`, `run --source ru_roszdravnadzor --snapshot /data/rzn` | the ЕСКЛП flag | Open-data terms of Росздравнадзор; run after ЕСКЛП |
| 6 | ГРЛС manual export (RU) | copy the monthly `.xlsx` into `catalog-import/grls/`, then `run --source grls_manual --snapshot /data/grls` | `CATALOG_IMPORTER_GRLS_ENABLED=true` | Site terms of 2014 forbid commercial use: only after legal review (Q3-Q4); no `fetch` exists |

Example: `$T python -m catalog.importers run --source ema --snapshot /data/ema`. The `fixture` source is refused
when `ENVIRONMENT=staging`. Exit codes: 0 ok, 1 failed (code on stderr), 3 refused (flag off, run in progress).
Afterwards check `curl https://<CATALOG_DOMAIN>/v1/sources`.

**Feature flags and the owner checklist.** The ЕСКЛП and ГРЛС flags are `false` in the stack. Set them in `.env`
(`CATALOG_IMPORTER_ESKLP_ENABLED=true`; the `catalog-tools` container reads it on the next `run`). Do it only
after: (1) the file downloads without authentication; (2) the written request to Минздрав / ЦНИИОИЗ is answered;
(3) legal review items 1-2 (`docs/phase4-plan.md`); (4) a smoke import of the real file into a scratch database
matches the portal counts (the headers are verified on synthetic fixtures only). **Never run an unverified real
file against the database that serves the app.** The first successful run of a source publishes its attribution.

### 12.3 Alerts (deployment note of 4.7)

The staging stack has no monitoring stack; check these on the server (cron plus mail, or your log shipper). In
a production deployment they become alert rules on the worker logs:

```bash
cd ~/pillpal
docker compose logs --since 2h worker | grep -E 'catalog_push_failed|catalog_generation_stale'
docker compose logs --since 2h catalog-private | grep -E 'maintenance_failed|redecide_after_import_failed'
```

| Signal (backend worker log) | Meaning | Action |
|---|---|---|
| `catalog_push_failed` while contributions are disabled (the only case in staging: the backend refuses to enable them) | The **retraction** is failing (the empty snapshot that zeroes this region's counts at the catalog) | Fix the link (URL, token, https, catalog up). Until it succeeds the old counts stay at the catalog and expire only after `CATALOG_INGEST_MAX_AGE_HOURS` = **72 h**. Alert on the first occurrence |
| `catalog_push_failed` while contributions are enabled | Counts are not arriving; consensus does not move | Same checks; not urgent |
| `catalog_generation_stale` | The catalog is ahead of the backend's clock, or two senders race | Check the server clock (NTP); if it persists, `$T python -m catalog.admin ingest reset ru` |

`catalog_push_failed` carries only the HTTP status or exception type, never a URL or token. **In staging it
cannot fire at all yet:** the backend link stays empty (`CATALOG_INTERNAL_URL`, `CATALOG_INGEST_TOKEN`), so the
worker neither pushes nor retracts, and these alerts become meaningful only once the link is configured. Set both only when the private listener is reachable over **https** (staging refuses plain http), for
example through a TLS hop that is never the public proxy host; the backend then also needs a worker restart.

### 12.4 Rotation, resets, checks

- Rotate a token by adding a second one (`ru-next:<digest>`), switching the backend, then removing the old digest;
  edit `.env` and `docker compose up -d catalog catalog-private`.
- Resolve a disputed GTIN: `$T python -m catalog.admin resolve <gtin> --action lock --product <uuid>` (audited as `cli`).
- Smoke check: `curl -s -X POST https://<CATALOG_DOMAIN>/v1/search -H 'content-type: application/json' -d '{"q":"test","lang":"en"}'`;
  `curl -s -o /dev/null -w '%{http_code}' https://<CATALOG_DOMAIN>/admin/v1/disputes` must print `404`.
