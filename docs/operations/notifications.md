# Notifications

Archarden deploys `ntfy` as a rootless Podman container behind NPM. The server is configured as a private instance with `auth-default-access: deny-all`, `web-root: disable`, `require-login: true`, generated admin and publisher credentials, a generated publisher token, and a randomized topic. No anonymous read access is granted. The ntfy configuration lives in the podmin config directory and the publisher settings are written to `/etc/archarden/notify.env`.

After phase 1, the pieces you care about are:

- public URL: `https://<--ntfy-public-host>`
- randomized topic: `/var/lib/archarden/secrets/ntfy_topic`
- admin username/password: `/var/lib/archarden/secrets/ntfy_admin_user` and `/var/lib/archarden/secrets/ntfy_admin_pass`
- publisher token used by Archarden: `/var/lib/archarden/secrets/ntfy_token`
- ntfy web UI is disabled by default; use the Android app or API clients instead
- sender env used by timers/jobs: `/etc/archarden/notify.env`

`archarden notify init --backend ntfy --test` now acts as a verification/write step. It reloads the publisher settings from persisted answers and secrets, writes `/etc/archarden/notify.env`, and can send a test message.
