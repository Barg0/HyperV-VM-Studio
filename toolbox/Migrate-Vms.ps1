#Requires -Version 5.1
<#
.SYNOPSIS
    Export and import Hyper-V VMs for host reinstall / migration (USB, SATA, or NAS).

.DESCRIPTION
    Interactive console menu (same look as Build-Vms.ps1 / New-Vhdx.ps1):
      Main: Import / Export / Check
      Export: all or selected VMs, Local (drive letter) or Network (UNC + staging)
      Import: all or selected packages into VmPath / VhdPath with short folders
      Check: host preflight or validate a backup package

    Graceful shutdown before export (default). vTPM certificates follow TPM VMs.
    Switches are optional. Inventory is JSON only (manifest.json).

.NOTES
    Target shell : Windows PowerShell 5.1 and PowerShell 7
    Requires     : Administrator, Hyper-V role
#>

[CmdletBinding()]
param (
    [switch]$CheckOnly,
    [switch]$ExportAll,
    [switch]$ImportAll,
    [string[]]$VmName,
    [string]$DestinationPath,
    [string]$SourcePath,
    [string]$StagingPath,
    [string]$VmPath,
    [string]$VhdPath,
    [switch]$IncludeSwitches,
    [switch]$IncludeHostSettings,
    [switch]$RestoreHostInventory,
    [switch]$StartAfterImport,
    [switch]$AllowRunningExport,
    [ValidateSet("CaptureCrashConsistentState", "CaptureSavedState", "CaptureDataConsistentState", "")]
    [string]$CaptureLiveState = "",
    [switch]$SkipVtpmCerts,
    [switch]$DirectExport,
    [string]$SmbUser,
    [string]$SmbPassword
)

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "Migrate-Vms"
$logFileName = (Get-Date -Format "yyyyMMdd-HHmm") + ".log"
$applicationName = "Migrate-Vms"

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

$logFileDirectory = Join-Path -Path $projectRoot -ChildPath "logs\migrate-vms"
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
$script:freeSpaceMargin = 1.15
# Remembered switch remap for the current import run: $null | "skip" | switch name
$script:importSwitchRemapChoice = $null
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
"@ -Name MigrateVmsVtConsole -Namespace MigrateVms -PassThru -ErrorAction Stop
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

# ---------------------------[ Path / size helpers ]---------------------------
function Test-IsUncPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return ($Path.StartsWith("\\") -or $Path.StartsWith("//"))
}

function Get-SanitizedFolderName {
    param([string]$Name)
    $n = ([string]$Name).Trim()
    if ([string]::IsNullOrWhiteSpace($n)) { return "vm" }
    foreach ($bad in [IO.Path]::GetInvalidFileNameChars()) {
        $n = $n.Replace([string]$bad, "-")
    }
    if ([string]::IsNullOrWhiteSpace($n)) { return "vm" }
    return $n.ToLowerInvariant()
}

function Get-ShortFolderName {
    param([string]$VmName)
    $n = ([string]$VmName).Trim()
    if ([string]::IsNullOrWhiteSpace($n)) { return "vm" }
    $dot = $n.IndexOf(".")
    if ($dot -gt 0) {
        $n = $n.Substring(0, $dot)
    }
    return (Get-SanitizedFolderName -Name $n)
}

function Test-FolderNameInUse {
    param(
        [string]$Candidate,
        [string]$VmPathRoot,
        [string]$VhdPathRoot,
        [hashtable]$Used
    )
    if ($Used.ContainsKey($Candidate)) { return $true }
    if (Test-Path -LiteralPath (Join-Path $VmPathRoot $Candidate)) { return $true }
    if (Test-Path -LiteralPath (Join-Path $VhdPathRoot $Candidate)) { return $true }
    return $false
}

function Get-UniqueImportFolder {
    param(
        [string]$ShortName,
        [string]$HyperVName,
        [string]$VmPathRoot,
        [string]$VhdPathRoot,
        [hashtable]$Used
    )
    # Prefer short name (strip FQDN). On collision, use full FQDN as folder name.
    if (-not (Test-FolderNameInUse -Candidate $ShortName -VmPathRoot $VmPathRoot -VhdPathRoot $VhdPathRoot -Used $Used)) {
        $Used[$ShortName] = $true
        return $ShortName
    }

    $fqdnFolder = Get-SanitizedFolderName -Name $HyperVName
    if ($fqdnFolder -eq $ShortName) {
        # Name had no domain part; fall back to numeric only in that edge case
        $i = 2
        $candidate = "{0}-{1}" -f $ShortName, $i
        while (Test-FolderNameInUse -Candidate $candidate -VmPathRoot $VmPathRoot -VhdPathRoot $VhdPathRoot -Used $Used) {
            $i++
            $candidate = "{0}-{1}" -f $ShortName, $i
        }
        Write-Log "Folder '$ShortName' in use; using '$candidate' (no FQDN available)" -Tag "Info"
        $Used[$candidate] = $true
        return $candidate
    }

    if (-not (Test-FolderNameInUse -Candidate $fqdnFolder -VmPathRoot $VmPathRoot -VhdPathRoot $VhdPathRoot -Used $Used)) {
        Write-Log "Folder '$ShortName' in use; using FQDN folder '$fqdnFolder'" -Tag "Info"
        $Used[$fqdnFolder] = $true
        return $fqdnFolder
    }

    # Both short and FQDN taken (re-import); append counter to FQDN
    $i = 2
    $candidate = "{0}-{1}" -f $fqdnFolder, $i
    while (Test-FolderNameInUse -Candidate $candidate -VmPathRoot $VmPathRoot -VhdPathRoot $VhdPathRoot -Used $Used) {
        $i++
        $candidate = "{0}-{1}" -f $fqdnFolder, $i
    }
    Write-Log "Folders '$ShortName' and '$fqdnFolder' in use; using '$candidate'" -Tag "Info"
    $Used[$candidate] = $true
    return $candidate
}

function Get-FreeBytesForPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return [int64]0 }
    try {
        if (Test-IsUncPath -Path $Path) {
            $root = $Path
            if (-not $root.EndsWith("\")) { $root = $root.TrimEnd("\") }
            $info = New-Object System.IO.DriveInfo($root)
            # DriveInfo may not work for UNC on all hosts; fall back
            if ($info.IsReady) {
                return [int64]$info.AvailableFreeSpace
            }
        }
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

function Format-ByteSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1TB) { return ("{0:N1} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N0} MB" -f ($Bytes / 1MB)) }
    return ("{0} B" -f $Bytes)
}

function Read-ConsolePath {
    param(
        [string]$PromptLabel,
        [string]$DefaultValue = "",
        [string]$ExampleHint = ""
    )
    $hint = ""
    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
        $hint = " [$DefaultValue]"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ExampleHint)) {
        $hint = " (e.g. $ExampleHint)"
    }
    $raw = Read-Host "$PromptLabel$hint"
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $DefaultValue
    }
    return $raw.Trim().Trim('"')
}

function Read-SecurePassword {
    param([string]$Prompt = "Password")
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    return $secure
}

