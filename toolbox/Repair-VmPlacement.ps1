#Requires -Version 5.1
<#
.SYNOPSIS
    Find Hyper-V VMs whose files are not laid out the way the studio builds them, and move
    them into place - per VM, picked from a list.

.DESCRIPTION
    Build-Vms.ps1 puts every VM in two folders named after it:
      <VM path>\<name>\    the configuration (and checkpoints, smart paging)
      <VHD path>\<name>\   every disk the VM owns
    with the VM and VHD paths taken from the Hyper-V host's defaults unless a config says
    otherwise. A VM built before a fix, by hand, or by another tool can have its disks
    beside its configuration, or anywhere else.

    Interactive console menu (same look as Build-Vms.ps1 / Remove-Vms.ps1):
      Check   list every VM and what is out of place
      Sort    pick the misplaced VMs and move them
    Moves use Move-VMStorage. By default a running VM is shut down first (gracefully,
    never forced) and started again afterwards, so the disks move cold; -Live, or the
    menu's "Move live", keeps it running instead - the same live storage migration
    Hyper-V Manager's "Move..." runs. Folders left empty behind are removed, never a host
    default folder or a drive root.

    Left alone, and said why:
      clustered VMs            storage on a cluster is the cluster's to move
      VMs with checkpoints     the .avhdx chain belongs to the checkpoint tree
      shared disks (.vhds)     VHD Sets, and any disk attached to more than one VM
      pass-through disks       there is no file to move
      differencing parents     only the VM's own child disk moves; a shared gold stays

.NOTES
    Target shell : Windows PowerShell 5.1 and PowerShell 7
    Requires     : Administrator, Hyper-V role
#>

[CmdletBinding()]
param (
    # List every VM and what is out of place; move nothing.
    [switch]$ListOnly,
    # Sort every misplaced VM (needs -Force).
    [switch]$All,
    # Sort only these VMs (needs -Force).
    [string[]]$VmName,
    # Where configurations belong. Default: the Hyper-V host's VirtualMachinePath.
    [string]$VmPath,
    # Where disks belong. Default: the Hyper-V host's VirtualHardDiskPath.
    [string]$VhdPath,
    # Move running VMs live instead of shutting them down first.
    [switch]$Live,
    # Required in parameter mode; without it the plan is printed and nothing moves.
    [switch]$Force
)

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "Repair-VmPlacement"
$logFileName = (Get-Date -Format "yyyyMMdd-HHmm") + ".log"
$applicationName = "Repair-VmPlacement"

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
$enableLogFile = $true

# ---------------------------[ Progress Panel ]---------------------------
# The blue band a compiled cmdlet paints across the top of the console -
# Add-WindowsCapability, Convert-VHD, Optimize-VHD and the rest. It steals rows,
# scrolls the buffer under a menu that has parked its cursor, and looks nothing like
# anything else this script writes. Every operation that draws one is logged before
# and after it, so nothing is lost by turning it off.
#
# It is also a speed win: on Windows PowerShell 5.1 the host repaints that band far
# more often than the work warrants, and for a chunked read the console I/O dominates
# - which is why Invoke-WebRequest is not used for the image download either.
#
# Replacing it with this project's own bar was researched and dropped; the findings
# are in .claude\progress-panel-research.md rather than in code.
#
# GLOBAL, not script scope. Most cmdlets resolve a preference variable by walking the
# caller's scope and would see either, but the Storage module's cmdlets are CDXML -
# generated wrappers over CIM - and Format-Volume was still painting its band with the
# script-scoped form. The global is the scope every lookup ends at, so it is the one
# that reaches all of them. These scripts own their process and exit at the end, so
# there is nothing to restore it for.
$global:ProgressPreference = "SilentlyContinue"

# This script lives in toolbox\, one level below the project root. Logs stay in the
# project-wide logs\ folder next to Build-Vms.ps1, not in a second one under toolbox\.
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = $PSScriptRoot }

$logFileDirectory = Join-Path -Path $projectRoot -ChildPath "logs\repair-vmplacement"
$logFile          = Join-Path -Path $logFileDirectory -ChildPath $logFileName

if ($enableLogFile -and -not (Test-Path -Path $logFileDirectory)) {
    New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null
}

# ---------------------------[ Studio Palette ]---------------------------
#
# Kaido Dark, the studio's default theme, as the console's palette.
#
# Every hex below is lifted verbatim from FAMILIES[kaido].dark in
# html\hyperv-vm-studio.html - which is already this project's default theme
# (data-theme="kaido_dark", THEME_DEFAULT = "kaido") - with one stated exception,
# `yellow`, documented where it is defined. A run and the studio that designed it are
# the same colours rather than two guesses at them.
#
# Truecolor where the console does virtual terminal processing, the nearest of the
# sixteen named ConsoleColors where it does not. Everything that reaches the screen
# goes through Write-Studio, which is what makes the theme one table instead of a
# hundred scattered -ForegroundColor arguments.
#
# The logo is deliberately NOT part of this: it keeps its own base64 ANSI art and
# the colours baked into it.

$script:studioPalette = @{
    bg       = "#16171e"; elevated  = "#1d1f28"; subtle = "#1a1c24"; hover = "#262a38"
    fg       = "#d7dbec"; muted     = "#8b93ad"
    border   = "#2b2f3d"; borderStrong = "#3d4356"; divider = "#23262f"
    accent   = "#7aa2f7"; accentHover = "#93b3fa"; accentSoft = "#22304f"; accentFg = "#11141c"
    success  = "#9ece6a"; danger    = "#f7768e"; warn = "#e0af68"
    bandHost = "#7dcfff"; bandIdent = "#bb9af7"; bandWork = "#9ece6a"; bandDeploy = "#ff9e64"
    # THE ONE VALUE IN THIS TABLE THAT IS NOT THE STUDIO'S.
    #
    # Kaido has exactly two warm colours - warn #e0af68, a gold, and deploy #ff9e64, an
    # orange - and a log needs three warm steps, because `info` is the commonest tag
    # there is and it has to sit below `warn` without either reading as the other.
    #
    # Pick it by HUE, not by eye. 30 degrees is orange, 45 gold, 60 pure yellow; this is
    # 56, far enough from warn's 35 to separate at a glance and short of acid lemon.
    yellow   = "#e6de78"
}

# One per key, for a console that cannot do truecolor. Chosen for the JOB the hex does,
# not the nearest RGB: muted and borderStrong both land on DarkGray because both are
# "quieter than the text", and that is what has to survive.
$script:studioFallback = @{
    bg       = "Black";    elevated  = "Black";  subtle = "Black";     hover = "Black"
    fg       = "Gray";     muted     = "DarkGray"
    border   = "DarkGray"; borderStrong = "DarkGray"; divider = "DarkGray"
    accent   = "Cyan";     accentHover = "White"; accentSoft = "DarkBlue"; accentFg = "Black"
    success  = "Green";    danger    = "Red";     warn = "DarkYellow"
    bandHost = "Cyan";     bandIdent = "Magenta"; bandWork = "Green";   bandDeploy = "Yellow"
    yellow   = "Yellow"
}

function ConvertFrom-HexColor {
    param([string]$Hex)

    $h = $Hex.TrimStart("#")
    return @(
        [Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16),
        [Convert]::ToInt32($h.Substring(4, 2), 16)
    )
}

