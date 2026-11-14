# OdooTool - one-shot installer for Windows.
# Invoked by install.bat. Sets up a complete local stack:
#   1. Asks for the company data and the AI provider (environment variables win, so it can
#      also run unattended).
#   2. Installs PostgreSQL, Python and Git when missing.
#   3. Installs Odoo Community and creates a database with the base modules.
#   4. Downloads AgentBridge and installs the OdooTool plugin (activated by default).
#   5. Configures OdooTool with the Odoo address and an API key.
#   6. Opens the firewall port, starts Odoo, opens the Odoo 20 first-steps page in the default
#      browser and leaves Odoo running with the assistant installed and ready to start from
#      the icon.
#
# INSTALLER CONTRACT - do not change without reading INSTALLER-CONTRACT.md.
# The "AI Odoo" launcher must start Odoo and AgentBridge (with the OdooTool plugin) and open
# the assistant chat at http://localhost:5290/OfficeManager. It must never open only Odoo and
# must never open Odoo's login page instead of the chat. Shared rationale:
# AgentBridge/docs-dev/INSTALLER-CONTRACT.md.
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
$PgSuper    = if ($env:PG_SUPERUSER){ $env:PG_SUPERUSER } else { 'postgres' }
# Password this installer assigns to the local PostgreSQL superuser account. The account is created
# by the installer itself, so asking the user for its password means asking for something nobody can
# know (a silent PostgreSQL install picks one on its own and shows it to no one). PG_SUPERPASS only
# exists to override it in unattended runs.
$PgSuperPass = if ($env:PG_SUPERPASS) { $env:PG_SUPERPASS } else { 'odoo' }
$OdooPort   = if ($env:ODOO_PORT)   { $env:ODOO_PORT }   else { '8069' }

function Log($m)  { Write-Host "`n==> $m" -ForegroundColor Green }
function Warn($m) { Write-Host "! $m" -ForegroundColor Yellow }

# Everything that goes wrong but does not stop the install is collected here, so the final
# summary can tell the user what is NOT working instead of printing a bare "Done." over a
# stack that silently never came up.
$Problems = @()
function Problem($m) { Write-Host "! $m" -ForegroundColor Yellow; $script:Problems += $m }

function Ask($label,$def,$envName) {
    if ($envName -and -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))) {
        return [Environment]::GetEnvironmentVariable($envName)
    }
    $r = Read-Host "$label [$def]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $def } else { return $r }
}

# Same as Ask, but what you type stays hidden on screen. Plain Read-Host echoes the typed text,
# which means a secret (an admin password, a database superuser password) ends up visible in the
# console window and can be copied straight out of it. Here the answer is read into a SecureString
# and turned back into text only in memory. An environment variable of the same name still wins,
# so unattended runs behave exactly as before.
function AskSecret($label,$def,$envName) {
    if ($envName -and -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($envName))) {
        return [Environment]::GetEnvironmentVariable($envName)
    }
    $ss = Read-Host "$label [$def]" -AsSecureString
    if ($ss.Length -eq 0) { return $def }
    $hglobal = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($ss)
    try  { return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($hglobal) }
    finally { if ($hglobal -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($hglobal) } }
}

function GeneratePassword { -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 20 | ForEach-Object {[char]$_}) }

# Keeps only the last $n characters of a program's output, so a long error dump never buries the
# one line that actually matters.
function Tail($t,$n) { $s = ('' + $t).Trim(); if ($s.Length -le $n) { return $s }; return $s.Substring($s.Length - $n) }

# Builds a PowerShell single-quoted literal (any embedded quote is doubled), so the generated
# launcher keeps the exact role name and password even when they contain $ ` " ' or spaces.
function PsSingleQuote([string]$s) { if ([string]::IsNullOrEmpty($s)) { return "''" }; "'" + ($s -replace "'", "''") + "'" }

# Runs a native program (winget, psql, curl, tar, pip, odoo-bin) without letting its stderr
# kill the whole install. Windows PowerShell 5.1 raises a terminating NativeCommandError the
# moment a native program writes anything to stderr while $ErrorActionPreference is 'Stop',
# so the preference is dropped to 'Continue' here and success is decided by the exit code.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$ArgList = @()
    )
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Code = -1; Text = "$Exe not found" }
    }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @ArgList 2>&1 | Out-String
        $code = $LASTEXITCODE
        $clean = ('' + $out).Trim()
        if ($clean.Length -gt 4000) { $clean = $clean.Substring($clean.Length - 4000) }
        $res = [pscustomobject]@{ Code = $code; Text = $clean }
    } finally {
        $ErrorActionPreference = $saved
    }
    return $res
}

# psql can live under the default prefix, somewhere else (a custom folder, a portable install) or
# on the PATH, so all three are checked instead of assuming the default prefix.
function Find-Psql {
    $p = (Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
          Select-Object -First 1).FullName
    if (-not $p) { $p = (Get-Command psql -ErrorAction SilentlyContinue).Source }
    return $p
}

# The data directory belongs to the installation psql was found in; a custom location is read back
# from the Windows service, which is told the directory with -D.
function Find-PgDataDir([string]$psqlPath) {
    if ($psqlPath) {
        $d = Join-Path (Split-Path (Split-Path $psqlPath -Parent) -Parent) 'data'
        if (Test-Path (Join-Path $d 'pg_hba.conf')) { return $d }
    }
    foreach ($svc in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'postgresql*' })) {
        $m = [regex]::Match([string]$svc.PathName, '-D\s+"?([^"]+)"?')
        if ($m.Success) {
            $cand = $m.Groups[1].Value.Trim()
            if (Test-Path (Join-Path $cand 'pg_hba.conf')) { return $cand }
        }
    }
    return $null
}

# The service that runs this data directory (so a reset restarts the right one).
function Find-PgService([string]$dataDir) {
    $all = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'postgresql*' })
    if ($dataDir) {
        $match = $all | Where-Object { [string]$_.PathName -like "*$dataDir*" } | Select-Object -First 1
        if ($match) { return $match.Name }
    }
    if ($all.Count -gt 0) { return $all[0].Name }
    return $null
}

