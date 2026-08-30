#Requires -Version 5.1
<#
.SYNOPSIS
    Delete Hyper-V VMs and their files (config, VHD/VHDX, checkpoints).

.DESCRIPTION
    Interactive console menu (same look as Build-Vms.ps1 / New-Vhdx.ps1):
      All        delete every VM on this host
      Selected   pick VMs from a multi-select list

    Per VM: force turn off if not already Off (no graceful shutdown - the VM is
    being deleted), leave the failover cluster if it is a clustered role, remove
    it from Hyper-V, then delete its disk files and its configuration folder.

    Disks still attached to a VM that is NOT being deleted are never touched, and
    neither are pass-through physical disks or differencing parents that live
    outside the VM's own disk folder.

.NOTES
    Target shell : Windows PowerShell 5.1 and PowerShell 7
    Requires     : Administrator, Hyper-V role
    WARNING      : This deletes data permanently. There is no recycle bin here.
#>

[CmdletBinding()]
param (
    [switch]$All,
    [string[]]$VmName,
    [switch]$KeepDisks,
    [switch]$ListOnly,
    [switch]$Force
)

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "Remove-Vms"
$logFileName = (Get-Date -Format "yyyyMMdd-HHmm") + ".log"
$applicationName = "Remove-Vms"

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
$enableLogFile = $true

# This script lives in toolbox\, one level below the project root. Logs stay in the
# project-wide logs\ folder next to Build-Vms.ps1, not in a second one under toolbox\.
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = $PSScriptRoot }

$logFileDirectory = Join-Path -Path $projectRoot -ChildPath "logs\remove-vms"
$logFile          = Join-Path -Path $logFileDirectory -ChildPath $logFileName

if ($enableLogFile -and -not (Test-Path -Path $logFileDirectory)) {
    New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null
}

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

function Complete-Script {
    param([int]$ExitCode)

    $scriptEndTime = Get-Date
    $duration      = $scriptEndTime - $scriptStartTime
    Write-Log "Runtime $($duration.ToString('hh\:mm\:ss\.ff'))" -Tag "Info"
    Write-Log "Exit $ExitCode" -Tag "Info"
    Write-Log "==================== End ====================" -Tag "End"
    exit $ExitCode
}

