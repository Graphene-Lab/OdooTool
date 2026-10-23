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

# --- Wizard (environment variables make it unattended) ------------------
Log "Questions"
$Company    = Ask "Company name" "My Company" 'COMPANY_NAME'
$AdminEmail = Ask "Odoo admin email" "admin@example.com" 'ADMIN_EMAIL'
$AdminPass  = AskSecret "Odoo admin password" (GeneratePassword) 'ADMIN_PASS'
$LlmUrl     = Ask "LLM provider base URL (OpenAI-compatible)" "http://192.168.43.253:8741/v1" 'LLM_BASE_URL'
$LlmKey     = AskSecret "LLM provider API key" "" 'LLM_KEY'
$LlmModel   = Ask "LLM model name" "halogen-qwen3.8-flash-next" 'LLM_MODEL'

# --- Prerequisites (install only what is missing) -----------------------
Log "Checking PostgreSQL, Python and Git"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $r = Invoke-Native -Exe 'winget' -ArgList @('install', '-e', '--id', 'Git.Git', '--accept-source-agreements', '--accept-package-agreements')
    if ($r.Code -ne 0) { Problem "winget could not install Git (exit $($r.Code)). The Odoo download needs Git; install it yourself if it is missing." }
}
$psql = (Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
         Select-Object -First 1).FullName
# psql can also live somewhere else (a non-default install folder, a portable install), so PATH
# is checked too instead of assuming the default prefix.
if (-not $psql) { $psql = (Get-Command psql -ErrorAction SilentlyContinue).Source }
if (-not $psql) {
    Write-Host "PostgreSQL is not installed. winget installs it now; its own installer asks you to choose the password for the '$PgSuper' account. Remember what you type - the next question needs that same password."
    $r = Invoke-Native -Exe 'winget' -ArgList @('install', '-e', '--id', 'PostgreSQL.PostgreSQL.16', '--accept-source-agreements', '--accept-package-agreements')
    if ($r.Code -ne 0) { Problem "winget could not install PostgreSQL (exit $($r.Code))." }
    # A just-installed PostgreSQL is not on this window's PATH yet, so refresh it before looking.
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
               [System.Environment]::GetEnvironmentVariable('Path','User')
    $psql = (Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
             Select-Object -First 1).FullName
    if (-not $psql) { $psql = (Get-Command psql -ErrorAction SilentlyContinue).Source }
}
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
if (-not $psql) {
    throw "psql was not found, so the '$DbUser' database role cannot be prepared and nothing after this would work. Install PostgreSQL first (for example: winget install -e --id PostgreSQL.PostgreSQL.16), choose a password for the '$PgSuper' account and remember it, then run this installer again - it continues where it stopped."
}

