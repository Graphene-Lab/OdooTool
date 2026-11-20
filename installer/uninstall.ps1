# OdooTool - uninstaller for Windows.
# Invoked by uninstall.bat. Removes what install.ps1 created:
#   1. stops the ERP and the assistant if they are running from this installation;
#   2. drops the Odoo database (every customer, product, order, invoice and stock move in it);
#   3. removes the "Odoo <port>" firewall rule, the start page, the launcher and the shortcuts;
#   4. deletes the installation folder, keeping AgentBridge only when the user asks to keep it.
#
# INSTALLER CONTRACT - see INSTALLER-CONTRACT.md. Two confirmations guard the deletion: a yes/no
# question that says what disappears, then the phrase DESTROY ALL typed in capitals. The phrase is
# not decoration: it is the only thing standing between a tired user and a company's ledger, and
# the deletion cannot be undone. PostgreSQL itself is left installed, because it is a service other
# programs may share and it is removed from Apps & features like any other program.
$ErrorActionPreference = 'Stop'

$InstallRoot = if ($env:INSTALL_ROOT) { $env:INSTALL_ROOT } else { Join-Path $env:LOCALAPPDATA 'odoo-tool-stack' }
$OdooPort    = if ($env:ODOO_PORT)    { $env:ODOO_PORT }    else { '8069' }
$DbName      = 'odoo_agent'

function Log($m)  { Write-Host "`n==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "! $m" -ForegroundColor Yellow }

# The folder is deleted recursively, so it is only accepted when it is recognisably an OdooTool
# installation: a mistyped INSTALL_ROOT (C:\ or a home folder) must never be wiped.
$markers = @(Get-ChildItem -Path $InstallRoot -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -in @('odoo', 'agentbridge', 'venv', 'start.ps1', 'start.html') })
if (-not (Test-Path $InstallRoot) -or $markers.Count -eq 0) {
    Write-Host "Nothing to remove: no OdooTool installation was found in '$InstallRoot'."
    exit 0
}

function FolderSize([string]$path) {
    if (-not (Test-Path $path)) { return '0 MB' }
    $b = (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if (-not $b) { return '0 MB' }
    return ('{0:N0} MB' -f ($b / 1MB))
}

# The launcher holds the real database credentials and port: reading them here means the user is
# never asked for a database password to delete a database.
$dbPort = '5432'; $dbUser = 'odoo'; $dbPass = 'odoo'
$launcher = Join-Path $InstallRoot 'start.ps1'
if (Test-Path $launcher) {
    $t = Get-Content -Raw $launcher
    if ($t -match '\$port\s*=\s*(\d+)')    { $OdooPort = $Matches[1] }
    if ($t -match '\$dbPort\s*=\s*(\d+)')  { $dbPort   = $Matches[1] }
    if ($t -match "(?m)^\`$dbUser\s*=\s*'(.*)'\s*$") { $dbUser = $Matches[1] -replace "''", "'" }
    if ($t -match "(?m)^\`$dbPass\s*=\s*'(.*)'\s*$") { $dbPass = $Matches[1] -replace "''", "'" }
}

Log "What this removes"
Write-Host "  Installation folder: $InstallRoot ($(FolderSize $InstallRoot))"
Write-Host "  Odoo database:       $DbName on PostgreSQL port $dbPort"
Write-Host "  Shortcuts:           'AI Odoo' on the Desktop and in the Start Menu"
Write-Host "  Firewall rule:       'Odoo $OdooPort'"
Write-Host "  The assistant (AgentBridge) is asked about separately."
Write-Host ''
Write-Host "  PostgreSQL itself is NOT removed: it is a service other programs may use."
Write-Host "  To remove it, use Settings > Apps > Installed apps, as with any other program."

# Unattended runs pass the phrase in the environment instead of typing it. The name says what it
# does on purpose: nothing else in this script accepts a silent confirmation.
$unattended = ($env:UNINSTALL_CONFIRM -eq 'DESTROY ALL')
$removeAgentBridge = $false
if ($unattended) {
    $removeAgentBridge = ($env:UNINSTALL_REMOVE_AGENTBRIDGE -eq '1')
} else {
    $answer = Read-Host "Delete all of this? The data in the database cannot be recovered [y/N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host "Nothing was changed."
        exit 0
    }
    $answer = Read-Host "Also delete AgentBridge, the assistant, its settings and the Odoo API key? [y/N]"
    $removeAgentBridge = ($answer -match '^(y|yes)$')

    Write-Host ''
    Write-Host "  This cannot be undone. Every customer, product, order, invoice and stock move" -ForegroundColor Yellow
    Write-Host "  in the database will be gone, and no backup is made here." -ForegroundColor Yellow
    $phrase = Read-Host "  Type DESTROY ALL in capital letters to continue"
    # -cne: case-sensitive, so "destroy all" does not pass. The phrase is a deliberate act.
    if (([string]$phrase).Trim() -cne 'DESTROY ALL') {
        Write-Host "The phrase did not match. Nothing was changed."
        exit 0
    }
}