# Seconds to wait for a forced turn off to land before giving up on a VM
$script:turnOffTimeoutSeconds = 120
# Delete retries for files the VMMS service still has a handle on
$script:deleteRetryCount = 5
$script:deleteRetryDelaySeconds = 2
# Folders Hyper-V creates inside a VM configuration root
$script:hyperVConfigSubfolders = @("Virtual Machines", "Snapshots", "Planned Virtual Machines")
# ---------------------------[ Console Menu ]---------------------------
# Same look as New-Vhdx.ps1: truecolor server logo + fastfetch-style header,
# arrow-key menus with plain fallbacks for hosts without RawUI/ANSI.
function Test-MenuHostSupported {
    try {
        if ($null -eq $Host -or $null -eq $Host.UI -or $null -eq $Host.UI.RawUI) {
            return $false
        }
        if ($Host.Name -match "ISE") {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

# Truecolor pixel-art logo (two teal server towers). Stored Base64-encoded so the
# script file stays pure ASCII; decoded at render time on ANSI-capable consoles.
$script:serverLogoAnsiB64 = @(
    "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"
)
$script:serverLogoAnsiWidth = 36
$script:menuVtEnabled = $false

function Enable-MenuVtProcessing {
    # Turns on virtual terminal processing so truecolor ANSI renders on
    # conhost-based Windows consoles. Safe no-op everywhere else.
    if ($script:menuVtEnabled) { return }
    $script:menuVtEnabled = $true

    try {
        $vt = Add-Type -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError=true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@ -Name RemoveVmsVtConsole -Namespace RemoveVms -PassThru -ErrorAction Stop
        $handle = $vt::GetStdHandle(-11)
        $mode = [uint32]0
        if ($vt::GetConsoleMode($handle, [ref]$mode)) {
            [void]$vt::SetConsoleMode($handle, ($mode -bor 0x4))
        }
    }
    catch {
        # Older hosts without VT support fall back to the plain ASCII logo
    }
}

function Test-MenuAnsiSupported {
    try {
        if ($env:NO_COLOR) { return $false }
        if ($Host.UI.SupportsVirtualTerminal) { return $true }
        if ($env:WT_SESSION -or $env:TERM_PROGRAM -or $env:TERM) { return $true }
        return $false
    }
    catch {
        return $false
    }
}

function Get-ServerLogoLines {
    # Truecolor pixel-art logo when the console supports ANSI, plain ASCII fallback otherwise.
    param([switch]$Plain)

    if (-not $Plain -and $script:serverLogoAnsiB64.Count -gt 0) {
        $decoded = @()
        foreach ($b64 in $script:serverLogoAnsiB64) {
            $decoded += [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        }
        return $decoded
    }

    return @(
        "      +--------------+              ",
        "      | ## ## ## ##  |   +--------+ ",
        "      | ## ## ## ##  |   | ## ##  | ",
        "      | ## ## ## ##  |   | ## ##  | ",
        "      | ## ## ## ##  |   | ## ##  | ",
        "      |          (o) |   |    (o) | ",
        "      +--------------+   +--------+ "
    )
}

function Write-ColoredLogoLine {
    param([string]$Line)

    foreach ($ch in $Line.ToCharArray()) {
        $color = "Cyan"
        switch ($ch) {
            "#" { $color = "Cyan" }
            "+" { $color = "DarkCyan" }
            "-" { $color = "DarkCyan" }
            "|" { $color = "DarkCyan" }
            "(" { $color = "Yellow" }
            ")" { $color = "Yellow" }
            "o" { $color = "Yellow" }
            " " { $color = "Cyan" }
            default { $color = "DarkCyan" }
        }
        Write-Host $ch -NoNewline -ForegroundColor $color
    }
}

function Get-AnsiVisibleLength {
    # Counts printable characters only (strips CSI / OSC escape sequences).
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return 0
    }

    $stripped = [regex]::Replace($Text, '\x1b\[[0-9;?]*[ -/]*[@-~]', '')
    $stripped = [regex]::Replace($stripped, '\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', '')
    return $stripped.Length
}

function Get-PaddedAnsiLine {
    param(
        [string]$Line,
        [int]$Width
    )

    $visible = Get-AnsiVisibleLength -Text $Line
    if ($visible -ge $Width) {
        return $Line
    }

    return ($Line + (" " * ($Width - $visible)))
}

function Write-FastfetchInfoRow {
    # Fastfetch-style aligned "label: value" (colons and values in one column).
    param(
        [string]$Label,
        [string]$Value,
        [int]$LabelWidth = 8
    )

    $paddedLabel = ("{0,-$LabelWidth}" -f $Label)
    Write-Host $paddedLabel -NoNewline -ForegroundColor DarkCyan
    Write-Host ": " -NoNewline -ForegroundColor DarkCyan
    Write-Host $Value -ForegroundColor Gray
}

function Show-MenuHeader {
    # Fastfetch-style header: colored server logo (left) + aligned facts (right).
    param(
        [string]$Title = "Build",
        [System.Collections.IDictionary]$StatusLines,
        [string]$Subtitle
    )

    Enable-MenuVtProcessing
    Clear-Host
    Write-Host ""

    $useAnsi = Test-MenuAnsiSupported
    $logo = @(Get-ServerLogoLines -Plain:(-not $useAnsi))
    $logoWidth = 36
    if ($useAnsi) {
        $logoWidth = [int]$script:serverLogoAnsiWidth
    }
    $pad = " " * $logoWidth
    $labelWidth = 8

    $info = New-Object System.Collections.Generic.List[object]
    $info.Add([pscustomobject]@{ Label = "toolkit"; Value = $scriptName; Accent = $true }) | Out-Null
    $info.Add([pscustomobject]@{ Label = "menu"; Value = $Title; Accent = $false }) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        $info.Add([pscustomobject]@{ Label = "section"; Value = $Subtitle; Accent = $false }) | Out-Null
    }
    $info.Add([pscustomobject]@{ Label = ""; Value = ""; Accent = $false }) | Out-Null

    if ($StatusLines) {
        foreach ($key in $StatusLines.Keys) {
            $info.Add([pscustomobject]@{
                    Label  = ([string]$key).ToLowerInvariant()
                    Value  = [string]$StatusLines[$key]
                    Accent = $false
                }) | Out-Null
        }
        $info.Add([pscustomobject]@{ Label = ""; Value = ""; Accent = $false }) | Out-Null
    }

    $info.Add([pscustomobject]@{ Label = "host"; Value = $env:COMPUTERNAME; Accent = $false }) | Out-Null
    $info.Add([pscustomobject]@{ Label = "user"; Value = $env:USERNAME; Accent = $false }) | Out-Null
    $info.Add([pscustomobject]@{ Label = "shell"; Value = ("PS " + $PSVersionTable.PSVersion.ToString()); Accent = $false }) | Out-Null

    $rows = [Math]::Max($logo.Count, $info.Count)
    for ($i = 0; $i -lt $rows; $i++) {
        Write-Host "  " -NoNewline

        if ($i -lt $logo.Count) {
            if ($useAnsi) {
                $line = Get-PaddedAnsiLine -Line $logo[$i] -Width $logoWidth
                Write-Host $line -NoNewline
            }
            else {
                $line = $logo[$i]
                if ($line.Length -lt $logoWidth) {
                    $line = $line + (" " * ($logoWidth - $line.Length))
                }
                elseif ($line.Length -gt $logoWidth) {
                    $line = $line.Substring(0, $logoWidth)
                }
                Write-ColoredLogoLine -Line $line
            }
        }
        else {
            Write-Host $pad -NoNewline
        }

        Write-Host "   " -NoNewline

        if ($i -lt $info.Count) {
            $row = $info[$i]
            if ([string]::IsNullOrWhiteSpace($row.Label) -and [string]::IsNullOrWhiteSpace($row.Value)) {
                Write-Host ""
                continue
            }
            if ($row.Accent) {
                Write-Host $row.Value -ForegroundColor White
            }
            else {
                Write-FastfetchInfoRow -Label $row.Label -Value $row.Value -LabelWidth $labelWidth
            }
        }
        else {
            Write-Host ""
        }
    }

    Write-Host ""
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
    Write-Host ""
}

function Show-Menu {
    param(
        [string]$Title,
        [object[]]$Items,
        [int]$SelectedIndex = 0,
        [System.Collections.IDictionary]$StatusLines,
        [string]$Question
    )

    if (-not $Items -or $Items.Count -eq 0) {
        throw "Show-Menu requires at least one item."
    }

    $index = $SelectedIndex
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $Items.Count) { $index = $Items.Count - 1 }

    $useRawUi = Test-MenuHostSupported
    $questionText = $Question
    if ([string]::IsNullOrWhiteSpace($questionText) -and $Title -and $Title.Trim().EndsWith("?")) {
        $questionText = $Title.Trim()
    }

    while ($true) {
        Show-MenuHeader -Title $Title -StatusLines $StatusLines

        if (-not [string]::IsNullOrWhiteSpace($questionText)) {
            Write-Host "  $questionText" -ForegroundColor White
            Write-Host ""
        }

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item  = $Items[$i]
            $label = if ($item.Label) { [string]$item.Label } else { [string]$item }
            $selected = ($i -eq $index)

            if ($selected) {
                Write-Host "  > " -NoNewline -ForegroundColor Cyan
                Write-Host $label -ForegroundColor White
            }
            else {
                Write-Host "    " -NoNewline
                Write-Host $label -ForegroundColor Gray
            }
        }

        Write-Host ""
        Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
        if ($useRawUi) {
            Write-Host "  Up/Down move   Enter select   Esc/Q cancel" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  Enter number + Enter   (Q to cancel)" -ForegroundColor DarkGray
        }
        Write-Host ""

        if ($useRawUi) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            $virtualKey = [int]$key.VirtualKeyCode
            $charKey = [string]$key.Character

            if ($virtualKey -eq 38) {
                $index = if ($index -le 0) { $Items.Count - 1 } else { $index - 1 }
                continue
            }
            if ($virtualKey -eq 40) {
                $index = if ($index -ge ($Items.Count - 1)) { 0 } else { $index + 1 }
                continue
            }
            if ($virtualKey -eq 13) {
                return $Items[$index].Id
            }
            if ($virtualKey -eq 27 -or $charKey -eq "q" -or $charKey -eq "Q") {
                return $null
            }
        }
        else {
            $raw = Read-Host "Select"
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            if ($raw -match "^[Qq]$") { return $null }
            if ($raw -match "^\d+$") {
                $num = [int]$raw
                if ($num -ge 1 -and $num -le $Items.Count) {
                    return $Items[$num - 1].Id
                }
            }
        }
    }
}

