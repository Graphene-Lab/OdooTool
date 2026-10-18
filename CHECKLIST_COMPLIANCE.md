# OdooTool — TOOL_CHECKLIST Compliance

Checked 2026-10-16 against `AIOrchestrator/API/TOOL_CHECKLIST.md`. `OdooTool` is a pure-network
agent tool: it drives the Odoo ERP external API and reads/writes **no files**, so the
file-oriented points are N/A.

## Release & layout (plugin tools)

- OK — csproj `<Version>$([System.DateTime]::Now.ToString("1.yy.MM.dd"))</Version>`: date auto-version.
- N/A — GitHub Release zip + NuGet workflows: to be added when the repo is created on GitHub.
  The csproj is ready for both channels (PackageId=Graphene.OdooTool, AssemblyMetadata set).
- OK — AIOrchestrator referenced at parent level (`..\AIOrchestrator\AIOrchestrator.csproj`
  ProjectReference when present, `Graphene.AIOrchestrator` 1.* package otherwise); never copied
  into the plugin folder.
- OK — never ships `AIOrchestrator.dll` or its dependency graph: the plugin has no unique
  dependency dlls beyond the BCL (System.Net.Http, System.Text.Json are framework-provided).
- OK — writes no state next to the host executable or inside `Tools/OdooTool/`: connection
  settings are READ from the environment or `PersistentData/odoo.json`; the tool never writes
  config or files.
- OK — independent of the host launch directory: config resolves via `AppContext.BaseDirectory`
  (a non-CWD base), requests use absolute URLs, no CWD use.

## Agent-facing descriptions

- OK — docs never mention internals (HttpClient, JSON-2 endpoint, Bearer token, HTTP headers).
  The class summary states competency + cross-method rules only.
- OK — minimal text: class summary three lines, each method `summary`/`param`/`returns`;
  rendered definitions stay small.
- OK — methods state what they do (outcomes), not how.
- OK — nothing mentions a sandbox or virtual paths (no file paths at all).
- N/A — no path-bearing methods.
- OK — every public method (`get_models`, `get_fields`, `search`, `read`, `create_record`,
  `update_record`, `delete_record`, `call_method`, `read_group`, `get_menus`,
  `get_menu_details`, `get_context`, `check_connection`) has `summary`, `param`, `returns`
  incl. error format.
- OK — class summary: one-line competency + cross-method rules (permissions apply, start with
  `get_models()`).
- OK — no summary/param redundancy; JSON/format details live only in `param`/`returns`.
- OK — one instruction per line; each `///` line is one continuous source line.
- OK — formats specified: JSON array/object shapes with examples, domain operators listed,
  model names as technical dotted names.
- N/A — no closed-set parameters requiring enum (all inputs are free-form: model names, JSON
  blobs, domain arrays, action names are open by design).
- OK — cross-references: params that come from another method's result name `get_models()`
  and `get_fields()`.
- OK — method-name references written naturally; the generator normalizes them.
- OK — runtime messages reference methods via `Utility.ToSnakeCase(nameof(...))`, never
  hardcoded PascalCase.
- OK — errors are actionable (cause + fix/alternative) and prefixed `Error:`; no raw
  exceptions, no URL/credential leakage.
- N/A — no `[[name]]` dynamic placeholders.

## Surface & sandbox

- OK — only agent operations are public (13 methods); system-side internals (HTTP send,
  config loading, JSON parsing, error extraction) are private/static.
- N/A — no file-handling methods: `SandboxPath` not applicable.
- OK — no sandbox escape, no credentials/configuration/host paths exposed: `OdooConfig`
  values are never returned to the agent (errors report the outcome, not the endpoint or
  the API key).

## Code & conventions

- OK — class name ends with `Tool`; package `Graphene.OdooTool`.
- OK — public methods declared on the class; the only inherited public member is
  `BaseAgentTool.LoadSkill`.
- OK — `Log.LogStep()` at entry/outcome of every public method and in the HTTP plumbing.
- OK — derives from `BaseAgentTool`; `IFileTool` N/A (no files handled).
- OK — `GenerateDocumentationFile=True` (tool definitions come from the `.xml` next to the dll).

## Standardized support — shared AIOrchestrator helpers

- N/A — no file content described/listed: `FileManager` not applicable.
- N/A — no files created/modified: `GitSupport.Snapshot` not applicable.
- N/A — no file output: no sandbox-relative path to return.
- N/A — the tool parses no LLM-generated text: `Utility.RemoveFencesEncapsulationAndFixTrim`
  not applicable.
- N/A — no HTML/SVG output: `Utility.EmbedSvgIcons` not applicable.
- N/A — no language detection: `Utility.DetectLanguage` not applicable.
- N/A — no path resolution: `SandboxPath` not applicable (see "Surface & sandbox").
- OK — method-name references in runtime messages use the shared `Utility.ToSnakeCase`.

## Completion — compliance file

- OK — this file is shipped at the repository root of the plugin and states every checklist
  point above.
