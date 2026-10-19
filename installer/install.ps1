# OdooTool - one-shot installer for Windows.
# Invoked by install.bat. Sets up a complete local stack:
#   1. Asks for the company data and the AI provider (environment variables win, so it can
#      also run unattended).
#   2. Installs PostgreSQL, Python and Git when missing.
#   3. Installs Odoo Community and creates a database with the base modules.
#   4. Downloads AgentBridge and installs the OdooTool plugin (activated by default).
#   5. Configures OdooTool with the Odoo address and an API key.
#   6. Opens the firewall port, starts Odoo and leaves the assistant ready.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Defaults (override with environment variables) ----------------------
$OdooRepo   = if ($env:ODOO_REPO)   { $env:ODOO_REPO }   else { 'https://github.com/odoo/odoo.git' }
$OdooBranch = if ($env:ODOO_BRANCH) { $env:ODOO_BRANCH } else { '20.0' }
$AbRepo     = if ($env:AB_REPO)     { $env:AB_REPO }     else { 'Graphene-Lab/AgentBridge' }
$AbTag      = if ($env:AB_TAG)      { $env:AB_TAG }      else { 'latest' }
$ToolPkg    = if ($env:TOOL_PKG)    { $env:TOOL_PKG }    else { 'Graphene.OdooTool' }
$InstallRoot= if ($env:INSTALL_ROOT){ $env:INSTALL_ROOT } else { Join-Path $env:LOCALAPPDATA 'odoo-tool-stack' }
$OdooDir    = Join-Path $InstallRoot 'odoo'
$AbDir      = Join-Path $InstallRoot 'agentbridge'
$DbUser     = if ($env:DB_USER)     { $env:DB_USER }     else { 'odoo' }
$DbPassword = if ($env:DB_PASSWORD) { $env:DB_PASSWORD } else { 'odoo' }
$DbPort     = if ($env:DB_PORT)     { $env:DB_PORT }     else { '5432' }
$OdooPort   = if ($env:ODOO_PORT)   { $env:ODOO_PORT }   else { '8069' }

function Log($m)  { Write-Host "`n==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "! $m" -ForegroundColor Yellow }
function Ask($label,$def,$envName) {
    if ($envName -and -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))) {
        return [Environment]::GetEnvironmentVariable($envName)
    }
    $r = Read-Host "$label [$def]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $def } else { return $r }
}
function GeneratePassword { -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 20 | ForEach-Object {[char]$_}) }

# --- Wizard (environment variables make it unattended) ------------------
Log "Questions"
$Company    = Ask "Company name" "My Company" 'COMPANY_NAME'
$AdminEmail = Ask "Odoo admin email" "admin@example.com" 'ADMIN_EMAIL'
$AdminPass  = Ask "Odoo admin password" (GeneratePassword) 'ADMIN_PASS'
$LlmUrl     = Ask "LLM provider base URL (OpenAI-compatible)" "http://192.168.43.253:8741/v1" 'LLM_BASE_URL'
$LlmKey     = Ask "LLM provider API key" "" 'LLM_KEY'
$LlmModel   = Ask "LLM model name" "halogen-qwen3.8-flash-next" 'LLM_MODEL'

# --- Prerequisites (install only what is missing) -----------------------
Log "Checking PostgreSQL, Python and Git"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    winget install -e --id Git.Git --accept-source-agreements --accept-package-agreements
}
$psql = (Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
         Select-Object -First 1).FullName
if (-not $psql) {
    winget install -e --id PostgreSQL.PostgreSQL.16 --accept-source-agreements --accept-package-agreements
    $psql = (Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
             Select-Object -First 1).FullName
}
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path','User')

