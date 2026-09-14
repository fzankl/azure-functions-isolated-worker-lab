<#
.SYNOPSIS
    Builds every locally runnable tag and checks the documented response.

.DESCRIPTION
    Walks the tag list in migration order, builds each tag in its own git
    worktree, and - for tags that are expected to run - starts the function
    host and asserts the response documented in docs/. A failing tag does not
    stop the run. The script exits non-zero if any check failed.

    If this passes, every tagged state behaves as documented.

    Isolated states are started with 'dotnet run', the way the isolated guide
    documents from Worker.Sdk 2.0.0 onward. Only baseline-inprocess uses
    'func start': that project is in-process and therefore a library, which
    'dotnet run' refuses. The two are told apart by the build SDK in the
    project file, not by tag name.

    aspire-optional is deliberately not checked: it needs the Aspire AppHost
    and is not part of the migration sequence.

    Not maintained as a general-purpose tool. It assumes Windows with Docker
    Desktop running, plus func and the .NET SDKs listed in README.md.

    PowerShell rather than a shell script on purpose: stopping the host
    reliably means dealing with several processes at once, and the port is not
    always held by the one that started them.

.PARAMETER Tags
    Optional. Check only these tags instead of the full list.

.EXAMPLE
    .\scripts\verify-all.ps1

.EXAMPLE
    .\scripts\verify-all.ps1 baseline-inprocess serializer-attributes-fixed-frombody
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Tags
)

$ErrorActionPreference = 'Continue'

$RepoRoot    = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
$ProjectRel  = 'src\OrderProcessor'
$Port        = 7071
$BaseUrl     = "http://localhost:$Port"
$Payload     = '{"OrderId":"ORD-5","customer_name":"Ada","Quantity":1}'

# The in-process response body, measured against host 4.851.100.26305.
# It is the contract the migration must not change, and every resolution of
# the serializer case has to reproduce it exactly. Note the camelCase: the
# in-process host serializes with Newtonsoft and a camelCase naming policy.
# Only the attributed customer_name keeps its form. See
# docs/baseline-inprocess.md.
$BaselineBody = '{"orderId":"ORD-5","customer_name":"Ada","quantity":1}'

$script:Failed = $false
$script:Checked = 0

# Resolve func explicitly. An npm install of Core Tools puts three shims on
# PATH: func.ps1, func.cmd and an extensionless shell script. Start-Process
# would pick the latter and fail with "not a valid Win32 application".
# func.exe covers installs without npm (MSI, winget).
$FuncCommand = (Get-Command 'func.cmd' -ErrorAction SilentlyContinue).Source
if (-not $FuncCommand) { $FuncCommand = (Get-Command 'func.exe' -ErrorAction SilentlyContinue).Source }

$Scratch  = Join-Path ([System.IO.Path]::GetTempPath()) ("vfy-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$Worktree = Join-Path $Scratch 'wt'
$BuildLog = Join-Path $Scratch 'build.log'
$HostOut  = Join-Path $Scratch 'host.out.log'
$HostErr  = Join-Path $Scratch 'host.err.log'
$BodyFile = Join-Path $Scratch 'payload.json'

function Write-Log  { param([string] $Message) Write-Host "[verify-all] $Message" }
function Add-Failure {
    param([string] $Message)
    Write-Host "[verify-all] FAIL: $Message" -ForegroundColor Red
    $script:Failed = $true
}

$script:HostPid = $null

function Get-ProcessTreeIds {
    param([int] $RootId)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $ids = @($RootId)
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $ids += @($all | Where-Object { $_.ParentProcessId -eq $ids[$i] } |
            ForEach-Object { [int] $_.ProcessId })
    }
    return $ids
}

