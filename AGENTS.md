# OdooTool — notes for coding agents

> Read this file first. This repo is one tool plugin of the AIOffice solution: it is compiled on
> its own and loaded by AgentBridge from `Tools/OdooTool/` at runtime.

## What this is

Control of an Odoo ERP over the JSON-2 external API: discover models and fields, search, create,
update, delete records, call model methods, read grouped aggregates.

## Read before you edit

| If you touch… | Read first |
|---|---|
| anything | [PLUGIN-GUARDRAILS](../AIOrchestrator/docs-dev/PLUGIN-GUARDRAILS.md) — the contract shared by the 12 plugins; the file lives in the sibling AIOrchestrator repo (private), reachable from the solution checkout |
| **anything in `installer/`** | [INSTALLER-CONTRACT.md](INSTALLER-CONTRACT.md) — prescriptive, not a suggestion |
| a tool method or its XML docs | [AGENT_TOOLS_GUIDE](../AIOrchestrator/API/AGENT_TOOLS_GUIDE.md) |
| the tool checklist | [CHECKLIST_COMPLIANCE.md](CHECKLIST_COMPLIANCE.md) |

## Non-negotiables

1. The class derives from `BaseAgentTool` and keeps `[ToolPurpose(ToolPurpose.BusinessData)]`.
2. Public methods and their XML docs **are** the agent's surface: no public method without docs,
   and a public method is never renamed (the model calls it by that name).
3. AnyCPU, no `RuntimeIdentifier`, `GenerateDocumentationFile` stays on.
4. The plugin folder never carries `AIOrchestrator.dll`; no state is written into `Tools/`.
5. **The launcher contract.** The desktop/menu icon starts Odoo, then AgentBridge with OdooTool
   already active in a visible console, then opens the ERP page. It must never open Odoo alone, and
   never the login page instead of the assistant's chat (issue #7 regression).
6. **This repo has no release zip, by design.** The installer extracts `OdooTool.dll` and
   `OdooTool.xml` from the NuGet package into `Tools/OdooTool`; `PluginUpdater` therefore finds no
   GitHub release for it and skips it. An update ships through the installer.
7. A new metadata goes in a class attribute (or a `virtual` member with a default) — never an
   `abstract` member: the dlls already shipped must keep loading.

## Where things are

- `OdooTool.cs` — the tool class; its public methods are what the model can call
- `installer/` — `install.ps1` and `install.sh`: Odoo + AgentBridge + plugin, and the launcher
- `OdooTool.Tests/`, `OdooTool.AgentTests/` — nested projects, excluded from the library compile

## Shipping

Publishes a NuGet package; the installer is the only channel that installs it. AgentBridge does not
fetch it, and AIOffice does not build it.