function Write-Studio {
    # The one write in this script, apart from the logo's own fallback. Takes a palette
    # KEY, never a colour: a call site that names a colour is a call site the theme
    # cannot reach.
    param(
        [AllowEmptyString()][string]$Text = "",
        [string]$Key = "fg",
        [switch]$NoNewline
    )

    $hex = [string]$script:studioPalette[$Key]
    if ([string]::IsNullOrWhiteSpace($hex)) { $hex = [string]$script:studioPalette["fg"] }

    # Cheap after the first call - Enable-MenuVtProcessing caches on $script:menuVtEnabled
    # - and it has to be here rather than only in the menu header, because log lines print
    # long before any header does.
    Enable-MenuVtProcessing
    if (Test-MenuAnsiSupported) {
        $rgb = ConvertFrom-HexColor -Hex $hex
        $escape = [char]27
        Write-Host ("{0}[38;2;{1};{2};{3}m{4}{0}[0m" -f $escape, $rgb[0], $rgb[1], $rgb[2], $Text) -NoNewline:$NoNewline
        return
    }

    $named = [string]$script:studioFallback[$Key]
    if ([string]::IsNullOrWhiteSpace($named)) { $named = "Gray" }
    Write-Host $Text -NoNewline:$NoNewline -ForegroundColor $named
}

function Format-LogPathsForConsole {
    <#
        Shortens every full path in a log line, for the CONSOLE only.

        A build writes the same handful of long paths over and over, and at eighty
        columns a line that is nine tenths path says nothing the eye can use. What
        matters is which file, and where it sits relative to the toolkit.

        A path under the script's own folder becomes the part below it - so
        D:\Tools\HyperV-Scripts\golds\hv-3f9a2c1e.vhdx reads as
        golds\hv-3f9a2c1e.vhdx. Anything else keeps its root and its last two
        segments with an ellipsis between - D:\...\Images\gold.vhdx - which is enough
        to recognise a path without spelling it out.

        The LOG FILE keeps the full text. It is the record somebody reads afterwards,
        possibly on another machine, and a shortened path there is a path that cannot
        be checked.
    #>
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $Message }

    $root = $PSScriptRoot
    $shorten = {
        param([string]$Path)

        $trimmed = $Path.TrimEnd("\")
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $rootTrimmed = $root.TrimEnd("\")
            if ($trimmed.Length -gt $rootTrimmed.Length -and
                $trimmed.Substring(0, $rootTrimmed.Length + 1).Equals($rootTrimmed + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
                return $trimmed.Substring($rootTrimmed.Length + 1)
            }
        }

        # A UNC path has to keep its two leading slashes: \\nas01\golds is a server and
        # a share, and nas01\golds is a folder somewhere quite different.
        $lead = ""
        if ($trimmed.StartsWith("\\")) { $lead = "\\" }

        $segments = @($trimmed -split "\\" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        # A root plus two segments is already short enough to leave alone.
        if ($segments.Count -le 3) { return $Path }
        return ("{0}{1}\...\{2}\{3}" -f $lead, $segments[0], $segments[$segments.Count - 2], $segments[$segments.Count - 1])
    }

    # Drive-letter paths and UNC paths, stopping at whitespace or a closing quote -
    # every path this script logs is wrapped in one or the other.
    $pattern = "(?<path>(?:[A-Za-z]:\\|\\\\)[^\s'`"]*)"
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        return (& $shorten $match.Groups["path"].Value)
    }
    return [System.Text.RegularExpressions.Regex]::Replace($Message, $pattern, $evaluator)
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

    # Palette keys, not ConsoleColor names - see Write-Studio above. info sits BELOW
    # warn on purpose: info is the commonest tag in any run and warn is the one that
    # wants to be noticed. Kaido's two warm colours are one step apart and read as
    # orange-on-orange, so the palette carries a third, `yellow`, for info alone.
    $color = switch ($shown) {
        "start" { "accent" }
        "get"   { "bandHost" }
        "run"   { "bandIdent" }
        "info"  { "yellow" }
        # There is no orange in ConsoleColor. DarkYellow is ANSI 3, which every current
        # scheme renders orange-brown, against info's Yellow = ANSI 11, the pale bright
        # one - so warn reads as the louder of the two, not the dimmer. That colour used
        # to belong to debug, which is now DarkGray, where a diagnostic tag belongs.
        "warn"  { "warn" }
        "o.k."  { "success" }
        "error" { "danger" }
        "debug" { "muted" }
        "end"   { "accent" }
        default { "fg" }
    }

    $logMessage = "$timestamp [ $rawTag ] $Message"

    if ($enableLogFile) {
        # Appended through a FileStream that shares read AND write, so a reader tailing the
        # log never blocks it. Something else can still hold the file for a moment: on
        # 2026-10-03 two New-Vhdx lines vanished in the second after a VHDX was dismounted,
        # past three 120 ms retries of the Add-Content this replaced. So a line is never
        # dropped any more - what cannot be written now waits in $script:LogPending and
        # goes in, in order, ahead of the next line that can. Logging still never blocks
        # the run: a few short retries, then on.
        if ($null -eq $script:LogPending) { $script:LogPending = New-Object System.Collections.Generic.List[string] }
        $script:LogPending.Add($logMessage)
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $stream = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
                    ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                try {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes((($script:LogPending -join "`r`n") + "`r`n"))
                    $stream.Write($bytes, 0, $bytes.Length)
                }
                finally {
                    $stream.Dispose()
                }
                $script:LogPending.Clear()
                break
            }
            catch {
                if ($attempt -lt 5) { Start-Sleep -Milliseconds 100 }
            }
        }
    }

    # The console line is written for the screen these scripts actually run on: a
    # Hyper-V host's own console at 1024x768, which is eighty columns. One line per
    # event, never two.
    #
    # A wrapped line costs two rows and puts the next line's tag out of column, and a
    # run of a few hundred events on that screen becomes unreadable - the eye can no
    # longer run down the tag column, which is the only reason the column exists.
    #
    # So the date goes: every line of one run carries the same one, the clock is what
    # changes, and the log FILE keeps the date in full. What is left is cut to the
    # width rather than being allowed to wrap - the file has the untruncated text, and
    # the paths have already been shortened above.
    $clock = $timestamp.Substring(11)
    $shownMessage = Format-LogPathsForConsole -Message $Message

    # warn and error are NEVER cut. Everything else on this line is something the run
    # is doing and can be read again in the file; those two are the run telling you
    # what went wrong, and a reason with its tail missing is not a reason. They wrap
    # instead - two rows for the lines that earn them.
    if ($shown -ne "warn" -and $shown -ne "error") {
        # The leading space counts too - it is a real column.
    $furniture = 1 + $clock.Length + 1 + 2 + $rawTag.Length + 3
        $available = (Get-ConsoleWidth) - 1 - $furniture
        if ($available -lt 12) { $available = 12 }
        if ($shownMessage.Length -gt $available) {
            $shownMessage = $shownMessage.Substring(0, $available - 3) + "..."
        }
    }

    # Clock and brackets are furniture, not content: `muted` keeps the eye on the tag
    # and the message.
    # One space in front, so the timestamp does not sit flush against the window
    # border. Console only: the log FILE has no border to clear and its lines stay
    # unindented, which keeps them greppable from column one.
    Write-Studio -Text " $clock " -Key "muted" -NoNewline
    Write-Studio -Text "[ " -Key "muted" -NoNewline
    Write-Studio -Text "$rawTag" -Key $color -NoNewline
    Write-Studio -Text " ] " -Key "muted" -NoNewline
    Write-Studio -Text $shownMessage -Key "fg"
}

