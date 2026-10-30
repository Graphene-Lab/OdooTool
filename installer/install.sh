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
#   6. Starts Odoo and opens the AgentBridge assistant.
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
  ADMIN_PASS="${ADMIN_PASS:-$(gen_password)}"
  ask LLM_BASE_URL "LLM provider base URL (OpenAI-compatible)" "http://192.168.43.253:8741/v1"
  ask LLM_KEY      "LLM provider API key" ""
  ask LLM_MODEL    "LLM model name" "halogen-qwen3.8-flash-next"
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
  # Reuse the API key from a previous install instead of creating a new one.
  if [ -f "$AB_DIR/PersistentData/odoo.json" ]; then
    local existing
    existing="$(sed -n 's/.*"apiKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$AB_DIR/PersistentData/odoo.json" 2>/dev/null | head -1)"
    if [ -n "$existing" ]; then
      ODOO_API_KEY="$existing"
      log "Reusing the existing Odoo API key"
      return 0
    fi
  fi
  log "Creating an Odoo API key for the admin user"
  # Use the Odoo shell to create the key once and save it. The value is shown only at creation.
  ODOO_ADMIN_EMAIL="$ADMIN_EMAIL" ODOO_ADMIN_PASS="$ADMIN_PASS" \
  "$INSTALL_ROOT/venv/bin/python" "$ODOO_DIR/odoo-bin" shell -d odoo_agent \
    --db_host=127.0.0.1 --db_port "$DB_PORT" --db_user "$DB_USER" --db_password "$DB_PASSWORD" \
    --addons-path="$ODOO_DIR/addons" --no-http <<'PY' > "$INSTALL_ROOT/odoo_api_key.txt" 2>/dev/null || true
import os
admin = env["res.users"].browse(2)
# Set the admin credentials only on the first install; on a re-run keep the existing ones.
if admin.login == 'admin':
    email = os.environ["ODOO_ADMIN_EMAIL"]
    admin.write({"login": email, "email": email, "password": os.environ["ODOO_ADMIN_PASS"]})
else:
    found = env["res.users"].search([("login", "=", os.environ["ODOO_ADMIN_EMAIL"])], limit=1)
    if found:
        admin = found
key = env["res.users.apikeys"].with_user(admin)._generate("rpc", "agentbridge", None)
env.cr.commit()
print(key or "")
PY
  ODOO_API_KEY="$(cat "$INSTALL_ROOT/odoo_api_key.txt" 2>/dev/null || true)"
  if [ -z "$ODOO_API_KEY" ]; then
    warn "Could not auto-create the API key. Create it in Odoo (Preferences -> Account Security -> New API Key) and set ODOO_API_KEY before starting the assistant."
  fi
}

# --- AgentBridge + OdooTool plugin --------------------------------------
install_agentbridge() {
  if [ -x "$AB_DIR/agent" ]; then
    log "AgentBridge already installed; skipping download"
    return 0
  fi
  log "Downloading AgentBridge"
  mkdir -p "$AB_DIR"
  local asset="agentbridge-linux-x64.tar.gz"
  local url
  if [ "$AB_TAG" = "latest" ]; then
    url="https://github.com/$AB_REPO/releases/latest/download/$asset"
  else
    url="https://github.com/$AB_REPO/releases/download/$AB_TAG/$asset"
  fi
  # Direct download from the public release; no gh auth needed. The archive is ~1 GB,
  # so retry and resume a partial transfer instead of failing on a network blip.
  curl -fL --retry 5 --retry-delay 5 -C - "$url" -o "$AB_DIR/$asset"
  if ! tar -tzf "$AB_DIR/$asset" >/dev/null 2>&1; then
    warn "AgentBridge archive is corrupt; downloading again from scratch"
    rm -f "$AB_DIR/$asset"
    curl -fL --retry 5 --retry-delay 5 "$url" -o "$AB_DIR/$asset"
    tar -tzf "$AB_DIR/$asset" >/dev/null 2>&1 || die "AgentBridge archive could not be verified (download corrupt)"
  fi
  tar -xzf "$AB_DIR/$asset" -C "$AB_DIR" || die "AgentBridge extraction failed"
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

create_launcher() {
  log "Creating the one-click launcher"
  # Header: written now, storing the real values as safe bash literals with printf %q, so a path
  # or a password containing $ ` " | \ or spaces cannot corrupt or inject anything in the file.
  cat > "$INSTALL_ROOT/start.sh" <<EOF
#!/bin/bash
ROOT=$(printf '%q' "$INSTALL_ROOT")
PORT=$ODOO_PORT
DBPORT=$DB_PORT
DBUSER=$(printf '%q' "$DB_USER")
DBPASS=$(printf '%q' "$DB_PASSWORD")
EOF
  # Body: kept literal; it only uses the variables defined just above.
  cat >> "$INSTALL_ROOT/start.sh" <<'LAUNCHER'
if ! curl -sf -o /dev/null "http://localhost:$PORT"; then
  setsid "$ROOT/venv/bin/python" "$ROOT/odoo/odoo-bin" -d odoo_agent --db_host=127.0.0.1 --db_port "$DBPORT" \
    --db_user "$DBUSER" --db_password "$DBPASS" --addons-path="$ROOT/odoo/addons" \
    --http-port "$PORT" --http-interface=0.0.0.0 > "$ROOT/odoo.log" 2>&1 < /dev/null &
  for i in $(seq 1 40); do curl -sf -o /dev/null "http://localhost:$PORT" && break; sleep 2; done
fi
xdg-open "http://localhost:$PORT" >/dev/null 2>&1 &
if [ -x "$ROOT/agentbridge/agent" ]; then
  x-terminal-emulator -e "$ROOT/agentbridge/agent" 2>/dev/null || "$ROOT/agentbridge/agent" &
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
  for i in $(seq 1 30); do curl -sf -o /dev/null "http://localhost:$ODOO_PORT/web/login" && break; sleep 2; done
  curl -sf -o /dev/null "http://localhost:$ODOO_PORT/web/login" \
    || warn "Odoo did not answer on port $ODOO_PORT after 60s; check $INSTALL_ROOT/odoo.log."
  open_firewall
  create_launcher
  echo
  log "Done."
  echo "  HOW TO START:"
  echo "    Double-click the 'AI Odoo' icon (Applications menu or Desktop)."
  echo "    It starts Odoo, opens it in the browser and launches the assistant."
  echo "    Then type a request such as 'list the customers'."
  echo
  echo "  Odoo URL:       http://localhost:$ODOO_PORT"
  echo "  Odoo login:     $ADMIN_EMAIL / $ADMIN_PASS   (local to this PC - no Odoo account needed)"
  echo "  Install root:   $INSTALL_ROOT"
  echo "  AgentBridge:    $AB_DIR"
  echo
  echo "  Manual start, if you ever need it:"
  echo "    Odoo:      $INSTALL_ROOT/venv/bin/python $INSTALL_ROOT/odoo/odoo-bin -d odoo_agent --db_port $DB_PORT"
  echo "    Assistant: $INSTALL_ROOT/agentbridge/agent"
}

main "$@"
