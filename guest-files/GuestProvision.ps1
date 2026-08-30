#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Guest-side provisioner injected by Build-Vms.ps1.

.DESCRIPTION
    Runs once at the end of Windows Setup (SetupComplete) to finish online work
    that cannot be done offline: leftover Windows features, Client RSAT when no
    FoD source was available, and Azure Arc onboarding (service-principal mode).

.NOTES
    Target shell : Windows PowerShell 5.1 and PowerShell 7
    Log root     : C:\ProgramData\VmDeployLogs
#>

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
# $scriptName     = "GuestProvision"
$applicationName = "GuestProvision"
$logFileName = (Get-Date -Format "yyyyMMdd-HHmm") + ".log"

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
$enableLogFile = $true

$logFileDirectory = Join-Path -Path $env:ProgramData -ChildPath "VmDeployLogs"
$logFile          = Join-Path -Path $logFileDirectory -ChildPath $logFileName
$stateFilePath    = Join-Path -Path $env:ProgramData -ChildPath "VmDeployLogs\state.json"
$manifestPath     = Join-Path -Path $PSScriptRoot -ChildPath "manifest.json"
$arcSecretPath    = Join-Path -Path $PSScriptRoot -ChildPath "arc-deploy.json"

if ($enableLogFile -and -not (Test-Path -Path $logFileDirectory)) {
    New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null
}

# ---------------------------[ Logging Function ]---------------------------
function Write-Log {
    [CmdletBinding()]
    param (
        [string]$Message,
        [string]$Tag = "Info"
    )

    if (-not $log) { return }

    if (($Tag -eq "Debug") -and (-not $logDebug)) { return }
    if (($Tag -eq "Get")   -and (-not $logGet))   { return }
    if (($Tag -eq "Run")   -and (-not $logRun))   { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Lower case, and five characters wide - 'error', 'debug' and 'start' are the longest
    # tags there are, so the message column starts in the same place on every line and the
    # eye reads down the text rather than down a ragged edge. 'ok' renders as 'o.k.' and
    # 'warn' is the word in full: the two that used to be 'Success' and 'Warning' were what
    # forced a seven-wide column, and neither said anything the short form does not.
    #
    # Both old spellings still map, on purpose, and the lookup is case-insensitive: a
    # -Tag "Success" or -Tag "Warning" call site keeps working rather than rendering red.
    $tagMap = @{
        "start"   = "start"
        "get"     = "get"
        "run"     = "run"
        "info"    = "info"
        "warn"    = "warn"
        "warning" = "warn"
        "ok"      = "o.k."
        "success" = "o.k."
        "error"   = "error"
        "debug"   = "debug"
        "end"     = "end"
    }

    $key = $Tag.Trim().ToLowerInvariant()
    # A tag outside the map renders as an error rather than being dropped, so a typo is
    # loud instead of invisible.
    $shown = $tagMap[$key]
    if ([string]::IsNullOrWhiteSpace($shown)) { $shown = "error" }
    $rawTag = $shown.PadRight(5)

    $color = switch ($shown) {
        "start" { "Cyan" }
        "get"   { "Blue" }
        "run"   { "Magenta" }
        "info"  { "Yellow" }
        # There is no orange in ConsoleColor. DarkYellow is ANSI 3, which every current
        # scheme renders orange-brown, against info's Yellow = ANSI 11, the pale bright
        # one - so warn reads as the louder of the two, not the dimmer. That colour used
        # to belong to debug, which is now DarkGray, where a diagnostic tag belongs.
        "warn"  { "DarkYellow" }
        "o.k."  { "Green" }
        "error" { "Red" }
        "debug" { "DarkGray" }
        "end"   { "Cyan" }
        default { "White" }
    }

    $logMessage = "$timestamp [ $rawTag ] $Message"

    if ($enableLogFile) {
        # -ErrorAction Stop is what makes the catch below a catch. Without it Add-Content
        # reports a locked file as a NON-TERMINATING error, which walks straight past
        # try/catch and prints the whole red block to the console - from nothing worse
        # than somebody tailing the log in another window.
        #
        # A lock on a log file is transient by nature, so it is retried rather than simply
        # swallowed: catching it alone would drop the line silently, which is a worse
        # failure than the noise it replaced. Three attempts, briefly spaced; after that
        # the line is lost and the run carries on, because logging must never block it.
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Add-Content -Path $logFile -Value $logMessage -Encoding UTF8 -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -eq 3) { break }
                Start-Sleep -Milliseconds 120
            }
        }
    }

    Write-Host "$timestamp " -NoNewline
    Write-Host "[ " -NoNewline -ForegroundColor White
    Write-Host "$rawTag" -NoNewline -ForegroundColor $color
    Write-Host " ] " -NoNewline -ForegroundColor White
    Write-Host "$Message"
}