function Complete-Script {
    param([int]$ExitCode)

    $scriptEndTime = Get-Date
    $duration      = $scriptEndTime - $scriptStartTime
    Write-Log "Runtime $($duration.ToString('hh\:mm\:ss\.ff'))" -Tag "Info"
    Write-Log "Exit $ExitCode" -Tag "Info"
    Write-Log "==================== End ====================" -Tag "End"

    # One blank line before the prompt comes back, so the shell's own line does not sit
    # flush against the end banner.
    Write-Host ""

    exit $ExitCode
}

# Delete retries for files the VMMS service still has a handle on
$script:deleteRetryCount = 5
$script:deleteRetryDelaySeconds = 2
# Folders Hyper-V creates inside a VM configuration root
$script:hyperVConfigSubfolders = @("Virtual Machines", "Snapshots", "Planned Virtual Machines", "UndoLog Configuration")
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

function Get-ConsoleWidth {
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -gt 20) { return [int]$width }
    }
    catch {
        # No RawUI at all - a redirected host, or ISE. 80 is the safe assumption.
    }
    return 80
}

function Write-FastfetchInfoRow {
    # Fastfetch-style aligned "label: value" (colons and values in one column).
    param(
        [string]$Label,
        [string]$Value,
        [int]$LabelWidth = 8,
        # Columns already consumed before this call - the logo and the gap after it,
        # which Show-MenuHeader writes itself.
        [int]$ReservedWidth = 0
    )

    # A value that does not fit WRAPS, and the wrapped part lands in the logo's columns
    # on the next line - straight through the artwork. A header is a summary, so a
    # value that will not fit is truncated rather than allowed to redraw the screen.
    # The label is measured, not assumed. $LabelWidth is the column it is padded TO,
    # and a longer label simply overruns it - budgeting for eight when twelve are
    # written leaves the value four columns too long, which is exactly enough to wrap
    # it into the logo.
    $labelCells = [Math]::Max($LabelWidth, $Label.Length)
    $available = (Get-ConsoleWidth) - 1 - $ReservedWidth - $labelCells - 2
    if ($available -lt 8) { $available = 8 }
    if ($Value.Length -gt $available) {
        $Value = $Value.Substring(0, $available - 3) + "..."
    }

    $paddedLabel = ("{0,-$LabelWidth}" -f $Label)
    Write-Studio -Text $paddedLabel -Key "accent" -NoNewline
    Write-Studio -Text ": " -Key "accent" -NoNewline
    Write-Studio -Text $Value -Key "muted"
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
                Write-Studio -Text $row.Value -Key "fg"
            }
            else {
                # The two-space indent Show-MenuHeader writes before the logo counts too: the
                # row starts at column 2, not column 0 - logo, the three-space gap, that indent.
                Write-FastfetchInfoRow -Label $row.Label -Value $row.Value -LabelWidth $labelWidth -ReservedWidth ($logoWidth + 5)
            }
        }
        else {
            Write-Host ""
        }
    }

    Write-Host ""
    Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
    Write-Host ""
}

# ---------------------------[ Flicker-Free Repaint ]---------------------------
# Every interactive blade used to redraw itself from the top on each keypress:
# Clear-Host, the logo, the header, then the list. On a short list that reads as a
# blink; on a long one it is a page of writing per arrow key and the screen visibly
# flashes.
#
# The header does not change while a list is being walked, so it is drawn ONCE and the
# cursor parked underneath it. Each keypress rewinds to that spot, wipes what is below
# and writes the list again - the top of the screen is never touched, so there is
# nothing to flash.
#
# Where the host cannot report or set a cursor position - ISE, a redirected console, a
# terminal with no VT - every one of these returns false and the caller falls back to
# the full redraw it always did.

function Get-MenuCursorAnchor {
    if (-not (Test-MenuHostSupported)) { return $null }
    if (-not (Test-MenuAnsiSupported)) { return $null }
    try { return $Host.UI.RawUI.CursorPosition }
    catch { return $null }
}

function Set-MenuCursorAnchor {
    param($Anchor)

    if ($null -eq $Anchor) { return $false }
    if (-not (Test-MenuHostSupported)) { return $false }
    try {
        $Host.UI.RawUI.CursorPosition = $Anchor
        return $true
    }
    catch {
        # The buffer scrolled and the row the anchor names is gone. Saying so is what
        # makes the caller draw the whole screen again instead of writing the list
        # somewhere arbitrary.
        return $false
    }
}

function Clear-MenuBelowCursor {
    # ESC[0J - erase from the cursor to the end of the screen. Clear-Host would take
    # the header and the logo with it, and redrawing those is the flicker.
    if (-not (Test-MenuAnsiSupported)) { return $false }
    try {
        Write-Host ("{0}[0J" -f [char]27) -NoNewline
        return $true
    }
    catch {
        return $false
    }
}

function Test-MenuWindowScrolled {
    # A frame taller than the window scrolls as its last lines are written, so this is
    # only ever asked once a frame is COMPLETE - see where the caller reads it.
    param($TopBefore)

    if ($null -eq $TopBefore) { return $false }
    try { return ($Host.UI.RawUI.WindowPosition.Y -ne $TopBefore) }
    catch { return $true }
}

