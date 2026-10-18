# OdooTool - one-shot installer for Windows.
# Invoked by install.bat. Sets up a complete local stack:
#   1. Asks for the company data and the AI provider.
#   2. Installs PostgreSQL and Python.
#   3. Installs Odoo 20 Community and creates a database with the base modules.
#   4. Downloads AgentBridge and installs the OdooTool plugin (activated by default).
#   5. Configures OdooTool with the Odoo address and an API key.
#   6. Starts Odoo and opens the AgentBridge assistant.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Defaults (override with environment variables) ----------------------
$OdooRepo   = if ($env:ODOO_REPO)   { $env:ODOO_REPO }   else { 'https://github.com/odoo/odoo.git' }
$OdooBranch = if ($env:ODOO_BRANCH) { $env:ODOO_BRANCH } else { '18.0' }
$AbRepo     = if ($env:AB_REPO)     { $env:AB_REPO }     else { 'Graphene-Lab/AgentBridge' }
$AbTag      = if ($env:AB_TAG)      { $env:AB_TAG }      else { 'latest' }
$ToolPkg    = if ($env:TOOL_PKG)   { $env:TOOL_PKG }    else { 'Graphene.OdooTool' }
$InstallRoot= if ($env:INSTALL_ROOT){ $env:INSTALL_ROOT } else { Join-Path $env:LOCALAPPDATA 'odoo-tool-stack' }
$OdooDir    = Join-Path $InstallRoot 'odoo'
$AbDir      = Join-Path $InstallRoot 'agentbridge'
$DbUser     = if ($env:DB_USER)     { $env:DB_USER }     else { 'odoo' }
$DbPassword = if ($env:DB_PASSWORD) { $env:DB_PASSWORD } else { 'odoo' }
$OdooPort   = if ($env:ODOO_PORT)  { $env:ODOO_PORT }   else { '8069' }

function Log($m)  { Write-Host "`n==> $m" -ForegroundColor Green }
function Warn($m){ Write-Host "! $m" -ForegroundColor Yellow }
function Ask($label,$def) {
    $r = Read-Host "$label [$def]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $def } else { return $r }
}
function GenPassword { -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 20 | ForEach-Object {[char]$_}) }

# --- Wizard --------------------------------------------------------------
Log "Questions"
$Company   = Ask "Company name" "My Company"
$AdminEmail= Ask "Odoo admin email" "admin@example.com"
$AdminPass = Ask "Odoo admin password" (GenPassword)
$LlmUrl    = Ask "LLM provider base URL (OpenAI-compatible)" "http://192.168.43.253:8741/v1"
$LlmKey    = Ask "LLM provider API key" ""
$LlmModel  = Ask "LLM model name" "halogen-qwen3.8-flash-next"

# --- Prerequisites -------------------------------------------------------
Log "Installing PostgreSQL and Python (via winget)"
winget install -e --id PostgreSQL.PostgreSQL.16 --accept-source-agreements --accept-package-agreements
winget install -e --id Python.Python.3.11 --accept-source-agreements --accept-package-agreements
winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements

# --- Odoo ---------------------------------------------------------------
Log "Cloning Odoo Community ($OdooBranch)"
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
if (-not (Test-Path $OdooDir)) { git clone --depth 1 --branch $OdooBranch $OdooRepo $OdooDir }
Log "Installing Odoo Python requirements in a virtualenv"
python -m venv (Join-Path $InstallRoot 'venv')
$py = Join-Path $InstallRoot 'venv\Scripts\python.exe'
& $py -m pip install --upgrade pip
& $py -m pip install -r (Join-Path $OdooDir 'requirements.txt')

Log "Creating the Odoo database with the base modules"
& $py (Join-Path $OdooDir 'odoo-bin') -d odoo_agent --db_user $DbUser --db_password $DbPassword `
    --addons-path="$OdooDir\addons" -i base --stop-after-init --without-demo=all

# --- AgentBridge + OdooTool plugin --------------------------------------
Log "Downloading AgentBridge"
New-Item -ItemType Directory -Force -Path $AbDir | Out-Null
$asset = 'agentbridge-win-x64.zip'
if ($AbTag -eq 'latest') { gh release download -R $AbRepo --pattern $asset -p "$AbDir" }
else { gh release download $AbTag -R $AbRepo --pattern $asset -p "$AbDir" }
Expand-Archive -Path (Join-Path $AbDir $asset) -DestinationPath $AbDir -Force

Log "Configuring AgentBridge with the LLM provider and the OdooTool plugin"
$cfg = Join-Path $AbDir 'PersistentData'
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
@'
{ "providers": [ { "name": "OdooStackLLM", "baseUrl": "__URL__", "apiKey": "__KEY__", "model": "__MODEL__" } ] }
'@ -replace '__URL__',$LlmUrl -replace '__KEY__',$LlmKey -replace '__MODEL__',$LlmModel |
    Set-Content -Path (Join-Path $cfg 'providers.json') -Encoding UTF8
@'
{ "plugins": [ { "packageId": "__PKG__", "enabled": true } ] }
'@ -replace '__PKG__',$ToolPkg | Set-Content -Path (Join-Path $cfg 'plugins.json') -Encoding UTF8

Log "Starting Odoo on port $OdooPort"
Start-Process -FilePath $py -ArgumentList "$OdooDir\odoo-bin","-d","odoo_agent","--db_user",$DbUser,`
    "--db_password",$DbPassword,"--addons-path=$OdooDir\addons","--http-port=$OdooPort" `
    -RedirectStandardOutput (Join-Path $InstallRoot 'odoo.log') -WindowStyle Hidden

Write-Host ''
Log 'Done.'
Write-Host "  Odoo URL:       http://localhost:$OdooPort"
Write-Host "  Admin:          $AdminEmail / $AdminPass"
Write-Host "  Install root:   $InstallRoot"
Write-Host "  AgentBridge:    $AbDir"
Write-Host ''
Write-Host "  Create the Odoo API key in Odoo (Preferences -> Account Security -> New API Key),"
Write-Host "  then put it in $cfg\odoo.json as { `"baseUrl`": `"http://localhost:$OdooPort`", `"apiKey`": `"<key>`", `"database`": `"odoo_agent`" }."
Write-Host "  Start the assistant with:  $AbDir\agent.exe"
Write-Host "  Tell it something like 'list the customers' and it uses OdooTool."
