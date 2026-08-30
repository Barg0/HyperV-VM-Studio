#Requires -Version 5.1
<#
.SYNOPSIS
    Convert Fixed (thick) Hyper-V VHDX disks to Dynamic (thin) to reclaim host disk space.

.DESCRIPTION
    Interactive console menu (same look as Migrate-Vms.ps1 / Build-Vms.ps1):
      Main: Check only / Convert selected / Convert all Fixed / Compact Dynamic / Exit
      Select VMs, then per-VM disk multi-select when a VM has more than one disk.

    Reclaim pipeline (community-approved only):
      1) Guest ReTrim  - Optimize-Volume -Defrag/-ReTrim inside the guest (PowerShell Direct)
      2) If that fails - offline Zero free space (sdelete -z / cipher /w)
      3) Host Optimize-VHD Retrim + Full

    Host-only Optimize-VHD without ReTrim/zero is NOT offered: it usually reclaims almost nothing
    after Fixed->Dynamic (the issue you hit). Max capacity stays the same; FileSize drops toward used data.

.NOTES
    Target shell : Windows PowerShell 5.1 and PowerShell 7
    Requires     : Administrator, Hyper-V role
    Guest ReTrim : PowerShell Direct + guest local admin credentials
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [switch]$CheckOnly,
    [switch]$ConvertAllFixed,
    [string[]]$VmName,
    [string[]]$DiskPath,
    [switch]$KeepSource,
    [switch]$StartAfter,
    [switch]$ZeroFreeSpace,
    [switch]$CompactOnly,
    [ValidateSet("GuestReTrim", "ZeroFreeSpace", "")]
    [string]$ReclaimMode = "",
    [pscredential]$GuestCredential
)

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "Convert-Vhdx"
$logFileName = (Get-Date -Format "yyyyMMdd-HHmm") + ".log"
$applicationName = "Convert-Vhdx"

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

$logFileDirectory = Join-Path -Path $projectRoot -ChildPath "logs\convert-vhdx"
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

$script:shutdownTimeoutSeconds = 600
$script:freeSpaceMargin = 1.10
$script:guestCredential = $null
$script:guestRetrimTimeoutSeconds = 600
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
"@ -Name ConvertVhdxVtConsole -Namespace ConvertVhdx -PassThru -ErrorAction Stop
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
    if (-not (Get-Command -Name Convert-VHD -ErrorAction SilentlyContinue)) {
        throw "Convert-VHD is not available. Install Hyper-V management tools."
    }
}

function ConvertTo-Int64Safe {
    # Get-VHD / property enumeration can yield Object[]; never cast arrays to Int64.
    param($Value)
    if ($null -eq $Value) { return [int64]0 }
    if ($Value -is [System.Array]) {
        if ($Value.Length -eq 0) { return [int64]0 }
        $Value = $Value[0]
        if ($null -eq $Value) { return [int64]0 }
        if ($Value -is [System.Array]) {
            return [int64]0
        }
    }
    try {
        return [int64]$Value
    }
    catch {
        return [int64]0
    }
}

function Format-ByteSize {
    param($Bytes)
    $n = ConvertTo-Int64Safe -Value $Bytes
    if ($n -ge 1TB) { return ("{0:N1} TB" -f ($n / 1TB)) }
    if ($n -ge 1GB) { return ("{0:N1} GB" -f ($n / 1GB)) }
    if ($n -ge 1MB) { return ("{0:N0} MB" -f ($n / 1MB)) }
    return ("{0} B" -f $n)
}

function Get-FreeBytesForPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return [int64]0 }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($full)
        $drive = New-Object System.IO.DriveInfo($root)
        if ($drive.IsReady) {
            return [int64]$drive.AvailableFreeSpace
        }
    }
    catch { }
    return [int64]0
}

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