function Get-MenuWindowTop {
    if (-not (Test-MenuHostSupported)) { return $null }
    try { return [int]$Host.UI.RawUI.WindowPosition.Y }
    catch { return $null }
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

        # Header and anything above the list stay put while it is walked - they are
        # drawn once and the keypress repaints only what is below them.
        $anchor = $null
        $windowTop = $null

    while ($true) {
        $repainted = $false
        if ($null -ne $anchor -and -not (Test-MenuWindowScrolled -TopBefore $windowTop)) {
            if (Set-MenuCursorAnchor -Anchor $anchor) {
                $repainted = (Clear-MenuBelowCursor)
                if (-not $repainted) { $anchor = $null }
            }
            else {
                $anchor = $null
            }
        }
        if (-not $repainted) {
            Show-MenuHeader -Title $Title -StatusLines $StatusLines

            if (-not [string]::IsNullOrWhiteSpace($questionText)) {
                Write-Studio -Text "  $questionText" -Key "fg"
                Write-Host ""
            }

            $anchor = Get-MenuCursorAnchor
        }

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item  = $Items[$i]
            $label = if ($item.Label) { [string]$item.Label } else { [string]$item }
            $selected = ($i -eq $index)

            if ($selected) {
                Write-Studio -Text "  > " -Key "accent" -NoNewline
                Write-Studio -Text $label -Key "fg"
            }
            else {
                Write-Host "    " -NoNewline
                Write-Studio -Text $label -Key "muted"
            }
        }

        Write-Host ""
        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
        if ($useRawUi) {
            Write-Studio -Text "  Up/Down move   Enter select   Esc/Q cancel" -Key "muted"
        }
        else {
            Write-Studio -Text "  Enter number + Enter   (Q to cancel)" -Key "muted"
        }
        Write-Host ""

        # Read when the frame is COMPLETE, never half way through it. A frame taller
        # than the window scrolls as its last lines are written, so a top measured
        # before the list was drawn always disagrees with the one measured after - and
        # the guard then declared a scroll on every keypress and redrew the whole
        # screen, which is the flicker coming back on exactly the tall blades.
        $windowTop = Get-MenuWindowTop
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

        # Header and anything above the list stay put while it is walked - they are
        # drawn once and the keypress repaints only what is below them.
        $anchor = $null
        $windowTop = $null

    while ($true) {
        $repainted = $false
        if ($null -ne $anchor -and -not (Test-MenuWindowScrolled -TopBefore $windowTop)) {
            if (Set-MenuCursorAnchor -Anchor $anchor) {
                $repainted = (Clear-MenuBelowCursor)
                if (-not $repainted) { $anchor = $null }
            }
            else {
                $anchor = $null
            }
        }
        if (-not $repainted) {
            Show-MenuHeader -Title $Title -StatusLines $StatusLines -Subtitle "Space toggles selection"

            if (-not [string]::IsNullOrWhiteSpace($questionText)) {
                Write-Studio -Text "  $questionText" -Key "fg"
                Write-Host ""
            }

            $anchor = Get-MenuCursorAnchor
        }

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item  = $Items[$i]
            $id    = [string]$item.Id
            $mark  = if ($selected[$id]) { "[x]" } else { "[ ]" }
            $label = "$mark  $($item.Label)"
            $isSelectedRow = ($i -eq $index)

            if ($isSelectedRow) {
                Write-Studio -Text "  > " -Key "accent" -NoNewline
                Write-Studio -Text $label -Key "fg"
            }
            else {
                Write-Host "    " -NoNewline
                Write-Studio -Text $label -Key "muted"
            }
        }

        Write-Host ""
        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
        if ($useRawUi) {
            Write-Studio -Text "  Up/Down move   Space toggle   Enter done   Esc/Q cancel" -Key "muted"
        }
        else {
            Write-Studio -Text "  Number toggles, Enter alone confirms, Q cancels" -Key "muted"
        }
        Write-Host ""

        # Read when the frame is COMPLETE, never half way through it. A frame taller
        # than the window scrolls as its last lines are written, so a top measured
        # before the list was drawn always disagrees with the one measured after - and
        # the guard then declared a scroll on every keypress and redrew the whole
        # screen, which is the flicker coming back on exactly the tall blades.
        $windowTop = Get-MenuWindowTop
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

# ---------------------------[ Progress bar ]---------------------------
# The Pac-Man bar from Build-Vms.ps1 / New-Vhdx.ps1, copied rather than shared - every
# script in this project carries its own. Move-VMStorage reports nothing while it
# copies, so the bar is fed from Hyper-V's own job: the Msvm_MigrationJob ("Moving
# Storage") for this VM, whose PercentComplete climbs as the copy goes. The destination
# file's size is no use - Hyper-V creates it at full length before copying a byte.

function Format-Duration {
    param([double]$Seconds)

    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) { return "--:--" }
    if ($Seconds -gt 359999) { return "99:59:59" }

    $span = [System.TimeSpan]::FromSeconds([Math]::Round($Seconds))
    if ($span.TotalHours -ge 1) { return ("{0}:{1:00}:{2:00}" -f [int]$span.TotalHours, $span.Minutes, $span.Seconds) }
    return ("{0}:{1:00}" -f $span.Minutes, $span.Seconds)
}

function Write-ChompBar {
    <#
        The bar itself, drawn the way pacman draws its ILoveCandy one: a mouth eating
        its way along a line of dots, leaving a chewed track behind it.

            [------C  o  o  o  o  o  o  o ]

        Still 7-bit ASCII, for the same reason the rest of this line is - "C", "c", "o"
        and "-" are on every console in existence, and this output runs for minutes on
        a machine nobody has configured yet.

        The dots sit at fixed cells, every third one, so they stay put and the mouth
        eats them as it advances rather than the whole field sliding along. The mouth
        opens and closes on a frame counter rather than on the position: a 32 GB copy
        can sit on the same percentage for a minute, and a bar that has stopped moving
        is exactly when it matters that it is still alive.
    #>
    param(
        [int]$Width,
        [int]$Filled
    )

    if ($Width -lt 1) { return }
    if ($Filled -lt 0) { $Filled = 0 }
    if ($Filled -gt $Width) { $Filled = $Width }

    # The line repaints every 80 ms, so four frames a mouth is roughly three chomps a
    # second. Flapping on every repaint is twelve, which reads as jitter rather than
    # as something eating.
    $script:chompFrame = ([int]$script:chompFrame + 1) % 8
    $mouth = if ($script:chompFrame -lt 4) { "C" } else { "c" }

    # Nothing left to eat: the mouth goes with the last dot rather than sitting on the
    # end of a finished bar. A completed download is a solid line, full width.
    if ($Filled -ge $Width) {
        Write-Studio -Text ("-" * $Width) -Key "fg" -NoNewline
        return
    }

    # The mouth stands on the last eaten cell, so an empty bar still shows it at the
    # start rather than leaving the line blank until the first percent arrives.
    $mouthAt = $Filled - 1
    if ($mouthAt -lt 0) { $mouthAt = 0 }

    if ($mouthAt -gt 0) {
        Write-Studio -Text ("-" * $mouthAt) -Key "fg" -NoNewline
    }
    Write-Studio -Text $mouth -Key "yellow" -NoNewline

    $ahead = $Width - $mouthAt - 1
    if ($ahead -gt 0) {
        $dots = New-Object System.Text.StringBuilder
        for ($cell = $mouthAt + 1; $cell -lt $Width; $cell++) {
            # Counted from the bar's own start, not from the mouth - a dot belongs to a
            # place on the track, and moving with the mouth would make it uneatable.
            if (($cell % 3) -eq 0) { [void]$dots.Append("o") } else { [void]$dots.Append(" ") }
        }
        Write-Studio -Text $dots.ToString() -Key "accent" -NoNewline
    }
}

