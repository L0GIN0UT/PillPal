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

Create the environment `staging` (Settings -> Environments) and put the five `STAGING_SSH_*`
secrets in it (or use repository secrets). The `PILLPAL_*` variables must be **repository**
variables (the app build does not use the environment).

| Kind | Name | Value |
|---|---|---|
| secret | `STAGING_SSH_HOST` | VPS host or IP |
| secret | `STAGING_SSH_PORT` | optional, default 22 |
| secret | `STAGING_SSH_USER` | the deploy user |
| secret | `STAGING_SSH_KEY` | private key of the deploy key (below), whole file |
| secret | `STAGING_SSH_KNOWN_HOSTS` | verified `ssh-keyscan` line(s) of the server (below) |
| variable | `STAGING_PUBLIC_URL` | `https://staging.example.com` |
| variable | `STAGING_DIR` | optional, default `~/pillpal` |
| variable | `PILLPAL_API_BASE_URL_RU` | `https://staging.example.com` (no path, no slash) |
| variable | `PILLPAL_LINK_HOST_RU` | `staging.example.com` (host only) |
| variable | `PILLPAL_FCM_API_KEY`, `PILLPAL_FCM_APP_ID`, `PILLPAL_FCM_SENDER_ID`, `PILLPAL_FCM_PROJECT_ID` | from step 3 (all four or none) |
| secret | `ANDROID_KEYSTORE_BASE64` | step 5 |
| secret | `ANDROID_KEY_ALIAS` | `pillpal-upload` |
| secret | `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD` | the passwords you chose |

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
mkdir -p ~/pillpal/secrets && cd ~/pillpal
```

**`.env`** - copy `infra/staging/.env.example` there (`scp infra/staging/.env.example deploy@<host>:pillpal/.env`)
and fill every `CHANGE_ME`: `PILLPAL_IMAGE=ghcr.io/<your github login in lower case>/pillpal-backend`,
`PUBLIC_DOMAIN`, `JWT_SECRET`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD` (generators are in the file; URL-safe
characters, no `$`), `ANDROID_CERT_SHA256S`, `FCM_PROJECT_ID`, `SMTP_*`. `chmod 600 .env`.

**Secret files** (mounted read-only as Docker secrets; the container user has uid 10001):

```bash
printf '%s' 'THE-SMTP-APP-PASSWORD' > secrets/smtp_password
# paste the service account JSON of step 3.4 into secrets/fcm_service_account.json (or scp it)
sudo chown 10001:10001 secrets/smtp_password secrets/fcm_service_account.json
sudo chmod 400 secrets/smtp_password secrets/fcm_service_account.json
```

`docker-compose.yml`, `Caddyfile` and `backup.sh` are uploaded by every deploy from the deployed
commit (local edits there are overwritten: use `.env`).

**Image pull (GHCR).** The package is private by default. Either:

- (recommended) a read-only login on the server: GitHub -> Settings -> Developer settings ->
  Personal access tokens -> *Tokens (classic)* -> scope **`read:packages`** only (fine-grained
  tokens do not support the container registry). Then
  `echo '<token>' | docker login ghcr.io -u <github login> --password-stdin`. The token stays in
  `~/.docker/config.json` on the server and is never put into an image or sent by the workflow; or
- make the `pillpal-backend` package public (Package settings -> Change visibility). It holds no secrets.

**Reverse proxy.** Pick one.

### (a) The host already runs nginx (another app on 80/443)

Add `/etc/nginx/conf.d/pillpal-staging.conf` (or a `sites-available` file), then get the certificate:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name staging.example.com;

    client_max_body_size 1m;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    # Overwrite, never append: the API trusts this header for rate limiting.
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_read_timeout 60s;

    # Everything goes to the API; the two paths below matter for invite links and must answer 200
    # directly on https (no redirect), because Google fetches the verification file.
    location = /.well-known/assetlinks.json { proxy_pass http://127.0.0.1:8080; }
    location = /i                            { proxy_pass http://127.0.0.1:8080; }
    location /                               { proxy_pass http://127.0.0.1:8080; }
}
```

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

### (b) No proxy yet: bundled Caddy (automatic HTTPS)

Ports 80 and 443 must be free. Add `COMPOSE_PROFILES=caddy` to `.env`. The deploy then also starts
Caddy, which obtains and renews the certificate for `PUBLIC_DOMAIN` by itself (the DNS record must
already point to the server). Nothing else to configure.

## 8. First deployment

1. Merge the PR so that `deploy-staging.yml` is on `main`; set the secrets/variables of step 6.
2. Actions -> `deploy-staging` -> Run workflow (ref `main`). It builds and pushes the image
   (`:<sha>` and `:staging`), uploads the compose files, runs
   `docker compose pull && docker compose run --rm api alembic upgrade head && docker compose up -d`
   and waits for `https://<domain>/readyz`.
3. Check by hand: `curl https://staging.example.com/.well-known/assetlinks.json` returns your
   package name and fingerprint.

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

Restore into an empty database: stop the stack (`docker compose stop api worker`), then
`gunzip -c backups/<file>.sql.gz | docker compose exec -T postgres psql -U pillpal -d pillpal`,
start again. Copy dumps to another machine only inside Russia (152-FZ).

## 11. Variables of the stack (`infra/staging/.env`)

See `infra/staging/.env.example`. The compose file fixes `ENVIRONMENT=staging`, `REGION=ru`,
`DETECTOR_ENABLED=true`, `EMAIL_BACKEND=smtp`; staging refuses to start with `LOG_EMAIL_CODES`, a
non-SMTP e-mail backend, a short `JWT_SECRET` or a half-configured push provider.