function Convert-SecureStringToPlain {
    param([securestring]$Secure)
    if ($null -eq $Secure) { return "" }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Write-JsonFile {
    param(
        [object]$InputObject,
        [string]$Path
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $InputObject | ConvertTo-Json -Depth 10
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($Path, $json, $utf8Bom)
}

function Read-JsonFile {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Invoke-RobocopyCopy {
    param(
        [string]$Source,
        [string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $robocopyArgs = @($Source, $Destination, "/E", "/COPY:DAT", "/R:2", "/W:5", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
    & robocopy @robocopyArgs | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) {
        throw "Robocopy failed with exit code $code (source=$Source dest=$Destination)"
    }
}

function Write-LockErrorHint {
    param([string]$Message)
    Write-Log $Message -Tag "Error"
    Write-Log "    Exclude the Hyper-V / VHDX paths from real-time antivirus, stop the VM, then retry" -Tag "Error"
}

function Connect-MigrateSmbShare {
    param(
        [string]$Path,
        [string]$UserName,
        [string]$PlainPassword
    )
    if ([string]::IsNullOrWhiteSpace($UserName)) { return }
    Write-Log "Mapping SMB credentials for '$Path' as '$UserName'" -Tag "Run"
    net use $Path /user:$UserName $PlainPassword 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "net use failed (exit $LASTEXITCODE) for '$Path' - continuing with whatever credentials are already cached" -Tag "Error"
    }
}

# ---------------------------[ Inventory ]---------------------------
function Get-VmHasVtpm {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    try {
        $sec = Get-VMSecurity -VM $VM -ErrorAction Stop
        if ($null -ne $sec.TpmEnabled) {
            return [bool]$sec.TpmEnabled
        }
    }
    catch { }
    return $false
}

function Get-VmDiskSizeBytes {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    $total = [int64]0
    try {
        $drives = @(Get-VMHardDiskDrive -VM $VM -ErrorAction SilentlyContinue)
        foreach ($d in $drives) {
            $p = [string]$d.Path
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if (Test-Path -LiteralPath $p) {
                $total += (Get-Item -LiteralPath $p).Length
            }
            try {
                $vhd = Get-VHD -Path $p -ErrorAction SilentlyContinue
                if ($vhd -and $vhd.FileSize -gt $total) {
                    # prefer summed file sizes; keep max of file length
                }
            }
            catch { }
        }
    }
    catch { }
    return $total
}

function Get-MigrateVmInventory {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)

    $hasVtpm = Get-VmHasVtpm -VM $VM
    $sizeBytes = Get-VmDiskSizeBytes -VM $VM
    $checkpoints = @()
    try { $checkpoints = @(Get-VMSnapshot -VM $VM -ErrorAction SilentlyContinue) } catch { }

    $nics = @()
    try {
        foreach ($nic in @(Get-VMNetworkAdapter -VM $VM -ErrorAction SilentlyContinue)) {
            $vlan = $null
            try {
                $vlanInfo = Get-VMNetworkAdapterVlan -VMNetworkAdapter $nic -ErrorAction SilentlyContinue
                if ($vlanInfo) {
                    $vlan = [pscustomobject]@{
                        Mode         = [string]$vlanInfo.Mode
                        AccessVlanId = $vlanInfo.AccessVlanId
                    }
                }
            }
            catch { }
            $nics += [pscustomobject]@{
                Name       = [string]$nic.Name
                SwitchName = [string]$nic.SwitchName
                MacAddress = [string]$nic.MacAddress
                Vlan       = $vlan
            }
        }
    }
    catch { }

    $disks = @()
    $hasPassthrough = $false
    try {
        foreach ($d in @(Get-VMHardDiskDrive -VM $VM -ErrorAction SilentlyContinue)) {
            if ($d.Path -and ($d.Path -match '^[0-9]')) { $hasPassthrough = $true }
            if ([string]::IsNullOrWhiteSpace([string]$d.Path) -and $d.DiskNumber) { $hasPassthrough = $true }
            $len = [int64]0
            if ($d.Path -and (Test-Path -LiteralPath $d.Path)) {
                $len = (Get-Item -LiteralPath $d.Path).Length
            }
            $disks += [pscustomobject]@{
                ControllerType     = [string]$d.ControllerType
                ControllerNumber   = $d.ControllerNumber
                ControllerLocation = $d.ControllerLocation
                Path               = [string]$d.Path
                SizeBytes          = $len
            }
        }
    }
    catch { }

    $dvdPaths = @()
    try {
        foreach ($dvd in @(Get-VMDvdDrive -VM $VM -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$dvd.Path)) {
                $dvdPaths += [string]$dvd.Path
            }
        }
    }
    catch { }

    $generation = 1
    try { $generation = [int]$VM.Generation } catch { }

    return [pscustomobject]@{
        Name              = [string]$VM.Name
        Id                = [string]$VM.Id
        State             = [string]$VM.State
        Generation        = $generation
        Version           = [string]$VM.Version
        ProcessorCount    = [int]$VM.ProcessorCount
        MemoryStartupBytes = [int64]$VM.MemoryStartup
        CheckpointCount   = $checkpoints.Count
        HasVtpm           = $hasVtpm
        HasPassthrough    = $hasPassthrough
        EstimatedSizeBytes = $sizeBytes
        NetworkAdapters   = $nics
        HardDisks         = $disks
        DvdPaths          = $dvdPaths
        ShortFolderName   = (Get-ShortFolderName -VmName $VM.Name)
        ExportStatus      = "pending"
        ExportMessage     = ""
    }
}

function Get-AllMigrateInventories {
    $list = @()
    foreach ($vm in @(Get-VM -ErrorAction Stop)) {
        $list += (Get-MigrateVmInventory -VM $vm)
    }
    return $list
}

# ---------------------------[ Shutdown / DVD / merge ]---------------------------
function Wait-VmStateOff {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 600
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $vm = Get-VM -Name $Name -ErrorAction Stop
        if ([string]$vm.State -eq "Off") {
            return $true
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Stop-MigrateVmGracefully {
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

function Test-VmDiskFileLocked {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $stream.Close()
        return $false
    }
    catch {
        return $true
    }
}

function Wait-VmDiskMerge {
    param([string]$Name)
    Write-Log "Waiting for the disk merge on '$Name'" -Tag "Run"
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Date) -lt $deadline) {
        $busy = $false
        try {
            foreach ($d in @(Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue)) {
                if (-not $d.Path) { continue }
                if (Test-VmDiskFileLocked -Path $d.Path) {
                    $busy = $true
                }
            }
        }
        catch { }

        if (-not $busy) {
            return
        }
        Write-Log "Disk(s) for '$Name' still locked (merge in progress) - waiting" -Tag "Info"
        Start-Sleep -Seconds 2
    }
    Write-Log "Timed out waiting for the disk merge on '$Name' - continuing" -Tag "Warn"
}

function Disconnect-VmDvdMedia {
    param([string]$Name)
    try {
        foreach ($dvd in @(Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue)) {
            $p = [string]$dvd.Path
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            Write-Log "Disconnected DVD on '$Name': $p" -Tag "Run"
            Set-VMDvdDrive -VMName $Name -ControllerNumber $dvd.ControllerNumber `
                -ControllerLocation $dvd.ControllerLocation -Path $null -ErrorAction Stop
        }
    }
    catch {
        Write-Log "DVD disconnect warning for '$Name': $($_.Exception.Message)" -Tag "Warn"
    }
}

# ---------------------------[ vTPM / switches ]---------------------------
function Export-VtpmCertificates {
    param(
        [string]$PfxPath,
        [securestring]$Password
    )
    $storePath = "Cert:\LocalMachine\Shielded VM Local Certificates"
    if (-not (Test-Path -LiteralPath $storePath)) {
        throw "Certificate store '$storePath' not found. Enable vTPM on a VM once to create it, or create the store."
    }
    $certs = @(Get-ChildItem -Path $storePath -ErrorAction Stop)
    if ($certs.Count -eq 0) {
        throw "No certificates found in Shielded VM Local Certificates store."
    }
    $dir = Split-Path -Parent $PfxPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Export all certs into one PFX by exporting each then... Export-PfxCertificate one at a time into same file overwrites.
    # Export first cert with -ChainOption, then others - best effort: export each to numbered files and also a combined approach.
    $i = 0
    foreach ($cert in $certs) {
        $i++
        $target = if ($i -eq 1) { $PfxPath } else { ($PfxPath -replace '\.pfx$', "-$i.pfx") }
        Export-PfxCertificate -Cert $cert -FilePath $target -Password $Password -ErrorAction Stop | Out-Null
        Write-Log "Exported vTPM cert thumbprint $($cert.Thumbprint) -> $target" -Tag "Ok"
    }
    return $certs.Count
}

function Import-VtpmCertificates {
    param(
        [string]$HostFolder,
        [securestring]$Password
    )
    $storePath = "Cert:\LocalMachine\Shielded VM Local Certificates"
    if (-not (Test-Path -LiteralPath $storePath)) {
        New-Item -Path $storePath -Force | Out-Null
        Write-Log "Created certificate store '$storePath'" -Tag "Run"
    }
    $pfxFiles = @(Get-ChildItem -LiteralPath $HostFolder -Filter "*.pfx" -ErrorAction SilentlyContinue)
    if ($pfxFiles.Count -eq 0) {
        throw "No .pfx files found in $HostFolder"
    }
    foreach ($pfx in $pfxFiles) {
        Import-PfxCertificate -FilePath $pfx.FullName -CertStoreLocation $storePath `
            -Password $Password -Exportable -ErrorAction Stop | Out-Null
        Write-Log "Imported vTPM cert from $($pfx.Name)" -Tag "Ok"
    }
}

function Export-VmSwitchInventory {
    param([string]$JsonPath)
    $data = @()
    foreach ($sw in @(Get-VMSwitch -ErrorAction Stop)) {
        $type = [string]$sw.SwitchType
        if ($type -eq "1") { $type = "External" }
        elseif ($type -eq "2") { $type = "Internal" }
        elseif ($type -eq "3") { $type = "Private" }
        $adapter = $null
        try { $adapter = [string]$sw.NetAdapterInterfaceDescription } catch { }
        $data += [pscustomobject]@{
            Name               = [string]$sw.Name
            SwitchType         = $type
            AllowManagementOS  = [bool]$sw.AllowManagementOS
            NetAdapterNames    = $adapter
            Notes              = [string]$sw.Notes
        }
    }
    Write-JsonFile -InputObject $data -Path $JsonPath
    Write-Log "Wrote switch inventory ($($data.Count)) -> $JsonPath" -Tag "Ok"
}

function Import-VmSwitchInventory {
    param(
        [string]$JsonPath,
        [switch]$Interactive
    )
    if (-not (Test-Path -LiteralPath $JsonPath)) {
        Write-Log "No switch inventory at $JsonPath" -Tag "Info"
        return
    }
    $switches = @(Read-JsonFile -Path $JsonPath)
    foreach ($sw in $switches) {
        $name = [string]$sw.Name
        if (Get-VMSwitch -Name $name -ErrorAction SilentlyContinue) {
            Write-Log "Switch '$name' already exists - skipping" -Tag "Info"
            continue
        }
        $type = [string]$sw.SwitchType
        Write-Log "Creating switch '$name' ($type)" -Tag "Run"
        if ($type -eq "External") {
            $adapter = [string]$sw.NetAdapterNames
            $nic = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
                $_.InterfaceDescription -eq $adapter -or $_.Name -eq $adapter
            } | Select-Object -First 1
            if (-not $nic -and $Interactive) {
                $nics = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" })
                $items = @()
                foreach ($n in $nics) {
                    $items += [pscustomobject]@{ Id = $n.Name; Label = ("{0}  ({1})" -f $n.Name, $n.InterfaceDescription) }
                }
                $items += [pscustomobject]@{ Id = "skip"; Label = "Skip this switch" }
                $pick = Show-Menu -Title "Network adapter" -Question "Pick NIC for external switch '$name'" -Items $items
                if ($null -eq $pick -or $pick -eq "skip") { continue }
                $nic = Get-NetAdapter -Name $pick
            }
            if (-not $nic) {
                Write-Log "No NIC for external switch '$name' - skipping" -Tag "Error"
                continue
            }
            New-VMSwitch -Name $name -NetAdapterName $nic.Name -AllowManagementOS ([bool]$sw.AllowManagementOS) -ErrorAction Stop | Out-Null
        }
        elseif ($type -eq "Internal") {
            New-VMSwitch -Name $name -SwitchType Internal -ErrorAction Stop | Out-Null
        }
        else {
            New-VMSwitch -Name $name -SwitchType Private -ErrorAction Stop | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$sw.Notes)) {
            Set-VMSwitch -Name $name -Notes ([string]$sw.Notes) -ErrorAction SilentlyContinue
        }
        Write-Log "Created switch '$name'" -Tag "Ok"
    }
}

function Export-VmHostSettings {
    param([string]$JsonPath)
    $h = Get-VMHost
    $obj = [pscustomobject]@{
        ComputerName                     = [string]$h.ComputerName
        VirtualMachinePath               = [string]$h.VirtualMachinePath
        VirtualHardDiskPath              = [string]$h.VirtualHardDiskPath
        MacAddressMinimum                = [string]$h.MacAddressMinimum
        MacAddressMaximum                = [string]$h.MacAddressMaximum
        NumaSpanningEnabled              = [bool]$h.NumaSpanningEnabled
        VirtualMachineMigrationEnabled   = [bool]$h.VirtualMachineMigrationEnabled
    }
    Write-JsonFile -InputObject $obj -Path $JsonPath
    Write-Log "Wrote host settings -> $JsonPath" -Tag "Ok"
}

# ---------------------------[ Package / free space ]---------------------------
function New-MigratePackageRoot {
    param([string]$DestinationRoot)
    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $folder = "{0}_{1}" -f $env:COMPUTERNAME, $stamp
    $root = Join-Path -Path $DestinationRoot -ChildPath (Join-Path "Migrate-Vms" $folder)
    New-Item -ItemType Directory -Path (Join-Path $root "vms") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root "host") -Force | Out-Null
    return $root
}