# The port written in postgresql.conf. A PostgreSQL set up earlier (or by another tool) can be on
# 5433 while 5432 is taken, and connecting to the wrong port looks exactly like a wrong password.
function Get-PgConfPort([string]$dataDir) {
    if (-not $dataDir) { return $null }
    $conf = Join-Path $dataDir 'postgresql.conf'
    if (-not (Test-Path $conf)) { return $null }
    $m = Select-String -Path $conf -Pattern '^\s*port\s*=\s*(\d+)' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Replaces an unknown superuser password with the one this installer assigns, using PostgreSQL's own
# escape hatch: for a single restart the local TCP connections are trusted, which is the standard way
# back into a server whose password nobody has. pg_hba.conf sits under Program Files and the service
# has to be restarted, so a short helper script does it with Administrator rights - Windows may show
# its own consent prompt, but the user never has to type a database password. Returns the working
# password, or $null when the reset was not possible.
function Reset-PgSuperPassword {
    param([string]$DataDir, [string]$Service, [string]$NewPass)
    if (-not $DataDir -or -not $Service -or -not $psql) { return $null }
    $helper = Join-Path $env:TEMP 'odootool-pg-reset.ps1'
    $result = Join-Path $env:TEMP 'odootool-pg-reset.txt'
    Remove-Item $result -Force -ErrorAction SilentlyContinue
    $body = @'
param([string]$Psql, [string]$DataDir, [string]$Service, [string]$Super, [string]$Pass, [string]$Port, [string]$Result)
$ErrorActionPreference = 'Stop'
$conf   = Join-Path $DataDir 'pg_hba.conf'
$backup = "$conf.odootool-backup"
$script:ok = $false
$script:err = ''
try {
    Copy-Item $conf $backup -Force
    $text = Get-Content -Raw $conf
    $text = [regex]::Replace($text, '(?m)^(\s*host\s+\S+\s+\S+\s+(?:127\.0\.0\.1/32|::1/128)\s+)\S+', '${1}trust')
    Set-Content -Path $conf -Value $text -Encoding ASCII
    Restart-Service -Name $Service -Force
    $sql = "ALTER USER $Super WITH PASSWORD '" + ($Pass -replace "'", "''") + "';"
    $ErrorActionPreference = 'Continue'
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 2
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
        # -w: never prompt. If the trust line did not take effect psql must fail at once instead of
        # waiting on a hidden password prompt that nobody can see or answer.
        $out = & $Psql -w -U $Super -h 127.0.0.1 -p $Port -d postgres -c $sql 2>&1
        if ($LASTEXITCODE -eq 0) { $script:ok = $true; break }
        $script:err = ('psql exit ' + $LASTEXITCODE + ': ' + (($out | Out-String).Trim()))
    }
} catch {
    $script:err = $_.Exception.Message
} finally {
    # Whatever happened, the original authentication rules go back and the service is restarted.
    if (Test-Path $backup) { Move-Item $backup $conf -Force -ErrorAction SilentlyContinue }
    Restart-Service -Name $Service -Force -ErrorAction SilentlyContinue
    Set-Content -Path $Result -Value $(if ($script:ok) { 'ok' } else { $script:err }) -Encoding ASCII
}
'@
    [System.IO.File]::WriteAllText($helper, $body, (New-Object System.Text.UTF8Encoding($false)))
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$helper,'-Psql',$psql,'-DataDir',$DataDir,
                 '-Service',$Service,'-Super',$PgSuper,'-Pass',$NewPass,'-Port',[string]$DbPort,'-Result',$result)
    if (Test-Elevated) {
        & powershell @argList | Out-Null
    } else {
        # Start-Process joins an array with single spaces and does not quote the elements, so a path
        # such as 'C:\Program Files\PostgreSQL\16\bin\psql.exe' arrives at the elevated shell split
        # in two and the helper starts with no usable arguments - a bare powershell that waits
        # forever. The string below quotes every element that contains a space.
        $argString = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        Warn "Windows will ask for Administrator rights: changing the local PostgreSQL '$PgSuper' password needs them."
        try {
            $elev = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -Verb RunAs -PassThru -WindowStyle Hidden
            # An unattended run must never wait on a consent dialog nobody is going to click.
            if (-not $elev.WaitForExit(240000)) {
                try { $elev.Kill() } catch { }
                Warn "the elevated password reset did not finish within four minutes; run install.bat as Administrator to complete it."
                return $null
            }
        } catch { return $null }
    }
    # Verify with the value that was written, so a failed reset is not mistaken for a success.
    for ($i = 0; $i -lt 10; $i++) {
        $env:PGPASSWORD = $NewPass
        $t = Invoke-Native -Exe $psql -ArgList @('-w', '-U', $PgSuper, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-tAc', 'select 1')
        if ($t.Code -eq 0) { Remove-Item $helper -Force -ErrorAction SilentlyContinue; return $NewPass }
        Start-Sleep -Seconds 2
    }
    if (Test-Path $result) { Warn "the password reset did not work: $((Get-Content -Raw $result).Trim())" }
    Remove-Item $helper -Force -ErrorAction SilentlyContinue
    return $null
}

# --- Wizard (environment variables make it unattended) ------------------
Log "Questions"
$Company    = Ask "Company name" "My Company" 'COMPANY_NAME'
# The administrator is a user of the database created here, not an account anywhere: Odoo
# Community needs no registration, nothing is sent to odoo.com, and nobody is asked for Odoo
# credentials. The login and the password are generated locally and printed at the end;
# ADMIN_EMAIL / ADMIN_PASS still override them for unattended runs.
$AdminEmail = if ([string]::IsNullOrWhiteSpace($env:ADMIN_EMAIL)) { 'admin@example.com' } else { $env:ADMIN_EMAIL }
$AdminPass  = if ([string]::IsNullOrWhiteSpace($env:ADMIN_PASS))  { GeneratePassword }    else { $env:ADMIN_PASS }
# The AI provider is NOT asked here: AgentBridge asks on its first start, offering the known
# services with their models and a masked key field. That question belongs where the answer is
# used — the installer cannot test a key, so a wrong address typed here only surfaces later,
# inside the assistant. LLM_* still configure a stack unattended (a scripted or CI install).
$LlmUrl     = $env:LLM_BASE_URL
$LlmKey     = $env:LLM_KEY
$LlmModel   = $env:LLM_MODEL