# ---------------------------[ Inventory ]---------------------------
function Get-VmDiskInventory {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)

    $checkpoints = @()
    try { $checkpoints = @(Get-VMSnapshot -VM $VM -ErrorAction SilentlyContinue) } catch { }

    $disks = New-Object System.Collections.Generic.List[object]
    foreach ($drive in @(Get-VMHardDiskDrive -VM $VM -ErrorAction SilentlyContinue)) {
        $path = [string]$drive.Path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $fileName = [IO.Path]::GetFileName($path)
        $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
        $controller = ("{0} {1}:{2}" -f $drive.ControllerType, $drive.ControllerNumber, $drive.ControllerLocation)

        $vhdType = "Unknown"
        $sizeBytes = [int64]0
        $fileSizeBytes = [int64]0
        $minimumSizeBytes = [int64]0
        $attached = $false
        $parentPath = $null
        $vhdError = $null

        if ($extension -eq ".vhds") {
            $vhdType = "VhdSet"
        }
        elseif (Test-Path -LiteralPath $path) {
            try {
                # Force a single VHD object (pipeline enumeration can otherwise yield arrays).
                $vhd = Get-VHD -Path $path -ErrorAction Stop | Select-Object -First 1
                $vhdType = [string]$vhd.VhdType
                $sizeBytes = ConvertTo-Int64Safe -Value $vhd.Size
                $fileSizeBytes = ConvertTo-Int64Safe -Value $vhd.FileSize
                if ($null -ne $vhd.MinimumSize) {
                    $minimumSizeBytes = ConvertTo-Int64Safe -Value $vhd.MinimumSize
                }
                $attached = [bool]$vhd.Attached
                if ($vhd.ParentPath) {
                    $parentPath = [string]$vhd.ParentPath
                }
            }
            catch {
                $vhdError = $_.Exception.Message
                try {
                    $fileSizeBytes = ConvertTo-Int64Safe -Value (Get-Item -LiteralPath $path).Length
                    $sizeBytes = $fileSizeBytes
                }
                catch { }
            }
        }
        else {
            $vhdError = "File not found"
        }

        $isFixed = ($vhdType -eq "Fixed")
        $isConvertible = $isFixed -and ($extension -eq ".vhdx") -and [string]::IsNullOrWhiteSpace($vhdError) `
            -and [string]::IsNullOrWhiteSpace($parentPath) -and ($checkpoints.Count -eq 0)

        # Fixed FileSize is the thick allocation; MinimumSize is a weak lower bound after convert.
        $reclaimHintBytes = [int64]0
        if ($isFixed -and $fileSizeBytes -gt 0) {
            if ($minimumSizeBytes -gt 0 -and $minimumSizeBytes -lt $fileSizeBytes) {
                $reclaimHintBytes = $fileSizeBytes - $minimumSizeBytes
            }
            else {
                # Unknown used blocks; show thick size as upper-bound pressure on host.
                $reclaimHintBytes = $fileSizeBytes
            }
        }

        $disks.Add([pscustomobject]@{
                VmName            = [string]$VM.Name
                VmState           = [string]$VM.State
                Path              = $path
                FileName          = $fileName
                Extension         = $extension
                Controller        = $controller
                ControllerType    = [string]$drive.ControllerType
                ControllerNumber  = [int]$drive.ControllerNumber
                ControllerLocation = [int]$drive.ControllerLocation
                VhdType           = $vhdType
                SizeBytes         = $sizeBytes
                FileSizeBytes     = $fileSizeBytes
                MinimumSizeBytes  = $minimumSizeBytes
                ReclaimHintBytes  = $reclaimHintBytes
                Attached          = $attached
                ParentPath        = $parentPath
                CheckpointCount   = $checkpoints.Count
                IsFixed           = $isFixed
                IsConvertible     = $isConvertible
                VhdError          = $vhdError
                DiskId            = ("{0}|{1}" -f $VM.Name, $path)
            }) | Out-Null
    }

    # Do not use "return ,$array" here: ToArray() is already Object[], and the
    # unary comma nests it so callers treat one VM's disks as a single Object[].
    return $disks.ToArray()
}

function Get-HostDiskInventory {
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($vm in @(Get-VM -ErrorAction Stop | Sort-Object Name)) {
        foreach ($disk in @(Get-VmDiskInventory -VM $vm)) {
            # Skip accidental nested arrays from any caller/pipeline quirk.
            if ($disk -is [System.Array]) {
                foreach ($inner in @($disk)) {
                    if ($null -ne $inner -and -not ($inner -is [System.Array])) {
                        $all.Add($inner) | Out-Null
                    }
                }
                continue
            }
            $all.Add($disk) | Out-Null
        }
    }
    return $all.ToArray()
}

function Write-DiskInventoryReport {
    param([object[]]$Disks)

    $fixed = @($Disks | Where-Object { $_.IsFixed -eq $true })
    $dynamic = @($Disks | Where-Object { $_.VhdType -eq "Dynamic" })
    $thickBytes = [int64]0
    foreach ($d in $fixed) { $thickBytes += (ConvertTo-Int64Safe -Value $d.FileSizeBytes) }

    Write-Log ("Inventory: {0} disk(s) across host ({1} Fixed, {2} Dynamic)" -f $Disks.Count, $fixed.Count, $dynamic.Count) -Tag "Info"
    Write-Log ("Fixed thick on disk: {0}" -f (Format-ByteSize $thickBytes)) -Tag "Info"
    Write-Host ""
    Write-Host ("  {0,-28} {1,-10} {2,-12} {3,-8} {4,10} {5,10} {6}" -f `
            "VM", "State", "Controller", "Type", "Max", "OnDisk", "File") -ForegroundColor DarkCyan
    Write-Host ("  " + ("-" * 100)) -ForegroundColor DarkGray

    foreach ($d in $Disks) {
        $typeColor = "Gray"
        if ($d.IsFixed) { $typeColor = "Yellow" }
        elseif ($d.VhdType -eq "Dynamic") { $typeColor = "Green" }
        elseif ($d.VhdType -eq "Differencing") { $typeColor = "Magenta" }

        Write-Host ("  {0,-28} {1,-10} {2,-12} " -f $d.VmName, $d.VmState, $d.Controller) -NoNewline
        Write-Host ("{0,-8}" -f $d.VhdType) -NoNewline -ForegroundColor $typeColor
        Write-Host (" {0,10} {1,10} {2}" -f `
                (Format-ByteSize $d.SizeBytes), `
                (Format-ByteSize $d.FileSizeBytes), `
                $d.FileName)
        if ($d.CheckpointCount -gt 0) {
            Write-Host ("    checkpoints={0} (clear before convert)" -f $d.CheckpointCount) -ForegroundColor DarkYellow
        }
        if ($d.VhdError) {
            Write-Host ("    error: {0}" -f $d.VhdError) -ForegroundColor Red
        }
    }
    Write-Host ""
}

# ---------------------------[ Shutdown ]---------------------------
function Wait-VmStateOff {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 600
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $Name -ErrorAction Stop
        if ([string]$vm.State -eq "Off") {
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Stop-ConvertVmGracefully {
    param(
        [string]$Name,
        [switch]$Interactive
    )

    $vm = Get-VM -Name $Name -ErrorAction Stop
    $state = [string]$vm.State
    if ($state -eq "Off") {
        Write-Log "VM '$Name' already Off" -Tag "Info"
        return $true
    }

    if ($state -eq "Saved" -or $state -eq "Paused") {
        Write-Log "VM '$Name' is $state - resuming before graceful shutdown" -Tag "Run"
        try {
            if ($state -eq "Paused") { Resume-VM -Name $Name -ErrorAction Stop }
            else { Start-VM -Name $Name -ErrorAction Stop }
            Start-Sleep -Seconds 5
        }
        catch {
            Write-Log "Could not resume '$Name': $($_.Exception.Message)" -Tag "Error"
        }
    }

    Write-Log "Graceful shutdown of '$Name'" -Tag "Run"
    try {
        Stop-VM -Name $Name -ErrorAction Stop
    }
    catch {
        Write-Log "Stop-VM failed for '$Name': $($_.Exception.Message)" -Tag "Error"
    }

    if (Wait-VmStateOff -Name $Name -TimeoutSeconds $script:shutdownTimeoutSeconds) {
        Write-Log "VM '$Name' is Off" -Tag "Ok"
        return $true
    }

    if (-not $Interactive) {
        Write-Log "Shutdown timeout for '$Name' - forcing turn off" -Tag "Info"
        Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
        return (Wait-VmStateOff -Name $Name -TimeoutSeconds 60)
    }

    while ($true) {
        $items = @(
            [pscustomobject]@{ Id = "wait";  Label = "Wait more (another timeout)" }
            [pscustomobject]@{ Id = "force"; Label = "Force turn off (like power cord)" }
            [pscustomobject]@{ Id = "skip";  Label = "Skip this VM" }
        )
        $choice = Show-Menu -Title "Shutdown timeout" -Question "VM '$Name' did not shut down in time. What next?" -Items $items
        if ($null -eq $choice -or $choice -eq "skip") { return $false }
        if ($choice -eq "wait") {
            if (Wait-VmStateOff -Name $Name -TimeoutSeconds $script:shutdownTimeoutSeconds) { return $true }
            continue
        }
        if ($choice -eq "force") {
            Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue
            return (Wait-VmStateOff -Name $Name -TimeoutSeconds 60)
        }
    }
}

# ---------------------------[ Convert pipeline ]---------------------------
function Test-DiskConvertible {
    param([object]$Disk)

    if (-not $Disk.IsFixed) {
        return "Not Fixed (type=$($Disk.VhdType))"
    }
    if ($Disk.Extension -ne ".vhdx") {
        return "Only .vhdx is supported (got $($Disk.Extension))"
    }
    if ($Disk.VhdError) {
        return $Disk.VhdError
    }
    if ($Disk.CheckpointCount -gt 0) {
        return ("VM has {0} checkpoint(s) - remove/merge first" -f $Disk.CheckpointCount)
    }
    if (-not [string]::IsNullOrWhiteSpace($Disk.ParentPath)) {
        return "Differencing disk - merge first"
    }
    if ($Disk.VhdType -eq "Differencing") {
        return "Differencing disk - merge first"
    }
    if ($Disk.Extension -eq ".vhds" -or $Disk.VhdType -eq "VhdSet") {
        return "VHD Set (.vhds) is out of scope"
    }
    return $null
}

function Get-FirstFreeDriveLetter {
    $used = @{}
    foreach ($letter in [IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() }) {
        $used[$letter] = $true
    }
    foreach ($code in 90..68) {
        # Z..D - leave A/B/C alone
        $letter = [char]$code
        $key = [string]$letter
        if (-not $used.ContainsKey($key)) {
            return $key
        }
    }
    return $null
}

function Wait-MountedVhdReady {
    param(
        [int]$DiskNumber,
        [int]$TimeoutSeconds = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
            if ($null -ne $disk) {
                $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)
                if ($parts.Count -gt 0) {
                    return $true
                }
            }
        }
        catch { }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Get-SdeleteExecutable {
    # Both toolbox\ and the project root are checked, so an existing sdelete drop next to
    # Build-Vms.ps1 keeps working after this script moved into toolbox\.
    $candidates = @(
        (Join-Path $PSScriptRoot "tools\sdelete64.exe"),
        (Join-Path $PSScriptRoot "tools\sdelete.exe"),
        (Join-Path $PSScriptRoot "sdelete64.exe"),
        (Join-Path $PSScriptRoot "sdelete.exe"),
        (Join-Path $projectRoot "tools\sdelete64.exe"),
        (Join-Path $projectRoot "tools\sdelete.exe"),
        (Join-Path $projectRoot "sdelete64.exe"),
        (Join-Path $projectRoot "sdelete.exe")
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command -Name "sdelete64.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command -Name "sdelete.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-ZeroVhdFreeSpace {
    # Overwrite NTFS free space with zeros so Optimize-VHD Prezeroed can reclaim blocks.
    # Prefer Sysinternals sdelete -z (community standard); fall back to cipher /w then zero-fill.
    param([string]$Path)

    Write-Log "Zeroing free space inside '$Path' (this can take a while)" -Tag "Run"
    $sdelete = Get-SdeleteExecutable
    if ($sdelete) {
        Write-Log ("Using sdelete: {0}" -f $sdelete) -Tag "Info"
    }
    else {
        Write-Log "sdelete not found - using cipher zero-fill. For sdelete, put sdelete64.exe next to the script or in PATH" -Tag "Warn"
    }

    try {
        $disk = Mount-VHD -Path $Path -Passthru -ErrorAction Stop | Get-Disk -ErrorAction Stop
        $diskNumber = [int]$disk.Number
        if (-not (Wait-MountedVhdReady -DiskNumber $diskNumber)) {
            Write-Log "Mounted VHD volumes did not appear in time - skip zeroing" -Tag "Info"
            return
        }

        try {
            Set-Disk -Number $diskNumber -IsOffline $false -ErrorAction SilentlyContinue
            Set-Disk -Number $diskNumber -IsReadOnly $false -ErrorAction SilentlyContinue
        }
        catch { }

        $partitions = @(Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue)
        foreach ($part in $partitions) {
            $partType = [string]$part.Type
            if ($partType -match "System|Reserved|Recovery") { continue }
            if ($part.Size -lt 100MB) { continue }

            $vol = $null
            try { $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue } catch { }
            if ($null -eq $vol) { continue }

            $fs = [string]$vol.FileSystem
            if ($fs -ne "NTFS" -and $fs -ne "ReFS") {
                Write-Log ("  skip partition {0} filesystem={1}" -f $part.PartitionNumber, $fs) -Tag "Info"
                continue
            }

            $letter = $null
            if ($vol.DriveLetter) {
                $letter = [string]$vol.DriveLetter
            }
            else {
                $letter = Get-FirstFreeDriveLetter
                if (-not $letter) {
                    Write-Log "  no free drive letter for zeroing" -Tag "Info"
                    continue
                }
                try {
                    Set-Partition -DiskNumber $diskNumber -PartitionNumber $part.PartitionNumber `
                        -NewDriveLetter $letter -ErrorAction Stop
                }
                catch {
                    Write-Log ("  could not assign drive letter: {0}" -f $_.Exception.Message) -Tag "Warn"
                    continue
                }
            }

            $root = ("{0}:\" -f $letter)
            $remaining = ConvertTo-Int64Safe -Value $vol.SizeRemaining
            Write-Log ("  volume {0} free={1} - wiping free space" -f $root, (Format-ByteSize $remaining)) -Tag "Run"

            $done = $false
            if ($sdelete) {
                try {
                    $p = Start-Process -FilePath $sdelete -ArgumentList @("-accepteula", "-nobanner", "-z", ("{0}:" -f $letter)) `
                        -Wait -PassThru -WindowStyle Hidden
                    Write-Log ("  sdelete -z exit code {0}" -f $p.ExitCode) -Tag "Info"
                    $done = $true
                }
                catch {
                    Write-Log ("  sdelete failed: {0}" -f $_.Exception.Message) -Tag "Warn"
                }
            }

            if (-not $done) {
                $cipher = Get-Command -Name cipher.exe -ErrorAction SilentlyContinue
                if ($cipher) {
                    $p = Start-Process -FilePath $cipher.Source -ArgumentList @("/w:$root") `
                        -Wait -PassThru -WindowStyle Hidden
                    Write-Log ("  cipher /w exit code {0}" -f $p.ExitCode) -Tag "Info"
                    $done = $true
                }
            }

            if (-not $done) {
                $zeroPath = Join-Path $root ("cvt-zero-{0}.tmp" -f ([guid]::NewGuid().ToString("N")))
                $chunk = New-Object byte[] (8MB)
                $stream = $null
                try {
                    $stream = [System.IO.File]::Open($zeroPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    while ($true) {
                        $volNow = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
                        if ($null -eq $volNow) { break }
                        $freeNow = ConvertTo-Int64Safe -Value $volNow.SizeRemaining
                        if ($freeNow -lt 16MB) { break }
                        $writeLen = [int]([Math]::Min($chunk.Length, $freeNow - 8MB))
                        if ($writeLen -le 0) { break }
                        $stream.Write($chunk, 0, $writeLen)
                    }
                }
                catch {
                    Write-Log ("  zero-fill ended: {0}" -f $_.Exception.Message) -Tag "Info"
                }
                finally {
                    if ($null -ne $stream) { $stream.Dispose() }
                    Remove-Item -LiteralPath $zeroPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    catch {
        Write-Log ("Zero free space failed: {0}" -f $_.Exception.Message) -Tag "Warn"
    }
    finally {
        Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
    }
}

function Wait-VmStateRunning {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 300
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $Name -ErrorAction Stop
        if ([string]$vm.State -eq "Running") {
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-GuestCredentialInteractive {
    if ($null -ne $script:guestCredential) {
        return $script:guestCredential
    }
    Write-Host ""
    Write-Host "  Guest ReTrim needs PowerShell Direct credentials (local admin inside the VM)." -ForegroundColor Yellow
    Write-Host "  Tip: use DOMAIN\user or .\Administrator" -ForegroundColor DarkGray
    Write-Host ""
    $script:guestCredential = Get-Credential -Message "Guest OS credentials for PowerShell Direct"
    return $script:guestCredential
}

function Invoke-GuestVolumeRetrim {
    # Community recipe: Optimize-Volume -ReTrim (and Defrag) inside the guest before host Optimize-VHD.
    param(
        [string]$VmName,
        [pscredential]$Credential,
        [switch]$Interactive
    )

    if ($null -eq $Credential) {
        if ($Interactive) {
            $Credential = Get-GuestCredentialInteractive
        }
        if ($null -eq $Credential) {
            Write-Log "Guest ReTrim skipped: no credentials" -Tag "Warn"
            return $false
        }
    }

    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ([string]$vm.State -ne "Running") {
        Write-Log ("Starting VM '{0}' for guest ReTrim" -f $VmName) -Tag "Run"
        Start-VM -Name $VmName -ErrorAction Stop
        if (-not (Wait-VmStateRunning -Name $VmName -TimeoutSeconds 180)) {
            Write-Log ("VM '{0}' did not reach Running for guest ReTrim" -f $VmName) -Tag "Error"
            return $false
        }
        # Give guest OS time to finish boot / Integration Services
        Write-Log "Waiting 45s for the guest OS and Integration Services" -Tag "Run"
        Start-Sleep -Seconds 45
    }

    $scriptBlock = {
        $ErrorActionPreference = "Continue"
        $report = New-Object System.Collections.Generic.List[string]
        $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object {
                $_.DriveLetter -and
                ($_.FileSystem -eq "NTFS" -or $_.FileSystem -eq "ReFS") -and
                $_.DriveType -eq "Fixed"
            })
        if ($vols.Count -eq 0) {
            $report.Add("No fixed NTFS/ReFS volumes with drive letters found.")
            return $report.ToArray()
        }
        foreach ($v in $vols) {
            $letter = [string]$v.DriveLetter
            $report.Add(("Volume {0}: size={1:N0}MB free={2:N0}MB" -f $letter, ($v.Size / 1MB), ($v.SizeRemaining / 1MB)))
            try {
                Optimize-Volume -DriveLetter $letter -Defrag -ErrorAction Stop | Out-Null
                $report.Add(("  Defrag OK on {0}:" -f $letter))
            }
            catch {
                $report.Add(("  Defrag skip on {0}:: {1}" -f $letter, $_.Exception.Message))
            }
            try {
                Optimize-Volume -DriveLetter $letter -ReTrim -ErrorAction Stop | Out-Null
                $report.Add(("  ReTrim OK on {0}:" -f $letter))
            }
            catch {
                $report.Add(("  ReTrim FAILED on {0}:: {1}" -f $letter, $_.Exception.Message))
            }
        }
        return $report.ToArray()
    }

    Write-Log ("Guest ReTrim via PowerShell Direct on '{0}'" -f $VmName) -Tag "Run"
    try {
        $output = Invoke-Command -VMName $VmName -Credential $Credential -ScriptBlock $scriptBlock -ErrorAction Stop
        foreach ($line in @($output)) {
            if ($null -ne $line -and -not [string]::IsNullOrWhiteSpace([string]$line)) {
                Write-Log ("  guest: {0}" -f $line) -Tag "Info"
            }
        }
        Write-Log "Guest ReTrim finished" -Tag "Ok"
        return $true
    }
    catch {
        Write-Log ("Guest ReTrim failed: {0}" -f $_.Exception.Message) -Tag "Error"
        Write-Log "    Enable Integration Services, use an admin account, or pick ZeroFreeSpace" -Tag "Error"
        return $false
    }
}

function Invoke-OptimizeDynamicVhd {
    param(
        [string]$Path,
        [ValidateSet("ZeroFreeSpace", "HostCompact")]
        [string]$ReclaimMode = "HostCompact"
    )

    $before = ConvertTo-Int64Safe -Value ((Get-VHD -Path $Path -ErrorAction SilentlyContinue | Select-Object -First 1).FileSize)
    Write-Log ("Compacting '{0}' (onDisk before={1}, mode={2})" -f $Path, (Format-ByteSize $before), $ReclaimMode) -Tag "Run"

    # Zeroing is host-offline; GuestReTrim already ran while VM was up, then we HostCompact.
    if ($ReclaimMode -eq "ZeroFreeSpace") {
        Invoke-ZeroVhdFreeSpace -Path $Path
        try {
            Optimize-VHD -Path $Path -Mode Prezeroed -ErrorAction Stop
            Write-Log "Optimize-VHD Prezeroed completed" -Tag "Ok"
        }
        catch {
            Write-Log ("Optimize-VHD Prezeroed failed: {0}" -f $_.Exception.Message) -Tag "Warn"
        }
    }

    $mounted = $false
    try {
        Mount-VHD -Path $Path -ReadOnly -Passthru -ErrorAction Stop | Out-Null
        $mounted = $true
        Start-Sleep -Seconds 2

        try {
            Optimize-VHD -Path $Path -Mode Retrim -ErrorAction Stop
            Write-Log "Optimize-VHD Retrim completed" -Tag "Ok"
        }
        catch {
            Write-Log ("Optimize-VHD Retrim skipped: {0}" -f $_.Exception.Message) -Tag "Warn"
        }

        try {
            Optimize-VHD -Path $Path -Mode Full -ErrorAction Stop
            Write-Log "Optimize-VHD Full completed" -Tag "Ok"
        }
        catch {
            Write-Log ("Optimize-VHD Full failed: {0} - trying Quick" -f $_.Exception.Message) -Tag "Warn"
            try {
                Optimize-VHD -Path $Path -Mode Quick -ErrorAction Stop
                Write-Log "Optimize-VHD Quick completed" -Tag "Ok"
            }
            catch {
                Write-Log ("Optimize-VHD Quick failed: {0}" -f $_.Exception.Message) -Tag "Warn"
            }
        }
    }
    catch {
        Write-Log ("Optimize RO mount failed: {0} - trying Pretrimmed" -f $_.Exception.Message) -Tag "Warn"
        try {
            if ($mounted) {
                Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
                $mounted = $false
            }
            Optimize-VHD -Path $Path -Mode Pretrimmed -ErrorAction Stop
            Write-Log "Optimize-VHD Pretrimmed completed" -Tag "Ok"
        }
        catch {
            Write-Log ("Optimize-VHD Pretrimmed skipped: {0}" -f $_.Exception.Message) -Tag "Warn"
        }
    }
    finally {
        if ($mounted) {
            Dismount-VHD -Path $Path -ErrorAction SilentlyContinue
        }
    }

    $after = ConvertTo-Int64Safe -Value ((Get-VHD -Path $Path -ErrorAction SilentlyContinue | Select-Object -First 1).FileSize)
    $saved = [int64]0
    if ($before -gt $after) { $saved = $before - $after }
    Write-Log ("Compact result: onDisk {0} -> {1} (saved {2})" -f `
            (Format-ByteSize $before), (Format-ByteSize $after), (Format-ByteSize $saved)) -Tag "Ok"
}

function Convert-FixedDiskToDynamic {
    param(
        [object]$Disk,
        [switch]$KeepSourceFile,
        [switch]$WhatIfMode,
        [ValidateSet("GuestReTrim", "ZeroFreeSpace")]
        [string]$ReclaimMode = "GuestReTrim"
    )

    $result = [pscustomobject]@{
        VmName          = $Disk.VmName
        Path            = $Disk.Path
        Success         = $false
        Skipped         = $false
        Message         = ""
        BeforeFileSize  = (ConvertTo-Int64Safe -Value $Disk.FileSizeBytes)
        AfterFileSize   = [int64]0
        ReclaimedBytes  = [int64]0
    }

    $blockReason = Test-DiskConvertible -Disk $Disk
    if ($blockReason) {
        $result.Skipped = $true
        $result.Message = $blockReason
        Write-Log ("Skip '{0}' on '{1}': {2}" -f $Disk.FileName, $Disk.VmName, $blockReason) -Tag "Info"
        return $result
    }

    $sourcePath = $Disk.Path
    $directory = Split-Path -Parent $sourcePath
    $baseName = [IO.Path]::GetFileNameWithoutExtension($sourcePath)
    $tempPath = Join-Path $directory ($baseName + ".convert-temp.vhdx")
    $oldPath = Join-Path $directory ($baseName + ".vhdx.fixed-old")

    if (Test-Path -LiteralPath $tempPath) {
        $result.Message = "Temp file already exists: $tempPath"
        Write-Log $result.Message -Tag "Error"
        return $result
    }
    if (Test-Path -LiteralPath $oldPath) {
        $result.Message = "Leftover .fixed-old exists: $oldPath (remove or rename first)"
        Write-Log $result.Message -Tag "Error"
        return $result
    }

    $needed = [int64]([double]$Disk.FileSizeBytes * $script:freeSpaceMargin)
    $free = Get-FreeBytesForPath -Path $directory
    if ($free -gt 0 -and $free -lt $needed) {
        $result.Message = ("Not enough free space on volume (need ~{0}, have {1})" -f `
                (Format-ByteSize $needed), (Format-ByteSize $free))
        Write-Log $result.Message -Tag "Error"
        return $result
    }

    if ($WhatIfMode) {
        $result.Success = $true
        $result.Skipped = $true
        $result.Message = "WhatIf: would convert Fixed -> Dynamic"
        Write-Log ("WhatIf: convert '{0}' Fixed -> Dynamic" -f $sourcePath) -Tag "Info"
        return $result
    }

    Write-Log ("Converting '{0}' Fixed -> Dynamic" -f $sourcePath) -Tag "Run"
    Write-Log ("  before: type=Fixed size={0} onDisk={1}" -f `
            (Format-ByteSize $Disk.SizeBytes), `
            (Format-ByteSize $Disk.FileSizeBytes)) -Tag "Info"

    try {
        Convert-VHD -Path $sourcePath -DestinationPath $tempPath -VHDType Dynamic -ErrorAction Stop
    }
    catch {
        $result.Message = "Convert-VHD failed: $($_.Exception.Message)"
        Write-Log $result.Message -Tag "Error"
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        return $result
    }

    try {
        $newVhd = Get-VHD -Path $tempPath -ErrorAction Stop | Select-Object -First 1
        if ([string]$newVhd.VhdType -ne "Dynamic") {
            throw "Converted file type is '$($newVhd.VhdType)', expected Dynamic"
        }
        # After GuestReTrim, host compact is enough; ZeroFreeSpace does offline wipe here.
        $optimizeMode = $ReclaimMode
        if ($ReclaimMode -eq "GuestReTrim") {
            $optimizeMode = "HostCompact"
        }
        Invoke-OptimizeDynamicVhd -Path $tempPath -ReclaimMode $optimizeMode
        $newVhd = Get-VHD -Path $tempPath -ErrorAction Stop | Select-Object -First 1
        $afterSize = ConvertTo-Int64Safe -Value $newVhd.FileSize

        Write-Log ("  after convert+compact: type=Dynamic onDisk={0}" -f (Format-ByteSize $afterSize)) -Tag "Info"

        # Point VM at temp path first so original can be renamed.
        $drive = Get-VMHardDiskDrive -VMName $Disk.VmName -ControllerType $Disk.ControllerType `
            -ControllerNumber $Disk.ControllerNumber -ControllerLocation $Disk.ControllerLocation -ErrorAction Stop
        Set-VMHardDiskDrive -VMHardDiskDrive $drive -Path $tempPath -ErrorAction Stop
        Write-Log "VM hard disk path set to temp Dynamic file" -Tag "Run"

        Move-Item -LiteralPath $sourcePath -Destination $oldPath -ErrorAction Stop
        Move-Item -LiteralPath $tempPath -Destination $sourcePath -ErrorAction Stop

        $drive = Get-VMHardDiskDrive -VMName $Disk.VmName -ControllerType $Disk.ControllerType `
            -ControllerNumber $Disk.ControllerNumber -ControllerLocation $Disk.ControllerLocation -ErrorAction Stop
        Set-VMHardDiskDrive -VMHardDiskDrive $drive -Path $sourcePath -ErrorAction Stop
        Write-Log "Restored original path with Dynamic VHDX" -Tag "Ok"

        $final = Get-VHD -Path $sourcePath -ErrorAction Stop | Select-Object -First 1
        $result.AfterFileSize = ConvertTo-Int64Safe -Value $final.FileSize
        if ($result.BeforeFileSize -gt $result.AfterFileSize) {
            $result.ReclaimedBytes = $result.BeforeFileSize - $result.AfterFileSize
        }
        $result.Success = $true
        $result.Message = ("Reclaimed {0}" -f (Format-ByteSize $result.ReclaimedBytes))
        Write-Log ("Done '{0}': {1}" -f $Disk.FileName, $result.Message) -Tag "Ok"

        if (-not $KeepSourceFile) {
            Remove-Item -LiteralPath $oldPath -Force -ErrorAction Stop
            Write-Log "Removed old Fixed file '$oldPath'" -Tag "Run"
        }
        else {
            Write-Log "Kept old Fixed file at '$oldPath' (-KeepSource)" -Tag "Info"
        }
    }
    catch {
        $result.Message = "Post-convert swap failed: $($_.Exception.Message)"
        Write-Log $result.Message -Tag "Error"
        Write-Log "Manual recovery: check paths temp='$tempPath' old='$oldPath' source='$sourcePath'" -Tag "Info"
        # Best effort: if temp exists and VM points at temp, leave it; do not delete blindly.
        return $result
    }

    return $result
}

function Start-ConvertSelectedDisks {
    param(
        [object[]]$Disks,
        [switch]$Interactive,
        [switch]$KeepSourceFile,
        [switch]$StartVmsAfter,
        [switch]$WhatIfMode,
        [ValidateSet("GuestReTrim", "ZeroFreeSpace")]
        [string]$ReclaimMode = "GuestReTrim",
        [pscredential]$GuestCredential
    )

    if (-not $Disks -or $Disks.Count -eq 0) {
        Write-Log "No disks selected." -Tag "Info"
        return @()
    }

    if ($GuestCredential) {
        $script:guestCredential = $GuestCredential
    }

    $byVm = $Disks | Group-Object -Property VmName
    $results = New-Object System.Collections.Generic.List[object]
    $priorState = @{}

    foreach ($group in $byVm) {
        $vmName = [string]$group.Name
        $vmDisks = @($group.Group)
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        $priorState[$vmName] = [string]$vm.State

        Write-Log ("==== VM '{0}' ({1} Fixed disk(s) selected, reclaim={2}) ====" -f `
                $vmName, $vmDisks.Count, $ReclaimMode) -Tag "Start"

        $vmReclaimMode = $ReclaimMode

        if (-not $WhatIfMode -and $vmReclaimMode -eq "GuestReTrim") {
            $cred = $script:guestCredential
            if ($null -eq $cred -and $Interactive) {
                $cred = Get-GuestCredentialInteractive
            }
            $retrimOk = Invoke-GuestVolumeRetrim -VmName $vmName -Credential $cred -Interactive:$Interactive
            if (-not $retrimOk) {
                Write-Log "Guest ReTrim failed - using community fallback: offline ZeroFreeSpace" -Tag "Warn"
                $vmReclaimMode = "ZeroFreeSpace"
            }
        }

        if (-not $WhatIfMode) {
            $ok = Stop-ConvertVmGracefully -Name $vmName -Interactive:$Interactive
            if (-not $ok) {
                foreach ($d in $vmDisks) {
                    $results.Add([pscustomobject]@{
                            VmName         = $vmName
                            Path           = $d.Path
                            Success        = $false
                            Skipped        = $true
                            Message        = "VM shutdown skipped/failed"
                            BeforeFileSize = (ConvertTo-Int64Safe -Value $d.FileSizeBytes)
                            AfterFileSize  = [int64]0
                            ReclaimedBytes = [int64]0
                        }) | Out-Null
                }
                continue
            }
        }

        foreach ($disk in $vmDisks) {
            $freshList = @(Get-VmDiskInventory -VM (Get-VM -Name $vmName -ErrorAction Stop))
            $fresh = $freshList | Where-Object { $_.Path -eq $disk.Path } | Select-Object -First 1
            if (-not $fresh) { $fresh = $disk }

            $r = Convert-FixedDiskToDynamic -Disk $fresh -KeepSourceFile:$KeepSourceFile `
                -WhatIfMode:$WhatIfMode -ReclaimMode $vmReclaimMode
            $results.Add($r) | Out-Null
        }

        if ($StartVmsAfter -and -not $WhatIfMode) {
            $wasRunning = ($priorState[$vmName] -eq "Running")
            if ($wasRunning) {
                $failed = @($results | Where-Object { $_.VmName -eq $vmName -and -not $_.Success -and -not $_.Skipped })
                if ($failed.Count -eq 0) {
                    Write-Log "Starting VM '$vmName' (-StartAfter)" -Tag "Run"
                    try {
                        Start-VM -Name $vmName -ErrorAction Stop
                        Write-Log "VM '$vmName' started" -Tag "Ok"
                    }
                    catch {
                        Write-Log "Start-VM failed for '$vmName': $($_.Exception.Message)" -Tag "Error"
                    }
                }
                else {
                    Write-Log "'$vmName' left off - one or more disk converts failed" -Tag "Warn"
                }
            }
        }
    }

    return $results.ToArray()
}

function Write-ConvertSummary {
    param([object[]]$Results)

    $ok = @($Results | Where-Object { $_.Success -and -not $_.Skipped })
    $skip = @($Results | Where-Object { $_.Skipped })
    $fail = @($Results | Where-Object { -not $_.Success -and -not $_.Skipped })
    $reclaimed = [int64]0
    foreach ($r in $ok) { $reclaimed += (ConvertTo-Int64Safe -Value $r.ReclaimedBytes) }

    Write-Host ""
    Write-Log "==================== Summary ====================" -Tag "Info"
    Write-Log ("Converted : {0}" -f $ok.Count) -Tag "Ok"
    Write-Log ("Skipped   : {0}" -f $skip.Count) -Tag "Info"
    Write-Log ("Failed    : {0}" -f $fail.Count) -Tag $(if ($fail.Count -gt 0) { "Error" } else { "Info" })
    Write-Log ("Reclaimed : {0}" -f (Format-ByteSize $reclaimed)) -Tag "Ok"

    foreach ($r in $Results) {
        $tag = "Info"
        if ($r.Success -and -not $r.Skipped) { $tag = "Ok" }
        elseif (-not $r.Success -and -not $r.Skipped) { $tag = "Error" }
        Write-Log ("  [{0}] {1} :: {2}" -f $r.VmName, $r.Path, $r.Message) -Tag $tag
    }

    return ($fail.Count -eq 0)
}

function Start-CompactSelectedDisks {
    param(
        [object[]]$Disks,
        [switch]$Interactive,
        [switch]$StartVmsAfter,
        [switch]$WhatIfMode,
        [ValidateSet("GuestReTrim", "ZeroFreeSpace")]
        [string]$ReclaimMode = "GuestReTrim",
        [pscredential]$GuestCredential
    )

    if (-not $Disks -or $Disks.Count -eq 0) {
        Write-Log "No disks selected." -Tag "Info"
        return @()
    }

    if ($GuestCredential) {
        $script:guestCredential = $GuestCredential
    }

    $byVm = $Disks | Group-Object -Property VmName
    $results = New-Object System.Collections.Generic.List[object]
    $priorState = @{}

    foreach ($group in $byVm) {
        $vmName = [string]$group.Name
        $vmDisks = @($group.Group)
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        $priorState[$vmName] = [string]$vm.State
        $vmReclaimMode = $ReclaimMode

        Write-Log ("==== Compact VM '{0}' ({1} disk(s), reclaim={2}) ====" -f `
                $vmName, $vmDisks.Count, $vmReclaimMode) -Tag "Start"

        if (-not $WhatIfMode -and $vmReclaimMode -eq "GuestReTrim") {
            $cred = $script:guestCredential
            if ($null -eq $cred -and $Interactive) {
                $cred = Get-GuestCredentialInteractive
            }
            $retrimOk = Invoke-GuestVolumeRetrim -VmName $vmName -Credential $cred -Interactive:$Interactive
            if (-not $retrimOk) {
                Write-Log "Guest ReTrim failed - using community fallback: offline ZeroFreeSpace" -Tag "Info"
                $vmReclaimMode = "ZeroFreeSpace"
            }
        }

        if (-not $WhatIfMode) {
            $ok = Stop-ConvertVmGracefully -Name $vmName -Interactive:$Interactive
            if (-not $ok) {
                foreach ($d in $vmDisks) {
                    $results.Add([pscustomobject]@{
                            VmName         = $vmName
                            Path           = $d.Path
                            Success        = $false
                            Skipped        = $true
                            Message        = "VM shutdown skipped/failed"
                            BeforeFileSize = (ConvertTo-Int64Safe -Value $d.FileSizeBytes)
                            AfterFileSize  = [int64]0
                            ReclaimedBytes = [int64]0
                        }) | Out-Null
                }
                continue
            }
        }

        foreach ($disk in $vmDisks) {
            $before = ConvertTo-Int64Safe -Value $disk.FileSizeBytes
            $r = [pscustomobject]@{
                VmName         = $vmName
                Path           = $disk.Path
                Success        = $false
                Skipped        = $false
                Message        = ""
                BeforeFileSize = $before
                AfterFileSize  = [int64]0
                ReclaimedBytes = [int64]0
            }

            if ($disk.VhdType -ne "Dynamic") {
                $r.Skipped = $true
                $r.Message = ("Not Dynamic (type={0})" -f $disk.VhdType)
                $results.Add($r) | Out-Null
                continue
            }
            if ($disk.CheckpointCount -gt 0) {
                $r.Skipped = $true
                $r.Message = "VM has checkpoints - clear first"
                $results.Add($r) | Out-Null
                continue
            }
            if ($WhatIfMode) {
                $r.Success = $true
                $r.Skipped = $true
                $r.Message = ("WhatIf: would compact Dynamic VHDX ({0})" -f $vmReclaimMode)
                $results.Add($r) | Out-Null
                continue
            }

            try {
                $optimizeMode = "HostCompact"
                if ($vmReclaimMode -eq "ZeroFreeSpace") {
                    $optimizeMode = "ZeroFreeSpace"
                }
                Invoke-OptimizeDynamicVhd -Path $disk.Path -ReclaimMode $optimizeMode
                $afterVhd = Get-VHD -Path $disk.Path -ErrorAction Stop | Select-Object -First 1
                $after = ConvertTo-Int64Safe -Value $afterVhd.FileSize
                $r.AfterFileSize = $after
                if ($before -gt $after) { $r.ReclaimedBytes = $before - $after }
                $r.Success = $true
                $r.Message = ("Reclaimed {0}" -f (Format-ByteSize $r.ReclaimedBytes))
                Write-Log ("Compact done '{0}': {1}" -f $disk.FileName, $r.Message) -Tag "Ok"
            }
            catch {
                $r.Message = $_.Exception.Message
                Write-Log ("Compact failed '{0}': {1}" -f $disk.FileName, $r.Message) -Tag "Error"
            }
            $results.Add($r) | Out-Null
        }

        if ($StartVmsAfter -and -not $WhatIfMode) {
            if ($priorState[$vmName] -eq "Running") {
                $failed = @($results | Where-Object { $_.VmName -eq $vmName -and -not $_.Success -and -not $_.Skipped })
                if ($failed.Count -eq 0) {
                    try {
                        Start-VM -Name $vmName -ErrorAction Stop
                        Write-Log "VM '$vmName' started" -Tag "Ok"
                    }
                    catch {
                        Write-Log ("Start-VM failed for '{0}': {1}" -f $vmName, $_.Exception.Message) -Tag "Error"
                    }
                }
            }
        }
    }

    return $results.ToArray()
}

# ---------------------------[ Selection UI ]---------------------------
function Select-ConvertVmsInteractive {
    param(
        [object[]]$Disks,
        [ValidateSet("Fixed", "Dynamic")]
        [string]$DiskKind = "Fixed"
    )

    if ($DiskKind -eq "Fixed") {
        $pool = @($Disks | Where-Object { $_.IsFixed -and $_.Extension -eq ".vhdx" })
        $emptyMsg = "No Fixed .vhdx disks found on this host."
        $question = "Which VMs have Fixed disks to convert?"
    }
    else {
        $pool = @($Disks | Where-Object { $_.VhdType -eq "Dynamic" -and $_.Extension -eq ".vhdx" })
        $emptyMsg = "No Dynamic .vhdx disks found on this host."
        $question = "Which VMs have Dynamic disks to compact?"
    }

    $byVm = $pool | Group-Object -Property VmName | Sort-Object Name
    if ($byVm.Count -eq 0) {
        Write-Log $emptyMsg -Tag "Info"
        return @()
    }

    $items = @()
    foreach ($g in $byVm) {
        $vmDisks = @($g.Group)
        $onDisk = [int64]0
        foreach ($d in $vmDisks) { $onDisk += (ConvertTo-Int64Safe -Value $d.FileSizeBytes) }
        $state = [string]$vmDisks[0].VmState
        $cp = [int]$vmDisks[0].CheckpointCount
        $cpNote = ""
        if ($cp -gt 0) { $cpNote = "  CP=$cp" }
        $kindLabel = if ($DiskKind -eq "Fixed") { "Fixed" } else { "Dynamic" }
        $label = ("{0,-32} {1,-10} {2}={3}  onDisk={4}{5}" -f `
                $g.Name, $state, $kindLabel, $vmDisks.Count, (Format-ByteSize $onDisk), $cpNote)
        $items += [pscustomobject]@{ Id = [string]$g.Name; Label = $label }
    }

    $picked = Show-MultiSelectMenu -Title "Select VMs" -Question $question -Items $items
    if ($null -eq $picked) { return $null }

    $set = @{}
    foreach ($p in @($picked)) { $set[[string]$p] = $true }
    return @($pool | Where-Object { $set.ContainsKey([string]$_.VmName) })
}

function Select-ConvertDisksInteractive {
    param(
        [object[]]$VmDisks,
        [string]$ActionVerb = "convert"
    )

    if (-not $VmDisks -or $VmDisks.Count -eq 0) {
        return @()
    }

    $selected = New-Object System.Collections.Generic.List[object]
    $byVm = $VmDisks | Group-Object -Property VmName | Sort-Object Name

    foreach ($g in $byVm) {
        $disks = @($g.Group)
        if ($disks.Count -eq 1) {
            Write-Log ("VM '{0}': single disk auto-selected ({1})" -f $g.Name, $disks[0].FileName) -Tag "Info"
            $selected.Add($disks[0]) | Out-Null
            continue
        }

        $items = @()
        foreach ($d in $disks) {
            $label = ("{0,-12} {1,-8} max={2} onDisk={3}  {4}" -f `
                    $d.Controller, $d.VhdType, `
                    (Format-ByteSize $d.SizeBytes), `
                    (Format-ByteSize $d.FileSizeBytes), `
                    $d.FileName)
            $items += [pscustomobject]@{ Id = [string]$d.DiskId; Label = $label }
        }

        $status = @{
            vm    = [string]$g.Name
            disks = ("{0}" -f $disks.Count)
        }
        $picked = Show-MultiSelectMenu -Title "Select disks" `
            -Question ("VM '{0}' has multiple disks - which to {1}?" -f $g.Name, $ActionVerb) `
            -Items $items -StatusLines $status
        if ($null -eq $picked) {
            Write-Log ("Disk selection cancelled for VM '{0}' - skipping VM" -f $g.Name) -Tag "Warn"
            continue
        }
        $idSet = @{}
        foreach ($p in @($picked)) { $idSet[[string]$p] = $true }
        foreach ($d in $disks) {
            if ($idSet.ContainsKey([string]$d.DiskId)) {
                $selected.Add($d) | Out-Null
            }
        }
    }

    return $selected.ToArray()
}

function Resolve-DisksFromParameters {
    param(
        [object[]]$AllDisks,
        [string[]]$VmNames,
        [string[]]$DiskPaths,
        [switch]$AllFixed,
        [switch]$DynamicOnly
    )

    $pool = @($AllDisks | Where-Object { $_.Extension -eq ".vhdx" })
    if ($DynamicOnly) {
        $pool = @($pool | Where-Object { $_.VhdType -eq "Dynamic" })
    }
    else {
        $pool = @($pool | Where-Object { $_.IsFixed })
    }

    if ($DiskPaths -and @($DiskPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        $wanted = @{}
        foreach ($p in $DiskPaths) {
            if (-not [string]::IsNullOrWhiteSpace($p)) {
                $wanted[$p.Trim().ToLowerInvariant()] = $true
            }
        }
        return @($AllDisks | Where-Object {
                $_.Extension -eq ".vhdx" -and $wanted.ContainsKey($_.Path.ToLowerInvariant())
            })
    }

    if ($AllFixed -and -not $DynamicOnly) {
        return $pool
    }

    if ($VmNames -and @($VmNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        $wantedVm = @{}
        foreach ($n in $VmNames) {
            if (-not [string]::IsNullOrWhiteSpace($n)) {
                $wantedVm[$n.Trim().ToLowerInvariant()] = $true
            }
        }
        return @($pool | Where-Object { $wantedVm.ContainsKey($_.VmName.ToLowerInvariant()) })
    }

    return @()
}

function Start-InteractiveConvertMenu {
    while ($true) {
        $all = @(Get-HostDiskInventory)
        $fixedCount = @($all | Where-Object { $_.IsFixed }).Count
        $dynamicCount = @($all | Where-Object { $_.VhdType -eq "Dynamic" }).Count
        $thick = [int64]0
        foreach ($d in @($all | Where-Object { $_.IsFixed -eq $true })) {
            $thick += (ConvertTo-Int64Safe -Value $d.FileSizeBytes)
        }

        $status = @{
            fixed   = ("{0} disk(s)" -f $fixedCount)
            dynamic = ("{0} disk(s)" -f $dynamicCount)
            thick   = (Format-ByteSize $thick)
        }

        $main = Show-Menu -Title "Convert-Vhdx" -Question "Fixed (thick) -> Dynamic (thin) space reclaim" -StatusLines $status -Items @(
            [pscustomobject]@{ Id = "check";   Label = "Check only        Inventory Fixed vs Dynamic (no changes)" }
            [pscustomobject]@{ Id = "select";  Label = "Convert selected  Fixed -> Dynamic (pick VMs + disks)" }
            [pscustomobject]@{ Id = "all";     Label = "Convert all Fixed Every Fixed .vhdx on this host" }
            [pscustomobject]@{ Id = "compact"; Label = "Compact Dynamic   Reclaim space on already-Dynamic disks" }
            [pscustomobject]@{ Id = "exit";    Label = "Exit" }
        )

        if ($null -eq $main -or $main -eq "exit") {
            return
        }

        if ($main -eq "check") {
            Write-DiskInventoryReport -Disks $all
            Read-Host "Press Enter to continue"
            continue
        }

        $isCompact = ($main -eq "compact")
        $targets = @()

        if ($main -eq "all") {
            $targets = @($all | Where-Object { $_.IsFixed -and $_.Extension -eq ".vhdx" })
            if ($targets.Count -eq 0) {
                Write-Log "No Fixed .vhdx disks found." -Tag "Info"
                Read-Host "Press Enter to continue"
                continue
            }
            Write-DiskInventoryReport -Disks $targets
            $confirm = Show-YesNoMenu -Title ("Convert ALL {0} Fixed disk(s) to Dynamic?" -f $targets.Count) -DefaultId "no"
            if ($confirm -ne "yes") { continue }
        }
        elseif ($main -eq "select" -or $main -eq "compact") {
            $kind = if ($isCompact) { "Dynamic" } else { "Fixed" }
            $verb = if ($isCompact) { "compact" } else { "convert" }
            $vmDisks = Select-ConvertVmsInteractive -Disks $all -DiskKind $kind
            if ($null -eq $vmDisks) { continue }
            if ($vmDisks.Count -eq 0) {
                Write-Log ("No {0} disks in selection." -f $kind) -Tag "Info"
                Read-Host "Press Enter to continue"
                continue
            }
            $targets = @(Select-ConvertDisksInteractive -VmDisks $vmDisks -ActionVerb $verb)
            if ($targets.Count -eq 0) {
                Write-Log "No disks selected." -Tag "Info"
                Read-Host "Press Enter to continue"
                continue
            }
            Write-Log ("Selected {0} disk(s) for {1}" -f $targets.Count, $verb) -Tag "Info"
            foreach ($t in $targets) {
                Write-Log ("  {0} :: {1} ({2})" -f $t.VmName, $t.FileName, (Format-ByteSize $t.FileSizeBytes)) -Tag "Get"
            }
            $confirm = Show-YesNoMenu -Title ("{0} {1} disk(s) now?" -f $(if ($isCompact) { "Compact" } else { "Convert" }), $targets.Count) -DefaultId "no"
            if ($confirm -ne "yes") { continue }
        }

        Write-Log "Reclaim pipeline: Guest ReTrim, offline ZeroFreeSpace if Direct fails" -Tag "Info"
        $reclaimMode = "GuestReTrim"

        $startChoice = Show-YesNoMenu -Title "Start VMs afterward if they were Running?" -DefaultId "yes"
        if ($null -eq $startChoice -or $startChoice -eq "back") { continue }
        $doStart = ($startChoice -eq "yes")

        if ($isCompact) {
            $results = @(Start-CompactSelectedDisks -Disks $targets -Interactive -StartVmsAfter:$doStart `
                    -ReclaimMode $reclaimMode -GuestCredential $script:guestCredential)
        }
        else {
            $keepChoice = Show-YesNoMenu -Title "Keep old Fixed files (.vhdx.fixed-old) after success?" -DefaultId "no"
            if ($null -eq $keepChoice -or $keepChoice -eq "back") { continue }
            $doKeep = ($keepChoice -eq "yes")
            $results = @(Start-ConvertSelectedDisks -Disks $targets -Interactive -KeepSourceFile:$doKeep `
                    -StartVmsAfter:$doStart -ReclaimMode $reclaimMode -GuestCredential $script:guestCredential)
        }
        Write-ConvertSummary -Results $results | Out-Null
        Read-Host "Press Enter to continue"
    }
}

# ---------------------------[ Main ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "$env:COMPUTERNAME | $env:USERNAME | $applicationName" -Tag "Info"

try {
    if (-not (Test-IsAdministrator)) {
        throw "Please run Convert-Vhdx.ps1 elevated (Administrator)."
    }
    Confirm-HyperVAvailable

    $hasAutomation = $CheckOnly.IsPresent -or $ConvertAllFixed.IsPresent -or $CompactOnly.IsPresent `
        -or ($VmName -and @($VmName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) `
        -or ($DiskPath -and @($DiskPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)

    if (-not $hasAutomation) {
        Start-InteractiveConvertMenu
        Complete-Script -ExitCode 0
    }

    $all = @(Get-HostDiskInventory)

    if ($CheckOnly.IsPresent) {
        Write-DiskInventoryReport -Disks $all
        Complete-Script -ExitCode 0
    }

    $whatIfMode = ($WhatIfPreference -eq [System.Management.Automation.ActionPreference]::Continue)

    # Community default: Guest ReTrim. Offline ZeroFreeSpace only when requested or as Direct fallback.
    $resolvedReclaim = $ReclaimMode
    if ([string]::IsNullOrWhiteSpace($resolvedReclaim)) {
        if ($PSBoundParameters.ContainsKey("ZeroFreeSpace") -and $ZeroFreeSpace) {
            $resolvedReclaim = "ZeroFreeSpace"
        }
        else {
            $resolvedReclaim = "GuestReTrim"
        }
    }

    if ($GuestCredential) {
        $script:guestCredential = $GuestCredential
    }

    if ($resolvedReclaim -eq "GuestReTrim" -and $null -eq $script:guestCredential -and -not $whatIfMode) {
        throw "Guest ReTrim needs -GuestCredential (or run interactively to be prompted). Or use -ReclaimMode ZeroFreeSpace."
    }

    if ($CompactOnly.IsPresent) {
        $targets = @(Resolve-DisksFromParameters -AllDisks $all -VmNames $VmName -DiskPaths $DiskPath -DynamicOnly)
        if ($targets.Count -eq 0) {
            throw "No Dynamic .vhdx disks matched for compact."
        }
        Write-Log ("Automation compact: {0} disk(s), ReclaimMode={1}" -f $targets.Count, $resolvedReclaim) -Tag "Info"
        $results = @(Start-CompactSelectedDisks -Disks $targets -Interactive:$false `
                -StartVmsAfter:$StartAfter.IsPresent -WhatIfMode:$whatIfMode `
                -ReclaimMode $resolvedReclaim -GuestCredential $script:guestCredential)
        $ok = Write-ConvertSummary -Results $results
        Complete-Script -ExitCode $(if ($ok) { 0 } else { 1 })
    }

    $targets = @(Resolve-DisksFromParameters -AllDisks $all -VmNames $VmName -DiskPaths $DiskPath -AllFixed:$ConvertAllFixed.IsPresent)
    if ($targets.Count -eq 0) {
        throw "No Fixed .vhdx disks matched the given parameters."
    }

    Write-Log ("Automation convert: {0} Fixed disk(s), ReclaimMode={1}" -f $targets.Count, $resolvedReclaim) -Tag "Info"
    $results = @(Start-ConvertSelectedDisks -Disks $targets -Interactive:$false `
            -KeepSourceFile:$KeepSource.IsPresent -StartVmsAfter:$StartAfter.IsPresent `
            -WhatIfMode:$whatIfMode -ReclaimMode $resolvedReclaim -GuestCredential $script:guestCredential)
    $ok = Write-ConvertSummary -Results $results
    Complete-Script -ExitCode $(if ($ok) { 0 } else { 1 })
}
catch {
    Write-Log $_.Exception.Message -Tag "Error"
    Complete-Script -ExitCode 1
}