function Show-MultiSelectMenu {
    param(
        [string]$Title,
        [object[]]$Items,
        [System.Collections.IDictionary]$StatusLines,
        [string]$Question
    )

    if (-not $Items -or $Items.Count -eq 0) {
        throw "Show-MultiSelectMenu requires at least one item."
    }

    $index = 0
    $selected = @{}
    foreach ($item in $Items) {
        $selected[[string]$item.Id] = $false
    }

    $useRawUi = Test-MenuHostSupported
    $questionText = $Question
    if ([string]::IsNullOrWhiteSpace($questionText)) {
        $questionText = $Title
    }

    while ($true) {
        Show-MenuHeader -Title $Title -StatusLines $StatusLines -Subtitle "Space toggles selection"

        if (-not [string]::IsNullOrWhiteSpace($questionText)) {
            Write-Host "  $questionText" -ForegroundColor White
            Write-Host ""
        }

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item  = $Items[$i]
            $id    = [string]$item.Id
            $mark  = if ($selected[$id]) { "[x]" } else { "[ ]" }
            $label = "$mark  $($item.Label)"
            $isSelectedRow = ($i -eq $index)

            if ($isSelectedRow) {
                Write-Host "  > " -NoNewline -ForegroundColor Cyan
                Write-Host $label -ForegroundColor White
            }
            else {
                Write-Host "    " -NoNewline
                Write-Host $label -ForegroundColor Gray
            }
        }

        Write-Host ""
        Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
        if ($useRawUi) {
            Write-Host "  Up/Down move   Space toggle   Enter done   Esc/Q cancel" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  Number toggles, Enter alone confirms, Q cancels" -ForegroundColor DarkGray
        }
        Write-Host ""

        if ($useRawUi) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            $virtualKey = [int]$key.VirtualKeyCode
            $charKey = [string]$key.Character

            if ($virtualKey -eq 38) {
                $index = if ($index -le 0) { $Items.Count - 1 } else { $index - 1 }
                continue
            }
            if ($virtualKey -eq 40) {
                $index = if ($index -ge ($Items.Count - 1)) { 0 } else { $index + 1 }
                continue
            }
            if ($virtualKey -eq 32) {
                $id = [string]$Items[$index].Id
                $selected[$id] = -not $selected[$id]
                continue
            }
            if ($virtualKey -eq 13) {
                $chosen = @()
                foreach ($item in $Items) {
                    $id = [string]$item.Id
                    if ($selected[$id]) {
                        $chosen += $id
                    }
                }
                if ($chosen.Count -eq 0) {
                    continue
                }
                return ,$chosen
            }
            if ($virtualKey -eq 27 -or $charKey -eq "q" -or $charKey -eq "Q") {
                return $null
            }
        }
        else {
            $raw = Read-Host "Toggle number / empty Enter to confirm"
            if ($raw -match "^[Qq]$") { return $null }
            if ([string]::IsNullOrWhiteSpace($raw)) {
                $chosen = @()
                foreach ($item in $Items) {
                    $id = [string]$item.Id
                    if ($selected[$id]) {
                        $chosen += $id
                    }
                }
                if ($chosen.Count -eq 0) { continue }
                return ,$chosen
            }
            if ($raw -match "^\d+$") {
                $num = [int]$raw
                if ($num -ge 1 -and $num -le $Items.Count) {
                    $id = [string]$Items[$num - 1].Id
                    $selected[$id] = -not $selected[$id]
                }
            }
        }
    }
}


# ---------------------------[ Prerequisites ]---------------------------
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Confirm-HyperVAvailable {
    if (-not (Get-Command -Name Get-VM -ErrorAction SilentlyContinue)) {
        throw "Hyper-V PowerShell module is not available. Install the Hyper-V role/management tools."
    }
}

# ---------------------------[ Path helpers ]---------------------------
function Format-ByteSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1TB) { return ("{0:N1} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N0} MB" -f ($Bytes / 1MB)) }
    return ("{0} B" -f $Bytes)
}

function Get-PathKey {
    # Lower-case, trailing-slash-free absolute form used for all path comparisons.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $p = $Path.Trim().Trim('"')
    try { $p = [IO.Path]::GetFullPath($p) } catch { }
    $p = $p.TrimEnd('\')
    return $p.ToLowerInvariant()
}

function Test-IsPathRoot {
    # True for "C:\" / "\\server\share" style roots. Unknown paths count as roots so
    # that a parse failure can never turn into a recursive delete.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrWhiteSpace($root)) { return $true }
        return ((Get-PathKey $full) -eq (Get-PathKey $root))
    }
    catch {
        return $true
    }
}

