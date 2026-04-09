# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Uptime Kuma bootstrap helpers.
#
# Notes:
# - Kuma v2 may require /setup-database before /setup.
# - Initial admin bootstrap uses a headless browser against Kuma's real setup/login UI.
#   The previous private Socket.IO bootstrap path drifted across Kuma versions and proved
#   too brittle to keep stable.

kuma::base_url() {
    printf 'http://127.0.0.1:%s\n' "${KUMA_PORT:-3001}"
}

kuma::data_dir() {
    local podmin_home
    podmin_home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER:-podmin}" | cut -d: -f6)}"
    if [[ -z "${podmin_home}" ]]; then
        podmin_home="/home/${PODMAN_USER:-podmin}"
    fi
    printf '%s/.local/share/uptime-kuma\n' "${podmin_home}"
}

kuma::ensure_sqlite_db_config() {
    local data_dir cfg tmp owner group
    data_dir="$(kuma::data_dir)"
    cfg="${data_dir}/db-config.json"
    tmp="${cfg}.tmp"
    owner="${PODMAN_USER:-podmin}"
    group="${PODMAN_USER:-podmin}"

    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure Uptime Kuma sqlite db-config at ${cfg}."
        return 0
    fi

    fs::ensure_dir "${data_dir}" 0750 "${owner}" "${group}" >/dev/null
    printf '%s\n' '{"type":"sqlite"}' > "${tmp}"
    chown "${owner}:${group}" "${tmp}"
    chmod 0644 "${tmp}"
    mv -f "${tmp}" "${cfg}"
}

kuma::wait_ready() {
    local base attempts i code
    base="$(kuma::base_url)"
    attempts="${1:-60}"
    for ((i=1; i<=attempts; i++)); do
        code="$(http::http_code "${base}/")"
        case "${code}" in
            200|302|401|403)
                return 0
                ;;
        esac
        sleep 2
    done
    return 1
}

kuma::setup_database_if_needed() {
    local base info rc
    base="$(kuma::base_url)"

    if ! info="$(http::request GET "${base}/setup-database-info" '' -H 'Accept: application/json' 2>/dev/null)"; then
        rc=$?
        if [[ ${rc} -eq 22 && "${HTTP_LAST_STATUS:-}" == "404" ]]; then
            return 0
        fi
        return ${rc}
    fi

    if ! echo "${info}" | jq -e '.needSetup == true' >/dev/null 2>&1; then
        return 0
    fi

    utils::log_info "Uptime Kuma requires initial database setup; configuring sqlite backend."
    local payload='{"dbConfig":{"type":"sqlite"}}'
    http::request POST "${base}/setup-database" "${payload}" -H 'Content-Type: application/json' >/dev/null

    local i post_info
    for ((i=1; i<=30; i++)); do
        if post_info="$(http::request GET "${base}/setup-database-info" '' -H 'Accept: application/json' 2>/dev/null)"; then
            if echo "${post_info}" | jq -e '.needSetup == false' >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 2
    done

    utils::log_error "Uptime Kuma database setup did not complete in time."
    return 1
}

kuma::playwright_image() {
    printf '%s\n' "${KUMA_PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v1.58.2-noble}"
}

kuma::playwright_version() {
    printf '%s\n' "${KUMA_PLAYWRIGHT_VERSION:-1.58.2}"
}

kuma::browser_cache_dir() {
    local podmin_home
    podmin_home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER:-podmin}" | cut -d: -f6)}"
    if [[ -z "${podmin_home}" ]]; then
        podmin_home="/home/${PODMAN_USER:-podmin}"
    fi
    printf '%s/.cache/archarden/kuma-playwright\n' "${podmin_home}"
}