# --- Prerequisites (install only what is missing) -----------------------
Log "Checking PostgreSQL, Python and Git"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $r = Invoke-Native -Exe 'winget' -ArgList @('install', '-e', '--id', 'Git.Git', '--accept-source-agreements', '--accept-package-agreements')
    if ($r.Code -ne 0) { Problem "winget could not install Git (exit $($r.Code)). The Odoo download needs Git; install it yourself if it is missing." }
}
$psql = Find-Psql
if (-not $psql) {
    # A port that is already taken is the most common reason a perfectly good PostgreSQL
    # installation fails on a developer's PC: another database, a Docker container, or - very
    # often - a WSL distro whose own PostgreSQL is forwarded to 127.0.0.1 by wslrelay. The
    # vendor installer answers "The specified port number is not available. Please enter a
    # different port." and exits 1, which reads like a network fault; the user is left with no
    # database and a message about a port. Choose the first free port instead and carry it
    # through the whole stack (role, database, Odoo, the launcher), so nobody has to know.
    function Test-PortFree([int]$port) {
        try { return -not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) }
        catch { return $true }
    }
    if (-not (Test-PortFree ([int]$DbPort))) {
        $free = $null
        foreach ($candidate in 5433..5455) { if (Test-PortFree $candidate) { $free = $candidate; break } }
        if ($free) {
            Warn "TCP port $DbPort is already in use on this PC; the new PostgreSQL will listen on $free instead."
            $DbPort = [string]$free
        } else {
            Problem "TCP ports 5432-5455 are all in use. Set DB_PORT to a free port and run this installer again."
        }
    }
    # curl.exe ships with Windows 10 1803+ and resumes a partial transfer, so the PostgreSQL
    # download below can be retried without starting over.
    $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    # winget's built-in silent switches run the PostgreSQL installer WITHOUT --superpassword, so the
    # superuser password is picked by nobody and known by nobody - that is the question users could
    # not answer. --override replaces those switches, so the account is created with the password
    # this installer assigns and nothing has to be typed by hand.
    Write-Host "PostgreSQL is not installed. It is installed now with the '$PgSuper' superuser password set to '$PgSuperPass' (assigned by this installer - there is nothing to type)."
    $pgArgs = "--mode unattended --unattendedmodeui none --serverport $DbPort"
    if ($PgSuperPass -match '\s') { $pgArgs += " --superpassword `"$PgSuperPass`"" }
    else { $pgArgs += " --superpassword $PgSuperPass" }
    $r = Invoke-Native -Exe 'winget' -ArgList @('install', '-e', '--id', 'PostgreSQL.PostgreSQL.16', '--accept-source-agreements', '--accept-package-agreements', '--override', $pgArgs)
    if ($r.Code -ne 0) {
        # winget itself fails often enough (the vendor CDN answers 403 unless the URL carries a
        # query string, and winget uses the bare URL). Falling back to the same official installer
        # downloaded directly keeps the install going instead of stopping the user here.
        Warn "winget could not install PostgreSQL (exit $($r.Code)); downloading the official installer directly. $(Tail $r.Text 200)"
        $pgSetup = Join-Path $env:TEMP 'postgresql-16-windows-x64.exe'
        $got = $false
        foreach ($v in @('16.15-5', '16.15-4', '16.9-3')) {
            $url = "https://get.enterprisedb.com/postgresql/postgresql-$v-windows-x64.exe?download=1"
            # Start from nothing before a transfer. A leftover file from an earlier run (or from
            # winget's own failed download) is not a partial download of THIS url, and resuming
            # it with "curl -C -" appends the real file to the wrong bytes: the result is bigger
            # than the original and the installer then dies with "Installer payload
            # initialization failed. This is likely due to an incomplete or corrupt downloaded
            # file." — a message that sends the user looking for a network problem that is not
            # there. The expected size is read first, so a short transfer is caught here instead
            # of three screens later.
            $expected = $null
            try {
                $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 60
                $expected = [int64]$head.Headers['Content-Length']
            } catch { }
            # A file that already matches the declared size is a complete download of THIS url:
            # reusing it saves the transfer without trusting anything unverified.
            if ($expected -and (Test-Path $pgSetup) -and (Get-Item $pgSetup).Length -eq $expected) {
                Log "reusing the verified download of $v"
                $got = $true
                break
            }
            Remove-Item $pgSetup -Force -ErrorAction SilentlyContinue
            if ($curl) {
                $c = Invoke-Native -Exe $curl -ArgList @('-fL', '--retry', '5', '--retry-delay', '5', '--output', $pgSetup, $url)
            } else {
                $c = @{ Code = 1; Text = '' }
                try { Invoke-WebRequest -Uri $url -OutFile $pgSetup -UseBasicParsing -TimeoutSec 3600; $c = @{ Code = 0; Text = '' } }
                catch { $c = @{ Code = 1; Text = "$_" } }
            }
            if ($c.Code -eq 0 -and (Test-Path $pgSetup)) {
                $size = (Get-Item $pgSetup).Length
                if (-not $expected -or $size -eq $expected) { $got = $true; break }
                Warn "the download is incomplete ($size of $expected bytes); trying again"
            }
            Log "that version could not be downloaded: $(Tail $c.Text 200)"
            Remove-Item $pgSetup -Force -ErrorAction SilentlyContinue
        }
        if ($got) {
            $inst = Start-Process -FilePath $pgSetup -ArgumentList @('--mode', 'unattended', '--unattendedmodeui', 'none', '--serverport', $DbPort, '--superpassword', $PgSuperPass) -Wait -PassThru
            if ($inst.ExitCode -ne 0) { Problem "the PostgreSQL installer finished with exit $($inst.ExitCode)." }
            # The silent installer does not always honour --superpassword (the EDB package has
            # ignored it on some releases). Verify it now, while the reason is still obvious, so the
            # next step does not look like a wrong password typed by the user.
            $fresh = Find-Psql
            if ($fresh) {
                $okSuper = $false
                for ($i = 0; $i -lt 15; $i++) {
                    $env:PGPASSWORD = $PgSuperPass
                    $t = Invoke-Native -Exe $fresh -ArgList @('-w', '-U', $PgSuper, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-tAc', 'select 1')
                    if ($t.Code -eq 0) { $okSuper = $true; break }
                    Start-Sleep -Seconds 2
                }
                if ($okSuper) { Log "the PostgreSQL superuser password is the one this installer assigned" }
                else { Warn "the PostgreSQL installer did not apply the superuser password this run passed; it will be reset in the next step" }
            }
        } else {
            Problem "PostgreSQL could not be downloaded (winget and the direct download both failed). Install it yourself from enterprisedb.com and run this installer again - it continues where it stopped."
        }
    }
    # A just-installed PostgreSQL is not on this window's PATH yet, so refresh it before looking.
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
               [System.Environment]::GetEnvironmentVariable('Path','User')
    $psql = Find-Psql
}
# Use the port the server really listens on unless the user pinned one with DB_PORT: a PostgreSQL
# set up earlier may well run on 5433, and talking to the wrong port reports a password error.
$pgDataDir = Find-PgDataDir $psql
if (-not $env:DB_PORT) {
    $confPort = Get-PgConfPort $pgDataDir
    if ($confPort -and $confPort -ne $DbPort) {
        Log "PostgreSQL listens on port $confPort (read from postgresql.conf); using it"
        $DbPort = $confPort
    }
}
$pgService = Find-PgService $pgDataDir
# Python: use an installed 3.10-3.13 if present and working, otherwise install 3.12.
# Detecting Python only by the presence of the 'py' launcher or a 'python' command is not enough:
# on modern Windows the 'python' entry on the PATH is very often a Microsoft Store execution alias
# whose registry shim exists even when no Python is actually installed, so running it prints
# "Python not found ... Microsoft Store" and exits 9009. Before deciding Python must be installed
# we therefore actually run it; if it does not run, winget installs a real copy.
$pyOk = $false
if (Get-Command py -ErrorAction SilentlyContinue) {
    foreach ($v in @('3.12','3.11','3.13','3.10')) {
        $p = Invoke-Native -Exe 'py' -ArgList @("-$v", '--version')
        if ($p.Code -eq 0) { $pyOk = $true; break }
    }
}
if (-not $pyOk) {
    $pyProbe = Invoke-Native -Exe 'python' -ArgList @('--version')
    if ($pyProbe.Code -ne 0) {
        $r = Invoke-Native -Exe 'winget' -ArgList @('install', '-e', '--id', 'Python.Python.3.12', '--accept-source-agreements', '--accept-package-agreements')
        if ($r.Code -ne 0) { Problem "winget could not install Python (exit $($r.Code))." }
    }
}
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path','User')

# --- PostgreSQL role ----------------------------------------------------
Log "Configuring PostgreSQL user '$DbUser'"
# Nothing here is an Odoo password. The role 'odoo' created for the ERP is a database account on
# this PC; it is not an Odoo.com account and Odoo Community needs no registration, so there is no
# Odoo password to remember. The '$PgSuper' superuser password is the one THIS installer assigned
# when it installed PostgreSQL, so the user is never asked to type a value they cannot know.
if (-not $psql) {
    throw "psql was not found, so the '$DbUser' database role cannot be prepared and nothing after this would work. Install PostgreSQL first (for example: winget install -e --id PostgreSQL.PostgreSQL.16) and run this installer again - it continues where it stopped."
}

# Try the account the whole stack will use. On a fresh machine it does not exist yet, so a failing
# probe here is normal and must NOT stop the install. A just-installed server is also still starting
# up, so the probe is repeated for a while - but a rejected password or a missing database is not a
# slow start and ends the wait at once. Every psql call uses -w (never prompt for a password): psql
# would otherwise open its own hidden prompt and sit there forever waiting for a keyboard nobody is
# watching, which is the very freeze this section must not cause.
$probe = $null
for ($i = 0; $i -lt 30; $i++) {
    $env:PGPASSWORD = $DbPassword
    $probe = Invoke-Native -Exe $psql -ArgList @('-w', '-U', $DbUser, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-tAc', 'select 1')
    if ($probe.Code -eq 0) { break }
    if ($probe.Text -match 'authentication failed|no password supplied|does not exist') { break }
    Start-Sleep -Seconds 2
}
if ($probe.Code -eq 0) {
    Log "role '$DbUser' already works"
} else {
    # Superuser access is needed to create (or repair) the role. The password is normally the one
    # this installer assigned, so it is tried automatically - no question is asked. The list also
    # covers the PostgreSQL installers that ship a default of their own, and an account left without
    # a password.
    $supPass = $null
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:PG_SUPERPASS) { $candidates.Add($env:PG_SUPERPASS) }
    foreach ($c in @($PgSuperPass, 'postgres', 'password', 'admin', '')) {
        if (-not $candidates.Contains($c)) { $candidates.Add($c) }
    }
    foreach ($c in $candidates) {
        if ([string]::IsNullOrEmpty($c)) { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
        else { $env:PGPASSWORD = $c }
        $t = Invoke-Native -Exe $psql -ArgList @('-w', '-U', $PgSuper, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-tAc', 'select 1')
        if ($t.Code -eq 0) { $supPass = $c; break }
    }
    if ($null -eq $supPass) {
        # PostgreSQL was set up by something else and its password really is unknown: reset it here
        # instead of stopping the user on a value they do not have.
        Log "The '$PgSuper' password is not a known one; resetting it to the default of this installer"
        $supPass = Reset-PgSuperPassword $pgDataDir $pgService $PgSuperPass
        if ($supPass) { Log "the '$PgSuper' password is now '$supPass'" }
    }
    # Last resort, and it never blocks: three tries, and Enter skips the step. A run driven by
    # environment variables (PG_SUPERPASS set) is unattended and is not prompted at all.
    if ($null -eq $supPass -and -not $env:PG_SUPERPASS) {
        for ($try = 1; $try -le 3; $try++) {
            $askLabel = "PostgreSQL $PgSuper superuser password (press Enter to skip this step)"
            if ($try -gt 1) { $askLabel = "$askLabel (try $try of 3)" }
            try { $pgPass = AskSecret $askLabel '' $null } catch { break }
            if ([string]::IsNullOrWhiteSpace($pgPass)) { break }
            $env:PGPASSWORD = $pgPass
            $t = Invoke-Native -Exe $psql -ArgList @('-w', '-U', $PgSuper, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-tAc', 'select 1')
            if ($t.Code -eq 0) { $supPass = $pgPass; break }
            if ($try -lt 3) { Warn "That is not the '$PgSuper' password (exit $($t.Code)). Press Enter to skip: the install continues and this step can be repeated later." }
        }
    }
    if ($null -eq $supPass) {
        Problem "The '$PgSuper' superuser password of the local PostgreSQL could not be determined, so the '$DbUser' role was not created and the Odoo database step will fail. Nothing was changed: run install.bat as Administrator (the password is then reset automatically) or set PG_SUPERPASS, and run it again - it continues where it stopped."
    } else {
        $env:PGPASSWORD = $supPass
        # This one query tells us both things at once: whether the superuser password works (exit
        # code) and whether the role is already there (its answer).
        $act = Invoke-Native -Exe $psql -ArgList @('-w', '-U', $PgSuper, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-tAc', "select 1 from pg_roles where rolname='$DbUser'")
        if ($act.Code -ne 0) {
            Problem "Cannot connect to PostgreSQL as '$PgSuper' (exit $($act.Code)). Last answer from the database: $(Tail $act.Text 200)"
        } else {
            # Create the role when it is missing, repair the password when it is already there with
            # a different one. The answer is matched, not compared for equality: any noise ahead of
            # the digit still means "the role exists", and CREATE would fail with "role already exists".
            if ($act.Text -match '^\s*1\s*$') { $verb = 'ALTER' } else { $verb = 'CREATE' }
            $done = Invoke-Native -Exe $psql -ArgList @('-w', '-U', $PgSuper, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-c', "$verb ROLE $DbUser LOGIN SUPERUSER PASSWORD '$DbPassword'")
            if ($done.Code -ne 0) {
                Problem "Could not ${verb} the database role '$DbUser' (exit $($done.Code)): $(Tail $done.Text 300)"
            } else {
                # Verify with the credentials the rest of the stack actually uses, so a wrong
                # password is reported here instead of minutes later, in the Odoo setup.
                $env:PGPASSWORD = $DbPassword
                $check = Invoke-Native -Exe $psql -ArgList @('-w', '-U', $DbUser, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-tAc', 'select 1')
                if ($check.Code -eq 0) { Log "role '$DbUser' ready" }
                else { Problem "The role '$DbUser' cannot connect with its password ($(Tail $check.Text 200)), so Odoo will not be able to use the database." }
            }
        }
    }
}
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue

# Odoo 20 runs on Python 3.10-3.13. Python 3.14 and 3.15 already exist and a plain "python" on
# the PATH may point at them; Odoo 20 cannot build its native extensions (lxml, Pillow, psycopg2)
# and will even fail to import them there. A too-new interpreter therefore makes the whole pip
# install abort (and "No module named 'babel'" in the database step) instead of just failing that
# one library, so this rejects it and the virtualenv is always built on a supported release.
function Test-PythonOk([string]$pyExe) {
    # -Stop at the top of the script means a missing interpreter would throw; treat "not found"
    # as "not usable" so the install continues to the supported-Python fallback.
    if (-not (Get-Command $pyExe -ErrorAction SilentlyContinue)) { return $false }
    $ver = (& $pyExe --version 2>&1 | Out-String)
    $m = [regex]::Match($ver, 'Python\s+(\d+)\.(\d+)')
    if (-not $m.Success) { return $false }
    return ([int]$m.Groups[1].Value -eq 3 -and
            [int]$m.Groups[2].Value -ge 10 -and
            [int]$m.Groups[2].Value -le 13)
}

# --- Odoo ---------------------------------------------------------------
Log "Cloning Odoo Community ($OdooBranch)"
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
# The test is on the source, not on the folder: a clone interrupted after git created the target
# directory leaves an empty folder that used to make this step skip forever, and the run then died
# three screens later on a missing requirements.txt.
if (-not (Test-Path (Join-Path $OdooDir 'odoo-bin'))) {
    if (Test-Path $OdooDir) {
        Warn "removing an incomplete Odoo folder left by an earlier run"
        Remove-Item -Recurse -Force $OdooDir -ErrorAction SilentlyContinue
    }
    # A clone that stalls on a slow or throttled connection leaves the folder empty and would stop
    # the install after twenty minutes of nothing. It is therefore bounded: if it does not finish,
    # the branch archive below is one HTTP transfer and gets the source in a couple of minutes.
    $gitOut = Join-Path $InstallRoot 'odoo-clone.log'
    $gp = Start-Process -FilePath 'git' -ArgumentList @('clone', '--depth', '1', '--branch', $OdooBranch, $OdooRepo, $OdooDir) -PassThru -NoNewWindow -RedirectStandardOutput $gitOut -RedirectStandardError "$gitOut.err"
    if (-not $gp.WaitForExit(900000)) {
        try { $gp.Kill() } catch { }
        Warn "the git clone did not finish within fifteen minutes and was stopped"
    }
    if (-not (Test-Path (Join-Path $OdooDir 'odoo-bin'))) {
        Warn "the git clone did not produce the Odoo source; downloading the branch archive instead"
        Remove-Item $OdooDir -Recurse -Force -ErrorAction SilentlyContinue
        $zip = Join-Path $InstallRoot 'odoo-source.zip'
        $src = ($OdooRepo -replace '\.git$', '') + '/archive/refs/heads/' + $OdooBranch + '.zip'
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        $dl = Invoke-Native -Exe 'curl' -ArgList @('-fL', '--retry', '3', '--retry-delay', '5', '-o', $zip, $src)
        if ($dl.Code -ne 0 -or -not (Test-Path $zip)) { throw "Odoo could not be downloaded from $src (exit $($dl.Code)): $(Tail $dl.Text 300)" }
        $tmp = Join-Path $InstallRoot 'odoo-extract'
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $ex = Invoke-Native -Exe 'tar' -ArgList @('-xf', $zip, '-C', $tmp)
        if ($ex.Code -ne 0) { throw "The Odoo archive could not be extracted (exit $($ex.Code)): $(Tail $ex.Text 300)" }
        $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
        if (-not $inner) { throw "The Odoo archive was empty." }
        Move-Item $inner.FullName $OdooDir
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path (Join-Path $OdooDir 'odoo-bin'))) {
        throw "The Odoo source is not in '$OdooDir' after the clone and the archive fallback. Check the network and run install.bat again - it continues where it stopped."
    }
}

Log "Installing Odoo Python requirements in a virtualenv"
$venvDir = Join-Path $InstallRoot 'venv'
$py = Join-Path $venvDir 'Scripts\python.exe'
$venvMade = $false
if (Test-Path $py) {
    # A virtualenv left by an earlier run or by another tool may have been built with a Python
    # newer than Odoo 20 supports (e.g. 3.14/3.15). Reuse it only on a supported release;
    # otherwise recreate it so Odoo 20's native extensions can build.
    if (Test-PythonOk $py) {
        Log "reusing the existing virtualenv"
        $venvMade = $true
    } else {
        Warn "the existing virtualenv uses a Python Odoo 20 does not support; recreating it"
        Remove-Item -Recurse -Force $venvDir -ErrorAction SilentlyContinue
    }
}
if (-not $venvMade) {
    # Prefer the 'py' launcher's supported releases; if none is installed, the plain 'python'
    # on the PATH might be too new, so probe it before trusting it.
    if (Get-Command py -ErrorAction SilentlyContinue) {
        foreach ($v in @('3.12','3.11','3.13','3.10')) {
            $p = Invoke-Native -Exe 'py' -ArgList @("-$v", '-m', 'venv', $venvDir)
            if ($p.Code -eq 0 -and (Test-Path $py)) { $venvMade = $true; Log "using Python $v"; break }
        }
    }
    if (-not $venvMade) {
        # The fallback 'python' might be a too-new release (3.14/3.15) or a Microsoft Store
        # alias; only build with it when it is a supported version.
        if (Test-PythonOk 'python') {
            $p = Invoke-Native -Exe 'python' -ArgList @('-m', 'venv', $venvDir)
            if ($p.Code -eq 0 -and (Test-Path $py)) { $venvMade = $true }
            else { Warn "Could not create the virtualenv (exit $($p.Code)): $($p.Text)" }
        } else {
            Warn "the 'python' on your PATH is newer than Odoo 20 supports; installing Python 3.12"
            $r = Invoke-Native -Exe 'winget' -ArgList @('install', '-e', '--id', 'Python.Python.3.12', '--accept-source-agreements', '--accept-package-agreements')
            if ($r.Code -ne 0) { Problem "winget could not install Python 3.12 (exit $($r.Code))." }
            foreach ($v in @('3.12','3.11','3.13','3.10')) {
                $p = Invoke-Native -Exe 'py' -ArgList @("-$v", '-m', 'venv', $venvDir)
                if ($p.Code -eq 0 -and (Test-Path $py)) { $venvMade = $true; break }
            }
        }
    }
}
$py = Join-Path $venvDir 'Scripts\python.exe'
if (-not (Test-Path $py)) {
    throw "No usable Python was found, so Odoo cannot be installed. On Windows 11 the 'python' on your PATH is often a Microsoft Store entry that opens the store instead of running Python (it exits 9009); install real Python 3.10-3.13 from python.org, confirm 'py' works in a command prompt, then run install.bat again."
}
$up = Invoke-Native -Exe $py -ArgList @('-m', 'pip', 'install', '--upgrade', 'pip')
if ($up.Code -ne 0) { Warn "pip upgrade finished with exit $($up.Code) (this is often only a warning)." }
# The two optional, build-heavy libraries below need native headers a plain Windows machine does
# not have: OpenLDAP for python-ldap (LDAP logins) and freetype/cairo for reportlab's
# rl-renderPM (image-based PDF rendering). Neither ships a prebuilt wheel for every Python, so pip
# aborts trying to compile it, and that failure used to cascade into the database step. Both are
# optional in Odoo and are not needed for the data operations this tool performs, so they are
# skipped on Windows. reportlab's pure-Python core is kept so the database still builds.
$reqWin = Get-Content (Join-Path $OdooDir 'requirements.txt') |
          Where-Object { $_ -notmatch '^\s*(?:python-ldap|rl-renderPM)' }
$reqWin | Set-Content (Join-Path $InstallRoot 'requirements-win.txt') -Encoding ASCII
$rp = Invoke-Native -Exe $py -ArgList @('-m', 'pip', 'install', '-r', (Join-Path $InstallRoot 'requirements-win.txt'))
if ($rp.Code -ne 0) { Problem "pip install finished with exit $($rp.Code); last messages: $(Tail $rp.Text 400)" }

Log "Creating the Odoo database with the base modules"
# --db_host forces TCP password auth; the UNIX-socket shortcut does not exist on Windows.
$addons = Join-Path $OdooDir 'addons'
$db = Invoke-Native -Exe $py -ArgList @(
    (Join-Path $OdooDir 'odoo-bin'), '-d', 'odoo_agent', '--db_host=127.0.0.1',
    '--db_port', $DbPort, '--db_user', $DbUser, '--db_password', $DbPassword,
    "--addons-path=$addons", '-i', 'base', '--stop-after-init', '--without-demo')
if ($db.Code -eq 0) { Log "database 'odoo_agent' created" }
else { Problem "Odoo could not create the database (exit $($db.Code)). Last messages: $(Tail $db.Text 400). Without a database the assistant cannot read or change any data." }

# --- Admin credentials + API key ----------------------------------------
# Reuse the API key from a previous install instead of creating a new one.
$odooJsonPath = Join-Path $AbDir 'PersistentData\odoo.json'
$existingKey = ''
if (Test-Path $odooJsonPath) {
    try { $existingKey = (Get-Content -Raw $odooJsonPath | ConvertFrom-Json).apiKey } catch {}
}
$OdooApiKey = $existingKey
if ([string]::IsNullOrWhiteSpace($existingKey)) {
Log "Creating the Odoo API key for the admin user"
$env:ODOO_ADMIN_EMAIL = $AdminEmail
$env:ODOO_ADMIN_PASS  = $AdminPass
$env:ODOO_COMPANY_NAME = $Company
$keyScript = @'
import os
admin = env["res.users"].browse(2)
# Set the admin credentials only on the first install; on a re-run keep the existing ones.
if admin.login == 'admin':
    email = os.environ["ODOO_ADMIN_EMAIL"]
    admin.write({"login": email, "email": email, "password": os.environ["ODOO_ADMIN_PASS"]})
else:
    found = env["res.users"].search([("login", "=", os.environ["ODOO_ADMIN_EMAIL"])], limit=1)
    if found:
        admin = found
# The company name asked in the wizard has to reach the database: without this the ERP stays
# "My Company" and every printed document carries the installer's placeholder.
company_name = os.environ.get("ODOO_COMPANY_NAME", "").strip()
company = env["res.company"].browse(1)
if company_name and company.name != company_name:
    company.write({"name": company_name})
    if company.partner_id:
        company.partner_id.write({"name": company_name})
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
if (Test-Path $outPath) {
    # odoo-bin shell writes nothing (the database step failed, or Odoo was unreachable), so the
    # redirected file can exist but be empty; Get-Content -Raw then returns $null and .Trim() used
    # to throw "You cannot call a method on a null-valued expression". Treat empty as "no key".
    $rawKey = Get-Content -Raw $outPath
    if ($rawKey) { $OdooApiKey = $rawKey.Trim() }
}
if ([string]::IsNullOrWhiteSpace($OdooApiKey)) {
    Problem "Could not auto-create the API key. Create it in Odoo (Preferences -> Account Security -> New API Key) and put it in $odooJsonPath, otherwise the assistant cannot call Odoo."
}
} else {
    Log "Reusing the existing Odoo API key"
}

# --- AgentBridge + OdooTool plugin --------------------------------------
New-Item -ItemType Directory -Force -Path $AbDir | Out-Null
if (Test-Path (Join-Path $AbDir 'agent.exe')) {
    Log "AgentBridge already installed; skipping download"
} else {
Log "Downloading AgentBridge"
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
        $d = Invoke-Native -Exe $curl -ArgList @('-fL', '--retry', '5', '--retry-delay', '5', '-C', '-', '--output', $pkg, $url)
        if ($d.Code -eq 0) { break }
        if ($attempt -ge 10) { throw "AgentBridge download failed after $attempt attempts (exit $($d.Code)): $($d.Text)" }
        Warn "download interrupted; resuming (attempt $attempt)..."
        Start-Sleep -Seconds 5
    }
} else {
    Invoke-WebRequest -Uri $url -OutFile $pkg -UseBasicParsing -TimeoutSec 7200
}
# Verify the archive before extracting: a truncated or resumed transfer is corrupt.
$verified = $false
for ($i = 0; $i -lt 2; $i++) {
    $t = Invoke-Native -Exe 'tar' -ArgList @('-tzf', $pkg)
    if ($t.Code -eq 0) { $verified = $true; break }
    Warn "AgentBridge archive is corrupt; downloading again from scratch"
    Remove-Item $pkg -Force -ErrorAction SilentlyContinue
    if ($curl) { $d2 = Invoke-Native -Exe $curl -ArgList @('-fL', '--retry', '5', '--retry-delay', '5', '--output', $pkg, $url) }
    else { Invoke-WebRequest -Uri $url -OutFile $pkg -UseBasicParsing -TimeoutSec 7200 }
    if ($curl -and $d2.Code -ne 0) { break }
}
if (-not $verified) { throw "AgentBridge archive could not be verified (download corrupt)" }
$t = Invoke-Native -Exe 'tar' -ArgList @('-xzf', $pkg, '-C', $AbDir)
if ($t.Code -ne 0) { throw "AgentBridge extraction failed (exit $($t.Code)): $($t.Text)" }
if (-not (Test-Path (Join-Path $AbDir 'agent.exe'))) { throw "AgentBridge binary missing after extraction" }
}

# --- OdooTool plugin: AgentBridge loads plugins from Tools/ next to the exe ---
Log "Installing the OdooTool plugin into Tools\OdooTool"
$toolsDir = Join-Path $AbDir 'Tools\OdooTool'
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
try {
    $idx = Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/graphene.odootool/index.json' -TimeoutSec 30
    $ver = @($idx.versions)[-1]
    $nupkg = Join-Path $env:TEMP "graphene.odootool.$ver.nupkg"
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/graphene.odootool/$ver/graphene.odootool.$ver.nupkg" `
        -OutFile $nupkg -UseBasicParsing -TimeoutSec 60
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
    $entry = $zip.Entries | Where-Object { $_.FullName -like 'lib/*/OdooTool.dll' } | Select-Object -First 1
    if (-not $entry) { throw "OdooTool.dll not found in the package" }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $toolsDir 'OdooTool.dll'), $true)
    $xmlEntry = $zip.Entries | Where-Object { $_.FullName -like 'lib/*/OdooTool.xml' } | Select-Object -First 1
    if ($xmlEntry) { [IO.Compression.ZipFileExtensions]::ExtractToFile($xmlEntry, (Join-Path $toolsDir 'OdooTool.xml'), $true) }
    $zip.Dispose()
    Log "OdooTool plugin installed (version $ver)"
} catch {
    Problem ("Could not install the OdooTool plugin: " + $_.Exception.Message)
}

