# OdooTool

[![NuGet](https://img.shields.io/nuget/v/Graphene.OdooTool?logo=nuget&label=NuGet)](https://www.nuget.org/packages/Graphene.OdooTool)
[![License](https://img.shields.io/github/license/Graphene-Lab/OdooTool?label=license)](https://github.com/Graphene-Lab/OdooTool/blob/main/LICENSE.md)
[![Download](https://img.shields.io/github/v/release/Graphene-Lab/OdooTool?label=download&logo=github)](https://github.com/Graphene-Lab/OdooTool/releases/latest)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux-blue)](#one-command-installer-whole-local-stack)
[![Install on Linux](https://img.shields.io/badge/install-Linux-2ea44f?logo=linux&logoColor=white)](https://github.com/Graphene-Lab/OdooTool/releases/latest/download/install.sh)
[![Install on Windows](https://img.shields.io/badge/install-Windows-0078d7?logo=windows&logoColor=white)](https://github.com/Graphene-Lab/OdooTool/releases/latest/download/install.bat)

OdooTool is an agent tool for **AIOrchestrator**. It lets an LLM control an Odoo ERP through the
Odoo JSON-2 external API. The agent can discover models and fields, search records, create, update
and delete records, call model methods (like confirming a sale order), and read grouped aggregates.
All calls go to the Odoo JSON-2 endpoint protected by a Bearer API key.

OdooTool is a plugin tool. It is published in two channels:

* a GitHub Release zip, which the host installs into `Tools/OdooTool/`;
* the NuGet package `Graphene.OdooTool`.

The class derives from `BaseAgentTool`. Each public method becomes a tool method for the LLM
(with a snake_case name).

## Where it fits

OdooTool is one of three small programs that work together to let an AI agent run a company:

| Part | Repo | Job |
|---|---|---|
| **Odoo** | [odoo/odoo](https://github.com/odoo/odoo) | The ERP: stores the data, runs the real operations, enforces the rules and permissions. |
| **AgentBridge** | [Graphene-Lab/AgentBridge](https://github.com/Graphene-Lab/AgentBridge) | The chat front-end and the agent runtime (AIOrchestrator). You talk to the agent here. |
| **OdooTool** | this repository | The bridge: turns the agent's decisions into secure calls to the Odoo API. |

```text
You -> AgentBridge -> AIOrchestrator (the agent) -> OdooTool -> HTTPS + Bearer key -> Odoo JSON-2 API
```

OdooTool runs inside AgentBridge as a plugin (dropped into `Tools/OdooTool/`). The agent reads
the Odoo schema, picks a method, and OdooTool calls the Odoo JSON-2 API over HTTPS with a Bearer
token. The Odoo server checks the access rights of the API key owner and does the real work.

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

For automated use, create a dedicated bot user with minimum required permissions.

## Install (hosts)

Copy the release zip into `Tools/OdooTool/`. The host finds it at startup, or adds it while the
app is running. The zip contains only the plugin files. The AIOrchestrator libraries come from
the host.

## One-command installer (whole local stack)

If you want the whole ecosystem ready on your own machine — **AgentBridge + OdooTool + Odoo** —
use the installer in the `installer/` folder. It sets everything up in one run and asks a few
simple questions (company name, admin email and password, and the AI provider to use). It
installs PostgreSQL and Odoo, creates the database, downloads AgentBridge, and turns the OdooTool
plugin on by default, so the assistant can drive Odoo right away.

On Windows, double-click `install.bat` (or run `install.ps1` from PowerShell):

```bat
installer\install.bat
```

On Linux or WSL, run:

```bash
bash installer/install.sh
```

When it finishes, open the assistant and tell it something like "list the customers". The
assistant uses OdooTool to read and change the data in Odoo. You can watch the result in the Odoo
window at `http://localhost:8069`.

The installer needs the GitHub CLI (`gh`) signed in, because it downloads the AgentBridge release.
You can change what it installs with environment variables (for example `ODOO_BRANCH`, `AB_TAG`,
`INSTALL_ROOT`). iOS is not supported: Odoo and AgentBridge do not run on iOS.

## License

See [LICENSE.md](LICENSE.md).