function Test-PathIsUnder {
    param(
        [string]$Child,
        [string]$Parent
    )
    $c = Get-PathKey $Child
    $p = Get-PathKey $Parent
    if ([string]::IsNullOrWhiteSpace($c) -or [string]::IsNullOrWhiteSpace($p)) { return $false }
    if ($c -eq $p) { return $true }
    return $c.StartsWith($p + "\")
}

function Get-HostStopFolders {
    # Folders that must never be deleted themselves: the host defaults plus the
    # drive roots they sit on.
    $stop = @{}
    try {
        $h = Get-VMHost -ErrorAction Stop
        foreach ($p in @([string]$h.VirtualMachinePath, [string]$h.VirtualHardDiskPath)) {
            $k = Get-PathKey $p
            if ($k) { $stop[$k] = $true }
        }
    }
    catch { }
    return $stop
}

function Remove-FileWithRetry {
    # VMMS can hold a handle for a moment after Remove-VM, so retry before failing.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    for ($attempt = 1; $attempt -le $script:deleteRetryCount; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            return $true
        }
        catch {
            if ($attempt -ge $script:deleteRetryCount) {
                Write-Log ("Could not delete '{0}': {1}" -f $Path, $_.Exception.Message) -Tag "Error"
                return $false
            }
            Start-Sleep -Seconds $script:deleteRetryDelaySeconds
        }
    }
    return $false
}

function Remove-FolderWithRetry {
    param(
        [string]$Path,
        [switch]$Recurse
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    for ($attempt = 1; $attempt -le $script:deleteRetryCount; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Force -Recurse:$Recurse -ErrorAction Stop
            return $true
        }
        catch {
            if ($attempt -ge $script:deleteRetryCount) {
                Write-Log ("Could not delete folder '{0}': {1}" -f $Path, $_.Exception.Message) -Tag "Error"
                return $false
            }
            Start-Sleep -Seconds $script:deleteRetryDelaySeconds
        }
    }
    return $false
}

function Test-FolderIsEmpty {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    try {
        $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
        return ($children.Count -eq 0)
    }
    catch {
        return $false
    }
}

function Remove-EmptyFolderChain {
    # Walks up from a now-empty VM disk folder, deleting empty folders until it hits
    # a host default folder, a drive root, or something that still has content.
    param(
        [string]$StartFolder,
        [hashtable]$StopFolders
    )

    $current = $StartFolder
    $guard = 0
    while ($guard -lt 8) {
        $guard++
        if ([string]::IsNullOrWhiteSpace($current)) { return }
        if (Test-IsPathRoot -Path $current) { return }
        $key = Get-PathKey $current
        if ($StopFolders -and $StopFolders.ContainsKey($key)) { return }
        if (-not (Test-FolderIsEmpty -Path $current)) { return }

        $parent = Split-Path -Parent $current
        if (Remove-FolderWithRetry -Path $current) {
            Write-Log "Removed empty folder '$current'" -Tag "Run"
        }
        else {
            return
        }
        $current = $parent
    }
}

# ---------------------------[ Inventory ]---------------------------
function Get-VmDiskFileSet {
    # Every file on disk that belongs to this VM's storage: attached VHD/VHDX/AVHDX,
    # the checkpoint / differencing chain below it, and VHD Set data files.
    #
    # Deliberately NOT included:
    #   - pass-through physical disks (path is a disk number, not a file)
    #   - differencing parents that live outside the attached disk's own folder,
    #     because those are usually shared gold images
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)

    $files = New-Object System.Collections.Generic.List[object]
    $seen  = @{}

    foreach ($drive in @(Get-VMHardDiskDrive -VM $VM -ErrorAction SilentlyContinue)) {
        $path = [string]$drive.Path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($path -match '^\s*\d+\s*$') {
            Write-Log ("VM '{0}': pass-through physical disk left untouched ({1})" -f $VM.Name, $path) -Tag "Info"
            continue
        }

        $diskFolder = Split-Path -Parent $path
        $extension  = [IO.Path]::GetExtension($path).ToLowerInvariant()

        $key = Get-PathKey $path
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $files.Add([pscustomobject]@{ Path = $path; Kind = "attached" }) | Out-Null
        }

        if ($extension -eq ".vhds") {
            # VHD Set: <name>.vhds plus sibling <name>-<guid>.avhdx data files
            $baseName = [IO.Path]::GetFileNameWithoutExtension($path)
            foreach ($file in @(Get-ChildItem -LiteralPath $diskFolder -Filter "$baseName*.avhdx" -File -ErrorAction SilentlyContinue)) {
                $k = Get-PathKey $file.FullName
                if (-not $seen.ContainsKey($k)) {
                    $seen[$k] = $true
                    $files.Add([pscustomobject]@{ Path = $file.FullName; Kind = "vhdset-data" }) | Out-Null
                }
            }
            continue
        }

        # Walk the checkpoint / differencing chain downwards to the base disk
        $current = $path
        $guard = 0
        while ($guard -lt 64) {
            $guard++
            $parent = ""
            try {
                $vhd = Get-VHD -Path $current -ErrorAction Stop | Select-Object -First 1
                $parent = [string]$vhd.ParentPath
            }
            catch {
                break
            }
            if ([string]::IsNullOrWhiteSpace($parent)) { break }

            if ((Get-PathKey (Split-Path -Parent $parent)) -ne (Get-PathKey $diskFolder)) {
                Write-Log ("VM '{0}': parent disk '{1}' is outside the VM disk folder - left in place" -f $VM.Name, $parent) -Tag "Info"
                break
            }

            $k = Get-PathKey $parent
            if (-not $seen.ContainsKey($k)) {
                $seen[$k] = $true
                $files.Add([pscustomobject]@{ Path = $parent; Kind = "chain" }) | Out-Null
            }
            $current = $parent
        }
    }

    return $files.ToArray()
}