# --- PostgreSQL role ----------------------------------------------------
Log "Configuring PostgreSQL user '$DbUser'"
if (-not $psql) {
    Warn "psql not found. Create a PostgreSQL role named '$DbUser' (superuser, password '$DbPassword') manually."
} else {
    $env:PGPASSWORD = $DbPassword
    $canConnect = & $psql -U $DbUser -h 127.0.0.1 -p $DbPort -d postgres -tAc "select 1" 2>$null
    if ($canConnect -eq '1') {
        Log "role '$DbUser' already works"
    } else {
        $pgPass = Ask "PostgreSQL 'postgres' superuser password" "" 'PG_SUPERPASS'
        if ($pgPass) {
            $env:PGPASSWORD = $pgPass
            & $psql -U postgres -h 127.0.0.1 -p $DbPort -d postgres -c "CREATE ROLE $DbUser LOGIN SUPERUSER PASSWORD '$DbPassword';" 2>$null
            if ($LASTEXITCODE -ne 0) { Warn "Could not create the role '$DbUser'; continuing if it already exists." }
        } else {
            Warn "No superuser password given: create the role '$DbUser' manually if the next step fails."
        }
    }
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}

# --- Odoo ---------------------------------------------------------------
Log "Cloning Odoo Community ($OdooBranch)"
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
if (-not (Test-Path $OdooDir)) { git clone --depth 1 --branch $OdooBranch $OdooRepo $OdooDir }

Log "Installing Odoo Python requirements in a virtualenv"
$venvDir = Join-Path $InstallRoot 'venv'
$py = Join-Path $venvDir 'Scripts\python.exe'
if (Test-Path $py) {
    Log "reusing the existing virtualenv"
} else {
    if (Test-Path $venvDir) { Remove-Item -Recurse -Force $venvDir -ErrorAction SilentlyContinue }
    $venvMade = $false
    if (Get-Command py -ErrorAction SilentlyContinue) {
        foreach ($v in @('3.12','3.11','3.13','3.10')) {
            & py "-$v" --version 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                & py "-$v" -m venv $venvDir
                if ($LASTEXITCODE -eq 0) { $venvMade = $true; Log "using Python $v"; break }
            }
        }
    }
    if (-not $venvMade) { python -m venv $venvDir }
}
$py = Join-Path $venvDir 'Scripts\python.exe'
& $py -m pip install --upgrade pip
# python-ldap has no Windows wheel and needs OpenLDAP headers; LDAP auth is optional in
# Odoo, so exclude it — otherwise pip fails on a plain Windows machine.
$reqWin = Get-Content (Join-Path $OdooDir 'requirements.txt') |
          Where-Object { $_ -notmatch '^\s*python-ldap' }
$reqWin | Set-Content (Join-Path $InstallRoot 'requirements-win.txt') -Encoding ASCII
& $py -m pip install -r (Join-Path $InstallRoot 'requirements-win.txt')

Log "Creating the Odoo database with the base modules"
# --db_host forces TCP password auth; the UNIX-socket shortcut does not exist on Windows.
& $py (Join-Path $OdooDir 'odoo-bin') -d odoo_agent --db_host=127.0.0.1 --db_port $DbPort --db_user $DbUser --db_password $DbPassword `
    --addons-path="$OdooDir\addons" -i base --stop-after-init --without-demo

# --- Admin credentials + API key ----------------------------------------
Log "Creating the Odoo API key for the admin user"
$env:ODOO_ADMIN_EMAIL = $AdminEmail
$env:ODOO_ADMIN_PASS  = $AdminPass
$keyScript = @'
import os
admin = env["res.users"].browse(2)
email = os.environ["ODOO_ADMIN_EMAIL"]
admin.write({"login": email, "email": email, "password": os.environ["ODOO_ADMIN_PASS"]})
key = env["res.users.apikeys"].with_user(admin)._generate("rpc", "agentbridge", None)
env.cr.commit()
print(key or "")
'@
$scriptPath = Join-Path $InstallRoot 'make_key.py'
[System.IO.File]::WriteAllText($scriptPath, $keyScript, (New-Object System.Text.UTF8Encoding($false)))
$outPath = Join-Path $InstallRoot 'odoo_api_key.txt'
$errPath = Join-Path $InstallRoot 'make_key.err'
# Feed the script as a FILE and capture stdout as a FILE: piping through PowerShell 5.1
# re-encodes the text in the console code page and corrupts the Python source.
Start-Process -FilePath $py -ArgumentList @(
    (Join-Path $OdooDir 'odoo-bin'), 'shell', '-d', 'odoo_agent',
    '--db_host=127.0.0.1', '--db_port', $DbPort, '--db_user', $DbUser, '--db_password', $DbPassword,
    "--addons-path=$OdooDir\addons", '--no-http'
) -RedirectStandardInput $scriptPath -RedirectStandardOutput $outPath -RedirectStandardError $errPath `
  -NoNewWindow -Wait