Log "Configuring AgentBridge: the OdooTool plugin and the Odoo address"
$cfg = Join-Path $AbDir 'PersistentData'
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
# providers.json is an ARRAY of provider objects, and the field names are the ones the
# engine reads (ProviderName, BaseAddress, EndPoint, ModelName, ApiKey). A different shape
# is not a configuration error the app reports: it silently falls back to the factory list,
# so the assistant would answer with a provider the user never chose. Only written when an
# unattended run supplied LLM_BASE_URL; otherwise the first start asks (see the note above).
if ($LlmUrl -and -not (Test-Path (Join-Path $cfg 'providers.json'))) {
    $base = $LlmUrl.TrimEnd('/') + '/'
    # ".../v1" already carries the version segment: only the call path is missing.
    $endPoint = if ($LlmUrl.TrimEnd('/') -match '/v1$') { 'chat/completions' } else { 'v1/chat/completions' }
    $modelName = if ($LlmModel) { $LlmModel } else { 'default' }
    @"
[
  {
    "ProviderName": "OdooStackLLM",
    "IsDefault": true,
    "Protocol": "OpenAI",
    "CacheType": "PrefixCache",
    "ModelName": "$modelName",
    "ApiKey": "$LlmKey",
    "BaseAddress": "$base",
    "EndPoint": "$endPoint",
    "Timeout": "00:05:00",
    "ContextWindow": 128000
  }
]
"@ | Set-Content -Path (Join-Path $cfg 'providers.json') -Encoding UTF8
    Log "AI provider written to providers.json (unattended install)"
} elseif (Test-Path (Join-Path $cfg 'providers.json')) {
    Log "Keeping the existing providers.json"
} else {
    Log "The AI provider will be asked by the assistant on its first start"
}
@"
{ "baseUrl": "http://localhost:$OdooPort", "apiKey": "$OdooApiKey", "database": "odoo_agent" }
"@ | Set-Content -Path (Join-Path $cfg 'odoo.json') -Encoding UTF8