function Get-VmClusterGroupName {
    # Returns the cluster group name if this VM is a clustered role, otherwise $null.
    param([string]$VmId)

    if (-not (Get-Command -Name Get-ClusterResource -ErrorAction SilentlyContinue)) { return $null }
    try { Get-Cluster -ErrorAction Stop | Out-Null } catch { return $null }

    $wanted = ([string]$VmId).Replace("{", "").Replace("}", "").ToLowerInvariant()
    try {
        foreach ($res in @(Get-ClusterResource -ErrorAction Stop | Where-Object { [string]$_.ResourceType -eq "Virtual Machine" })) {
            try {
                $param = Get-ClusterParameter -InputObject $res -Name "VmID" -ErrorAction SilentlyContinue
                if ($null -eq $param) { continue }
                $value = ([string]$param.Value).Replace("{", "").Replace("}", "").ToLowerInvariant()
                if ($value -eq $wanted) {
                    return [string]$res.OwnerGroup.Name
                }
            }
            catch { }
        }
    }
    catch { }
    return $null
}

function Get-VmRemovalInventory {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)

    $checkpoints = @()
    try { $checkpoints = @(Get-VMSnapshot -VM $VM -ErrorAction SilentlyContinue) } catch { }

    $diskFiles = @(Get-VmDiskFileSet -VM $VM)
    $totalBytes = [int64]0
    foreach ($file in $diskFiles) {
        try {
            if (Test-Path -LiteralPath $file.Path) {
                $totalBytes += [int64](Get-Item -LiteralPath $file.Path -Force).Length
            }
        }
        catch { }
    }

    $generation = 1
    try { $generation = [int]$VM.Generation } catch { }

    return [pscustomobject]@{
        Name             = [string]$VM.Name
        Id               = [string]$VM.Id
        State            = [string]$VM.State
        Generation       = $generation
        CheckpointCount  = $checkpoints.Count
        ClusterGroup     = (Get-VmClusterGroupName -VmId ([string]$VM.Id))
        ConfigPath       = [string]$VM.Path
        SnapshotPath     = [string]$VM.SnapshotFileLocation
        SmartPagingPath  = [string]$VM.SmartPagingFilePath
        DiskFiles        = $diskFiles
        TotalBytes       = $totalBytes
    }
}

function Get-AllRemovalInventories {
    $list = @()
    foreach ($vm in @(Get-VM -ErrorAction Stop | Sort-Object Name)) {
        $list += (Get-VmRemovalInventory -VM $vm)
    }
    return $list
}

function Get-ProtectedDiskPaths {
    # Disk files that belong to VMs which are NOT being deleted. Never touched.
    param([string[]]$DeleteVmIds)

    $skip = @{}
    foreach ($id in @($DeleteVmIds)) { $skip[([string]$id).ToLowerInvariant()] = $true }

    $protected = @{}
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        if ($skip.ContainsKey(([string]$vm.Id).ToLowerInvariant())) { continue }
        foreach ($file in @(Get-VmDiskFileSet -VM $vm)) {
            $key = Get-PathKey $file.Path
            if ($key) { $protected[$key] = [string]$vm.Name }
        }
    }
    return $protected
}

function Get-ProtectedFolders {
    # Configuration / snapshot / disk folders of the VMs we are keeping.
    param([string[]]$DeleteVmIds)

    $skip = @{}
    foreach ($id in @($DeleteVmIds)) { $skip[([string]$id).ToLowerInvariant()] = $true }

    $protected = @{}
    foreach ($vm in @(Get-VM -ErrorAction SilentlyContinue)) {
        if ($skip.ContainsKey(([string]$vm.Id).ToLowerInvariant())) { continue }

        $folders = @([string]$vm.Path, [string]$vm.SnapshotFileLocation, [string]$vm.SmartPagingFilePath)
        foreach ($file in @(Get-VmDiskFileSet -VM $vm)) {
            $folders += (Split-Path -Parent $file.Path)
        }
        foreach ($folder in $folders) {
            $key = Get-PathKey $folder
            if ($key) { $protected[$key] = [string]$vm.Name }
        }
    }
    return $protected
}

# ---------------------------[ Removal steps ]---------------------------
function Stop-VmForced {
    # No graceful shutdown on purpose - the VM is about to be deleted.
    param([object]$VM)

    $name  = [string]$VM.Name
    $state = [string]$VM.State

    if ($state -eq "Off") {
        Write-Log "VM '$name' is already Off" -Tag "Info"
        return $true
    }

    if ($state -eq "Saved") {
        Write-Log "VM '$name' is Saved - discarding saved state" -Tag "Run"
        try {
            Remove-VMSavedState -VM $VM -ErrorAction Stop
            return $true
        }
        catch {
            Write-Log ("Could not discard saved state of '{0}': {1}" -f $name, $_.Exception.Message) -Tag "Error"
        }
    }

    Write-Log "VM '$name' is $state - forcing turn off" -Tag "Run"
    try {
        Stop-VM -VM $VM -TurnOff -Force -ErrorAction Stop
    }
    catch {
        Write-Log ("Stop-VM failed for '{0}': {1}" -f $name, $_.Exception.Message) -Tag "Error"
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $script:turnOffTimeoutSeconds) {
        $current = Get-VM -Id $VM.Id -ErrorAction SilentlyContinue
        if ($null -eq $current) { return $true }
        $now = [string]$current.State
        if ($now -eq "Off" -or $now -eq "Saved") {
            Write-Log "VM '$name' is $now" -Tag "Ok"
            return $true
        }
        Start-Sleep -Seconds 2
    }

    Write-Log "VM '$name' did not turn off within $($script:turnOffTimeoutSeconds)s" -Tag "Error"
    return $false
}

function Remove-VmClusterRole {
    param(
        [string]$GroupName,
        [string]$VmName
    )

    if ([string]::IsNullOrWhiteSpace($GroupName)) { return $true }
    if (-not (Get-Command -Name Remove-ClusterGroup -ErrorAction SilentlyContinue)) {
        Write-Log "VM '$VmName' looks clustered but the FailoverClusters module is missing - skipping cluster cleanup" -Tag "Error"
        return $false
    }

    # Take the group offline first. A clustered VM that is simply turned off looks
    # like a failure to the cluster, which would restart it while we delete.
    try {
        Write-Log "Taking cluster group '$GroupName' offline" -Tag "Run"
        Stop-ClusterGroup -Name $GroupName -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log ("Could not take cluster group '{0}' offline: {1}" -f $GroupName, $_.Exception.Message) -Tag "Warn"
    }

    Write-Log "Removing cluster role '$GroupName' for '$VmName'" -Tag "Run"
    try {
        Remove-ClusterGroup -Name $GroupName -RemoveResources -Force -ErrorAction Stop
        Write-Log "Cluster role '$GroupName' removed" -Tag "Ok"
        return $true
    }
    catch {
        Write-Log ("Could not remove cluster role '{0}': {1}" -f $GroupName, $_.Exception.Message) -Tag "Error"
        return $false
    }
}