# --- Stop what this installation started --------------------------------
Log "Stopping the ERP and the assistant"
$stopped = 0
foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    if ($p.ProcessId -eq $PID) { continue }
    $cmd = [string]$p.CommandLine
    $exe = [string]$p.ExecutablePath
    $isOdoo  = $cmd -like '*odoo-bin*' -and $cmd -like "*$InstallRoot*"
    $isAgent = $exe -and ($exe -like "$InstallRoot\agentbridge\*")
    if ($isOdoo -or $isAgent) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { }
    }
}
if ($stopped -eq 0) { Write-Host "  nothing was running from this installation" }
else { Write-Host "  stopped $stopped process(es)" }

# --- Drop the database --------------------------------------------------
Log "Dropping the database '$DbName'"
$psql = (Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
         Select-Object -First 1).FullName
if (-not $psql) { $psql = (Get-Command psql -ErrorAction SilentlyContinue).Source }
if (-not $psql) {
    Warn "psql was not found, so the database '$DbName' was NOT dropped. Remove it from pgAdmin or reinstall PostgreSQL's client tools and run this again."
} else {
    $env:PGPASSWORD = $dbPass
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # FORCE disconnects the sessions a still-running ERP left behind; on a PostgreSQL older than
    # 13 the clause does not exist, so the backends are terminated first and the drop repeated.
    $out = & $psql -w -U $dbUser -h 127.0.0.1 -p $dbPort -d postgres -c "DROP DATABASE IF EXISTS $DbName WITH (FORCE)" 2>&1
    if ($LASTEXITCODE -ne 0) {
        & $psql -w -U $dbUser -h 127.0.0.1 -p $dbPort -d postgres -tAc "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DbName'" | Out-Null
        $out = & $psql -w -U $dbUser -h 127.0.0.1 -p $dbPort -d postgres -c "DROP DATABASE IF EXISTS $DbName" 2>&1
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    if ($code -eq 0) { Write-Host "  database dropped" }
    else { Warn "the database could not be dropped: $(('' + $out).Trim())" }
}

# --- Firewall rule and shortcuts ---------------------------------------
Log "Removing the firewall rule and the shortcuts"
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
netsh advfirewall firewall delete rule name="Odoo $OdooPort" 2>&1 | Out-Null
$ErrorActionPreference = $saved
$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'AI Odoo'
Remove-Item (Join-Path $desktop 'AI Odoo.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item $startMenu -Recurse -Force -ErrorAction SilentlyContinue

# --- Files --------------------------------------------------------------
Log "Deleting the files"
if ($removeAgentBridge) {
    Remove-Item $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    # AgentBridge's own user data lives outside the installation folder.
    Remove-Item (Join-Path $env:LOCALAPPDATA 'agent') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  removed $InstallRoot (including AgentBridge)"
} else {
    # AgentBridge can host other tools and holds its own settings, so it survives when the user
    # asked to keep it. Everything else in the folder belongs to this Odoo stack.
    Get-ChildItem $InstallRoot -Force | Where-Object { $_.Name -ne 'agentbridge' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  removed everything in $InstallRoot except agentbridge\"
    Write-Host "  AgentBridge is still installed; start it with $InstallRoot\agentbridge\agent.exe"
}
if (Test-Path $InstallRoot) {
    $left = @(Get-ChildItem $InstallRoot -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) { Remove-Item $InstallRoot -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Log "Finished"
Write-Host "  Odoo, its database and its shortcuts are gone from this PC."
Write-Host "  PostgreSQL was left in place. The 'odoo' database role may still exist; it is harmless"
Write-Host "  and is reused by a future installation."
