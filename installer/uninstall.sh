#!/usr/bin/env bash
#
# OdooTool - uninstaller (Linux native + WSL)
#
# Removes what install.sh created:
#   1. stops the ERP and the assistant if they run from this installation;
#   2. drops the Odoo database (every customer, product, order, invoice and stock move in it);
#   3. removes the firewall rule, the start page, the launcher and the desktop entries;
#   4. deletes the installation folder, keeping AgentBridge only when the user asks to keep it.
#
# INSTALLER CONTRACT - see INSTALLER-CONTRACT.md. Two confirmations guard the deletion: a yes/no
# question that says what disappears, then the phrase DESTROY ALL typed in capitals. The phrase is
# the only thing standing between a tired user and a company's ledger, and the deletion cannot be
# undone. PostgreSQL itself is left installed: it is a service other programs may share, and it is
# removed with the distribution's package manager like any other program.
#
# CROSS-PLATFORM PARITY - this file is the Linux half of ONE uninstaller. Every substantial change
# here must be made in installer/uninstall.ps1 (and installer/uninstall.bat) as well.
#
# Run:  bash uninstall.sh
#
set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-$HOME/odoo-tool-stack}"
ODOO_PORT="${ODOO_PORT:-8069}"
DB_NAME="odoo_agent"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }

# The folder is deleted recursively, so it is only accepted when it is recognisably an OdooTool
# installation: a mistyped INSTALL_ROOT must never wipe a home directory.
if [ ! -d "$INSTALL_ROOT" ]; then
  echo "Nothing to remove: no OdooTool installation was found in '$INSTALL_ROOT'."
  exit 0
fi
found=0
for m in odoo agentbridge venv start.sh start.html; do
  [ -e "$INSTALL_ROOT/$m" ] && found=1
done
if [ "$found" -eq 0 ]; then
  echo "Nothing to remove: '$INSTALL_ROOT' does not look like an OdooTool installation."
  exit 0
fi

# The launcher holds the real ports: reading them here means nobody is asked for a database
# password to delete a database.
DB_PORT="5432"
if [ -f "$INSTALL_ROOT/start.sh" ]; then
  p="$(sed -n 's/^PORT=\([0-9]*\).*/\1/p' "$INSTALL_ROOT/start.sh" | head -1)"
  [ -n "$p" ] && ODOO_PORT="$p"
  p="$(sed -n 's/^DBPORT=\([0-9]*\).*/\1/p' "$INSTALL_ROOT/start.sh" | head -1)"
  [ -n "$p" ] && DB_PORT="$p"
fi

log "What this removes"
echo "  Installation folder: $INSTALL_ROOT ($(du -sh "$INSTALL_ROOT" 2>/dev/null | cut -f1))"
echo "  Odoo database:       $DB_NAME on PostgreSQL port $DB_PORT"
echo "  Desktop entries:     ai-odoo.desktop in the applications menu and on the Desktop"
echo "  Firewall rule:       TCP $ODOO_PORT"
echo "  The assistant (AgentBridge) is asked about separately."
echo
echo "  PostgreSQL itself is NOT removed: it is a service other programs may use."
echo "  To remove it, use your distribution's package manager."

# Unattended runs pass the phrase in the environment instead of typing it. The name says what it
# does on purpose: nothing else in this script accepts a silent confirmation.
REMOVE_AGENTBRIDGE=0
if [ "${UNINSTALL_CONFIRM:-}" = "DESTROY ALL" ]; then
  [ "${UNINSTALL_REMOVE_AGENTBRIDGE:-0}" = "1" ] && REMOVE_AGENTBRIDGE=1
else
  read -r -p "Delete all of this? The data in the database cannot be recovered [y/N]: " answer || true
  case "${answer:-}" in
    y|Y|yes|YES) ;;
    *) echo "Nothing was changed."; exit 0 ;;
  esac
  read -r -p "Also delete AgentBridge, the assistant, its settings and the Odoo API key? [y/N]: " answer || true
  case "${answer:-}" in
    y|Y|yes|YES) REMOVE_AGENTBRIDGE=1 ;;
  esac

  echo
  printf '\033[1;33m  This cannot be undone. Every customer, product, order, invoice and stock move\033[0m\n'
  printf '\033[1;33m  in the database will be gone, and no backup is made here.\033[0m\n'
  read -r -p "  Type DESTROY ALL in capital letters to continue: " phrase || true
  # An exact, case-sensitive match: "destroy all" is not the same act as "DESTROY ALL".
  if [ "${phrase:-}" != "DESTROY ALL" ]; then
    echo "The phrase did not match. Nothing was changed."
    exit 0
  fi
fi

# --- Stop what this installation started --------------------------------
log "Stopping the ERP and the assistant"
stopped=0
for pat in "$INSTALL_ROOT/odoo/odoo-bin" "$INSTALL_ROOT/agentbridge/agent"; do
  if pkill -f -- "$pat" 2>/dev/null; then stopped=$((stopped + 1)); fi
done
if [ "$stopped" -eq 0 ]; then
  echo "  nothing was running from this installation"
else
  sleep 2
  echo "  stopped"
fi

# --- Drop the database --------------------------------------------------
log "Dropping the database '$DB_NAME'"
# The local socket with peer authentication is how install.sh reaches PostgreSQL: no superuser
# password is involved. -w keeps psql from opening a prompt nobody can answer.
if sudo -u postgres psql -w -p "$DB_PORT" -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE)" </dev/null 2>/dev/null; then
  echo "  database dropped"
elif sudo -u postgres psql -w -p "$DB_PORT" -tAc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME'" </dev/null >/dev/null 2>&1 &&
     sudo -u postgres psql -w -p "$DB_PORT" -c "DROP DATABASE IF EXISTS $DB_NAME" </dev/null 2>/dev/null; then
  # PostgreSQL older than 13 has no WITH (FORCE); the backends are closed first instead.
  echo "  database dropped"
else
  warn "the database could not be dropped; remove it with 'sudo -u postgres psql -c \"DROP DATABASE $DB_NAME\"'"
fi

# --- Firewall rule and desktop entries ---------------------------------
log "Removing the firewall rule and the desktop entries"
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow "${ODOO_PORT}/tcp" >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --remove-port="${ODOO_PORT}/tcp" --permanent >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi
rm -f "$HOME/.local/share/applications/ai-odoo.desktop" "$HOME/Desktop/ai-odoo.desktop" 2>/dev/null || true

# --- Files --------------------------------------------------------------
log "Deleting the files"
if [ "$REMOVE_AGENTBRIDGE" -eq 1 ]; then
  rm -rf "$INSTALL_ROOT"
  # AgentBridge's own user data lives outside the installation folder.
  rm -rf "$HOME/.local/share/agent" "$HOME/.config/agent" 2>/dev/null || true
  echo "  removed $INSTALL_ROOT (including AgentBridge)"
else
  # AgentBridge can host other tools and holds its own settings, so it survives when the user
  # asked to keep it. Everything else in the folder belongs to this Odoo stack.
  find "$INSTALL_ROOT" -mindepth 1 -maxdepth 1 ! -name agentbridge -exec rm -rf {} + 2>/dev/null || true
  echo "  removed everything in $INSTALL_ROOT except agentbridge/"
  echo "  AgentBridge is still installed; start it with $INSTALL_ROOT/agentbridge/agent"
fi

echo
log "Finished"
echo "  Odoo, its database and its desktop entries are gone from this machine."
echo "  PostgreSQL was left in place. The 'odoo' database role may still exist; it is harmless"
echo "  and is reused by a future installation."