$OdooApiKey = ''
if (Test-Path $outPath) { $OdooApiKey = (Get-Content -Raw $outPath).Trim() }
if ([string]::IsNullOrWhiteSpace($OdooApiKey)) {
    Warn "Could not auto-create the API key. Create it in Odoo (Preferences -> Account Security -> New API Key) and set it in the AgentBridge config."
}

# --- AgentBridge + OdooTool plugin --------------------------------------
Log "Downloading AgentBridge"
New-Item -ItemType Directory -Force -Path $AbDir | Out-Null
$asset = 'agentbridge-win-x64.tar.gz'
if ($AbTag -eq 'latest') {
    $url = "https://github.com/$AbRepo/releases/latest/download/$asset"
} else {
    $url = "https://github.com/$AbRepo/releases/download/$AbTag/$asset"
}
$pkg = Join-Path $AbDir $asset
# curl.exe (built into Windows 10+) resumes a partial transfer and retries transient
# failures. BITS stalled here with no progress, so curl is the reliable path.
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
if ($curl) {
    # Resume, never restart: on a flaky link the partial file is kept and -C - continues it.
    $attempt = 0
    while ($true) {
        $attempt++
        & $curl -fL --retry 5 --retry-delay 5 -C - --output $pkg $url
        if ($LASTEXITCODE -eq 0) { break }
        if ($attempt -ge 10) { throw "AgentBridge download failed after $attempt attempts" }
        Warn "download interrupted; resuming (attempt $attempt)..."
        Start-Sleep -Seconds 5
    }
} else {
    Invoke-WebRequest -Uri $url -OutFile $pkg -UseBasicParsing -TimeoutSec 7200
}
# Verify the archive before extracting: a truncated or resumed transfer is corrupt.
$verified = $false
for ($i = 0; $i -lt 2; $i++) {
    & tar -tzf $pkg *> $null
    if ($LASTEXITCODE -eq 0) { $verified = $true; break }
    Warn "AgentBridge archive is corrupt; downloading again from scratch"
    Remove-Item $pkg -Force -ErrorAction SilentlyContinue
    if ($curl) { & $curl -fL --retry 5 --retry-delay 5 --output $pkg $url }
    else { Invoke-WebRequest -Uri $url -OutFile $pkg -UseBasicParsing -TimeoutSec 7200 }
    if ($LASTEXITCODE -ne 0) { break }
}
if (-not $verified) { throw "AgentBridge archive could not be verified (download corrupt)" }
tar -xzf $pkg -C $AbDir
if ($LASTEXITCODE -ne 0) { throw "AgentBridge extraction failed" }
if (-not (Test-Path (Join-Path $AbDir 'agent.exe'))) { throw "AgentBridge binary missing after extraction" }

Log "Configuring AgentBridge with the LLM provider and the OdooTool plugin"
$cfg = Join-Path $AbDir 'PersistentData'
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
@"
{ "providers": [ { "name": "OdooStackLLM", "baseUrl": "$LlmUrl", "apiKey": "$LlmKey", "model": "$LlmModel" } ] }
"@ | Set-Content -Path (Join-Path $cfg 'providers.json') -Encoding UTF8
@"
{ "plugins": [ { "packageId": "$ToolPkg", "enabled": true } ] }
"@ | Set-Content -Path (Join-Path $cfg 'plugins.json') -Encoding UTF8
@"
{ "baseUrl": "http://localhost:$OdooPort", "apiKey": "$OdooApiKey", "database": "odoo_agent" }
"@ | Set-Content -Path (Join-Path $cfg 'odoo.json') -Encoding UTF8