# The plugin being installed is not the same as the plugin being USED. AgentBridge resolves the
# tools of a chat from the agent set (a preset id plus an optional custom list) and the
# default preset contains only the file, web and git tools. Without this file the assistant is
# installed, connected and ready — and answers "there are no Odoo tools in this environment",
# which is the most confusing possible outcome for a user who has just run one command.
# The toolset is PersistentData configuration, so writing it here is the installer's job.
$toolset = Join-Path $cfg 'toolset.json'
if (-not (Test-Path $toolset)) {
    @"
{ "agent_set": "default-agent", "tools": ["FileTool", "WebTool", "GitTool", "OdooTool"] }
"@ | Set-Content -Path $toolset -Encoding UTF8
    Log "OdooTool enabled in the assistant's tool set"
} else {
    Log "Keeping the existing toolset.json"
}

# --- Firewall -----------------------------------------------------------
Log "Opening TCP port $OdooPort in Windows Firewall"
# Kept inline instead of Invoke-Native: netsh needs the rule name as one token with its own
# quotes, and the array form would mangle that quoting. Dropping to 'Continue' is enough to
# stop a "no such rule" message on stderr from killing the install.
$savedPref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
netsh advfirewall firewall delete rule name="Odoo $OdooPort" 2>&1 | Out-Null
netsh advfirewall firewall add rule name="Odoo $OdooPort" dir=in action=allow protocol=TCP localport=$OdooPort 2>&1 | Out-Null
$rc = $LASTEXITCODE
$ErrorActionPreference = $savedPref
if ($rc -ne 0) { Warn "Could not add the firewall rule (exit $rc) - run the installer as Administrator if you need remote access." }

