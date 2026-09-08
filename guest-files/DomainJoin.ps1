#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deferred domain join, run by the VmDeploy-DomainJoin scheduled task as SYSTEM.

.DESCRIPTION
    Registered by GuestProvision.ps1 at the end of first-boot provisioning when a VM
    carries domainJoin.mode = "deferred". Runs after Windows Setup has let go of the
    machine, joins the domain (and OU) from the DPAPI-protected credential that
    GuestProvision sealed, then wipes the credential, this script and the task on
    every outcome - success or failure - and reboots only when the join succeeded.

    A failed join leaves the machine in its workgroup with one line in
    C:\ProgramData\VmDeployLogs\state.json (domainJoin.result) and this log. Nothing
    secret survives the run.

.NOTES
    Target shell : Windows PowerShell 5.1 only (Add-Computer does not exist in PowerShell 7)
    Log root     : C:\ProgramData\VmDeployLogs
#>

$taskName        = "VmDeploy-DomainJoin"
$logDirectory    = Join-Path -Path $env:ProgramData -ChildPath "VmDeployLogs"
$logFile         = Join-Path -Path $logDirectory -ChildPath ("domain-join-" + (Get-Date -Format "yyyyMMdd-HHmm") + ".log")
$stateFilePath   = Join-Path -Path $logDirectory -ChildPath "state.json"
$secretFilePath  = Join-Path -Path $PSScriptRoot -ChildPath "domain-join.bin"
$plainFilePath   = Join-Path -Path $PSScriptRoot -ChildPath "domain-join.json"

# How long the task waits for a domain controller before giving up, and how many join
# attempts it makes once one answers. Retries live here, not on the task, so the wipe in
# the finally block below is the last thing that ever runs.
$dcWaitSeconds   = 600
$dcPollSeconds   = 15
$joinAttempts    = 3
$joinRetryDelay  = 60

if (-not (Test-Path -LiteralPath $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Tag = "Info")
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Tag.ToLowerInvariant(), $Message
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
}

function Remove-FileSecurely {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        # Overwrite before delete so the plaintext does not linger in freed clusters.
        $length = (Get-Item -LiteralPath $Path).Length
        if ($length -gt 0) {
            [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $length))
        }
    }
    catch { }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Get-JoinSecret {
    if (-not (Test-Path -LiteralPath $secretFilePath)) {
        throw "Sealed credential '$secretFilePath' is missing"
    }
    Add-Type -AssemblyName System.Security
    $sealed = [System.IO.File]::ReadAllBytes($secretFilePath)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $sealed, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    [Array]::Clear($bytes, 0, $bytes.Length)
    return ($json | ConvertFrom-Json)
}

function Wait-DomainController {
    param([string]$Domain)
    $deadline = (Get-Date).AddSeconds($dcWaitSeconds)
    do {
        & nltest.exe /dsgetdc:$Domain /force 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds $dcPollSeconds
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Save-JoinResult {
    param([string]$Result, [string]$Domain, [string]$OuPath)
    $state = @{}
    if (Test-Path -LiteralPath $stateFilePath) {
        try {
            $existing = Get-Content -LiteralPath $stateFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) { $state[$p.Name] = $p.Value }
        }
        catch { }
    }
    $state.domainJoin = @{
        mode         = "deferred"
        domain       = $Domain
        ouPath       = $OuPath
        result       = $Result
        completedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($stateFilePath, ($state | ConvertTo-Json -Depth 6), $utf8NoBom)
}

function Remove-JoinFootprint {
    Remove-FileSecurely -Path $secretFilePath
    Remove-FileSecurely -Path $plainFilePath
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}

Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "$env:COMPUTERNAME | $env:USERNAME | $taskName" -Tag "Info"

$result  = "failed"
$domain  = ""
$ouPath  = ""
$joined  = $false

try {
    if ((Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain) {
        Write-Log "Already a domain member - nothing to do" -Tag "Info"
        $result = "already-joined"
        $joined = $false
        return
    }

    $secret = Get-JoinSecret
    $domain = ([string]$secret.domain).Trim()
    $ouPath = ([string]$secret.ouPath).Trim()
    $dcFqdn = ([string]$secret.dcFqdn).Trim()
    $user   = [string]$secret.joinUser
    if ([string]::IsNullOrWhiteSpace($domain) -or [string]::IsNullOrWhiteSpace($user)) {
        throw "Sealed credential is incomplete (domain or joinUser empty)"
    }

    Write-Log "Waiting up to ${dcWaitSeconds}s for a domain controller of '$domain'" -Tag "Run"
    if (-not (Wait-DomainController -Domain $domain)) {
        throw "No domain controller for '$domain' answered within ${dcWaitSeconds}s"
    }

    $securePassword = ConvertTo-SecureString -String ([string]$secret.joinPassword) -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($user, $securePassword)
    $secret = $null

    $joinParams = @{
        DomainName  = $domain
        Credential  = $credential
        Force       = $true
        ErrorAction = "Stop"
    }
    if (-not [string]::IsNullOrWhiteSpace($ouPath)) { $joinParams.OUPath = $ouPath }
    # KB5020276: a domain controller handed to the join must be its FQDN.
    if (-not [string]::IsNullOrWhiteSpace($dcFqdn)) { $joinParams.Server = $dcFqdn }

    for ($attempt = 1; $attempt -le $joinAttempts -and -not $joined; $attempt++) {
        try {
            $target = if ($ouPath) { "$domain / $ouPath" } else { "$domain (default Computers container)" }
            Write-Log "Join attempt $attempt/$joinAttempts -> $target" -Tag "Run"
            Add-Computer @joinParams
            $joined = $true
            $result = "joined"
            Write-Log "Joined '$domain'" -Tag "Ok"
        }
        catch {
            Write-Log "Join attempt $attempt failed: $($_.Exception.Message)" -Tag "Error"
            if ($attempt -lt $joinAttempts) { Start-Sleep -Seconds $joinRetryDelay }
            else { $result = "failed: $($_.Exception.Message)" }
        }
    }
}
catch {
    $result = "failed: $($_.Exception.Message)"
    Write-Log $result -Tag "Error"
}
finally {
    # Runs on every exit path, including the early return above: the credential, this
    # script and the task never outlive one run.
    Remove-JoinFootprint
    try { Save-JoinResult -Result $result -Domain $domain -OuPath $ouPath } catch { }
    Write-Log "Wiped credential, script and task '$taskName'" -Tag "Info"
    Write-Log "Result: $result" -Tag "Info"
    Write-Log "==================== End ====================" -Tag "End"
}

if ($joined) {
    Restart-Computer -Force
}