# ---------------------------[ Exit Function ]---------------------------
function Complete-Script {
    param([int]$ExitCode)

    $scriptEndTime = Get-Date
    $duration      = $scriptEndTime - $scriptStartTime

    Write-Log "Runtime $($duration.ToString('hh\:mm\:ss\.ff'))" -Tag "Info"
    Write-Log "Exit $ExitCode" -Tag "Info"
    Write-Log "==================== End ====================" -Tag "End"

    exit $ExitCode
}

function Save-GuestProvisionState {
    param(
        [hashtable]$State
    )

    $stateDirectory = Split-Path -Path $stateFilePath -Parent
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($stateFilePath, $json, $utf8NoBom)
}

function Get-GuestProvisionManifest {
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found at '$manifestPath'"
    }

    $raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Test-IsWindowsClientOs {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        # ProductType: 1 = Workstation, 2 = Domain Controller, 3 = Server
        return ([int]$os.ProductType -eq 1)
    }
    catch {
        Write-Log "Could not detect OS product type: $($_.Exception.Message)" -Tag "Error"
        return $false
    }
}

function ConvertTo-MacKey {
    # Bare uppercase hex, so a Hyper-V MAC (001122334455) and a guest one (00-11-22-33-44-55)
    # compare equal.
    param([string]$MacAddress)

    return ((([string]$MacAddress) -replace '[^0-9A-Fa-f]', '')).ToUpperInvariant()
}