kuma::__browser_script() {
    cat <<'EOF'
const { chromium } = require("playwright");

const baseUrl = process.env.KUMA_URL || "http://127.0.0.1:3001";
const user = process.env.KUMA_USER || "admin";
const pass = process.env.KUMA_PASS || "";

function summarize(text) {
  return String(text || "").replace(/\s+/g, " ").trim().slice(0, 600);
}

async function bodyText(page) {
  try {
    return summarize(await page.locator("body").innerText({ timeout: 5000 }));
  } catch (_err) {
    return "";
  }
}

async function settle(page) {
  await page.waitForLoadState("domcontentloaded", { timeout: 30000 }).catch(() => {});
  await page.waitForLoadState("networkidle", { timeout: 10000 }).catch(() => {});
  await page.waitForTimeout(1500);
}

async function openBase(page) {
  await page.goto(baseUrl, { waitUntil: "domcontentloaded", timeout: 30000 });
  await settle(page);
}

async function detectState(page) {
  const url = page.url();
  const text = await bodyText(page);
  const passwordCount = await page.locator('input[type="password"]').count().catch(() => 0);
  const textCount = await page.locator('input[type="text"], input[type="email"], input:not([type])').count().catch(() => 0);

  if (passwordCount >= 2 || /create your admin account|repeat password/i.test(text) || /setup/i.test(url)) {
    return { state: "setup", url, text, passwordCount, textCount };
  }
  if ((passwordCount >= 1 && textCount >= 1) || /login/i.test(url)) {
    return { state: "login", url, text, passwordCount, textCount };
  }
  return { state: "app", url, text, passwordCount, textCount };
}

async function firstVisible(locator, maxCount = 8) {
  const count = await locator.count().catch(() => 0);
  for (let i = 0; i < Math.min(count, maxCount); i += 1) {
    const item = locator.nth(i);
    try {
      if (await item.isVisible()) {
        return item;
      }
    } catch (_err) {
      // continue
    }
  }
  return null;
}

async function clickPrimary(page) {
  const candidates = page.locator('button[type="submit"], button.btn-primary, button');
  const button = await firstVisible(candidates, 10);
  if (!button) {
    throw new Error("submit button not found");
  }
  await button.click();
}

async function fillSetup(page) {
  const usernameInput = await firstVisible(page.locator('input[type="text"], input[type="email"], input:not([type])'));
  if (!usernameInput) {
    throw new Error("setup username input not found");
  }
  const passwords = page.locator('input[type="password"]');
  if ((await passwords.count()) < 2) {
    throw new Error("setup password inputs not found");
  }
  await usernameInput.fill(user);
  await passwords.nth(0).fill(pass);
  await passwords.nth(1).fill(pass);
  await clickPrimary(page);
  await settle(page);
}

async function fillLogin(page) {
  const usernameInput = await firstVisible(page.locator('input[type="text"], input[type="email"], input:not([type])'));
  if (!usernameInput) {
    throw new Error("login username input not found");
  }
  const passwordInput = await firstVisible(page.locator('input[type="password"]'));
  if (!passwordInput) {
    throw new Error("login password input not found");
  }
  await usernameInput.fill(user);
  await passwordInput.fill(pass);
  await clickPrimary(page);
  await settle(page);
}

(async () => {
  let browser;
  try {
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    page.setDefaultTimeout(15000);

    await openBase(page);
    let state = await detectState(page);

    if (state.state === "setup") {
      await fillSetup(page);
      state = await detectState(page);
    }

    if (state.state === "login") {
      await fillLogin(page);
      state = await detectState(page);
    }

    if (state.state !== "app") {
      throw new Error(`unexpected final state: ${state.state}`);
    }

    console.log(JSON.stringify({ ok: true, state: state.state, url: state.url, detail: state.text }));
    await browser.close();
    process.exit(0);
  } catch (err) {
    let text = "";
    let url = "";
    try {
      const pages = browser ? browser.contexts().flatMap((ctx) => ctx.pages()) : [];
      const page = pages[0];
      if (page) {
        url = page.url();
        text = await bodyText(page);
      }
    } catch (_err) {
      // ignore secondary inspection failure
    }
    if (browser) {
      await browser.close().catch(() => {});
    }
    console.log(JSON.stringify({ ok: false, error: String(err && err.message ? err.message : err), url, detail: text }));
    process.exit(1);
  }
})();
EOF
}

kuma::__ensure_browser_assets() {
    local cache_dir script_file owner
    cache_dir="$(kuma::browser_cache_dir)"
    script_file="${cache_dir}/kuma-browser.js"
    owner="${PODMAN_USER:-podmin}"

    fs::ensure_dir "${cache_dir}" 0700 "${owner}" "${owner}" >/dev/null
    kuma::__browser_script | utils::write_file_atomic "${script_file}"
    utils::ensure_file_permissions "${script_file}" 0600 "${owner}" >/dev/null
}

kuma::__browser_run() {
    local user="$1" pass="$2" out cache_dir image version
    cache_dir="$(kuma::browser_cache_dir)"
    image="$(kuma::playwright_image)"
    version="$(kuma::playwright_version)"

    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        printf '{"ok":true,"dry_run":true}
'
        return 0
    fi

    kuma::__ensure_browser_assets || return 1

    out="$(runuser -u "${PODMAN_USER:-podmin}" -- bash -lc '
cd / >/dev/null 2>&1 || true
export KUMA_URL="'"$(kuma::base_url)"'"
export KUMA_USER="'"${user}"'"
export KUMA_PASS="'"${pass}"'"
export KUMA_PW_VERSION="'"${version}"'"
bash -s
' <<'EOF'
set -euo pipefail
cache_dir="$(printf '%s' "${HOME}/.cache/archarden/kuma-playwright")"
podman run --rm --init --ipc=host --network container:uptime-kuma   -e KUMA_URL -e KUMA_USER -e KUMA_PASS -e KUMA_PW_VERSION   -v "${cache_dir}:/work:Z" -w /work   "$(printf '%s' "${KUMA_PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v1.58.2-noble}")"   /bin/sh -lc '
    set -eu
    if [ ! -d node_modules/playwright ]; then
      [ -f package.json ] || npm init -y >/dev/null 2>&1
      npm install --no-fund --no-audit "playwright@${KUMA_PW_VERSION}" >/dev/null 2>&1
    fi
    node /work/kuma-browser.js
  '
EOF
)" || return 1
    printf '%s\n' "${out}"
}

kuma::ensure_admin_credentials() {
    local user pass out
    user="$(secrets::ensure_kuma_admin_user)"
    pass="$(secrets::ensure_kuma_admin_pass)"

    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would bootstrap Uptime Kuma admin '${user}' via headless browser at $(kuma::base_url)."
        return 0
    fi

    kuma::ensure_sqlite_db_config || return 1

    if ! kuma::wait_ready 60; then
        utils::log_error "Uptime Kuma did not become reachable at $(kuma::base_url)."
        return 1
    fi

    kuma::setup_database_if_needed || return 1

    if ! kuma::wait_ready 60; then
        utils::log_error "Uptime Kuma did not become reachable after database setup at $(kuma::base_url)."
        return 1
    fi

    utils::log_info "Ensuring Uptime Kuma admin account via headless browser."
    out="$(kuma::__browser_run "${user}" "${pass}")" || {
        utils::log_error "Unable to bootstrap or verify Uptime Kuma admin account via headless browser."
        return 1
    }

    if ! echo "${out}" | jq -e '.ok == true' >/dev/null 2>&1; then
        utils::log_error "Uptime Kuma browser bootstrap detail: ${out}"
        utils::log_error "Unable to bootstrap or verify Uptime Kuma admin account via headless browser."
        return 1
    fi

    utils::log_info "Uptime Kuma admin credentials are configured and verified via headless browser."
}