function Test-ExportPackageVm {
    param([string]$VmExportFolder)
    $vmcx = @(Get-ChildItem -LiteralPath (Join-Path $VmExportFolder "Virtual Machines") -Filter "*.vmcx" -ErrorAction SilentlyContinue)
    $vhdx = @(Get-ChildItem -LiteralPath (Join-Path $VmExportFolder "Virtual Hard Disks") -Filter "*.vhdx" -ErrorAction SilentlyContinue)
    $vhd  = @(Get-ChildItem -LiteralPath (Join-Path $VmExportFolder "Virtual Hard Disks") -Filter "*.vhd" -ErrorAction SilentlyContinue)
    if ($vmcx.Count -lt 1) { return $false }
    if (($vhdx.Count + $vhd.Count) -lt 1) { return $false }
    return $true
}

function Assert-FreeSpace {
    param(
        [string]$Path,
        [int64]$RequiredBytes,
        [string]$Label
    )
    $free = Get-FreeBytesForPath -Path $Path
    $need = [int64]([math]::Ceiling($RequiredBytes * $script:freeSpaceMargin))
    if ($free -gt 0 -and $free -lt $need) {
        throw ("Insufficient free space on {0}: have {1}, need ~{2} (incl. 15% margin)" -f `
            $Label, (Format-ByteSize $free), (Format-ByteSize $need))
    }
    if ($free -gt 0) {
        Write-Log ("{0} free space {1} (need ~{2})" -f $Label, (Format-ByteSize $free), (Format-ByteSize $need)) -Tag "Info"
    }
}

function Get-LocalStagingPath {
    param(
        [string]$Preferred,
        [int64]$RequiredBytes
    )
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        if (-not (Test-Path -LiteralPath $Preferred)) {
            New-Item -ItemType Directory -Path $Preferred -Force | Out-Null
        }
        Assert-FreeSpace -Path $Preferred -RequiredBytes $RequiredBytes -Label "Staging"
        return $Preferred
    }
    $candidates = @()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne "Fixed") { continue }
        if (-not $d.IsReady) { continue }
        $candidates += $d
    }
    $candidates = @($candidates | Sort-Object AvailableFreeSpace -Descending)
    foreach ($d in $candidates) {
        $need = [int64]([math]::Ceiling($RequiredBytes * $script:freeSpaceMargin))
        if ($d.AvailableFreeSpace -ge $need) {
            $path = Join-Path $d.RootDirectory.FullName "Migrate-Vms-Staging"
            if (-not (Test-Path -LiteralPath $path)) {
                New-Item -ItemType Directory -Path $path -Force | Out-Null
            }
            Write-Log "Using staging path $path" -Tag "Info"
            return $path
        }
    }
    throw "No local volume has enough free space for staging (~$(Format-ByteSize ([int64]($RequiredBytes * $script:freeSpaceMargin))))."
}

function Get-FixedDriveMenuItems {
    $items = @()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        if ($d.DriveType -ne "Fixed" -and $d.DriveType -ne "Removable") { continue }
        $letter = $d.Name.TrimEnd("\")
        $label = ("{0}  {1} free  ({2})" -f $letter, (Format-ByteSize $d.AvailableFreeSpace), $d.DriveType)
        $items += [pscustomobject]@{ Id = $letter; Label = $label }
    }
    return $items
}


# ---------------------------[ Export ]---------------------------
function Export-SingleMigrateVm {
    param(
        [object]$Inventory,
        [string]$PackageRoot,
        [string]$ExportWorkRoot,
        [switch]$UseStagingCopy,
        [switch]$AllowRunning,
        [string]$LiveState
    )

    $name = [string]$Inventory.Name
    $vmStart = Get-Date
    $destVmFolder = Join-Path (Join-Path $PackageRoot "vms") $name

    try {
        if (-not $AllowRunning) {
            $ok = Stop-MigrateVmGracefully -Name $name -Interactive
            if (-not $ok) {
                throw "Could not shut down VM '$name'"
            }
            Wait-VmDiskMerge -Name $name
            Disconnect-VmDvdMedia -Name $name
        }

        $exportTarget = $ExportWorkRoot
        if (-not (Test-Path -LiteralPath $exportTarget)) {
            New-Item -ItemType Directory -Path $exportTarget -Force | Out-Null
        }

        Write-Log "Exporting VM '$name' to $exportTarget" -Tag "Run"
        try {
            if ($AllowRunning -and -not [string]::IsNullOrWhiteSpace($LiveState)) {
                Export-VM -Name $name -Path $exportTarget -CaptureLiveState $LiveState -ErrorAction Stop
            }
            else {
                Export-VM -Name $name -Path $exportTarget -ErrorAction Stop
            }
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match "being used by another process|0x80070020|sharing violation|lock") {
                Write-LockErrorHint -Message "Export failed for '$name': $msg"
            }
            else {
                Write-Log "Export failed for '$name': $msg" -Tag "Error"
            }
            throw
        }

        $exportedFolder = Join-Path $exportTarget $name
        if (-not (Test-Path -LiteralPath $exportedFolder)) {
            # Export-VM may nest differently
            $exportedFolder = Get-ChildItem -LiteralPath $exportTarget -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        }

        if ($UseStagingCopy) {
            Write-Log "Copying '$name' from staging to package" -Tag "Run"
            if (Test-Path -LiteralPath $destVmFolder) {
                Remove-Item -LiteralPath $destVmFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
            Invoke-RobocopyCopy -Source $exportedFolder -Destination $destVmFolder
            try { Remove-Item -LiteralPath $exportedFolder -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
        else {
            if ($exportedFolder -ne $destVmFolder) {
                if (-not (Test-Path -LiteralPath (Split-Path $destVmFolder -Parent))) {
                    New-Item -ItemType Directory -Path (Split-Path $destVmFolder -Parent) -Force | Out-Null
                }
                if (Test-Path -LiteralPath $destVmFolder) {
                    Remove-Item -LiteralPath $destVmFolder -Recurse -Force
                }
                Move-Item -LiteralPath $exportedFolder -Destination $destVmFolder -Force
            }
        }

        if (-not (Test-ExportPackageVm -VmExportFolder $destVmFolder)) {
            throw "Export package validation failed for '$name' (missing vmcx/vhdx)"
        }

        $Inventory.ExportStatus = "success"
        $Inventory.ExportMessage = "ok"
        $dur = (Get-Date) - $vmStart
        Write-Log ("Exported '{0}' in {1}" -f $name, $dur.ToString("hh\:mm\:ss")) -Tag "Ok"
        return $true
    }
    catch {
        $Inventory.ExportStatus = "failed"
        $Inventory.ExportMessage = $_.Exception.Message
        Write-Log "VM '$name' export failed: $($_.Exception.Message)" -Tag "Error"
        return $false
    }
}

function Start-MigrateExport {
    param(
        [object[]]$Inventories,
        [string]$DestinationRoot,
        [string]$StagingPathPreferred,
        [bool]$IsNetwork,
        [bool]$DoSwitches,
        [bool]$DoHostSettings,
        [bool]$DoDirectExport,
        [bool]$AllowRunning,
        [string]$LiveState,
        [bool]$SkipVtpm,
        [securestring]$VtpmPassword
    )

    $totalBytes = [int64]0
    foreach ($inv in $Inventories) { $totalBytes += [int64]$inv.EstimatedSizeBytes }

    Assert-FreeSpace -Path $DestinationRoot -RequiredBytes $totalBytes -Label "Destination"

    $packageRoot = New-MigratePackageRoot -DestinationRoot $DestinationRoot
    Write-Log "Package root: $packageRoot" -Tag "Info"

    $exportWorkRoot = Join-Path $packageRoot "vms"
    $useStaging = $false
    if ($IsNetwork -and -not $DoDirectExport) {
        $useStaging = $true
        $staging = Get-LocalStagingPath -Preferred $StagingPathPreferred -RequiredBytes $totalBytes
        $exportWorkRoot = Join-Path $staging ("export-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
        New-Item -ItemType Directory -Path $exportWorkRoot -Force | Out-Null
    }

    $needsVtpm = $false
    foreach ($inv in $Inventories) {
        if ($inv.HasVtpm) { $needsVtpm = $true; break }
    }
    if ($needsVtpm -and -not $SkipVtpm) {
        if ($null -eq $VtpmPassword) {
            throw "vTPM VMs selected but no PFX password provided"
        }
        $pfx = Join-Path (Join-Path $packageRoot "host") "vtpm-certs.pfx"
        Export-VtpmCertificates -PfxPath $pfx -Password $VtpmPassword | Out-Null
    }
    elseif ($needsVtpm -and $SkipVtpm) {
        Write-Log "Skipping vTPM certificate export (-SkipVtpmCerts)" -Tag "Info"
    }

    if ($DoSwitches) {
        Export-VmSwitchInventory -JsonPath (Join-Path (Join-Path $packageRoot "host") "vmswitches.json")
    }
    if ($DoHostSettings) {
        Export-VmHostSettings -JsonPath (Join-Path (Join-Path $packageRoot "host") "vmhost.json")
    }

    $okCount = 0
    $failCount = 0
    foreach ($inv in $Inventories) {
        $ok = Export-SingleMigrateVm -Inventory $inv -PackageRoot $packageRoot `
            -ExportWorkRoot $exportWorkRoot -UseStagingCopy:$useStaging `
            -AllowRunning:$AllowRunning -LiveState $LiveState
        if ($ok) { $okCount++ } else { $failCount++ }
    }

    $manifest = [pscustomobject]@{
        SchemaVersion   = 1
        Tool            = "Migrate-Vms"
        HostName        = $env:COMPUTERNAME
        ExportedAt      = (Get-Date).ToString("o")
        DestinationType = $(if ($IsNetwork) { "Network" } else { "Local" })
        IncludeSwitches = $DoSwitches
        IncludeHostSettings = $DoHostSettings
        VtpmExported    = ($needsVtpm -and -not $SkipVtpm)
        SuccessCount    = $okCount
        FailCount       = $failCount
        VirtualMachines = @($Inventories)
    }
    Write-JsonFile -InputObject $manifest -Path (Join-Path $packageRoot "manifest.json")
    Write-Log ("Export complete: {0}/{1} succeeded" -f $okCount, ($okCount + $failCount)) -Tag $(if ($failCount -eq 0) { "Ok" } else { "Info" })
    Write-Log "Package: $packageRoot" -Tag "Info"
    return $packageRoot
}

# ---------------------------[ Import ]---------------------------
function Find-VmConfigFile {
    param([string]$VmExportFolder)
    $dir = Join-Path $VmExportFolder "Virtual Machines"
    $file = Get-ChildItem -LiteralPath $dir -Filter "*.vmcx" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($file) { return $file.FullName }
    $file = Get-ChildItem -LiteralPath $VmExportFolder -Filter "*.vmcx" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($file) { return $file.FullName }
    return $null
}

function Get-UniqueShortFolder {
    param(
        [string]$BaseName,
        [string]$VmPathRoot,
        [string]$VhdPathRoot,
        [hashtable]$Used
    )
    # Kept for compatibility; prefer Get-UniqueImportFolder with HyperVName.
    return (Get-UniqueImportFolder -ShortName $BaseName -HyperVName $BaseName `
            -VmPathRoot $VmPathRoot -VhdPathRoot $VhdPathRoot -Used $Used)
}

function Resolve-SwitchRemapChoice {
    param(
        [string]$HyperVName,
        [switch]$Interactive
    )

    if ($null -ne $script:importSwitchRemapChoice) {
        return [string]$script:importSwitchRemapChoice
    }

    if (-not $Interactive) {
        throw "Unresolved switch incompatibilities for '$HyperVName' (non-interactive)"
    }

    $switches = @(Get-VMSwitch | Select-Object -ExpandProperty Name)
    $items = @()
    foreach ($s in $switches) {
        $items += [pscustomobject]@{ Id = $s; Label = "Connect to switch: $s" }
        $items += [pscustomobject]@{
            Id    = ("__all__:{0}" -f $s)
            Label = "Connect to switch: $s  [use for all remaining VMs]"
        }
    }
    $items += [pscustomobject]@{ Id = "skip"; Label = "Leave disconnected / skip remap" }
    $items += [pscustomobject]@{
        Id    = "__all__:skip"
        Label = "Leave disconnected  [use for all remaining VMs]"
    }

    $pick = Show-Menu -Title "Switch remap" -Question "Remap missing switch for '$HyperVName'" -Items $items
    if ($null -eq $pick) {
        throw "Switch remap cancelled for '$HyperVName'"
    }

    if ($pick -like "__all__:*") {
        $choice = $pick.Substring("__all__:".Length)
        $script:importSwitchRemapChoice = $choice
        if ($choice -eq "skip") {
            Write-Log "Will leave missing switches disconnected for all remaining VMs" -Tag "Warn"
        }
        else {
            Write-Log "Will use switch '$choice' for all remaining VMs" -Tag "Info"
        }
        return $choice
    }

    return $pick
}

function Set-SwitchRemapOnAdapter {
    param(
        $NetworkAdapter,
        [string]$Choice,
        [string]$HyperVName
    )

    if ($Choice -eq "skip") {
        Disconnect-VMNetworkAdapter -VMNetworkAdapter $NetworkAdapter -ErrorAction Stop
        Write-Log "Disconnected NIC on '$HyperVName' (missing switch left unmapped)" -Tag "Warn"
        return
    }

    Connect-VMNetworkAdapter -VMNetworkAdapter $NetworkAdapter -SwitchName $Choice -ErrorAction Stop
    Write-Log "Remapped NIC on '$HyperVName' -> switch '$Choice'" -Tag "Ok"
}

function Get-VmIdFromConfigFile {
    param([string]$Vmcx)

    # Hyper-V names the config file after the VM's GUID.
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Vmcx)
    if ($name -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { return $name }
    return $null
}

function Remove-StalePlannedVm {
    param(
        [string]$VmId,
        [string]$HyperVName
    )

    # Compare-VM parks a planned VM under the source VM's GUID. A run killed
    # mid-import leaves that planned VM registered, and the next Compare-VM
    # dies while trying to delete it - reported as the useless
    # "Deleting '<name>' failed. The operation was passed a parameter that was
    # not valid." Clearing it up front keeps the real error visible.
    try {
        $planned = @(Get-CimInstance -Namespace "root\virtualization\v2" `
                -ClassName Msvm_PlannedComputerSystem -ErrorAction Stop |
            Where-Object {
                ($VmId -and $_.Name -eq $VmId) -or ($HyperVName -and $_.ElementName -eq $HyperVName)
            })
    }
    catch {
        Write-Log "Could not query planned VMs: $($_.Exception.Message)" -Tag "Debug"
        return
    }

    if ($planned.Count -eq 0) { return }

    $vsms = Get-CimInstance -Namespace "root\virtualization\v2" -ClassName Msvm_VirtualSystemManagementService
    foreach ($p in $planned) {
        try {
            Invoke-CimMethod -InputObject $vsms -MethodName DestroySystem `
                -Arguments @{ AffectedSystem = $p } -ErrorAction Stop | Out-Null
            Write-Log "Removed stale planned VM '$($p.ElementName)' ($($p.Name))" -Tag "Warn"
        }
        catch {
            Write-Log "Could not remove stale planned VM '$($p.ElementName)': $($_.Exception.Message)" -Tag "Error"
        }
    }
}

function Invoke-MigrateVmImportAttempt {
    param(
        [string]$Vmcx,
        [string]$HyperVName,
        [string]$VmDest,
        [string]$VhdDest,
        [string]$SnapDest,
        [switch]$NewId,
        [switch]$Interactive
    )

    # Set when the failure is a compatibility problem a new VM ID cannot fix,
    # so the caller knows not to burn a retry on it.
    $script:importCompatFatal = $false

    # Always go through Compare-VM so switch remaps stick on the report.
    # After repair, Import-VM -CompatibilityReport must be used - a plain
    # Import-VM -Path ignores Connect-VMNetworkAdapter fixes on the report.
    $compareArgs = @{
        Path               = $Vmcx
        Copy               = $true
        VirtualMachinePath = $VmDest
        VhdDestinationPath = $VhdDest
        SnapshotFilePath   = $SnapDest
        ErrorAction        = "Stop"
    }
    if ($NewId) { $compareArgs["GenerateNewId"] = $true }

    $report = Compare-VM @compareArgs

    $safety = 0
    while ($report.Incompatibilities -and @($report.Incompatibilities).Count -gt 0) {
        $safety++
        if ($safety -gt 20) {
            $script:importCompatFatal = $true
            throw "Too many compatibility repair attempts for '$HyperVName'"
        }

        $switchIssues = @($report.Incompatibilities | Where-Object { [int]$_.MessageID -eq 33012 })
        $otherIssues = @($report.Incompatibilities | Where-Object { [int]$_.MessageID -ne 33012 })

        foreach ($inc in @($report.Incompatibilities)) {
            Write-Log ("Compatibility: {0} (MessageID={1})" -f $inc.Message, $inc.MessageID) -Tag "Info"
        }

        if ($switchIssues.Count -eq 0) {
            $detail = ($otherIssues | ForEach-Object { $_.Message }) -join "; "
            $script:importCompatFatal = $true
            throw "Unresolved compatibility errors for '$HyperVName': $detail"
        }

        foreach ($inc in $switchIssues) {
            $pick = Resolve-SwitchRemapChoice -HyperVName $HyperVName -Interactive:$Interactive
            Set-SwitchRemapOnAdapter -NetworkAdapter $inc.Source -Choice $pick -HyperVName $HyperVName
        }

        $report = Compare-VM -CompatibilityReport $report -ErrorAction Stop
    }

    Import-VM -CompatibilityReport $report -ErrorAction Stop | Out-Null
}

function Clear-ImportDestination {
    param(
        [string]$VmDest,
        [string]$VhdDest
    )

    # Only ever called on folders this import created, so wiping them is safe.
    foreach ($dir in @($VmDest, $VhdDest)) {
        Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Import-SingleMigrateVm {
    param(
        [string]$VmExportFolder,
        [string]$HyperVName,
        [string]$ShortFolder,
        [string]$VmPathRoot,
        [string]$VhdPathRoot,
        [switch]$Interactive
    )

    $vmcx = Find-VmConfigFile -VmExportFolder $VmExportFolder
    if (-not $vmcx) { throw "No .vmcx found under $VmExportFolder" }

    $vmId = Get-VmIdFromConfigFile -Vmcx $vmcx

    $vmDest = Join-Path $VmPathRoot $ShortFolder
    $vhdDest = Join-Path $VhdPathRoot $ShortFolder
    $destWasEmpty = -not ((Test-Path -LiteralPath $vmDest) -or (Test-Path -LiteralPath $vhdDest))
    New-Item -ItemType Directory -Path $vmDest -Force | Out-Null
    New-Item -ItemType Directory -Path $vhdDest -Force | Out-Null
    $snapDest = Join-Path $vmDest "Snapshots"

    Write-Log "Importing '$HyperVName' -> VM:$vmDest VHD:$vhdDest" -Tag "Run"

    Remove-StalePlannedVm -VmId $vmId -HyperVName $HyperVName

    # Compare-VM -Copy keeps the source GUID, so re-importing a package whose VM
    # is still registered collides on the ID. Detect it up front where we can.
    $newId = $false
    if ($vmId) {
        $clash = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.Id.Guid -eq $vmId })
        if ($clash.Count -gt 0) {
            Write-Log "VM ID $vmId already registered as '$($clash[0].Name)'; importing '$HyperVName' with a new ID" -Tag "Info"
            $newId = $true
        }
    }

    try {
        Invoke-MigrateVmImportAttempt -Vmcx $vmcx -HyperVName $HyperVName -VmDest $vmDest `
            -VhdDest $vhdDest -SnapDest $snapDest -NewId:$newId -Interactive:$Interactive
    }
    catch {
        # A compatibility failure or an attempt that already used a new ID is
        # not going to improve on a retry.
        if ($script:importCompatFatal -or $newId) { throw }

        $first = ([string]$_.Exception.Message -split "`n")[0].Trim()
        Write-Log "Import of '$HyperVName' failed ($first); retrying with a new VM ID" -Tag "Warn"

        Remove-StalePlannedVm -VmId $vmId -HyperVName $HyperVName
        if ($destWasEmpty) { Clear-ImportDestination -VmDest $vmDest -VhdDest $vhdDest }

        Invoke-MigrateVmImportAttempt -Vmcx $vmcx -HyperVName $HyperVName -VmDest $vmDest `
            -VhdDest $vhdDest -SnapDest $snapDest -NewId -Interactive:$Interactive

        Write-Log "Imported '$HyperVName' with a new VM ID" -Tag "Ok"
        return $true
    }

    Write-Log "Imported '$HyperVName'" -Tag "Ok"
    return $true
}

function Start-MigrateImport {
    param(
        [string]$PackageRoot,
        [string]$VmPathRoot,
        [string]$VhdPathRoot,
        [string[]]$OnlyVmNames,
        [switch]$DoStart,
        [switch]$Interactive,
        [securestring]$VtpmPassword
    )

    $manifestPath = Join-Path $PackageRoot "manifest.json"
    $manifest = $null
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Read-JsonFile -Path $manifestPath
    }

    $vmsRoot = Join-Path $PackageRoot "vms"
    $folders = @(Get-ChildItem -LiteralPath $vmsRoot -Directory -ErrorAction Stop)

    if ($manifest -and $manifest.VtpmExported) {
        $hostDir = Join-Path $PackageRoot "host"
        if ($null -eq $VtpmPassword) { throw "Package includes vTPM certs; password required" }
        Import-VtpmCertificates -HostFolder $hostDir -Password $VtpmPassword
    }

    $used = @{}
    $okCount = 0
    $failCount = 0
    $importedNames = @()
    $script:importSwitchRemapChoice = $null
    $script:importCompatFatal = $false

    foreach ($folder in $folders) {
        $hvName = $folder.Name
        if ($OnlyVmNames -and $OnlyVmNames.Count -gt 0) {
            $match = $false
            foreach ($n in $OnlyVmNames) {
                if ($n -eq $hvName) { $match = $true; break }
            }
            if (-not $match) { continue }
        }

        $short = Get-ShortFolderName -VmName $hvName
        if ($manifest -and $manifest.VirtualMachines) {
            foreach ($m in @($manifest.VirtualMachines)) {
                if ([string]$m.Name -eq $hvName -and $m.ShortFolderName) {
                    $short = Get-SanitizedFolderName -Name ([string]$m.ShortFolderName)
                    break
                }
            }
        }
        # Always lowercase destination folders (DC01 -> dc01)
        $short = Get-SanitizedFolderName -Name $short
        $short = Get-UniqueImportFolder -ShortName $short -HyperVName $hvName `
            -VmPathRoot $VmPathRoot -VhdPathRoot $VhdPathRoot -Used $used

        try {
            Import-SingleMigrateVm -VmExportFolder $folder.FullName -HyperVName $hvName `
                -ShortFolder $short -VmPathRoot $VmPathRoot -VhdPathRoot $VhdPathRoot -Interactive:$Interactive | Out-Null
            $okCount++
            $importedNames += $hvName
        }
        catch {
            $failCount++
            Write-Log "Import failed for '$hvName': $($_.Exception.Message)" -Tag "Error"
        }
    }

    Write-Log ("Import complete: {0}/{1} succeeded" -f $okCount, ($okCount + $failCount)) -Tag $(if ($failCount -eq 0) { "Ok" } else { "Info" })

    if ($DoStart -and $importedNames.Count -gt 0) {
        foreach ($n in $importedNames) {
            try {
                Write-Log "Starting VM '$n'" -Tag "Run"
                Start-VM -Name $n -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log "Start failed for '$n': $($_.Exception.Message)" -Tag "Error"
            }
        }
    }

    return ($failCount -eq 0)
}

# ---------------------------[ Check ]---------------------------
function Invoke-HostPreflight {
    Write-Log "Running host preflight" -Tag "Start"
    $list = @(Get-AllMigrateInventories)
    Write-Log ("Found {0} VM(s)" -f $list.Count) -Tag "Get"
    $total = [int64]0
    foreach ($inv in $list) {
        $total += [int64]$inv.EstimatedSizeBytes
        $vtpm = if ($inv.HasVtpm) { "vTPM" } else { "----" }
        $cp = $inv.CheckpointCount
        Write-Log ("  {0,-40} {1,-12} {2}  cp={3}  {4}" -f `
            $inv.Name, $inv.State, $vtpm, $cp, (Format-ByteSize ([int64]$inv.EstimatedSizeBytes))) -Tag "Info"
        if ($inv.HasPassthrough) {
            Write-Log ("  WARNING: '{0}' may have pass-through disks (export may fail)" -f $inv.Name) -Tag "Error"
        }
        if ($inv.CheckpointCount -gt 0) {
            Write-Log ("  NOTE: '{0}' has {1} checkpoint(s) - export will include them" -f $inv.Name, $inv.CheckpointCount) -Tag "Info"
        }
        if ($inv.DvdPaths -and @($inv.DvdPaths).Count -gt 0) {
            Write-Log ("  NOTE: '{0}' has DVD media attached (will disconnect on export)" -f $inv.Name) -Tag "Info"
        }
    }
    Write-Log ("Estimated total disk footprint: {0}" -f (Format-ByteSize $total)) -Tag "Info"
    Write-Log "Preflight complete" -Tag "Ok"
}

function Invoke-ValidatePackage {
    param([string]$PackageRoot)
    Write-Log "Validating package $PackageRoot" -Tag "Start"
    $manifestPath = Join-Path $PackageRoot "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "manifest.json missing"
    }
    $manifest = Read-JsonFile -Path $manifestPath
    Write-Log ("Host={0} ExportedAt={1} Success={2} Fail={3}" -f `
        $manifest.HostName, $manifest.ExportedAt, $manifest.SuccessCount, $manifest.FailCount) -Tag "Info"
    $vmsRoot = Join-Path $PackageRoot "vms"
    foreach ($dir in @(Get-ChildItem -LiteralPath $vmsRoot -Directory)) {
        $ok = Test-ExportPackageVm -VmExportFolder $dir.FullName
        if ($ok) {
            Write-Log ("OK   {0}" -f $dir.Name) -Tag "Ok"
        }
        else {
            Write-Log ("FAIL {0} (incomplete export folder)" -f $dir.Name) -Tag "Error"
        }
    }
    $hostDir = Join-Path $PackageRoot "host"
    if (Test-Path -LiteralPath (Join-Path $hostDir "vtpm-certs.pfx")) {
        Write-Log "vTPM PFX present" -Tag "Info"
    }
    if (Test-Path -LiteralPath (Join-Path $hostDir "vmswitches.json")) {
        Write-Log "Switch inventory present" -Tag "Info"
    }
    Write-Log "Validation complete" -Tag "Ok"
}


# ---------------------------[ Interactive wizards ]---------------------------
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
    $idx = 0
    if ($DefaultId -eq "yes") { $idx = 0 } else { $idx = 1 }
    return (Show-Menu -Title "Confirm" -Question $Title -Items $items -SelectedIndex $idx -StatusLines $StatusLines)
}

function Select-MigrateVmsInteractive {
    param([object[]]$Inventories)
    $items = @()
    foreach ($inv in $Inventories) {
        $vtpm = if ($inv.HasVtpm) { "vTPM" } else { "    " }
        $label = ("{0,-36} {1,-10} {2}  {3}" -f $inv.Name, $inv.State, $vtpm, (Format-ByteSize ([int64]$inv.EstimatedSizeBytes)))
        $items += [pscustomobject]@{ Id = [string]$inv.Name; Label = $label }
    }
    $picked = Show-MultiSelectMenu -Title "Select VMs to export" -Items $items
    if ($null -eq $picked) { return $null }
    $set = @{}
    foreach ($p in @($picked)) { $set[[string]$p] = $true }
    return @($Inventories | Where-Object { $set.ContainsKey([string]$_.Name) })
}

function Resolve-ExportDestinationInteractive {
    $items = @(
        [pscustomobject]@{ Id = "local";   Label = "Local     USB / SATA / local folder (pick drive letter)" }
        [pscustomobject]@{ Id = "network"; Label = "Network   UNC path (stage locally then copy)" }
        [pscustomobject]@{ Id = "back";    Label = "Back" }
    )
    $type = Show-Menu -Title "Export destination" -Question "Where should the export package be written?" -Items $items
    if ($null -eq $type -or $type -eq "back") { return $null }

    $result = [ordered]@{
        IsNetwork = $false
        Path      = ""
        Staging   = ""
        SmbUser   = ""
        SmbPassword = $null
    }

    if ($type -eq "local") {
        $drives = @(Get-FixedDriveMenuItems)
        if ($drives.Count -eq 0) { throw "No ready fixed/removable drives found" }
        $drives += [pscustomobject]@{ Id = "back"; Label = "Back" }
        $letter = Show-Menu -Title "Destination drive" -Question "Select the destination drive letter" -Items $drives
        if ($null -eq $letter -or $letter -eq "back") { return $null }
        $sub = Read-ConsolePath -PromptLabel "Subfolder under drive" -DefaultValue "Migrate-Vms-Backups"
        $result.Path = Join-Path $letter $sub
    }
    else {
        $result.IsNetwork = $true
        $unc = Read-ConsolePath -PromptLabel "UNC path" -ExampleHint "\\nas\backups\hyperv"
        if ([string]::IsNullOrWhiteSpace($unc)) { return $null }
        $result.Path = $unc
        $credAsk = Show-YesNoMenu -Title "SMB credentials required?" -DefaultId "no"
        if ($credAsk -eq "yes") {
            $result.SmbUser = Read-Host "SMB user (domain\\user)"
            $result.SmbPassword = Read-SecurePassword -Prompt "SMB password"
        }
        $stg = Read-ConsolePath -PromptLabel "Local staging path (blank = auto)" -DefaultValue ""
        $result.Staging = $stg
    }

    if (-not (Test-Path -LiteralPath $result.Path)) {
        try { New-Item -ItemType Directory -Path $result.Path -Force | Out-Null } catch { }
    }
    return [pscustomobject]$result
}

function Confirm-CheckpointContinue {
    param([object[]]$Inventories)
    $withCp = @($Inventories | Where-Object { $_.CheckpointCount -gt 0 })
    if ($withCp.Count -eq 0) { return $true }
    Write-Log ("{0} VM(s) have checkpoints - export will include the chain (larger/slower)" -f $withCp.Count) -Tag "Info"
    $c = Show-YesNoMenu -Title "Continue export with checkpoints?" -DefaultId "yes"
    return ($c -eq "yes")
}

function Invoke-ExportWizard {
    param(
        [switch]$AllVms,
        [string[]]$NameFilter
    )

    $all = @(Get-AllMigrateInventories)
    if ($all.Count -eq 0) {
        Write-Log "No VMs found on this host" -Tag "Error"
        return
    }

    $selected = @()
    if ($AllVms) {
        $selected = $all
    }
    elseif ($NameFilter -and $NameFilter.Count -gt 0) {
        $selected = @($all | Where-Object { $NameFilter -contains $_.Name })
    }
    else {
        $selected = @(Select-MigrateVmsInteractive -Inventories $all)
        if ($null -eq $selected) { return }
    }
    if ($selected.Count -eq 0) {
        Write-Log "No VMs selected" -Tag "Info"
        return
    }

    $dest = Resolve-ExportDestinationInteractive
    if ($null -eq $dest) { return }

    $sw = Show-YesNoMenu -Title "Include virtual switches in package?" -DefaultId "no"
    if ($sw -eq "back" -or $null -eq $sw) { return }
    $hs = Show-YesNoMenu -Title "Include host settings (paths) in package?" -DefaultId "no"
    if ($hs -eq "back" -or $null -eq $hs) { return }

    if (-not (Confirm-CheckpointContinue -Inventories $selected)) { return }

    $needsVtpm = @($selected | Where-Object { $_.HasVtpm }).Count -gt 0
    $vtpmPass = $null
    if ($needsVtpm -and -not $SkipVtpmCerts) {
        $vtpmPass = Read-SecurePassword -Prompt "PFX password for vTPM certificates"
    }

    $status = [ordered]@{
        vms   = "$($selected.Count) selected"
        dest  = [string]$dest.Path
        type  = $(if ($dest.IsNetwork) { "network" } else { "local" })
        vtpm  = $(if ($needsVtpm) { "yes" } else { "no" })
    }
    $confirm = Show-Menu -Title "Confirm export" -Question "Start the export with these settings?" -StatusLines $status -Items @(
        [pscustomobject]@{ Id = "go";   Label = "Start export" }
        [pscustomobject]@{ Id = "back"; Label = "Back" }
    )
    if ($confirm -ne "go") { return }

    if ($dest.IsNetwork -and $dest.SmbUser) {
        $plain = Convert-SecureStringToPlain -Secure $dest.SmbPassword
        Connect-MigrateSmbShare -Path $dest.Path -UserName $dest.SmbUser -PlainPassword $plain
    }

    Start-MigrateExport -Inventories $selected -DestinationRoot $dest.Path `
        -StagingPathPreferred $dest.Staging -IsNetwork:([bool]$dest.IsNetwork) `
        -DoSwitches:($sw -eq "yes") -DoHostSettings:($hs -eq "yes") `
        -DoDirectExport:$DirectExport.IsPresent -AllowRunning:$AllowRunningExport.IsPresent `
        -LiveState $CaptureLiveState -SkipVtpm:$SkipVtpmCerts.IsPresent -VtpmPassword $vtpmPass | Out-Null

    Read-Host "Press Enter to continue"
}

function Invoke-ExportHostInventoryOnly {
    $dest = Resolve-ExportDestinationInteractive
    if ($null -eq $dest) { return }
    $sw = Show-YesNoMenu -Title "Include virtual switches?" -DefaultId "yes"
    if ($sw -eq "back" -or $null -eq $sw) { return }
    $hs = Show-YesNoMenu -Title "Include host settings?" -DefaultId "yes"
    if ($hs -eq "back" -or $null -eq $hs) { return }

    $all = @(Get-AllMigrateInventories)
    $needsVtpm = @($all | Where-Object { $_.HasVtpm }).Count -gt 0
    $vtpmPass = $null
    if ($needsVtpm -and -not $SkipVtpmCerts) {
        $ask = Show-YesNoMenu -Title "Export vTPM certificates (TPM VMs present)?" -DefaultId "yes"
        if ($ask -eq "yes") {
            $vtpmPass = Read-SecurePassword -Prompt "PFX password for vTPM certificates"
        }
    }

    # empty VM list export of host bits only
    $packageRoot = New-MigratePackageRoot -DestinationRoot $dest.Path
    if ($sw -eq "yes") {
        Export-VmSwitchInventory -JsonPath (Join-Path (Join-Path $packageRoot "host") "vmswitches.json")
    }
    if ($hs -eq "yes") {
        Export-VmHostSettings -JsonPath (Join-Path (Join-Path $packageRoot "host") "vmhost.json")
    }
    if ($null -ne $vtpmPass) {
        Export-VtpmCertificates -PfxPath (Join-Path (Join-Path $packageRoot "host") "vtpm-certs.pfx") -Password $vtpmPass | Out-Null
    }
    $manifest = [pscustomobject]@{
        SchemaVersion = 1
        Tool          = "Migrate-Vms"
        HostName      = $env:COMPUTERNAME
        ExportedAt    = (Get-Date).ToString("o")
        HostInventoryOnly = $true
        VirtualMachines = @()
    }
    Write-JsonFile -InputObject $manifest -Path (Join-Path $packageRoot "manifest.json")
    Write-Log "Host inventory package: $packageRoot" -Tag "Ok"
    Read-Host "Press Enter to continue"
}

function Resolve-ImportPackageInteractive {
    $path = Read-ConsolePath -PromptLabel "Package folder (contains manifest.json)" `
        -ExampleHint "E:\Migrate-Vms-Backups\Migrate-Vms\HOST_2026-..."
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $path "manifest.json"))) {
        # maybe user pointed at Migrate-Vms parent
        $children = @(Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        if ($children.Count -gt 0) {
            $items = @()
            foreach ($c in $children) {
                if (Test-Path -LiteralPath (Join-Path $c.FullName "manifest.json")) {
                    $items += [pscustomobject]@{ Id = $c.FullName; Label = $c.Name }
                }
            }
            if ($items.Count -gt 0) {
                $items += [pscustomobject]@{ Id = "back"; Label = "Back" }
                $pick = Show-Menu -Title "Select package" -Question "Which backup package do you want to use?" -Items $items
                if ($null -eq $pick -or $pick -eq "back") { return $null }
                return $pick
            }
        }
        Write-Log "manifest.json not found under $path" -Tag "Error"
        return $null
    }
    return $path
}