# Try the account the whole stack will use. On a fresh machine it does not exist yet, so a
# failing probe here is normal and must NOT stop the install: this exact line used to kill
# the whole script (NativeCommandError) before the question below could even be asked.
# psql exits 0 only when it really connected, so the exit code is the signal we trust.
$env:PGPASSWORD = $DbPassword
$probe = Invoke-Native -Exe $psql -ArgList @('-U', $DbUser, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-tAc', 'select 1')
if ($probe.Code -eq 0) {
    Log "role '$DbUser' already works"
} else {
    # The role is not usable yet, so the '$PgSuper' superuser password is needed: the one that was
    # typed when PostgreSQL was installed on this machine. Two things used to make this hopeless to
    # read. First, "$act.Code" inside a double-quoted string does NOT expand the Code property - it
    # expands the whole object, so the message printed "@{Code=2; Text=...}.Code" instead of "2".
    # Second, a single wrong answer aborted everything and the user had to start from scratch.
    # Now it asks again, up to 3 times, and says in plain words what happened. With PG_SUPERPASS
    # set (unattended run) there is no prompt and only one attempt: retrying the same value twice
    # cannot turn a wrong password into a right one.
    $act = $null
    $maxTries = if ($env:PG_SUPERPASS) { 1 } else { 3 }
    for ($try = 1; $try -le $maxTries; $try++) {
        $askLabel = "PostgreSQL '$PgSuper' superuser password"
        if ($try -gt 1) { $askLabel = "PostgreSQL '$PgSuper' superuser password (try $try of $maxTries)" }
        $pgPass = AskSecret $askLabel '' 'PG_SUPERPASS'
        if ([string]::IsNullOrWhiteSpace($pgPass)) { break }
        $env:PGPASSWORD = $pgPass
        # This one query tells us both things at once: whether the '$PgSuper' password works
        # (exit code) and whether the role is already there (its answer).
        $act = Invoke-Native -Exe $psql -ArgList @('-U', $PgSuper, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-tAc', "select 1 from pg_roles where rolname='$DbUser'")
        if ($act.Code -eq 0) { break }
        if ($try -lt $maxTries) {
            Warn "That is not the '$PgSuper' password (exit $($act.Code)): PostgreSQL answered 'password authentication failed'. It is the password that was chosen when PostgreSQL was installed on this PC - it is not the Odoo admin password you just typed above."
        }
    }
    if ($null -eq $act) {
        throw "No '$PgSuper' password was given, so the '$DbUser' role cannot be prepared. Run the installer again and type the password for '$PgSuper' (the one chosen when PostgreSQL was installed), or have someone create the role for you with: CREATE ROLE $DbUser LOGIN SUPERUSER PASSWORD '$DbPassword';"
    }
    if ($act.Code -ne 0) {
        throw "Cannot connect to PostgreSQL as '$PgSuper' (exit $($act.Code)). Last answer from the database: $(Tail $act.Text 300). Type the correct '$PgSuper' password and run the installer again - it continues where it stopped. If nobody knows that password it can be reset: stop the PostgreSQL Windows service, edit its pg_hba.conf so that connections from 127.0.0.1 use 'trust' instead of 'scram-sha-256', start the service again, connect with 'psql -U $PgSuper -h 127.0.0.1' (no password is asked then), run ALTER USER $PgSuper PASSWORD 'the password you want';, then put pg_hba.conf back to 'scram-sha-256' and restart the service."
    }
    # Create the role when it is missing, repair the password when it is already there with
    # a different one. Both cases used to break the Odoo database step some minutes later.
    # The answer is matched, not compared for equality: any noise ahead of the digit still means
    # "the role exists", and picking CREATE there would fail with "role already exists".
    if ($act.Text -match '^\s*1\s*$') { $verb = 'ALTER' } else { $verb = 'CREATE' }
    $done = Invoke-Native -Exe $psql -ArgList @('-U', $PgSuper, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-c', "$verb ROLE $DbUser LOGIN SUPERUSER PASSWORD '$DbPassword'")
    if ($done.Code -ne 0) {
        throw "Could not ${verb} the database role '$DbUser' (exit $($done.Code)): $(Tail $done.Text 300)"
    }
    # Verify with the credentials the rest of the stack actually uses, so a wrong password is
    # reported here instead of minutes later, in the middle of the Odoo setup.
    $env:PGPASSWORD = $DbPassword
    $check = Invoke-Native -Exe $psql -ArgList @('-U', $DbUser, '-h', '127.0.0.1', '-p', $DbPort, '-d', 'postgres', '-tAc', 'select 1')
    if ($check.Code -eq 0) {
        Log "role '$DbUser' ready"
    } else {
        throw "The role '$DbUser' still cannot connect to the database ($(Tail $check.Text 200)). Everything after this needs that role, so the install stops here. Check the password and run the installer again."
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
Write-Host "  Admin:          $AdminEmail / $AdminPass"
Write-Host "  Install root:   $InstallRoot"
Write-Host "  AgentBridge:    $AbDir"
Write-Host "  Firewall:       TCP $OdooPort open"
Write-Host ''
Write-Host "  Manual start, if you ever need it:"
Write-Host "    Odoo:      $py `"$OdooDir\odoo-bin`" -d odoo_agent --db_port $DbPort"
Write-Host "    Assistant: $AbDir\agent.exe"
