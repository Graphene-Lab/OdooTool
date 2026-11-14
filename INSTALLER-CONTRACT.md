# OdooTool installer contract (contributors)

> **Read this before changing anything in `installer/`.** The installer is the product's
> first impression, and its launcher is a deliberate design decision — not a convenience that
> can be "simplified" on request.

## The invariant

The **AI Odoo** icon on the Desktop and in the application menu must always start the whole
stack and leave the user in front of the ERP:

1. **Odoo** (if it is not already running), waiting until it answers;
2. **AgentBridge** with the **OdooTool plugin already active** in `Tools/OdooTool/`, in a
   **visible terminal window** — the TUI is the product, and a process started without a
   console shows nothing;
3. the **Odoo page** at `http://localhost:8069` in the system default browser, so the user sees
   the data the assistant works on.

The user must land in a working state: Odoo open in the browser, the assistant's terminal open
beside it, ready for a prompt such as *"list the customers"*. The agent acts on Odoo through
OdooTool, and every result is visible in the page that was just opened.

The assistant's browser chat at `http://localhost:5290/OfficeManager` is a **second entrance**,
available but not opened automatically. It used to be what the launcher opened; that hid the
ERP behind a page the user had not asked for, and it made the icon look like it started the
wrong program (issue #7, reversed on 2026-11-14).

The icon must **never** open Odoo alone without the assistant, and must **never** leave the
assistant as an invisible background process.

## Why — the architecture decision

AgentBridge is the base program: it hosts the agent engine and the chat interface for
piloting **one** agent. The browser chat at `/OfficeManager` is served by AgentBridge; the name
is historical, because the same page also carries the optional multi-agent view. In the standard
installation it drives one agent, and it is reached on purpose rather than on start-up: the
launcher opens the ERP, and the terminal is where the prompt is typed.

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
| Launcher behaviour | start Odoo, start `agentbridge\agent.exe` in a visible console (`conhost`) if 5290 is free, then open `http://localhost:8069` | start Odoo, start `agentbridge/agent` detached if needed, then `xdg-open` `http://localhost:8069` |
| First steps | at the end of a successful run, open the Odoo 20 docs page in the default browser | same, via `xdg-open` |

Re-running the installer is safe: it reuses AgentBridge, the virtualenv, the API key and the
existing configuration.

## Do not change these on a user request

- **Do not replace the launcher with an Odoo-only shortcut.** A user may ask for "just Odoo";
  the answer is a separate optional shortcut or the manual command printed at the end, not a
  change to the standard icon.
- **Do not open the assistant's browser chat on start-up.** `http://localhost:5290/OfficeManager`
  is a second entrance: opening it instead of the ERP is the regression that made the icon look
  like it started the wrong program (reversed 2026-11-14). The browser opens `http://localhost:8069`.
- **Do not start AgentBridge as an invisible background process.** The TUI is the product: it
  gets a real console window (`conhost`), so the user sees the prompt and the tool calls.
- **Do not remove the AgentBridge launch from the launcher**, and do not make the OdooTool
  plugin optional or inactive by default.
- **Do not configure a multi-agent workload by default.** The standard installation is
  single-agent; the multi-agent view at `/OfficeManager` remains available but is not the
  default configuration, and it is not for a local model: one machine has one GPU and one VRAM
  budget, so parallel agents share the same model, slow each other down instead of finishing
  sooner, and can exhaust the memory and take the stack down. That is also why the launcher
  never opens the office by itself.
- **Do not reintroduce a manual first-run step** (for example the Odoo database manager). The
  installer creates the database, the admin user and the API key itself.
- **Do not remove the idempotent re-run behaviour** (keep the existing API key, providers and
  database on a second run).
- **Do not start a second assistant.** If port 5290 already has a listener, the launcher reuses
  it instead of starting another copy.

If a user reports that the icon opens only Odoo, that the assistant is missing, or that a page
other than Odoo appears, that is a regression: check that the launcher starts `agent.exe` /
`agent` in a visible console and opens the Odoo URL. If the report is about a different
installer, point it to the contract above.

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
- [ ] The launcher opens the **Odoo page** (`http://localhost:8069`) in the default browser and
      starts AgentBridge in a **visible terminal**, not as an invisible process.
- [ ] The launcher does **not** open `http://localhost:5290/OfficeManager` on start-up.
- [ ] The final message still prints the Odoo URL and login, so the ERP UI can be opened to
      watch the result.
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
