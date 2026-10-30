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
        Warn "Windows will ask for Administrator rights: changing the local PostgreSQL '$PgSuper' password needs them."
        try { Start-Process -FilePath 'powershell' -ArgumentList $argList -Verb RunAs -Wait | Out-Null }
        catch { return $null }
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
$LlmUrl     = Ask "LLM provider base URL (OpenAI-compatible)" "http://192.168.43.253:8741/v1" 'LLM_BASE_URL'
$LlmKey     = AskSecret "LLM provider API key" "" 'LLM_KEY'
$LlmModel   = Ask "LLM model name" "halogen-qwen3.8-flash-next" 'LLM_MODEL'

# --- Prerequisites (install only what is missing) -----------------------
Log "Checking PostgreSQL, Python and Git"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $r = Invoke-Native -Exe 'winget' -ArgList @('install', '-e', '--id', 'Git.Git', '--accept-source-agreements', '--accept-package-agreements')
    if ($r.Code -ne 0) { Problem "winget could not install Git (exit $($r.Code)). The Odoo download needs Git; install it yourself if it is missing." }
}
$psql = Find-Psql
if (-not $psql) {
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
            if ($curl) {
                $c = Invoke-Native -Exe $curl -ArgList @('-fL', '--retry', '5', '--retry-delay', '5', '-C', '-', '--output', $pgSetup, $url)
            } else {
                $c = @{ Code = 1; Text = '' }
                try { Invoke-WebRequest -Uri $url -OutFile $pgSetup -UseBasicParsing -TimeoutSec 3600; $c = @{ Code = 0; Text = '' } }
                catch { $c = @{ Code = 1; Text = "$_" } }
            }
            if ($c.Code -eq 0 -and (Test-Path $pgSetup) -and (Get-Item $pgSetup).Length -gt 100MB) { $got = $true; break }
            Log "that version could not be downloaded: $(Tail $c.Text 200)"
            Remove-Item $pgSetup -Force -ErrorAction SilentlyContinue
        }
        if ($got) {
            $inst = Start-Process -FilePath $pgSetup -ArgumentList @('--mode', 'unattended', '--unattendedmodeui', 'none', '--serverport', $DbPort, '--superpassword', $PgSuperPass) -Wait -PassThru
            if ($inst.ExitCode -ne 0) { Problem "the PostgreSQL installer finished with exit $($inst.ExitCode)." }
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
# Python: use an installed 3.10-3.13 if present, otherwise install 3.12.
$pyOk = $false
if (Get-Command py -ErrorAction SilentlyContinue) {
    foreach ($v in @('3.12','3.11','3.13','3.10')) {
        $p = Invoke-Native -Exe 'py' -ArgList @("-$v", '--version')
        if ($p.Code -eq 0) { $pyOk = $true; break }
    }
}
if (-not $pyOk -and -not (Get-Command python -ErrorAction SilentlyContinue)) {
    $r = Invoke-Native -Exe 'winget' -ArgList @('install', '-e', '--id', 'Python.Python.3.12', '--accept-source-agreements', '--accept-package-agreements')
    if ($r.Code -ne 0) { Problem "winget could not install Python (exit $($r.Code))." }
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

# --- Odoo ---------------------------------------------------------------
Log "Cloning Odoo Community ($OdooBranch)"
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
if (-not (Test-Path $OdooDir)) {
    $c = Invoke-Native -Exe 'git' -ArgList @('clone', '--depth', '1', '--branch', $OdooBranch, $OdooRepo, $OdooDir)
    if ($c.Code -ne 0) { Problem "git clone finished with exit $($c.Code): $(Tail $c.Text 300). Without the Odoo source there is nothing to install." }
}

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
            $p = Invoke-Native -Exe 'py' -ArgList @("-$v", '-m', 'venv', $venvDir)
            if ($p.Code -eq 0 -and (Test-Path $py)) { $venvMade = $true; Log "using Python $v"; break }
        }
    }
    if (-not $venvMade) {
        $p = Invoke-Native -Exe 'python' -ArgList @('-m', 'venv', $venvDir)
        if ($p.Code -ne 0) { Warn "Could not create the virtualenv (exit $($p.Code)): $($p.Text)" }
    }
}
$py = Join-Path $venvDir 'Scripts\python.exe'
if (-not (Test-Path $py)) {
    throw "No usable Python was found, so Odoo cannot be installed. Install Python 3.10, 3.11, 3.12 or 3.13 (check 'py' works in a command prompt) and run the installer again."
}
$up = Invoke-Native -Exe $py -ArgList @('-m', 'pip', 'install', '--upgrade', 'pip')
if ($up.Code -ne 0) { Warn "pip upgrade finished with exit $($up.Code) (this is often only a warning)." }
# python-ldap has no Windows wheel and needs OpenLDAP headers; LDAP auth is optional in
# Odoo, so exclude it — otherwise pip fails on a plain Windows machine.
$reqWin = Get-Content (Join-Path $OdooDir 'requirements.txt') |
          Where-Object { $_ -notmatch '^\s*python-ldap' }
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