# --- Firewall -----------------------------------------------------------
Log "Opening TCP port $OdooPort in Windows Firewall"
netsh advfirewall firewall delete rule name="Odoo $OdooPort" 2>$null | Out-Null
netsh advfirewall firewall add rule name="Odoo $OdooPort" dir=in action=allow protocol=TCP localport=$OdooPort 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Warn "Could not add the firewall rule (run as Administrator)." }

Log "Starting Odoo on port $OdooPort"
Start-Process -FilePath $py -ArgumentList @(
    (Join-Path $OdooDir 'odoo-bin'), '-d', 'odoo_agent', '--db_host=127.0.0.1',
    '--db_port', $DbPort, '--db_user', $DbUser, '--db_password', $DbPassword,
    "--addons-path=$OdooDir\addons", "--http-port=$OdooPort", '--http-interface=0.0.0.0'
) -RedirectStandardOutput (Join-Path $InstallRoot 'odoo.log') -WindowStyle Hidden

# --- One-click launcher + shortcut -------------------------------------
Log "Creating the one-click launcher and shortcuts"
$launcherTemplate = @'
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$py = Join-Path $root 'venv\Scripts\python.exe'
$odoo = Join-Path $root 'odoo\odoo-bin'
$ab = Join-Path $root 'agentbridge\agent.exe'
$port = 8069
$dbPort = __DB_PORT__
function Test-Odoo { (Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded }
if (-not (Test-Odoo)) {
    Start-Process -FilePath $py -ArgumentList @(
        $odoo, '-d', 'odoo_agent', '--db_host=127.0.0.1', "--db_port=$dbPort",
        '--db_user', 'odoo', '--db_password', 'odoo',
        ("--addons-path=" + (Join-Path $root 'odoo\addons')), "--http-port=$port", '--http-interface=0.0.0.0'
    ) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $root 'odoo.log')
    for ($i = 0; $i -lt 40; $i++) { if (Test-Odoo) { break }; Start-Sleep -Seconds 2 }
}
Start-Process "http://localhost:$port"
if (Test-Path $ab) { Start-Process -FilePath $ab -WorkingDirectory (Join-Path $root 'agentbridge') }
'@
$launcherPath = Join-Path $InstallRoot 'start.ps1'
[System.IO.File]::WriteAllText($launcherPath, $launcherTemplate.Replace('__DB_PORT__', $DbPort), (New-Object System.Text.UTF8Encoding($false)))

$ws = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'AI Odoo'
New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
foreach ($lnk in @((Join-Path $desktop 'AI Odoo.lnk'), (Join-Path $startMenu 'AI Odoo.lnk'))) {
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`""
    $sc.WorkingDirectory = $InstallRoot
    $sc.IconLocation = "$AbDir\agent.exe,0"
    $sc.Description = 'AI Odoo - assistant and ERP'
    $sc.Save()
}

Write-Host ''
Log 'Done.'
Write-Host "  HOW TO START:"
Write-Host "    Double-click the 'AI Odoo' icon on the Desktop (or in the Start Menu)."
Write-Host "    It starts Odoo, opens it in the browser and launches the assistant."
Write-Host "    Then type a request such as 'list the customers'."
Write-Host ''
Write-Host "  Odoo URL:       http://localhost:$OdooPort"
Write-Host "  Admin:          $AdminEmail / $AdminPass"
Write-Host "  Install root:   $InstallRoot"
Write-Host "  AgentBridge:    $AbDir"
Write-Host "  Firewall:       TCP $OdooPort open"
Write-Host ''
Write-Host "  Manual start, if you ever need it:"
Write-Host "    Odoo:      $py `"$OdooDir\odoo-bin`" -d odoo_agent --db_port $DbPort"
Write-Host "    Assistant: $AbDir\agent.exe"