function Rename-GuestNetworkAdapters {
    <#
      Names the guest's network connections after their Hyper-V adapters.

      Hyper-V "device naming" only publishes the adapter name as an NDIS property - it never
      touches the connection name Windows shows, which stays 'Ethernet', 'Ethernet 2', ...
      So the rename happens here, keyed by MAC: the same identity the unattend keyed each
      interface's addressing to, which is why renaming can never move an IP.
    #>
    param([object[]]$Plan)

    $renamed = New-Object System.Collections.Generic.List[string]
    $wanted = @($Plan | Where-Object {
            $null -ne $_ -and
            -not [string]::IsNullOrWhiteSpace([string]$_.name) -and
            -not [string]::IsNullOrWhiteSpace([string]$_.macAddress)
        })
    if ($wanted.Count -eq 0) {
        return $renamed.ToArray()
    }

    $adapters = @()
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop)
    }
    catch {
        Write-Log "Could not enumerate network adapters: $($_.Exception.Message)" -Tag "Error"
        return $renamed.ToArray()
    }

    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $wanted) {
        $target = [string]$entry.name
        $macKey = ConvertTo-MacKey -MacAddress ([string]$entry.macAddress)
        $match = $adapters | Where-Object { (ConvertTo-MacKey -MacAddress $_.MacAddress) -eq $macKey } | Select-Object -First 1
        if (-not $match) {
            Write-Log "No adapter carries MAC $macKey - '$target' was not applied" -Tag "Error"
            continue
        }
        if ($match.Name -eq $target) {
            Write-Log "Adapter '$target' is already named correctly" -Tag "Info"
            $renamed.Add($target) | Out-Null
            continue
        }
        $jobs.Add([pscustomobject]@{ Current = [string]$match.Name; Target = $target }) | Out-Null
    }
    if ($jobs.Count -eq 0) {
        return $renamed.ToArray()
    }

    # Two passes through a scratch name. Renaming straight to the target fails whenever the
    # target is still held by another adapter - which is exactly the normal case, since
    # Windows already called something 'Ethernet 2' and that is where vnic-02 has to land.
    $staged = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $temp = "GuestProvision-pending-$i"
        try {
            Rename-NetAdapter -Name $jobs[$i].Current -NewName $temp -ErrorAction Stop
            $staged.Add([pscustomobject]@{ Temp = $temp; Target = $jobs[$i].Target }) | Out-Null
        }
        catch {
            Write-Log "Could not stage rename of adapter '$($jobs[$i].Current)': $($_.Exception.Message)" -Tag "Error"
        }
    }
    foreach ($item in $staged) {
        try {
            Rename-NetAdapter -Name $item.Temp -NewName $item.Target -ErrorAction Stop
            Write-Log "Renamed network adapter to '$($item.Target)'" -Tag "Run"
            $renamed.Add($item.Target) | Out-Null
        }
        catch {
            # Leaving it on the scratch name is loud on purpose: a half-renamed adapter is
            # easier to spot than one silently back on 'Ethernet 2'.
            Write-Log "Could not rename '$($item.Temp)' to '$($item.Target)': $($_.Exception.Message)" -Tag "Warn"
        }
    }

    foreach ($nic in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
        Write-Log "Adapter '$($nic.Name)' | $($nic.MacAddress) | $($nic.Status)" -Tag "Info"
    }
    return $renamed.ToArray()
}

function Get-DiskScsiLun {
    # SCSI LUN out of Get-Disk's Location string, or -1 when it is not expressed that way.
    param([object]$Disk)

    $location = [string]$Disk.Location
    if ($location -match 'LUN\s*(\d+)') {
        return [int]$Matches[1]
    }
    return -1
}

function Get-DataDiskForJob {
    <#
      Find the raw Hyper-V data disk a manifest entry describes.

      First choice is the SCSI location the host attached it at - Get-Disk surfaces it as
      the LUN in the Location string, and it is the only field that survives a disk
      renumbering. If the string cannot be parsed (older guests report a bare PCI path),
      fall back on size among the disks whose LUN could not be read.

      The candidate list is pre-filtered by the caller: RAW only, never boot or system,
      and never a LUN the manifest did not ask for - that last rule is what keeps shared
      VHD Set disks (SCSI 0:8 and up) out of reach.
    #>
    param(
        [object]$Job,
        [System.Collections.Generic.List[object]]$Candidates,
        [bool]$AllowSizeFallback = $true
    )

    $scsiLocation = -1
    if ($null -ne $Job.scsiLocation) { $scsiLocation = [int]$Job.scsiLocation }

    if ($scsiLocation -ge 0) {
        foreach ($candidate in $Candidates) {
            if ((Get-DiskScsiLun -Disk $candidate) -eq $scsiLocation) {
                return $candidate
            }
        }
    }

    if (-not $AllowSizeFallback) {
        return $null
    }

    $sizeGb = 0
    if ($null -ne $Job.sizeGB) { $sizeGb = [int]$Job.sizeGB }
    if ($sizeGb -gt 0) {
        $wantedBytes = [int64]$sizeGb * 1GB
        # VHDX size is exact, but leave room for the odd geometry rounding.
        $tolerance = 64MB
        foreach ($candidate in $Candidates) {
            # Only disks whose LUN is unreadable - a readable LUN that did not match above
            # belongs to some other job, so size must not be allowed to steal it.
            if ((Get-DiskScsiLun -Disk $candidate) -ge 0) { continue }
            if ([Math]::Abs([int64]$candidate.Size - $wantedBytes) -le $tolerance) {
                Write-Log "Disk for $($Job.letter): matched on size ($sizeGb GB), SCSI location unreadable" -Tag "Info"
                return $candidate
            }
        }
    }

    return $null
}