Log "Configuring AgentBridge with the LLM provider and the OdooTool plugin"
$cfg = Join-Path $AbDir 'PersistentData'
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
if (-not (Test-Path (Join-Path $cfg 'providers.json'))) {
@"
{ "providers": [ { "name": "OdooStackLLM", "baseUrl": "$LlmUrl", "apiKey": "$LlmKey", "model": "$LlmModel" } ] }
"@ | Set-Content -Path (Join-Path $cfg 'providers.json') -Encoding UTF8
} else { Log "Keeping the existing providers.json" }
@"
{ "baseUrl": "http://localhost:$OdooPort", "apiKey": "$OdooApiKey", "database": "odoo_agent" }
"@ | Set-Content -Path (Join-Path $cfg 'odoo.json') -Encoding UTF8

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
Log "Creating the one-click launcher and shortcuts"
$launcherTemplate = @'
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$py = Join-Path $root 'venv\Scripts\python.exe'
$odoo = Join-Path $root 'odoo\odoo-bin'
$ab = Join-Path $root 'agentbridge\agent.exe'
$port = 8069
$dbPort = __DB_PORT__
$dbUser = __DB_USER__
$dbPass = __DB_PASS__
function Test-Odoo { (Test-NetConnection -ComputerName 127.0.0.1 -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded }
if (-not (Test-Odoo)) {
    Start-Process -FilePath $py -ArgumentList @(
        $odoo, '-d', 'odoo_agent', '--db_host=127.0.0.1', "--db_port=$dbPort",
        '--db_user', $dbUser, '--db_password', $dbPass,
        ("--addons-path=" + (Join-Path $root 'odoo\addons')), "--http-port=$port", '--http-interface=0.0.0.0'
    ) -WindowStyle Hidden -RedirectStandardOutput (Join-Path $root 'odoo.log')
    for ($i = 0; $i -lt 40; $i++) { if (Test-Odoo) { break }; Start-Sleep -Seconds 2 }
}
Start-Process "http://localhost:$port"
if (Test-Path $ab) { Start-Process -FilePath $ab -WorkingDirectory (Join-Path $root 'agentbridge') }
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
Write-Host "    It starts Odoo, opens it in the browser and launches the assistant."
Write-Host "    Then type a request such as 'list the customers'."
Write-Host ''
Write-Host "  Odoo URL:       http://localhost:$OdooPort"
Write-Host "  Odoo login:     $AdminEmail / $AdminPass   (local to this PC - no Odoo account needed)"
Write-Host "  PostgreSQL:     superuser '$PgSuper' password '$PgSuperPass' on port $DbPort (set by this installer)"
Write-Host "  Install root:   $InstallRoot"
Write-Host "  AgentBridge:    $AbDir"
Write-Host "  Firewall:       TCP $OdooPort open"
Write-Host ''
Write-Host "  Manual start, if you ever need it:"
Write-Host "    Odoo:      $py `"$OdooDir\odoo-bin`" -d odoo_agent --db_port $DbPort"
Write-Host "    Assistant: $AbDir\agent.exe"