Log "Starting Odoo on port $OdooPort"
Start-Process -FilePath $py -ArgumentList @(
    (Join-Path $OdooDir 'odoo-bin'), '-d', 'odoo_agent', '--db_host=127.0.0.1',
    '--db_port', $DbPort, '--db_user', $DbUser, '--db_password', $DbPassword,
    "--addons-path=$OdooDir\addons", "--http-port=$OdooPort", '--http-interface=0.0.0.0'
) -RedirectStandardOutput (Join-Path $InstallRoot 'odoo.log') -WindowStyle Hidden

# Wait until Odoo answers, so "Done" is only printed for a working stack.
$up = $false
for ($i = 0; $i -lt 30; $i++) {
    try { if ((Invoke-WebRequest "http://localhost:$OdooPort/web/login" -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) { $up = $true; break } } catch {}
    Start-Sleep -Seconds 2
}
if (-not $up) { Problem "Odoo did not answer on port $OdooPort after 60s; check $InstallRoot\odoo.log." }

# --- One-click launcher + shortcut -------------------------------------
# Launcher contract: start Odoo, start AgentBridge (with the OdooTool plugin already in
# Tools/) if the chat is not answering, wait for the chat and open it in the default browser.
# Do not reduce this to an Odoo-only shortcut or open Odoo's login page instead of the chat.
Log "Creating the one-click launcher and shortcuts"
$launcherTemplate = @'
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$py = Join-Path $root 'venv\Scripts\python.exe'
$odoo = Join-Path $root 'odoo\odoo-bin'
$ab = Join-Path $root 'agentbridge\agent.exe'
$port = 8069
$officePort = 5290
$officeUrl = "http://localhost:$officePort/OfficeManager"
$dbPort = __DB_PORT__
$dbUser = __DB_USER__
$dbPass = __DB_PASS__
function Test-Odoo { (Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded }
function Test-Assistant { try { (Invoke-WebRequest $officeUrl -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } catch { $false } }
if (-not (Test-Odoo)) {
    Start-Process -FilePath $py -ArgumentList @(
        $odoo, '-d', 'odoo_agent', '--db_host=127.0.0.1', "--db_port=$dbPort",
        '--db_user', $dbUser, '--db_password', $dbPass,
        ("--addons-path=" + (Join-Path $root 'odoo\addons')), "--http-port=$port", '--http-interface=0.0.0.0'
    ) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $root 'odoo.log')
    for ($i = 0; $i -lt 40; $i++) { if (Test-Odoo) { break }; Start-Sleep -Seconds 2 }
}
# Open the browser to the assistant's own chat (the AI office), NOT to Odoo's web login:
# localhost:8069 is the ERP's back-end login page, and opening it is what made the shortcut
# show a login screen instead of the assistant from the second launch on. The office chat is
# served by the assistant on port 5290 and ships in the AgentBridge release. Start the
# assistant first (only if the chat is not already answering), then wait for it, then open
# the window, so it shows the assistant instead of a "cannot reach" page.
if (-not (Test-Assistant) -and (Test-Path $ab)) {
    Start-Process -FilePath $ab -WorkingDirectory (Join-Path $root 'agentbridge')
}
for ($i = 0; $i -lt 40; $i++) { if (Test-Assistant) { break }; Start-Sleep -Seconds 3 }
if (Test-Assistant) {
    Start-Process $officeUrl
} else {
    Write-Host "The assistant did not start on port $officePort. Run 'agent.exe' in the folder"
    Write-Host "$root\agentbridge to bring it up, then double-click the 'AI Odoo' icon again."
}
'@
$launcherPath = Join-Path $InstallRoot 'start.ps1'
# Put the real role name and password in, quoted so nothing can break or be injected when they
# contain $ ` " ' or spaces (a custom DB_USER / DB_PASSWORD used to break the shortcut).
$launcherText = $launcherTemplate.Replace('__DB_PORT__', [string]$DbPort).Replace('__DB_USER__', (PsSingleQuote $DbUser)).Replace('__DB_PASS__', (PsSingleQuote $DbPassword))
[System.IO.File]::WriteAllText($launcherPath, $launcherText, (New-Object System.Text.UTF8Encoding($false)))

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
# A bare "Done." over a stack that never actually came up is what left the user in issue #3 with
# no idea what had failed. Anything collected during the run is listed here instead, so the last
# thing on screen says plainly whether the result is usable and what is standing in the way.
if ($Problems.Count -gt 0) {
    Log "Finished with $($Problems.Count) problem(s). Please read this before using the assistant."
    Write-Host "  The installation did not fully work. What was reported:"
    foreach ($p in $Problems) { Write-Host "    - $p" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host "  Fix what is listed above and run install.bat again: it continues where it stopped"
    Write-Host "  and reuses everything that is already there."
} else {
    Log 'Done.'
}
Write-Host "  HOW TO START:"
Write-Host "    Double-click the 'AI Odoo' icon on the Desktop (or in the Start Menu)."
Write-Host "    It opens the assistant in the browser: that is where you talk to it."
Write-Host "    Type a request there such as 'list the customers'."
Write-Host "    The database and the admin user are already created: do not run the Odoo database manager."
Write-Host "    If it appears, the install did not complete: run install.bat again."
Write-Host "    Odoo 20 first steps: https://www.odoo.com/documentation/20.0/applications.html"
Write-Host ''
Write-Host "  Assistant (talk to it here):  http://localhost:5290/OfficeManager"
Write-Host "  Odoo (the data behind it):    http://localhost:$OdooPort   login $AdminEmail / $AdminPass"
Write-Host "  PostgreSQL:     superuser '$PgSuper' password '$PgSuperPass' on port $DbPort (set by this installer)"
Write-Host "  Install root:   $InstallRoot"
Write-Host "  AgentBridge:    $AbDir"
Write-Host "  Firewall:       TCP $OdooPort open"
Write-Host ''
Write-Host "  Manual start, if you ever need it:"
Write-Host "    Odoo:      $py `"$OdooDir\odoo-bin`" -d odoo_agent --db_port $DbPort"
Write-Host "    Assistant: $AbDir\agent.exe"

# Users reached a working stack and still did not know what to do next, so put the vendor's
# first steps in front of them, after the credentials above have been printed. The URL is
# printed too, for headless runs and for users who close the tab.
if ($Problems.Count -eq 0) {
    try {
        Start-Process 'https://www.odoo.com/documentation/20.0/applications.html'
        Write-Host "    (Opened the Odoo 20 first-steps page in your default browser.)"
    } catch {
        Write-Host "    (Could not open the browser - use the URL above.)" -ForegroundColor Yellow
    }
}
