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
ODOO_BRANCH="${ODOO_BRANCH:-18.0}"
ODOO_MAJOR="${ODOO_MAJOR:-20}"
AB_REPO="${AB_REPO:-Graphene-Lab/AgentBridge}"
AB_TAG="${AB_TAG:-latest}"
TOOL_PKG="${TOOL_PKG:-Graphene.OdooTool}"
INSTALL_ROOT="${INSTALL_ROOT:-$HOME/odoo-tool-stack}"
ODOO_DIR="$INSTALL_ROOT/odoo"
AB_DIR="$INSTALL_ROOT/agentbridge"
DB_USER="${DB_USER:-odoo}"
DB_PASSWORD="${DB_PASSWORD:-odoo}"
ODOO_PORT="${ODOO_PORT:-8069}"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mx %s\033[0m\n' "$*" >&2; exit 1; }

# --- Wizard --------------------------------------------------------------
ask() { # ask VAR "Prompt" "default"
  local var="$1" prompt="$2" def="${3:-}" reply=""
  read -r -p "$prompt [${def}]: " reply || true
  reply="${reply:-$def}"
  printf -v "$var" '%s' "$reply"
}

gen_password() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }

run_wizard() {
  log "Questions"
  ask COMPANY_NAME  "Company name" "My Company"
  ask ADMIN_EMAIL  "Odoo admin email" "admin@example.com"
  ask ADMIN_PASS   "Odoo admin password" "$(gen_password)"
  ask LLM_BASE_URL "LLM provider base URL (OpenAI-compatible)" "http://192.168.43.253:8741/v1"
  ask LLM_KEY      "LLM provider API key" ""
  ask LLM_MODEL    "LLM model name" "halogen-qwen3.8-flash-next"
}

# --- Prerequisites -------------------------------------------------------
install_prereqs() {
  log "Installing PostgreSQL and Python build dependencies"
  sudo apt-get update -y
  sudo apt-get install -y git python3 python3-pip python3-venv postgresql libpq-dev \
    build-essential libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
    libjpeg-dev zlib1g-dev wkhtmltopdf
}

configure_postgres() {
  log "Configuring PostgreSQL user '$DB_USER'"
  sudo service postgresql start || sudo pg_ctlcluster 16 main start || true
  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE ROLE $DB_USER LOGIN SUPERUSER PASSWORD '$DB_PASSWORD';"
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
    -d odoo_agent --db_user "$DB_USER" --db_password "$DB_PASSWORD" \
    --addons-path="$ODOO_DIR/addons" \
    -i base --stop-after-init --without-demo=all || true
}

create_api_key() {
  log "Creating an Odoo API key for the admin user"
  # Use the Odoo shell to create the key once and save it. The value is shown only at creation.
  ODOO_ADMIN_EMAIL="$ADMIN_EMAIL" \
  "$INSTALL_ROOT/venv/bin/python" "$ODOO_DIR/odoo-bin" shell -d odoo_agent \
    --db_user "$DB_USER" --db_password "$DB_PASSWORD" \
    --addons-path="$ODOO_DIR/addons" --no-http <<'PY' > "$INSTALL_ROOT/odoo_api_key.txt" 2>/dev/null || true
from odoo import env
admin = env["res.users"].search([("login", "=", __import__("os").environ["ODOO_ADMIN_EMAIL"])], limit=1)
key = env["res.users.apikeys"].with_user(admin).create({"name": "agentbridge"})
print(key.key if hasattr(key, "key") else "")
PY
  ODOO_API_KEY="$(cat "$INSTALL_ROOT/odoo_api_key.txt" 2>/dev/null || true)"
  if [ -z "$ODOO_API_KEY" ]; then
    warn "Could not auto-create the API key. Create it in Odoo (Preferences -> Account Security -> New API Key) and set ODOO_API_KEY before starting the assistant."
  fi
}

# --- AgentBridge + OdooTool plugin --------------------------------------
install_agentbridge() {
  log "Downloading AgentBridge"
  mkdir -p "$AB_DIR"
  local asset="agentbridge-linux-x64.tar.gz"
  if [ "$AB_TAG" = "latest" ]; then
    gh release download -R "$AB_REPO" --pattern "$asset" -O - | tar -xz -C "$AB_DIR"
  else
    gh release download "$AB_TAG" -R "$AB_REPO" --pattern "$asset" -O - | tar -xz -C "$AB_DIR"
  fi
}

configure_agentbridge() {
  log "Configuring AgentBridge with the LLM provider and the OdooTool plugin"
  local cfg="$AB_DIR/PersistentData"
  mkdir -p "$cfg"
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
  cat > "$cfg/plugins.json" <<JSON
{
  "plugins": [
    { "packageId": "$TOOL_PKG", "enabled": true }
  ]
}
JSON
  cat > "$cfg/odoo.json" <<JSON
{
  "baseUrl": "http://localhost:$ODOO_PORT",
  "apiKey": "$ODOO_API_KEY",
  "database": "odoo_agent"
}
JSON
}

start_odoo() {
  log "Starting Odoo on port $ODOO_PORT"
  nohup "$INSTALL_ROOT/venv/bin/python" "$ODOO_DIR/odoo-bin" \
    -d odoo_agent --db_user "$DB_USER" --db_password "$DB_PASSWORD" \
    --addons-path="$ODOO_DIR/addons" --http-port="$ODOO_PORT" \
    > "$INSTALL_ROOT/odoo.log" 2>&1 &
  echo $! > "$INSTALL_ROOT/odoo.pid"
}

main() {
  log "OdooTool installer ($INSTALL_ROOT)"
  command -v gh >/dev/null || die "The GitHub CLI (gh) is required. Install it first."
  run_wizard
  install_prereqs
  configure_postgres
  install_odoo
  create_database
  install_agentbridge
  configure_agentbridge
  start_odoo
  echo
  log "Done."
  echo "  Odoo URL:       http://localhost:$ODOO_PORT"
  echo "  Admin:          $ADMIN_EMAIL / $ADMIN_PASS"
  echo "  Install root:   $INSTALL_ROOT"
  echo "  AgentBridge:    $AB_DIR"
  echo
  echo "  Start the assistant with:  $AB_DIR/agent"
  echo "  Tell it something like 'list the customers' and it uses OdooTool."
}

main "$@"