function Initialize-GuestDataDisks {
    <#
      Bring each configured data disk online, initialize it GPT, create one full-size
      partition, format it and mount it on its drive letter. Data disks only - the OS
      volume was formatted by New-Vhdx.ps1 when the gold image was built.

      Skips any disk that is not RAW: a disk that already carries a partition is either
      not ours or already done, and either way must not be overwritten.
    #>
    param(
        [object[]]$DiskJobs,
        [int]$SharedDiskCount = 0
    )

    $results = @()
    if ($null -eq $DiskJobs -or $DiskJobs.Count -eq 0) {
        Write-Log "No data disks to initialize" -Tag "Info"
        return $results
    }

    if (-not (Get-Command -Name "Get-Disk" -ErrorAction SilentlyContinue)) {
        Write-Log "Storage cmdlets unavailable - leaving $($DiskJobs.Count) data disk(s) raw" -Tag "Warn"
        return $results
    }

    # Every SCSI location the manifest actually asked for. Anything else attached to this
    # VM - above all a shared VHD Set at SCSI 0:8+ - must stay untouched: it belongs to a
    # guest cluster, another node may be using it, and formatting it would destroy it.
    $wantedLocations = @{}
    foreach ($job in $DiskJobs) {
        if ($null -ne $job.scsiLocation) { $wantedLocations[[int]$job.scsiLocation] = $true }
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    $skippedShared = 0
    try {
        foreach ($disk in @(Get-Disk -ErrorAction Stop | Sort-Object Number)) {
            if ($disk.IsBoot -or $disk.IsSystem) { continue }
            if ([string]$disk.PartitionStyle -ne "RAW") { continue }
            $lun = Get-DiskScsiLun -Disk $disk
            if ($lun -ge 0 -and -not $wantedLocations.ContainsKey($lun)) {
                Write-Log "Disk $($disk.Number) at SCSI 0:$lun is not in the manifest - left alone" -Tag "Info"
                $skippedShared++
                continue
            }
            $candidates.Add($disk) | Out-Null
        }
    }
    catch {
        Write-Log "Could not enumerate disks: $($_.Exception.Message)" -Tag "Warn"
        return $results
    }
    Write-Log "$($candidates.Count) raw data disk(s) available for $($DiskJobs.Count) configured volume(s), $skippedShared left alone" -Tag "Get"

    foreach ($job in $DiskJobs) {
        $letter = ([string]$job.letter).Trim().TrimEnd(':')
        $fileSystem = ([string]$job.fileSystem).Trim()
        $volumeLabel = ([string]$job.label).Trim()
        if ([string]::IsNullOrWhiteSpace($letter) -or [string]::IsNullOrWhiteSpace($fileSystem) -or $fileSystem -eq "None") {
            continue
        }

        # Matching on size alone is only safe while nothing shared is attached. With a
        # VHD Set on the VM and no readable SCSI location, the wrong pick would format a
        # disk another cluster node owns - refuse instead and let a human sort it out.
        $allowSizeFallback = ($SharedDiskCount -le 0)
        $disk = Get-DataDiskForJob -Job $job -Candidates $candidates -AllowSizeFallback $allowSizeFallback
        if ($null -eq $disk) {
            if (-not $allowSizeFallback) {
                Write-Log "$letter`: has no SCSI match and this VM has $SharedDiskCount shared VHD Set disk(s) - not guessing, format it by hand" -Tag "Warn"
            }
            else {
                Write-Log "No raw disk left for $letter`: ($($job.sizeGB) GB, SCSI 0:$($job.scsiLocation)) - skipped" -Tag "Warn"
            }
            $results += [pscustomobject]@{ letter = $letter; fileSystem = $fileSystem; success = $false }
            continue
        }
        $candidates.Remove($disk) | Out-Null

        try {
            Write-Log "Disk $($disk.Number) -> $letter`: $fileSystem '$volumeLabel'" -Tag "Run"
            if ($disk.IsOffline) {
                Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop
            }
            if ($disk.IsReadOnly) {
                Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction Stop
            }

            Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null
            $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $letter -ErrorAction Stop

            $formatParams = @{
                Partition          = $partition
                FileSystem         = $fileSystem
                Confirm            = $false
                Force              = $true
                ErrorAction        = "Stop"
            }
            if (-not [string]::IsNullOrWhiteSpace($volumeLabel)) {
                $formatParams["NewFileSystemLabel"] = $volumeLabel
            }
            Format-Volume @formatParams | Out-Null

            Write-Log "$letter`: is $fileSystem '$volumeLabel' ($([Math]::Round($disk.Size / 1GB)) GB)" -Tag "Ok"
            $results += [pscustomobject]@{ letter = $letter; fileSystem = $fileSystem; success = $true }
        }
        catch {
            Write-Log "Could not provision $letter`: on disk $($disk.Number): $($_.Exception.Message)" -Tag "Warn"
            $results += [pscustomobject]@{ letter = $letter; fileSystem = $fileSystem; success = $false }
        }
    }

    return $results
}

function Install-PendingWindowsFeatures {
    param(
        [string[]]$FeatureNames,
        [bool]$IncludeManagementTools
    )

    if ($null -eq $FeatureNames -or $FeatureNames.Count -eq 0) {
        Write-Log "No pending Windows features to install online" -Tag "Info"
        return $false
    }

    if (Test-IsWindowsClientOs) {
        Write-Log "Skipping Install-WindowsFeature on client OS" -Tag "Info"
        return $false
    }

    $restartNeeded = $false
    try {
        Import-Module ServerManager -ErrorAction Stop
    }
    catch {
        Write-Log "ServerManager module unavailable: $($_.Exception.Message)" -Tag "Warn"
        return $false
    }

    foreach ($featureName in $FeatureNames) {
        Write-Log "Installing Windows feature '$featureName' (online)" -Tag "Run"
        try {
            $params = @{
                Name                = $featureName
                ErrorAction         = "Stop"
                WarningAction       = "SilentlyContinue"
            }
            if ($IncludeManagementTools) {
                $params["IncludeManagementTools"] = $true
            }

            $result = Install-WindowsFeature @params
            if ($result.Success) {
                Write-Log "Feature '$featureName' installed (RestartNeeded=$($result.RestartNeeded))" -Tag "Ok"
                if ($result.RestartNeeded) {
                    $restartNeeded = $true
                }
            }
            else {
                Write-Log "Feature '$featureName' failed: ExitCode=$($result.ExitCode)" -Tag "Error"
            }
        }
        catch {
            Write-Log "Feature '$featureName' threw: $($_.Exception.Message)" -Tag "Error"
        }
    }

    return $restartNeeded
}

function Install-PendingCapabilities {
    param(
        [string[]]$CapabilityNames,
        [string]$Label = "capability"
    )

    if ($null -eq $CapabilityNames -or $CapabilityNames.Count -eq 0) {
        Write-Log "No pending $Label to install online" -Tag "Info"
        return $false
    }

    $restartNeeded = $false
    foreach ($capabilityName in $CapabilityNames) {
        Write-Log "Installing $Label '$capabilityName' (online / Windows Update)" -Tag "Run"
        try {
            $existing = Get-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
            if ($existing.State -eq "Installed") {
                Write-Log "$Label '$capabilityName' already installed" -Tag "Get"
                continue
            }

            $result = Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
            if ($result.RestartNeeded) {
                $restartNeeded = $true
            }
            Write-Log "$Label '$capabilityName' installed" -Tag "Ok"
        }
        catch {
            Write-Log "$Label '$capabilityName' failed: $($_.Exception.Message)" -Tag "Error"
        }
    }

    return $restartNeeded
}

function Connect-GuestProvisionAzureArc {
    param(
        [object]$ArcConfig
    )

    if ($null -eq $ArcConfig -or -not [bool]$ArcConfig.enabled) {
        Write-Log "Azure Arc not enabled in manifest" -Tag "Info"
        return
    }

    $authMode = [string]$ArcConfig.authMode
    if ([string]::IsNullOrWhiteSpace($authMode)) {
        $authMode = "servicePrincipal"
    }

    if ($authMode -eq "hostContext") {
        Write-Log "Arc authMode is hostContext - the host onboards this machine" -Tag "Info"
        return
    }

    # Everything below reads the plaintext secret from arc-deploy.json - wrap it all
    # in one try/finally so the secret file is removed on every exit path (not
    # just a successful azcmagent connect). Early returns used to leave it behind
    # in cleartext under C:\Windows\Setup\Scripts\GuestProvision permanently.
    try {
        $subscriptionId = [string]$ArcConfig.subscriptionId
        $tenantId       = [string]$ArcConfig.tenantId
        $resourceGroup  = [string]$ArcConfig.resourceGroup
        $location       = [string]$ArcConfig.location
        $appId          = [string]$ArcConfig.servicePrincipalAppId

        if ([string]::IsNullOrWhiteSpace($subscriptionId) -or
            [string]::IsNullOrWhiteSpace($tenantId) -or
            [string]::IsNullOrWhiteSpace($resourceGroup) -or
            [string]::IsNullOrWhiteSpace($location)) {
            Write-Log "Arc landing zone incomplete in manifest - skipping connect" -Tag "Warn"
            return
        }

        $secret = $null
        if (Test-Path -LiteralPath $arcSecretPath) {
            try {
                $secretDoc = Get-Content -LiteralPath $arcSecretPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $secret = [string]$secretDoc.servicePrincipalSecret
                if ([string]::IsNullOrWhiteSpace($appId) -and -not [string]::IsNullOrWhiteSpace([string]$secretDoc.servicePrincipalAppId)) {
                    $appId = [string]$secretDoc.servicePrincipalAppId
                }
            }
            catch {
                Write-Log "Failed to read arc-deploy.json: $($_.Exception.Message)" -Tag "Warn"
            }
        }

        if ([string]::IsNullOrWhiteSpace($appId) -or [string]::IsNullOrWhiteSpace($secret)) {
            Write-Log "Service principal App ID or secret missing - cannot connect Arc from guest" -Tag "Error"
            return
        }

        $azcmagentPath = Join-Path -Path $env:ProgramFiles -ChildPath "AzureConnectedMachineAgent\azcmagent.exe"
        if (-not (Test-Path -LiteralPath $azcmagentPath)) {
            Write-Log "azcmagent.exe not found - downloading Connected Machine agent" -Tag "Run"
            try {
                $msiPath = Join-Path -Path $env:TEMP -ChildPath "AzureConnectedMachineAgent.msi"
                $uri = "https://aka.ms/AzureConnectedMachineAgent"
                # Prefer curl.exe: Windows PowerShell 5.1 Invoke-WebRequest is extremely slow
                # on large binaries because of progress-bar overhead. curl is in-box on Server 2025.
                if (Get-Command -Name curl.exe -ErrorAction SilentlyContinue) {
                    Write-Log "Downloading agent via curl.exe" -Tag "Run"
                    & curl.exe -fSL --retry 3 --retry-delay 2 --connect-timeout 30 -o $msiPath $uri
                    if ($LASTEXITCODE -ne 0) {
                        throw "curl.exe exited with code $LASTEXITCODE"
                    }
                }
                else {
                    Write-Log "curl.exe unavailable - using Invoke-WebRequest" -Tag "Warn"
                    $prevProgress = $ProgressPreference
                    $ProgressPreference = "SilentlyContinue"
                    try {
                        Invoke-WebRequest -Uri $uri -OutFile $msiPath -UseBasicParsing -ErrorAction Stop
                    }
                    finally {
                        $ProgressPreference = $prevProgress
                    }
                }
                if (-not (Test-Path -LiteralPath $msiPath) -or ((Get-Item -LiteralPath $msiPath).Length -lt 1MB)) {
                    throw "Downloaded MSI is missing or too small: '$msiPath'"
                }
                $msiArgs = "/i `"$msiPath`" /qn /norestart"
                $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
                if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
                    throw "msiexec exited with code $($proc.ExitCode)"
                }
                Write-Log "Connected Machine agent installed" -Tag "Ok"
            }
            catch {
                Write-Log "Failed to install Connected Machine agent: $($_.Exception.Message)" -Tag "Error"
                return
            }
        }
        else {
            Write-Log "Using preinstalled azcmagent at '$azcmagentPath'" -Tag "Get"
        }

        if (-not (Test-Path -LiteralPath $azcmagentPath)) {
            Write-Log "azcmagent.exe still missing after install attempt" -Tag "Error"
            return
        }

        $connectArgs = @(
            "connect",
            "--service-principal-id", $appId,
            "--service-principal-secret", $secret,
            "--tenant-id", $tenantId,
            "--subscription-id", $subscriptionId,
            "--resource-group", $resourceGroup,
            "--location", $location
        )

        # Exit 42 ("Failed to Create Resource") is most often RBAC role-assignment
        # or resource-provider-registration propagation delay - inherently racy
        # against a VM that boots and connects immediately. Retry with backoff
        # before giving up; arc-deploy.json is only deleted once (in the finally
        # below) after the last attempt, success or not.
        $maxAttempts = 3
        $backoffSeconds = @(60, 120)
        $connected = $false

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            Write-Log "Connecting machine to Azure Arc (resource group '$resourceGroup', location '$location') - attempt $attempt/$maxAttempts" -Tag "Run"
            try {
                $output = & $azcmagentPath @connectArgs 2>&1
                $exitCode = $LASTEXITCODE
                foreach ($line in @($output)) {
                    Write-Log "azcmagent: $line" -Tag "Debug"
                }
                if ($exitCode -eq 0) {
                    Write-Log "Azure Arc connect succeeded (attempt $attempt/$maxAttempts)" -Tag "Ok"
                    $connected = $true
                    break
                }
                Write-Log "Azure Arc connect failed (exit $exitCode, attempt $attempt/$maxAttempts)" -Tag "Warn"
            }
            catch {
                Write-Log "Azure Arc connect threw: $($_.Exception.Message) (attempt $attempt/$maxAttempts)" -Tag "Warn"
            }

            if ($attempt -lt $maxAttempts) {
                $delay = $backoffSeconds[$attempt - 1]
                Write-Log "Retrying Azure Arc connect in ${delay}s" -Tag "Warn"
                Start-Sleep -Seconds $delay
            }
        }

        if (-not $connected) {
            Write-Log "Azure Arc connect did not succeed after $maxAttempts attempt(s)" -Tag "Error"
        }
    }
    finally {
        if (Test-Path -LiteralPath $arcSecretPath) {
            Remove-Item -LiteralPath $arcSecretPath -Force -ErrorAction SilentlyContinue
            Write-Log "Removed injected arc-deploy.json" -Tag "Info"
        }
    }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "$env:COMPUTERNAME | $env:USERNAME | $applicationName" -Tag "Info"

$exitCode = 0
$restartNeeded = $false
$state = @{
    computerName       = $env:COMPUTERNAME
    startedUtc         = (Get-Date).ToUniversalTime().ToString("o")
    featuresOnline     = @()
    rsatOnline         = @()
    capabilitiesOnline = @()
    dataDisks          = @()
    networkAdapters    = @()
    arc                = @{ attempted = $false; authMode = $null }
    completedUtc       = $null
    restartNeeded      = $false
    success            = $false
}

try {
    $manifest = Get-GuestProvisionManifest
    Write-Log "Loaded manifest from '$manifestPath'" -Tag "Get"

    $pendingFeatures = @()
    if ($manifest.pendingWindowsFeatures) {
        $pendingFeatures = @($manifest.pendingWindowsFeatures | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" })
    }

    $pendingRsat = @()
    if ($manifest.pendingRsatCapabilities) {
        $pendingRsat = @($manifest.pendingRsatCapabilities | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" })
    }

    # Non-RSAT capabilities (currently Server Core App Compatibility FOD) that could
    # not be added offline because no Features on Demand source was available.
    $pendingCapabilities = @()
    if ($manifest.pendingCapabilities) {
        $pendingCapabilities = @($manifest.pendingCapabilities | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" })
    }

    $includeManagementTools = $true
    if ($null -ne $manifest.includeManagementTools) {
        $includeManagementTools = [bool]$manifest.includeManagementTools
    }

    $dataDiskJobs = @()
    if ($manifest.dataDisks) {
        $dataDiskJobs = @($manifest.dataDisks | Where-Object { $null -ne $_ })
    }

    # Shared VHD Set disks attached to this VM. Never formatted here - only counted, so
    # the matcher knows it must not fall back to guessing by size.
    $sharedDiskCount = 0
    if ($null -ne $manifest.sharedDiskCount) {
        $sharedDiskCount = [int]$manifest.sharedDiskCount
    }

    $nicPlan = @()
    if ($manifest.networkAdapters) {
        $nicPlan = @($manifest.networkAdapters | Where-Object { $null -ne $_ })
    }

    $state.featuresOnline     = $pendingFeatures
    $state.rsatOnline         = $pendingRsat
    $state.capabilitiesOnline = $pendingCapabilities

    # Adapter names before anything else: it is the cheapest step here and the one whose
    # result is read back the most, so a failure further down still leaves usable names.
    $state.networkAdapters = @(Rename-GuestNetworkAdapters -Plan $nicPlan)

    # Data volumes first: a role installed below may be pointed at one of these drives,
    # and formatting needs nothing else to be in place.
    $state.dataDisks = @(Initialize-GuestDataDisks -DiskJobs $dataDiskJobs -SharedDiskCount $sharedDiskCount)

    # Server Core App Compatibility FOD must land before Windows Features/Roles - it is a
    # Core-only capability, never present alongside RSAT (client-only), but roles installed
    # on Core can depend on it already being present.
    if (Install-PendingCapabilities -CapabilityNames $pendingCapabilities -Label "Windows capability") {
        $restartNeeded = $true
    }

    if (Install-PendingWindowsFeatures -FeatureNames $pendingFeatures -IncludeManagementTools:$includeManagementTools) {
        $restartNeeded = $true
    }

    if (Install-PendingCapabilities -CapabilityNames $pendingRsat -Label "RSAT capability") {
        $restartNeeded = $true
    }

    if ($manifest.azureArc) {
        $state.arc.attempted = [bool]$manifest.azureArc.enabled
        $state.arc.authMode  = [string]$manifest.azureArc.authMode
        Connect-GuestProvisionAzureArc -ArcConfig $manifest.azureArc
    }

    $state.restartNeeded = $restartNeeded
    $state.success       = $true
    $state.completedUtc  = (Get-Date).ToUniversalTime().ToString("o")
    Save-GuestProvisionState -State $state
    Write-Log "Wrote state to '$stateFilePath'" -Tag "Ok"

    if ($restartNeeded) {
        Write-Log "Restart required to finish the feature installation" -Tag "Warn"
    }
}
catch {
    $exitCode = 1
    $state.success = $false
    $state.completedUtc = (Get-Date).ToUniversalTime().ToString("o")
    try { Save-GuestProvisionState -State $state } catch { }
    Write-Log "Guest provision failed: $($_.Exception.Message)" -Tag "Error"
}

Complete-Script -ExitCode $exitCode
