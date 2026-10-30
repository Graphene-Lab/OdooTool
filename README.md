# OdooTool — AI automation for Odoo Community (the free, self-hosted ERP)

[![NuGet](https://img.shields.io/nuget/v/Graphene.OdooTool?logo=nuget&label=NuGet)](https://www.nuget.org/packages/Graphene.OdooTool)
[![License](https://img.shields.io/github/license/Graphene-Lab/OdooTool?label=license)](https://github.com/Graphene-Lab/OdooTool/blob/main/LICENSE.md)
[![Download](https://img.shields.io/github/v/release/Graphene-Lab/OdooTool?label=download&logo=github)](https://github.com/Graphene-Lab/OdooTool/releases/latest)
[![Stars](https://img.shields.io/github/stars/Graphene-Lab/OdooTool?label=stars&logo=github)](https://github.com/Graphene-Lab/OdooTool/stargazers)
[![Odoo Community](https://img.shields.io/badge/Odoo-Community%2020%20(free)-875A7B)](https://github.com/odoo/odoo)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20WSL-blue)](#install-in-one-command)
[![Install on Linux](https://img.shields.io/badge/install-Linux-2ea44f?logo=linux&logoColor=white)](https://github.com/Graphene-Lab/OdooTool/releases/latest/download/install.sh)
[![Install on Windows](https://img.shields.io/badge/install-Windows-0078d7?logo=windows&logoColor=white)](https://github.com/Graphene-Lab/OdooTool/releases/latest/download/install.bat)

**OdooTool is an open-source AI agent for Odoo Community** — the free, self-hosted edition of the
Odoo ERP. It lets a large language model (ChatGPT, Claude, Gemini, Copilot, or a local model such as
Ollama, LM Studio or vLLM) **read and write real Odoo business data** through the Odoo **JSON-2
external API**: customers, products, sales orders, invoices, stock, projects. Every call runs as the
configured Odoo user, so Odoo's own access rights, record rules and field-level permissions still
apply.

No Odoo Enterprise licence, no **odoo.com** subscription, no paid AI add-on: **one script installs
Odoo Community, PostgreSQL and the AI assistant**, and OdooTool is enabled by default.

Ask in plain language — *"create a quotation for Acme for 10 units of the blue widget and confirm
it"*, *"which customers have overdue invoices?"* — and the agent performs the operations in the
running Odoo instance at `http://localhost:8069`.

## Start here: what people look for

| What you are searching for | How OdooTool answers it |
|---|---|
| **AI automation for Odoo Community (free edition)** | An agent that drives Odoo through its public JSON-2 API, with no Enterprise module and no Odoo.com account. [Install in one command →](#install-in-one-command) |
| **An AI agent / AI assistant for Odoo ERP** | 13 typed tool methods: model and field discovery, search, read, create, update, delete, `call_method`, grouped aggregates, menus, connection check. |
| **Odoo + ChatGPT, Claude, Gemini, Copilot or a local LLM** | OdooTool plugs into [AgentBridge](https://github.com/Graphene-Lab/AgentBridge), which speaks to any OpenAI-compatible endpoint — cloud APIs or a model running on your own machine. |
| **An alternative to an "Odoo MCP server"** | Same idea, less moving parts: instead of generating JSON-RPC scripts at every step, the LLM calls typed C# methods. No Node.js, no MCP gateway. |
| **Install Odoo and the AI stack in one run** | `install.bat` / `install.sh` installs PostgreSQL, Odoo 20 Community, AgentBridge and this plugin, creates the database and starts everything. [Windows](#windows-1011) · [Linux / WSL](#linux--wsl) |
| **Self-hosted, private ERP automation** | Everything runs locally. The only outbound traffic is to the LLM endpoint you configure, which may also be on your own hardware. |
| **A free Odoo integration** | AGPL-3.0, no account, no ticket system, no paid tier — and [free support, 24/7](#free-support-247). |

## Install in one command

**This is the easy way.** You do not need .NET, Git, Docker, a Python environment or any manual
configuration: one script installs and wires the whole stack — **PostgreSQL + Odoo 20 Community +
AgentBridge + OdooTool** — and only asks for the few things nobody can guess for you (company name,
admin email and which AI provider to use). It never asks for a PostgreSQL password: when PostgreSQL
is missing the installer creates it and assigns the superuser password itself.
Press Enter to accept every suggestion.

### Windows (10/11)

The badge below downloads `install.bat` from the latest release; double-click it, or run it from a
terminal:

[![Install on Windows](https://img.shields.io/badge/install-Windows-0078d7?logo=windows&logoColor=white)](https://github.com/Graphene-Lab/OdooTool/releases/latest/download/install.bat)

```powershell
curl.exe -L -o install.bat https://raw.githubusercontent.com/Graphene-Lab/OdooTool/main/installer/install.bat
.\install.bat
```

`install.bat` also works on its own: if `install.ps1` is not next to it, it downloads it from
`raw.githubusercontent.com/Graphene-Lab/OdooTool/main/installer/install.ps1` by itself. To run the
PowerShell installer directly, download it and start it with
`powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1`.

### Linux / WSL

[![Install on Linux](https://img.shields.io/badge/install-Linux-2ea44f?logo=linux&logoColor=white)](https://github.com/Graphene-Lab/OdooTool/releases/latest/download/install.sh)

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/Graphene-Lab/OdooTool/main/installer/install.sh
bash install.sh
```

From a clone of this repository:

```bash
git clone https://github.com/Graphene-Lab/OdooTool
bash OdooTool/installer/install.sh
```

### What happens next

The installer installs PostgreSQL and the Python packages Odoo needs, installs Odoo 20 Community,
creates the database with the base modules, downloads the public AgentBridge release, installs and
enables the OdooTool plugin, writes the Odoo address and an API key into the plugin configuration,
and starts Odoo and the assistant.

When it finishes, open the assistant and ask something like *"list the customers"*. The assistant
uses OdooTool to read — and, when you ask for it, change — the data in Odoo. You can watch the
result in the Odoo window at `http://localhost:8069`. The installer prints the generated admin login
and password at the end: they are created locally, not registered anywhere.

The installer downloads the public AgentBridge release with `curl` (built into Windows 10+), so no
GitHub sign-in is needed. Re-running it is safe: it continues where it stopped and reuses what is
already there.

For a fully unattended run, set these environment variables before starting:
`COMPANY_NAME`, `ADMIN_EMAIL`, `ADMIN_PASS`, `LLM_BASE_URL`, `LLM_KEY`, `LLM_MODEL`,
`DB_USER`, `DB_PASSWORD`, `DB_PORT`, `PG_SUPERUSER`, `PG_SUPERPASS` (Windows), `ODOO_REPO`,
`ODOO_BRANCH`, `ODOO_MAJOR` (Linux), `ODOO_PORT`, `AB_REPO`, `AB_TAG`, `TOOL_PKG`, `INSTALL_ROOT`,
and `ODOO_API_KEY` (Linux, to reuse an existing key).
iOS is not supported: Odoo and AgentBridge do not run on iOS.

## What you need

**Nothing at all if you use the installer above** — it installs every part for you. Doing it by
hand takes three steps:

1. **Odoo** — the ERP that stores the data and enforces the rules. Install the free
   [Odoo Community](https://github.com/odoo/odoo) (the installer uses 20.0) or an existing
   Enterprise instance; OdooTool only needs an Odoo release that exposes the JSON-2 external API.
2. **AgentBridge** (or AIOffice) — the host that runs the agent and the chat front-end. OdooTool is
   a plugin and cannot run on its own.
3. **OdooTool** — this plugin. Install the NuGet package `Graphene.OdooTool`, or unpack the release
   zip into the host's `Tools/OdooTool/` folder.

## Where it fits

OdooTool is one of three small programs that work together to let an AI agent run a company:

| Part | Repo | Job |
|---|---|---|
| **Odoo Community** | [odoo/odoo](https://github.com/odoo/odoo) | The ERP: stores the data, runs the real operations, enforces the rules and permissions. |
| **AgentBridge** | [Graphene-Lab/AgentBridge](https://github.com/Graphene-Lab/AgentBridge) | The chat front-end and the agent runtime (AIOrchestrator). You talk to the agent here. |
| **OdooTool** | this repository | The bridge: turns the agent's decisions into secure calls to the Odoo API. |

```text
You -> AgentBridge -> AIOrchestrator (the agent) -> OdooTool -> HTTPS + bearer token -> Odoo JSON-2 API
```

OdooTool runs inside AgentBridge as a plugin (dropped into `Tools/OdooTool/`). The agent reads the
Odoo schema, picks a method, and OdooTool calls the Odoo JSON-2 API over HTTPS with an API token.
The Odoo server checks the access rights of the API key owner and does the real work.

The same plugin loads unchanged into any host built on the AIOrchestrator libraries, such as the
AIOffice desktop application. The CAD counterpart of this tool is
[FreeCADTool](https://github.com/Graphene-Lab/FreeCADTool), installed the same way.

## Methods

| Method | What it does |
|---|---|
| `get_models(filter?)` | Lists every model the user can access. **Call this first.** |
| `get_fields(model)` | Lists the fields on a model: name, label, type, required. |
| `search(model, domain, fields?, limit?, offset?, order?)` | Searches records with a domain filter. |
| `read(model, ids, fields?)` | Reads specific records by ID. |
| `create_record(model, values)` | Creates a new record. |
| `update_record(model, ids, values)` | Updates existing records. |
| `delete_record(model, ids)` | Deletes records permanently. |
| `call_method(model, action, ids?, params?)` | Calls any model method (e.g. `action_confirm`). |
| `read_group(model, domain, group_by, fields)` | Groups records and computes aggregates. |
| `get_menus(filter?)` | Lists the Odoo menus the user can access. |
| `get_menu_details(menu_ids)` | Gets detailed info about specific menus. |
| `get_context()` | Returns the current user session context. |
| `check_connection()` | Verifies the connection to the Odoo server. |

Every call runs as the configured Odoo user. The Odoo access rights, record rules, and field
accesses still apply. OdooTool does not write to the database directly.

## Configuration

OdooTool reads the connection settings from the host, not from the agent. It uses these sources,
in order:

1. Environment variables: `ODOO_BASE_URL`, `ODOO_API_KEY`, `ODOO_DATABASE`.
2. The file `PersistentData/odoo.json` in the host base directory:

```json
{
  "baseUrl": "http://localhost:8069",
  "apiKey": "your-odoo-api-key",
  "database": "mycompany"
}
```

If no setting is found, every method returns an `Error:` message that says what to configure.

### How to get an API key

1. Log in to your Odoo instance.
2. Click the user icon (upper right) -> **My Preferences**.
3. Open the **Account Security** tab.
4. Click **New API Key** (or "Add API Key").
5. Give it a name (e.g. "AgentBridge") and set an expiration.
6. Copy the key immediately — it is shown only once.

For automated use, create a dedicated bot user with minimum required permissions. On Odoo
Community this is all the setup there is: no connector app, no licence key.

## Install as a plugin (existing hosts)

Copy the release zip into `Tools/OdooTool/`. The host finds it at startup, or adds it while the app
is running. The zip contains only the plugin files. The AIOrchestrator libraries come from the host.
NuGet users can reference `Graphene.OdooTool` instead. OdooTool is published in two channels: the
GitHub release zip the host installs into `Tools/OdooTool/`, and the NuGet package
`Graphene.OdooTool`. The class derives from `BaseAgentTool`; each public method becomes a tool
method for the LLM with a snake_case name.

## FAQ

**Does OdooTool work with Odoo Community (the free edition)?**
Yes — Community is the target. Enterprise instances work too, but nothing here requires an
Enterprise module, an Odoo.com subscription, or a paid third-party connector.

**Is it really free?**
Yes. The code is AGPL-3.0, the installer is free, and support is free (see below). You only pay
for the LLM endpoint you choose — and that can be a model running on your own machine.

**Which AI providers can it use?**
Any OpenAI-compatible endpoint: OpenAI, Azure OpenAI, OpenRouter, Groq, Together, a self-hosted
gateway, or a local server such as Ollama, LM Studio or vLLM. The plugin itself needs no API key:
the host holds the provider configuration.

**Which Odoo versions?**
The installer installs Odoo 20.0 Community. In general, any Odoo release that exposes the JSON-2
external API (`/json/2/...`) works, and `check_connection()` reports the server version.

**Does it write to the database directly?**
No. Every operation is an HTTPS call to the Odoo JSON-2 API, executed as the configured user, so
Odoo's permissions, record rules and field accesses decide what is allowed.

**Can it break my data?**
`delete_record` really deletes. Use a dedicated bot user with the minimum permissions you need, and
keep Odoo backups — as with any ERP automation.

**Do I need to be a developer?**
No. Run one script and talk to the assistant in plain language.

**Which password does the installer ask for?**
None for PostgreSQL — and that is deliberate. The database superuser account (`postgres`) is a local
account on this PC, not an Odoo.com account, and when the installer installs PostgreSQL it also
assigns that password: **`odoo`** by default, printed in the final summary and overridable with
`PG_SUPERPASS`. Nothing has to be typed, remembered or looked up, and it is unrelated to the Odoo
admin password printed at the end.

If PostgreSQL was already installed on the PC (by you, or by an earlier run of this installer) with
a different superuser password, the installer works it out by itself: it tries the password it would
have assigned, then the values PostgreSQL installers ship with, and if none of them works it resets
the password through PostgreSQL's local `trust` escape hatch (stop the service, let connections from
`127.0.0.1` in without a password, run `ALTER USER postgres PASSWORD ...`, restore `pg_hba.conf` and
restart). That reset needs Administrator rights, so Windows may show its own consent prompt — never a
password prompt. A run without those rights still does not stop: the final summary says which step
was left undone, and re-running `install.bat` as Administrator completes it.

The `odoo` database role is created for you, and the installer repairs its password when the role
already exists with a different one. On Linux and WSL it uses `sudo -u postgres` instead, so no
password is involved there either: peer authentication over the local socket needs none, and every
`psql` call passes `--no-password` (`-w`) so the installer can never stop and wait for input.

At the end the installer prints a summary of the run. If anything did not work — a missing tool, a
package that failed to install, a database that was not created — the last thing on screen lists
what is still broken and what to do about it, instead of printing a bare "Done." over a stack that
never actually came up.

## Free support, 24/7

Support is free, any day and any hour: if the installer stops, if Odoo does not come up, or if the
assistant does something you did not expect, open an issue at
<https://github.com/Graphene-Lab/OdooTool/issues> and describe what happened (pasting the
installer's output is enough). There is no paid support tier, no account to create and no ticket to
open. The same applies to the CAD side of the ecosystem,
[FreeCADTool](https://github.com/Graphene-Lab/FreeCADTool/issues).

## License

See [LICENSE.md](LICENSE.md).