function Invoke-ImportWizard {
    param(
        [switch]$AllVms,
        [string[]]$NameFilter
    )

    $package = Resolve-ImportPackageInteractive
    if (-not $package) { return }

    $vmPathDefault = ""
    $vhdPathDefault = ""
    try {
        $h = Get-VMHost
        $vmPathDefault = [string]$h.VirtualMachinePath
        $vhdPathDefault = [string]$h.VirtualHardDiskPath
    }
    catch { }

    $vmPath = Read-ConsolePath -PromptLabel "VM configuration path" -DefaultValue $vmPathDefault -ExampleHint "G:\Virtual Machines"
    $vhdPath = Read-ConsolePath -PromptLabel "VHD path" -DefaultValue $vhdPathDefault -ExampleHint "G:\Virtual Hard Drives"
    if ([string]::IsNullOrWhiteSpace($vmPath) -or [string]::IsNullOrWhiteSpace($vhdPath)) {
        Write-Log "VmPath and VhdPath are required" -Tag "Error"
        return
    }

    $only = @()
    $vmsRoot = Join-Path $package "vms"
    $folders = @(Get-ChildItem -LiteralPath $vmsRoot -Directory -ErrorAction SilentlyContinue)
    if (-not $AllVms) {
        if ($NameFilter -and $NameFilter.Count -gt 0) {
            $only = $NameFilter
        }
        else {
            $items = @()
            foreach ($f in $folders) {
                $items += [pscustomobject]@{ Id = $f.Name; Label = $f.Name }
            }
            $picked = Show-MultiSelectMenu -Title "Select VMs to import" -Items $items
            if ($null -eq $picked) { return }
            $only = @($picked)
        }
    }

    $manifest = $null
    $mp = Join-Path $package "manifest.json"
    if (Test-Path -LiteralPath $mp) { $manifest = Read-JsonFile -Path $mp }

    $vtpmPass = $null
    if ($manifest -and $manifest.VtpmExported) {
        $vtpmPass = Read-SecurePassword -Prompt "PFX password for vTPM certificates"
    }

    $startAns = Show-YesNoMenu -Title "Start imported VMs now?" -DefaultId "no"
    if ($startAns -eq "back" -or $null -eq $startAns) { return }

    $confirm = Show-Menu -Title "Confirm import" -Question "Start the import with these settings?" -StatusLines ([ordered]@{
            package = $package
            vmpath  = $vmPath
            vhdpath = $vhdPath
            count   = $(if ($only.Count -gt 0) { "$($only.Count) selected" } else { "all" })
        }) -Items @(
        [pscustomobject]@{ Id = "go"; Label = "Start import" }
        [pscustomobject]@{ Id = "back"; Label = "Back" }
    )
    if ($confirm -ne "go") { return }

    Start-MigrateImport -PackageRoot $package -VmPathRoot $vmPath -VhdPathRoot $vhdPath `
        -OnlyVmNames $only -DoStart:($startAns -eq "yes") -Interactive:$true -VtpmPassword $vtpmPass | Out-Null
    Read-Host "Press Enter to continue"
}

function Invoke-RestoreHostInventoryWizard {
    $package = Resolve-ImportPackageInteractive
    if (-not $package) { return }
    $hostDir = Join-Path $package "host"
    $swAsk = Show-YesNoMenu -Title "Recreate virtual switches from package?" -DefaultId "no"
    if ($swAsk -eq "back" -or $null -eq $swAsk) { return }
    if ($swAsk -eq "yes") {
        Import-VmSwitchInventory -JsonPath (Join-Path $hostDir "vmswitches.json") -Interactive
    }
    if (Test-Path -LiteralPath (Join-Path $hostDir "vtpm-certs.pfx")) {
        $vtpmAsk = Show-YesNoMenu -Title "Import vTPM certificates?" -DefaultId "yes"
        if ($vtpmAsk -eq "yes") {
            $pass = Read-SecurePassword -Prompt "PFX password"
            Import-VtpmCertificates -HostFolder $hostDir -Password $pass
        }
    }
    Write-Log "Host inventory restore finished" -Tag "Ok"
    Read-Host "Press Enter to continue"
}

function Start-InteractiveMigrateMenu {
    while ($true) {
        $main = Show-Menu -Title "Migrate Hyper-V VMs" -Items @(
            [pscustomobject]@{ Id = "import"; Label = "Import     restore VMs / host inventory from a package" }
            [pscustomobject]@{ Id = "export"; Label = "Export     copy VMs to USB, SATA, or NAS" }
            [pscustomobject]@{ Id = "check";  Label = "Check      preflight this host or validate a package" }
            [pscustomobject]@{ Id = "quit";   Label = "Quit" }
        )
        if ($null -eq $main -or $main -eq "quit") {
            Complete-Script -ExitCode 0
        }

        if ($main -eq "export") {
            while ($true) {
                $sub = Show-Menu -Title "Export" -Items @(
                    [pscustomobject]@{ Id = "all";      Label = "Export all VMs" }
                    [pscustomobject]@{ Id = "selected"; Label = "Export selected VMs" }
                    [pscustomobject]@{ Id = "host";     Label = "Export host inventory only" }
                    [pscustomobject]@{ Id = "back";     Label = "Back" }
                )
                if ($null -eq $sub -or $sub -eq "back") { break }
                if ($sub -eq "all") { Invoke-ExportWizard -AllVms }
                elseif ($sub -eq "selected") { Invoke-ExportWizard }
                elseif ($sub -eq "host") { Invoke-ExportHostInventoryOnly }
            }
        }
        elseif ($main -eq "import") {
            while ($true) {
                $sub = Show-Menu -Title "Import" -Items @(
                    [pscustomobject]@{ Id = "all";      Label = "Import all VMs" }
                    [pscustomobject]@{ Id = "selected"; Label = "Import selected VMs" }
                    [pscustomobject]@{ Id = "host";     Label = "Restore host inventory" }
                    [pscustomobject]@{ Id = "back";     Label = "Back" }
                )
                if ($null -eq $sub -or $sub -eq "back") { break }
                if ($sub -eq "all") { Invoke-ImportWizard -AllVms }
                elseif ($sub -eq "selected") { Invoke-ImportWizard }
                elseif ($sub -eq "host") { Invoke-RestoreHostInventoryWizard }
            }
        }
        elseif ($main -eq "check") {
            while ($true) {
                $sub = Show-Menu -Title "Check" -Items @(
                    [pscustomobject]@{ Id = "host";    Label = "Preflight (this host)" }
                    [pscustomobject]@{ Id = "package"; Label = "Validate backup package" }
                    [pscustomobject]@{ Id = "back";    Label = "Back" }
                )
                if ($null -eq $sub -or $sub -eq "back") { break }
                if ($sub -eq "host") {
                    Invoke-HostPreflight
                    Read-Host "Press Enter to continue"
                }
                elseif ($sub -eq "package") {
                    $p = Resolve-ImportPackageInteractive
                    if ($p) {
                        Invoke-ValidatePackage -PackageRoot $p
                        Read-Host "Press Enter to continue"
                    }
                }
            }
        }
    }
}

# ---------------------------[ Main ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "$env:COMPUTERNAME | $env:USERNAME | $applicationName" -Tag "Info"

try {
    if (-not (Test-IsAdministrator)) {
        throw "Please run Migrate-Vms.ps1 elevated (Administrator)."
    }
    Confirm-HyperVAvailable

    $hasAutomation = $CheckOnly.IsPresent -or $ExportAll.IsPresent -or $ImportAll.IsPresent `
        -or $RestoreHostInventory.IsPresent `
        -or ($VmName -and @($VmName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)

    if (-not $hasAutomation) {
        Start-InteractiveMigrateMenu
        Complete-Script -ExitCode 0
    }

    if ($CheckOnly.IsPresent -and -not $SourcePath) {
        Invoke-HostPreflight
        Complete-Script -ExitCode 0
    }
    if ($CheckOnly.IsPresent -and $SourcePath) {
        Invoke-ValidatePackage -PackageRoot $SourcePath
        Complete-Script -ExitCode 0
    }

    if ($RestoreHostInventory.IsPresent) {
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw "-SourcePath is required for -RestoreHostInventory" }
        $hostDir = Join-Path $SourcePath "host"
        if ($IncludeSwitches) {
            Import-VmSwitchInventory -JsonPath (Join-Path $hostDir "vmswitches.json")
        }
        if (-not $SkipVtpmCerts -and (Test-Path -LiteralPath (Join-Path $hostDir "vtpm-certs.pfx"))) {
            if ([string]::IsNullOrWhiteSpace($SmbPassword)) {
                # reuse SmbPassword param poorly - use prompt
                $pass = Read-SecurePassword -Prompt "PFX password for vTPM certificates"
            }
            else {
                $pass = ConvertTo-SecureString -String $SmbPassword -AsPlainText -Force
            }
            Import-VtpmCertificates -HostFolder $hostDir -Password $pass
        }
        Complete-Script -ExitCode 0
    }

    if ($ExportAll.IsPresent -or ($VmName -and -not $ImportAll.IsPresent)) {
        if ([string]::IsNullOrWhiteSpace($DestinationPath)) { throw "-DestinationPath is required for export" }
        $all = @(Get-AllMigrateInventories)
        $selected = $all
        if ($VmName) {
            $selected = @($all | Where-Object { $VmName -contains $_.Name })
        }
        $isNet = Test-IsUncPath -Path $DestinationPath
        if ($isNet -and $SmbUser) {
            Connect-MigrateSmbShare -Path $DestinationPath -UserName $SmbUser -PlainPassword $SmbPassword
        }
        $vtpmPass = $null
        if ((@($selected | Where-Object { $_.HasVtpm }).Count -gt 0) -and -not $SkipVtpmCerts) {
            $vtpmPass = Read-SecurePassword -Prompt "PFX password for vTPM certificates"
        }
        Start-MigrateExport -Inventories $selected -DestinationRoot $DestinationPath `
            -StagingPathPreferred $StagingPath -IsNetwork:$isNet `
            -DoSwitches:$IncludeSwitches.IsPresent -DoHostSettings:$IncludeHostSettings.IsPresent `
            -DoDirectExport:$DirectExport.IsPresent -AllowRunning:$AllowRunningExport.IsPresent `
            -LiveState $CaptureLiveState -SkipVtpm:$SkipVtpmCerts.IsPresent -VtpmPassword $vtpmPass | Out-Null
        Complete-Script -ExitCode 0
    }

    if ($ImportAll.IsPresent) {
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw "-SourcePath is required for import" }
        if ([string]::IsNullOrWhiteSpace($VmPath) -or [string]::IsNullOrWhiteSpace($VhdPath)) {
            throw "-VmPath and -VhdPath are required for import"
        }
        $vtpmPass = $null
        $manifestPath = Join-Path $SourcePath "manifest.json"
        if (Test-Path -LiteralPath $manifestPath) {
            $m = Read-JsonFile -Path $manifestPath
            if ($m.VtpmExported -and -not $SkipVtpmCerts) {
                $vtpmPass = Read-SecurePassword -Prompt "PFX password for vTPM certificates"
            }
        }
        $ok = Start-MigrateImport -PackageRoot $SourcePath -VmPathRoot $VmPath -VhdPathRoot $VhdPath `
            -OnlyVmNames $VmName -DoStart:$StartAfterImport.IsPresent -Interactive:$false -VtpmPassword $vtpmPass
        Complete-Script -ExitCode $(if ($ok) { 0 } else { 1 })
    }

    Start-InteractiveMigrateMenu
    Complete-Script -ExitCode 0
}
catch {
    Write-Log $_.Exception.Message -Tag "Error"
    Complete-Script -ExitCode 1
}
