#!/usr/bin/env bash
#
# OdooTool - one-shot installer (Linux native + WSL)
#
# Sets up a complete local stack in one run:
#   1. Asks for the company data and the AI provider.
#   2. Installs PostgreSQL and the Python packages Odoo needs.
#   3. Installs Odoo 20 Community and creates a database with the base modules.
#   4. Downloads AgentBridge and installs the OdooTool plugin (activated by default).
#   5. Configures OdooTool with the Odoo address and an API key.
#   6. Starts Odoo, opens the local start page in the default browser and leaves Odoo running with
#      the assistant installed and ready to start from the icon.
#
# INSTALLER CONTRACT - do not change without reading INSTALLER-CONTRACT.md.
# The "AI Odoo" launcher must start Odoo, give AgentBridge a visible terminal window, and open the
# local start page: one screen that says what runs on this machine, with a link to Odoo at
# http://localhost:8069/web/login?db=odoo_agent and the credentials. The assistant is the terminal
# window, not a browser tab: the page does not link the office chat. The bare address
# http://localhost:8069 is not the destination because, with the website module installed, it
# renders the public placeholder site. The office chat on 5290 is a second entrance: linked, never
# opened. Shared rationale: AgentBridge/docs-dev/INSTALLER-CONTRACT.md.
#
# CROSS-PLATFORM PARITY - this file is the Linux half of ONE installer. Every substantial change
# here must be made in installer/install.ps1 (and installer/install.bat) as well: the Windows user
# must get the same behaviour, the same questions and the same final state. Do not "simplify" one
# side on its own.
#
# Run:  bash install.sh
#
set -euo pipefail

# --- Defaults (override with environment variables) ------------------------
ODOO_REPO="${ODOO_REPO:-https://github.com/odoo/odoo.git}"
ODOO_BRANCH="${ODOO_BRANCH:-20.0}"
ODOO_MAJOR="${ODOO_MAJOR:-20}"
AB_REPO="${AB_REPO:-Graphene-Lab/AgentBridge}"
AB_TAG="${AB_TAG:-latest}"
TOOL_PKG="${TOOL_PKG:-Graphene.OdooTool}"
INSTALL_ROOT="${INSTALL_ROOT:-$HOME/odoo-tool-stack}"
ODOO_DIR="$INSTALL_ROOT/odoo"
AB_DIR="$INSTALL_ROOT/agentbridge"
DB_USER="${DB_USER:-odoo}"
DB_PASSWORD="${DB_PASSWORD:-odoo}"
DB_PORT="${DB_PORT:-5432}"
ODOO_PORT="${ODOO_PORT:-8069}"
ODOO_API_KEY="${ODOO_API_KEY:-}"
# Filled in by create_api_key: the administrator login that exists and whether this run set its
# password. Empty means "not configured", never "assume the wizard's default".
ADMIN_LOGIN=""
ADMIN_PASS_SET=0

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mx %s\033[0m\n' "$*" >&2; exit 1; }

# --- Wizard --------------------------------------------------------------
ask() { # ask VAR "Prompt" "default"
  local var="$1" prompt="$2" def="${3:-}" reply=""
  # Unattended: an environment variable of the same name wins (no prompt).
  if [ -n "${!var:-}" ]; then return; fi
  read -r -p "$prompt [${def}]: " reply || true
  reply="${reply:-$def}"
  printf -v "$var" '%s' "$reply"
}

gen_password() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }

run_wizard() {
  log "Questions"
  ask COMPANY_NAME  "Company name" "My Company"
  # The administrator is a user of the database created here, not an account anywhere: Odoo
  # Community needs no registration, nothing is sent to odoo.com, and nobody is asked for Odoo
  # credentials. The login and the password are generated locally and printed at the end;
  # ADMIN_EMAIL / ADMIN_PASS still override them for unattended runs.
  ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
  # ADMIN_PASS_GIVEN records whether the password came from the environment: on a re-run the
  # account keeps its own login, and its password is rewritten only when somebody asked for it.
  ADMIN_PASS_GIVEN="${ADMIN_PASS:-}"
  ADMIN_PASS="${ADMIN_PASS:-$(gen_password)}"
  ask LLM_BASE_URL "LLM provider base URL (OpenAI-compatible)" "http://192.168.43.253:8741/v1"
  ask LLM_KEY      "LLM provider API key" ""
  ask LLM_MODEL    "LLM model name" "halogen-qwen3.8-flash-next"
}

