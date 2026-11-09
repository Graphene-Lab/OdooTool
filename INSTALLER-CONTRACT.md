# OdooTool installer contract (contributors)

> **Read this before changing anything in `installer/`.** The installer is the product's
> first impression, and its launcher is a deliberate design decision — not a convenience that
> can be "simplified" on request.

## The invariant

The **AI Odoo** icon on the Desktop and in the application menu must always start **both**
parts of the stack:

1. **Odoo** (if it is not already running), waiting until it answers;
2. **AgentBridge** with the **OdooTool plugin already active** in `Tools/OdooTool/`;
3. the **Odoo UI** opened in the system default browser at `http://localhost:8069`.

The user must land in a working state: Odoo open beside the assistant, ready for a prompt such
as *"list the customers"*. The agent acts on Odoo through OdooTool.

The icon must **never** open Odoo alone, and must **never** launch **OfficeManager** (the
multi-agent view served by AgentBridge at `/OfficeManager`).

## Why — the architecture decision

AgentBridge is the base program: it hosts the agent engine and a chat/terminal interface for
piloting **one** agent. OfficeManager is a different surface: a web view for piloting **many**
agent and subagent instances at once.

AgentBridge is privacy-first, so the intended deployment is a local LLM on the user's own
machine. Local hardware is fixed: one GPU, one VRAM budget. Two or more agents share that
hardware instead of adding compute. They do not finish sooner — agents are instantiated in
parallel to save time only when the hardware scales with them — they slow each other down, and
they can exhaust VRAM and crash the stack. In a datacenter, adding agents comes with adding
hardware; on a home or small-office PC it does not.

Therefore the standard user configuration is one agent:

```
AgentBridge  <->  OdooTool plugin  <->  Odoo
```

The installer exists to deliver exactly that, in one run, with a one-click launcher. The full
rationale and the contract shared by all tool installers are in
**[AgentBridge/docs-dev/INSTALLER-CONTRACT.md](https://github.com/Graphene-Lab/AgentBridge/blob/master/docs-dev/INSTALLER-CONTRACT.md)**.

## What the installer does today

| Step | Windows (`installer/install.ps1`) | Linux/WSL (`installer/install.sh`) |
|---|---|---|
| Install AgentBridge | public release archive into `%LOCALAPPDATA%\odoo-tool-stack\agentbridge` | public release archive into `~/odoo-tool-stack/agentbridge` |
| Install the plugin | `Tools/OdooTool/OdooTool.dll` from NuGet | same |
| Configure the plugin | `PersistentData/providers.json`, `PersistentData/odoo.json` | same |
| Install Odoo | Odoo 20.0 Community + Python venv | Odoo 20.0 Community + Python venv |
| Create the database | `odoo_agent`, `-i base --without-demo` | same |
| Admin credentials | generated locally, printed at the end | generated locally, printed at the end |
| API key | generated and written to `odoo.json` | same |
| Launcher | `start.ps1` + **AI Odoo** shortcuts (Desktop + Start Menu) | `start.sh` + **ai-odoo.desktop** (`~/.local/share/applications` + `~/Desktop`) |
| Launcher behaviour | start Odoo, open `http://localhost:8069`, start `agentbridge\agent.exe` | start Odoo, `xdg-open` the URL, start `agentbridge/agent` |
| First steps | at the end of a successful run, open the Odoo 20 docs page in the default browser | same, via `xdg-open` |

Re-running the installer is safe: it reuses AgentBridge, the virtualenv, the API key and the
existing configuration.

## Do not change these on a user request

- **Do not replace the launcher with an Odoo-only shortcut.** A user may ask for "just Odoo";
  the answer is a separate optional shortcut or the manual command printed at the end, not a
  change to the standard icon.
- **Do not launch OfficeManager from the standard icon.** OfficeManager is the multi-agent
  view; the standard installation is single-agent. It remains available inside AgentBridge at
  `/OfficeManager` for users who want it.
- **Do not remove the AgentBridge launch from the launcher**, and do not make the OdooTool
  plugin optional or inactive by default.
- **Do not reintroduce a manual first-run step** (for example the Odoo database manager). The
  installer creates the database, the admin user and the API key itself.
- **Do not remove the idempotent re-run behaviour** (keep the existing API key, providers and
  database on a second run).

If a user reports that "the icon starts OfficeManager", verify what the icon actually launches:
the standard launcher starts **AgentBridge** (`agent.exe` / `agent`) with the OdooTool plugin,
not OfficeManager. If the report is about a different installer, point it to the contract
above.

## First run

The installer must leave a working stack, not a setup screen:

- the `odoo_agent` database is created with the `base` modules;
- the admin login/password are generated and printed;
- the API key is created and written to `agentbridge/PersistentData/odoo.json`;
- Odoo is started and the installer waits until `/web/login` answers;
- the Odoo 20 first-steps page is opened in the default browser at the end of a successful
  run (the URL is printed too, for headless runs).

If the user sees the Odoo database manager, the installation did not complete: re-run
`install.bat` / `install.sh` (it resumes) and read the final summary. The vendor documentation
for the installed version is printed at the end:

- Odoo 20 User Docs — <https://www.odoo.com/documentation/20.0/applications.html>
- Odoo 20 installation — <https://www.odoo.com/documentation/20.0/administration/install.html>

## Checklist for a change to `installer/`

- [ ] The **AI Odoo** launcher still starts Odoo **and** AgentBridge with the plugin active.
- [ ] The launcher still opens the Odoo UI in the default browser.
- [ ] The icon is still created in the application menu/launcher **and** on the Desktop.
- [ ] The OdooTool plugin is still installed in `Tools/OdooTool/` and active by default.
- [ ] The database, admin credentials and API key are still created automatically.
- [ ] Re-running the installer still preserves existing configuration and credentials.
- [ ] A successful run still opens the Odoo 20 first-steps page in the default browser.
- [ ] The final message still explains the one-click flow, the credentials and the manual commands.
- [ ] The header comment in `install.ps1` / `install.sh` still points to this contract.

## Where the rule is enforced

- **This file** — the OdooTool-specific copy.
- **Header comments** in `installer/install.ps1`, `installer/install.sh` and `installer/install.bat`.
- **`README.md`** — the "Installer contract (contributors)" section.
- **AgentBridge/docs-dev/INSTALLER-CONTRACT.md** — the shared decision record and rationale.