function Remove-VmDiskFiles {
    param(
        [object]$Inventory,
        [hashtable]$ProtectedFiles,
        [hashtable]$StopFolders
    )

    $result = [pscustomobject]@{
        Deleted    = 0
        Failed     = 0
        Skipped    = 0
        BytesFreed = [int64]0
    }

    $diskFolders = @{}

    foreach ($file in @($Inventory.DiskFiles)) {
        $path = [string]$file.Path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $key = Get-PathKey $path
        if ($ProtectedFiles -and $ProtectedFiles.ContainsKey($key)) {
            Write-Log ("Disk '{0}' is still attached to VM '{1}' - kept" -f $path, $ProtectedFiles[$key]) -Tag "Info"
            $result.Skipped++
            continue
        }

        if (-not (Test-Path -LiteralPath $path)) {
            $result.Skipped++
            continue
        }

        $size = [int64]0
        try { $size = [int64](Get-Item -LiteralPath $path -Force).Length } catch { }

        if (Remove-FileWithRetry -Path $path) {
            Write-Log ("Deleted {0} ({1})" -f $path, (Format-ByteSize $size)) -Tag "Run"
            $result.Deleted++
            $result.BytesFreed += $size
            $folder = Split-Path -Parent $path
            $fk = Get-PathKey $folder
            if ($fk) { $diskFolders[$fk] = $folder }
        }
        else {
            $result.Failed++
        }
    }

    foreach ($folder in $diskFolders.Values) {
        Remove-EmptyFolderChain -StartFolder $folder -StopFolders $StopFolders
    }

    return $result
}

function Remove-VmConfigLocations {
    # Remove-VM already deleted the .vmcx/.vmrs/.vmgs files. What is left are the
    # folders Hyper-V created for this VM. A folder is deleted outright only when it
    # is dedicated to this VM; otherwise only the empty Hyper-V subfolders go.
    param(
        [object]$Inventory,
        [hashtable]$ProtectedFolders,
        [hashtable]$StopFolders
    )

    $candidates = @{}
    foreach ($path in @($Inventory.ConfigPath, $Inventory.SnapshotPath, $Inventory.SmartPagingPath)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $key = Get-PathKey $path
        if ($key) { $candidates[$key] = $path }
    }

    foreach ($key in @($candidates.Keys)) {
        $folder = $candidates[$key]
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }

        $isRoot      = Test-IsPathRoot -Path $folder
        $isStop      = ($StopFolders -and $StopFolders.ContainsKey($key))
        $isProtected = ($ProtectedFolders -and $ProtectedFolders.ContainsKey($key))

        # Another VM's folder sitting underneath this one also blocks a recursive delete
        $hasProtectedChild = $false
        if (-not $isProtected -and $ProtectedFolders) {
            foreach ($protectedKey in $ProtectedFolders.Keys) {
                if ($protectedKey.StartsWith($key + "\")) {
                    $hasProtectedChild = $true
                    break
                }
            }
        }

        if ($isRoot -or $isStop -or $isProtected -or $hasProtectedChild) {
            if ($isProtected -or $hasProtectedChild) {
                Write-Log "Folder '$folder' is shared with another VM - only empty Hyper-V subfolders are cleaned" -Tag "Info"
            }
            foreach ($sub in $script:hyperVConfigSubfolders) {
                $subPath = Join-Path $folder $sub
                if (Test-FolderIsEmpty -Path $subPath) {
                    if (Remove-FolderWithRetry -Path $subPath) {
                        Write-Log "Removed empty folder '$subPath'" -Tag "Run"
                    }
                }
            }
            if (-not $isRoot -and -not $isStop -and (Test-FolderIsEmpty -Path $folder)) {
                if (Remove-FolderWithRetry -Path $folder) {
                    Write-Log "Removed empty folder '$folder'" -Tag "Run"
                }
            }
            continue
        }

        if (Remove-FolderWithRetry -Path $folder -Recurse) {
            Write-Log "Deleted VM folder '$folder'" -Tag "Run"
            Remove-EmptyFolderChain -StartFolder (Split-Path -Parent $folder) -StopFolders $StopFolders
        }
    }
}