function Write-DownloadProgressLine {
    <#
        One line, redrawn in place with a carriage return.

        Deliberately 7-bit ASCII. Block-drawing characters look better but depend on
        the console font having them, and this is the one piece of output that runs
        for minutes on a machine nobody has configured yet. Colour still applies -
        the mouth takes the log's own info yellow, the dots ahead of it the accent
        blue, the chewed track behind it the foreground the brackets have, the
        numbers muted:

          [-----------C  o  o  o  o  o  ]  58%  478.2/824.6 MiB  12.4 MiB/s  ETA 0:28
    #>
    param(
        [int64]$BytesRead,
        [int64]$TotalBytes,
        [double]$BytesPerSecond,
        # Only ever seen when the total is unknown - everything else on the line is the
        # same whether the bytes came off a mirror or off another disk.
        [string]$Activity = "downloading",
        [switch]$Final
    )

    $rate = ""
    if ($BytesPerSecond -gt 0) { $rate = "  " + (Format-ByteSize -Bytes ([int64]$BytesPerSecond)) + "/s" }

    if ($TotalBytes -gt 0) {
        $percent = [int][Math]::Floor(($BytesRead * 100.0) / $TotalBytes)
        if ($percent -gt 100) { $percent = 100 }

        # EVERY field here is a fixed width, and that is the whole point. The bar takes
        # whatever the stats leave, so a stats string that grows by a character - 9.9
        # MiB becoming 10.1 MiB, an ETA gaining a digit - steals a cell from the track
        # and the bar visibly twitches between redraws several times a second.
        # Right-aligned numbers, left-aligned units, blanks where a value is absent.
        $counts = "{0,9}/{1,-9}" -f (Format-ByteSize -Bytes $BytesRead), (Format-ByteSize -Bytes $TotalBytes)

        if ($BytesPerSecond -gt 0) { $rate = "{0,9}/s" -f (Format-ByteSize -Bytes ([int64]$BytesPerSecond)) }
        else                       { $rate = " " * 11 }

        if ($Final)                     { $eta = " " * 11 }
        elseif ($BytesPerSecond -gt 0)  { $eta = "ETA {0,-7}" -f (Format-Duration -Seconds (($TotalBytes - $BytesRead) / $BytesPerSecond)) }
        else                            { $eta = "ETA {0,-7}" -f "--:--" }

        # The percentage is the one number somebody reads at a glance, so it carries the
        # foreground the brackets do. Everything after it - the byte counts, the rate,
        # the ETA - is detail and stays muted. Split only at drawing time: the width
        # calculation below needs the whole line's length either way.
        $percentText = "{0,4}%" -f $percent
        $statsRest = "  " + $counts + "  " + $rate + "  " + $eta
        $stats = $percentText + $statsRest

        # The bar gets whatever is left. Two for the brackets, two for the leading
        # indent, one so the line never lands in the last cell - writing there wraps
        # the console and scrolls the bar out of sight.
        $barWidth = (Get-ConsoleWidth) - $stats.Length - 7
        if ($barWidth -lt 10) { $barWidth = 10 }
        if ($barWidth -gt 60) { $barWidth = 60 }

        $filled = [int][Math]::Floor(($BytesRead * [double]$barWidth) / $TotalBytes)
        if ($filled -gt $barWidth) { $filled = $barWidth }
        if ($filled -lt 0) { $filled = 0 }

        Write-Host "`r" -NoNewline
        # The brackets take `fg`, not `border`: they are what gives the bar its ends, and
        # at border they sank into the background beside the track they are meant to bound.
        Write-Studio -Text "  [" -Key "fg" -NoNewline
        Write-ChompBar -Width $barWidth -Filled $filled
        Write-Studio -Text "]" -Key "fg" -NoNewline
        Write-Studio -Text $percentText -Key "fg" -NoNewline
        Write-Studio -Text $statsRest -Key "muted" -NoNewline
        $drawn = 3 + $barWidth + $stats.Length
    }
    else {
        # No Content-Length: a chunked response, or a proxy that stripped it. There is
        # no percentage to show and no end to predict, so the line says what it knows.
        $stats = "  " + (Format-ByteSize -Bytes $BytesRead) + $rate
        Write-Host "`r" -NoNewline
        Write-Studio -Text "  [ $Activity ]" -Key "fg" -NoNewline
        Write-Studio -Text $stats -Key "muted" -NoNewline
        $drawn = 6 + $Activity.Length + $stats.Length
    }

    # Pad out whatever the previous, longer line left behind.
    $slack = (Get-ConsoleWidth) - 1 - $drawn
    if ($slack -gt 0) { Write-Host (" " * $slack) -NoNewline }

    if ($Final) { Write-Host "" }
}

# ---------------------------[ Placement ]---------------------------
# How long a shutdown may take before the VM is skipped. Longer than Hyper-V's own
# window on purpose: with -Force, Hyper-V gives the guest five minutes and then shuts it
# down itself (Stop-VM docs) - wait exactly those five minutes and a VM goes Off a moment
# after the script has already given up on it, and is never started again.
$script:shutdownTimeoutSeconds = 360
# The Guest Service Shutdown integration component, by id - its Name is localized.
$script:shutdownServiceId = "9F8233AC-BE49-4C79-8EE3-E7E1985B2077"

function Get-PlacementRoots {
    # The two roots every VM belongs under: the parameters when given, else the
    # Hyper-V host's own defaults - the same fallback Build-Vms.ps1 uses for a blank
    # vmPath / vhdPath.
    $vmRoot = [string]$VmPath
    $vhdRoot = [string]$VhdPath
    if ([string]::IsNullOrWhiteSpace($vmRoot) -or [string]::IsNullOrWhiteSpace($vhdRoot)) {
        $h = Get-VMHost -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($vmRoot)) { $vmRoot = [string]$h.VirtualMachinePath }
        if ([string]::IsNullOrWhiteSpace($vhdRoot)) { $vhdRoot = [string]$h.VirtualHardDiskPath }
    }
    if ([string]::IsNullOrWhiteSpace($vhdRoot)) { $vhdRoot = $vmRoot }
    return [pscustomobject]@{ VmRoot = $vmRoot.TrimEnd('\'); VhdRoot = $vhdRoot.TrimEnd('\') }
}

function Get-DiskOwnerCounts {
    # How many VMs each disk file is attached to, so a disk two VMs share is never
    # dragged into one VM's folder.
    param([object[]]$Vms)
    $count = @{}
    foreach ($vm in $Vms) {
        foreach ($d in @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue)) {
            $k = Get-PathKey ([string]$d.Path)
            if ($k) { $count[$k] = 1 + [int]$count[$k] }
        }
    }
    return $count
}