# --- Free space ----------------------------------------------------------
# PostgreSQL, Odoo with its virtualenv and the 1.4 GB AgentBridge archive (plus the same again
# extracted) all land under one root. A disk that fills up does not fail cleanly: it truncates
# whatever is being written at that moment, so the space is checked before the first download.
INSTALL_NEED_GB="${INSTALL_NEED_GB:-12}"
check_space() {
  mkdir -p "$INSTALL_ROOT" || die "cannot create $INSTALL_ROOT"
  local avail_gb
  avail_gb=$(df -Pk "$INSTALL_ROOT" | awk 'NR==2 {printf "%.1f", $4/1048576}')
  awk -v a="$avail_gb" -v n="$INSTALL_NEED_GB" 'BEGIN { exit (a < n) ? 1 : 0 }' ||
    die "not enough free space on $INSTALL_ROOT - ${avail_gb} GB free, about ${INSTALL_NEED_GB} GB needed (INSTALL_NEED_GB overrides)"
  log "Free space: ${avail_gb} GB"
}

# --- Prerequisites -------------------------------------------------------
install_prereqs() {
  log "Installing PostgreSQL and Python build dependencies"
  sudo apt-get update -y || warn "apt update reported an error, continuing"
  # A pre-existing broken package (seen in WSL with linux-headers) makes apt return
  # non-zero even when the packages we need are installed, so do not abort on it:
  # verify the tools we actually require below instead.
  sudo apt-get install -y git python3 python3-pip python3-venv postgresql libpq-dev \
    build-essential libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
    libjpeg-dev zlib1g-dev wkhtmltopdf \
    || warn "apt reported an error (often an unrelated broken package in WSL); checking the required tools."
  local missing=0
  for tool in python3 psql wkhtmltopdf gcc git; do
    command -v "$tool" >/dev/null || { warn "required tool missing: $tool"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "One or more required tools are missing. Fix the system packages and re-run."
}

configure_postgres() {
  log "Configuring PostgreSQL user '$DB_USER'"
  # Start the cluster without assuming a PostgreSQL major version: the one installed by the
  # distro package changes over time (12/13/14/15/16/...), so the version is looked up.
  sudo service postgresql start 2>/dev/null || true
  if ! pg_isready -q -p "$DB_PORT" 2>/dev/null; then
    pg_cluster="$(pg_lsclusters -h 2>/dev/null | awk 'NR==1 {print $1" "$2}')"
    if [ -n "$pg_cluster" ]; then sudo pg_ctlcluster $pg_cluster start 2>/dev/null || true; fi
  fi
  # Create the role when it is missing, repair the password when it is already there with a
  # different one. Only CREATE used to leave an old password in place on a re-run with a changed
  # DB_PASSWORD, and the Odoo database step minutes later then failed with an authentication error.
  # -w (--no-password) and </dev/null: psql must never fall back to an interactive password
  # prompt, which would leave the installer blocked waiting for input nobody can provide.
  # The superuser is reached with sudo -u postgres over the local socket (peer authentication),
  # so no PostgreSQL superuser password is involved at any point.
  if sudo -u postgres psql -w -p "$DB_PORT" -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" </dev/null | grep -q 1; then
    sudo -u postgres psql -w -p "$DB_PORT" -c "ALTER ROLE $DB_USER LOGIN SUPERUSER PASSWORD '$DB_PASSWORD';" </dev/null \
      || warn "could not set the password for the existing role '$DB_USER'"
  else
    sudo -u postgres psql -w -p "$DB_PORT" -c "CREATE ROLE $DB_USER LOGIN SUPERUSER PASSWORD '$DB_PASSWORD';" </dev/null \
      || warn "could not create the role '$DB_USER'"
  fi
  # Verify with the credentials the rest of the stack actually uses, so a wrong password is
  # reported here instead of in the middle of the Odoo setup.
  if PGPASSWORD="$DB_PASSWORD" psql -w -U "$DB_USER" -h 127.0.0.1 -p "$DB_PORT" -d postgres -tAc 'select 1' </dev/null 2>/dev/null | grep -q 1; then
    log "role '$DB_USER' ready"
  else
    warn "role '$DB_USER' cannot connect with that password; the Odoo database step will fail until it does"
  fi
}

install_odoo() {
  log "Cloning Odoo $ODOO_MAJOR Community ($ODOO_BRANCH)"
  mkdir -p "$INSTALL_ROOT"
  [ -d "$ODOO_DIR" ] || git clone --depth 1 --branch "$ODOO_BRANCH" "$ODOO_REPO" "$ODOO_DIR"
  log "Installing Odoo Python requirements in a virtualenv"
  python3 -m venv "$INSTALL_ROOT/venv"
  "$INSTALL_ROOT/venv/bin/pip" install --upgrade pip
  "$INSTALL_ROOT/venv/bin/pip" install -r "$ODOO_DIR/requirements.txt"
}

create_database() {
  log "Creating the Odoo database and installing the base modules"
  "$INSTALL_ROOT/venv/bin/python" "$ODOO_DIR/odoo-bin" \
    -d odoo_agent --db_host=127.0.0.1 --db_port "$DB_PORT" --db_user "$DB_USER" --db_password "$DB_PASSWORD" \
    --addons-path="$ODOO_DIR/addons" \
    -i base --stop-after-init --without-demo || true
}

create_api_key() {
  # The key and the administrator account are read in the same Odoo shell run: the key is
  # generated only when there is none yet, and the account reports its REAL login, so the summary
  # and the start page never print a user name the database does not have. On a re-run the login
  # stays as it is and the password is rewritten only when ADMIN_PASS was given: printing a
  # password that was never applied is worse than printing none (measured 2026-11-20 on Windows).
  local existing="" need_key=0 set_pass=0 newkey=""
  if [ -f "$AB_DIR/PersistentData/odoo.json" ]; then
    existing="$(sed -n 's/.*"apiKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$AB_DIR/PersistentData/odoo.json" 2>/dev/null | head -1)"
  fi
  if [ -n "$existing" ]; then
    ODOO_API_KEY="$existing"
    log "Reading the administrator account (the API key is already there)"
  else
    need_key=1
    log "Creating an Odoo API key for the admin user"
  fi
  [ -n "$ADMIN_PASS_GIVEN" ] && set_pass=1
  ODOO_ADMIN_EMAIL="$ADMIN_EMAIL" ODOO_ADMIN_PASS="$ADMIN_PASS" \
  ODOO_SET_PASSWORD="$set_pass" ODOO_MAKE_KEY="$need_key" \
  "$INSTALL_ROOT/venv/bin/python" "$ODOO_DIR/odoo-bin" shell -d odoo_agent \
    --db_host=127.0.0.1 --db_port "$DB_PORT" --db_user "$DB_USER" --db_password "$DB_PASSWORD" \
    --addons-path="$ODOO_DIR/addons" --no-http <<'PY' > "$INSTALL_ROOT/odoo_api_key.txt" 2>/dev/null || true
import os
admin = env["res.users"].browse(2)
set_password = os.environ.get("ODOO_SET_PASSWORD") == "1"
# The database step creates the administrator with the login 'admin'. That account is renamed to
# the address the wizard asked for and given a password this run can print. On a re-run the login
# stays as it is, and the password is rewritten only when ADMIN_PASS was given.
if admin.login == 'admin':
    email = os.environ["ODOO_ADMIN_EMAIL"]
    admin.write({"login": email, "email": email, "password": os.environ["ODOO_ADMIN_PASS"]})
    set_password = True
else:
    found = env["res.users"].search([("login", "=", os.environ["ODOO_ADMIN_EMAIL"])], limit=1)
    if found:
        admin = found
    if set_password:
        admin.write({"password": os.environ["ODOO_ADMIN_PASS"]})
key = ""
if os.environ.get("ODOO_MAKE_KEY") == "1":
    key = env["res.users.apikeys"].with_user(admin)._generate("rpc", "agentbridge", None)
env.cr.commit()
# Three facts on three lines, so a stray log line can never be taken for the key.
print("KEY=" + (key or ""))
print("LOGIN=" + (admin.login or ""))
print("PASSWORD_SET=" + ("1" if set_password else "0"))
PY
  newkey="$(sed -n 's/^KEY=//p' "$INSTALL_ROOT/odoo_api_key.txt" 2>/dev/null | head -1)"
  [ -n "$newkey" ] && ODOO_API_KEY="$newkey"
  ADMIN_LOGIN="$(sed -n 's/^LOGIN=//p' "$INSTALL_ROOT/odoo_api_key.txt" 2>/dev/null | head -1)"
  ADMIN_PASS_SET="$(sed -n 's/^PASSWORD_SET=//p' "$INSTALL_ROOT/odoo_api_key.txt" 2>/dev/null | head -1)"
  ADMIN_PASS_SET="${ADMIN_PASS_SET:-0}"
  if [ "$need_key" -eq 1 ] && [ -z "$ODOO_API_KEY" ]; then
    warn "Could not auto-create the API key. Create it in Odoo (Preferences -> Account Security -> New API Key) and set ODOO_API_KEY before starting the assistant."
  fi
}

# --- AgentBridge + OdooTool plugin --------------------------------------
install_agentbridge() {
  mkdir -p "$AB_DIR"
  # "Already installed" is not "up to date". The first version of this installer skipped the
  # download whenever the binary existed, so a stack installed in November kept that assistant for
  # ever while the tool, the plugin and the book moved on: the user saw a TUI four releases old and
  # reported it as a bug (2026-11-20). The installed tag is read from a stamp written after every
  # successful install.
  local stamp="$AB_DIR/odootool-version.txt" installed="" want="$AB_TAG" need=0
  [ -f "$stamp" ] && installed="$(tr -d '\r\n' < "$stamp")"
  if [ "$AB_TAG" = "latest" ]; then
    # One API call per run, bounded: an install must not fail because a version check did.
    want="$(curl -fsSL --max-time 30 "https://api.github.com/repos/$AB_REPO/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    if [ -z "$want" ]; then
      warn "could not ask GitHub which AgentBridge release is current; keeping what is installed"
      want="$installed"
    fi
  fi
  if [ ! -x "$AB_DIR/agent" ]; then
    need=1
  elif [ -n "$want" ] && [ -n "$installed" ] && [ "$want" != "$installed" ]; then
    log "AgentBridge $installed is installed and $want is current: updating"
    # A running assistant holds its own binary open, so it is stopped before the archive is unpacked.
    pkill -f -- "$AB_DIR/agent" 2>/dev/null || true
    sleep 2
    need=1
  elif [ -z "$installed" ]; then
    log "AgentBridge is installed (version unknown); keeping it"
  else
    log "AgentBridge $installed is up to date"
  fi
  [ "$need" -eq 1 ] || return 0
  log "Downloading AgentBridge"
  local asset="agentbridge-linux-x64.tar.gz"
  # The file name carries the tag, so a partial transfer left by an earlier run can only ever be
  # resumed for the release it belongs to: appending a new version to an old prefix produces an
  # archive the extractor rejects minutes later.
  local pkg="$AB_DIR/agentbridge-linux-x64-${want:-latest}.tar.gz"
  local url
  if [ -n "$want" ] && [ "$want" != "latest" ]; then
    url="https://github.com/$AB_REPO/releases/download/$want/$asset"
  else
    url="https://github.com/$AB_REPO/releases/latest/download/$asset"
  fi
  # Direct download from the public release; no gh auth needed. The archive is ~1 GB,
  # so retry and resume a partial transfer instead of failing on a network blip.
  curl -fL --retry 5 --retry-delay 5 -C - "$url" -o "$pkg"
  if ! tar -tzf "$pkg" >/dev/null 2>&1; then
    warn "AgentBridge archive is corrupt; downloading again from scratch"
    rm -f "$pkg"
    curl -fL --retry 5 --retry-delay 5 "$url" -o "$pkg"
    tar -tzf "$pkg" >/dev/null 2>&1 || die "AgentBridge archive could not be verified (download corrupt)"
  fi
  tar -xzf "$pkg" -C "$AB_DIR" || die "AgentBridge extraction failed"
  # 1 GB that is never needed again; keeping it doubled the footprint of the install.
  rm -f "$pkg"
  # The stamp is what a later run compares against: without it, "already installed" is the only
  # thing the installer can say, and a stack is frozen at the release it was born with.
  [ -n "$want" ] && [ "$want" != "latest" ] && printf '%s' "$want" > "$stamp"
  return 0
}

install_plugin() {
  log "Installing the OdooTool plugin into Tools/OdooTool"
  local tools_dir="$AB_DIR/Tools/OdooTool"
  mkdir -p "$tools_dir"
  local ver
  ver=$(curl -sf "https://api.nuget.org/v3-flatcontainer/graphene.odootool/index.json" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['versions'][-1])" 2>/dev/null)
  if [ -z "$ver" ]; then
    warn "Could not resolve the Graphene.OdooTool version"
    return 1
  fi
  local nupkg="/tmp/graphene.odootool.$ver.nupkg"
  curl -sfL "https://api.nuget.org/v3-flatcontainer/graphene.odootool/$ver/graphene.odootool.$ver.nupkg" -o "$nupkg" \
    || { warn "Could not download the OdooTool package"; return 1; }
  python3 - "$nupkg" "$tools_dir" <<'PY' || { warn "Could not extract OdooTool.dll"; return 1; }
import sys, zipfile, os
nupkg, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(nupkg) as z:
    names = [n for n in z.namelist() if n.startswith('lib/') and n.endswith('/OdooTool.dll')]
    if not names:
        sys.exit('OdooTool.dll not found in the package')
    with z.open(names[0]) as src, open(os.path.join(out, 'OdooTool.dll'), 'wb') as dst:
        dst.write(src.read())
    xmls = [n for n in z.namelist() if n.startswith('lib/') and n.endswith('/OdooTool.xml')]
    if xmls:
        with z.open(xmls[0]) as src, open(os.path.join(out, 'OdooTool.xml'), 'wb') as dst:
            dst.write(src.read())
PY
  log "OdooTool plugin installed (version $ver)"
}

configure_agentbridge() {
  log "Configuring AgentBridge with the LLM provider and the OdooTool plugin"
  local cfg="$AB_DIR/PersistentData"
  mkdir -p "$cfg"
  if [ ! -f "$cfg/providers.json" ]; then
  cat > "$cfg/providers.json" <<JSON
{
  "providers": [
    {
      "name": "OdooStackLLM",
      "baseUrl": "$LLM_BASE_URL",
      "apiKey": "$LLM_KEY",
      "model": "$LLM_MODEL"
    }
  ]
}
JSON
  else log "Keeping the existing providers.json"; fi
  cat > "$cfg/odoo.json" <<JSON
{
  "baseUrl": "http://localhost:$ODOO_PORT",
  "apiKey": "$ODOO_API_KEY",
  "database": "odoo_agent"
}
JSON
}

open_firewall() {
  log "Opening TCP port $ODOO_PORT in the firewall"
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${ODOO_PORT}/tcp" || warn "ufw could not open the port"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --add-port="${ODOO_PORT}/tcp" --permanent && firewall-cmd --reload \
      || warn "firewalld could not open the port"
  elif command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$ODOO_PORT" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "$ODOO_PORT" -j ACCEPT \
      || warn "iptables could not open the port"
  else
    warn "No firewall tool found; open TCP $ODOO_PORT manually if remote access is needed."
  fi
}

# The local start page: a file, not a web service, so it needs no process and works offline. It is
# what the icon opens and what the installation ends with, and it is regenerated on every run so
# the credentials on it are the ones that work. It replaced the bare http://localhost:8069, whose
# meaning depends on what is installed: with the website module it renders the public placeholder
# site, and a reader cannot tell it apart from a demo web page (reported 2026-11-20).
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

create_start_page() {
  log "Writing the start page"
  local erp_url="http://localhost:$ODOO_PORT/web/login?db=odoo_agent"
  local login_html pass_html
  if [ -n "$ADMIN_LOGIN" ]; then
    login_html="<code>$(printf '%s' "$ADMIN_LOGIN" | html_escape)</code>"
    if [ "$ADMIN_PASS_SET" = "1" ]; then
      pass_html="<code>$(printf '%s' "$ADMIN_PASS" | html_escape)</code>"
    else
      pass_html="unchanged since the first installation (set ADMIN_PASS before running the installer to change it)"
    fi
  else
    login_html="not configured by this run: read the problems printed above"
    pass_html="not configured by this run"
  fi
  cat > "$INSTALL_ROOT/start.html" <<HTML
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>AI Odoo - start page</title>
<style>
  body { margin:0; font:16px/1.55 "Segoe UI", system-ui, sans-serif; color:#1b1b1b; background:#f4f4f6; }
  main { max-width:780px; margin:0 auto; padding:40px 24px 56px; }
  h1 { font-size:28px; margin:0 0 10px; }
  h2 { font-size:18px; margin:34px 0 10px; }
  .lede { font-size:17px; color:#3c3c46; margin:0 0 26px; }
  .doors { display:grid; gap:16px; grid-template-columns:1fr; }
  a.door { display:block; text-decoration:none; color:inherit; background:#fff; border:1px solid #dcdce4;
           border-radius:10px; padding:18px 20px; }
  a.door:hover { border-color:#875A7B; }
  .t { font-weight:600; font-size:18px; color:#714B67; }
  .d { color:#4a4a55; font-size:15px; margin-top:6px; }
  .addr { font-family:Consolas, monospace; font-size:13px; color:#6b6b76; margin-top:10px; }
  .card { background:#fff; border:1px solid #dcdce4; border-radius:10px; padding:14px 20px; }
  table { border-collapse:collapse; }
  td { padding:3px 18px 3px 0; vertical-align:top; }
  td.k { color:#6b6b76; white-space:nowrap; }
  code { font-family:Consolas, monospace; background:#f0f0f4; padding:1px 5px; border-radius:4px; }
  ul { margin:6px 0 0; padding-left:20px; }
  li { margin:5px 0; }
  footer { margin-top:34px; color:#6b6b76; font-size:13px; }
</style>
<main>
  <h1>AI Odoo is running on this computer</h1>
  <p class="lede">Odoo is a <strong>web application</strong>: the program runs here, on this PC, and
  the browser is its screen. The address <code>localhost</code> means <em>this computer</em>.
  Nothing on this page goes through the internet.</p>

  <div class="doors">
    <a class="door" href="$erp_url">
      <div class="t">Open Odoo &rarr;</div>
      <div class="d">The ERP: customers, products, orders, invoices, stock. Log in with the account below.</div>
      <div class="addr">http://localhost:$ODOO_PORT</div>
    </a>
  </div>

  <h2>The account</h2>
  <div class="card"><table>
    <tr><td class="k">Login</td><td>$login_html</td></tr>
    <tr><td class="k">Password</td><td>$pass_html</td></tr>
  </table></div>

  <h2>The black window is the assistant</h2>
  <div class="card"><p style="margin:0">Double-clicking the <strong>AI Odoo</strong> icon also opens a
  black window: <strong>that is the assistant</strong>, and it is where you talk to it. Type there,
  for example <em>list the customers</em>, and it does the work in Odoo, in the browser. Leave it
  open while you work: closing it stops the assistant.</p></div>

  <h2>If a page does not open</h2>
  <div class="card"><ul>
    <li>Double-click the <strong>AI Odoo</strong> icon again: it starts whatever is not running.</li>
    <li>If Odoo still does not answer, the file <code>odoo.log</code> in <code>$INSTALL_ROOT</code> says why.</li>
    <li>Odoo's own user guide: <a href="https://www.odoo.com/documentation/20.0/applications.html">odoo.com/documentation/20.0</a>.</li>
  </ul></div>

  <footer>This page is generated by the OdooTool installer. It lives on this computer, in $INSTALL_ROOT.</footer>
</main>
</html>
HTML
}

# Launcher contract: start Odoo, start AgentBridge (with the OdooTool plugin already in
# Tools/) if the chat is not answering, and open the local start page in the default browser.
# Do not reduce this to an Odoo-only shortcut, and do not open the bare Odoo address: the start
# page is the one screen that explains what runs here and leads to both doors.
create_launcher() {
  log "Creating the one-click launcher"
  # Header: written now, storing the real values as safe bash literals with printf %q, so a path
  # or a password containing $ ` " | \ or spaces cannot corrupt or inject anything in the file.
  cat > "$INSTALL_ROOT/start.sh" <<EOF
#!/bin/bash
ROOT=$(printf '%q' "$INSTALL_ROOT")
PORT=$ODOO_PORT
OFFICE_PORT=5290
OFFICE_URL="http://localhost:$OFFICE_PORT/OfficeManager"
DBPORT=$DB_PORT
DBUSER=$(printf '%q' "$DB_USER")
DBPASS=$(printf '%q' "$DB_PASSWORD")
EOF
  # Body: kept literal; it only uses the variables defined just above.
  cat >> "$INSTALL_ROOT/start.sh" <<'LAUNCHER'
if ! curl -sf -o /dev/null "http://localhost:$PORT/web/login"; then
  setsid "$ROOT/venv/bin/python" "$ROOT/odoo/odoo-bin" -d odoo_agent --db_host=127.0.0.1 --db_port "$DBPORT" \
    --db_user "$DBUSER" --db_password "$DBPASS" --addons-path="$ROOT/odoo/addons" \
    --http-port "$PORT" --http-interface=0.0.0.0 > "$ROOT/odoo.log" 2>&1 < /dev/null &
  for i in $(seq 1 40); do curl -sf -o /dev/null "http://localhost:$PORT/web/login" && break; sleep 2; done
fi
# Start the assistant in its own terminal window when 5290 is free: the TUI is the product, and
# a detached process without a terminal shows nothing. If no terminal emulator is available the
# agent still starts headless, so the chat remains reachable at $OFFICE_URL.
if ! curl -sf -o /dev/null "http://localhost:$OFFICE_PORT" && [ -x "$ROOT/agentbridge/agent" ]; then
  if command -v x-terminal-emulator >/dev/null 2>&1; then
    setsid x-terminal-emulator -e "$ROOT/agentbridge/agent" >/dev/null 2>&1 < /dev/null &
  elif command -v gnome-terminal >/dev/null 2>&1; then
    setsid gnome-terminal -- "$ROOT/agentbridge/agent" >/dev/null 2>&1 < /dev/null &
  elif command -v konsole >/dev/null 2>&1; then
    setsid konsole -e "$ROOT/agentbridge/agent" >/dev/null 2>&1 < /dev/null &
  elif command -v xterm >/dev/null 2>&1; then
    setsid xterm -e "$ROOT/agentbridge/agent" >/dev/null 2>&1 < /dev/null &
  else
    setsid "$ROOT/agentbridge/agent" > "$ROOT/agentbridge/agent.log" 2>&1 < /dev/null &
  fi
fi
# The start page in the default browser: it explains what is running and holds the door into the
# ERP. The assistant is the terminal window, so the office chat on $OFFICE_PORT is not linked.
for i in $(seq 1 30); do curl -sf -o /dev/null "http://localhost:$PORT/web/login" && break; sleep 2; done
if command -v xdg-open >/dev/null 2>&1; then
  if [ -f "$ROOT/start.html" ]; then
    xdg-open "$ROOT/start.html" >/dev/null 2>&1 &
  else
    xdg-open "http://localhost:$PORT/web/login?db=odoo_agent" >/dev/null 2>&1 &
  fi
fi
LAUNCHER
  chmod +x "$INSTALL_ROOT/start.sh"

  mkdir -p "$HOME/.local/share/applications" "$HOME/Desktop"
  cat > "$HOME/.local/share/applications/ai-odoo.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=AI Odoo
Comment=Start Odoo and the AI assistant
Exec=bash "$INSTALL_ROOT/start.sh"
Terminal=false
Categories=Office;
DESKTOP
  cp "$HOME/.local/share/applications/ai-odoo.desktop" "$HOME/Desktop/ai-odoo.desktop" 2>/dev/null || true
  chmod +x "$HOME/Desktop/ai-odoo.desktop" 2>/dev/null || true
}

start_odoo() {
  log "Starting Odoo on port $ODOO_PORT"
  nohup "$INSTALL_ROOT/venv/bin/python" "$ODOO_DIR/odoo-bin" \
    -d odoo_agent --db_host=127.0.0.1 --db_port "$DB_PORT" --db_user "$DB_USER" --db_password "$DB_PASSWORD" \
    --addons-path="$ODOO_DIR/addons" --http-port="$ODOO_PORT" \
    > "$INSTALL_ROOT/odoo.log" 2>&1 &
  echo $! > "$INSTALL_ROOT/odoo.pid"
}

main() {
  log "OdooTool installer ($INSTALL_ROOT)"
  run_wizard
  check_space
  install_prereqs
  configure_postgres
  install_odoo
  create_database
  create_api_key
  install_agentbridge
  install_plugin
  configure_agentbridge
  start_odoo
  # Wait until Odoo answers, so "Done" is only printed for a working stack.
  local odoo_up=0
  for i in $(seq 1 30); do
    curl -sf -o /dev/null "http://localhost:$ODOO_PORT/web/login" && { odoo_up=1; break; }
    sleep 2
  done
  [ "$odoo_up" -eq 1 ] \
    || warn "Odoo did not answer on port $ODOO_PORT after 60s; check $INSTALL_ROOT/odoo.log."
  open_firewall
  create_start_page
  create_launcher
  echo
  log "Done."
  echo "  HOW TO START:"
  echo "    Double-click the 'AI Odoo' icon (Applications menu or Desktop)."
  echo "    A page opens in the browser: it says what is running here, with the account and the link."
  echo "      'Open Odoo'  the ERP, where the data is. Log in with the account below."
  echo "    A black window also opens: that is the assistant. Type there, for example"
  echo "    'list the customers', and leave it open while you work."
  echo "    The database and the admin user are already created: do not run the Odoo database manager."
  echo "    If it appears, the install did not complete: run install.sh again."
  echo "    Odoo 20 user guide: https://www.odoo.com/documentation/20.0/applications.html"
  echo
  echo "  Odoo (the ERP, in the browser):  http://localhost:$ODOO_PORT"
  if [ -n "$ADMIN_LOGIN" ]; then
    echo "  Login:    $ADMIN_LOGIN"
    if [ "$ADMIN_PASS_SET" = "1" ]; then
      echo "  Password: $ADMIN_PASS"
    else
      echo "  Password: unchanged since the first installation (set ADMIN_PASS to change it)"
    fi
  else
    echo "  Login:    not configured by this run - read the problems listed above"
  fi
  echo "  Assistant (talk to it here):  http://localhost:5290/OfficeManager"
  echo "  Install root:   $INSTALL_ROOT"
  echo "  AgentBridge:    $AB_DIR"
  echo
  echo "  Manual start, if you ever need it:"
  echo "    Odoo:      $INSTALL_ROOT/venv/bin/python $INSTALL_ROOT/odoo/odoo-bin -d odoo_agent --db_port $DB_PORT"
  echo "    Assistant: $INSTALL_ROOT/agentbridge/agent"

  # The local start page, not the vendor's documentation site: a page about the machine in front of
  # the user is what a reader who does not know what a local web application is needs first. The
  # vendor's guide stays printed above as a link for later.
  if [ "$odoo_up" -eq 1 ] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$INSTALL_ROOT/start.html" >/dev/null 2>&1 &
  fi
}

main "$@"