function Remove-SingleVm {
    param(
        [object]$Inventory,
        [hashtable]$ProtectedFiles,
        [hashtable]$ProtectedFolders,
        [hashtable]$StopFolders,
        [switch]$KeepDisks
    )

    $name = [string]$Inventory.Name
    $outcome = [pscustomobject]@{
        Name       = $name
        Removed    = $false
        FilesDeleted = 0
        FilesFailed  = 0
        BytesFreed = [int64]0
        Message    = ""
    }

    Write-Log "---------- $name ----------" -Tag "Start"

    $vm = Get-VM -Id $Inventory.Id -ErrorAction SilentlyContinue
    if ($null -eq $vm) {
        Write-Log "VM '$name' is no longer registered - continuing with file cleanup" -Tag "Warn"
    }
    else {
        if (-not (Remove-VmClusterRole -GroupName ([string]$Inventory.ClusterGroup) -VmName $name)) {
            $outcome.Message = "cluster role removal failed"
            Write-Log "Skipping '$name' - resolve the cluster role first" -Tag "Error"
            return $outcome
        }

        # Remove-ClusterGroup may already have unregistered the VM
        $vm = Get-VM -Id $Inventory.Id -ErrorAction SilentlyContinue
    }

    if ($null -ne $vm) {
        if (-not (Stop-VmForced -VM $vm)) {
            $outcome.Message = "could not turn the VM off"
            Write-Log "Skipping '$name' - still running" -Tag "Error"
            return $outcome
        }

        Write-Log "Removing '$name' from Hyper-V" -Tag "Run"
        try {
            Remove-VM -VM $vm -Force -ErrorAction Stop
            Write-Log "VM '$name' removed from Hyper-V" -Tag "Ok"
        }
        catch {
            $outcome.Message = $_.Exception.Message
            Write-Log ("Remove-VM failed for '{0}': {1}" -f $name, $_.Exception.Message) -Tag "Error"
            return $outcome
        }
    }

    $outcome.Removed = $true

    if ($KeepDisks) {
        Write-Log "KeepDisks set - disk and configuration files left on disk" -Tag "Info"
        return $outcome
    }

    $diskResult = Remove-VmDiskFiles -Inventory $Inventory -ProtectedFiles $ProtectedFiles -StopFolders $StopFolders
    $outcome.FilesDeleted = $diskResult.Deleted
    $outcome.FilesFailed  = $diskResult.Failed
    $outcome.BytesFreed   = $diskResult.BytesFreed

    Remove-VmConfigLocations -Inventory $Inventory -ProtectedFolders $ProtectedFolders -StopFolders $StopFolders

    if ($outcome.FilesFailed -gt 0) {
        $outcome.Message = "$($outcome.FilesFailed) file(s) could not be deleted"
    }

    Write-Log ("'{0}' done - {1} file(s) deleted, {2} freed" -f $name, $outcome.FilesDeleted, (Format-ByteSize $outcome.BytesFreed)) -Tag "Ok"
    return $outcome
}

function Start-VmRemoval {
    param(
        [object[]]$Inventories,
        [switch]$KeepDisks
    )

    if (-not $Inventories -or $Inventories.Count -eq 0) {
        Write-Log "Nothing to remove" -Tag "Info"
        return $true
    }

    $ids = @($Inventories | ForEach-Object { [string]$_.Id })
    $protectedFiles   = Get-ProtectedDiskPaths -DeleteVmIds $ids
    $protectedFolders = Get-ProtectedFolders -DeleteVmIds $ids
    $stopFolders      = Get-HostStopFolders

    Write-Log ("Removing {0} VM(s)" -f $Inventories.Count) -Tag "Start"

    $results = @()
    foreach ($inv in $Inventories) {
        $results += (Remove-SingleVm -Inventory $inv -ProtectedFiles $protectedFiles `
                -ProtectedFolders $protectedFolders -StopFolders $stopFolders -KeepDisks:$KeepDisks)
    }

    $ok = @($results | Where-Object { $_.Removed -and $_.FilesFailed -eq 0 })
    $partial = @($results | Where-Object { $_.Removed -and $_.FilesFailed -gt 0 })
    $failed = @($results | Where-Object { -not $_.Removed })
    $freed = [int64]0
    foreach ($r in $results) { $freed += [int64]$r.BytesFreed }

    Write-Log "---------- Summary ----------" -Tag "Info"
    foreach ($r in $results) {
        if ($r.Removed -and $r.FilesFailed -eq 0) {
            Write-Log ("OK      {0,-36} {1} freed" -f $r.Name, (Format-ByteSize $r.BytesFreed)) -Tag "Ok"
        }
        elseif ($r.Removed) {
            Write-Log ("PARTIAL {0,-36} {1}" -f $r.Name, $r.Message) -Tag "Error"
        }
        else {
            Write-Log ("FAILED  {0,-36} {1}" -f $r.Name, $r.Message) -Tag "Error"
        }
    }
    Write-Log ("Removed {0}, partial {1}, failed {2}, freed {3}" -f `
            $ok.Count, $partial.Count, $failed.Count, (Format-ByteSize $freed)) -Tag "Info"

    return ($failed.Count -eq 0 -and $partial.Count -eq 0)
}

# ---------------------------[ Interactive wizard ]---------------------------
function Show-YesNoMenu {
    param(
        [string]$Title,
        [string]$DefaultId = "no",
        [System.Collections.IDictionary]$StatusLines
    )
    $items = @(
        [pscustomobject]@{ Id = "yes"; Label = "Yes" }
        [pscustomobject]@{ Id = "no";  Label = "No" }
        [pscustomobject]@{ Id = "back"; Label = "Back" }
    )
    $idx = 1
    if ($DefaultId -eq "yes") { $idx = 0 }
    return (Show-Menu -Title "Confirm" -Question $Title -Items $items -SelectedIndex $idx -StatusLines $StatusLines)
}

function Get-VmRemovalLabel {
    param([object]$Inventory)

    $cp = "      "
    if ($Inventory.CheckpointCount -gt 0) { $cp = ("cp={0,-3}" -f $Inventory.CheckpointCount) }
    $cluster = "       "
    if (-not [string]::IsNullOrWhiteSpace([string]$Inventory.ClusterGroup)) { $cluster = "cluster" }

    return ("{0,-32} {1,-10} {2} {3}  {4,3} disk file(s)  {5}" -f `
            $Inventory.Name, $Inventory.State, $cp, $cluster, `
        @($Inventory.DiskFiles).Count, (Format-ByteSize ([int64]$Inventory.TotalBytes)))
}

function Write-VmRemovalReport {
    param([object[]]$Inventories)

    $total = [int64]0
    foreach ($inv in $Inventories) {
        $total += [int64]$inv.TotalBytes
        Write-Log ("  " + (Get-VmRemovalLabel -Inventory $inv)) -Tag "Info"
        foreach ($file in @($inv.DiskFiles)) {
            Write-Log ("      disk  {0}" -f $file.Path) -Tag "Info"
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$inv.ConfigPath)) {
            Write-Log ("      conf  {0}" -f $inv.ConfigPath) -Tag "Info"
        }
    }
    Write-Log ("Total disk footprint to be freed: {0}" -f (Format-ByteSize $total)) -Tag "Info"
}