function Get-VmPlacement {
    # One VM against the layout: where each part is, where it should be, and why it
    # cannot be moved when it cannot.
    param(
        [object]$Vm,
        [object]$Roots,
        [hashtable]$OwnerCounts
    )

    $configKey = Get-PathKey ([string]$Vm.ConfigurationLocation)
    # The folder name the VM already has when its configuration sits directly under the
    # VM root - Build-Vms keeps the short name there even when it renames the VM to its
    # FQDN - and the VM's name otherwise.
    $folderName = [string]$Vm.Name
    $configParent = Get-PathKey (Split-Path -Parent ([string]$Vm.ConfigurationLocation))
    if ($configParent -eq (Get-PathKey $Roots.VmRoot)) {
        $folderName = Split-Path -Leaf ([string]$Vm.ConfigurationLocation)
    }
    $wantVm = Join-Path -Path $Roots.VmRoot -ChildPath $folderName
    $wantVhd = Join-Path -Path $Roots.VhdRoot -ChildPath $folderName

    $problems = @()
    $skip = @()
    $configMove = $false
    foreach ($loc in @([string]$Vm.ConfigurationLocation, [string]$Vm.SnapshotFileLocation, [string]$Vm.SmartPagingFilePath)) {
        if ([string]::IsNullOrWhiteSpace($loc)) { continue }
        if ((Get-PathKey $loc) -ne (Get-PathKey $wantVm)) { $configMove = $true }
    }
    if ($configMove) { $problems += "config in '$([string]$Vm.ConfigurationLocation)'" }

    $diskMoves = @()
    foreach ($d in @(Get-VMHardDiskDrive -VM $Vm -ErrorAction SilentlyContinue)) {
        $path = [string]$d.Path
        if ([string]::IsNullOrWhiteSpace($path) -or $null -ne $d.DiskNumber) {
            $skip += "pass-through disk on $($d.ControllerType) $($d.ControllerNumber):$($d.ControllerLocation)"
            continue
        }
        $key = Get-PathKey $path
        if ($path -match '\.vhds$') { $skip += "shared VHD Set '$path' stays"; continue }
        if ([int]$OwnerCounts[$key] -gt 1) { $skip += "disk '$path' is attached to another VM too"; continue }
        $parentKey = Get-PathKey (Split-Path -Parent $path)
        if ($parentKey -eq (Get-PathKey $wantVhd)) { continue }
        $target = Join-Path -Path $wantVhd -ChildPath (Split-Path -Leaf $path)
        $bytes = 0
        try { $bytes = (Get-Item -LiteralPath $path -ErrorAction Stop).Length } catch { }
        $diskMoves += [pscustomobject]@{ Source = $path; Destination = $target; Bytes = [int64]$bytes }
        $problems += "disk '$(Split-Path -Leaf $path)' in '$(Split-Path -Parent $path)'"
    }

    $blocked = @()
    if ($Vm.IsClustered) { $blocked += "clustered - move it with Failover Cluster Manager" }
    $checkpoints = @(Get-VMSnapshot -VM $Vm -ErrorAction SilentlyContinue)
    if ($checkpoints.Count -gt 0) { $blocked += "$($checkpoints.Count) checkpoint(s) - delete or merge them first" }
    foreach ($m in $diskMoves) {
        if ((Test-Path -LiteralPath $m.Destination) -and ((Get-PathKey $m.Destination) -ne (Get-PathKey $m.Source))) {
            $blocked += "'$($m.Destination)' already exists"
        }
    }

    $status = "ok"
    if ($problems.Count -gt 0) { $status = if ($blocked.Count -gt 0) { "blocked" } else { "misplaced" } }

    return [pscustomobject]@{
        Id          = [string]$Vm.Id
        Name        = [string]$Vm.Name
        State       = [string]$Vm.State
        Vm          = $Vm
        Status      = $status
        WantVm      = $wantVm
        WantVhd     = $wantVhd
        ConfigMove  = $configMove
        DiskMoves   = $diskMoves
        MoveBytes   = [int64](($diskMoves | Measure-Object -Property Bytes -Sum).Sum)
        Problems    = $problems
        Blocked     = $blocked
        Skipped     = $skip
        OldFolders  = @(@([string]$Vm.ConfigurationLocation) + @($diskMoves | ForEach-Object { Split-Path -Parent $_.Source }) | Select-Object -Unique)
    }
}

function Get-AllPlacements {
    param([object]$Roots)
    $vms = @(Get-VM -ErrorAction Stop | Sort-Object -Property Name)
    $owners = Get-DiskOwnerCounts -Vms $vms
    return @($vms | ForEach-Object { Get-VmPlacement -Vm $_ -Roots $Roots -OwnerCounts $owners })
}

function Write-PlacementReport {
    param([object[]]$Placements)

    foreach ($p in $Placements) {
        switch ($p.Status) {
            "ok"        { Write-Log ("{0,-24} in place" -f $p.Name) -Tag "Ok" }
            "misplaced" {
                $size = if ($p.DiskMoves.Count -gt 0) { "$(Format-ByteSize $p.MoveBytes) to move" } else { "config only" }
                Write-Log ("{0,-24} out of place - {1}" -f $p.Name, $size) -Tag "Warn"
                foreach ($x in $p.Problems) { Write-Log "    $x" -Tag "Info" }
                Write-Log "    -> config '$($p.WantVm)', disks '$($p.WantVhd)'" -Tag "Info"
            }
            "blocked"   {
                Write-Log ("{0,-24} out of place, cannot be moved" -f $p.Name) -Tag "Error"
                foreach ($x in $p.Problems) { Write-Log "    $x" -Tag "Info" }
                foreach ($x in $p.Blocked) { Write-Log "    $x" -Tag "Warn" }
            }
        }
        foreach ($x in $p.Skipped) { Write-Log "    left alone: $x" -Tag "Info" }
    }
    $mis = @($Placements | Where-Object Status -eq "misplaced").Count
    $blk = @($Placements | Where-Object Status -eq "blocked").Count
    Write-Log ("{0} VM(s): {1} in place, {2} to sort, {3} blocked" -f $Placements.Count, ($Placements.Count - $mis - $blk), $mis, $blk) -Tag "Info"
}

function Test-FreeSpaceForMoves {
    # A move to another volume needs the room first; one on the same volume is a rename.
    param([object[]]$Placements)
    $need = @{}
    foreach ($p in $Placements) {
        foreach ($m in $p.DiskMoves) {
            $dst = [IO.Path]::GetPathRoot($m.Destination).ToUpperInvariant()
            if ($dst -eq [IO.Path]::GetPathRoot($m.Source).ToUpperInvariant()) { continue }
            $need[$dst] = [int64]$need[$dst] + $m.Bytes
        }
    }
    $ok = $true
    foreach ($root in $need.Keys) {
        $free = (Get-PSDrive -Name $root.Substring(0, 1) -ErrorAction SilentlyContinue).Free
        if ($null -ne $free -and $free -lt $need[$root]) {
            Write-Log ("{0} needs {1}, has {2} free" -f $root, (Format-ByteSize $need[$root]), (Format-ByteSize $free)) -Tag "Error"
            $ok = $false
        }
    }
    return $ok
}