function Stop-FunctionHost {
    # Three passes, because the port is not always held by the process that
    # was started: first the process tree this script started (collected
    # before anything is stopped, so no child loses its link to the root),
    # then whatever still listens on the port, then anything running from the
    # worktree. The last pass covers a 'dotnet run' child that outlived its
    # parent. Unrelated func or dotnet processes on the machine are left alone.
    if ($script:HostPid) {
        Get-ProcessTreeIds $script:HostPid |
            ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
        $script:HostPid = $null
    }

    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique |
        ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }

    # Only processes from this exact worktree, so no unrelated dotnet process
    # on the machine gets killed.
    Get-CimInstance Win32_Process -Filter "Name='dotnet.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Worktree) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Start-Sleep -Seconds 1
}

function Start-AzuriteIfNeeded {
    $running = & docker ps --format '{{.Names}}' 2>$null
    if ($running -notcontains 'azurite-demo') {
        Write-Log 'Starting Azurite (azurite-demo)'
        & docker rm -f azurite-demo 2>$null | Out-Null
        & docker run -d --name azurite-demo -p 10000:10000 -p 10001:10001 -p 10002:10002 `
            mcr.microsoft.com/azure-storage/azurite | Out-Null
        Start-Sleep -Seconds 2
    }
}

function Wait-ForHost {
    for ($i = 0; $i -lt 30; $i++) {
        & curl.exe -s -o NUL --max-time 5 -X POST "$BaseUrl/api/orders" `
            -H 'Content-Type: application/json' -d '{}' 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Start-FunctionHost {
    param([string] $Tag)

    Remove-Item -LiteralPath $HostOut, $HostErr -ErrorAction SilentlyContinue

    # 'dotnet run' for isolated projects, 'func start' for the in-process
    # library, see the header of this file.
    $proj    = Join-Path $Worktree $ProjectRel
    $csproj  = Get-Content -LiteralPath (Join-Path $proj 'OrderProcessor.csproj') -Raw
    $isolated = $csproj -match 'Azure\.Functions\.Sdk'

    if ($isolated) { $exe = 'dotnet'; $hostArgs = @('run') }
    else           { $exe = $FuncCommand; $hostArgs = @('start') }

    try {
        $process = Start-Process -FilePath $exe -ArgumentList $hostArgs `
            -WorkingDirectory $proj `
            -RedirectStandardOutput $HostOut -RedirectStandardError $HostErr `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
        $script:HostPid = $process.Id
    }
    catch {
        Add-Failure "$Tag`: could not start the function host: $($_.Exception.Message)"
        return $false
    }

    if (-not (Wait-ForHost)) {
        Add-Failure "$Tag`: host did not come up after 30 attempts"
        return $false
    }
    return $true
}

function Get-HostLog {
    $text = ''
    foreach ($f in @($HostOut, $HostErr)) {
        if (Test-Path -LiteralPath $f) { $text += (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) }
    }
    return $text
}

function Build-Tag {
    $proj = Join-Path $Worktree $ProjectRel
    foreach ($d in @('bin', 'obj')) {
        Remove-Item -LiteralPath (Join-Path $proj $d) -Recurse -Force -ErrorAction SilentlyContinue
    }
    & dotnet build (Join-Path $proj 'OrderProcessor.csproj') --nologo -v:q *>&1 |
        Out-File -LiteralPath $BuildLog -Encoding utf8
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Order {
    # The payload is read from a file so its quotes do not pass through
    # native command argument handling.
    $raw = & curl.exe -s -w "`n%{http_code}" -X POST "$BaseUrl/api/orders" `
        -H 'Content-Type: application/json' -d "@$BodyFile"
    $lines = (($raw -join "`n") -split "`n")
    $status = $lines[-1]
    $body = if ($lines.Count -gt 1) { ($lines[0..($lines.Count - 2)] -join "`n") } else { '' }
    return [pscustomobject]@{ Status = $status; Body = $body }
}

function Assert-Status {
    param($Actual, $Expected, $What)
    if ($Actual -ne $Expected) { Add-Failure "$What`: expected HTTP $Expected, got $Actual" }
}

function Assert-Contains {
    param($Haystack, $Needle, $What)
    if ($Haystack -notlike "*$Needle*") { Add-Failure "$What`: expected to find '$Needle', got: $Haystack" }
}

function Assert-NotContains {
    param($Haystack, $Needle, $What)
    if ($Haystack -like "*$Needle*") { Add-Failure "$What`: expected NOT to find '$Needle', got: $Haystack" }
}

function Assert-BodyEquals {
    param($Actual, $Expected, $What)
    if ($Actual -ne $Expected) {
        Add-Failure "$What`: body differs from the in-process contract"
        Write-Host "         expected: $Expected" -ForegroundColor Red
        Write-Host "         actual:   $Actual"   -ForegroundColor Red
    }
}

function Assert-InHostLog {
    param($Needle, $What)
    if ((Get-HostLog) -notlike "*$Needle*") { Add-Failure "$What`: expected '$Needle' in the host log, not found" }
}

# The tag tables in README.md and README.de.md provide the shared numbering
# for repository states. They have drifted apart before: the English version
# omitted the slot swap case and therefore listed target-net10 as 14 instead
# of 15. From here on, such a mismatch is a test failure rather than something
# discovered months later.
function Get-TagTable {
    param([string] $Path)

    $rows = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $rows }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        # | 11a | Case | `tag` | ...   and   | 14 | Case | *(no tag)* | ...
        if ($line -match '^\|\s*(\d+[a-z]?)\s*\|[^|]*\|\s*(?:`([^`]+)`|\*\([^)]*\)\*)\s*\|') {
            $rows += [pscustomobject]@{ Number = $Matches[1]; Tag = $Matches[2] }
        }
    }
    return $rows
}

function Test-TagTables {
    param([string[]] $ScriptTags)

    $before = $script:Failed
    $enPath = Join-Path $RepoRoot 'README.md'
    $dePath = Join-Path $RepoRoot 'README.de.md'
    $en = Get-TagTable $enPath
    $de = Get-TagTable $dePath

    if ($en.Count -eq 0 -or $de.Count -eq 0) {
        Add-Failure 'tag tables: could not parse README.md or README.de.md'
        return
    }

    # Number and tag must match row by row. The descriptions are translated
    # and deliberately not compared.
    $enKey = ($en | ForEach-Object { "$($_.Number)=$($_.Tag)" }) -join ', '
    $deKey = ($de | ForEach-Object { "$($_.Number)=$($_.Tag)" }) -join ', '
    if ($enKey -ne $deKey) {
        Add-Failure 'tag tables: README.md and README.de.md disagree'
        Write-Host "         README.md:    $enKey" -ForegroundColor Red
        Write-Host "         README.de.md: $deKey" -ForegroundColor Red
    }

    $tableTags = @($en | Where-Object { $_.Tag } | ForEach-Object { $_.Tag })
    $repoTags  = @(& git -C $RepoRoot tag)

    foreach ($t in ($tableTags | Where-Object { $_ -notin $repoTags })) {
        Add-Failure "tag tables: '$t' is listed in README.md but does not exist"
    }
    foreach ($t in ($repoTags | Where-Object { $_ -notin $tableTags })) {
        Add-Failure "tag tables: tag '$t' exists but is not listed in README.md"
    }

    # aspire-optional is deliberately skipped, see the header of this file.
    # Everything else in the table belongs in the check list and vice versa.
    foreach ($t in ($tableTags | Where-Object { $_ -ne 'aspire-optional' -and $_ -notin $ScriptTags })) {
        Add-Failure "tag tables: '$t' is documented but not checked by this script"
    }
    foreach ($t in ($ScriptTags | Where-Object { $_ -notin $tableTags })) {
        Add-Failure "tag tables: this script checks '$t', which is not in the README tables"
    }

    if ($script:Failed -eq $before) {
        Write-Log "tag tables: $($en.Count) rows, consistent across README.md, README.de.md, git and this script - OK"
    }
}

# Migration order: first the compiler error, then the 500 from the synchronous
# read, then the null logger, then the silent serialization failure.
$AllTags = @(
    'baseline-inprocess'
    'output-binding-broken'
    'output-binding-fixed'
    'sync-read-broken'
    'sync-read-fixed'
    'logger-parameter-broken'
    'logger-parameter-fixed'
    'serializer-attributes-broken'
    'serializer-attributes-worker-noop'
    'serializer-attributes-fixed-stj'
    'serializer-attributes-fixed-newtonsoft'
    'serializer-attributes-fixed-frombody'
    'log-filter-broken'
    'log-filter-fixed'
    'target-net10'
)

# The table check covers the repository, not the selected subset, so it
# always runs, before -Tags overrides the list.
Test-TagTables -ScriptTags $AllTags

if ($Tags -and $Tags.Count -gt 0) { $AllTags = $Tags }

if (-not $FuncCommand) {
    Write-Host '[verify-all] FAIL: func not found on PATH.' -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $Scratch -Force | Out-Null
Set-Content -LiteralPath $BodyFile -Value $Payload -NoNewline -Encoding ascii

function Invoke-TagCheck {
    param([string] $tag)

    & git -C $Worktree checkout --detach $tag 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Add-Failure "tag $tag does not exist"; return }

    if ($tag -eq 'output-binding-broken') {
        if (Build-Tag) {
            Add-Failure "$tag`: expected dotnet build to fail (CS0592), but it succeeded"
        }
        else {
            $log = Get-Content -LiteralPath $BuildLog -Raw
            if ($log -notlike '*CS0592*') {
                Add-Failure "$tag`: build failed, but not with CS0592"
                Write-Host $log
            }
            else {
                Write-Log "$tag`: build failed as documented (CS0592) - OK"
            }
        }
        return
    }

    if (-not (Build-Tag)) {
        Add-Failure "$tag`: dotnet build failed unexpectedly"
        Write-Host (Get-Content -LiteralPath $BuildLog -Raw)
        return
    }

    Start-AzuriteIfNeeded
    Stop-FunctionHost
    if (-not (Start-FunctionHost -Tag $tag)) {
        Write-Host (Get-HostLog)
        return
    }

    if ($tag -eq 'baseline-inprocess') {
        # This establishes the reference. A status code alone proves
        # little, so the full body is pinned down.
        $r = Invoke-Order
        Assert-Status $r.Status '200' $tag
        Assert-BodyEquals $r.Body $BaselineBody $tag
    }
    elseif ($tag -in @('output-binding-fixed', 'sync-read-broken')) {
        # Compiles again but does not run: the StreamReader carried over
        # from the in-process model reads the Kestrel stream synchronously.
        # Both tags have the same code.
        $r = Invoke-Order
        Assert-Status $r.Status '500' $tag
        Assert-InHostLog 'Synchronous operations are disallowed' $tag
    }
    elseif ($tag -in @('sync-read-fixed', 'logger-parameter-broken')) {
        # AllowSynchronousIO is set and the 500 from the read is gone - and
        # the next error shows up immediately: ILogger as a parameter is
        # null. Both tags have the same code.
        $r = Invoke-Order
        Assert-Status $r.Status '500' $tag
        Assert-InHostLog "Value cannot be null. (Parameter 'logger')" $tag
        if ((Get-HostLog) -like '*Synchronous operations are disallowed*') {
            Add-Failure "$tag`: expected the synchronous-read 500 to be gone, but it is still in the log"
        }
    }
    elseif ($tag -eq 'logger-parameter-fixed') {
        # The call works again and the data is still correct (Newtonsoft
        # reads the body). But the field is already named customerName
        # without anyone having changed it. This is the entry point to
        # the serializer case and must not change unnoticed.
        $r = Invoke-Order
        Assert-Status $r.Status '200' $tag
        Assert-Contains    $r.Body '"Ada"'          $tag
        Assert-Contains    $r.Body '"customerName"' $tag
        Assert-NotContains $r.Body '"customer_name"' $tag
    }
    elseif ($tag -in @('serializer-attributes-broken', 'serializer-attributes-worker-noop')) {
        # The silent failure: 200, no log, no error, empty field. In
        # -worker-noop, WorkerOptions.Serializer is additionally set to
        # Newtonsoft - the fix found everywhere, which changes nothing.
        $r = Invoke-Order
        Assert-Status $r.Status '200' $tag
        Assert-Contains $r.Body '"customerName":null' $tag
        if ($r.Body -like '*"Ada"*') {
            Add-Failure "$tag`: expected customer_name to be silently null, but found 'Ada' bound correctly"
        }
        if ((Get-HostLog) -like '*Synchronous operations are disallowed*') {
            Add-Failure "$tag`: unexpected synchronous-read 500 - the body is read asynchronously here"
        }
    }
    elseif ($tag -in @('serializer-attributes-fixed-stj',
                       'serializer-attributes-fixed-newtonsoft',
                       'serializer-attributes-fixed-frombody')) {
        $r = Invoke-Order
        Assert-Status $r.Status '200' $tag
        # All three resolutions reproduce the in-process body exactly.
        # That is the actual promise of this case: the migration must not
        # change the contract. A camelCase or PascalCase shift is caught
        # here even if "Ada" is bound correctly.
        Assert-BodyEquals $r.Body $BaselineBody $tag
        Assert-Contains    $r.Body '"Ada"'            $tag
        Assert-Contains    $r.Body '"customer_name"'  $tag
        # Input and output depend on different layers and can break
        # independently. In variant B, AddNewtonsoftJson() only covers the
        # write side: replacing the explicit JsonConvert read with
        # ReadFromJsonAsync later still yields "customer_name", but null.
        Assert-NotContains $r.Body '"customer_name":null' $tag
    }
    elseif ($tag -eq 'log-filter-broken') {
        $body = & curl.exe -s "$BaseUrl/api/diagnostics/log-filters"
        Assert-Contains ($body -join '') 'ApplicationInsightsLoggerProvider' $tag
    }
    elseif ($tag -in @('log-filter-fixed', 'target-net10')) {
        $body = ((& curl.exe -s "$BaseUrl/api/diagnostics/log-filters") -join '')
        if ($body -like '*ApplicationInsightsLoggerProvider*') {
            Add-Failure "$tag`: expected the ApplicationInsights filter rule to be removed, but it is still present"
        }
        if ($tag -eq 'target-net10') {
            $r = Invoke-Order
            Assert-Status $r.Status '200' $tag
            Assert-Contains $r.Body '"Ada"'           $tag
            Assert-Contains $r.Body '"customer_name"' $tag
            $retry = ((& curl.exe -s "$BaseUrl/api/diagnostics/retry-options") -join '')
            # The response goes through OkObjectResult, hence camelCase: "maxRetries".
            Assert-Contains $retry '"maxRetries":0' $tag
        }
    }
}

try {
    & git -C $RepoRoot worktree add --detach $Worktree HEAD | Out-Null

    foreach ($tag in $AllTags) {
        Write-Log "=== $tag ==="
        try {
            Invoke-TagCheck -tag $tag
            $script:Checked++
        }
        catch {
            # An unexpected error in one tag must neither skip the remaining
            # tags nor end up reported as success.
            Add-Failure "$tag`: unexpected error: $($_.Exception.Message)"
            Write-Host $_.ScriptStackTrace
        }
        Stop-FunctionHost
    }
}
catch {
    Add-Failure "aborted: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
}
finally {
    Stop-FunctionHost
    & git -C $RepoRoot worktree remove --force $Worktree 2>$null | Out-Null
    & git -C $RepoRoot worktree prune 2>$null | Out-Null
    Remove-Item -LiteralPath $Scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# Without this check, an abort after the first tag would be reported as success.
if ($script:Checked -ne $AllTags.Count) {
    Add-Failure "only $($script:Checked) of $($AllTags.Count) tags were checked"
}

if ($script:Failed) {
    Write-Log 'One or more checks failed. See output above.'
    exit 1
}

Write-Log "All $($script:Checked) tags verified successfully."