function Select-RemoveVmsInteractive {
    param([object[]]$Inventories)

    $items = @()
    foreach ($inv in $Inventories) {
        $items += [pscustomobject]@{ Id = [string]$inv.Id; Label = (Get-VmRemovalLabel -Inventory $inv) }
    }

    $picked = Show-MultiSelectMenu -Title "Select VMs to delete" `
        -Question "Which VMs should be deleted? Space toggles, Enter confirms." -Items $items
    if ($null -eq $picked) { return $null }

    $set = @{}
    foreach ($p in @($picked)) { $set[[string]$p] = $true }
    return @($Inventories | Where-Object { $set.ContainsKey([string]$_.Id) })
}

function Confirm-RemovalInteractive {
    param([object[]]$Inventories)

    $total = [int64]0
    foreach ($inv in $Inventories) { $total += [int64]$inv.TotalBytes }
    $running = @($Inventories | Where-Object { [string]$_.State -ne "Off" }).Count

    $status = [ordered]@{
        vms      = "$($Inventories.Count) selected"
        size     = (Format-ByteSize $total)
        running  = $(if ($running -gt 0) { "$running will be force turned off" } else { "none" })
        files    = "config, VHD/VHDX and checkpoints are deleted"
    }

    $choice = Show-Menu -Title "Delete VMs" -StatusLines $status `
        -Question "This permanently deletes the VMs and their files. Continue?" -Items @(
        [pscustomobject]@{ Id = "back"; Label = "Cancel - go back" }
        [pscustomobject]@{ Id = "go";   Label = "Delete these VMs permanently" }
    ) -SelectedIndex 0
    if ($choice -ne "go") { return $false }

    Write-Host ""
    Write-Log "The following VMs and files will be deleted permanently:" -Tag "Info"
    Write-VmRemovalReport -Inventories $Inventories
    Write-Host ""
    $typed = Read-Host "Type DELETE (upper case) to confirm, anything else cancels"
    if ($typed -cne "DELETE") {
        Write-Log "Cancelled - nothing was deleted" -Tag "Info"
        return $false
    }
    return $true
}

function Invoke-RemoveWizard {
    param([switch]$AllVms)

    $all = @(Get-AllRemovalInventories)
    if ($all.Count -eq 0) {
        Write-Log "No VMs found on this host" -Tag "Info"
        Read-Host "Press Enter to continue"
        return
    }

    $selected = @()
    if ($AllVms) {
        $selected = $all
    }
    else {
        $selected = Select-RemoveVmsInteractive -Inventories $all
        if ($null -eq $selected) { return }
    }

    $selected = @($selected)
    if ($selected.Count -eq 0) {
        Write-Log "No VMs selected" -Tag "Info"
        Read-Host "Press Enter to continue"
        return
    }

    if (-not (Confirm-RemovalInteractive -Inventories $selected)) {
        Read-Host "Press Enter to continue"
        return
    }

    Start-VmRemoval -Inventories $selected | Out-Null
    Read-Host "Press Enter to continue"
}

function Start-InteractiveRemoveMenu {
    while ($true) {
        $main = Show-Menu -Title "Remove Hyper-V VMs" -Question "What should be deleted?" -Items @(
            [pscustomobject]@{ Id = "all";      Label = "All        delete every VM on this host" }
            [pscustomobject]@{ Id = "selected"; Label = "Selected   pick the VMs to delete" }
            [pscustomobject]@{ Id = "quit";     Label = "Quit" }
        )
        if ($null -eq $main -or $main -eq "quit") {
            Complete-Script -ExitCode 0
        }

        if ($main -eq "all") { Invoke-RemoveWizard -AllVms }
        elseif ($main -eq "selected") { Invoke-RemoveWizard }
    }
}

# ---------------------------[ Main ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "$env:COMPUTERNAME | $env:USERNAME | $applicationName" -Tag "Info"

try {
    if (-not (Test-IsAdministrator)) {
        throw "Please run Remove-Vms.ps1 elevated (Administrator)."
    }
    Confirm-HyperVAvailable

    $nameFilter = @()
    if ($VmName) {
        $nameFilter = @($VmName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ($ListOnly.IsPresent) {
        $all = @(Get-AllRemovalInventories)
        Write-Log ("Found {0} VM(s)" -f $all.Count) -Tag "Get"
        Write-VmRemovalReport -Inventories $all
        Complete-Script -ExitCode 0
    }

    $hasAutomation = $All.IsPresent -or ($nameFilter.Count -gt 0)
    if (-not $hasAutomation) {
        Start-InteractiveRemoveMenu
        Complete-Script -ExitCode 0
    }

    $all = @(Get-AllRemovalInventories)
    if ($all.Count -eq 0) {
        Write-Log "No VMs found on this host" -Tag "Info"
        Complete-Script -ExitCode 0
    }

    $selected = $all
    if ($nameFilter.Count -gt 0) {
        $selected = @($all | Where-Object { $nameFilter -contains $_.Name })
        $missing = @($nameFilter | Where-Object { -not ($all.Name -contains $_) })
        foreach ($m in $missing) {
            Write-Log "VM '$m' not found on this host" -Tag "Error"
        }
    }
    $selected = @($selected)
    if ($selected.Count -eq 0) {
        Write-Log "No matching VMs" -Tag "Error"
        Complete-Script -ExitCode 1
    }

    Write-Log "The following VMs and files will be deleted permanently:" -Tag "Info"
    Write-VmRemovalReport -Inventories $selected

    if (-not $Force.IsPresent) {
        Write-Log "Refusing to delete without -Force in non-interactive mode. Re-run with -Force, or start the script without parameters for the menu." -Tag "Error"
        Complete-Script -ExitCode 1
    }

    $ok = Start-VmRemoval -Inventories $selected -KeepDisks:$KeepDisks.IsPresent
    Complete-Script -ExitCode $(if ($ok) { 0 } else { 1 })
}
catch {
    Write-Log $_.Exception.Message -Tag "Error"
    Complete-Script -ExitCode 1
}