function Stop-VmGracefully {
    # A guest shutdown through the integration service, waited for. Never a turn off:
    # a VM that will not shut down cleanly is one to look at, not one to move.
    #
    # The service is checked first, because Stop-VM -Force does not fail when nobody
    # answers - it powers the VM off. Tried on HV-01: a VM whose shutdown service said
    # "No Contact" (no OS, sitting in firmware) was Off within a second, no error. The
    # same holds for a Linux guest without hv_utils, a VM at a boot menu or installer,
    # or a hung guest. So the request is only made to a VM whose service is up.
    # -Force stays: a job cannot answer the "unsaved data / locked" prompt.
    param([object]$Vm)

    $service = @(Get-VMIntegrationService -VM $Vm -ErrorAction SilentlyContinue |
                 Where-Object { [string]$_.Id -like "*$($script:shutdownServiceId)*" }) | Select-Object -First 1
    if ($null -eq $service -or -not $service.Enabled -or [string]$service.PrimaryOperationalStatus -ne "Ok") {
        $why = if ($null -eq $service) { "no shutdown integration service" }
               elseif (-not $service.Enabled) { "its shutdown integration service is disabled" }
               else { "its shutdown integration service is not answering ($($service.PrimaryStatusDescription))" }
        Write-Log "'$($Vm.Name)' skipped - $why, and a shutdown request would power it off. Shut it down yourself, or use -Live" -Tag "Error"
        return $false
    }

    Write-Log "Shutting down '$($Vm.Name)'" -Tag "Run"
    try {
        $job = Stop-VM -VM $Vm -Force -AsJob -ErrorAction Stop
    }
    catch {
        Write-Log "Shutdown of '$($Vm.Name)' could not be requested: $($_.Exception.Message)" -Tag "Error"
        return $false
    }
    try {
        $deadline = (Get-Date).AddSeconds($script:shutdownTimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if ([string](Get-VM -Id $Vm.Id).State -eq "Off") { return $true }
            if ($job.State -eq "Failed") {
                $null = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors 2>$null
                $text = if ($jobErrors) { $jobErrors[0].Exception.Message } else { [string]$job.ChildJobs[0].JobStateInfo.Reason }
                Write-Log "Shutdown of '$($Vm.Name)' failed: $text" -Tag "Error"
                return $false
            }
            Start-Sleep -Seconds 2
        }
        # One last look: the deadline sits past Hyper-V's five minutes, so a guest it
        # had to shut down itself is Off by now and is treated like any other.
        if ([string](Get-VM -Id $Vm.Id).State -eq "Off") { return $true }
        Write-Log "'$($Vm.Name)' is not off after $($script:shutdownTimeoutSeconds)s - skipped, not forced" -Tag "Error"
        return $false
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Move-VmIntoPlace {
    param(
        [object]$Placement,
        [bool]$ShutDownFirst = $true
    )

    $p = $Placement
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log "Moving '$($p.Name)' ($($p.State), $(Format-ByteSize $p.MoveBytes))" -Tag "Run"

    # Only a Running VM is shut down and started again; one that was Off stays Off, and
    # a Saved or Paused one is moved as it is (its state files move with the config).
    $restart = $false
    if ($ShutDownFirst -and [string](Get-VM -Id $p.Id).State -eq "Running") {
        if (-not (Stop-VmGracefully -Vm $p.Vm)) { return $false }
        $restart = $true
    }

    $moveArgs = @{ VM = $p.Vm; ErrorAction = "Stop" }
    if ($p.ConfigMove) {
        $moveArgs.VirtualMachinePath = $p.WantVm
        $moveArgs.SnapshotFilePath = $p.WantVm
        $moveArgs.SmartPagingFilePath = $p.WantVm
    }
    if ($p.DiskMoves.Count -gt 0) {
        # A plain loop into a typed array. Built in a pipeline, the hashtables arrive
        # wrapped and Move-VMStorage answers "must contain 'DestinationFilePath' key"
        # about a table that plainly has one.
        [hashtable[]]$vhds = @()
        foreach ($m in $p.DiskMoves) {
            $vhds += @{ SourceFilePath = [string]$m.Source; DestinationFilePath = [string]$m.Destination }
        }
        $moveArgs.Vhds = $vhds
        if (-not (Test-Path -LiteralPath $p.WantVhd)) { New-Item -ItemType Directory -Path $p.WantVhd -Force | Out-Null }
    }
    foreach ($m in $p.DiskMoves) { Write-Log "  $($m.Source) -> $($m.Destination)" -Tag "Info" }
    if ($p.ConfigMove) { Write-Log "  config -> $($p.WantVm)" -Tag "Info" }

    try {
        Invoke-MoveWithProgress -MoveArgs $moveArgs -Placement $p
    }
    catch {
        Write-Log "Move of '$($p.Name)' failed: $($_.Exception.Message)" -Tag "Error"
        # Hyper-V leaves a failed move on the old files, so the VM can start as it was.
        if ($restart) { Start-VmAgain -Id $p.Id -Name $p.Name }
        return $false
    }
    if ($restart) { Start-VmAgain -Id $p.Id -Name $p.Name }

    # Check the result rather than trusting the cmdlet's silence.
    $vm = Get-VM -Id $p.Id -ErrorAction SilentlyContinue
    $bad = @()
    foreach ($d in @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue)) {
        $src = @($p.DiskMoves | Where-Object { (Get-PathKey (Split-Path -Leaf $_.Destination)) -eq (Get-PathKey (Split-Path -Leaf ([string]$d.Path))) })
        if ($src.Count -gt 0 -and (Get-PathKey ([string]$d.Path)) -ne (Get-PathKey $src[0].Destination)) { $bad += [string]$d.Path }
    }
    if ($p.ConfigMove -and (Get-PathKey ([string]$vm.ConfigurationLocation)) -ne (Get-PathKey $p.WantVm)) { $bad += "config still in '$($vm.ConfigurationLocation)'" }
    if ($bad.Count -gt 0) {
        foreach ($b in $bad) { Write-Log "  not where it should be: $b" -Tag "Error" }
        return $false
    }

    $stop = Get-HostStopFolders
    foreach ($k in @((Get-PathKey $p.WantVm), (Get-PathKey $p.WantVhd), (Get-PathKey $script:roots.VmRoot), (Get-PathKey $script:roots.VhdRoot))) { if ($k) { $stop[$k] = $true } }
    foreach ($old in $p.OldFolders) {
        if ([string]::IsNullOrWhiteSpace($old) -or -not (Test-Path -LiteralPath $old)) { continue }
        if ($stop.ContainsKey((Get-PathKey $old))) { continue }
        # A configuration folder Hyper-V has moved out of keeps the empty subfolders it
        # created - "Virtual Machines", "Snapshots", "UndoLog Configuration" - so it is
        # not empty until they go. Only those names, and only when they hold nothing.
        foreach ($sub in $script:hyperVConfigSubfolders) {
            $subPath = Join-Path -Path $old -ChildPath $sub
            if (Test-FolderIsEmpty -Path $subPath) { [void](Remove-FolderWithRetry -Path $subPath) }
        }
        Remove-EmptyFolderChain -StartFolder $old -StopFolders $stop
    }

    $clock.Stop()
    Write-Log "Moved '$($p.Name)' in $($clock.Elapsed.ToString('hh\:mm\:ss\.ff'))" -Tag "Ok"
    return $true
}

function Invoke-MoveWithProgress {
    # Move-VMStorage as a job, with the bar drawn from Hyper-V's migration job while it
    # runs. A move with no disks (config only) or a console that cannot draw simply
    # waits. Errors surface from Receive-Job, so the caller's catch sees them.
    param(
        [hashtable]$MoveArgs,
        [object]$Placement
    )

    $job = Move-VMStorage @MoveArgs -AsJob
    $total = [int64]$Placement.MoveBytes
    $draw = ($total -gt 0) -and (Test-MenuHostSupported)
    if ($draw) {
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Host ""
        $done = [int64]0
        $percent = 0
        $vmId = ([string]$Placement.Id).ToUpperInvariant()
        while ($job.State -eq "Running" -or $job.State -eq "NotStarted") {
            # JobState 4 is Running; VirtualSystemName is the VM's GUID. A finished job
            # from an earlier move of the same VM reads 100 and must not count.
            $hv = Get-CimInstance -Namespace root\virtualization\v2 -ClassName Msvm_MigrationJob -ErrorAction SilentlyContinue |
                Where-Object { $_.JobState -eq 4 -and ([string]$_.VirtualSystemName).ToUpperInvariant() -eq $vmId } |
                Select-Object -First 1
            if ($hv -and [int]$hv.PercentComplete -gt $percent) { $percent = [int]$hv.PercentComplete }
            $done = [int64]($total * $percent / 100)
            $rate = 0.0
            if ($clock.Elapsed.TotalSeconds -gt 0.5) { $rate = $done / $clock.Elapsed.TotalSeconds }
            Write-DownloadProgressLine -BytesRead $done -TotalBytes $total -BytesPerSecond $rate -Activity "moving"
            Start-Sleep -Milliseconds 200
        }
        $clock.Stop()
        $average = 0.0
        if ($clock.Elapsed.TotalSeconds -gt 0) { $average = $total / $clock.Elapsed.TotalSeconds }
        if ($job.State -eq "Completed") { $done = $total }
        Write-DownloadProgressLine -BytesRead $done -TotalBytes $total -BytesPerSecond $average -Activity "moving" -Final
        Write-Host ""
    }
    else {
        [void](Wait-Job -Job $job)
    }
    try {
        Receive-Job -Job $job -ErrorAction Stop | Out-Null
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Start-VmAgain {
    param([string]$Id, [string]$Name)
    try {
        Start-VM -VM (Get-VM -Id $Id) -ErrorAction Stop
        Write-Log "Started '$Name' again" -Tag "Run"
    }
    catch {
        Write-Log "Could not start '$Name' again: $($_.Exception.Message)" -Tag "Error"
    }
}

function Start-PlacementMoves {
    param(
        [object[]]$Placements,
        [bool]$ShutDownFirst = $true
    )
    if (-not (Test-FreeSpaceForMoves -Placements $Placements)) { return $false }
    $mode = if ($ShutDownFirst) { "running VMs are shut down first and started again" } else { "running VMs are moved live" }
    Write-Log "Move mode: $mode" -Tag "Info"
    $failed = 0
    foreach ($p in $Placements) {
        if (-not (Move-VmIntoPlace -Placement $p -ShutDownFirst $ShutDownFirst)) { $failed++ }
    }
    if ($failed -gt 0) {
        Write-Log "$failed of $($Placements.Count) VM(s) could not be moved" -Tag "Error"
        return $false
    }
    Write-Log "$($Placements.Count) VM(s) moved into place" -Tag "Ok"
    return $true
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


function Get-PlacementLabel {
    param([object]$Placement)
    $what = @()
    if ($Placement.ConfigMove) { $what += "config" }
    if ($Placement.DiskMoves.Count -gt 0) { $what += "$($Placement.DiskMoves.Count) disk(s)" }
    return ("{0,-24} {1,-10} {2,-22} {3}" -f $Placement.Name, $Placement.State, ($what -join " + "), (Format-ByteSize $Placement.MoveBytes))
}

function Get-RootStatusLines {
    return [ordered]@{ "vm path" = $script:roots.VmRoot; "vhd path" = $script:roots.VhdRoot }
}

function Invoke-SortWizard {
    $placements = @(Get-AllPlacements -Roots $script:roots)
    $movable = @($placements | Where-Object Status -eq "misplaced")
    if ($movable.Count -eq 0) {
        Write-PlacementReport -Placements $placements
        Write-Log "Nothing to sort" -Tag "Info"
        return
    }

    $items = @($movable | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Label = (Get-PlacementLabel -Placement $_) } })
    $picked = Show-MultiSelectMenu -Title "Sort VMs" -StatusLines (Get-RootStatusLines) `
        -Question "Which VMs should be moved into place? Space toggles, Enter confirms." -Items $items
    if ($null -eq $picked -or @($picked).Count -eq 0) { return }
    $set = @{}
    foreach ($id in @($picked)) { $set[[string]$id] = $true }
    $chosen = @($movable | Where-Object { $set.ContainsKey([string]$_.Id) })

    Write-PlacementReport -Placements $chosen
    $running = @($chosen | Where-Object { $_.State -eq "Running" }).Count
    $shutDown = $true
    if ($running -gt 0) {
        $how = Show-Menu -Title "Sort VMs" -StatusLines (Get-RootStatusLines) `
            -Question "$running of the $($chosen.Count) VM(s) are running. How should they be moved?" -Items @(
                [pscustomobject]@{ Id = "shutdown"; Label = "Shut down first   graceful shutdown, move cold, start again (recommended)" }
                [pscustomobject]@{ Id = "live";     Label = "Move live         keep them running (Hyper-V live storage migration)" }
                [pscustomobject]@{ Id = "back";     Label = "Back" }
            )
        if ($null -eq $how -or $how -eq "back") { return }
        $shutDown = ($how -eq "shutdown")
    }
    $answer = Show-YesNoMenu -Title "Move $($chosen.Count) VM(s) now?" -DefaultId "yes" -StatusLines (Get-RootStatusLines)
    if ($answer -ne "yes") { return }
    [void](Start-PlacementMoves -Placements $chosen -ShutDownFirst $shutDown)
}

function Start-InteractiveMenu {
    while ($true) {
        $main = Show-Menu -Title "Repair VM placement" -StatusLines (Get-RootStatusLines) -Question "What should be done?" -Items @(
            [pscustomobject]@{ Id = "check"; Label = "Check   list every VM and what is out of place" }
            [pscustomobject]@{ Id = "sort";  Label = "Sort    pick misplaced VMs and move them into place" }
            [pscustomobject]@{ Id = "quit";  Label = "Quit" }
        )
        if ($null -eq $main -or $main -eq "quit") { Complete-Script -ExitCode 0 }
        if ($main -eq "check") { Write-PlacementReport -Placements @(Get-AllPlacements -Roots $script:roots) }
        elseif ($main -eq "sort") { Invoke-SortWizard }
    }
}

# ---------------------------[ Main ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "$env:COMPUTERNAME | $env:USERNAME | $applicationName" -Tag "Info"

try {
    if (-not (Test-IsAdministrator)) {
        throw "Please run Repair-VmPlacement.ps1 elevated (Administrator)."
    }
    Confirm-HyperVAvailable

    $script:roots = Get-PlacementRoots
    Write-Log "VM path: $($script:roots.VmRoot)" -Tag "Info"
    Write-Log "VHD path: $($script:roots.VhdRoot)" -Tag "Info"

    $nameFilter = @($VmName | ForEach-Object { ([string]$_ -split ",") } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($ListOnly.IsPresent) {
        Write-PlacementReport -Placements @(Get-AllPlacements -Roots $script:roots)
        Complete-Script -ExitCode 0
    }

    if (-not $All.IsPresent -and $nameFilter.Count -eq 0) {
        Start-InteractiveMenu
        Complete-Script -ExitCode 0
    }

    $placements = @(Get-AllPlacements -Roots $script:roots)
    $selected = @($placements | Where-Object Status -eq "misplaced")
    if ($nameFilter.Count -gt 0) {
        foreach ($n in $nameFilter) {
            if (-not ($placements.Name -contains $n)) { Write-Log "VM '$n' not found on this host" -Tag "Error" }
            elseif (($placements | Where-Object Name -eq $n).Status -eq "ok") { Write-Log "VM '$n' is already in place" -Tag "Info" }
            elseif (($placements | Where-Object Name -eq $n).Status -eq "blocked") { Write-Log "VM '$n' cannot be moved - see -ListOnly" -Tag "Error" }
        }
        $selected = @($selected | Where-Object { $nameFilter -contains $_.Name })
    }
    if ($selected.Count -eq 0) {
        Write-Log "Nothing to sort" -Tag "Info"
        Complete-Script -ExitCode 0
    }

    Write-PlacementReport -Placements $selected
    if (-not $Force.IsPresent) {
        Write-Log "Refusing to move without -Force in non-interactive mode. Re-run with -Force, or start the script without parameters for the menu." -Tag "Error"
        Complete-Script -ExitCode 1
    }

    $ok = Start-PlacementMoves -Placements $selected -ShutDownFirst (-not $Live.IsPresent)
    Complete-Script -ExitCode $(if ($ok) { 0 } else { 1 })
}
catch {
    Write-Log $_.Exception.Message -Tag "Error"
    Complete-Script -ExitCode 1
}
