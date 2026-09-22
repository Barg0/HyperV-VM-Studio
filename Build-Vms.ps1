<#
.SYNOPSIS
    Creates Hyper-V Gen2 VMs from golden hv-*.vhdx images using config.json.

.DESCRIPTION
    Reads config.json (designed in html\hyperv-vm-studio.html), resolves gold
    images from vhdx\ by imageId (New-Vhdx naming) or optional imageHint, creates
    OS disks (full copy by default, or differencing), optional data disks and
    VHD Sets, injects offline unattend.xml, optionally installs Windows roles /
    RSAT offline (and, opt-in per VM on Windows 11 client images, removes a
    fixed list of built-in provisioned apps offline - see Remove-OfflineProvisionedApps),
    injects GuestProvision guest payload (Arc / leftover features), optionally
    registers VMs with a failover cluster, then starts them.

    Naming (defaults.naming in config.json), both toggles off by default:
      vmNameIncludeFqdn - Hyper-V object name is computerName.domain
      folderIncludeFqdn - VM/VHD leaf folder is computerName.domain (needs the above)
      fqdn              - optional fixed suffix used for every VM, joined or not;
                          without it the suffix comes from each VM's domain join, so a
                          VM that builds its own domain would stay on the short name
    The guest's own NetBIOS ComputerName is always the short name. See
    Get-ServerNamingSuffix / Get-HyperVVmName / Get-ServerFolderName.

    Local accounts:
      servers[].builtInAdminOnly - provision no <LocalAccounts>, leaving
      Built-in\Administrator as the only account. Always on for AD-Domain-Services
      VMs (dcpromo destroys the local SAM). See Test-BuiltInAdminOnly.

    Features on Demand (Server Core App Compatibility, Windows 11 RSAT):
      When the config asks for either, an interactive run offers to browse for the
      matching Languages and Optional Features ISO, mounts it, and installs offline
      against the mounted VHD. Otherwise - and always for unattended runs - the
      capabilities are queued for the guest's own online install at first boot.
      See Resolve-FodPlans.

    Modes:
      Interactive console menu (default) - same look as New-Vhdx.ps1:
        Build all VMs / Build selected VMs
      -CheckOnly     Preflight: gold images, switches, paths, name conflicts
                     (quiet - one summary line plus every warning/error; -Verbose
                     prints the individual passing checks)
      -BuildAll      Provision every server in config
      -VmName        Provision one or more named servers from config
      -SlowHost      Prep ALL OS/data disks first, then create VMs, then start
                     (avoids gold copies fighting VM boot I/O on slow storage)
      -ArcServicePrincipalPath / -ArcServicePrincipalSecret
        Optional overrides. Prefer filling App ID + secret on each Azure Arc
        principal in the HTML (exported into config.json azureArcPrincipals).

.NOTES
    Target shell : Windows PowerShell 5.1 and PowerShell 7
    Requires     : Administrator, Hyper-V role
#>

[CmdletBinding()]
param (
    [Parameter(HelpMessage = "Path to config.json. Defaults to config.json next to this script.")]
    [string]$ConfigPath,

    [Parameter(HelpMessage = "Create VMs and inject unattend but do not start them.")]
    [switch]$SkipStart,

    [Parameter(HelpMessage = "Validate prerequisites only; do not create VMs.")]
    [switch]$CheckOnly,

    [Parameter(HelpMessage = "Build every server in config.json (skip interactive menu).")]
    [switch]$BuildAll,

    [Parameter(HelpMessage = "Build only these computer names (from config servers[].name).")]
    [string[]]$VmName,

    [Parameter(HelpMessage = "Slow host: copy/create all VHDX first, then create VMs, then start. Better on busy or slow disks.")]
    [switch]$SlowHost,

    [Parameter(HelpMessage = "Path to JSON with servicePrincipalAppId + servicePrincipalSecret for Arc SP auth.")]
    [string]$ArcServicePrincipalPath,

    [Parameter(HelpMessage = "Service principal secret for Arc SP auth (prefer -ArcServicePrincipalPath).")]
    [string]$ArcServicePrincipalSecret,

    [Parameter(HelpMessage = "Gold image language to use when more than one is on disk, as it appears in the file name (e.g. enus, dede).")]
    [string]$GoldLanguage
)

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "Build-Vms"
$logFileName = (Get-Date -Format "yyyyMMdd-HHmm") + ".log"

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

$logFileDirectory = Join-Path -Path $PSScriptRoot -ChildPath "logs\build-vms"
$logFile          = Join-Path -Path $logFileDirectory -ChildPath $logFileName

# ---------------------------[ Gold Image Language ]---------------------------
# Which language wins when a gold exists in more than one. The parameter is the
# operator's up-front answer; ForRun is the same answer given mid-run through the
# picker, which is why it is separate - one is an instruction, the other a choice
# made once and then honoured for the rest of the run.
$script:GoldLanguageParameter = (($GoldLanguage -replace "[^A-Za-z0-9]", "")).ToLowerInvariant()
$script:GoldLanguageForRun    = ""
# VM name -> language, answered once up front for every image that has more than one
# language on disk. Preflight resolves the same golds the build does, so the question has
# to be settled before it runs - otherwise the ambiguity reads as a failure and the build
# never reaches the point where it could ask.
$script:GoldLanguageByServer  = @{}

# ---------------------------[ Naming Options ]---------------------------
# Overwritten from config defaults.naming by Set-NamingOptionsFromDefaults.
$script:NamingVmIncludeFqdn     = $false
$script:NamingFolderIncludeFqdn = $false
$script:NamingFqdnOverride      = ""

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
# The logo is deliberately NOT part of this: the server logo keeps its own base64
# ANSI art and the colours baked into it.

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
        D:\Tools\HyperV-Scripts\vhdx\hv-enus-ubuntu2604.vhdx reads as
        vhdx\hv-enus-ubuntu2604.vhdx. Anything else keeps its root and its last two
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

    # Palette keys, not ConsoleColor names - see Write-Studio above. The pairing this
    # has to preserve is info BELOW warn: info is the commonest tag in any run, warn is
    # the one that wants to be noticed, and the two sit next to each other on screen.
    # Kaido's own two warm colours are one step apart and read as orange-on-orange, so
    # the palette carries a third - `yellow`, the only value in it that is not the
    # studio's. info takes it and warn keeps Kaido's gold.
    $color = switch ($shown) {
        "start" { "accent" }
        "get"   { "bandHost" }
        "run"   { "bandIdent" }
        "info"  { "yellow" }
        "warn"  { "warn" }
        "o.k."  { "success" }
        "error" { "danger" }
        "debug" { "muted" }
        "end"   { "accent" }
        default { "fg" }
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

    # The clock and the brackets are furniture, not content: they take `muted` so the
    # tag and the message are what the eye lands on.
    # One space in front, so the timestamp does not sit flush against the window
    # border. Console only: the log FILE has no border to clear and its lines stay
    # unindented, which keeps them greppable from column one.
    Write-Studio -Text " $clock " -Key "muted" -NoNewline
    Write-Studio -Text "[ " -Key "muted" -NoNewline
    Write-Studio -Text "$rawTag" -Key $color -NoNewline
    Write-Studio -Text " ] " -Key "muted" -NoNewline
    Write-Studio -Text $shownMessage -Key "fg"
}

# ISOs this run mounted itself (Features on Demand media picked interactively).
$script:mountedIsoPaths = @()

function Complete-Script {
    param([int]$ExitCode)

    if (Get-Command -Name "Dismount-TrackedIsos" -ErrorAction SilentlyContinue) {
        Dismount-TrackedIsos
    }

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

function Convert-ToPlainText {
    param($Value)

    if ($null -eq $Value) { return "" }
    if ($Value -is [securestring]) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    return [string]$Value
}

function Convert-ToBase64Unicode {
    param(
        [string]$PlainText,
        [string]$ElementName = "AdministratorPassword"
    )

    # Windows Setup expects base64(UTF-16LE(password + parent element name)):
    # "AdministratorPassword" for UserAccounts\AdministratorPassword,
    # "Password" for LocalAccounts\LocalAccount\Password.
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($PlainText + $ElementName)
    return [Convert]::ToBase64String($bytes)
}

function Get-ConfigObject {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return ($raw | ConvertFrom-Json)
}

function Get-BuildConfigCandidates {
    <#
        Every config this run could be built from: config.json beside the script, plus
        whatever is in configs\.

        Each one is opened and looked at rather than trusted by extension - a file that
        does not parse, or that carries no servers, is still RETURNED but marked
        invalid with the reason. A config somebody meant to use and mistyped is more
        useful on screen, greyed out and explained, than silently absent from a list
        they are staring at.
    #>
    param([string]$ScriptRoot)

    $found = New-Object System.Collections.Generic.List[object]
    $paths = New-Object System.Collections.Generic.List[string]

    $beside = Join-Path -Path $ScriptRoot -ChildPath "config.json"
    if (Test-Path -LiteralPath $beside) { $paths.Add($beside) | Out-Null }

    $folder = Join-Path -Path $ScriptRoot -ChildPath "configs"
    if (Test-Path -LiteralPath $folder) {
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            # A config.json symlinked or copied into configs\ as well should not be
            # offered twice.
            if ($paths -contains $file.FullName) { continue }
            $paths.Add($file.FullName) | Out-Null
        }
    }

    foreach ($path in $paths) {
        $entry = [pscustomobject]@{
            Path    = $path
            Name    = (Split-Path -Leaf $path)
            InRoot  = ($path -eq $beside)
            Valid   = $false
            Reason  = ""
            Servers = 0
            Linux   = 0
            Windows = 0
        }

        try {
            $doc = Get-ConfigObject -Path $path
            $servers = @($doc.servers)
            if ($servers.Count -eq 0) {
                $entry.Reason = "no servers"
            }
            else {
                $entry.Valid = $true
                $entry.Servers = $servers.Count
                foreach ($server in $servers) {
                    if (Test-IsLinuxServer -Server $server) { $entry.Linux++ } else { $entry.Windows++ }
                }
            }
        }
        catch {
            # The parser's own words, trimmed to something that fits a menu row.
            $reason = ($_.Exception.Message -replace "\s+", " ").Trim()
            if ($reason.Length -gt 48) { $reason = $reason.Substring(0, 45) + "..." }
            $entry.Reason = $reason
        }

        $found.Add($entry) | Out-Null
    }

    return $found.ToArray()
}

function Get-BuildConfigSources {
    <#
        Every valid config, loaded, with each of its servers tagged with the source it
        came from.

        Not merged. Two configs can disagree about the gold folder, where VMs live, how
        machines are named, which domain join accounts exist - and the right answer to
        all of that is "whatever the config that server came from says". So the servers
        are pooled for the MENU, and the build regroups them by source and gives each
        group its own defaults back. Merging would have to pick a winner for every one
        of those, and any winner is wrong for half the machines.

        The tag is a note property on the server object rather than a parallel lookup,
        because the server object is what every function downstream already receives.
    #>
    param([string]$ScriptRoot)

    $sources = New-Object System.Collections.Generic.List[object]

    foreach ($entry in @(Get-BuildConfigCandidates -ScriptRoot $ScriptRoot)) {
        if (-not $entry.Valid) {
            Write-Log "Ignoring '$($entry.Name)' - $($entry.Reason)" -Tag "Warn"
            continue
        }

        $config = Get-ConfigObject -Path $entry.Path
        if (-not $config.defaults) {
            Write-Log "Ignoring '$($entry.Name)' - no defaults section" -Tag "Warn"
            continue
        }

        $source = [pscustomobject]@{
            Path     = $entry.Path
            Name     = $entry.Name
            Config   = $config
            Defaults = $config.defaults
            Servers  = @($config.servers)
        }

        foreach ($server in $source.Servers) {
            # Added, never replaced: re-running discovery on the same objects must not
            # throw on the second pass.
            if ($server.PSObject.Properties.Match("_source").Count -eq 0) {
                $server | Add-Member -NotePropertyName "_source" -NotePropertyValue $source
            }
            else {
                $server._source = $source
            }
        }

        $sources.Add($source) | Out-Null
    }

    return $sources.ToArray()
}

function Test-BuildConfigSourcesUnique {
    <#
        Refuses the run when two configs name the same machine.

        Hyper-V would refuse the second one anyway - but late, after its gold has been
        copied, which on a 32 GB fixed disk is minutes of work and a half-built lab to
        clean up. Better to say it before anything is written, and to name BOTH files
        so it is obvious which pair to fix.
    #>
    param([object[]]$Sources)

    $seen = @{}
    $clashes = New-Object System.Collections.Generic.List[string]

    foreach ($source in $Sources) {
        foreach ($server in @($source.Servers)) {
            $name = ([string](Get-HyperVVmName -Server $server)).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($seen.ContainsKey($name)) {
                $clashes.Add(("'{0}' is in both {1} and {2}" -f $name, $seen[$name], $source.Name)) | Out-Null
            }
            else {
                $seen[$name] = $source.Name
            }
        }
    }

    if ($clashes.Count -eq 0) { return $true }

    Write-Log "The same VM name appears in more than one config:" -Tag "Error"
    foreach ($clash in $clashes) { Write-Log "  $clash" -Tag "Error" }
    Write-Log "Rename one of them, or pass -ConfigPath to build from a single config" -Tag "Error"
    return $false
}

function Set-ActiveConfigSource {
    <#
        Makes one config the current one: the catalogue root every lookup resolves
        against (domain join accounts, Arc principals, VHD Sets) and the naming rules.

        Called once per source group at build time, so a run that spans two configs
        gives each group the settings its own file asked for.
    #>
    param([object]$Source)

    $script:ConfigRoot = $Source.Config
    Set-NamingOptionsFromDefaults -Defaults $Source.Defaults
}

function Resolve-ConfiguredHostPath {
    param(
        [string]$ConfiguredPath,
        [Parameter(Mandatory)]
        [string]$PromptLabel,
        [string]$ExampleHint = "",
        [string]$DefaultWhenEmpty = ""
    )

    $path = $ConfiguredPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        if (-not [string]::IsNullOrWhiteSpace($DefaultWhenEmpty)) {
            $path = $DefaultWhenEmpty
        }
        else {
            $hint = ""
            if (-not [string]::IsNullOrWhiteSpace($ExampleHint)) {
                $hint = " (e.g. $ExampleHint)"
            }
            Write-Host ""
            Write-Studio -Text "$PromptLabel$hint" -Key "accent"
            $path = Read-Host "Path"
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw "$PromptLabel was left blank"
            }
        }
    }

    $path = $path.Trim().Trim('"')
    if ([System.IO.Path]::IsPathRooted($path)) {
        return $path
    }

    return (Join-Path -Path $PSScriptRoot -ChildPath $path.TrimStart('.', '\', '/'))
}

function Resolve-ServerPathRoot {
    <#
    .SYNOPSIS
        Per-VM vmPath / vhdPath override.
    .DESCRIPTION
        A server entry may carry its own vmPath / vhdPath. Blank or missing falls back to
        the already-resolved default. Relative overrides resolve against the script folder,
        exactly like Resolve-ConfiguredHostPath does for the defaults.
    #>
    param(
        [object]$Server,
        [Parameter(Mandatory)]
        [string]$Property,
        [string]$Fallback = ""
    )

    $raw = ""
    if ($null -ne $Server -and $null -ne $Server.PSObject.Properties[$Property]) {
        $raw = [string]$Server.$Property
    }
    $raw = $raw.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Fallback
    }
    if ([System.IO.Path]::IsPathRooted($raw)) {
        return $raw
    }
    return (Join-Path -Path $PSScriptRoot -ChildPath $raw.TrimStart('.', '\', '/'))
}

function Get-StoragePlacementVolumes {
    <#
    .SYNOPSIS
        Automatic storage placement volume catalog (Azure Local style).
    .DESCRIPTION
        config.json defaults.storagePlacement = { mode: "auto", volumes: [ { vmPath, vhdPath } ] }
        turns on per-VM automatic placement: each VM lands on the volume with the most
        usable space at its turn (see Select-StoragePlacementVolume). Returns the resolved
        volume list, or an empty array when auto mode is off / has no usable volumes.
        A volume's blank vhdPath falls back to its vmPath, mirroring the global fields.
    #>
    param([object]$Defaults)

    $placement = $null
    if ($Defaults) { $placement = $Defaults.storagePlacement }
    if ($null -eq $placement -or ([string]$placement.mode) -ne "auto") {
        return @()
    }

    $volumes = New-Object System.Collections.ArrayList
    $index = 0
    foreach ($volume in @($placement.volumes)) {
        if ($null -eq $volume) { continue }
        $vmRoot = ([string]$volume.vmPath).Trim().Trim('"')
        $vhdRoot = ([string]$volume.vhdPath).Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($vmRoot) -and [string]::IsNullOrWhiteSpace($vhdRoot)) { continue }
        if ([string]::IsNullOrWhiteSpace($vmRoot)) { $vmRoot = $vhdRoot }
        if ([string]::IsNullOrWhiteSpace($vhdRoot)) { $vhdRoot = $vmRoot }
        if (-not [System.IO.Path]::IsPathRooted($vmRoot)) {
            $vmRoot = Join-Path -Path $PSScriptRoot -ChildPath $vmRoot.TrimStart('.', '\', '/')
        }
        if (-not [System.IO.Path]::IsPathRooted($vhdRoot)) {
            $vhdRoot = Join-Path -Path $PSScriptRoot -ChildPath $vhdRoot.TrimStart('.', '\', '/')
        }
        $volumes.Add([pscustomobject]@{
            Index   = $index
            VmPath  = $vmRoot
            VhdPath = $vhdRoot
        }) | Out-Null
        $index++
    }
    return @($volumes)
}

function Get-PathVolumeFreeBytes {
    # Free bytes of the volume holding $Path. Get-Volume -FilePath resolves CSVFS
    # mount points (C:\ClusterStorage\VolumeX) as well as plain local folders, so no
    # FailoverClusters module is needed. The path may not exist yet - walk up to the
    # nearest existing ancestor first. Returns $null when the volume cannot be read.
    param([string]$Path)

    $probe = $Path
    while (-not [string]::IsNullOrWhiteSpace($probe) -and -not (Test-Path -LiteralPath $probe)) {
        $parent = [System.IO.Path]::GetDirectoryName($probe)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { return $null }
        $probe = $parent
    }
    if ([string]::IsNullOrWhiteSpace($probe)) { return $null }

    try {
        $volume = Get-Volume -FilePath $probe -ErrorAction Stop
        return [int64]$volume.SizeRemaining
    }
    catch {
        return $null
    }
}

function Get-ServerPlannedStorageBytes {
    # Worst-case footprint a VM adds to its volume: the gold size (a copied OS disk
    # is that big immediately, a differencing child can grow to it) plus every data
    # disk at full configured size (dynamic disks also grow there eventually).
    param(
        [object]$Server,
        [string]$GoldPath
    )

    $bytes = [int64]0
    try {
        $bytes += (Get-Item -LiteralPath $GoldPath -ErrorAction Stop).Length
    }
    catch {
        $bytes += 64GB
    }
    foreach ($disk in @($Server.additionalDisks)) {
        if ($null -eq $disk) { continue }
        $sizeGb = 0
        if ($null -ne $disk.sizeGB -and [string]$disk.sizeGB -ne "") { $sizeGb = [int]$disk.sizeGB }
        if ($sizeGb -gt 0) { $bytes += [int64]$sizeGb * 1GB }
    }
    return $bytes
}

function Select-StoragePlacementVolume {
    <#
    .SYNOPSIS
        Pick the placement volume for one VM.
    .DESCRIPTION
        Score = live free space minus what this run has already planned onto the
        volume. The planned counter matters because differencing children consume
        almost nothing at creation time - raw free space alone would put every VM
        of a sequential run onto the same volume. Ties fall to the volume least
        recently picked (round robin). State is script-scoped per run.
    #>
    param(
        [object[]]$Volumes,
        [object]$Server,
        [string]$GoldPath,
        [string]$Label
    )

    if ($null -eq $script:PlacementPlannedBytes) {
        $script:PlacementPlannedBytes = @{}
        $script:PlacementLastPick = -1
    }

    $best = $null
    $bestScore = [int64]::MinValue
    foreach ($volume in $Volumes) {
        $free = Get-PathVolumeFreeBytes -Path $volume.VhdPath
        if ($null -eq $free) {
            Write-Log "Placement: volume '$($volume.VhdPath)' is unreadable - skipped" -Tag "Warn"
            continue
        }
        $planned = [int64]0
        if ($script:PlacementPlannedBytes.ContainsKey($volume.Index)) {
            $planned = $script:PlacementPlannedBytes[$volume.Index]
        }
        $score = $free - $planned
        $isBetter = $score -gt $bestScore
        if (-not $isBetter -and $score -eq $bestScore -and $null -ne $best -and $best.Volume.Index -eq $script:PlacementLastPick) {
            $isBetter = $true
        }
        if ($isBetter) {
            $best = [pscustomobject]@{ Volume = $volume; Free = $free; Planned = $planned }
            $bestScore = $score
        }
    }

    if ($null -eq $best) {
        throw "Automatic storage placement: no usable volume (all storagePlacement.volumes unreadable)"
    }

    $vmBytes = Get-ServerPlannedStorageBytes -Server $Server -GoldPath $GoldPath
    $script:PlacementPlannedBytes[$best.Volume.Index] = $best.Planned + $vmBytes
    $script:PlacementLastPick = $best.Volume.Index

    $freeGb = [math]::Round($best.Free / 1GB)
    $plannedGb = [math]::Round(($best.Planned + $vmBytes) / 1GB)
    Write-Log "Placement $Label -> '$($best.Volume.VhdPath)' ($freeGb GB free)" -Tag "Info"
    return $best.Volume
}

function Get-HyperVGoldImages {
    param([string]$VhdxDirectory)

    if (-not (Test-Path -LiteralPath $VhdxDirectory)) {
        throw "VHDX directory not found: $VhdxDirectory"
    }

    return @(Get-ChildItem -LiteralPath $VhdxDirectory -Filter "hv-*.vhdx" -File -ErrorAction Stop)
}

function Get-ImageIdMatchRules {
    # Mirrors the studio's IMAGE_CATALOG and the imageIds New-Vhdx.ps1 bakes into gold
    # file names (<hv|azl>-<language>-<imageId>.vhdx). The id in the file name IS the id
    # in config.json, so resolving a gold is an exact comparison - no guessing from what
    # a name happens to contain, and no edition that can collide with another.
    $server = [ordered]@{}
    foreach ($year in 2016, 2019, 2022, 2025) {
        foreach ($sku in "datacenter", "standard") {
            $skuLabel = (Get-Culture).TextInfo.ToTitleCase($sku)
            $server["ws$year-$sku-desktop"] = @{
                Experience = "DesktopExperience"
                Label      = "Windows Server $year $skuLabel Desktop Experience"
            }
            $server["ws$year-$sku-core"] = @{
                Experience = "Core"
                Label      = "Windows Server $year $skuLabel Core"
            }
        }
    }

    # Its own SKU next to Standard and Datacenter, built by New-Vhdx.ps1 as a
    # post-generalize edition upgrade from a 2025 Datacenter index. Server 2025 only:
    # older media has no conversion path to it.
    $server["ws2025-datacenter-az-desktop"] = @{
        Experience = "DesktopExperience"
        Label      = "Windows Server 2025 Datacenter: Azure Edition Desktop Experience"
    }
    $server["ws2025-datacenter-az-core"] = @{
        Experience = "Core"
        Label      = "Windows Server 2025 Datacenter: Azure Edition Core"
    }

    $client = [ordered]@{
        "w11-enterprise"    = @{ Experience = "DesktopExperience"; Label = "Windows 11 Enterprise" }
        "w11-enterprise-n"  = @{ Experience = "DesktopExperience"; Label = "Windows 11 Enterprise N" }
        # Its own SKU, not an edition of Enterprise: same WIM name prefix, different
        # licensing and a different id, so the two golds never share a file name.
        "w11-enterprise-ms" = @{ Experience = "DesktopExperience"; Label = "Windows 11 Enterprise multi-session" }
        "w11-pro"           = @{ Experience = "DesktopExperience"; Label = "Windows 11 Pro" }
        "w11-pro-n"         = @{ Experience = "DesktopExperience"; Label = "Windows 11 Pro N" }
        # Azure Local: the media still names its image "Azure Stack HCI". Core-based, so
        # it takes the Core experience like a Core server. The id repeats the "azl" that
        # can also appear as a prefix - there it names the target, here the image, and a
        # gold can carry both: azl-enus-azl.vhdx is Azure Local built for Azure Local.
        "azl"               = @{ Experience = "Core"; Label = "Azure Local" }
    }

    $rules = [ordered]@{}
    foreach ($key in $server.Keys) { $rules[$key] = $server[$key] }
    foreach ($key in $client.Keys) { $rules[$key] = $client[$key] }
    return $rules
}

function Get-ImageDisplayName {
    <#
      Friendly OS name for a server entry ("Windows Server 2025 Datacenter Core").
      Falls back to the raw imageId / imageHint for custom image selections.
    #>
    param([object]$Server)

    $imageId = ([string]$Server.imageId).Trim()
    $imageHint = ([string]$Server.imageHint).Trim()
    $label = ""

    if (-not [string]::IsNullOrWhiteSpace($imageId)) {
        $rules = Get-ImageIdMatchRules
        $key = $imageId.ToLowerInvariant()
        if ($rules.Contains($key)) {
            $label = [string]$rules[$key].Label
        }
    }

    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = if (-not [string]::IsNullOrWhiteSpace($imageId)) { $imageId } else { "custom image" }
        $experience = ([string]$Server.experience).Trim()
        if (-not [string]::IsNullOrWhiteSpace($experience)) {
            $label = "{0} ({1})" -f $label, $experience
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($imageHint)) {
        $label = "{0} - matches '{1}'" -f $label, $imageHint
    }

    return $label
}

function Get-GoldNameParts {
    # <hv|azl>-<language>-<imageId>.vhdx -> the language and imageId it carries.
    # Anything that does not have all three segments is reported as unparseable rather
    # than half-read: a gold nobody can identify should say so, not match by accident.
    param([string]$BaseName)

    $base = ([string]$BaseName).ToLowerInvariant()
    if ($base -notmatch "^(hv|azl)-([a-z0-9]+)-(.+)$") {
        return $null
    }
    return [pscustomobject]@{
        Prefix   = $Matches[1]
        Language = $Matches[2]
        ImageId  = $Matches[3]
    }
}

function Get-LinuxGoldIds {
    # The imageIds the studio emits for Linux, which are also the LAST segment of the
    # gold's file name - hv-enus-ubuntu2604. Keep in step with Get-LinuxImageCatalog in
    # New-Vhdx.ps1. Their only job here is to let a Linux id past the Windows rules
    # table; everything after that is the ordinary three-segment lookup.
    return @("ubuntu2604", "ubuntu2404", "debian13")
}

function Test-IsLinuxImageId {
    param([string]$ImageId)

    $key = ([string]$ImageId).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($key)) { return $false }
    return @(Get-LinuxGoldIds) -contains $key
}

function Get-ConfiguredLanguageSlug {
    # defaults.locale as it appears in a gold file name: "de-DE" -> "dede". Empty when
    # the config says "default", which means the gold decides the locale - so it cannot
    # be the thing that picks the gold.
    param([object]$Defaults)

    $locale = ""
    if ($Defaults) { $locale = [string]$Defaults.locale }
    if ([string]::IsNullOrWhiteSpace($locale) -or $locale -ieq "default") {
        return ""
    }
    return (($locale -replace "[^A-Za-z0-9]", "")).ToLowerInvariant()
}

function Get-LanguageTagFromSlug {
    # "dede" -> "de-DE". The slug in a gold's file name is the locale with its hyphen
    # flattened out, so putting it back is the whole job: two letters, a hyphen, two
    # letters upper-cased. Anything that is not four characters is handed back as-is
    # rather than guessed at.
    param([string]$Slug)

    $slug = ([string]$Slug).Trim().ToLowerInvariant()
    if ($slug.Length -ne 4) { return $slug }
    return "{0}-{1}" -f $slug.Substring(0, 2), $slug.Substring(2, 2).ToUpperInvariant()
}

function Show-GoldLanguageForm {
    # One card for the whole question. The rows at the top answer it for every VM at
    # once, which is what a single-language lab wants; the rows below answer it per VM
    # with left/right, for the lab that mixes.
    #
    # Every VM that resolves a gold by imageId is listed, including the ones with nothing
    # to decide: a VM whose image exists in only one language is shown locked, so the
    # list reads as the whole build rather than the subset that happens to be ambiguous.
    # The cursor skips those - there is nothing there to change.
    #
    # Returns a map of VM name -> language slug, or $null if the operator backed out.
    param(
        [object[]]$Rows,
        [string[]]$CommonLanguages,
        [System.Collections.IDictionary]$StatusLines
    )

    $allRows = @($CommonLanguages)

    # Index space: the "every VM" rows, then one per VM, then Continue. Locked VM rows
    # keep their index so the arithmetic stays readable - they are simply never landed on.
    $continueIndex = $allRows.Count + $Rows.Count
    $selectable = @(0..($allRows.Count - 1) | Where-Object { $allRows.Count -gt 0 })
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        if (@($Rows[$i].Languages).Count -gt 1) { $selectable += ($allRows.Count + $i) }
    }
    $selectable += $continueIndex
    $selectable = @($selectable | Sort-Object)
    $index = $selectable[0]

    if (-not (Test-MenuHostSupported)) {
        # No cursor keys to drive the form. Ask once, in text, and apply it everywhere.
        foreach ($language in $allRows) {
            Write-Host ("  {0}  ({1})" -f (Get-LanguageTagFromSlug -Slug $language), $language)
        }
        $raw = Read-Host "Gold language for every VM (tag or slug, empty cancels)"
        $picked = (($raw -replace "[^A-Za-z0-9]", "")).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($picked)) { return $null }
        $map = @{}
        foreach ($row in $Rows) {
            $map[$row.Key] = if ($row.Languages -contains $picked) { $picked } else { [string]$row.Language }
        }
        return $map
    }

    # Header once, list on every keypress - see the repaint helpers.
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
            Show-MenuHeader -Title "Choose the gold image language" -StatusLines $StatusLines `
                -Subtitle "More than one language is on disk for these images"
            $anchor = Get-MenuCursorAnchor
        }

        $cursor = 0

        if ($allRows.Count -gt 0) {
            Write-Studio -Text "  Every VM" -Key "fg"
            Write-Host ""
            foreach ($language in $allRows) {
                $label = "Build all VMs with {0}" -f (Get-LanguageTagFromSlug -Slug $language)
                if ($cursor -eq $index) {
                    Write-Studio -Text "    > " -Key "accent" -NoNewline
                    Write-Studio -Text $label -Key "fg"
                }
                else {
                    Write-Host "      " -NoNewline
                    Write-Studio -Text $label -Key "muted"
                }
                $cursor++
            }
            Write-Host ""
        }

        Write-Studio -Text "  Pick per VM" -Key "fg"
        Write-Host ""
        $nameWidth = 1
        foreach ($row in $Rows) {
            $len = ([string]$row.Name).Length
            if ($len -gt $nameWidth) { $nameWidth = $len }
        }
        foreach ($row in $Rows) {
            $tag = Get-LanguageTagFromSlug -Slug $row.Language
            $locked = (@($row.Languages).Count -le 1)
            $arrows = if ($locked) { @(" ", " ") } else { @("<", ">") }
            # Palette keys, not ConsoleColor names. "DarkGray" and "Gray" are not in
            # the table, so Write-Studio fell back to `fg` for both and a locked row -
            # one with a single gold on disk, which the arrows cannot move - was drawn
            # exactly as brightly as a row you can actually change.
            $rowColor = if ($locked) { "muted" } else { "fg" }

            # The arrows are a control, like the cursor, so they carry the cursor's colour
            # rather than the row's - the language between them is the value.
            if ($cursor -eq $index) {
                Write-Studio -Text "    > " -Key "accent" -NoNewline
                # The row under the cursor is already marked by the accent caret, so
                # the tag only needs full foreground - and a locked row stays muted
                # even under the cursor, because it still cannot be changed.
                $tagColor = if ($locked) { "muted" } else { "fg" }
            }
            else {
                Write-Host "      " -NoNewline
                $tagColor = $rowColor
            }
            Write-Studio -Text $arrows[0] -Key "accent" -NoNewline
            Write-Studio -Text (" {0,-5} " -f $tag) -Key $tagColor -NoNewline
            Write-Studio -Text $arrows[1] -Key "accent" -NoNewline
            Write-Studio -Text ("   {0}" -f ([string]$row.Name).PadRight($nameWidth)) -Key $rowColor -NoNewline
            Write-Studio -Text ("   {0}" -f [string]$row.ImageId) -Key "muted" -NoNewline
            if ($locked) {
                Write-Studio -Text "   only gold on disk" -Key "muted"
            }
            else {
                Write-Host ""
            }
            $cursor++
        }

        Write-Host ""
        if ($cursor -eq $index) {
            Write-Studio -Text "    > " -Key "accent" -NoNewline
            Write-Studio -Text "Continue" -Key "fg"
        }
        else {
            Write-Host "      " -NoNewline
            Write-Studio -Text "Continue" -Key "muted"
        }

        # What the highlighted row would actually do. On an "every VM" row that is worth
        # spelling out: it does not reach a VM whose image has no gold in that language,
        # and those keep the one they have.
        Write-Host ""
        if ($index -lt $allRows.Count) {
            $language = [string]$allRows[$index]
            $tag = Get-LanguageTagFromSlug -Slug $language
            $covered = @($Rows | Where-Object { $_.Languages -contains $language })
            $kept = @($Rows | Where-Object { -not ($_.Languages -contains $language) })
            Write-Studio -Text ("  {0} applies to {1}" -f $tag, (($covered | ForEach-Object { $_.Name }) -join ", ")) -Key "muted"
            if ($kept.Count -gt 0) {
                $keptText = (($kept | ForEach-Object {
                            "{0} stays {1}" -f $_.Name, (Get-LanguageTagFromSlug -Slug $_.Language)
                        }) -join ", ")
                Write-Studio -Text ("  No {0} gold for the rest - {1}" -f $tag, $keptText) -Key "muted"
            }
        }

        Write-Host ""
        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
        Write-Studio -Text "  Up/Down move   Left/Right change language   Enter continue   Esc/Q cancel" -Key "muted"
        Write-Host ""

        # Read when the frame is COMPLETE, never half way through it. A frame taller
        # than the window scrolls as its last lines are written, so a top measured
        # before the list was drawn always disagrees with the one measured after - and
        # the guard then declared a scroll on every keypress and redrew the whole
        # screen, which is the flicker coming back on exactly the tall blades.
        $windowTop = Get-MenuWindowTop
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        $virtualKey = [int]$key.VirtualKeyCode
        $charKey = [string]$key.Character

        if ($virtualKey -eq 38 -or $virtualKey -eq 40) {
            $at = [Array]::IndexOf($selectable, $index)
            if ($at -lt 0) { $at = 0 }
            if ($virtualKey -eq 38) {
                $at = if ($at -le 0) { $selectable.Count - 1 } else { $at - 1 }
            }
            else {
                $at = if ($at -ge ($selectable.Count - 1)) { 0 } else { $at + 1 }
            }
            $index = $selectable[$at]
            continue
        }
        if ($virtualKey -eq 37 -or $virtualKey -eq 39) {
            $rowIndex = $index - $allRows.Count
            if ($rowIndex -ge 0 -and $rowIndex -lt $Rows.Count) {
                $row = $Rows[$rowIndex]
                $languages = @($row.Languages)
                if ($languages.Count -gt 1) {
                    $at = [Array]::IndexOf($languages, [string]$row.Language)
                    if ($at -lt 0) { $at = 0 }
                    if ($virtualKey -eq 37) {
                        $at = if ($at -le 0) { $languages.Count - 1 } else { $at - 1 }
                    }
                    else {
                        $at = if ($at -ge ($languages.Count - 1)) { 0 } else { $at + 1 }
                    }
                    $row.Language = $languages[$at]
                }
            }
            continue
        }
        if ($virtualKey -eq 13) {
            $map = @{}
            if ($index -lt $allRows.Count) {
                # An "every VM" row answers for all of them. A VM whose image does not
                # have that language keeps whatever its own row shows - leaving it
                # unanswered would only push the question to preflight, which is the
                # thing this form exists to prevent.
                $language = [string]$allRows[$index]
                foreach ($row in $Rows) {
                    $map[$row.Key] = if ($row.Languages -contains $language) { $language } else { [string]$row.Language }
                }
                return $map
            }
            foreach ($row in $Rows) {
                $map[$row.Key] = [string]$row.Language
            }
            return $map
        }
        if ($virtualKey -eq 27 -or $charKey -eq "q" -or $charKey -eq "Q") {
            return $null
        }
    }
}

function Show-GoldLanguagePicker {
    # Two golds of the same image in different languages is a question only the operator
    # can answer, and only at build time - the studio cannot see this host's disk. Offer
    # the choice per VM, plus "use it for the rest of this run" for the common case where
    # the whole lab is one language.
    param(
        [object[]]$Candidates,
        [string]$ImageId,
        [string]$ServerName
    )

    $items = @()
    foreach ($candidate in $Candidates) {
        $parts = Get-GoldNameParts -BaseName $candidate.BaseName
        $items += [PSCustomObject]@{
            Id    = "one:$($candidate.FullName)"
            Label = "{0}  ({1})" -f $candidate.Name, $parts.Language
        }
    }
    foreach ($candidate in $Candidates) {
        $parts = Get-GoldNameParts -BaseName $candidate.BaseName
        $items += [PSCustomObject]@{
            Id    = "all:$($parts.Language)"
            Label = "Use '{0}' for every remaining VM this run" -f $parts.Language
        }
    }

    $choice = Show-Menu -Title "Choose a gold image" `
        -Subtitle "More than one language is on disk for this image" `
        -Items $items `
        -StatusLines ([ordered]@{ vm = $ServerName; image = $ImageId })

    if ([string]::IsNullOrWhiteSpace($choice)) {
        throw "No gold image chosen for imageId='$ImageId'"
    }
    if ($choice.StartsWith("all:")) {
        $script:GoldLanguageForRun = $choice.Substring(4)
        Write-Log "Gold language '$($script:GoldLanguageForRun)' for the rest of this run" -Tag "Info"
        $picked = @($Candidates | Where-Object {
                (Get-GoldNameParts -BaseName $_.BaseName).Language -eq $script:GoldLanguageForRun
            })
        return $picked[0].FullName
    }
    return $choice.Substring(4)
}

function Resolve-GoldLanguagePlan {
    # Asked once, before preflight, for every VM whose image exists in more than one
    # language on disk. Same shape as Resolve-FodPlans: an interactive run settles it up
    # front, an unattended one stays silent and lets preflight report the ambiguity as
    # the error it is there.
    #
    # It has to happen before preflight rather than during the build, because preflight
    # resolves the same golds - left to the build, the ambiguity fails preflight and the
    # build never reaches the point where it could ask.
    param(
        [object[]]$Servers,
        [object[]]$GoldImages,
        [switch]$Interactive
    )

    if (-not $Interactive) { return }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:GoldLanguageParameter)) { return }

    $configured = Get-ConfiguredLanguageSlug -Defaults $script:ConfigRoot.defaults
    $rows = @()

    foreach ($server in $Servers) {
        $imageId = ([string]$server.imageId).ToLowerInvariant().Trim()
        $name = ([string]$server.name).Trim()
        if ([string]::IsNullOrWhiteSpace($imageId) -or [string]::IsNullOrWhiteSpace($name)) { continue }
        # A hand-picked file name answers the question by itself.
        if (-not [string]::IsNullOrWhiteSpace([string]$server.imageHint)) { continue }

        $candidates = @($GoldImages | Where-Object {
                $parts = Get-GoldNameParts -BaseName $_.BaseName
                $null -ne $parts -and $parts.ImageId -eq $imageId
            })
        # No gold at all is preflight's error to report, not a row with nothing to pick.
        if ($candidates.Count -eq 0) { continue }

        $languages = @(($candidates | ForEach-Object { (Get-GoldNameParts -BaseName $_.BaseName).Language }) | Sort-Object -Unique)

        $default = if (-not [string]::IsNullOrWhiteSpace($configured) -and $languages -contains $configured) {
            $configured
        }
        else {
            $languages[0]
        }

        # Every VM that resolves by imageId gets a row, including the ones with a single
        # gold. Those are shown locked: the list is then the whole build, and an "every
        # VM" choice can say honestly which VMs it does not reach.
        $rows += [PSCustomObject]@{
            Key       = $name.ToLowerInvariant()
            Name      = $name
            ImageId   = $imageId
            Languages = $languages
            Language  = $default
        }
    }

    # Nothing to ask unless at least one VM has a real choice that nothing has answered.
    # A config locale that lands on exactly one gold is an answer.
    $open = @($rows | Where-Object {
            @($_.Languages).Count -gt 1 -and
            -not (-not [string]::IsNullOrWhiteSpace($configured) -and
                @($_.Languages | Where-Object { $_ -eq $configured }).Count -eq 1)
        })
    if ($open.Count -eq 0) { return }

    # "Build all VMs with X" is offered for any language at least one open row can take.
    # A locked row cannot follow it, which is what the coverage line under the list says.
    $common = @((($open | ForEach-Object { $_.Languages }) | Sort-Object -Unique))

    $result = Show-GoldLanguageForm -Rows $rows -CommonLanguages $common -StatusLines ([ordered]@{
            vms       = "$($rows.Count) need a language"
            languages = ((($rows | ForEach-Object { $_.Languages }) | Sort-Object -Unique) -join ", ")
        })

    if ($null -eq $result) {
        Write-Log "No gold language chosen - preflight will report the ambiguity" -Tag "Warn"
        return
    }

    foreach ($key in @($result.Keys)) {
        $script:GoldLanguageByServer[[string]$key] = [string]$result[$key]
    }
    $summary = ($rows | Where-Object { $script:GoldLanguageByServer.ContainsKey($_.Key) } | ForEach-Object {
            "{0}={1}" -f $_.Name, (Get-LanguageTagFromSlug -Slug $script:GoldLanguageByServer[$_.Key])
        }) -join ", "
    Write-Log "Gold language chosen: $summary" -Tag "Info"
}

function Resolve-GoldVhdxPath {
    param(
        [object[]]$GoldImages,
        [string]$ImageId,
        [string]$ImageHint,
        [string]$ServerName,
        # Only the build path may ask. Preflight and the review page resolve the same way
        # but must never block on a prompt - they report the ambiguity instead.
        [switch]$AllowPrompt
    )

    if (-not $GoldImages -or $GoldImages.Count -eq 0) {
        throw "No hv-*.vhdx files found in the vhdx folder"
    }

    $candidates = @($GoldImages)
    if (-not [string]::IsNullOrWhiteSpace($ImageHint)) {
        # A hand-picked image is matched on the file name as typed, exactly as before -
        # the operator named a file, so nothing here second-guesses which one they meant.
        $hint = $ImageHint.ToLowerInvariant().Trim()
        $candidates = @($candidates | Where-Object { $_.BaseName.ToLowerInvariant().Contains($hint) })
        if ($candidates.Count -eq 0) {
            throw "No gold image matched custom imageHint='$ImageHint'"
        }
        if ($candidates.Count -gt 1) {
            $names = ($candidates | ForEach-Object { $_.Name }) -join ', '
            Write-Log "imageHint '$ImageHint' -> $($candidates[0].Name)" -Tag "Info"
        }
        return $candidates[0].FullName
    }

    if ([string]::IsNullOrWhiteSpace($ImageId)) {
        throw "Server has neither imageId nor imageHint - nothing to resolve a gold image from"
    }

    $key = $ImageId.ToLowerInvariant().Trim()

    # A Linux gold is hv-enus-ubuntu2604.vhdx - the same three segments a Windows gold
    # has, so Get-GoldNameParts reads it correctly and everything below works unchanged.
    # The only thing these ids need is a pass through the Windows rules table, which
    # only knows about Windows editions.
    if (-not (Test-IsLinuxImageId -ImageId $key)) {
        $rules = Get-ImageIdMatchRules
        if (-not $rules.Contains($key)) {
            throw "Unknown imageId '$ImageId'. Expected one of: $($rules.Keys -join ', ')"
        }
    }

    $candidates = @($GoldImages | Where-Object {
            $parts = Get-GoldNameParts -BaseName $_.BaseName
            $null -ne $parts -and $parts.ImageId -eq $key
        })
    if ($candidates.Count -eq 0) {
        throw "No gold image for imageId='$ImageId' (expected hv-<language>-$key.vhdx in the vhdx folder)"
    }
    if ($candidates.Count -eq 1) {
        return $candidates[0].FullName
    }

    # More than one language of the same image. Narrow, in order of how explicit the
    # instruction was, and only ask when nothing has already answered it.
    $serverKey = ([string]$ServerName).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($serverKey) -and $script:GoldLanguageByServer.ContainsKey($serverKey)) {
        $chosen = [string]$script:GoldLanguageByServer[$serverKey]
        $picked = @($candidates | Where-Object { (Get-GoldNameParts -BaseName $_.BaseName).Language -eq $chosen })
        if ($picked.Count -gt 0) {
            return $picked[0].FullName
        }
    }

    $forRun = [string]$script:GoldLanguageForRun
    if (-not [string]::IsNullOrWhiteSpace($forRun)) {
        $picked = @($candidates | Where-Object { (Get-GoldNameParts -BaseName $_.BaseName).Language -eq $forRun })
        if ($picked.Count -gt 0) {
            return $picked[0].FullName
        }
        throw "Gold language '$forRun' was chosen for this run but no $forRun gold exists for imageId='$ImageId'"
    }

    $requested = [string]$script:GoldLanguageParameter
    if (-not [string]::IsNullOrWhiteSpace($requested)) {
        $picked = @($candidates | Where-Object { (Get-GoldNameParts -BaseName $_.BaseName).Language -eq $requested })
        if ($picked.Count -eq 0) {
            $langs = (($candidates | ForEach-Object { (Get-GoldNameParts -BaseName $_.BaseName).Language }) | Sort-Object -Unique) -join ', '
            throw "-GoldLanguage '$requested' does not match any gold for imageId='$ImageId' (on disk: $langs)"
        }
        return $picked[0].FullName
    }

    # An explicit locale in the config already says what language this lab speaks. If
    # exactly one gold agrees with it, that is the answer and there is nothing to ask.
    $configured = Get-ConfiguredLanguageSlug -Defaults $script:ConfigRoot.defaults
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $picked = @($candidates | Where-Object { (Get-GoldNameParts -BaseName $_.BaseName).Language -eq $configured })
        if ($picked.Count -eq 1) {
            Write-Log "'$ImageId' by locale ${configured}: $($picked[0].Name)" -Tag "Info"
            return $picked[0].FullName
        }
    }

    $names = (($candidates | ForEach-Object { $_.Name }) | Sort-Object) -join ', '
    if ($AllowPrompt -and (Test-MenuHostSupported)) {
        return Show-GoldLanguagePicker -Candidates $candidates -ImageId $key -ServerName $ServerName
    }

    throw "More than one gold image for imageId='$ImageId' ($names). Pass -GoldLanguage <tag> or set defaults.locale in config.json"
}

function Test-IsWindows11Gold {
    # Reads the imageId out of the gold's name rather than searching the whole string:
    # the id is the part that is guaranteed to be there, and the language segment in
    # front of it is not something either of these questions cares about.
    param([string]$GoldPath)

    $parts = Get-GoldNameParts -BaseName ([System.IO.Path]::GetFileNameWithoutExtension($GoldPath))
    if ($null -eq $parts) { return $false }
    return ($parts.ImageId -match "^w1[01]-")
}

function Test-IsServerGold {
    # Azure Local counts here: it is Core-based and takes the server provisioning path,
    # not the Windows 11 OOBE one. Naming it explicitly means the concrete gold decides,
    # rather than the classifier falling through to its default.
    param([string]$GoldPath)

    $parts = Get-GoldNameParts -BaseName ([System.IO.Path]::GetFileNameWithoutExtension($GoldPath))
    if ($null -eq $parts) { return $false }
    return ($parts.ImageId -match "^ws\d{4}-" -or $parts.ImageId -eq "azl")
}

function Test-IsClientProvision {
    param(
        [object]$Server,
        [string]$GoldPath = ""
    )

    # Prefer concrete gold filename over config hints - a stale imageHint must
    # never flip a Server gold onto the Win11 OOBE path (HideOnlineAccountScreens
    # / offline OOBE hive -> answer-file or first-boot failures on Server).
    if (-not [string]::IsNullOrWhiteSpace($GoldPath)) {
        if (Test-IsWindows11Gold -GoldPath $GoldPath) { return $true }
        if (Test-IsServerGold -GoldPath $GoldPath) { return $false }
    }

    $imageId = ([string]$Server.imageId).ToLowerInvariant()
    if ($imageId -match '^ws\d' -or $imageId -match 'server') {
        return $false
    }
    if ($imageId -match '^w1[01]-' -or $imageId -match 'windows-?1[01]') {
        return $true
    }

    $hint = ([string]$Server.imageHint).ToLowerInvariant()
    if ($hint -match 'windows-?server') {
        return $false
    }
    if ($hint -match 'windows-?1[01]' -or $hint -match 'win-?1[01]') {
        return $true
    }

    return $false
}

function ConvertTo-XmlEscapedText {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [System.Security.SecurityElement]::Escape($Text)
}

function ConvertTo-UnattendMacAddress {
    param([string]$MacAddress)

    $raw = (($MacAddress) -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($raw.Length -ne 12 -or $raw -eq "000000000000") {
        return $null
    }
    return ($raw -replace '..(?!$)', '$&-')
}

function New-HyperVStaticMacAddress {
    # Hyper-V OUI 00-15-5D + 3 random bytes.
    $b = 1..3 | ForEach-Object { Get-Random -Minimum 0 -Maximum 256 }
    return ("00155D{0:X2}{1:X2}{2:X2}" -f $b[0], $b[1], $b[2])
}

function Get-VmNicMacForUnattend {
    param(
        [string]$VmName,
        # Empty targets the first adapter - the one New-VM created.
        [string]$AdapterName = ""
    )

    # Gold images often leave a ghost "Ethernet"; the live Hyper-V NIC becomes
    # "Ethernet 2". TCPIP Identifier by name then misses - use MAC instead.
    $existing = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 0) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($AdapterName)) {
        $nic = $existing[0]
    }
    else {
        $nic = $existing | Where-Object { $_.Name -eq $AdapterName } | Select-Object -First 1
        if (-not $nic) {
            Write-Log "Adapter '$AdapterName' not found on '$VmName'" -Tag "Warn"
            return $null
        }
    }

    # A VM with several adapters must not draw the same random MAC twice.
    $taken = @($existing | ForEach-Object { ([string]$_.MacAddress).ToUpperInvariant() })
    $raw = New-HyperVStaticMacAddress
    for ($attempt = 0; $attempt -lt 5 -and ($taken -contains $raw.ToUpperInvariant()); $attempt++) {
        $raw = New-HyperVStaticMacAddress
    }
    try {
        Set-VMNetworkAdapter -VMNetworkAdapter $nic -StaticMacAddress $raw -ErrorAction Stop
    }
    catch {
        Write-Log "Set static MAC '$raw' on '$VmName' failed: $($_.Exception.Message)" -Tag "Warn"
        return $null
    }

    $nic = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -eq $nic.Id } | Select-Object -First 1
    if (-not $nic) {
        return ConvertTo-UnattendMacAddress -MacAddress $raw
    }
    return ConvertTo-UnattendMacAddress -MacAddress $nic.MacAddress
}

function Get-ServerAdditionalNics {
    <#
      Normalized additionalNics rows from config.json. Every entry that survives has a name
      and a switch; a nameless or switchless adapter is a config error, not something to
      guess at, so it throws rather than attaching a NIC to nothing.
    #>
    param([object]$Server)

    $result = New-Object System.Collections.Generic.List[object]
    if (-not $Server.additionalNics) {
        return $result.ToArray()
    }
    $index = 1
    foreach ($raw in @($Server.additionalNics)) {
        if ($null -eq $raw) { continue }
        $index++
        $name = ([string]$raw.name).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = "vnic-{0:D2}" -f $index
        }
        $switchName = ([string]$raw.switchName).Trim()
        if ([string]::IsNullOrWhiteSpace($switchName)) {
            throw "Server '$(([string]$Server.name).Trim())' adapter '$name' has no switchName"
        }
        $vlanId = $null
        if ($null -ne $raw.vlanId -and [string]$raw.vlanId -ne "") {
            $vlanId = [int]$raw.vlanId
        }
        $prefix = 24
        if ($null -ne $raw.prefixLength -and [string]$raw.prefixLength -ne "") {
            $prefix = [int]$raw.prefixLength
        }
        $result.Add([pscustomobject]@{
                Name         = $name
                SwitchName   = $switchName
                VlanId       = $vlanId
                IpAddress    = ([string]$raw.ipAddress).Trim()
                PrefixLength = $prefix
                MacAddress   = ""
            }) | Out-Null
    }
    return $result.ToArray()
}

function Get-ServerPrimaryNicName {
    param([object]$Server)

    $name = ([string]$Server.nicName).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return "vnic-01"
    }
    return $name
}

function Get-ServerAutomaticStartAction {
    <#
      Hyper-V's AutomaticStartAction for this VM. Anything the config does not name is
      "Nothing" - the studio default and Hyper-V's own for a hand-built VM.
    #>
    param([object]$Server)

    $action = ([string]$Server.automaticStartAction).Trim()
    if ($action -eq "Start" -or $action -eq "StartIfRunning") {
        return $action
    }
    return "Nothing"
}

function Get-ServerAutomaticStartDelay {
    param([object]$Server)

    if ($null -eq $Server.automaticStartDelay -or [string]$Server.automaticStartDelay -eq "") {
        return 0
    }
    $delay = [int]$Server.automaticStartDelay
    if ($delay -lt 0) { return 0 }
    return $delay
}

function Test-ServerWantsNestedVirtualization {
    <#
      Explicit per-VM flag, or implied by the Hyper-V role landing inside the guest - a guest
      that installs Hyper-V and cannot start a VM is not what anybody asked for.
    #>
    param([object]$Server)

    if ($null -ne $Server.nestedVirtualization -and [bool]$Server.nestedVirtualization) {
        return $true
    }
    if ($Server.windowsFeatures) {
        return (@($Server.windowsFeatures) -contains "Hyper-V")
    }
    return $false
}

function Test-BuiltInAdminOnly {
    <#
      True when the VM should come up with Built-in\Administrator as its only local
      account (no provisioned localUserName). Always on for domain controllers -
      AD DS promotion removes the local SAM, so any extra local admin is discarded
      anyway. Otherwise driven by the per-server builtInAdminOnly flag.
    #>
    param([object]$Server)

    $features = @()
    if ($Server.windowsFeatures) {
        $features = @($Server.windowsFeatures | ForEach-Object { ([string]$_).Trim() })
    }
    if ($features -contains "AD-Domain-Services") {
        return $true
    }

    if ($null -ne $Server.builtInAdminOnly) {
        return [bool]$Server.builtInAdminOnly
    }
    return $false
}

function Get-ServerLocalCredentialUser {
    <#
      Account name Build-Vms uses for PowerShell Direct into a freshly built guest.
    #>
    param([object]$Server)

    if (Test-BuiltInAdminOnly -Server $Server) {
        return "Administrator"
    }
    $user = [string]$Server.localUserName
    if ([string]::IsNullOrWhiteSpace($user)) {
        return "localadmin"
    }
    return $user
}

function Get-GoldImageManifest {
    # Sidecar manifest New-Vhdx.ps1 writes next to every gold ("<name>.vhdx.json").
    # Records the locale/keyboard/time zone actually baked into the image. Cached
    # per gold path - one read serves every VM provisioned from that gold.
    param([string]$GoldPath)

    if ($null -eq $script:GoldManifestCache) {
        $script:GoldManifestCache = @{}
    }
    $key = $GoldPath.ToLowerInvariant()
    if ($script:GoldManifestCache.ContainsKey($key)) {
        return $script:GoldManifestCache[$key]
    }

    $manifestPath = "$GoldPath.json"
    $manifest = $null
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Log "Gold manifest '$manifestPath' is unreadable: $($_.Exception.Message)" -Tag "Error"
            $manifest = $null
        }
    }
    $script:GoldManifestCache[$key] = $manifest
    return $manifest
}

function Resolve-EffectiveLocale {
    # config.json locale "default" means: inherit whatever New-Vhdx.ps1 baked into
    # this VM's gold image, read from the gold's sidecar manifest. Explicit tags
    # still pass through untouched. Returns Locale/KeyboardLayout/InputLocale.
    param(
        [object]$Defaults,
        [string]$GoldPath
    )

    $locale = "de-DE"
    $keyboardLayout = "de-DE"
    if ($Defaults) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Defaults.locale)) {
            $locale = ([string]$Defaults.locale).Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$Defaults.keyboardLayout)) {
            $keyboardLayout = ([string]$Defaults.keyboardLayout).Trim()
        }
    }

    if ($locale -ieq "default") {
        $manifest = $null
        if (-not [string]::IsNullOrWhiteSpace($GoldPath)) {
            $manifest = Get-GoldImageManifest -GoldPath $GoldPath
        }
        if ($null -eq $manifest -or [string]::IsNullOrWhiteSpace([string]$manifest.locale)) {
            throw "config.json locale is 'default' but gold '$GoldPath' has no readable sidecar manifest ('$GoldPath.json'). Rebuild the gold with the current New-Vhdx.ps1, or pick an explicit locale in the studio."
        }
        $resolved = [pscustomobject]@{
            Locale         = ([string]$manifest.locale).Trim()
            KeyboardLayout = ([string]$manifest.keyboardLayout).Trim()
            InputLocale    = ([string]$manifest.inputLocale).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($resolved.KeyboardLayout)) { $resolved.KeyboardLayout = $resolved.Locale }
        if ([string]::IsNullOrWhiteSpace($resolved.InputLocale)) {
            $resolved.InputLocale = Get-InputLocaleForKeyboard -KeyboardLayout $resolved.KeyboardLayout
        }
        return $resolved
    }

    return [pscustomobject]@{
        Locale         = $locale
        KeyboardLayout = $keyboardLayout
        InputLocale    = Get-InputLocaleForKeyboard -KeyboardLayout $keyboardLayout
    }
}

function Get-InputLocaleForKeyboard {
    # InputLocale (keyboard) table - LangId:KeyboardId hex pairs, verified against
    # https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-8.1-and-8/hh825684(v=win.10)
    # Kept as a literal table here (not shared with New-Vhdx.ps1 - two separate
    # scripts, no shared module today).
    param([string]$KeyboardLayout)

    $inputLocaleMap = @{
        "de-DE" = "0407:00000407"; "en-US" = "0409:00000409"
        "cs-CZ" = "0405:00000405"; "da-DK" = "0406:00000406"
        "en-GB" = "0809:00000809"; "es-ES" = "0c0a:0000040a"
        "fi-FI" = "040b:0000040b"; "fr-FR" = "040c:0000040c"
        "it-IT" = "0410:00000410"; "nb-NO" = "0414:00000414"
        "nl-NL" = "0413:00000413"; "pl-PL" = "0415:00000415"
        "pt-PT" = "0816:00000816"; "sv-SE" = "041d:0000041d"
    }
    if ($inputLocaleMap.ContainsKey($KeyboardLayout)) { return $inputLocaleMap[$KeyboardLayout] }
    return "0407:00000407"
}

function Get-ServerUnattendContent {
    param(
        [object]$Server,
        [object]$Defaults,
        [bool]$IsClient = $false,
        [string]$NicMacAddress = "",
        # One entry per extra adapter: Name, MacAddress, IpAddress, PrefixLength.
        [object[]]$AdditionalNicPlan = @(),
        # Gold VHDX this VM derives from - source of truth when locale is "default".
        [string]$GoldPath = ""
    )

    $computerName = ([string]$Server.name).Trim().ToLowerInvariant()
    if ($computerName.Length -gt 15) {
        $computerName = $computerName.Substring(0, 15)
    }
    # NetBIOS: letters, digits, hyphen; cannot start/end with hyphen.
    if ($computerName -notmatch '^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$') {
        throw "Server name '$computerName' is not a valid NetBIOS computer name"
    }

    $userName = [string]$Server.localUserName
    if ([string]::IsNullOrWhiteSpace($userName)) {
        $userName = "localadmin"
    }

    $password = Convert-ToPlainText -Value $Server.localUserPassword
    if ([string]::IsNullOrWhiteSpace($password)) {
        throw "Server '$computerName' has an empty localUserPassword"
    }

    $adminPasswordB64 = Convert-ToBase64Unicode -PlainText $password -ElementName "AdministratorPassword"
    $localPasswordB64 = Convert-ToBase64Unicode -PlainText $password -ElementName "Password"
    $ipAddress = ([string]$Server.ipAddress).Trim()
    $prefix = 24
    if ($null -ne $Server.prefixLength -and [string]$Server.prefixLength -ne "") {
        $prefix = [int]$Server.prefixLength
    }
    $gateway = ([string]$Server.defaultGateway).Trim()
    $dnsList = @()
    if ($Server.dnsServers) {
        $dnsList = @($Server.dnsServers | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne "" })
    }

    # Static IP + domain join both happen in the specialize pass for every OS type
    # (TCPIP + DNS-Client + UnattendedJoin, MAC Identifier - AutomatedLab / AzSHCI
    # pattern). A join from SetupComplete itself is off the table: it needs a reboot,
    # and Microsoft documents a reboot inside SetupComplete as leaving the machine in
    # a bad state (that is the Win11 OOBE hang seen 2026-08-30). domainJoin.mode =
    # "deferred" therefore keeps the unattend join-free and hands the join to the
    # VmDeploy-DomainJoin task that GuestProvision registers - see
    # Set-OfflineGuestProvisionPayload.
    if (-not [string]::IsNullOrWhiteSpace($ipAddress)) {
        $ipv4Pattern = '^\d{1,3}(\.\d{1,3}){3}$'
        if ($ipAddress -notmatch $ipv4Pattern) {
            throw "Server '$computerName' has an invalid ipAddress '$ipAddress'"
        }
        if ($prefix -lt 1 -or $prefix -gt 32) {
            throw "Server '$computerName' has an invalid prefixLength '$prefix' (1-32)"
        }
        if (-not [string]::IsNullOrWhiteSpace($gateway) -and $gateway -notmatch $ipv4Pattern) {
            throw "Server '$computerName' has an invalid defaultGateway '$gateway'"
        }
        foreach ($dns in $dnsList) {
            if ($dns -notmatch $ipv4Pattern) {
                throw "Server '$computerName' has an invalid DNS server '$dns'"
            }
        }
    }

    $domainJoin = $null
    try {
        $domainJoin = Resolve-DomainJoinForServer -Server $Server
    }
    catch {
        throw
    }
    if ($domainJoin -and [string]::IsNullOrWhiteSpace($ipAddress)) {
        throw "Server '$computerName' domainJoin requires ipAddress (static IP before join; no DHCP on target VLAN)"
    }

    $computerEsc = ConvertTo-XmlEscapedText -Text $computerName
    $userEsc = ConvertTo-XmlEscapedText -Text $userName

    # Built-in Administrator only: emit no <LocalAccounts> at all. The account the
    # unattend still sets a password for is Built-in\Administrator (AdministratorPassword
    # above). Mandatory for domain controllers - dcpromo deletes the local SAM, so a
    # provisioned second local admin silently disappears on promotion.
    $localAccountsXml = @"

        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>$localPasswordB64</Value>
              <PlainText>false</PlainText>
            </Password>
            <Description>Provisioned local admin</Description>
            <DisplayName>$userEsc</DisplayName>
            <Group>Administrators</Group>
            <Name>$userEsc</Name>
          </LocalAccount>
        </LocalAccounts>
"@
    if (Test-BuiltInAdminOnly -Server $Server) {
        $localAccountsXml = ""
    }

    # Regional / OOBE: answer country/keyboard/format so that screen is skipped.
    # There is no separate hide-flag for the OOBE region/keyboard page the way
    # there is <HideWirelessSetupInOOBE>/<HideEULAPage> - Windows Setup only
    # skips it when Microsoft-Windows-International-Core is present with an
    # answer. Locale is purely a property of the gold image (baked once via
    # New-Vhdx.ps1); this only echoes back a matching answer so Setup doesn't
    # interactively block first boot - it is not an independent per-VM override.
    # config.json locale "default" inherits the gold's own baked values via its
    # sidecar manifest; an explicit tag must match what the operator actually
    # built the gold with. UI language is never set here - Auto only, no
    # language-pack source exists.
    $effectiveLocale = Resolve-EffectiveLocale -Defaults $Defaults -GoldPath $GoldPath
    $localeEsc = ConvertTo-XmlEscapedText -Text $effectiveLocale.Locale
    $inputEsc = ConvertTo-XmlEscapedText -Text $effectiveLocale.InputLocale

    $internationalXml = @"

    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>$inputEsc</InputLocale>
      <SystemLocale>$localeEsc</SystemLocale>
      <UserLocale>$localeEsc</UserLocale>
    </component>
"@

    # Server: only OOBE keys that validate on Server images.
    # Client: also hide MSA / OEM / local-account OOBE pages.
    $oobeExtraXml = ""
    if ($IsClient) {
        $oobeExtraXml = @"

        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
"@
    }

    # Hyper-V golds are sysprep'd with /mode:vm (New-Vhdx -Target HyperV).
    $vmModeXml = @"

        <VMModeOptimizations>
          <SkipAdministratorProfileRemoval>true</SkipAdministratorProfileRemoval>
          <SkipNotifyUILanguageChange>true</SkipNotifyUILanguageChange>
        </VMModeOptimizations>
"@

    # Every OS type: Microsoft-Windows-TCPIP / DNS-Client / UnattendedJoin in specialize.
    # Prefer MAC Identifier - gold images often leave ghost "Ethernet", live NIC is "Ethernet 2".
    # One <Interface> per adapter that carries a static address: the primary adapter first
    # (it owns the default route and the resolver), then every additionalNics entry with an
    # ipAddress. Extra adapters deliberately get no route and no DNS - a second default route
    # is the standard way to make a multi-homed guest unreachable.
    $networkXml = ""
    $joinXml = ""

    $ifacePlan = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($ipAddress)) {
        $ifaceId = "Ethernet"
        $macCheck = ConvertTo-UnattendMacAddress -MacAddress $NicMacAddress
        if ($macCheck) {
            $ifaceId = $macCheck
        }
        $ifacePlan.Add([pscustomobject]@{
                Identifier = $ifaceId
                Cidr       = ("{0}/{1}" -f $ipAddress, $prefix)
                Gateway    = $gateway
                DnsServers = $dnsList
            }) | Out-Null
    }
    foreach ($extraNic in @($AdditionalNicPlan)) {
        if ($null -eq $extraNic) { continue }
        $extraIp = ([string]$extraNic.IpAddress).Trim()
        if ([string]::IsNullOrWhiteSpace($extraIp)) { continue }
        $extraMac = ConvertTo-UnattendMacAddress -MacAddress ([string]$extraNic.MacAddress)
        if (-not $extraMac) {
            throw "Server '$computerName' adapter '$([string]$extraNic.Name)' has a static IP but no usable MAC address for the TCPIP Identifier"
        }
        $extraPrefix = 24
        if ($null -ne $extraNic.PrefixLength -and [string]$extraNic.PrefixLength -ne "") {
            $extraPrefix = [int]$extraNic.PrefixLength
        }
        if ($extraIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            throw "Server '$computerName' adapter '$([string]$extraNic.Name)' has an invalid ipAddress '$extraIp'"
        }
        if ($extraPrefix -lt 1 -or $extraPrefix -gt 32) {
            throw "Server '$computerName' adapter '$([string]$extraNic.Name)' has an invalid prefixLength '$extraPrefix' (1-32)"
        }
        $ifacePlan.Add([pscustomobject]@{
                Identifier = $extraMac
                Cidr       = ("{0}/{1}" -f $extraIp, $extraPrefix)
                Gateway    = ""
                DnsServers = @()
            }) | Out-Null
    }

    if ($ifacePlan.Count -gt 0) {
        $tcpipIfaceXml = New-Object System.Collections.Generic.List[string]
        $dnsIfaceEntries = New-Object System.Collections.Generic.List[string]
        foreach ($plan in $ifacePlan) {
            $ifaceEsc = ConvertTo-XmlEscapedText -Text ([string]$plan.Identifier)
            $ipCidrEsc = ConvertTo-XmlEscapedText -Text ([string]$plan.Cidr)

            $routesXml = ""
            if (-not [string]::IsNullOrWhiteSpace([string]$plan.Gateway)) {
                $gwEsc = ConvertTo-XmlEscapedText -Text ([string]$plan.Gateway)
                $routesXml = @"

          <Routes>
            <Route wcm:action="add">
              <Identifier>0</Identifier>
              <Prefix>0.0.0.0/0</Prefix>
              <NextHopAddress>$gwEsc</NextHopAddress>
            </Route>
          </Routes>
"@
            }

            # Element order per MS: Ipv4Settings, Ipv6Settings, Identifier, UnicastIpAddresses, Routes
            $tcpipIfaceXml.Add(@"
        <Interface wcm:action="add">
          <Ipv4Settings>
            <DhcpEnabled>false</DhcpEnabled>
          </Ipv4Settings>
          <Ipv6Settings>
            <DhcpEnabled>false</DhcpEnabled>
          </Ipv6Settings>
          <Identifier>$ifaceEsc</Identifier>
          <UnicastIpAddresses>
            <IpAddress wcm:action="add" wcm:keyValue="1">$ipCidrEsc</IpAddress>
          </UnicastIpAddresses>$routesXml
        </Interface>
"@) | Out-Null

            $planDns = @($plan.DnsServers)
            if ($planDns.Count -gt 0) {
                $dnsEntries = for ($di = 0; $di -lt $planDns.Count; $di++) {
                    $dnsEsc = ConvertTo-XmlEscapedText -Text $planDns[$di]
                    "            <IpAddress wcm:action=`"add`" wcm:keyValue=`"$($di + 1)`">$dnsEsc</IpAddress>"
                }
                $dnsEntriesText = $dnsEntries -join "`n"
                $dnsIfaceEntries.Add(@"
        <Interface wcm:action="add">
          <DNSServerSearchOrder>
$dnsEntriesText
          </DNSServerSearchOrder>
          <Identifier>$ifaceEsc</Identifier>
        </Interface>
"@) | Out-Null
            }
        }

        $dnsIfaceXml = ""
        if ($dnsIfaceEntries.Count -gt 0) {
            $dnsIfaceText = ($dnsIfaceEntries -join "`n").TrimEnd()
            $dnsIfaceXml = @"

    <component name="Microsoft-Windows-DNS-Client"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <Interfaces>
$dnsIfaceText
      </Interfaces>
    </component>
"@
        }

        $tcpipIfaceText = ($tcpipIfaceXml -join "`n").TrimEnd()
        $networkXml = @"

    <component name="Microsoft-Windows-TCPIP"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <Interfaces>
$tcpipIfaceText
      </Interfaces>
    </component>$dnsIfaceXml
"@
    }

    if ($domainJoin -and $domainJoin.mode -ne "deferred") {
        $domain = ([string]$domainJoin.domain).Trim()
        $joinUser = ([string]$domainJoin.joinUser).Trim()
        $joinPassword = [string]$domainJoin.joinPassword

        $credDomain = $domain
        $credUser = $joinUser
        if ($joinUser.Contains([char]'\')) {
            $parts = $joinUser.Split([char]'\', 2)
            $credDomain = $parts[0]
            $credUser = $parts[1]
        }
        elseif ($joinUser.Contains([char]'@')) {
            $parts = $joinUser.Split([char]'@', 2)
            $credUser = $parts[0]
            $credDomain = $parts[1]
        }

        $domainEsc = ConvertTo-XmlEscapedText -Text $domain
        $credDomainEsc = ConvertTo-XmlEscapedText -Text $credDomain
        $credUserEsc = ConvertTo-XmlEscapedText -Text $credUser
        $credPassEsc = ConvertTo-XmlEscapedText -Text $joinPassword

        $ouXml = ""
        $ouPath = ([string]$domainJoin.ouPath).Trim()
        if (-not [string]::IsNullOrWhiteSpace($ouPath)) {
            $ouEsc = ConvertTo-XmlEscapedText -Text $ouPath
            $ouXml = "`n        <MachineObjectOU>$ouEsc</MachineObjectOU>"
        }

        $joinXml = @"

    <component name="Microsoft-Windows-UnattendedJoin"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <Identification>
        <Credentials>
          <Domain>$credDomainEsc</Domain>
          <Password>$credPassEsc</Password>
          <Username>$credUserEsc</Username>
        </Credentials>
        <JoinDomain>$domainEsc</JoinDomain>$ouXml
      </Identification>
    </component>
"@
    }

    $content = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>$computerEsc</ComputerName>
    </component>$internationalXml$networkXml$joinXml
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <UserAccounts>
        <AdministratorPassword>
          <Value>$adminPasswordB64</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>$localAccountsXml
      </UserAccounts>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>$oobeExtraXml
        <ProtectYourPC>3</ProtectYourPC>$vmModeXml
      </OOBE>
    </component>$internationalXml
  </settings>
</unattend>
"@

    return $content
}

function Clear-OfflineUnattendRegistryPointer {
    param([string]$OsRoot)

    # Sysprep /unattend:C:\Windows\Deploy\unattend.xml can leave
    # HKLM\SYSTEM\Setup\UnattendFile pointing at Deploy\unattend.xml.
    # Build-Vms used to delete that file as a "conflict", which makes first boot
    # fail with exactly: "internal error while loading or searching for an
    # unattend answer file" (Setup search order #1 = registry pointer).
    $systemHive = Join-Path -Path $OsRoot -ChildPath "Windows\System32\config\SYSTEM"
    if (-not (Test-Path -LiteralPath $systemHive)) {
        Write-Log "SYSTEM hive not found at '$systemHive' - skipping UnattendFile cleanup" -Tag "Warn"
        return
    }

    $hiveRoot = "HKLM\OfflineBuildUnattend"
    Write-Log "Clearing offline UnattendFile registry pointer" -Tag "Run"
    & reg.exe load $hiveRoot $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SYSTEM hive to clear UnattendFile (exit $LASTEXITCODE)"
    }

    try {
        & reg.exe delete "$hiveRoot\Setup" /v UnattendFile /f 2>$null | Out-Null
        # Point Setup explicitly at the Panther file we inject (search order #1).
        & reg.exe add "$hiveRoot\Setup" /v UnattendFile /t REG_SZ /d "C:\Windows\Panther\unattend.xml" /f | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set UnattendFile registry pointer (exit $LASTEXITCODE)"
        }
        Write-Log "UnattendFile -> C:\Windows\Panther\unattend.xml" -Tag "Debug"
    }
    finally {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        & reg.exe unload $hiveRoot | Out-Null
    }
}

function Test-UnattendXml {
    param(
        [string]$UnattendContent,
        [string]$Label
    )

    # Windows Setup fails first boot with "internal error while loading or searching
    # for an unattend answer file" (0x800705b9) when the injected XML is malformed.
    # Catch that on the host instead of as a dialog in the guest.
    try {
        $null = [xml]$UnattendContent
    }
    catch {
        throw "Generated unattend for $Label is not well-formed XML: $($_.Exception.Message)"
    }
}

function Set-OfflineClientOobeBypass {
    param([string]$OsRoot)

    # Client OOBE hardening (offline SOFTWARE hive):
    # - HideOnlineAccountScreens: reinforce unattend MSA skip
    # - DisablePrivacyExperience / PrivacyConsentStatus: skip 24H2 privacy pages
    #   that ProtectYourPC alone often does not hide
    # BypassNRO intentionally omitted - undocumented, being removed by MS; unattend
    # HideOnlineAccountScreens + LocalAccounts is the supported path.
    $softwareHive = Join-Path -Path $OsRoot -ChildPath "Windows\System32\config\SOFTWARE"
    if (-not (Test-Path -LiteralPath $softwareHive)) {
        Write-Log "SOFTWARE hive not found - skipping client OOBE registry bypass" -Tag "Warn"
        return
    }

    $hiveRoot = "HKLM\OfflineBuildOobe"
    Write-Log "Setting offline client OOBE registry bypasses" -Tag "Run"
    & reg.exe load $hiveRoot $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SOFTWARE hive for OOBE bypass (exit $LASTEXITCODE)"
    }

    try {
        $oobeKey = "$hiveRoot\Microsoft\Windows\CurrentVersion\OOBE"
        $values = @{
            HideOnlineAccountScreens = 1
            DisablePrivacyExperience = 1
            DisableVoice            = 1
            PrivacyConsentStatus    = 1
            Protectyourpc           = 3
            HideEULAPage            = 1
        }
        foreach ($name in $values.Keys) {
            & reg.exe add $oobeKey /v $name /t REG_DWORD /d $values[$name] /f | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to set OOBE\$name (exit $LASTEXITCODE)"
            }
        }
    }
    finally {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        & reg.exe unload $hiveRoot | Out-Null
    }
}

function Get-ConfigDomainJoinAccounts {
    param([object]$ConfigRoot)
    if ($null -eq $ConfigRoot) { return @() }
    $raw = $null
    if ($ConfigRoot.PSObject.Properties.Name -contains "domainJoinAccounts") {
        $raw = $ConfigRoot.domainJoinAccounts
    }
    if ($null -eq $raw) { return @() }
    # ConvertFrom-Json (Windows PS 5.1) unwraps single-element arrays to one PSCustomObject
    if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
        $list = @(foreach ($item in $raw) { $item })
        if ($list.Count -gt 0) { return $list }
    }
    return @($raw)
}

function Get-ConfigAzureArcPrincipals {
    param([object]$ConfigRoot)
    if ($null -eq $ConfigRoot) { return @() }
    $raw = $null
    if ($ConfigRoot.PSObject.Properties.Name -contains "azureArcPrincipals") {
        $raw = $ConfigRoot.azureArcPrincipals
    }
    if ($null -eq $raw) { return @() }
    if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) {
        $list = @(foreach ($item in $raw) { $item })
        if ($list.Count -gt 0) { return $list }
    }
    return @($raw)
}

function Resolve-DomainJoinForServer {
    param(
        [object]$Server,
        [object]$ConfigRoot = $null
    )

    if ($null -eq $ConfigRoot) { $ConfigRoot = $script:ConfigRoot }

    $dj = $null
    if ($Server) { $dj = $Server.domainJoin }
    if (-not ($dj -and [bool]$dj.enabled)) {
        return $null
    }

    $serverName = if ($Server -and $Server.name) { [string]$Server.name } else { "?" }
    $accountId = ([string]$dj.accountId).Trim()
    $domain = ([string]$dj.domain).Trim()
    $joinUser = ([string]$dj.joinUser).Trim()
    $joinPassword = Convert-ToPlainText -Value $dj.joinPassword
    $ouPath = ([string]$dj.ouPath).Trim()
    # "specialize" (default) joins from the unattend; "deferred" leaves the unattend alone
    # and lets GuestProvision register the VmDeploy-DomainJoin task, which joins once
    # Setup is finished - the studio decides the value, this script never guesses it.
    $mode = ([string]$dj.mode).Trim().ToLowerInvariant()
    if ($mode -ne "deferred") { $mode = "specialize" }

    # Catalog shape: accountId -> domainJoinAccounts[] (overlay; keep any inline values as fallback)
    if (-not [string]::IsNullOrWhiteSpace($accountId)) {
        $accounts = @(Get-ConfigDomainJoinAccounts -ConfigRoot $ConfigRoot)
        $account = $accounts |
            Where-Object {
                $id = ([string]$_.id).Trim()
                $alt = ([string]$_._id).Trim()
                ($id -and ($id -eq $accountId)) -or ($alt -and ($alt -eq $accountId))
            } |
            Select-Object -First 1

        if ($null -eq $account) {
            if ([string]::IsNullOrWhiteSpace($domain) -or [string]::IsNullOrWhiteSpace($joinUser) -or [string]::IsNullOrWhiteSpace($joinPassword)) {
                $catalogCount = $accounts.Count
                throw "Server '$serverName' domainJoin.accountId '$accountId' was not found in domainJoinAccounts ($catalogCount account(s) in config). Re-export config.json from html\hyperv-vm-studio.html."
            }
            # Inline credentials present - continue with those
        }
        else {
            $cDomain = ([string]$account.domain).Trim()
            $cUser = ([string]$account.joinUser).Trim()
            $cPass = Convert-ToPlainText -Value $account.joinPassword
            if (-not [string]::IsNullOrWhiteSpace($cDomain)) { $domain = $cDomain }
            if (-not [string]::IsNullOrWhiteSpace($cUser)) { $joinUser = $cUser }
            if (-not [string]::IsNullOrWhiteSpace($cPass)) { $joinPassword = $cPass }
        }
    }

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($domain)) { $missing += "domain" }
    if ([string]::IsNullOrWhiteSpace($joinUser)) { $missing += "joinUser" }
    if ([string]::IsNullOrWhiteSpace($joinPassword)) { $missing += "joinPassword" }
    if ($missing.Count -gt 0) {
        $hint = if ([string]::IsNullOrWhiteSpace($accountId)) {
            "Attach the VM on the Domain Join blade (accountId is missing)."
        }
        else {
            "Fill Domain / Join user / Join password on join account '$accountId', then re-export config.json."
        }
        throw "Server '$serverName' domainJoin is enabled but incomplete (missing: $($missing -join ', ')). $hint"
    }

    return [pscustomobject]@{
        enabled      = $true
        accountId    = $accountId
        domain       = $domain
        joinUser     = $joinUser
        joinPassword = $joinPassword
        ouPath       = $ouPath
        mode         = $mode
    }
}

function Get-EffectiveAzureArcConfig {
    param(
        [object]$Server,
        [object]$Defaults,
        [object]$ConfigRoot = $null
    )

    if ($null -eq $ConfigRoot) { $ConfigRoot = $script:ConfigRoot }

    $enabled = $false
    if ($Server -and $Server.azureArc -and $null -ne $Server.azureArc.enabled) {
        $enabled = [bool]$Server.azureArc.enabled
    }
    if (-not $enabled) {
        return $null
    }

    $serverName = if ($Server -and $Server.name) { [string]$Server.name } else { "?" }
    $sa = $Server.azureArc

    $principalId = ([string]$sa.principalId).Trim()
    $subscriptionId = ([string]$sa.subscriptionId).Trim()
    $tenantId = ([string]$sa.tenantId).Trim()
    $resourceGroup = ([string]$sa.resourceGroup).Trim()
    $location = ([string]$sa.location).Trim()
    $authMode = ([string]$sa.authMode).Trim()
    $servicePrincipalAppId = ([string]$sa.servicePrincipalAppId).Trim()
    $servicePrincipalSecret = Convert-ToPlainText -Value $sa.servicePrincipalSecret

    # Catalog shape: principalId -> azureArcPrincipals[] (overlay; keep inline as fallback)
    if (-not [string]::IsNullOrWhiteSpace($principalId)) {
        $principals = @(Get-ConfigAzureArcPrincipals -ConfigRoot $ConfigRoot)
        $principal = $principals |
            Where-Object {
                $id = ([string]$_.id).Trim()
                $alt = ([string]$_._id).Trim()
                ($id -and ($id -eq $principalId)) -or ($alt -and ($alt -eq $principalId))
            } |
            Select-Object -First 1

        if ($null -eq $principal) {
            $hasInline = -not [string]::IsNullOrWhiteSpace($subscriptionId) -and
                         -not [string]::IsNullOrWhiteSpace($resourceGroup) -and
                         -not [string]::IsNullOrWhiteSpace($location)
            if (-not $hasInline) {
                throw "Server '$serverName' azureArc.principalId '$principalId' was not found in azureArcPrincipals ($($principals.Count) principal(s) in config). Re-export config.json from html\hyperv-vm-studio.html."
            }
        }
        else {
            $cSub = ([string]$principal.subscriptionId).Trim()
            $cTenant = ([string]$principal.tenantId).Trim()
            $cRg = ([string]$principal.resourceGroup).Trim()
            $cLoc = ([string]$principal.location).Trim()
            $cAuth = ([string]$principal.authMode).Trim()
            $cApp = ([string]$principal.servicePrincipalAppId).Trim()
            $cSecret = Convert-ToPlainText -Value $principal.servicePrincipalSecret
            if (-not [string]::IsNullOrWhiteSpace($cSub)) { $subscriptionId = $cSub }
            if (-not [string]::IsNullOrWhiteSpace($cTenant)) { $tenantId = $cTenant }
            if (-not [string]::IsNullOrWhiteSpace($cRg)) { $resourceGroup = $cRg }
            if (-not [string]::IsNullOrWhiteSpace($cLoc)) { $location = $cLoc }
            if (-not [string]::IsNullOrWhiteSpace($cAuth)) { $authMode = $cAuth }
            if (-not [string]::IsNullOrWhiteSpace($cApp)) { $servicePrincipalAppId = $cApp }
            if (-not [string]::IsNullOrWhiteSpace($cSecret)) { $servicePrincipalSecret = $cSecret }
        }
    }
    elseif ($Defaults -and $Defaults.azureArc -and [bool]$Defaults.azureArc.available) {
        # Legacy: single global defaults.azureArc landing zone
        $legacy = $Defaults.azureArc
        if ([string]::IsNullOrWhiteSpace($subscriptionId)) { $subscriptionId = ([string]$legacy.subscriptionId).Trim() }
        if ([string]::IsNullOrWhiteSpace($tenantId)) { $tenantId = ([string]$legacy.tenantId).Trim() }
        if ([string]::IsNullOrWhiteSpace($resourceGroup)) { $resourceGroup = ([string]$legacy.resourceGroup).Trim() }
        if ([string]::IsNullOrWhiteSpace($location)) { $location = ([string]$legacy.location).Trim() }
        if ([string]::IsNullOrWhiteSpace($authMode)) { $authMode = ([string]$legacy.authMode).Trim() }
        if ([string]::IsNullOrWhiteSpace($servicePrincipalAppId)) { $servicePrincipalAppId = ([string]$legacy.servicePrincipalAppId).Trim() }
        if ([string]::IsNullOrWhiteSpace($servicePrincipalSecret)) { $servicePrincipalSecret = Convert-ToPlainText -Value $legacy.servicePrincipalSecret }
    }
    else {
        throw "Server '$serverName' azureArc is enabled but principalId is missing. Attach the VM on the Azure Arc blade, then re-export config.json."
    }

    if ([string]::IsNullOrWhiteSpace($authMode)) { $authMode = "servicePrincipal" }

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) { $missing += "subscriptionId" }
    if ([string]::IsNullOrWhiteSpace($resourceGroup)) { $missing += "resourceGroup" }
    if ([string]::IsNullOrWhiteSpace($location)) { $missing += "location" }
    if ($authMode -ne "hostContext") {
        if ([string]::IsNullOrWhiteSpace($tenantId)) { $missing += "tenantId" }
        if ([string]::IsNullOrWhiteSpace($servicePrincipalAppId)) { $missing += "servicePrincipalAppId" }
        # Secret may come from -ArcServicePrincipalPath / -ArcServicePrincipalSecret at build time
    }
    if ($missing.Count -gt 0) {
        $hint = if ([string]::IsNullOrWhiteSpace($principalId)) {
            "Attach the VM on the Azure Arc blade and fill the landing zone fields."
        }
        else {
            "Complete Arc principal '$principalId' in the Azure Arc blade, then re-export config.json."
        }
        throw "Server '$serverName' azureArc is enabled but incomplete (missing: $($missing -join ', ')). $hint"
    }

    return [pscustomobject]@{
        enabled                = $true
        principalId            = $principalId
        authMode               = $authMode
        subscriptionId         = $subscriptionId
        tenantId               = $tenantId
        resourceGroup          = $resourceGroup
        location               = $location
        servicePrincipalAppId  = $servicePrincipalAppId
        servicePrincipalSecret = $servicePrincipalSecret
    }
}

function Get-ArcServicePrincipalSecretMaterial {
    param(
        [object]$ArcConfig
    )

    if ($null -eq $ArcConfig -or $ArcConfig.authMode -ne "servicePrincipal") {
        return $null
    }

    $appId = [string]$ArcConfig.servicePrincipalAppId
    # Preference: CLI override file/param -> config.json azureArc.servicePrincipalSecret (from HTML)
    $secret = ""
    if (-not [string]::IsNullOrWhiteSpace([string]$ArcConfig.servicePrincipalSecret)) {
        $secret = [string]$ArcConfig.servicePrincipalSecret
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:ArcServicePrincipalSecret)) {
        $secret = [string]$script:ArcServicePrincipalSecret
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ArcServicePrincipalPath)) {
        if (-not (Test-Path -LiteralPath $script:ArcServicePrincipalPath)) {
            throw "Arc service principal file not found: $($script:ArcServicePrincipalPath)"
        }
        $doc = Get-Content -LiteralPath $script:ArcServicePrincipalPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($appId) -and -not [string]::IsNullOrWhiteSpace([string]$doc.servicePrincipalAppId)) {
            $appId = [string]$doc.servicePrincipalAppId
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$doc.servicePrincipalSecret)) {
            $secret = [string]$doc.servicePrincipalSecret
        }
    }

    if ([string]::IsNullOrWhiteSpace($appId) -or [string]::IsNullOrWhiteSpace($secret)) {
        Write-Log "Arc SP mode selected but App ID/secret missing - guest Arc connect will be skipped" -Tag "Warn"
        return $null
    }

    return [pscustomobject]@{
        servicePrincipalAppId   = $appId
        servicePrincipalSecret  = $secret
    }
}

$script:FodPayloadExtensions = @(".cab", ".esd", ".msu", ".wim")

function Test-FodFolderHasPayload {
    <#
      True when a folder actually holds Features on Demand payload. Deliberately looks for
      package files rather than "any file at all": the .gitkeep and README.md notes shipped
      in client-features\ and server-features\ must not read as a populated repository, and
      neither must the top level of a whole-ISO copy (autorun.inf, setup.exe, ...) whose real
      payload lives one folder down in LanguagesAndOptionalFeatures\.
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }

    $payload = @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $script:FodPayloadExtensions -contains $_.Extension.ToLowerInvariant() })
    return ($payload.Count -gt 0)
}

function Get-FodSourceCandidates {
    <#
      Folders to try as an Add-WindowsCapability -Source, best match first.

      Layout differs per medium (see the Server Core App Compatibility FOD docs:
      https://learn.microsoft.com/en-us/windows-server/get-started/server-core-app-compatibility-feature-on-demand):
        - Windows Server 2022 / 2025 "Languages and Optional Features" ISO keeps the cabs
          under \LanguagesAndOptionalFeatures.
        - Windows Server 2019 and the Windows 11 FoD ISO keep them at the ISO root.

      The FoD medium also has to match the OS version, so a per-version subfolder
      (server-features\2025\, \2022\, \2019\) is checked before the folder itself. That
      lets one repository serve labs that mix Windows Server releases.
    #>
    param(
        [string]$Path,
        [string]$VersionToken = ""
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }

    $roots = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($VersionToken)) {
        $roots.Add((Join-Path -Path $Path -ChildPath $VersionToken))
    }
    $roots.Add($Path)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        $candidates.Add((Join-Path -Path $root -ChildPath "LanguagesAndOptionalFeatures"))
        $candidates.Add($root)
    }
    return @($candidates)
}

function Resolve-FodSourcePath {
    <#
      First candidate folder that actually holds payload, or "" when nothing usable
      is there (caller then defers the capability to the guest's online install).
    #>
    param(
        [string]$Path,
        [string]$VersionToken = ""
    )

    foreach ($candidate in (Get-FodSourceCandidates -Path $Path -VersionToken $VersionToken)) {
        if (Test-FodFolderHasPayload -Path $candidate) { return $candidate }
    }
    return ""
}

function Get-ServerFodVersionToken {
    <#
      "2019" / "2022" / "2025" from a server imageId such as ws2025-datacenter-core.
      Empty for client images and for custom gold images that carry no version hint.
    #>
    param([object]$Server)

    $id = ([string]$Server.imageId).ToLowerInvariant()
    if ($id -match 'ws(\d{4})') { return $Matches[1] }
    return ""
}

function Install-OfflineRsatCapabilities {
    param(
        [string]$OsRoot,
        [string[]]$CapabilityNames,
        [string]$Source = "",
        [switch]$ForceOnline
    )

    $pending = New-Object System.Collections.Generic.List[string]
    if ($null -eq $CapabilityNames -or $CapabilityNames.Count -eq 0) {
        return @()
    }

    if ($ForceOnline.IsPresent -or [string]::IsNullOrWhiteSpace($Source)) {
        Write-Log "RSAT deferred to the guest ($($CapabilityNames.Count) capability(ies))" -Tag "Info"
        return @($CapabilityNames)
    }
    $source = $Source

    Write-Log "Installing $($CapabilityNames.Count) RSAT offline from '$source'" -Tag "Run"
    foreach ($capabilityName in $CapabilityNames) {
        try {
            $result = Add-WindowsCapability -Path $OsRoot -Name $capabilityName -Source $source -LimitAccess -ErrorAction Stop
            Write-Log "RSAT '$capabilityName' (restart=$($result.RestartNeeded))" -Tag "Ok"
        }
        catch {
            Write-Log "Offline RSAT '$capabilityName' failed: $($_.Exception.Message) - deferring to guest" -Tag "Warn"
            $pending.Add($capabilityName)
        }
    }
    return @($pending)
}

# What a feature request is expected to leave behind, keyed by the feature asked for.
# Enable-WindowsOptionalFeature reports success for the name it was handed, which says
# nothing about the two leaves that actually carry Hyper-V Manager and the PowerShell
# module, and nothing about what else came along. Both get read back afterwards.
#
#   Expect - must end Enabled, or the VM did not get what the tick promised.
#   Guard  - must NOT end Enabled. -All enables a feature's parents "with default values",
#            and the Microsoft-Hyper-V-All container's defaults turn out to include the
#            platform: every build enables the hypervisor on the way to the consoles, and
#            every build switches it back off. Measured, not assumed - the first run with
#            -All is what showed it.
$script:ClientFeatureChecks = @{
    "Microsoft-Hyper-V-Tools-All" = @{
        Expect = @("Microsoft-Hyper-V-Management-Clients", "Microsoft-Hyper-V-Management-PowerShell")
        Guard  = @("Microsoft-Hyper-V")
    }
}

function Get-OfflineFeatureState {
    param(
        [string]$OsRoot,
        [string]$FeatureName
    )

    try {
        return [string](Get-WindowsOptionalFeature -Path $OsRoot -FeatureName $FeatureName -ErrorAction Stop).State
    }
    catch {
        Write-Log "Feature '$FeatureName': $($_.Exception.Message)" -Tag "Debug"
        return ""
    }
}

function Enable-OfflineClientFeatures {
    <#
      Windows optional features on a client VM, enabled straight into the mounted image.

      Unlike RSAT these are not Features on Demand: the payload ships inside the client
      image, so there is no ISO to find, nothing to download and nothing to defer to the
      guest. The one entry the studio offers is Microsoft-Hyper-V-Tools-All - Hyper-V
      Manager, vmconnect and the Hyper-V PowerShell module. There is no
      Rsat.Hyper-V.Tools capability; that name does not exist, and asking for it is how
      this first failed.

      -All, because the run without it came back "One or several parent features are
      disabled so current feature can not be enabled": the tools hang off the
      Microsoft-Hyper-V-All container, and a disabled parent blocks the child. That is what
      -All is documented to fix.

      Everything after the enable is there because the cmdlet's own success only covers the
      name it was given. The leaves are checked so a VM cannot ship without the consoles
      the tick promised, and the platform is checked because a workstation that quietly
      grew a hypervisor it has no nested virtualization for is worse than one missing a
      console.

      A failure is a warning, not a build stop: the VM is still the VM, minus a console.
    #>
    param(
        [string]$OsRoot,
        [string[]]$FeatureNames
    )

    if ($null -eq $FeatureNames -or $FeatureNames.Count -eq 0) { return }

    Write-Log "Enabling $($FeatureNames.Count) feature(s) offline" -Tag "Run"
    foreach ($featureName in $FeatureNames) {
        try {
            $result = Enable-WindowsOptionalFeature -Path $OsRoot -FeatureName $featureName -All -NoRestart -ErrorAction Stop
            Write-Log "Feature '$featureName' on (restart=$($result.RestartNeeded))" -Tag "Ok"
        }
        catch {
            Write-Log "Offline feature '$featureName' failed: $($_.Exception.Message)" -Tag "Warn"
            continue
        }

        $checks = $script:ClientFeatureChecks[$featureName]
        if ($null -eq $checks) { continue }

        # Guard first, leaves after. The tools and the platform are separate features, so
        # switching one off should not touch the other - but a leaf checked before the
        # guard runs only proves what was true a moment earlier, and the state that ships
        # is the one after every change has been made.
        foreach ($guarded in @($checks.Guard)) {
            if ((Get-OfflineFeatureState -OsRoot $OsRoot -FeatureName $guarded) -ne "Enabled") {
                Write-Log "'$guarded' stayed off - as intended" -Tag "Debug"
                continue
            }

            # Expected on every build, not a surprise: -All enables the parents, and the
            # Microsoft-Hyper-V-All container's default values include the platform. The
            # tools were the request; the hypervisor was not.
            Write-Log "'$featureName' pulled in '$guarded' - turning it back off" -Tag "Run"
            try {
                Disable-WindowsOptionalFeature -Path $OsRoot -FeatureName $guarded -NoRestart -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log "Could not disable '$guarded': $($_.Exception.Message) - the VM carries it" -Tag "Warn"
                continue
            }

            $guardState = Get-OfflineFeatureState -OsRoot $OsRoot -FeatureName $guarded
            if ("$guardState" -eq "Enabled") {
                Write-Log "'$guarded' is still Enabled after being disabled - the VM carries it" -Tag "Warn"
            }
            else {
                Write-Log "'$guarded' is off ('$guardState')" -Tag "Ok"
            }
        }

        foreach ($expected in @($checks.Expect)) {
            $state = Get-OfflineFeatureState -OsRoot $OsRoot -FeatureName $expected
            if ("$state" -eq "Enabled") {
                Write-Log "'$expected' is Enabled" -Tag "Ok"
            }
            else {
                Write-Log "'$featureName' reported success but '$expected' is '$state' - the VM may not get that tool" -Tag "Warn"
            }
        }
    }
}

$script:ServerCoreAppCompatCapability = "ServerCore.AppCompatibility~~~~0.0.1.0"

# Where each Features on Demand medium comes from, decided once per run by Resolve-FodPlans.
# Keys: "appcompat:<release>" (or "appcompat:*" for a gold with no release hint) and "rsat".
#   @{ Mode = "Offline"; Source = "E:\LanguagesAndOptionalFeatures"; Iso = "D:\isos\...iso" }
#   @{ Mode = "Online" }   install in the guest at first boot
#   @{ Mode = "Skip" }     do not install at all
$script:FodPlanMap = @{}

function Get-AppCompatPlanKey {
    param([object]$Server)

    $token = Get-ServerFodVersionToken -Server $Server
    if ([string]::IsNullOrWhiteSpace($token)) { return "appcompat:*" }
    return "appcompat:$token"
}

function Get-AppCompatPlan {
    param([object]$Server)

    $key = Get-AppCompatPlanKey -Server $Server
    if ($script:FodPlanMap.ContainsKey($key)) { return $script:FodPlanMap[$key] }
    return $null
}

function Get-RsatPlan {
    if ($script:FodPlanMap.ContainsKey("rsat")) { return $script:FodPlanMap["rsat"] }
    return $null
}

function Test-WantsServerCoreAppCompat {
    <#
      Server Core App Compatibility FOD (mmc.exe, eventvwr, perfmon, resmon, dcomcnfg,
      devmgmt, diskmgmt, failover cluster manager, File Explorer, PowerShell ISE ...).
      Core-only by definition - Desktop Experience already ships these, and the
      capability refuses to install there.
      https://learn.microsoft.com/en-us/windows-server/get-started/server-core-app-compatibility-feature-on-demand
    #>
    param([object]$Server)

    if ($null -eq $Server) { return $false }
    if (-not [bool]$Server.appCompatFod) { return $false }
    if (([string]$Server.experience).Trim() -ne "Core") { return $false }

    # An interactive run may have chosen to drop App Compatibility for this release.
    $plan = Get-AppCompatPlan -Server $Server
    if ($plan -and $plan.Mode -eq "Skip") { return $false }
    return $true
}

function Install-OfflineServerCoreAppCompat {
    <#
      Offline Add-WindowsCapability against the mounted gold disk. Returns the
      capability names that still need an online (Windows Update) install in the
      guest - empty when the offline install succeeded.
    #>
    param(
        [string]$OsRoot,
        [string]$VersionToken = "",
        [string]$Source = "",
        [switch]$ForceOnline
    )

    $capability = $script:ServerCoreAppCompatCapability

    if ($ForceOnline.IsPresent -or [string]::IsNullOrWhiteSpace($Source)) {
        Write-Log "App Compatibility deferred to the guest" -Tag "Info"
        return @($capability)
    }
    $source = $Source

    Write-Log "App Compatibility FOD offline from '$source'" -Tag "Run"
    try {
        $result = Add-WindowsCapability -Path $OsRoot -Name $capability -Source $source -LimitAccess -ErrorAction Stop
        Write-Log "App Compatibility FOD (restart=$($result.RestartNeeded))" -Tag "Ok"
        return @()
    }
    catch {
        # By far the most common cause is a FoD medium from a different Windows Server
        # release than the gold image - the capability payload is version-specific.
        $hint = ""
        if (-not [string]::IsNullOrWhiteSpace($VersionToken)) {
            $hint = " (source '$source' must come from the Windows Server $VersionToken Languages and Optional Features ISO)"
        }
        Write-Log "Server Core App Compatibility FOD offline install failed: $($_.Exception.Message)$hint - deferring to guest" -Tag "Warn"
        return @($capability)
    }
}

function Resolve-FodPlans {
    <#
    .SYNOPSIS
        Decides where each Features on Demand medium comes from, once per run.
    .DESCRIPTION
        Runs after the server selection is known, before preflight. Two kinds of medium are
        involved and they are different downloads:

          - Server Core App Compatibility, one medium per Windows Server release;
          - Windows 11 RSAT capabilities, one medium for all client VMs.

        An interactive run is asked once per medium: browse for the ISO (it gets mounted and
        used as the Add-WindowsCapability source directly, which is what Microsoft's own
        instructions do), let the guest install online at first boot, or skip. A
        non-interactive run cannot ask, so it defers to the guest's online install.

        Fills $script:FodPlanMap.
    #>
    param(
        [object[]]$Servers,
        [switch]$Interactive
    )

    $script:FodPlanMap = @{}

    # --- Server Core App Compatibility, grouped by Windows Server release ---
    $appCompatVms = @($Servers | Where-Object {
            $null -ne $_ -and [bool]$_.appCompatFod -and (([string]$_.experience).Trim() -eq "Core")
        })

    $byRelease = [ordered]@{}
    foreach ($server in $appCompatVms) {
        $key = Get-AppCompatPlanKey -Server $server
        if (-not $byRelease.Contains($key)) { $byRelease[$key] = @() }
        $byRelease[$key] += (Get-ServerComputerName -Server $server)
    }

    foreach ($key in @($byRelease.Keys)) {
        $release = $key.Substring("appcompat:".Length)
        $releaseLabel = if ($release -eq "*") { "this gold image" } else { "Windows Server $release" }

        if (-not $Interactive.IsPresent) {
            $script:FodPlanMap[$key] = @{ Mode = "Online" }
            Write-Log "App Compatibility ($releaseLabel): guest installs at first boot" -Tag "Info"
            continue
        }

        $script:FodPlanMap[$key] = Get-FodMediumInteractive `
            -Title "Server Core App Compatibility" `
            -MediumLabel "$releaseLabel Languages and Optional Features ISO" `
            -Subject "App Compatibility ($releaseLabel)" `
            -VmList ($byRelease[$key] -join ", ") `
            -OnlineLabel "Install in guest    from Windows Update at first boot" `
            -OnlineWarning "minutes, needs internet" `
            -Notes @(
                "Installing in the guest adds minutes to every VM's first boot, and needs",
                "internet - or a WSUS configured to allow optional content."
            )
    }

    # --- Windows 11 RSAT capabilities, one medium for every client VM ---
    $rsatVms = @($Servers | Where-Object {
            $null -ne $_ -and $null -ne $_.rsatCapabilities -and @($_.rsatCapabilities).Count -gt 0
        })
    if ($rsatVms.Count -eq 0) { return }

    $rsatNames = @($rsatVms | ForEach-Object { Get-ServerComputerName -Server $_ })
    $rsatCount = @($rsatVms | ForEach-Object { @($_.rsatCapabilities).Count } | Measure-Object -Sum).Sum

    if (-not $Interactive.IsPresent) {
        $script:FodPlanMap["rsat"] = @{ Mode = "Online" }
        Write-Log "RSAT: guests install $rsatCount capability(ies) at first boot" -Tag "Info"
        return
    }

    $script:FodPlanMap["rsat"] = Get-FodMediumInteractive `
        -Title "Windows 11 RSAT capabilities" `
        -MediumLabel "Windows 11 Languages and Optional Features ISO" `
        -Subject "RSAT" `
        -VmList ($rsatNames -join ", ") `
        -Extra ([ordered]@{ "capabilities" = "$rsatCount to install" }) `
        -OnlineLabel "Install in guest    SLOW - one Windows Update download each" `
        -OnlineWarning "one download per item" `
        -Notes @(
            "Each capability is fetched separately at first boot, so this is slow. A WSUS",
            "without optional content configured fails all of them."
        )
}

function Get-FodMediumInteractive {
    <#
      One menu per Features on Demand medium that has to be sourced.
      Returns the plan hashtable for $script:FodPlanMap.
    #>
    param(
        [string]$Title,
        [string]$MediumLabel,
        [string]$Subject,
        [string]$VmList,
        [System.Collections.IDictionary]$Extra,
        [string]$OnlineLabel,
        [string]$OnlineWarning,
        # The caveat, in lines the caller has already broken. It goes above the list
        # rather than into a row or the header: a menu row is one line by definition,
        # and the header column is half a screen narrower than this one.
        [string[]]$Notes = @()
    )

    while ($true) {
        $status = [ordered]@{ "needs it" = $VmList }
        if ($Extra) {
            foreach ($k in $Extra.Keys) { $status[$k] = $Extra[$k] }
        }
        # The medium is named in the note above the list, not here: which ISO to go and
        # find is a sentence, and the header column is half a screen narrower than the
        # list is.
        $status["online"] = $OnlineWarning

        $items = @(
            [pscustomobject]@{ Id = "iso";    Label = "Select FoD ISO...   browse for it on disk" }
            [pscustomobject]@{ Id = "online"; Label = $OnlineLabel }
            [pscustomobject]@{ Id = "skip";   Label = "Skip                do not install these on the VMs above" }
        )

        $note = {
            Write-Studio -Text "  Needs the $MediumLabel." -Key "fg"
            Write-Host ""
            foreach ($line in $Notes) {
                if ([string]::IsNullOrWhiteSpace($line)) { Write-Host "" }
                else { Write-Studio -Text "  $line" -Key "muted" }
            }
            if ($Notes.Count -gt 0) { Write-Host "" }
        }

        $choice = Show-Menu -Title $Title -StatusLines $status -Items $items -PreItems $note

        if ($null -eq $choice -or $choice -eq "online") {
            Write-Log "$Subject : installing online in the guest at first boot" -Tag "Info"
            return @{ Mode = "Online" }
        }
        if ($choice -eq "skip") {
            Write-Log "$Subject : skipped by choice" -Tag "Info"
            return @{ Mode = "Skip" }
        }

        $isoPath = Show-IsoFilePicker -StartPath (Get-DefaultIsoBrowseRoot) `
            -Title "Select the $MediumLabel" `
            -Subtitle "Enter opens folder / selects .iso - Esc goes back"
        if ($null -eq $isoPath) { continue }

        $isoRoot = $null
        try {
            $isoRoot = Mount-IsoAndGetRoot -IsoFilePath $isoPath
        }
        catch {
            Write-Log "Could not mount '$isoPath': $($_.Exception.Message)" -Tag "Error"
            continue
        }

        # Two layouts exist: Windows Server 2022+ keeps the payload under
        # LanguagesAndOptionalFeatures\, Windows Server 2019 and Windows 11 at the root.
        $source = Resolve-FodSourcePath -Path $isoRoot
        if ([string]::IsNullOrWhiteSpace($source)) {
            Write-Log "'$isoPath' has no Features on Demand payload - needs the Languages and Optional Features ISO" -Tag "Error"
            continue
        }

        Write-Log "$Subject : offline source '$source'" -Tag "Info"
        return @{ Mode = "Offline"; Source = $source; Iso = $isoPath }
    }
}

function Remove-OfflineProvisionedApps {
    param(
        [string]$OsRoot,
        # Custom pick from the studio (config removeApps). Empty means the full catalog -
        # the compact removeBuiltInApps: true shape. Ids outside the catalog are refused
        # with a warning rather than removed: this function only ever takes apps the
        # protected list has been weighed against.
        [string[]]$RemoveApps = @()
    )

    # $targetApps mirrors the studio's APP_REMOVAL_CATALOG (and old-scripts/
    # Remove-BuiltInApps.ps1's list) - keep the two identical or a ticked app silently
    # survives the bake. Provisioned-package removal only (Remove-AppxProvisionedPackage
    # -Path, against the offline-mounted disk) - there are no per-user AllUsers Appx instances to
    # clean up yet since no one has ever logged on to this VM's disk. Windows 11 client
    # images only (N and multi-session included), opt-in per VM.
    $protectedApps = @(
        "Microsoft.NET.Native.Framework.2.2", "Microsoft.VCLibs.140.00", "Microsoft.UI.Xaml.2.8",
        "Microsoft.VCLibs.140.00.UWPDesktop", "Microsoft.WindowsStore", "Microsoft.DesktopAppInstaller",
        "Microsoft.StorePurchaseApp", "Microsoft.WindowsTerminal", "Microsoft.ScreenSketch",
        "Microsoft.WindowsNotepad", "Microsoft.Windows.Photos"
    )
    $targetApps = @(
        "Microsoft.Microsoft3DViewer", "Microsoft.WindowsAlarms", "Microsoft.Copilot",
        "Microsoft.549981C3F5F10", "Microsoft.WindowsFeedbackHub", "Microsoft.ZuneVideo",
        "Microsoft.ZuneMusic", "Microsoft.GetHelp", "Microsoft.YourPhone",
        "microsoft.windowscommunicationsapps", "Microsoft.WindowsCamera", "Microsoft.WindowsMaps",
        "Microsoft.People", "Microsoft.MicrosoftSolitaireCollection", "Microsoft.MixedReality.Portal",
        "Microsoft.MicrosoftOfficeHub", "Microsoft.Office.OneNote", "Microsoft.OutlookForWindows",
        "Microsoft.MSPaint", "Microsoft.SkypeApp", "Microsoft.WindowsSoundRecorder",
        "Microsoft.MicrosoftStickyNotes", "Microsoft.BingWeather", "Microsoft.Getstarted",
        "Microsoft.Windows.DevHome", "Clipchamp.Clipchamp", "Microsoft.Todos", "Microsoft.BingNews",
        "MicrosoftCorporationII.QuickAssist", "Microsoft.PowerAutomateDesktop", "Microsoft.Whiteboard",
        "MicrosoftCorporationII.MicrosoftFamily", "Microsoft.MicrosoftJournal", "MicrosoftTeams",
        "Microsoft.BingSearch", "Microsoft.XboxApp", "Microsoft.GamingApp", "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxGameOverlay", "Microsoft.XboxIdentityProvider", "Microsoft.XboxSpeechToTextOverlay",
        "Microsoft.Xbox.TCUI", "MSTeams"
    )

    $wanted = @($RemoveApps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($wanted.Count -gt 0) {
        $unknown = @($wanted | Where-Object { $_ -notin $targetApps })
        foreach ($name in $unknown) {
            Write-Log "removeApps entry '$name' is not in the removal catalog - skipped" -Tag "Warn"
        }
        $targetApps = @($targetApps | Where-Object { $_ -in $wanted })
    }

    Write-Log "Removing $($targetApps.Count) provisioned app(s) offline, $($protectedApps.Count) protected" -Tag "Run"

    $provisioned = $null
    try {
        $provisioned = Get-AppxProvisionedPackage -Path $OsRoot -ErrorAction Stop
    }
    catch {
        Write-Log "Could not enumerate provisioned packages offline: $($_.Exception.Message)" -Tag "Error"
        return
    }

    foreach ($appName in $targetApps) {
        if ($appName -in $protectedApps) {
            continue
        }
        $hits = @($provisioned | Where-Object { $_.DisplayName -eq $appName })
        foreach ($pkg in $hits) {
            try {
                Remove-AppxProvisionedPackage -Path $OsRoot -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
                Write-Log "Removed provisioned app '$appName'" -Tag "Ok"
            }
            catch {
                Write-Log "Failed to remove provisioned app '$appName': $($_.Exception.Message)" -Tag "Error"
            }
        }
    }
}

function Set-OfflineGuestProvisionPayload {
    param(
        [string]$OsRoot,
        [object]$Server,
        [object]$Defaults,
        [bool]$IsClient,
        [string[]]$PendingWindowsFeatures,
        [string[]]$PendingRsatCapabilities,
        [string[]]$PendingCapabilities = @(),
        [bool]$IncludeManagementTools,
        # Name + pinned MAC per adapter, for the guest-side connection rename.
        [object[]]$NicPlan = @(),
        # Second pass over an already-written payload: the caller remounted the VHD to fold
        # in deferred features or Arc material. Same work, different sentence in the log, so
        # two identical lines do not read like a double injection.
        [switch]$Refresh
    )

    $arc = Get-EffectiveAzureArcConfig -Server $Server -Defaults $Defaults

    # Deferred domain join: the unattend carried no UnattendedJoin, so the guest owns the
    # join. The manifest gets the non-secret half, domain-join.json the credential (which
    # GuestProvision seals with DPAPI and wipes before the task ever fires).
    $deferredJoin = $null
    $resolvedJoin = Resolve-DomainJoinForServer -Server $Server
    if ($resolvedJoin -and $resolvedJoin.mode -eq "deferred") {
        $deferredJoin = $resolvedJoin
    }

    # Only the disks the guest has work to do on. Paths are host-side, so they are not
    # passed through - the guest matches on SCSI location and falls back to disk size.
    $dataDiskJobs = @(Get-ServerDataDiskPlan -Server $Server | Where-Object {
            $_.FileSystem -ne "None" -and -not [string]::IsNullOrWhiteSpace($_.Letter)
        })

    # Shared VHD Sets on this VM are never formatted by the guest - they belong to a guest
    # cluster. The count travels with the manifest purely so the guest refuses to fall back
    # to size matching, which could otherwise pick a shared disk.
    $sharedDiskCount = 0
    if ($script:ConfigRoot -and $script:ConfigRoot.vhdSets) {
        $sharedDiskCount = @(Select-VhdSetsForServers -VhdSets @($script:ConfigRoot.vhdSets) -Servers @($Server)).Count
    }

    # Adapter renaming counts: Hyper-V device naming never touches the guest's connection
    # names, so without this pass even a VM with no features, disks or Arc still comes up
    # calling its NICs Ethernet, Ethernet 2, ...
    $needsGuest = ($PendingWindowsFeatures.Count -gt 0) -or
                  ($PendingRsatCapabilities.Count -gt 0) -or
                  ($PendingCapabilities.Count -gt 0) -or
                  ($dataDiskJobs.Count -gt 0) -or
                  (@($NicPlan).Count -gt 0) -or
                  ($null -ne $arc) -or
                  ($null -ne $deferredJoin)

    $scriptsDir = Join-Path -Path $OsRoot -ChildPath "Windows\Setup\Scripts"
    $guestProvisionDir = Join-Path -Path $scriptsDir -ChildPath "GuestProvision"
    if (-not $needsGuest) {
        if (Test-Path -LiteralPath $guestProvisionDir) {
            Remove-Item -LiteralPath $guestProvisionDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        return
    }

    if (-not (Test-Path -LiteralPath $scriptsDir)) {
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $guestProvisionDir)) {
        New-Item -ItemType Directory -Path $guestProvisionDir -Force | Out-Null
    }

    $sourceScript = Join-Path -Path $PSScriptRoot -ChildPath "guest-files\GuestProvision.ps1"
    if (-not (Test-Path -LiteralPath $sourceScript)) {
        throw "GuestProvision guest script not found at '$sourceScript'"
    }
    Copy-Item -LiteralPath $sourceScript -Destination (Join-Path -Path $guestProvisionDir -ChildPath "GuestProvision.ps1") -Force

    # The join script rides along only when a deferred join is wanted; a stale copy or
    # credential from an earlier pass over the same payload is removed either way.
    $joinScriptTarget = Join-Path -Path $guestProvisionDir -ChildPath "DomainJoin.ps1"
    $joinSecretTarget = Join-Path -Path $guestProvisionDir -ChildPath "domain-join.json"
    foreach ($stale in @($joinScriptTarget, $joinSecretTarget)) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
    }
    if ($null -ne $deferredJoin) {
        $joinScriptSource = Join-Path -Path $PSScriptRoot -ChildPath "guest-files\DomainJoin.ps1"
        if (-not (Test-Path -LiteralPath $joinScriptSource)) {
            throw "DomainJoin guest script not found at '$joinScriptSource'"
        }
        Copy-Item -LiteralPath $joinScriptSource -Destination $joinScriptTarget -Force
    }

    $manifest = @{
        pendingWindowsFeatures  = @($PendingWindowsFeatures)
        pendingRsatCapabilities = @($PendingRsatCapabilities)
        pendingCapabilities     = @($PendingCapabilities)
        includeManagementTools  = $IncludeManagementTools
        sharedDiskCount         = $sharedDiskCount
        networkAdapters         = @($NicPlan | Where-Object { $null -ne $_ } | ForEach-Object {
                @{
                    name       = [string]$_.Name
                    macAddress = [string]$_.MacAddress
                }
            })
        dataDisks               = @($dataDiskJobs | ForEach-Object {
                @{
                    scsiLocation = [int]$_.Location
                    sizeGB       = [int]$_.SizeGB
                    letter       = [string]$_.Letter
                    fileSystem   = [string]$_.FileSystem
                    label        = [string]$_.Label
                }
            })
        azureArc                = $null
        domainJoin              = $null
    }
    if ($null -ne $deferredJoin) {
        $manifest.domainJoin = @{
            enabled = $true
            mode    = "deferred"
            domain  = [string]$deferredJoin.domain
            ouPath  = [string]$deferredJoin.ouPath
        }
    }
    if ($null -ne $arc) {
        $manifest.azureArc = @{
            enabled               = $true
            authMode              = [string]$arc.authMode
            subscriptionId        = [string]$arc.subscriptionId
            tenantId              = [string]$arc.tenantId
            resourceGroup         = [string]$arc.resourceGroup
            location              = [string]$arc.location
            servicePrincipalAppId = [string]$arc.servicePrincipalAppId
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $manifestJson = $manifest | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText((Join-Path -Path $guestProvisionDir -ChildPath "manifest.json"), $manifestJson, $utf8NoBom)

    if ($null -ne $arc -and $arc.authMode -eq "servicePrincipal") {
        $sp = Get-ArcServicePrincipalSecretMaterial -ArcConfig $arc
        if ($null -ne $sp) {
            $secretDoc = @{
                servicePrincipalAppId  = [string]$sp.servicePrincipalAppId
                servicePrincipalSecret = [string]$sp.servicePrincipalSecret
            } | ConvertTo-Json -Depth 3
            [System.IO.File]::WriteAllText((Join-Path -Path $guestProvisionDir -ChildPath "arc-deploy.json"), $secretDoc, $utf8NoBom)
            Write-Log "Injected Arc SP secret material for guest connect" -Tag "Run"
        }
    }

    if ($null -ne $deferredJoin) {
        $joinDoc = @{
            domain       = [string]$deferredJoin.domain
            ouPath       = [string]$deferredJoin.ouPath
            joinUser     = [string]$deferredJoin.joinUser
            joinPassword = [string]$deferredJoin.joinPassword
        } | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($joinSecretTarget, $joinDoc, $utf8NoBom)
        Write-Log "Injected credential + DomainJoin.ps1 for deferred join" -Tag "Run"
    }

    $setupCmd = @"
@echo off
REM GuestProvision - runs after specialize; a deferred domain join is registered here, not done here
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GuestProvision\GuestProvision.ps1" >nul 2>&1
"@
    [System.IO.File]::WriteAllText((Join-Path -Path $scriptsDir -ChildPath "SetupComplete.cmd"), $setupCmd, $utf8NoBom)
    if ($Refresh) {
        Write-Log "Refreshed GuestProvision payload + SetupComplete.cmd" -Tag "Ok"
    }
    else {
        Write-Log "Injected GuestProvision payload + SetupComplete.cmd" -Tag "Ok"
    }
}

# ---------------------------[ cloud-init seed ]---------------------------
#
# A Linux VM is provisioned the way a Windows VM is provisioned by an unattend.xml:
# with an answer file that first boot reads and then never looks at again. The format
# is cloud-init's NoCloud datasource - user-data, meta-data and optionally
# network-config on a volume labelled CIDATA.
#
# It cannot go INSIDE the gold the way an unattend.xml does. Set-OfflineUnattendFile
# mounts a Windows gold and writes into NTFS; a Linux gold is ext4, which Windows
# cannot write at all. So the answer file has to arrive on a second volume the guest
# reads at boot - that part is not a choice.
#
# What IS a choice is the medium, and it is a small FAT32 VHDX rather than an ISO.
# NoCloud takes either: its own code searches `TYPE=vfat` first and `TYPE=iso9660`
# second, then intersects with a case-insensitive LABEL=cidata. A disk is the better
# fit here - this project builds VHDX, a VM ends up with disks instead of a disc drive
# nobody asked for, and it needs no IMAPI2FS, no COM and no compiled IStream helper.
#
# NoCloud is used for every distribution here, which is the whole reason the golds are
# built from the GENERIC cloud images rather than the vendors' azure ones: an azure
# image pins cloud-init to the Azure datasource and would want an ovf-env.xml and a
# wire server that a lab does not have.

function Get-LinuxLocaleName {
    # de-DE -> de_DE.UTF-8. A copy of the function in New-Vhdx.ps1: neither script
    # dot-sources the other, which is why both already carry their own Write-Log.
    param([string]$LocaleTag)

    if ([string]::IsNullOrWhiteSpace($LocaleTag)) { return "en_US.UTF-8" }
    return ($LocaleTag -replace "-", "_") + ".UTF-8"
}

function Get-LinuxKeymap {
    # de-DE -> de, en-GB -> gb. Also a copy from New-Vhdx.ps1; keep the two in step.
    param([string]$LocaleTag)

    $overrides = @{
        "en-US" = "us"; "en-GB" = "gb"; "ja-JP" = "jp"; "pt-BR" = "br"
        "zh-CN" = "cn"; "zh-TW" = "tw"; "ko-KR" = "kr"; "cs-CZ" = "cz"
        "da-DK" = "dk"; "el-GR" = "gr"; "sv-SE" = "se"; "uk-UA" = "ua"
        "he-IL" = "il"; "sl-SI" = "si"; "et-EE" = "ee"
    }
    if ($overrides.ContainsKey($LocaleTag)) { return $overrides[$LocaleTag] }

    $parts = $LocaleTag -split "-"
    if ($parts.Count -ge 2) { return $parts[$parts.Count - 1].ToLowerInvariant() }
    return "us"
}

function Test-IsLinuxServer {
    # A row is Linux because the studio said so. The gold's sidecar manifest says the
    # same thing, but the row is what this script was handed and it is checked first.
    param([object]$Server)

    if ($null -eq $Server) { return $false }
    return ([string]$Server.osFamily).Trim().ToLowerInvariant() -eq "linux"
}

function ConvertTo-YamlSingleQuoted {
    # YAML single-quoted scalars escape one character - the quote itself, by doubling
    # it - and interpret nothing else. That makes them the right container for a
    # generated password, which may hold anything the generator produced.
    param([string]$Value)

    if ($null -eq $Value) { return "''" }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Format-MacWithColons {
    # Hyper-V hands a MAC over as 00155D0A0B0C; netplan matches on 00:15:5d:0a:0b:0c.
    param([string]$MacAddress)

    $clean = ([string]$MacAddress) -replace "[^0-9A-Fa-f]", ""
    if ($clean.Length -ne 12) { return "" }
    # All zeroes is what Hyper-V reports for an adapter whose dynamic address has not
    # been generated yet. It passes every format check and matches no adapter alive, so
    # it must never reach a netplan file.
    if ($clean -eq "000000000000") { return "" }
    $pairs = @()
    for ($i = 0; $i -lt 12; $i += 2) { $pairs += $clean.Substring($i, 2).ToLowerInvariant() }
    return ($pairs -join ":")
}

function Get-CloudInitMetaData {
    <#
        meta-data is the smaller half of a NoCloud seed and it has one job that matters:
        instance-id. cloud-init re-runs its per-instance modules when that value changes
        and skips them when it does not, so a rebuilt VM with a recycled instance-id
        would come up unprovisioned. It carries the build time for exactly that reason.
    #>
    param([string]$HostName)

    $stamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")
    return @"
instance-id: $HostName-$stamp
local-hostname: $HostName
"@
}

function ConvertTo-YamlDoubleQuoted {
    # A YAML double-quoted scalar. Needed because a shell command may contain single
    # quotes - a realm join does - and the single-quoted form cannot hold one without
    # doubling it, which the shell would then see.
    param([string]$Value)

    # .Replace, not -replace: the pattern of -replace is a regex and its replacement
    # has its own rules, so a backslash has to be written three different ways to mean
    # one thing. These are literal string swaps and read as what they are.
    $escaped = ([string]$Value).Replace("\", "\\")
    $escaped = $escaped.Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Get-LinuxDomainJoinPackages {
    <#
        realmd does the join and writes the sssd, krb5, nsswitch and PAM configuration;
        the rest is what has to be installed for it to be able to.

        oddjob and oddjob-mkhomedir USED to be in this list, on the belief that a
        domain user would otherwise log in with no home directory. That is RHEL
        thinking and it is wrong here. Checked on a joined Ubuntu 26.04 box: both
        packages install, oddjobd runs - and does nothing, because Debian and Ubuntu
        ship no pam-configs profile for it, so pam_oddjob_mkhomedir.so sits on disk
        unreferenced. What these distributions use is the plain kernel-side
        pam_mkhomedir.so, wired up by pam-auth-update. See the mkhomedir command in
        Get-LinuxDomainJoinCommands.
    #>
    return @(
        "realmd", "sssd", "sssd-tools", "adcli", "krb5-user",
        "libnss-sss", "libpam-sss", "samba-common-bin"
    )
}

function ConvertTo-ShellSingleQuoted {
    param([string]$Value)
    return "'" + (([string]$Value) -replace "'", "'\''") + "'"
}

function ConvertTo-LinuxGroupName {
    <#
        A domain group as a Linux box knows it.

        A realm join leaves sssd resolving names fully qualified, so "Domain Admins" is
        "Domain Admins@ad.example" to everything on the box and a line naming the short
        form matches nothing at all. A name with no @ gets the domain appended rather
        than being taken on trust.

        The down-level form is accepted and its prefix dropped. "AD\Domain Admins" is
        how Windows spells it and how somebody used to Windows will type it, but sssd
        never answers to a backslash - and a backslash reaching a sudoers file is worse
        than a name that does not resolve, because there it is an escape character.
    #>
    param([string]$Group, [string]$Domain)

    $name = ([string]$Group).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return "" }
    $slash = $name.LastIndexOf("\")
    if ($slash -ge 0) { $name = $name.Substring($slash + 1).Trim() }
    if ([string]::IsNullOrWhiteSpace($name)) { return "" }
    if ($name -notmatch "@" -and -not [string]::IsNullOrWhiteSpace($Domain)) {
        $name = "$name@$($Domain.Trim())"
    }
    return $name
}

function ConvertTo-SudoersGroupToken {
    <#
        A group as sudoers spells it: "%" then the name, with every space escaped -
        "Domain Admins" is one group, not two words, and sudoers only reads it that way
        when the space carries a backslash.
    #>
    param([string]$Group, [string]$Domain)

    $name = ConvertTo-LinuxGroupName -Group $Group -Domain $Domain
    if ([string]::IsNullOrWhiteSpace($name)) { return "" }
    return "%" + ($name -replace " ", "\ ")
}

function ConvertTo-RealmLoginUser {
    <#
        The join account as `realm join --user=` needs it: the BARE name, with any
        domain stripped off either end.

        This is not cosmetics. realm hands the value to `adcli --login-user`, and when
        it contains an @, Kerberos reads everything after it as the REALM - literally,
        and case-sensitively. A Kerberos realm is upper case, so "administrator@ad.example"
        asks for a ticket in the realm "ad.example" while the KDC answers for
        "AD.EXAMPLE", and the library rejects the reply it did not expect:

            ! Couldn't get kerberos ticket for: administrator@ad.example:
              KDC reply did not match expectations

        Observed on a real join, 2026-09-22. Nothing about it says "wrong user name",
        which is what made it worth this comment.

        The domain is not lost by stripping it: `realm join` already takes it as its
        final argument, and adcli derives the realm from that with the right case
        (--domain-realm AD.EXAMPLE). The down-level form is stripped for the same
        reason - "AD\Administrator" is a Windows spelling that means nothing to adcli.

        The studio's own placeholder is "Administrator@ad.example.invalid", because
        that IS right for the Windows path - Add-Computer takes a UPN. One field,
        two consumers, and only one of them may keep the domain.
    #>
    param([string]$User)

    $name = ([string]$User).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return "" }

    $slash = $name.LastIndexOf("\")
    if ($slash -ge 0) { $name = $name.Substring($slash + 1).Trim() }

    $at = $name.IndexOf("@")
    if ($at -ge 0) { $name = $name.Substring(0, $at).Trim() }

    return $name
}

function Get-LinuxArcCommands {
    <#
        The runcmd lines that install the Connected Machine agent and onboard the VM.

        The Windows path does this from GuestProvision.ps1, which never runs on a Linux
        VM - Set-LinuxProvisioning writes a cloud-init seed instead - so Arc was simply
        absent here until now.

        THE SECRET DOES NOT GO ON THE COMMAND LINE. Microsoft says so in the azcmagent
        reference, and on Linux it matters more than on Windows: cloud-init sends every
        runcmd's output to /var/log/cloud-init-output.log, which is world readable on
        these images, and a command line is visible in /proc while it runs. So the
        credentials are written to a 0600 file, passed with --config, and deleted in
        the same command whatever happens - the trap is what makes "whatever happens"
        true, including a connect that throws.

        Only servicePrincipal is supported. hostContext means "sign in with the host's
        own Az PowerShell session and call Connect-AzConnectedMachine", which is a
        Windows-and-PowerShell-Direct mechanism with no Linux counterpart; a config
        asking for it is left alone rather than half-honoured.

        Retries mirror the Windows path: exit 42 is most often RBAC or resource
        provider registration still propagating, which is inherently racy against a VM
        that boots and connects immediately.
    #>
    param([object]$ArcConfig)

    $commands = New-Object System.Collections.Generic.List[string]
    if ($null -eq $ArcConfig) { return $commands.ToArray() }
    if (([string]$ArcConfig.authMode) -ne "servicePrincipal") { return $commands.ToArray() }

    $secret = [string]$ArcConfig.servicePrincipalSecret
    if ([string]::IsNullOrWhiteSpace($secret)) { return $commands.ToArray() }

    # Keys are the flag names with the leading dashes removed - that is the whole
    # contract of --config, and it is why this is hand-built rather than ConvertTo-Json
    # over the config object, which carries fields azcmagent has never heard of.
    $settings = [ordered]@{
        "service-principal-id"     = [string]$ArcConfig.servicePrincipalAppId
        "service-principal-secret" = $secret
        "tenant-id"                = [string]$ArcConfig.tenantId
        "subscription-id"          = [string]$ArcConfig.subscriptionId
        "resource-group"           = [string]$ArcConfig.resourceGroup
        "location"                 = [string]$ArcConfig.location
    }
    $json = ($settings | ConvertTo-Json -Compress)

    $configPath = "/etc/azcmagent-connect.json"
    $installer = "/tmp/install_linux_azcmagent.sh"

    $install = "curl -sSL -o " + $installer + " https://aka.ms/azcmagent && bash " + $installer +
               " && echo ARC-AGENT-OK || echo ARC-AGENT-FAILED"
    [void]$commands.Add($install)

    # umask before the write, not chmod after it: chmod leaves a window in which the
    # file exists world readable, and this one holds a credential.
    $connect = "umask 077; printf '%s' " + (ConvertTo-ShellSingleQuoted -Value $json) + " > " + $configPath + "; " +
               "trap 'rm -f " + $configPath + "' EXIT INT TERM; " +
               "n=0; while [ `$n -lt 3 ]; do " +
               "/opt/azcmagent/bin/azcmagent connect --config " + $configPath + " && { echo ARC-CONNECT-OK; break; }; " +
               "n=`$((n+1)); " +
               "[ `$n -lt 3 ] && { echo ARC-CONNECT-RETRY; sleep `$((n*60)); } || echo ARC-CONNECT-FAILED; " +
               "done; rm -f " + $configPath
    [void]$commands.Add($connect)

    return $commands.ToArray()
}

function Get-LinuxDomainJoinCommands {
    <#
        The shell commands that join a domain and hand out sudo. Returned as plain
        strings; the caller quotes them for YAML.

        Order matters and every step earns its place:

        1. `realm join --unattended` with the password on stdin. Unattended is what
           makes realmd read stdin instead of prompting at a console nobody is watching.
        2. `getent group` for each group BEFORE it reaches sudoers. A group that does
           not resolve is a typo, or a name sssd spells differently - and the difference
           between saying so and saying nothing is this check.
        3. The sudoers file is built in a temp file, validated with `visudo -cf`, and
           only then installed. An invalid file under /etc/sudoers.d does not disable
           one rule; it can stop sudo running at all, on a machine whose only other
           account may be a domain account that cannot yet elevate.
        4. `realm permit` only when a login list was given. A plain realm join already
           permits every domain user, so an empty list means "leave that alone" rather
           than "permit nobody".
    #>
    param([object]$DomainJoin)

    $commands = New-Object System.Collections.Generic.List[string]

    $domain = ([string]$DomainJoin.domain).Trim()
    $joinUser = ([string]$DomainJoin.joinUser).Trim()
    $joinPassword = [string]$DomainJoin.joinPassword
    $ouPath = ([string]$DomainJoin.ouPath).Trim()
    if ([string]::IsNullOrWhiteSpace($domain)) { return $commands.ToArray() }

    # Bare name only - see ConvertTo-RealmLoginUser for what an @domain does to the
    # Kerberos realm.
    $realmUser = ConvertTo-RealmLoginUser -User $joinUser
    if ([string]::IsNullOrWhiteSpace($realmUser)) { return $commands.ToArray() }

    $joinArgs = "--unattended --user=" + (ConvertTo-ShellSingleQuoted -Value $realmUser)
    if (-not [string]::IsNullOrWhiteSpace($ouPath)) {
        $joinArgs += " --computer-ou=" + (ConvertTo-ShellSingleQuoted -Value $ouPath)
    }
    $join = "printf '%s' " + (ConvertTo-ShellSingleQuoted -Value $joinPassword) +
            " | realm join $joinArgs " + (ConvertTo-ShellSingleQuoted -Value $domain) +
            " && echo DOMAIN-JOIN-OK || echo DOMAIN-JOIN-FAILED"
    [void]$commands.Add($join)

    # A home directory on first login.
    #
    # sssd already knows WHERE it goes - realm join writes fallback_homedir into
    # sssd.conf, /home/%u@%d - but nothing creates it, so without this a domain user
    # logs in to a directory that is not there.
    #
    # Ubuntu and Debian do this with pam_mkhomedir.so through pam-auth-update rather
    # than with oddjob, which is why the oddjob packages are no longer installed. The
    # stock "mkhomedir" profile would work, but it leaves homes at the pam_mkhomedir
    # default of umask 0022 - drwxr-xr-x, every domain user able to read every other
    # one's home. So a profile of our own goes in beside it with umask=0077, matching
    # the mode a local user's home already gets.
    #
    # The tab between "optional" and the module name is what pam-auth-update's parser
    # expects; spaces there are not accepted.
    $profileLines = @(
        "Name: Create home directory on login (private)",
        "Default: yes",
        "Priority: 0",
        "Session-Type: Additional",
        "Session-Interactive-Only: yes",
        "Session:",
        "`toptional`t`t`tpam_mkhomedir.so umask=0077"
    )
    $profileWrite = "printf '%s\n'"
    foreach ($line in $profileLines) { $profileWrite += " " + (ConvertTo-ShellSingleQuoted -Value $line) }
    $profileWrite += " > /usr/share/pam-configs/mkhomedir-private"

    $mkhomedir = $profileWrite + "; " +
                 "DEBIAN_FRONTEND=noninteractive pam-auth-update --enable mkhomedir-private" +
                 " && echo MKHOMEDIR-OK || echo MKHOMEDIR-FAILED"
    [void]$commands.Add($mkhomedir)

    $sudoTokens = @()
    foreach ($group in @($DomainJoin.sudoGroups)) {
        $token = ConvertTo-SudoersGroupToken -Group $group -Domain $domain
        if (-not [string]::IsNullOrWhiteSpace($token)) { $sudoTokens += $token }
    }

    if ($sudoTokens.Count -gt 0) {
        $script = 'tmp=$(mktemp); '
        foreach ($token in $sudoTokens) {
            $plain = $token.Substring(1) -replace "\\ ", " "
            $script += "if getent group " + (ConvertTo-ShellSingleQuoted -Value $plain) + " >/dev/null 2>&1; then "
            $script += "printf '%s ALL=(ALL:ALL) ALL\n' " + (ConvertTo-ShellSingleQuoted -Value $token) + ' >> $tmp; '
            $script += "else echo " + (ConvertTo-ShellSingleQuoted -Value ("SUDO-GROUP-UNRESOLVED " + $plain)) + "; fi; "
        }
        $script += 'if [ -s $tmp ] && visudo -cf $tmp >/dev/null 2>&1; then '
        $script += 'install -m 0440 -o root -g root $tmp /etc/sudoers.d/90-domain-sudo && echo SUDO-OK; '
        $script += 'else echo SUDO-NOT-INSTALLED; fi; rm -f $tmp'
        [void]$commands.Add($script)
    }

    $loginNames = @()
    foreach ($group in @($DomainJoin.loginGroups)) {
        $name = ConvertTo-LinuxGroupName -Group $group -Domain $domain
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $loginNames += $name
    }

    if ($loginNames.Count -gt 0) {
        $permit = "realm deny --all; "
        foreach ($name in $loginNames) {
            $permit += "realm permit -g " + (ConvertTo-ShellSingleQuoted -Value $name) + "; "
        }
        $permit += "echo DOMAIN-LOGIN-RESTRICTED"
        [void]$commands.Add($permit)
    }

    return $commands.ToArray()
}

function Get-CloudInitUserData {
    <#
        The Linux answer file.

        The password is written in clear. That is deliberate and it is not a new
        exposure: the Windows path already stores its password as base64(UTF-16LE) in
        the unattend, which is reversible, and this seed is ejected and deleted after
        first boot the same way. Hashing it properly would need crypt(3) SHA-512, which
        Windows PowerShell 5.1 has no way to produce.

        ssh_pwauth defaults to on so the Hyper-V console and a password are a way back
        in when a key is wrong - on a lab VM that is worth more than the hardening - but
        it is the studio's Optional features card that decides, and a config written
        before that card existed has no opinion and gets the old behaviour.
    #>
    param(
        [object]$Server,
        [object]$Defaults,
        [string]$HostName,
        [string]$Language,
        [string]$Locale,
        [string]$Keymap,
        [string]$TimeZone
    )

    $userName = ([string]$Server.localUserName).Trim()
    if ([string]::IsNullOrWhiteSpace($userName)) { $userName = "admin" }
    $password = [string]$Server.localUserPassword

    $sshKey = ([string]$Server.sshAuthorizedKey).Trim()
    if ([string]::IsNullOrWhiteSpace($sshKey) -and $Defaults) {
        $sshKey = ([string]$Defaults.sshAuthorizedKey).Trim()
    }

    # The join is a property of the row, resolved by the studio's export into a plain
    # domainJoin block - the same one the Windows path reads. mode "deferred" is
    # Windows only: it exists because a Windows join has to survive a reboot inside
    # specialize, and cloud-init has no equivalent problem.
    $domainJoin = $null
    if ($Server.domainJoin -and [bool]$Server.domainJoin.enabled -and
        -not [string]::IsNullOrWhiteSpace([string]$Server.domainJoin.domain)) {
        $domainJoin = $Server.domainJoin
    }

    # Resolved through the same function the Windows path uses, so the catalogue
    # lookup, the legacy defaults block and the validation are all one implementation.
    # It throws on an enabled-but-incomplete block, which is what we want: a VM that
    # was meant to be Arc-enabled and silently is not is worse than a failed build.
    $arcConfig = $null
    try {
        $arcConfig = Get-EffectiveAzureArcConfig -Server $Server -Defaults $Defaults
    }
    catch {
        Write-Log "Azure Arc for '$HostName': $($_.Exception.Message)" -Tag "Error"
        throw
    }
    if ($null -ne $arcConfig -and ([string]$arcConfig.authMode) -ne "servicePrincipal") {
        # hostContext signs in with the HOST's Az PowerShell session and calls
        # Connect-AzConnectedMachine over PowerShell Direct - Windows only, and there is
        # no Linux equivalent to fall back to.
        Write-Log "Azure Arc for '$HostName' asks for $($arcConfig.authMode) auth, which is Windows only - skipped" -Tag "Warn"
        $arcConfig = $null
    }

    $packages = @()
    if ($null -ne $arcConfig) {
        # The install script is fetched with curl. Ubuntu's cloud image has it, Debian's
        # generic one does not always, and a missing curl would fail the onboarding for
        # a reason that has nothing to do with Arc.
        $packages += "curl"
    }
    if ($null -ne $domainJoin) {
        # Installed per VM rather than baked, by decision: a gold stays lean and only
        # the machines that actually join pay for it. The cost is that a joining VM
        # needs the package mirror AND the domain controller reachable on first boot.
        foreach ($package in @(Get-LinuxDomainJoinPackages)) { $packages += $package }
    }
    foreach ($package in @($Server.packages)) {
        $trimmed = ([string]$package).Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $packages += $trimmed }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("#cloud-config")
    [void]$lines.Add("hostname: $HostName")
    [void]$lines.Add("preserve_hostname: false")
    # cloud-init's `locale` module writes LANG, and on glibc LANG decides what the
    # system SAYS - messages, logs, man pages - as well as how it formats. That is one
    # setting for two questions, and the answers differ: German dates with English error
    # messages is the normal case. So the module gets the LANGUAGE, and the format
    # locale is applied further down through the LC_* family, which LANG does not touch.
    if (-not [string]::IsNullOrWhiteSpace($Language)) { [void]$lines.Add("locale: $Language") }
    if (-not [string]::IsNullOrWhiteSpace($TimeZone)) { [void]$lines.Add("timezone: $TimeZone") }
    if (-not [string]::IsNullOrWhiteSpace($Keymap)) {
        [void]$lines.Add("keyboard:")
        [void]$lines.Add("  layout: $Keymap")
    }

    [void]$lines.Add("users:")
    [void]$lines.Add("  - name: $userName")
    [void]$lines.Add("    groups: [sudo]")
    [void]$lines.Add("    shell: /bin/bash")
    [void]$lines.Add("    sudo: 'ALL=(ALL) NOPASSWD:ALL'")
    [void]$lines.Add("    lock_passwd: false")
    if (-not [string]::IsNullOrWhiteSpace($sshKey)) {
        [void]$lines.Add("    ssh_authorized_keys:")
        [void]$lines.Add("      - " + (ConvertTo-YamlSingleQuoted -Value $sshKey))
    }

    if (-not [string]::IsNullOrWhiteSpace($password)) {
        [void]$lines.Add("chpasswd:")
        [void]$lines.Add("  expire: false")
        [void]$lines.Add("  users:")
        [void]$lines.Add("    - name: $userName")
        [void]$lines.Add("      password: " + (ConvertTo-YamlSingleQuoted -Value $password))
        [void]$lines.Add("      type: text")
    }
    # Stated out loud, and outside the password block: cloud-init's own default differs
    # between images, so the seed says what it wants rather than inheriting an answer.
    [void]$lines.Add("ssh_pwauth: true")

    if ($packages.Count -gt 0) {
        [void]$lines.Add("package_update: true")
        [void]$lines.Add("packages:")
        foreach ($package in $packages) { [void]$lines.Add("  - " + (ConvertTo-YamlSingleQuoted -Value $package)) }
    }

    # The LC_* format family. cloud-init has no module for the language/format split, so
    # this is runcmd: generate the format locale (it is not the one the locale module
    # just generated) and point the nine format variables at it. LC_MESSAGES is
    # deliberately absent - leaving it unset is what keeps messages on LANG.
    #
    # Both distributions carry `locales`, so locale-gen needs no network. Ubuntu also
    # carries console-setup, keyboard-configuration and kbd; Debian's genericcloud image
    # carries none of them, which is why the Debian gold installs them during its bake.
    # One runcmd block, whatever fills it - cloud-init takes the key once and a second
    # `runcmd:` in the same document silently replaces the first.
    $runCommands = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Locale) -and $Locale -ne $Language) {
        $formatVariables = @("LC_TIME","LC_NUMERIC","LC_MONETARY","LC_PAPER","LC_MEASUREMENT",
                             "LC_ADDRESS","LC_TELEPHONE","LC_NAME","LC_IDENTIFICATION")
        $assignments = ($formatVariables | ForEach-Object { "$_=$Locale" }) -join " "
        [void]$runCommands.Add("locale-gen $Locale || true")
        [void]$runCommands.Add("update-locale $assignments")
    }

    # Last, and after the packages that cloud-init installs earlier in this same file:
    # realm join cannot run until realmd exists, and the locale work above has no
    # opinion about any of it.
    if ($null -ne $domainJoin) {
        foreach ($command in @(Get-LinuxDomainJoinCommands -DomainJoin $domainJoin)) {
            [void]$runCommands.Add($command)
        }
    }

    # After the join, deliberately. A join can disturb name resolution and it restarts
    # sssd; onboarding a machine whose identity has just changed underneath it is a
    # worse order than doing it once the box has settled.
    if ($null -ne $arcConfig) {
        foreach ($command in @(Get-LinuxArcCommands -ArcConfig $arcConfig)) {
            [void]$runCommands.Add($command)
        }
    }
    if ($runCommands.Count -gt 0) {
        [void]$lines.Add("runcmd:")
        # Double-quoted, not single: a realm join carries single-quoted shell words
        # of its own, and the single-quoted YAML form cannot hold one without doubling
        # it - which the shell would then see as part of the command.
        foreach ($command in $runCommands) { [void]$lines.Add("  - [ sh, -c, " + (ConvertTo-YamlDoubleQuoted -Value $command) + " ]") }
    }

    # The gold is grown to its full size by New-Vhdx, but the partition and the
    # filesystem inside it are still the cloud image's. These two modules are on by
    # default in every image used here; naming them makes the intent explicit and
    # survives an image that ever changes its mind.
    [void]$lines.Add("growpart:")
    [void]$lines.Add("  mode: auto")
    [void]$lines.Add("  devices: ['/']")
    [void]$lines.Add("resize_rootfs: true")

    # Power off when provisioning is finished, so the host has an unambiguous signal
    # that the seed has been read and can be taken away. power_state_change runs LAST
    # in cloud_final_modules and its frequency is per-instance, so this happens once,
    # on the first boot of this machine, and never again.
    #
    # It is the only signal that needs no channel: no serial pipe to read, no heartbeat
    # to interpret, and nothing that depends on hyperv-daemons being installed - so it
    # works even on a gold whose bake never finished.
    [void]$lines.Add("power_state:")
    [void]$lines.Add("  mode: poweroff")
    [void]$lines.Add("  timeout: 30")
    [void]$lines.Add("  condition: true")

    return ($lines -join "`n") + "`n"
}

function Get-CloudInitNetworkConfig {
    <#
        netplan v2, which NoCloud reads from a THIRD file called network-config - not
        from inside user-data. Getting that wrong is silent: cloud-init ignores the
        stanza and the VM comes up on DHCP.

        The adapter is matched by MAC rather than by name because the kernel's name for
        it is not knowable from here.

        Returns an empty string when there is no static address to set, and no file is
        written - the image's own DHCP default is then left alone.
    #>
    param(
        [object]$Server,
        [string]$MacAddress
    )

    $ipAddress = ([string]$Server.ipAddress).Trim()
    if ([string]::IsNullOrWhiteSpace($ipAddress)) { return "" }

    $prefix = 24
    if ($Server.prefixLength) { $prefix = [int]$Server.prefixLength }
    $gateway = ([string]$Server.defaultGateway).Trim()

    $dns = @()
    foreach ($server in @($Server.dnsServers)) {
        $trimmed = ([string]$server).Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $dns += $trimmed }
    }

    $mac = Format-MacWithColons -MacAddress $MacAddress

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("version: 2")
    [void]$lines.Add("ethernets:")
    [void]$lines.Add("  primary:")
    [void]$lines.Add("    match:")
    if (-not [string]::IsNullOrWhiteSpace($mac)) {
        [void]$lines.Add("      macaddress: '$mac'")
    }
    else {
        # Without a match netplan reads the key `primary` as the INTERFACE NAME, finds
        # no such device and silently configures nothing - the VM then boots with no
        # address and nothing to say about it. Matching every ethernet is the honest
        # fallback: these VMs are built with one adapter, and a machine that has more
        # gets its MAC from Get-VmNicMacForUnattend, which pins one before reading it.
        [void]$lines.Add("      name: 'e*'")
    }
    [void]$lines.Add("    dhcp4: false")
    [void]$lines.Add("    dhcp6: false")
    [void]$lines.Add("    addresses: ['$ipAddress/$prefix']")
    if (-not [string]::IsNullOrWhiteSpace($gateway)) {
        # `gateway4` is deprecated and newer netplan warns on it or drops it; a default
        # route says the same thing and keeps working.
        [void]$lines.Add("    routes:")
        [void]$lines.Add("      - to: default")
        [void]$lines.Add("        via: '$gateway'")
    }
    if ($dns.Count -gt 0) {
        [void]$lines.Add("    nameservers:")
        [void]$lines.Add("      addresses: [" + (($dns | ForEach-Object { "'$_'" }) -join ", ") + "]")
    }

    return ($lines -join "`n") + "`n"
}

# ---------------------------[ Progress bar ]---------------------------
#
# Copies of New-Vhdx.ps1's bar. Neither script dot-sources the other - they
# already each carry their own Write-Log - so these travel together and have to
# be kept in step.

function Format-ByteSize {
    param([int64]$Bytes)

    if ($Bytes -ge 1073741824) { return ("{0:N1} GiB" -f ($Bytes / 1073741824)) }
    if ($Bytes -ge 1048576)    { return ("{0:N1} MiB" -f ($Bytes / 1048576)) }
    if ($Bytes -ge 1024)       { return ("{0:N1} KiB" -f ($Bytes / 1024)) }
    return "$Bytes B"
}

function Format-Duration {
    param([double]$Seconds)

    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) { return "--:--" }
    if ($Seconds -gt 359999) { return "99:59:59" }

    $span = [System.TimeSpan]::FromSeconds([Math]::Round($Seconds))
    if ($span.TotalHours -ge 1) { return ("{0}:{1:00}:{2:00}" -f [int]$span.TotalHours, $span.Minutes, $span.Seconds) }
    return ("{0}:{1:00}" -f $span.Minutes, $span.Seconds)
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

function Copy-FileWithProgress {
    <#
        Copy-Item with the download bar in front of it.

        Worth the code for one reason: the files this copies are golds. A non-
        differencing VM copies a 32 GB disk, and Copy-Item says nothing at all while it
        does - so a build that is working looks identical to a build that has hung, for
        several minutes at a time.

        Same loop as the downloader and the same bar: read a buffer, write it, redraw on
        a clock rather than per buffer. 4 MiB rather than the downloader's 256 KiB,
        because this is disk to disk and the syscalls cost more than the bytes.

        Falls back to Copy-Item when the console cannot draw - and on failure deletes the
        half-written destination, so a copy that died cannot be mistaken for a disk.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Activity = "copying",
        [int]$BufferSize = 4194304
    )

    if (-not (Test-MenuHostSupported)) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        return
    }

    $sourceInfo = Get-Item -LiteralPath $Source -ErrorAction Stop
    $totalBytes = [int64]$sourceInfo.Length

    $directory = Split-Path -Path $Destination -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $inStream = $null
    $outStream = $null
    $completed = $false
    try {
        $inStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $outStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $buffer = [byte[]]::new($BufferSize)
        $copied = [int64]0
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $lastDraw = [double]0

        $sampleTimes = New-Object System.Collections.ArrayList
        $sampleBytes = New-Object System.Collections.ArrayList
        $windowSeconds = 3.0

        Write-Host ""
        Write-DownloadProgressLine -BytesRead 0 -TotalBytes $totalBytes -BytesPerSecond 0 -Activity $Activity

        while ($true) {
            $read = $inStream.Read($buffer, 0, $BufferSize)
            if ($read -le 0) { break }
            $outStream.Write($buffer, 0, $read)
            $copied += $read

            $now = $clock.Elapsed.TotalSeconds
            [void]$sampleTimes.Add($now)
            [void]$sampleBytes.Add($copied)
            while ($sampleTimes.Count -gt 2 -and ($now - $sampleTimes[0]) -gt $windowSeconds) {
                $sampleTimes.RemoveAt(0)
                $sampleBytes.RemoveAt(0)
            }

            if ((($now - $lastDraw) * 1000) -ge 80) {
                $lastDraw = $now
                $rate = 0.0
                $span = $now - $sampleTimes[0]
                if ($span -gt 0.2) { $rate = ($copied - $sampleBytes[0]) / $span }
                Write-DownloadProgressLine -BytesRead $copied -TotalBytes $totalBytes -BytesPerSecond $rate -Activity $Activity
            }
        }

        $outStream.Flush()
        $clock.Stop()

        $average = 0.0
        if ($clock.Elapsed.TotalSeconds -gt 0) { $average = $copied / $clock.Elapsed.TotalSeconds }
        Write-DownloadProgressLine -BytesRead $copied -TotalBytes $totalBytes -BytesPerSecond $average -Activity $Activity -Final
        Write-Host ""

        if ($copied -ne $totalBytes) {
            throw "Copied $copied of $totalBytes bytes from '$Source'"
        }
        $completed = $true
        Write-Log "Copied $(Format-ByteSize -Bytes $copied) in $(Format-Duration -Seconds $clock.Elapsed.TotalSeconds) ($(Format-ByteSize -Bytes ([int64]$average))/s)" -Tag "ok"
    }
    finally {
        if ($inStream) { $inStream.Dispose() }
        if ($outStream) { $outStream.Dispose() }
        # A half-copied gold is worse than no gold: it is a file that looks like a disk.
        if (-not $completed -and (Test-Path -LiteralPath $Destination)) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-CloudInitSeedDisk {
    <#
        Writes the cloud-init seed as a small FAT32 VHDX instead of an ISO.

        cloud-init's NoCloud datasource does not care which of the two it gets. Its own
        code looks for `TYPE=vfat` FIRST and `TYPE=iso9660` second, then intersects that
        with a case-insensitive `LABEL=cidata` - so a formatted disk and a mastered disc
        are equally valid seeds. Given the choice, a VHDX is the better one here: this
        project produces VHDX, a VM ends up with disks rather than a disc drive nobody
        asked for, and it needs no IMAPI2FS, no COM and no compiled IStream helper.

        The label must be exactly CIDATA. Without it the datasource does not recognise
        the volume and the VM boots unprovisioned, with nothing said about why.

        64 MB because Windows will not format FAT32 much below 32 MB, and a dynamic
        VHDX only occupies what it holds - which for three small text files is nothing.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$VhdxPath,
        [Parameter(Mandatory = $true)][string]$UserData,
        [Parameter(Mandatory = $true)][string]$MetaData,
        [string]$NetworkConfig
    )

    $directory = Split-Path -Path $VhdxPath -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $VhdxPath) { Remove-Item -LiteralPath $VhdxPath -Force }

    $mounted = $false
    try {
        New-VHD -Path $VhdxPath -SizeBytes 64MB -Dynamic -ErrorAction Stop | Out-Null

        $disk = Mount-VHD -Path $VhdxPath -Passthru -ErrorAction Stop
        $mounted = $true

        # MBR, not GPT: this is a data volume the firmware never boots from, and MBR
        # keeps it to one partition with no reserved space to reason about.
        Initialize-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction Stop | Out-Null
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
        $null = Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel "CIDATA" `
            -Confirm:$false -Force -ErrorAction Stop

        # Re-read it: the drive letter is assigned by the partition call above, and the
        # object captured before the format does not always carry it.
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.DriveLetter } | Select-Object -First 1
        if (-not $partition -or -not $partition.DriveLetter) {
            throw "The seed volume was created but Windows assigned it no drive letter"
        }
        $root = "$($partition.DriveLetter):\"

        # LF endings and no BOM. cloud-init parses YAML, and a BOM at the top of
        # user-data makes the first line unparseable.
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $root "user-data"), ($UserData -replace "`r`n", "`n"), $encoding)
        [System.IO.File]::WriteAllText((Join-Path $root "meta-data"), ($MetaData -replace "`r`n", "`n"), $encoding)
        if (-not [string]::IsNullOrWhiteSpace($NetworkConfig)) {
            [System.IO.File]::WriteAllText((Join-Path $root "network-config"), ($NetworkConfig -replace "`r`n", "`n"), $encoding)
        }

        Write-Log "Wrote cloud-init seed disk '$VhdxPath'" -Tag "Run"
        return $VhdxPath
    }
    finally {
        if ($mounted) {
            # Always, and before anything else touches the file: a seed still mounted on
            # the host is a file the VM cannot be given.
            try { Dismount-VHD -Path $VhdxPath -ErrorAction Stop }
            catch { Write-Log "Could not dismount the seed disk '$VhdxPath': $($_.Exception.Message)" -Tag "Error" }
        }
    }
}

function Set-CloudInitSeedOnVm {
    <#
        Attaches the seed disk. It is left in place rather than detached after the first
        boot: cloud-init reads it on every boot and re-reading a seed whose instance-id
        has not changed is a no-op, while pulling it out from under a VM that has not
        finished booting is not.

        Any DVD drive this VM picked up is removed. Nothing on the Linux path needs one
        now that the seed is a disk, and an empty drive on every VM is clutter that
        invites the question of what it was for.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$SeedPath
    )

    $attached = @(Get-VMHardDiskDrive -VMName $VmName -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $SeedPath })
    if ($attached.Count -eq 0) {
        Add-VMHardDiskDrive -VMName $VmName -Path $SeedPath -ErrorAction Stop
    }

    foreach ($drive in @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue)) {
        try { Remove-VMDvdDrive -VMDvdDrive $drive -ErrorAction Stop }
        catch { Write-Log "DVD drive '$VmName': $($_.Exception.Message)" -Tag "Debug" }
    }

    Write-Log "Attached the cloud-init seed disk to '$VmName'" -Tag "Run"
}

function Complete-LinuxFirstBoot {
    <#
        Runs the provisioning boot, then takes the seed away.

        The VM is started whatever the studio's "start after create" says, because that
        toggle decides whether a FINISHED machine is left running - not whether it gets
        provisioned at all. A Linux VM that is never started is a VM that never read its
        answer file, which is not a useful thing to hand somebody.

        cloud-init powers the machine off when it is done, and that is the signal: no
        serial pipe, no heartbeat, nothing that needs hyperv-daemons. When it arrives,
        the seed disk is detached and deleted - it holds the local password in clear,
        and a VM that has finished with it should not carry it around.

        If it never arrives the seed is LEFT ALONE and the run says so. A VM that can
        still be fixed is worth more than a tidy disk list.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$SeedPath,
        [int]$TimeoutMinutes = 20
    )

    Write-Log "Starting '$VmName' for its provisioning boot" -Tag "Run"
    Start-VmWithRetry -VmName $VmName

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastReport = Get-Date
    $poweredOff = $false

    while ((Get-Date) -lt $deadline) {
        $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($null -eq $vm) {
            Write-Log "'$VmName' disappeared while waiting for its provisioning boot" -Tag "Error"
            return $false
        }
        if ($vm.State -eq "Off") { $poweredOff = $true; break }

        if (((Get-Date) - $lastReport).TotalSeconds -ge 60) {
            $lastReport = Get-Date
            Write-Log "Waiting for '$VmName' to provision and power off" -Tag "Info"
        }
        Start-Sleep -Seconds 5
    }

    if (-not $poweredOff) {
        Write-Log "'$VmName' did not power off within $TimeoutMinutes minute(s) - cloud-init may still be working, or may have failed" -Tag "Warn"
        Write-Log "Seed disk still attached at '$SeedPath' - it holds this VM's password in clear, remove it once the VM is good" -Tag "Warn"
        return $false
    }

    Write-Log "'$VmName' finished provisioning" -Tag "Ok"

    try {
        foreach ($drive in @(Get-VMHardDiskDrive -VMName $VmName -ErrorAction Stop | Where-Object { $_.Path -eq $SeedPath })) {
            Remove-VMHardDiskDrive -VMHardDiskDrive $drive -ErrorAction Stop
        }
        Write-Log "Detached the seed disk from '$VmName'" -Tag "Run"
    }
    catch {
        Write-Log "Could not detach the seed disk from '$VmName': $($_.Exception.Message)" -Tag "Error"
        return $false
    }

    # Hyper-V holds the file for a moment after detaching it; this helper exists for
    # exactly that and is already used elsewhere in this script.
    $null = Wait-VhdFileReleased -VhdPath $SeedPath
    try {
        if (Test-Path -LiteralPath $SeedPath) {
            Remove-Item -LiteralPath $SeedPath -Force -ErrorAction Stop
            Write-Log "Deleted the seed disk '$SeedPath'" -Tag "Run"
        }
    }
    catch {
        Write-Log "Could not delete the seed disk '$SeedPath': $($_.Exception.Message) - it still holds the VM's password" -Tag "Warn"
    }

    return $true
}

function Set-LinuxProvisioning {
    <#
        The Linux replacement for Set-OfflineUnattendFile: renders the seed, writes the
        ISO beside the VM's own files and attaches it.

        Region settings come from the gold's sidecar manifest when the config does not
        override them - the same rule the Windows path uses, for the same reason: the
        gold was baked with a locale and a machine built from it should not silently
        disagree with it.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Server,
        [Parameter(Mandatory = $true)][object]$Defaults,
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$SeedDirectory,
        [string]$GoldPath,
        [string]$NicMacAddress
    )

    $language = ""
    $locale = ""
    $keymap = ""
    $timeZone = ""

    if (-not [string]::IsNullOrWhiteSpace($GoldPath)) {
        $manifestPath = "$GoldPath.json"
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($manifest.language)       { $language = Get-LinuxLocaleName -LocaleTag ([string]$manifest.language) }
                if ($manifest.locale)         { $locale   = Get-LinuxLocaleName -LocaleTag ([string]$manifest.locale) }
                if ($manifest.keyboardLayout) { $keymap   = Get-LinuxKeymap     -LocaleTag ([string]$manifest.keyboardLayout) }
                if ($manifest.timeZone)       { $timeZone = [string]$manifest.timeZone }
            }
            catch {
                Write-Log "Could not read the gold manifest '$manifestPath': $($_.Exception.Message)" -Tag "Warn"
            }
        }
    }

    # A gold built before language became its own field has a locale and no language.
    # Falling back to the locale reproduces the old behaviour rather than silently
    # switching that machine to English.
    if ([string]::IsNullOrWhiteSpace($language)) { $language = $locale }

    $userData = Get-CloudInitUserData -Server $Server -Defaults $Defaults -HostName $HostName `
        -Language $language -Locale $locale -Keymap $keymap -TimeZone $timeZone
    $metaData = Get-CloudInitMetaData -HostName $HostName
    $networkConfig = Get-CloudInitNetworkConfig -Server $Server -MacAddress $NicMacAddress

    if ([string]::IsNullOrWhiteSpace($networkConfig)) {
        Write-Log "No static address for '$HostName' - DHCP" -Tag "Info"
    }

    $seedPath = Join-Path -Path $SeedDirectory -ChildPath ("{0}-seed.vhdx" -f $VmName)
    $null = New-CloudInitSeedDisk -VhdxPath $seedPath -UserData $userData -MetaData $metaData -NetworkConfig $networkConfig
    Set-CloudInitSeedOnVm -VmName $VmName -SeedPath $seedPath
    return $seedPath
}

function Set-OfflineUnattendFile {
    param(
        [string]$VhdPath,
        [string]$UnattendContent,
        [string]$VmName,
        [bool]$IsClient = $false,
        [object]$Server = $null,
        [object]$Defaults = $null,
        [object[]]$NicPlan = @()
    )

    Test-UnattendXml -UnattendContent $UnattendContent -Label "'$VmName'"

    Clear-StaleVhdAttachment -VhdPath $VhdPath

    Write-Log "Injecting unattend into '$VhdPath'" -Tag "Run"
    $mounted = $false
    try {
        $disk = Mount-VHD -Path $VhdPath -Passthru | Get-Disk
        $mounted = $true
        $osVolume = Get-Partition -DiskNumber $disk.Number |
            Get-Volume |
            Where-Object { $_.FileSystem -eq "NTFS" -and $_.DriveLetter } |
            Sort-Object -Property Size -Descending |
            Select-Object -First 1

        if ($null -eq $osVolume) {
            throw "Could not locate the OS volume after mounting '$VhdPath'"
        }

        $osRoot = "$($osVolume.DriveLetter):"

        Clear-OfflineUnattendRegistryPointer -OsRoot $osRoot

        $conflictPaths = @(
            "$osRoot\Windows\Panther\Unattend",
            "$osRoot\Windows\System32\Sysprep\unattend.xml",
            "$osRoot\Windows\Deploy\unattend.xml",
            "$osRoot\unattend.xml",
            "$osRoot\autounattend.xml"
        )
        foreach ($conflict in $conflictPaths) {
            if (Test-Path -LiteralPath $conflict) {
                Write-Log "Removing conflicting answer file location '$conflict'" -Tag "Run"
                Remove-Item -LiteralPath $conflict -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $panther = "$osRoot\Windows\Panther"
        if (Test-Path -LiteralPath $panther) {
            Get-ChildItem -LiteralPath $panther -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(unattend|autounattend)' } |
                ForEach-Object {
                    Write-Log "Removing leftover '$($_.FullName)'" -Tag "Run"
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
        }
        else {
            New-Item -ItemType Directory -Path $panther -Force | Out-Null
        }

        $unattendPath = Join-Path -Path $panther -ChildPath "unattend.xml"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($unattendPath, $UnattendContent, $utf8NoBom)
        Write-Log "Wrote '$unattendPath'" -Tag "Info"

        if ($IsClient) {
            Set-OfflineClientOobeBypass -OsRoot $osRoot
        }

        $scriptsDir = Join-Path -Path $osRoot -ChildPath "Windows\Setup\Scripts"
        $obsoleteScripts = @(
            (Join-Path -Path $scriptsDir -ChildPath "SetupComplete.cmd"),
            (Join-Path -Path $scriptsDir -ChildPath "SetupComplete.ps1"),
            (Join-Path -Path $scriptsDir -ChildPath "ClientSpecialize.ps1"),
            (Join-Path -Path $scriptsDir -ChildPath "ClientSetupComplete.ps1"),
            (Join-Path -Path $scriptsDir -ChildPath "ClientFirstLogon.ps1")
        )
        foreach ($p in $obsoleteScripts) {
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }

        $pendingFeatures = @()
        $pendingRsat = @()
        $pendingCapabilities = @()
        $includeMgmt = $true
        if ($null -ne $Server) {
            if ($IsClient) {
                $rsatNames = @()
                if ($Server.rsatCapabilities) {
                    $rsatNames = @($Server.rsatCapabilities | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" } | Select-Object -Unique)
                }
                $rsatPlan = Get-RsatPlan
                if ($rsatPlan -and $rsatPlan.Mode -eq "Skip") {
                    $rsatNames = @()
                }
                $rsatSource = ""
                $rsatOnline = $false
                if ($rsatPlan) {
                    if ($rsatPlan.Mode -eq "Online") { $rsatOnline = $true }
                    elseif ($rsatPlan.Mode -eq "Offline") { $rsatSource = [string]$rsatPlan.Source }
                }
                $pendingRsat = @(Install-OfflineRsatCapabilities -OsRoot $osRoot -CapabilityNames $rsatNames `
                    -Source $rsatSource -ForceOnline:$rsatOnline)

                # In-box optional features. No FoD plan applies - nothing here is downloaded,
                # so there is no medium to choose and no online fallback to defer to.
                $clientFeatureNames = @()
                if ($Server.clientFeatures) {
                    $clientFeatureNames = @($Server.clientFeatures | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" } | Select-Object -Unique)
                }
                Enable-OfflineClientFeatures -OsRoot $osRoot -FeatureNames $clientFeatureNames
                if ($null -ne $Server.includeManagementTools) {
                    $includeMgmt = [bool]$Server.includeManagementTools
                }

                # Client-only, opt-in per VM. Double-gated on the imageId shape (not just
                # $IsClient) - this must never run against a Server image. Every Windows
                # client edition qualifies, N and multi-session included: they carry the
                # same provisioned app packages the removal targets.
                $imageIdForApps = ([string]$Server.imageId).ToLowerInvariant()
                # removeBuiltInApps: true takes the whole catalog; removeApps lists a custom
                # pick and implies the removal on its own - the studio exports one or the other.
                $removeAppsList = @($Server.removeApps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if (([bool]$Server.removeBuiltInApps -or $removeAppsList.Count -gt 0) -and $imageIdForApps -match "^w1[01]-") {
                    Remove-OfflineProvisionedApps -OsRoot $osRoot -RemoveApps $removeAppsList
                }
            }
            else {
                # Install-WindowsFeature -Vhd requires the VHD to be dismounted.
                # Collect names now; install after Dismount in the caller path via flag.
                # We install offline AFTER this mount session ends.
                #
                # Capabilities are different - Add-WindowsCapability takes the mounted
                # OS root, so Server Core App Compat is installed right here.
                if (Test-WantsServerCoreAppCompat -Server $Server) {
                    $plan = Get-AppCompatPlan -Server $Server
                    $planSource = ""
                    $planOnline = $false
                    if ($plan) {
                        if ($plan.Mode -eq "Online") { $planOnline = $true }
                        elseif ($plan.Mode -eq "Offline") { $planSource = [string]$plan.Source }
                    }
                    $pendingCapabilities = @(Install-OfflineServerCoreAppCompat -OsRoot $osRoot `
                        -VersionToken (Get-ServerFodVersionToken -Server $Server) `
                        -Source $planSource -ForceOnline:$planOnline)
                }
            }
        }

        # Defer ServerManager -Vhd until after dismount (below).
        $script:PendingOfflineFeatureInstall = $null
        if ($null -ne $Server -and -not $IsClient) {
            $script:PendingOfflineFeatureInstall = [pscustomobject]@{
                # The deferred pass rewrites the whole manifest and rebuilds most of it from
                # $Server. These four cannot be rebuilt from $Server - they are results of
                # this mount session - so they ride along, or the refresh writes them empty
                # and the guest silently never does the work they describe.
                NicPlan             = $NicPlan
                RsatCapabilities    = $pendingRsat
                Capabilities        = $pendingCapabilities
                IncludeManagementTools = $includeMgmt
                VhdPath             = $VhdPath
                Server              = $Server
                Defaults            = $Defaults
            }
        }

        Set-OfflineGuestProvisionPayload -OsRoot $osRoot -Server $Server -Defaults $Defaults -IsClient:$IsClient `
            -PendingWindowsFeatures $pendingFeatures -PendingRsatCapabilities $pendingRsat `
            -PendingCapabilities $pendingCapabilities -IncludeManagementTools:$includeMgmt `
            -NicPlan $NicPlan
    }
    finally {
        if ($mounted) {
            Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
        }
    }

    # Offline Server features require an unmounted VHD.
    if ($null -ne $script:PendingOfflineFeatureInstall) {
        $job = $script:PendingOfflineFeatureInstall
        $script:PendingOfflineFeatureInstall = $null
        $result = Install-OfflineServerFeaturesOnVhd -VhdPath $job.VhdPath -Server $job.Server -Defaults $job.Defaults
        # Only remount when the offline install actually produced something the manifest does
        # not already say. Arc used to force a pass too, but every Arc field is known during
        # the first write - that pass rewrote an identical manifest, logged a second identical
        # line, and paid for a mount/dismount cycle to do it.
        if ($result.PendingWindowsFeatures.Count -gt 0) {
            # Re-mount briefly to refresh manifest with deferred features. Best-effort: if the
            # VHD is still locked, retry a few times like Start-VmWithRetry does, then give up
            # without aborting the whole VM - but say so loudly, since the deferred feature(s)
            # were never queued for guest install either and need manual install after boot.
            $remountAttempts = 3
            $remountDelaySeconds = 10
            for ($remountAttempt = 1; $remountAttempt -le $remountAttempts; $remountAttempt++) {
                $remounted = $false
                try {
                    Clear-StaleVhdAttachment -VhdPath $job.VhdPath
                    $disk2 = Mount-VHD -Path $job.VhdPath -Passthru | Get-Disk
                    $remounted = $true
                    $osVolume2 = Get-Partition -DiskNumber $disk2.Number |
                        Get-Volume |
                        Where-Object { $_.FileSystem -eq "NTFS" -and $_.DriveLetter } |
                        Sort-Object -Property Size -Descending |
                        Select-Object -First 1
                    if ($null -ne $osVolume2) {
                        $osRoot2 = "$($osVolume2.DriveLetter):"
                        Set-OfflineGuestProvisionPayload -OsRoot $osRoot2 -Server $job.Server -Defaults $job.Defaults -IsClient:$false `
                            -PendingWindowsFeatures $result.PendingWindowsFeatures `
                            -PendingRsatCapabilities @($job.RsatCapabilities) -PendingCapabilities @($job.Capabilities) `
                            -IncludeManagementTools:$job.IncludeManagementTools -NicPlan @($job.NicPlan) -Refresh
                    }
                    break
                }
                catch {
                    $remountMsg = $_.Exception.Message
                    if ((Test-IsTransientDiskLockError -Message $remountMsg) -and $remountAttempt -lt $remountAttempts) {
                        Write-Log "Remount of '$($job.VhdPath)' locked (attempt $remountAttempt/$remountAttempts) - retrying in ${remountDelaySeconds}s" -Tag "Warn"
                        Start-Sleep -Seconds $remountDelaySeconds
                        continue
                    }
                    Write-Log "Remount of '$($job.VhdPath)' failed after $remountAttempt attempt(s): $remountMsg" -Tag "Error"
                    Write-Log "    Not queued for the guest: $($result.PendingWindowsFeatures -join ', ') - install them on '$VmName' after first boot" -Tag "Error"
                    break
                }
                finally {
                    if ($remounted) {
                        Dismount-VHD -Path $job.VhdPath -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
}

function Wait-VhdFileReleased {
    param(
        [string]$VhdPath,
        [int]$TimeoutSeconds = 30,
        [int]$PollMilliseconds = 500
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $stream = [System.IO.File]::Open($VhdPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $stream.Close()
            return $true
        }
        catch [System.IO.IOException] {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Test-IsTransientDiskLockError {
    param([string]$Message)
    return ($Message -match "being used by another process") -or ($Message -match "ResourceBusy") -or `
        ($Message -match "0x80070020") -or ($Message -match "changed unexpectedly")
}

function Clear-StaleVhdAttachment {
    param([string]$VhdPath)

    # A VHD can be left "Attached" (still holding the file open) by a prior failed run or
    # a botched Install-WindowsFeature -Vhd session, with NO drive letter ever assigned -
    # Wait-VhdFileReleased's file-lock poll correctly reports it as locked, but nothing will
    # spontaneously detach it; only an explicit Dismount-VHD does. Check for and clear that
    # before mounting, so a stray attachment from a previous failure doesn't require going
    # into Disk Management by hand.
    try {
        $existing = Get-VHD -Path $VhdPath -ErrorAction Stop
        if ($existing.Attached) {
            Write-Log "'$VhdPath' still attached from a prior run - dismounting" -Tag "Warn"
            Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Get-VHD throws if the file was never touched via the VHD APIs - nothing to clear.
    }
}

function Test-IsStaleDismMountError {
    param([string]$Message)
    return ($Message -match "mount status") -or ($Message -match "changed unexpectedly")
}

function Clear-StaleDismMountPoints {
    # Install-WindowsFeature -Vhd mounts the image through DISM, which tracks active mounts
    # under %WinDir%\System32\ServerManager\Images\<GUID>. A prior failed/interrupted -Vhd
    # session can leave that tracking record orphaned, so every later attempt against the
    # same VHD keeps hitting the same stale GUID with "mount status is not valid" / "image
    # file has changed unexpectedly" - a different resource than the VHD's own Attached
    # state (see Clear-StaleVhdAttachment), and a plain retry alone won't fix it.
    try {
        Clear-WindowsCorruptMountPoint -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Clear-WindowsCorruptMountPoint unavailable or failed: $($_.Exception.Message)" -Tag "Warn"
    }
}

function Start-VmWithRetry {
    param(
        [string]$VmName,
        [int]$MaxAttempts = 12,
        [int]$DelaySeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Start-VM -Name $VmName -ErrorAction Stop
            return
        }
        catch {
            $msg = $_.Exception.Message
            if (-not (Test-IsTransientDiskLockError -Message $msg) -or $attempt -ge $MaxAttempts) {
                throw
            }
            Write-Log "Start-VM '$VmName' hit a transient disk lock (attempt $attempt/$MaxAttempts) - retrying in ${DelaySeconds}s" -Tag "Warn"
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# Features that are never staged into the image offline, even though
# Install-WindowsFeature -Vhd accepts them and reports success. Their payload carries a
# CBS "advanced installer" - a custom installer DLL that offline servicing cannot run,
# so CBS queues it and executes it during first boot, inside Setup's "Getting ready"
# phase. That phase runs BEFORE the specialize pass applies <ComputerName> and
# <JoinDomain> from the unattend, which produces two distinct failure classes:
#
# 1. Boot-abort: the installer needs services that do not exist that early. It fails,
#    the whole advanced operation queue fails with it, and Setup aborts: "Windows could
#    not configure one or more system components" - an image that can never finish
#    installing.
#
#    RDS-Web-Access, from a failed build's C:\Windows\Panther\setuperr.log:
#      Failed execution of queue item Installer: RDWEB Installer ... HRESULT_FROM_WIN32(1753)
#      Installer: RDWEB Installer  Binary Name: RDWebAI.dll  Component: TSPortalWebPart
#      CBS  Startup: Failed to process advanced operation queue [0x80073713]
#    1753 is EPT_S_NOT_REGISTERED - RDWebAI.dll configures the RDWeb IIS application at
#    install time and found no RPC endpoint to talk to that early in Setup.
#
# 2. Identity capture: the installer succeeds and the machine boots, but it persists the
#    computer name it ran under - Setup's random WIN-* name, since specialize has not
#    renamed the machine yet. The feature is silently bound to an identity the machine
#    sheds minutes later.
#
#    RDS-Connection-Broker, from a broken broker's event log after the RDS deployment
#    wizard tried to use it (renaming a server after installing the Connection Broker
#    role service is unsupported by Microsoft - same failure, just self-inflicted at
#    first boot):
#      RD Connection Broker Server name changed from (WIN-CI2EI8NU8SN) to (rds-cb-01.ad.migolf.io)
#      Remote Desktop Services failed to join the Connection Broker on server WIN-CI2EI8NU8SN.
#      Error: Current async message was dropped by async dispatcher, because there is a
#      new message which will override the current one.
#    The "from" name is the tell: the machine only ever carries a WIN-* name in the
#    window between Setup generating it and specialize applying <ComputerName>, and the
#    only code that runs in that window is this CBS queue.
#
# Membership is evidence-only: a feature earns its place here with a setuperr.log or
# event log naming its installer, not by resembling one that did. ADCS web role
# services, for instance, look like candidates but are not - Add-WindowsFeature installs
# inert binaries and all of their IIS work lives in the Install-Adcs* deployment
# cmdlets, run post-boot. RDS-RD-Server likewise stays offline: a Session Host only
# binds to a broker at New-RDSessionDeployment time, not at feature install.
#
# Deferred features install in the guest at SetupComplete via GuestProvision.ps1, where
# every service is up and the machine already has its final name and domain membership.
# Same result, a few minutes later, and the machine boots with the right identity.
$script:guestOnlyWindowsFeatures = @(
    "RDS-Web-Access"
    "RDS-Connection-Broker"
)

function Install-OfflineServerFeaturesOnVhd {
    param(
        [string]$VhdPath,
        [object]$Server,
        [object]$Defaults
    )

    $pendingOnline = New-Object System.Collections.Generic.List[string]
    $featureNames = @()
    if ($Server.windowsFeatures) {
        $featureNames = @($Server.windowsFeatures | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" } | Select-Object -Unique)
    }
    $includeMgmt = $true
    if ($null -ne $Server.includeManagementTools) {
        $includeMgmt = [bool]$Server.includeManagementTools
    }
    $sxsPath = ""
    if ($Defaults) { $sxsPath = [string]$Defaults.sxsSourcePath }

    if ($featureNames.Count -eq 0) {
        return [pscustomobject]@{ PendingWindowsFeatures = @(); IncludeManagementTools = $includeMgmt }
    }

    if ($null -eq (Get-Module -ListAvailable -Name ServerManager)) {
        Write-Log "ServerManager not available - deferring all features to guest" -Tag "Warn"
        return [pscustomobject]@{ PendingWindowsFeatures = @($featureNames); IncludeManagementTools = $includeMgmt }
    }

    # Route the offline-unsafe features (see $script:guestOnlyWindowsFeatures) straight
    # to the guest's first-boot install before anything touches the VHD.
    foreach ($guestOnlyFeature in @($featureNames | Where-Object { $script:guestOnlyWindowsFeatures -contains $_ })) {
        Write-Log "Feature '$guestOnlyFeature' cannot be staged offline - deferred to guest first boot" -Tag "Warn"
        $pendingOnline.Add($guestOnlyFeature)
    }
    $featureNames = @($featureNames | Where-Object { $script:guestOnlyWindowsFeatures -notcontains $_ })
    if ($featureNames.Count -eq 0) {
        return [pscustomobject]@{
            PendingWindowsFeatures = @($pendingOnline | Select-Object -Unique)
            IncludeManagementTools = $includeMgmt
        }
    }

    Import-Module ServerManager -ErrorAction Stop

    # The unattend-injection mount above just dismounted this same VHD. Dismount-VHD can
    # return before the OS fully releases the file (CBS/TiWorker cleanup lag), and
    # Install-WindowsFeature -Vhd mounting the same path moments later races that release -
    # producing "image file has changed unexpectedly" instead of a clean lock error. Clear
    # any stray attachment first (belt-and-suspenders - Set-OfflineUnattendFile already did
    # this before its own mount, but a failed prior Install-WindowsFeature -Vhd session can
    # leave the VHD attached with no drive letter, which a plain file-lock wait won't fix),
    # then wait for the file to actually be free.
    Clear-StaleVhdAttachment -VhdPath $VhdPath
    Clear-StaleDismMountPoints
    if (-not (Wait-VhdFileReleased -VhdPath $VhdPath -TimeoutSeconds 30)) {
        Write-Log "'$VhdPath' still locked - feature install may race" -Tag "Info"
    }

    Write-Log "Installing $($featureNames.Count) feature(s) into the VHD" -Tag "Run"
    foreach ($featureName in $featureNames) {
        $installed = $false
        for ($featAttempt = 1; $featAttempt -le 2; $featAttempt++) {
            try {
                $params = @{
                    Name                   = $featureName
                    Vhd                    = $VhdPath
                    IncludeManagementTools = $includeMgmt
                    ErrorAction            = "Stop"
                    WarningAction          = "SilentlyContinue"
                }
                if ($featureName -eq "NET-Framework-Core" -and -not [string]::IsNullOrWhiteSpace($sxsPath)) {
                    $params["Source"] = $sxsPath
                }
                $result = Install-WindowsFeature @params
                if ($result.Success) {
                    Write-Log "Offline feature '$featureName' enabled" -Tag "Ok"
                    $installed = $true
                }
                else {
                    Write-Log "Offline feature '$featureName' failed (ExitCode=$($result.ExitCode)) - deferring to guest" -Tag "Warn"
                }
                break
            }
            catch {
                $featMsg = $_.Exception.Message
                if ((Test-IsStaleDismMountError -Message $featMsg) -and $featAttempt -eq 1) {
                    Write-Log "Offline feature '$featureName' hit a stale DISM mount record - clearing corrupt mount points and retrying once" -Tag "Warn"
                    Clear-StaleDismMountPoints
                    continue
                }
                Write-Log "Offline feature '$featureName' error: $featMsg - deferring to guest" -Tag "Warn"
                break
            }
        }
        if (-not $installed) {
            $pendingOnline.Add($featureName)
        }
    }

    # Install-WindowsFeature -Vhd mounts/dismounts the image via its own DISM/CBS
    # session. The servicing stack can keep the VHDX file briefly locked (TiWorker
    # cleanup) even after the cmdlet reports success, which races with Start-VM
    # attaching the same file. Block here until the OS actually releases it.
    if (-not (Wait-VhdFileReleased -VhdPath $VhdPath -TimeoutSeconds 60)) {
        Write-Log "'$VhdPath' still locked after offline feature install - Start-VM will retry" -Tag "Warn"
    }

    return [pscustomobject]@{
        PendingWindowsFeatures = @($pendingOnline | Select-Object -Unique)
        IncludeManagementTools = $includeMgmt
    }
}

function Connect-HostContextAzureArc {
    param(
        [string]$VmName,
        [string]$ComputerName,
        [object]$Server,
        [object]$Defaults
    )

    $arc = Get-EffectiveAzureArcConfig -Server $Server -Defaults $Defaults
    if ($null -eq $arc -or $arc.authMode -ne "hostContext") {
        return
    }

    if ([string]::IsNullOrWhiteSpace($arc.subscriptionId) -or
        [string]::IsNullOrWhiteSpace($arc.resourceGroup) -or
        [string]::IsNullOrWhiteSpace($arc.location)) {
        Write-Log "Host Arc context incomplete (subscription/RG/location) - skipping" -Tag "Warn"
        return
    }

    $arcResourceName = $ComputerName
    if ([string]::IsNullOrWhiteSpace($arcResourceName)) {
        $arcResourceName = $VmName
    }

    Write-Log "Arc onboarding '$VmName' as '$arcResourceName'" -Tag "Run"

    $credUser = Get-ServerLocalCredentialUser -Server $Server
    $credPassPlain = Convert-ToPlainText -Value $Server.localUserPassword
    if ([string]::IsNullOrWhiteSpace($credPassPlain)) {
        Write-Log "No local password for PowerShell Direct Arc connect - skipping" -Tag "Warn"
        return
    }
    $secure = ConvertTo-SecureString -String $credPassPlain -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($credUser, $secure)

    $ready = $false
    for ($i = 1; $i -le 36; $i++) {
        try {
            $null = Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            $ready = $true
            break
        }
        catch {
            Start-Sleep -Seconds 10
        }
    }
    if (-not $ready) {
        Write-Log "PowerShell Direct not ready for '$VmName' - host Arc deferred (run Connect-AzConnectedMachine later)" -Tag "Warn"
        return
    }

    try {
        if ($null -eq (Get-Module -ListAvailable -Name Az.ConnectedMachine)) {
            Write-Log "Az.ConnectedMachine module missing on host - install Az.ConnectedMachine to use hostContext Arc" -Tag "Warn"
            return
        }
        Import-Module Az.ConnectedMachine -ErrorAction Stop
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx) {
            # The host being Arc-enabled itself is the azcmagent machine agent and does not
            # sign PowerShell in. Say so: it is the most common wrong guess at this message.
            Write-Log "No Azure context - skipping host Arc. Run Connect-AzAccount (-DeviceCode where no browser opens) as the account that runs this script" -Tag "Warn"
            return
        }

        $session = New-PSSession -VMName $VmName -Credential $cred -ErrorAction Stop
        try {
            Connect-AzConnectedMachine -ResourceGroupName $arc.resourceGroup -Name $arcResourceName `
                -Location $arc.location -SubscriptionId $arc.subscriptionId -PSSession $session -ErrorAction Stop
            Write-Log "Host Arc connected '$arcResourceName'" -Tag "Ok"
        }
        finally {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "Host Arc connect failed for '$VmName': $($_.Exception.Message)" -Tag "Error"
    }
}

function Set-VmIntegrationServicesFromConfig {
    param(
        [string]$VmName,
        [object]$Server
    )

    $svc = $Server.integrationServices
    if (-not $svc) {
        # Time synchronization off by default when omitted.
        $svc = [pscustomobject]@{
            shutdown            = $true
            timeSynchronization = $false
            dataExchange        = $true
            heartbeat           = $true
            backup              = $true
            guestServices       = $false
        }
    }

    $map = @{
        shutdown            = "Shutdown"
        timeSynchronization = "Time Synchronization"
        dataExchange        = "Key-Value Pair Exchange"
        heartbeat           = "Heartbeat"
        backup              = "VSS"
        guestServices       = "Guest Service Interface"
    }

    foreach ($key in $map.Keys) {
        $enabled = $true
        if ($null -ne $svc.$key) {
            $enabled = [bool]$svc.$key
        }
        elseif ($key -eq "timeSynchronization" -or $key -eq "guestServices") {
            $enabled = $false
        }

        $hyperVName = $map[$key]
        try {
            if ($enabled) {
                Enable-VMIntegrationService -VMName $VmName -Name $hyperVName -ErrorAction Stop | Out-Null
            }
            else {
                Disable-VMIntegrationService -VMName $VmName -Name $hyperVName -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-Log "Integration service '$VmName': $($_.Exception.Message)" -Tag "Warn"
        }
    }

    Write-Log "Integration Services on '$VmName' (timesync=$([bool]$svc.timeSynchronization))" -Tag "Run"
}

function Get-DiskNameToken {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "vm" }
    return ($Name.ToLowerInvariant() -replace '-', '')
}

function Get-OsDiskFileName {
    <#
        Windows disks are named for the drive letter they will carry - disk-dc01-c.vhdx
        is the C: drive, and that is the most useful label a Windows VM's disk can have.

        Linux has no drive letters. The same file would be called -c after a letter that
        never appears anywhere in the guest, so a Linux VM names its system disk what it
        is instead.
    #>
    # ForLinux, not IsLinux: $IsLinux is a READ-ONLY automatic variable in PowerShell 6+
    # and a parameter of that name cannot be bound there at all.
    param([string]$VmName, [switch]$ForLinux)

    if ($ForLinux) { return ("disk-{0}-system.vhdx" -f (Get-DiskNameToken -Name $VmName)) }
    return ("disk-{0}-c.vhdx" -f (Get-DiskNameToken -Name $VmName))
}

function Get-DataDiskFileName {
    param(
        [string]$VmName,
        [int]$Index,
        [switch]$ForLinux
    )

    # Linux: 01, 02, ... one-based, because -00 beside -system reads like a mistake and
    # the guest will call them sdb, sdc, nvme1n1 or whatever the kernel decides anyway -
    # the number here is only an ordering, so it should look like one.
    if ($ForLinux) {
        return ("disk-{0}-{1:00}.vhdx" -f (Get-DiskNameToken -Name $VmName), ($Index + 1))
    }

    # Windows: index 0 => d, 1 => e, ...
    $letter = [char](100 + $Index)
    return ("disk-{0}-{1}.vhdx" -f (Get-DiskNameToken -Name $VmName), $letter)
}

# ---------------------------[ Data disk volumes ]---------------------------
# Data disks only. The OS volume is laid down by New-Vhdx.ps1 when the gold image is
# built, so nothing here ever touches C:. A data disk with a file system is created
# empty on the host, then initialized (GPT), formatted and mounted on its drive letter
# by GuestProvision.ps1 at first boot - "None" leaves it raw and offline.
$script:DataDiskFileSystems = @("NTFS", "ReFS")

function Get-DataDiskFileSystem {
    param([object]$Disk)

    $raw = ([string]$Disk.fileSystem).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return "NTFS" }
    foreach ($candidate in $script:DataDiskFileSystems) {
        if ($raw -eq $candidate -or $raw.ToLowerInvariant() -eq $candidate.ToLowerInvariant()) { return $candidate }
    }
    if ($raw.ToLowerInvariant() -eq "none") { return "None" }
    return $raw   # invalid - preflight reports it by name
}

function Get-DataDiskDriveLetter {
    # Normalized single letter without colon, or "" when there is nothing usable.
    param(
        [object]$Disk,
        [int]$Index = -1
    )

    $letter = ([string]$Disk.letter).Trim().TrimEnd(':', '\')
    if ([string]::IsNullOrWhiteSpace($letter) -and $Index -ge 0) {
        # Same convention as the file name: index 0 => d, 1 => e, ...
        $letter = [string][char](100 + $Index)
    }
    return $letter.ToUpperInvariant()
}

function Get-DataDiskVolumeLabel {
    param(
        [object]$Disk,
        [int]$Index = -1
    )

    $volumeLabel = ([string]$Disk.label).Trim()
    if (-not [string]::IsNullOrWhiteSpace($volumeLabel)) { return $volumeLabel }
    $letter = Get-DataDiskDriveLetter -Disk $Disk -Index $Index
    if ([string]::IsNullOrWhiteSpace($letter)) { return "Data" }
    return ("Data {0}" -f $letter)
}

function Get-DataDiskPlanText {
    # "250 GB Dynamic E: NTFS" - one plan entry as it reads on the confirm screen.
    param([object]$Entry)

    if ($Entry.FileSystem -eq "None" -or [string]::IsNullOrWhiteSpace([string]$Entry.Letter)) {
        return ("{0} GB {1} raw" -f $Entry.SizeGB, $Entry.Type)
    }
    return ("{0} GB {1} {2}: {3}" -f $Entry.SizeGB, $Entry.Type, $Entry.Letter, $Entry.FileSystem)
}

function Get-ServerDataDiskPlan {
    <#
      One entry per configured data disk: where its VHDX goes, and what the guest is
      supposed to do with it. Single source for disk creation, the guest manifest and
      the preflight checks, so the three can never disagree.
    #>
    param(
        [object]$Server,
        [string]$VhdFolder,
        [string]$DiskNameToken
    )

    # NOTE: @($null) is a 1-element array in PowerShell - missing additionalDisks must
    # not be treated as "one blank disk" (that created a surprise 100 GB Dynamic VHDX).
    if ($null -eq $Server -or $null -eq $Server.additionalDisks) {
        return @()
    }
    $disks = @($Server.additionalDisks | Where-Object { $null -ne $_ })
    if ($disks.Count -eq 0) {
        return @()
    }

    $token = $DiskNameToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = Get-ServerComputerName -Server $Server
    }

    $plan = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($disk in $disks) {
        $diskFile = Get-DataDiskFileName -VmName $token -Index $index -ForLinux:(Test-IsLinuxServer -Server $Server)
        if (-not [string]::IsNullOrWhiteSpace([string]$disk.fileName)) {
            $diskFile = [string]$disk.fileName
        }

        $path = [string]$disk.path
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = if ([string]::IsNullOrWhiteSpace($VhdFolder)) { $diskFile } else { Join-Path -Path $VhdFolder -ChildPath $diskFile }
        }
        elseif (-not [System.IO.Path]::IsPathRooted($path)) {
            $path = Join-Path -Path $PSScriptRoot -ChildPath $path.TrimStart('.', '\', '/')
        }
        elseif (-not $path.ToLowerInvariant().EndsWith(".vhdx")) {
            $path = Join-Path -Path $path -ChildPath $diskFile
        }

        $diskType = [string]$disk.type
        if ([string]::IsNullOrWhiteSpace($diskType)) { $diskType = "Dynamic" }

        $plan.Add([pscustomobject]@{
                Index      = $index
                FileName   = $diskFile
                Path       = $path
                SizeGB     = $(if ($null -ne $disk.sizeGB) { [int]$disk.sizeGB } else { 100 })
                Type       = $diskType
                # SCSI 0:0 is the OS disk, so data disks start at location 1 (VHD Sets at 8).
                Location   = ($index + 1)
                Letter     = (Get-DataDiskDriveLetter -Disk $disk -Index $index)
                FileSystem = (Get-DataDiskFileSystem -Disk $disk)
                Label      = (Get-DataDiskVolumeLabel -Disk $disk -Index $index)
            }) | Out-Null
        $index++
    }

    return $plan.ToArray()
}

function Get-VhdSetFileName {
    param(
        [string[]]$AttachTo,
        [int]$Sequence
    )
    $parts = @(
        $AttachTo |
            ForEach-Object { Get-DiskNameToken -Name $_ } |
            Where-Object { $_ -ne "" } |
            Sort-Object -Unique
    )
    if ($parts.Count -eq 0) { $parts = @("shared") }
    $seq = $Sequence.ToString("00")
    return ("vhds-{0}-{1}.vhds" -f ($parts -join "-"), $seq)
}

function Select-VhdSetsForServers {
    # Only VHD Sets that attach to at least one selected guest - skip sets for
    # guest clusters outside the current build scope.
    param(
        [object[]]$VhdSets,
        [object[]]$Servers
    )

    if (-not $VhdSets -or $VhdSets.Count -eq 0) {
        return @()
    }

    $selectedNames = @{}
    foreach ($server in @($Servers)) {
        $cn = (Get-ServerComputerName -Server $server).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($cn)) {
            $selectedNames[$cn] = $true
        }
    }

    $inScope = @()
    foreach ($set in @($VhdSets)) {
        $attachTo = @()
        if ($set.attachTo) {
            $attachTo = @($set.attachTo | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ -ne "" })
        }
        $hit = $false
        foreach ($member in $attachTo) {
            if ($selectedNames.ContainsKey($member)) {
                $hit = $true
                break
            }
        }
        if ($hit) {
            $inScope += $set
        }
    }

    return $inScope
}

function Add-ServerDataDisks {
    param(
        [string]$VmName,
        [string]$VhdFolder,
        [object]$Server,
        [string]$DiskNameToken = $null,
        [ValidateSet("CreateAndAttach", "CreateOnly", "AttachOnly")]
        [string]$Mode = "CreateAndAttach"
    )

    $token = $DiskNameToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = $VmName
    }

    $plan = @(Get-ServerDataDiskPlan -Server $Server -VhdFolder $VhdFolder -DiskNameToken $token)
    if ($plan.Count -eq 0) {
        return
    }

    foreach ($entry in $plan) {
        $path = [string]$entry.Path
        $sizeGb = [int]$entry.SizeGB
        $diskType = [string]$entry.Type

        $parent = Split-Path -Path $path -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $exists = Test-Path -LiteralPath $path
        if ($Mode -eq "AttachOnly") {
            if (-not $exists) {
                throw "Prepared data disk missing: $path"
            }
        }
        elseif ($exists) {
            throw "Data disk already exists: $path"
        }
        else {
            Write-Log "Data disk '$path' ($sizeGb GB $diskType)" -Tag "Run"
            if ($diskType -eq "Fixed") {
                New-VHD -Path $path -SizeBytes ([int64]$sizeGb * 1GB) -Fixed | Out-Null
            }
            else {
                New-VHD -Path $path -SizeBytes ([int64]$sizeGb * 1GB) -Dynamic | Out-Null
            }
        }

        if ($Mode -ne "CreateOnly") {
            if ([string]::IsNullOrWhiteSpace($VmName)) {
                throw "VmName is required to attach data disks"
            }
            Add-VMHardDiskDrive -VMName $VmName -Path $path -ControllerType SCSI -ControllerNumber 0 -ControllerLocation ([int]$entry.Location)
            if ($entry.FileSystem -eq "None") {
                Write-Log "Disk '$($entry.FileName)' stays raw" -Tag "Info"
            }
            else {
                Write-Log "Disk '$($entry.FileName)' -> $($entry.Letter): $($entry.FileSystem)" -Tag "Info"
            }
        }
    }
}

function Initialize-VhdSets {
    param(
        [object[]]$VhdSets,
        [string]$VhdRoot
    )

    $created = @{}
    if (-not $VhdSets -or $VhdSets.Count -eq 0) {
        return $created
    }

    $sequenceByKey = @{}
    foreach ($set in $VhdSets) {
        $attachTo = @()
        if ($set.attachTo) {
            $attachTo = @($set.attachTo | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ -ne "" })
        }

        $key = (@($attachTo | ForEach-Object { Get-DiskNameToken -Name $_ } | Sort-Object -Unique) -join "|")
        if (-not $sequenceByKey.ContainsKey($key)) {
            $sequenceByKey[$key] = 0
        }
        $sequenceByKey[$key] = [int]$sequenceByKey[$key] + 1
        $seq = [int]$sequenceByKey[$key]

        $autoFile = Get-VhdSetFileName -AttachTo $attachTo -Sequence $seq
        $setName = ([string]$set.name).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($setName)) {
            $setName = [System.IO.Path]::GetFileNameWithoutExtension($autoFile)
        }

        $path = Resolve-VhdSetTargetPath -Set $set -VhdRoot $VhdRoot -AttachTo $attachTo -Sequence $seq

        if (-not (Test-PathSupportsVhdSharing -Path $path)) {
            throw ("VHD Set '$setName' would be created at '$path', which is not CSV or SMB 3. Hyper-V cannot attach shared disks on local NTFS. Set a custom path under ClusterStorage or an SMB 3 share (e.g. C:\ClusterStorage\Volume1\vhds\ or \\fileserver\vhds\).")
        }

        if (-not (Test-Path -LiteralPath $path)) {
            $sizeGb = 100
            if ($null -ne $set.sizeGB) { $sizeGb = [int]$set.sizeGB }
            $diskType = [string]$set.type
            if ([string]::IsNullOrWhiteSpace($diskType)) { $diskType = "Dynamic" }

            $parent = Split-Path -Path $path -Parent
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            Write-Log "VHD Set '$path' ($sizeGb GB $diskType)" -Tag "Run"
            if ($diskType -eq "Fixed") {
                New-VHD -Path $path -SizeBytes ([int64]$sizeGb * 1GB) -Fixed | Out-Null
            }
            else {
                New-VHD -Path $path -SizeBytes ([int64]$sizeGb * 1GB) -Dynamic | Out-Null
            }
        }
        else {
            Write-Log "Reusing existing VHD Set '$path'" -Tag "Info"
        }

        $created[$setName] = @{
            Path     = $path
            AttachTo = $attachTo
        }
    }

    return $created
}

function Test-PathSupportsVhdSharing {
    # Hyper-V shared VHD / VHD Set (PR) requires CSV or SMB 3 - not local NTFS.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $p = $Path.Trim()
    if ($p.StartsWith("\\")) {
        return $true
    }

    # Cluster Shared Volume: C:\ClusterStorage\Volume1\...
    if ($p -match '(?i)(^|\\)ClusterStorage(\\|$)') {
        return $true
    }

    return $false
}

function Resolve-VhdSetTargetPath {
    param(
        [object]$Set,
        [string]$VhdRoot,
        [string[]]$AttachTo,
        [int]$Sequence
    )

    # 'name' carries the file name without the extension. Studio exports the generated
    # name by default, so honouring it here only changes anything when it was renamed.
    $autoFile = Get-VhdSetFileName -AttachTo $AttachTo -Sequence $Sequence
    $customName = ([string]$Set.name).Trim()
    if (-not [string]::IsNullOrWhiteSpace($customName)) {
        $customName = $customName -replace '[\\/:*?"<>|]', ''
        $customName = $customName -replace '(?i)\.vhds$', ''
        if (-not [string]::IsNullOrWhiteSpace($customName)) {
            $autoFile = "$customName.vhds"
        }
    }
    $vhdsRoot = Join-Path -Path $VhdRoot -ChildPath "vhds"

    $path = [string]$Set.path
    if ([string]::IsNullOrWhiteSpace($path)) {
        return (Join-Path -Path $vhdsRoot -ChildPath $autoFile)
    }
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        return (Join-Path -Path $PSScriptRoot -ChildPath $path.TrimStart('.', '\', '/'))
    }
    if ((Test-Path -LiteralPath $path -PathType Container -ErrorAction SilentlyContinue) -or $path.EndsWith("\") -or $path.EndsWith("/")) {
        return (Join-Path -Path $path.TrimEnd('\', '/') -ChildPath $autoFile)
    }
    if (-not $path.ToLowerInvariant().EndsWith(".vhds")) {
        return (Join-Path -Path $path -ChildPath $autoFile)
    }
    return $path
}

function Add-VhdSetsToVm {
    param(
        [string]$VmName,
        [hashtable]$VhdSetMap,
        [int]$StartLocation = 8,
        [string]$ComputerName = $null
    )

    if (-not $VhdSetMap -or $VhdSetMap.Count -eq 0) {
        return
    }

    $attachName = $ComputerName
    if ([string]::IsNullOrWhiteSpace($attachName)) {
        $attachName = $VmName
    }
    $attachName = $attachName.ToLowerInvariant()

    $location = $StartLocation
    foreach ($key in $VhdSetMap.Keys) {
        $entry = $VhdSetMap[$key]
        $attachTo = @($entry.AttachTo)
        if ($attachTo -notcontains $attachName) {
            continue
        }

        $path = [string]$entry.Path
        if (-not (Test-PathSupportsVhdSharing -Path $path)) {
            throw ("VHD Set '$path' is not on CSV or SMB 3 storage. Hyper-V cannot enable disk sharing on local NTFS. Place the .vhds under ClusterStorage or an SMB 3 share, then set a custom path on the VHD Set.")
        }

        Write-Log "Attaching VHD Set '$path' to '$VmName'" -Tag "Run"
        try {
            Add-VMHardDiskDrive -VMName $VmName -Path $path -ControllerType SCSI -ControllerNumber 0 `
                -ControllerLocation $location -SupportPersistentReservations -ErrorAction Stop
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match 'does not support virtual hard disk sharing' -or $msg -match 'sharing') {
                throw ("Failed to attach VHD Set '$path' to '$VmName': storage does not support VHD sharing. Use CSV (ClusterStorage) or an SMB 3 share. Underlying error: $msg")
            }
            throw
        }
        $location++
    }
}

function Add-VmToFailoverCluster {
    param(
        [string]$VmName,
        [object]$ClusterSettings,
        [object]$Server
    )

    if (-not $ClusterSettings -or -not [bool]$ClusterSettings.enabled) {
        return
    }
    if ($null -ne $ClusterSettings.addAfterCreate -and -not [bool]$ClusterSettings.addAfterCreate) {
        return
    }

    # addAllVms is the studio's "add every VM" toggle - it wins over the per-VM flags.
    # Otherwise: per-VM opt-in from the Failover Cluster blade. A server with no cluster
    # block at all is a pre-blade config: those meant "every VM", so keep adding it.
    if (-not [bool]$ClusterSettings.addAllVms) {
        if ($null -ne $Server -and $null -ne $Server.cluster) {
            if (-not [bool]$Server.cluster.enabled) {
                Write-Log "'$VmName' not clustered - staying standalone" -Tag "Info"
                return
            }
        }
    }

    if (-not (Get-Command -Name "Add-ClusterVirtualMachineRole" -ErrorAction SilentlyContinue)) {
        Write-Log "FailoverClusters module not available; skip cluster join for '$VmName'" -Tag "Warn"
        return
    }

    $clusterName = [string]$ClusterSettings.name
    try {
        if ([string]::IsNullOrWhiteSpace($clusterName)) {
            Write-Log "Adding '$VmName' to local failover cluster" -Tag "Run"
            Add-ClusterVirtualMachineRole -VirtualMachine $VmName | Out-Null
        }
        else {
            Write-Log "Adding '$VmName' to cluster '$clusterName'" -Tag "Run"
            Add-ClusterVirtualMachineRole -VirtualMachine $VmName -Cluster $clusterName | Out-Null
        }
        Write-Log "Cluster role created for '$VmName'" -Tag "Ok"
    }
    catch {
        Write-Log "Could not add '$VmName' to cluster: $($_.Exception.Message)" -Tag "Error"
        throw
    }
}

function Get-ProvisionVmContext {
    param(
        [object]$Server,
        [object]$Defaults,
        [object[]]$GoldImages
    )

    $computerName = Get-ServerComputerName -Server $Server
    if ([string]::IsNullOrWhiteSpace($computerName)) {
        throw "A server entry is missing the name property"
    }
    $hyperVName = Get-HyperVVmName -Server $Server
    $folderName = Get-ServerFolderName -Server $Server

    $imageId = [string]$Server.imageId
    $imageHint = [string]$Server.imageHint
    $goldPath = Resolve-GoldVhdxPath -GoldImages $GoldImages -ImageId $imageId -ImageHint $imageHint `
        -ServerName ([string]$Server.name) -AllowPrompt

    # Path precedence: per-VM vmPath/vhdPath override wins; otherwise automatic
    # storage placement (when enabled) picks a volume for this VM; otherwise the
    # global defaults apply. The folder name is still appended either way, so a
    # custom or placed root behaves exactly like the default one.
    $vmRoot = Resolve-ServerPathRoot -Server $Server -Property "vmPath" -Fallback ""
    $vhdRoot = Resolve-ServerPathRoot -Server $Server -Property "vhdPath" -Fallback ""
    if ([string]::IsNullOrWhiteSpace($vmRoot) -and [string]::IsNullOrWhiteSpace($vhdRoot)) {
        $placementVolumes = @(Get-StoragePlacementVolumes -Defaults $Defaults)
        if ($placementVolumes.Count -gt 0) {
            $volume = Select-StoragePlacementVolume -Volumes $placementVolumes -Server $Server `
                -GoldPath $goldPath -Label "'$computerName'"
            $vmRoot = $volume.VmPath
            $vhdRoot = $volume.VhdPath
        }
    }
    if ([string]::IsNullOrWhiteSpace($vmRoot)) { $vmRoot = [string]$Defaults.vmPath }
    if ([string]::IsNullOrWhiteSpace($vhdRoot)) { $vhdRoot = [string]$Defaults.vhdPath }
    if ([string]::IsNullOrWhiteSpace($vhdRoot)) {
        $vhdRoot = $vmRoot
    }

    $vmFolder = Join-Path -Path $vmRoot -ChildPath $folderName
    $vhdFolder = Join-Path -Path $vhdRoot -ChildPath $folderName

    $osDiskName = Get-OsDiskFileName -VmName $computerName -ForLinux:(Test-IsLinuxServer -Server $Server)
    if (-not [string]::IsNullOrWhiteSpace([string]$Server.osDiskFileName)) {
        $osDiskName = [string]$Server.osDiskFileName
    }
    $childVhd = Join-Path -Path $vhdFolder -ChildPath $osDiskName

    $useDiff = $false
    if ($null -ne $Server.useDifferencingDisk) {
        $useDiff = [bool]$Server.useDifferencingDisk
    }

    return [pscustomobject]@{
        ComputerName = $computerName
        HyperVName   = $hyperVName
        FolderName   = $folderName
        ImageId      = $imageId
        GoldPath     = $goldPath
        VmRoot       = $vmRoot
        VhdRoot      = $vhdRoot
        VmFolder     = $vmFolder
        VhdFolder    = $vhdFolder
        ChildVhd     = $childVhd
        UseDiff      = $useDiff
    }
}

function Initialize-ProvisionVmDisks {
    # Slow-host phase 1: create folders + OS gold copy/diff + data VHDX files (no VM yet).
    param(
        [object]$Server,
        [object]$Defaults,
        [object[]]$GoldImages
    )

    $ctx = Get-ProvisionVmContext -Server $Server -Defaults $Defaults -GoldImages $GoldImages
    if ($ctx.HyperVName -ne $ctx.ComputerName) {
        Write-Log "Prep '$($ctx.ComputerName)' <- '$($ctx.GoldPath)'" -Tag "Info"
    }
    else {
        Write-Log "Prep '$($ctx.ComputerName)' <- gold '$($ctx.GoldPath)'" -Tag "Info"
    }

    if (-not (Test-Path -LiteralPath $ctx.VmFolder)) {
        New-Item -ItemType Directory -Path $ctx.VmFolder -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $ctx.VhdFolder)) {
        New-Item -ItemType Directory -Path $ctx.VhdFolder -Force | Out-Null
    }

    if (Test-Path -LiteralPath $ctx.ChildVhd) {
        throw "VHDX already exists: $($ctx.ChildVhd)"
    }

    $existingHyperV = Get-VM -Name $ctx.HyperVName -ErrorAction SilentlyContinue
    if ($existingHyperV) {
        throw "A VM named '$($ctx.HyperVName)' already exists"
    }
    if ($ctx.HyperVName -ne $ctx.FolderName) {
        $existingShort = Get-VM -Name $ctx.FolderName -ErrorAction SilentlyContinue
        if ($existingShort) {
            throw "A VM named '$($ctx.FolderName)' already exists (needed as temporary name before rename to '$($ctx.HyperVName)')"
        }
    }

    if ($ctx.UseDiff) {
        Write-Log "Creating differencing disk '$($ctx.ChildVhd)'" -Tag "Run"
        New-VHD -Path $ctx.ChildVhd -ParentPath $ctx.GoldPath -Differencing | Out-Null
    }
    else {
        Write-Log "Copying gold image to '$($ctx.ChildVhd)'" -Tag "Run"
        # A full copy of a gold is tens of gigabytes and Copy-Item says nothing while
        # it runs, which makes a working build indistinguishable from a hung one.
        Copy-FileWithProgress -Source $ctx.GoldPath -Destination $ctx.ChildVhd -Activity "copying gold"
    }

    Add-ServerDataDisks -VmName $ctx.ComputerName -VhdFolder $ctx.VhdFolder -Server $Server `
        -DiskNameToken $ctx.ComputerName -Mode CreateOnly

    Write-Log "Disks prepared for '$($ctx.ComputerName)'" -Tag "Ok"
    return $ctx
}

function Test-ShouldStartProvisionedVm {
    param(
        [object]$Server,
        [bool]$DoStart
    )

    if (-not $DoStart) { return $false }
    if ($null -ne $Server.startAfterCreate) {
        return [bool]$Server.startAfterCreate
    }
    return $true
}

function New-ProvisionedVm {
    param(
        [object]$Server,
        [object]$Defaults,
        [object[]]$GoldImages,
        [hashtable]$VhdSetMap,
        [bool]$DoStart,
        [switch]$DisksAlreadyPrepared
    )

    $ctx = Get-ProvisionVmContext -Server $Server -Defaults $Defaults -GoldImages $GoldImages
    if ($ctx.HyperVName -ne $ctx.ComputerName) {
        Write-Log "'$($ctx.ComputerName)' -> '$($ctx.HyperVName)' <- '$($ctx.GoldPath)'" -Tag "Info"
    }
    else {
        Write-Log "'$($ctx.ComputerName)' <- gold '$($ctx.GoldPath)'" -Tag "Info"
    }

    if (-not (Test-Path -LiteralPath $ctx.VmFolder)) {
        New-Item -ItemType Directory -Path $ctx.VmFolder -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $ctx.VhdFolder)) {
        New-Item -ItemType Directory -Path $ctx.VhdFolder -Force | Out-Null
    }

    $existingHyperV = Get-VM -Name $ctx.HyperVName -ErrorAction SilentlyContinue
    if ($existingHyperV) {
        throw "A VM named '$($ctx.HyperVName)' already exists"
    }
    if ($ctx.HyperVName -ne $ctx.FolderName) {
        $existingShort = Get-VM -Name $ctx.FolderName -ErrorAction SilentlyContinue
        if ($existingShort) {
            throw "A VM named '$($ctx.FolderName)' already exists (needed as temporary name before rename to '$($ctx.HyperVName)')"
        }
    }

    if ($DisksAlreadyPrepared) {
        if (-not (Test-Path -LiteralPath $ctx.ChildVhd)) {
            throw "Prepared OS disk missing: $($ctx.ChildVhd)"
        }
        Write-Log "Using prepared OS disk '$($ctx.ChildVhd)'" -Tag "Info"
    }
    elseif (Test-Path -LiteralPath $ctx.ChildVhd) {
        throw "VHDX already exists: $($ctx.ChildVhd)"
    }
    elseif ($ctx.UseDiff) {
        Write-Log "Creating differencing disk '$($ctx.ChildVhd)'" -Tag "Run"
        New-VHD -Path $ctx.ChildVhd -ParentPath $ctx.GoldPath -Differencing | Out-Null
    }
    else {
        Write-Log "Copying gold image to '$($ctx.ChildVhd)'" -Tag "Run"
        # A full copy of a gold is tens of gigabytes and Copy-Item says nothing while
        # it runs, which makes a working build indistinguishable from a hung one.
        Copy-FileWithProgress -Source $ctx.GoldPath -Destination $ctx.ChildVhd -Activity "copying gold"
    }

    $memoryGb = 4
    if ($null -ne $Server.memoryGB) { $memoryGb = [int]$Server.memoryGB }
    $cpuCount = 2
    if ($null -ne $Server.cpuCount) { $cpuCount = [int]$Server.cpuCount }
    $switchName = [string]$Server.switchName

    # New-VM derives its config subfolder from -Name, so create under the configured
    # folder name (...\VMs\paw-01\ by default) and rename afterwards if the Hyper-V
    # object name is supposed to differ (e.g. FQDN name + short folder).
    Write-Log "Gen2 VM '$($ctx.FolderName)' ($memoryGb GB / $cpuCount CPU)" -Tag "Run"
    $vm = New-VM -Name $ctx.FolderName -Generation 2 -MemoryStartupBytes ([int64]$memoryGb * 1GB) `
        -VHDPath $ctx.ChildVhd -Path $ctx.VmRoot
    Set-VM -VM $vm -ProcessorCount $cpuCount -StaticMemory

    $hyperVName = $ctx.HyperVName
    if ($hyperVName -ne $ctx.FolderName) {
        Write-Log "Renaming VM '$($ctx.FolderName)' -> '$hyperVName'" -Tag "Run"
        Rename-VM -VM $vm -NewName $hyperVName
        $vm = Get-VM -Name $hyperVName -ErrorAction Stop
    }

    # The adapter New-VM created, renamed to the configured name. Device naming pushes that
    # name into the guest, so Get-NetAdapter shows 'vnic-01' instead of Windows' own
    # 'Ethernet' / 'Ethernet 2' - which is guesswork the moment a VM has more than one NIC.
    $primaryNicName = Get-ServerPrimaryNicName -Server $Server
    $primaryNic = Get-VMNetworkAdapter -VMName $hyperVName -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($primaryNic -and $primaryNic.Name -ne $primaryNicName) {
        Rename-VMNetworkAdapter -VMNetworkAdapter $primaryNic -NewName $primaryNicName
    }
    if ($primaryNic) {
        try {
            Set-VMNetworkAdapter -VMName $hyperVName -Name $primaryNicName -DeviceNaming On -ErrorAction Stop
        }
        catch {
            Write-Log "Device naming '$primaryNicName': $($_.Exception.Message)" -Tag "Warn"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($switchName)) {
        $switch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
        if (-not $switch) {
            throw "Hyper-V switch '$switchName' was not found"
        }
        Connect-VMNetworkAdapter -VMName $hyperVName -Name $primaryNicName -SwitchName $switchName
        if ($null -ne $Server.vlanId -and [string]$Server.vlanId -ne "") {
            Set-VMNetworkAdapterVlan -VMName $hyperVName -VMNetworkAdapterName $primaryNicName -Access -VlanId ([int]$Server.vlanId)
            Write-Log "VLAN $([int]$Server.vlanId) set on '$hyperVName'" -Tag "Run"
        }
    }

    # Every adapter beyond the first, in config order.
    $additionalNics = @(Get-ServerAdditionalNics -Server $Server)
    foreach ($extraNic in $additionalNics) {
        if (-not (Get-VMSwitch -Name $extraNic.SwitchName -ErrorAction SilentlyContinue)) {
            throw "Hyper-V switch '$($extraNic.SwitchName)' was not found (adapter '$($extraNic.Name)')"
        }
        Add-VMNetworkAdapter -VMName $hyperVName -Name $extraNic.Name -SwitchName $extraNic.SwitchName -DeviceNaming On
        if ($null -ne $extraNic.VlanId) {
            Set-VMNetworkAdapterVlan -VMName $hyperVName -VMNetworkAdapterName $extraNic.Name -Access -VlanId ([int]$extraNic.VlanId)
        }
        Write-Log ("Added adapter '{0}' on '{1}'{2}" -f $extraNic.Name, $extraNic.SwitchName,
            $(if ($null -ne $extraNic.VlanId) { " (VLAN $($extraNic.VlanId))" } else { "" })) -Tag "Run"
    }

    $autoStartAction = Get-ServerAutomaticStartAction -Server $Server
    if ($autoStartAction -eq "Nothing") {
        Set-VM -VMName $hyperVName -AutomaticStartAction Nothing
    }
    else {
        $autoStartDelay = Get-ServerAutomaticStartDelay -Server $Server
        Set-VM -VMName $hyperVName -AutomaticStartAction $autoStartAction -AutomaticStartDelay $autoStartDelay
        Write-Log "Start action '$autoStartAction' +${autoStartDelay}s on '$hyperVName'" -Tag "Run"
    }

    $enableSecureBoot = $true
    if ($null -ne $Server.enableSecureBoot) {
        $enableSecureBoot = [bool]$Server.enableSecureBoot
    }
    if ($enableSecureBoot) {
        # These cloud images are signed by Microsoft's THIRD-PARTY UEFI CA, through shim.
        # The MicrosoftWindows template does not trust that chain, and a VM created with
        # it does not boot - with no message that points at Secure Boot.
        $secureBootTemplate = "MicrosoftWindows"
        if (Test-IsLinuxServer -Server $Server) { $secureBootTemplate = "MicrosoftUEFICertificateAuthority" }
        Set-VMFirmware -VMName $hyperVName -EnableSecureBoot On -SecureBootTemplate $secureBootTemplate
        Write-Log "Secure Boot on with the $secureBootTemplate template" -Tag "Debug"
    }

    $enableVtpm = $false
    if ($null -ne $Server.enableVtpm) {
        $enableVtpm = [bool]$Server.enableVtpm
    }
    if ($enableVtpm -and (Test-IsWindows11Gold -GoldPath $ctx.GoldPath)) {
        try {
            Set-VMKeyProtector -VMName $hyperVName -NewLocalKeyProtector -ErrorAction Stop
            Enable-VMTPM -VMName $hyperVName -ErrorAction Stop
            Write-Log "Enabled vTPM on '$hyperVName'" -Tag "Run"
        }
        catch {
            Write-Log "Could not enable vTPM on '$hyperVName': $($_.Exception.Message)" -Tag "Warn"
        }
    }

    $diskMode = "CreateAndAttach"
    if ($DisksAlreadyPrepared) { $diskMode = "AttachOnly" }
    Add-ServerDataDisks -VmName $hyperVName -VhdFolder $ctx.VhdFolder -Server $Server `
        -DiskNameToken $ctx.ComputerName -Mode $diskMode
    Add-VhdSetsToVm -VmName $hyperVName -VhdSetMap $VhdSetMap -ComputerName $ctx.ComputerName
    Set-VmIntegrationServicesFromConfig -VmName $hyperVName -Server $Server

    $isClient = Test-IsClientProvision -Server $Server -GoldPath $ctx.GoldPath

    # Pin a static MAC on every adapter, addressed or not. Two things key off it and neither
    # can use an identity that moves: the unattend keys each interface's addressing to it, and
    # GuestProvision renames the guest's connections by it. A dynamic MAC is reassigned when
    # the VM moves host, which would break both.
    $nicMac = Get-VmNicMacForUnattend -VmName $hyperVName -AdapterName $primaryNicName
    if (-not $nicMac -and -not [string]::IsNullOrWhiteSpace(([string]$Server.ipAddress).Trim())) {
        throw "'$($ctx.ComputerName)': could not assign a static Hyper-V NIC MAC for TCPIP Identifier (name 'Ethernet' is unreliable - gold often leaves Ethernet 2 as the live NIC)"
    }
    if ($nicMac) {
        Write-Log "Adapter '$primaryNicName' MAC = $nicMac" -Tag "Info"
    }
    foreach ($extraNic in $additionalNics) {
        $extraMac = Get-VmNicMacForUnattend -VmName $hyperVName -AdapterName $extraNic.Name
        if (-not $extraMac) {
            if (-not [string]::IsNullOrWhiteSpace($extraNic.IpAddress)) {
                throw "'$($ctx.ComputerName)': could not assign a static MAC to adapter '$($extraNic.Name)' for its TCPIP Identifier"
            }
            Write-Log "Adapter '$($extraNic.Name)' has no static MAC - dynamic MAC, not renamed in the guest" -Tag "Warn"
            continue
        }
        $extraNic.MacAddress = $extraMac
        Write-Log "Adapter '$($extraNic.Name)' MAC = $extraMac" -Tag "Info"
    }

    # Hyper-V device naming only publishes the adapter name as an NDIS property inside the
    # guest - it never touches the connection name Windows shows, which stays 'Ethernet',
    # 'Ethernet 2', ... So the rename itself happens in the guest, keyed by the MACs above.
    $nicPlan = New-Object System.Collections.Generic.List[object]
    if ($nicMac) {
        $nicPlan.Add([pscustomobject]@{ Name = $primaryNicName; MacAddress = $nicMac }) | Out-Null
    }
    foreach ($extraNic in $additionalNics) {
        if (-not [string]::IsNullOrWhiteSpace([string]$extraNic.MacAddress)) {
            $nicPlan.Add([pscustomobject]@{ Name = $extraNic.Name; MacAddress = $extraNic.MacAddress }) | Out-Null
        }
    }

    # The one place a Windows-specific action happens for every VM, and so the one place
    # Linux has to diverge: no answer file written into the disk, a cloud-init seed
    # attached beside it instead. Everything after this point is the same for both.
    $linuxSeedPath = ""
    if (Test-IsLinuxServer -Server $Server) {
        $linuxSeedPath = Set-LinuxProvisioning -Server $Server -Defaults $Defaults -VmName $hyperVName `
            -HostName $ctx.ComputerName -SeedDirectory (Split-Path -Path $ctx.ChildVhd -Parent) `
            -GoldPath $ctx.GoldPath -NicMacAddress ([string]$nicMac)
    }
    else {
        $unattend = Get-ServerUnattendContent -Server $Server -Defaults $Defaults -IsClient:$isClient `
            -NicMacAddress ([string]$nicMac) -AdditionalNicPlan $additionalNics -GoldPath $ctx.GoldPath
        Set-OfflineUnattendFile -VhdPath $ctx.ChildVhd -UnattendContent $unattend -VmName $ctx.ComputerName -IsClient:$isClient `
            -Server $Server -Defaults $Defaults -NicPlan $nicPlan.ToArray()
        if ($isClient) {
            Write-Log "Client image - Win11 OOBE skips applied" -Tag "Info"
        }
    }

    # Nested virtualization: the per-VM flag, or the Hyper-V role landing in the guest.
    if (Test-ServerWantsNestedVirtualization -Server $Server) {
        try {
            Set-VMProcessor -VMName $hyperVName -ExposeVirtualizationExtensions $true -ErrorAction Stop
            # Every adapter, not just the first: the nested guests' frames leave through
            # whichever NIC their virtual switch is bound to.
            Get-VMNetworkAdapter -VMName $hyperVName -ErrorAction Stop |
                ForEach-Object { Set-VMNetworkAdapter -VMNetworkAdapter $_ -MacAddressSpoofing On -ErrorAction Stop }
            Write-Log "Nested virtualization + MAC spoofing on '$hyperVName'" -Tag "Run"
        }
        catch {
            Write-Log "Could not enable nested virtualization on '$hyperVName': $($_.Exception.Message)" -Tag "Warn"
        }
    }

    Add-VmToFailoverCluster -VmName $hyperVName -ClusterSettings $Defaults.cluster -Server $Server

    if (-not [string]::IsNullOrWhiteSpace($linuxSeedPath)) {
        # A Linux VM is always started here, whatever the studio said: the toggle decides
        # whether a FINISHED machine is left running, and a machine that never booted
        # never read its answer file. cloud-init powers it off again when it is done,
        # which is what lets the seed be taken away.
        $null = Complete-LinuxFirstBoot -VmName $hyperVName -SeedPath $linuxSeedPath

        if (Test-ShouldStartProvisionedVm -Server $Server -DoStart:$DoStart) {
            $vm = Get-VM -Name $hyperVName -ErrorAction SilentlyContinue
            if ($vm -and $vm.State -eq "Off") {
                Write-Log "Starting VM '$hyperVName'" -Tag "Run"
                Start-VmWithRetry -VmName $hyperVName
            }
        }
        else {
            Write-Log "VM '$hyperVName' provisioned and left off" -Tag "Info"
        }
    }
    elseif (Test-ShouldStartProvisionedVm -Server $Server -DoStart:$DoStart) {
        Write-Log "Starting VM '$hyperVName'" -Tag "Run"
        Start-VmWithRetry -VmName $hyperVName
        Connect-HostContextAzureArc -VmName $hyperVName -ComputerName $ctx.ComputerName -Server $Server -Defaults $Defaults
    }
    else {
        Write-Log "VM '$hyperVName' created (not started)" -Tag "Info"
    }

    Write-Log "Provisioned '$hyperVName'" -Tag "Ok"
}

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
    "G1swbSAbWzBtG1szODsyOzEyNTsyMzc7MjQ3OzQ4OzI7MTI1OzIzNzsyNDdt4paA4paA4paA4paA4paA4paA4paA4paA4paA4paA4paA4paA4paA4paAG1swbRtbMzg7Mjs5NDsyMTY7MjMwOzQ4OzI7OTQ7MjE2OzIzMG3iloDiloDiloAbWzBtICAgICAgICAgICAgICAgICAgG1swbQ==",
    "G1swbSAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7MjsxNjsxODQ7MjA3beKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgBtbMG0bWzM4OzI7ODsxMjc7MTQ3OzQ4OzI7ODsxMjc7MTQ3beKWgOKWgOKWgBtbMG0gICAgICAgICAgICAgICAgICAbWzBt",
    "G1swbSAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7MjsxNjsxODQ7MjA3beKWgBtbMG0bWzM4OzI7MTkxOzI0NTsyNTE7NDg7Mjs2OzQ2OzU2beKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgBtbMG0bWzM4OzI7Njs0Njs1Njs0ODsyOzY7NDY7NTZt4paA4paA4paA4paAG1swbRtbMzg7MjsxNjsxODQ7MjA3OzQ4OzI7MTY7MTg0OzIwN23iloAbWzBtG1szODsyOzg7MTI3OzE0Nzs0ODsyOzg7MTI3OzE0N23iloDiloDiloAbWzBtICAgICAgICAgICAgICAgICAgG1swbQ==",
    "G1swbSAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7MjsxNjsxODQ7MjA3beKWgBtbMG0bWzM4OzI7MTY7MTg0OzIwNzs0ODsyOzE5MTsyNDU7MjUxbeKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgBtbMG0bWzM4OzI7MTY7MTg0OzIwNzs0ODsyOzY7NDY7NTZt4paA4paA4paA4paAG1swbRtbMzg7MjsxNjsxODQ7MjA3OzQ4OzI7MTY7MTg0OzIwN23iloAbWzBtG1szODsyOzg7MTI3OzE0Nzs0ODsyOzg7MTI3OzE0N23iloDiloDiloAbWzBtICAgICAgICAgICAgICAgICAgG1swbQ==",
    "G1swbSAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7MjsxNjsxODQ7MjA3beKWgBtbMG0bWzM4OzI7Njs0Njs1Njs0ODsyOzE2OzE4NDsyMDdt4paA4paA4paA4paA4paA4paA4paA4paA4paA4paA4paA4paAG1swbRtbMzg7MjsxNjsxODQ7MjA3OzQ4OzI7MTY7MTg0OzIwN23iloAbWzBtG1szODsyOzg7MTI3OzE0Nzs0ODsyOzg7MTI3OzE0N23iloDiloDiloAbWzBtICAgIBtbMG0bWzM4OzI7MTI1OzIzNzsyNDc7NDg7MjsxMjU7MjM3OzI0N23iloDiloDiloDiloDiloDiloDiloDiloAbWzBtG1szODsyOzk0OzIxNjsyMzA7NDg7Mjs5NDsyMTY7MjMwbeKWgOKWgOKWgBtbMG0gICAbWzBt",
    "G1swbSAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7MjsxNjsxODQ7MjA3beKWgBtbMG0bWzM4OzI7MTkxOzI0NTsyNTE7NDg7Mjs2OzQ2OzU2beKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgBtbMG0bWzM4OzI7Njs0Njs1Njs0ODsyOzY7NDY7NTZt4paA4paA4paA4paAG1swbRtbMzg7MjsxNjsxODQ7MjA3OzQ4OzI7MTY7MTg0OzIwN23iloAbWzBtG1szODsyOzg7MTI3OzE0Nzs0ODsyOzg7MTI3OzE0N23iloDiloDiloAbWzBtICAgIBtbMG0bWzM4OzI7MTY7MTg0OzIwNzs0ODsyOzE2OzE4NDsyMDdt4paA4paA4paA4paA4paA4paA4paA4paAG1swbRtbMzg7Mjs4OzEyNzsxNDc7NDg7Mjs4OzEyNzsxNDdt4paA4paA4paAG1swbSAgIBtbMG0=",
    "G1swbSAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7MjsxNjsxODQ7MjA3beKWgBtbMG0bWzM4OzI7MTY7MTg0OzIwNzs0ODsyOzE5MTsyNDU7MjUxbeKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgBtbMG0bWzM4OzI7MTY7MTg0OzIwNzs0ODsyOzY7NDY7NTZt4paA4paA4paA4paAG1swbRtbMzg7MjsxNjsxODQ7MjA3OzQ4OzI7MTY7MTg0OzIwN23iloAbWzBtG1szODsyOzg7MTI3OzE0Nzs0ODsyOzg7MTI3OzE0N23iloDiloDiloAbWzBtICAgIBtbMG0bWzM4OzI7MTY7MTg0OzIwNzs0ODsyOzE2OzE4NDsyMDdt4paAG1swbRtbMzg7MjsxOTE7MjQ1OzI1MTs0ODsyOzY7NDY7NTZt4paA4paA4paA4paAG1swbRtbMzg7Mjs2OzQ2OzU2OzQ4OzI7Njs0Njs1Nm3iloDiloAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7MjsxNjsxODQ7MjA3beKWgBtbMG0bWzM4OzI7ODsxMjc7MTQ3OzQ4OzI7ODsxMjc7MTQ3beKWgOKWgOKWgBtbMG0gICAbWzBt",
    "G1swbSAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7MjsxNjsxODQ7MjA3beKWgBtbMG0bWzM4OzI7Njs0Njs1Njs0ODsyOzE2OzE4NDsyMDdt4paA4paA4paA4paA4paA4paA4paA4paA4paA4paA4paA4paAG1swbRtbMzg7MjsxNjsxODQ7MjA3OzQ4OzI7MTY7MTg0OzIwN23iloAbWzBtG1szODsyOzg7MTI3OzE0Nzs0ODsyOzg7MTI3OzE0N23iloDiloDiloAbWzBtICAgIBtbMG0bWzM4OzI7MTY7MTg0OzIwNzs0ODsyOzE2OzE4NDsyMDdt4paAG1swbRtbMzg7MjsxNjsxODQ7MjA3OzQ4OzI7MTkxOzI0NTsyNTFt4paA4paA4paA4paAG1swbRtbMzg7MjsxNjsxODQ7MjA3OzQ4OzI7Njs0Njs1Nm3iloDiloAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7MjsxNjsxODQ7MjA3beKWgBtbMG0bWzM4OzI7ODsxMjc7MTQ3OzQ4OzI7ODsxMjc7MTQ3beKWgOKWgOKWgBtbMG0gICAbWzBt",
    "G1swbSAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7MjsxNjsxODQ7MjA3beKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgBtbMG0bWzM4OzI7MTY7MTg0OzIwNzs0ODsyOzI1NTsyMTU7OTVt4paAG1swbRtbMzg7MjsxNjsxODQ7MjA3OzQ4OzI7MTY7MTg0OzIwN23iloAbWzBtG1szODsyOzg7MTI3OzE0Nzs0ODsyOzg7MTI3OzE0N23iloDiloDiloAbWzBtICAgIBtbMG0bWzM4OzI7MTY7MTg0OzIwNzs0ODsyOzE2OzE4NDsyMDdt4paAG1swbRtbMzg7Mjs2OzQ2OzU2OzQ4OzI7MTY7MTg0OzIwN23iloDiloDiloDiloDiloAbWzBtG1szODsyOzY7NDY7NTY7NDg7MjsyNTU7MjE1Ozk1beKWgBtbMG0bWzM4OzI7MTY7MTg0OzIwNzs0ODsyOzE2OzE4NDsyMDdt4paAG1swbRtbMzg7Mjs4OzEyNzsxNDc7NDg7Mjs4OzEyNzsxNDdt4paA4paA4paAG1swbSAgIBtbMG0=",
    "G1swbSAbWzBtG1szODsyOzE2OzE4NDsyMDc7NDg7Mjs1OzY2Ozc5beKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgOKWgBtbMG0bWzM4OzI7ODsxMjc7MTQ3OzQ4OzI7ODsxMjc7MTQ3beKWgOKWgOKWgBtbMG0gICAgG1swbRtbMzg7MjsxNjsxODQ7MjA3OzQ4OzI7NTs2Njs3OW3iloDiloDiloDiloDiloDiloDiloDiloAbWzBtG1szODsyOzg7MTI3OzE0Nzs0ODsyOzg7MTI3OzE0N23iloDiloDiloAbWzBtICAgG1swbQ=="
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
"@ -Name BuildVmsVtConsole -Namespace VmBuild -PassThru -ErrorAction Stop
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
        [int]$LabelWidth = 8,
        [int]$IndentWidth = 0,
        # Columns already consumed before this call - the logo and the gap after it,
        # which Show-MenuHeader writes itself. Without it this function believes the
        # row starts at column zero.
        [int]$ReservedWidth = 0
    )

    # A value that does not fit WRAPS, and the wrapped part lands in the logo's
    # columns on the next line - straight through the artwork. Truncating is the only
    # honest option: the header is a summary, and a summary that redraws the screen
    # badly is worse than one that says the value ends in three dots.
    #
    # The label is measured, not assumed. $LabelWidth is the column it is padded TO,
    # and a longer label simply overruns it - "online costs" is twelve characters in an
    # eight-wide column. Budgeting for eight when twelve are written leaves the value
    # four columns too long, which is exactly enough to wrap it into the logo.
    $labelCells = [Math]::Max($LabelWidth, $Label.Length)
    $available = (Get-ConsoleWidth) - 1 - $ReservedWidth - $IndentWidth - $labelCells - 2
    if ($available -lt 8) { $available = 8 }
    if ($Value.Length -gt $available) {
        $Value = $Value.Substring(0, $available - 3) + "..."
    }

    if ($IndentWidth -gt 0) {
        Write-Host (" " * $IndentWidth) -NoNewline
    }
    $paddedLabel = ("{0,-$LabelWidth}" -f $Label)
    Write-Studio -Text $paddedLabel -Key "accent" -NoNewline
    Write-Studio -Text ": " -Key "accent" -NoNewline
    Write-Studio -Text $Value -Key "muted"
}

function New-MenuInfoRow {
    <#
      One line of the column that sits to the right of the logo.
      Kind: "pair" (label : value), "title" (white heading), "muted" (dim text),
      "blank" (empty line).
    #>
    param(
        [ValidateSet("pair", "title", "muted", "blank")]
        [string]$Kind = "pair",
        [string]$Label = "",
        [string]$Value = "",
        [int]$LabelWidth = 8,
        [int]$Indent = 0
    )

    return [pscustomobject]@{
        Kind       = $Kind
        Label      = $Label
        Value      = $Value
        LabelWidth = $LabelWidth
        Indent     = $Indent
    }
}

function Show-MenuHeader {
    # Fastfetch-style header: colored server logo (left) + aligned facts (right).
    # Every page in this script wears it, so it takes no options that change its shape.
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

    $info = New-Object System.Collections.Generic.List[object]
    $info.Add((New-MenuInfoRow -Kind "title" -Value $scriptName)) | Out-Null
    $info.Add((New-MenuInfoRow -Label "menu" -Value $Title)) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        $info.Add((New-MenuInfoRow -Label "section" -Value $Subtitle)) | Out-Null
    }
    $info.Add((New-MenuInfoRow -Kind "blank")) | Out-Null

    if ($StatusLines) {
        foreach ($key in $StatusLines.Keys) {
            $info.Add((New-MenuInfoRow -Label ([string]$key).ToLowerInvariant() -Value ([string]$StatusLines[$key]))) | Out-Null
        }
        $info.Add((New-MenuInfoRow -Kind "blank")) | Out-Null
    }

    $info.Add((New-MenuInfoRow -Label "host" -Value $env:COMPUTERNAME)) | Out-Null
    $info.Add((New-MenuInfoRow -Label "user" -Value $env:USERNAME)) | Out-Null
    $info.Add((New-MenuInfoRow -Label "shell" -Value ("PS " + $PSVersionTable.PSVersion.ToString()))) | Out-Null

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

        if ($i -ge $info.Count) {
            Write-Host ""
            continue
        }

        $row = $info[$i]
        switch ([string]$row.Kind) {
            "blank" { Write-Host "" }
            "title" {
                if ($row.Indent -gt 0) { Write-Host (" " * $row.Indent) -NoNewline }
                Write-Studio -Text $row.Value -Key "fg"
            }
            "muted" {
                if ($row.Indent -gt 0) { Write-Host (" " * $row.Indent) -NoNewline }
                Write-Studio -Text $row.Value -Key "accent"
            }
            default {
                # The two-space indent Show-MenuHeader writes before the logo counts too: the
                # row starts at column 2, not column 0 - logo, the three-space gap, that indent.
                Write-FastfetchInfoRow -Label $row.Label -Value $row.Value `
                    -LabelWidth $row.LabelWidth -IndentWidth $row.Indent -ReservedWidth ($logoWidth + 5)
            }
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
        [string]$Subtitle,
        [scriptblock]$PreItems
    )

    if (-not $Items -or $Items.Count -eq 0) {
        throw "Show-Menu requires at least one item."
    }

    $index = $SelectedIndex
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $Items.Count) { $index = $Items.Count - 1 }

    $useRawUi = Test-MenuHostSupported

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
            Show-MenuHeader -Title $Title -StatusLines $StatusLines -Subtitle $Subtitle

            if ($PreItems) {
                & $PreItems
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
        [System.Collections.IDictionary]$StatusLines
    )

    if (-not $Items -or $Items.Count -eq 0) {
        throw "Show-MultiSelectMenu requires at least one item."
    }

    # An item may carry a Section; consecutive items sharing one are drawn under a
    # heading. The headings are written INSIDE the row loop rather than being items of
    # their own, so the cursor still walks one index per selectable row and nothing
    # about navigation has to know they exist.
    $hasSections = (@($Items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Section) })).Count -gt 0

    $index = 0
    $selected = @{}
    foreach ($item in $Items) {
        $selected[[string]$item.Id] = $false
    }

    $useRawUi = Test-MenuHostSupported

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

            $anchor = Get-MenuCursorAnchor
        }

        $lastSection = $null
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item  = $Items[$i]
            $id    = [string]$item.Id
            $mark  = if ($selected[$id]) { "[x]" } else { "[ ]" }
            $label = "$mark  $($item.Label)"
            $isSelectedRow = ($i -eq $index)

            $section = [string]$item.Section
            if (-not [string]::IsNullOrWhiteSpace($section) -and $section -ne $lastSection) {
                # A blank line before every heading but the first, so the groups read as
                # groups rather than as one list with words in it.
                if ($null -ne $lastSection) { Write-Host "" }
                Write-Studio -Text ("  " + $section) -Key "accent"
                $lastSection = $section
            }

            # Rows sit one step in when there are headings above them, so the heading
            # is what the eye lands on first.
            $indent = if ($hasSections) { "  " } else { "" }

            if ($isSelectedRow) {
                Write-Studio -Text "  $indent> " -Key "accent" -NoNewline
                Write-Studio -Text $label -Key "fg"
            }
            else {
                Write-Host "    $indent" -NoNewline
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
                        $chosen += [int]$id
                    }
                }
                if ($chosen.Count -eq 0) {
                    continue
                }
                return $chosen
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
                        $chosen += [int]$id
                    }
                }
                if ($chosen.Count -eq 0) { continue }
                return $chosen
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

#region ISO picker
# Arrow-key .iso browser, same look and keys as the one in New-Vhdx.ps1. Deliberately a
# copy rather than a shared module - both scripts stay single-file and runnable on their own.

function Get-FilePickerEntries {
    # Builds the current folder listing for the arrow-key ISO browser.
    param([string]$CurrentPath)

    $entries = @()

    if ([string]::IsNullOrWhiteSpace($CurrentPath) -or $CurrentPath -eq ":DRIVES") {
        $entries += [PSCustomObject]@{
            Id = ":CANCEL"; Kind = "action"; Label = "[ Cancel ]"; FullPath = ""
        }

        $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Root -match '^[A-Za-z]:\\$' } |
            Sort-Object -Property Name)

        foreach ($drive in $drives) {
            $root = $drive.Root.TrimEnd('\')
            $labelExtra = ""
            try {
                $vol = Get-Volume -DriveLetter $drive.Name -ErrorAction SilentlyContinue
                if ($vol -and -not [string]::IsNullOrWhiteSpace($vol.FileSystemLabel)) {
                    $labelExtra = "  ($($vol.FileSystemLabel))"
                }
            }
            catch { }

            $entries += [PSCustomObject]@{
                Id = $root; Kind = "drive"; Label = ("{0}\{1}" -f $root, $labelExtra).TrimEnd(); FullPath = "$root\"
            }
        }

        return $entries
    }

    $normalized = $CurrentPath
    if (-not (Test-Path -LiteralPath $normalized -ErrorAction SilentlyContinue)) {
        return @([PSCustomObject]@{ Id = ":DRIVES"; Kind = "nav"; Label = "..  (drives)"; FullPath = ":DRIVES" })
    }

    $parent = Split-Path -Path $normalized -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $normalized) {
        $entries += [PSCustomObject]@{ Id = ":DRIVES"; Kind = "nav"; Label = "..  (drives)"; FullPath = ":DRIVES" }
    }
    else {
        $entries += [PSCustomObject]@{ Id = $parent; Kind = "nav"; Label = ".."; FullPath = $parent }
    }

    try {
        $dirs = @(Get-ChildItem -LiteralPath $normalized -Directory -Force -ErrorAction Stop | Sort-Object -Property Name)
        foreach ($dir in $dirs) {
            $entries += [PSCustomObject]@{ Id = $dir.FullName; Kind = "dir"; Label = "[+] $($dir.Name)"; FullPath = $dir.FullName }
        }
    }
    catch {
        $entries += [PSCustomObject]@{
            Id = ":ERROR"; Kind = "action"; Label = "(cannot list folders: $($_.Exception.Message))"; FullPath = ""
        }
    }

    try {
        $isos = @(Get-ChildItem -LiteralPath $normalized -File -Force -ErrorAction Stop |
            Where-Object { $_.Extension -match '^\.iso$' } |
            Sort-Object -Property Name)
        foreach ($iso in $isos) {
            $sizeGb = [math]::Round($iso.Length / 1GB, 2)
            $entries += [PSCustomObject]@{
                Id = $iso.FullName; Kind = "iso"; Label = "$($iso.Name)  (${sizeGb} GB)"; FullPath = $iso.FullName
            }
        }
    }
    catch { }

    return $entries
}

function Get-DefaultIsoBrowseRoot {
    <#
      isos\ next to the script is the project's convention for keeping Windows and Features
      on Demand media together. When that folder exists and holds at least one .iso, open
      the browser there instead of at the drive list.
    #>
    $isoFolder = Join-Path -Path $PSScriptRoot -ChildPath "isos"
    if (Test-Path -LiteralPath $isoFolder -PathType Container) {
        $found = @(Get-ChildItem -LiteralPath $isoFolder -File -Filter "*.iso" -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1)
        if ($found.Count -gt 0) { return $isoFolder }
    }
    return ":DRIVES"
}

function Show-IsoFilePicker {
    # Arrow-key file browser: drives -> folders -> select a .iso file.
    param(
        [string]$StartPath = ":DRIVES",
        [string]$Title = "Select ISO file",
        [string]$Subtitle = "Enter opens folder / selects .iso"
    )

    $currentPath = $StartPath
    $index = 0
    $useRawUi = Test-MenuHostSupported

    # Unlike the menus, this header is not constant: it carries the folder being
    # browsed. Walking the rows inside one folder repaints the list alone; stepping
    # into a folder changes the header, so the anchor is dropped and the whole screen
    # is drawn again - which is once per folder rather than once per arrow key.
    $anchor = $null
    $windowTop = $null
    $anchoredPath = $null

    while ($true) {
        $entries = @(Get-FilePickerEntries -CurrentPath $currentPath)
        if ($entries.Count -eq 0) {
            $entries = @([PSCustomObject]@{ Id = ":DRIVES"; Kind = "nav"; Label = "..  (drives)"; FullPath = ":DRIVES" })
        }

        if ($index -ge $entries.Count) { $index = $entries.Count - 1 }
        if ($index -lt 0) { $index = 0 }

        $displayPath = $currentPath
        if ($displayPath -eq ":DRIVES") { $displayPath = "This PC (drives)" }

        $repainted = $false
        if ($null -ne $anchor -and $anchoredPath -eq $displayPath -and -not (Test-MenuWindowScrolled -TopBefore $windowTop)) {
            if (Set-MenuCursorAnchor -Anchor $anchor) {
                $repainted = (Clear-MenuBelowCursor)
                if (-not $repainted) { $anchor = $null }
            }
            else {
                $anchor = $null
            }
        }

        if (-not $repainted) {
            Show-MenuHeader -Title $Title -Subtitle $Subtitle -StatusLines ([ordered]@{ path = $displayPath })
            $anchor = Get-MenuCursorAnchor
            $anchoredPath = $displayPath
        }

        $maxVisible = 16
        $windowStart = 0
        if ($entries.Count -gt $maxVisible) {
            $windowStart = $index - [math]::Floor($maxVisible / 2)
            if ($windowStart -lt 0) { $windowStart = 0 }
            if (($windowStart + $maxVisible) -gt $entries.Count) { $windowStart = $entries.Count - $maxVisible }
        }
        $windowEnd = [Math]::Min(($windowStart + $maxVisible - 1), ($entries.Count - 1))

        if ($windowStart -gt 0) { Write-Studio -Text "    ..." -Key "muted" }

        for ($i = $windowStart; $i -le $windowEnd; $i++) {
            $entry = $entries[$i]
            # Palette keys, not ConsoleColor names - see the note in New-Vhdx.ps1's
            # copy of this picker. Cyan, Yellow and DarkGray are not in the table, so
            # every row fell back to `fg`.
            $color = "fg"
            if ($entry.Kind -eq "dir" -or $entry.Kind -eq "drive") { $color = "warn" }
            elseif ($entry.Kind -eq "nav") { $color = "accent" }

            if ($i -eq $index) {
                Write-Studio -Text "  > " -Key "accent" -NoNewline
                Write-Studio -Text $entry.Label -Key "fg"
            }
            else {
                Write-Host "    " -NoNewline
                Write-Studio -Text $entry.Label -Key $color
            }
        }

        if ($windowEnd -lt ($entries.Count - 1)) { Write-Studio -Text "    ..." -Key "muted" }

        # Closed the same way every other blade is: one blank line, then the rule, then
        # what the keys do. Without it the list simply stopped in the middle of the
        # screen with nothing under it.
        Write-Host ""
        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
        if ($useRawUi) {
            Write-Studio -Text "  Up/Down move   Enter open/select   Backspace up   Esc cancel" -Key "muted"
        }
        else {
            Write-Studio -Text "  Enter a number, or blank to cancel." -Key "muted"
        }
        Write-Host ""

        $chosen = $null
        # Read when the frame is COMPLETE, never half way through it. A frame taller
        # than the window scrolls as its last lines are written, so a top measured
        # before the list was drawn always disagrees with the one measured after - and
        # the guard then declared a scroll on every keypress and redrew the whole
        # screen, which is the flicker coming back on exactly the tall blades.
        $windowTop = Get-MenuWindowTop
        if ($useRawUi) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            switch ($key.VirtualKeyCode) {
                38 { $index--; continue }              # Up
                40 { $index++; continue }              # Down
                27 { return $null }                    # Esc
                13 { $chosen = $entries[$index] }      # Enter
                default { continue }
            }
        }
        else {
            $raw = Read-Host "Selection"
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            if ($raw -notmatch '^\d+$') { continue }
            $num = [int]$raw
            if ($num -lt 1 -or $num -gt $entries.Count) { continue }
            $chosen = $entries[$num - 1]
        }

        if ($chosen.Kind -eq "action") {
            if ($chosen.Id -eq ":CANCEL") { return $null }
            continue
        }
        if ($chosen.Kind -eq "nav" -or $chosen.Kind -eq "dir" -or $chosen.Kind -eq "drive") {
            $currentPath = $chosen.FullPath
            $index = 0
            continue
        }
        if ($chosen.Kind -eq "iso") { return $chosen.FullPath }
    }
}

function Mount-IsoAndGetRoot {
    # Mounts an ISO, returns its drive root (e.g. "E:"), and tracks it for dismount at exit.
    param([string]$IsoFilePath)

    if (-not (Test-Path -LiteralPath $IsoFilePath -PathType Leaf)) {
        throw "ISO file not found: $IsoFilePath"
    }

    $existing = Get-DiskImage -ImagePath $IsoFilePath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Attached) {
        Write-Log "ISO already mounted: $IsoFilePath" -Tag "Debug"
    }
    else {
        Write-Log "Mounting ISO '$IsoFilePath'" -Tag "Run"
        Mount-DiskImage -ImagePath $IsoFilePath -ErrorAction Stop | Out-Null
        if ($script:mountedIsoPaths -notcontains $IsoFilePath) {
            $script:mountedIsoPaths += $IsoFilePath
        }
    }

    $volume = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $diskImage = Get-DiskImage -ImagePath $IsoFilePath -ErrorAction SilentlyContinue
        if ($diskImage) {
            $volume = $diskImage | Get-Volume -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter } | Select-Object -First 1
        }
        if ($volume) { break }
        Start-Sleep -Milliseconds 300
    }

    if (-not $volume -or -not $volume.DriveLetter) {
        throw "ISO mounted but no drive letter was assigned"
    }
    return "$($volume.DriveLetter):"
}

function Dismount-TrackedIsos {
    # Only ISOs this run mounted itself are dismounted; anything already attached is left alone.
    foreach ($isoPath in @($script:mountedIsoPaths)) {
        try {
            Dismount-DiskImage -ImagePath $isoPath -ErrorAction Stop | Out-Null
            Write-Log "Dismounted ISO '$isoPath'" -Tag "Info"
        }
        catch {
            Write-Log "Could not dismount ISO '$isoPath': $($_.Exception.Message)" -Tag "Warn"
        }
    }
    $script:mountedIsoPaths = @()
}

#endregion ISO picker

function Get-NormalizedVmName {
    param([string]$Name)
    $n = ([string]$Name).Trim().ToLowerInvariant()
    if ($n.Length -gt 15) { $n = $n.Substring(0, 15) }
    return $n
}

function Get-ServerComputerName {
    param([object]$Server)
    return (Get-NormalizedVmName -Name ([string]$Server.name))
}

function Get-ServerDomainSuffix {
    <#
      Lower-case DNS domain for a server when domain join is configured and
      resolvable, otherwise "". Never throws.
    #>
    param([object]$Server)

    $resolved = $null
    try {
        $resolved = Resolve-DomainJoinForServer -Server $Server
    }
    catch {
        $resolved = $null
    }
    if ($null -eq $resolved) {
        return ""
    }

    return ([string]$resolved.domain).Trim().TrimEnd('.').ToLowerInvariant()
}

function Get-ServerNamingSuffix {
    <#
      The suffix Hyper-V object names and folders append. defaults.naming.fqdn wins over
      the domain join, because the first DC of a fresh forest creates the domain instead
      of joining one and so has no join account to read a domain from. "" when neither is
      set. Never throws.
    #>
    param([object]$Server)

    if (-not [string]::IsNullOrWhiteSpace($script:NamingFqdnOverride)) {
        return $script:NamingFqdnOverride
    }

    return (Get-ServerDomainSuffix -Server $Server)
}

function Get-HyperVVmName {
    <#
      Hyper-V object name. With defaults.naming.vmNameIncludeFqdn (default off) and a
      naming suffix - defaults.naming.fqdn, or the VM's own domain join - use
      computerName.domain (e.g. paw-01.ad.example.invalid).
      Guest NetBIOS / unattend ComputerName always stays short.
    #>
    param([object]$Server)

    $computerName = Get-ServerComputerName -Server $Server
    if ([string]::IsNullOrWhiteSpace($computerName)) {
        return $computerName
    }
    if (-not $script:NamingVmIncludeFqdn) {
        return $computerName
    }

    $domain = Get-ServerNamingSuffix -Server $Server
    if ([string]::IsNullOrWhiteSpace($domain)) {
        return $computerName
    }

    return ("{0}.{1}" -f $computerName, $domain)
}

function Get-ServerFolderName {
    <#
      Leaf folder under vmPath / vhdPath. Short computer name unless
      defaults.naming.folderIncludeFqdn is on (only honoured when the Hyper-V VM
      name itself carries the FQDN).
    #>
    param([object]$Server)

    $computerName = Get-ServerComputerName -Server $Server
    if ([string]::IsNullOrWhiteSpace($computerName)) {
        return $computerName
    }
    if (-not $script:NamingVmIncludeFqdn -or -not $script:NamingFolderIncludeFqdn) {
        return $computerName
    }

    $domain = Get-ServerNamingSuffix -Server $Server
    if ([string]::IsNullOrWhiteSpace($domain)) {
        return $computerName
    }

    return ("{0}.{1}" -f $computerName, $domain)
}

function Set-NamingOptionsFromDefaults {
    param([object]$Defaults)

    $script:NamingVmIncludeFqdn = $false
    $script:NamingFolderIncludeFqdn = $false
    $script:NamingFqdnOverride = ""

    $naming = $null
    if ($null -ne $Defaults) { $naming = $Defaults.naming }
    if ($null -eq $naming) { return }

    if ($null -ne $naming.vmNameIncludeFqdn) {
        $script:NamingVmIncludeFqdn = [bool]$naming.vmNameIncludeFqdn
    }
    if ($null -ne $naming.folderIncludeFqdn) {
        $script:NamingFolderIncludeFqdn = [bool]$naming.folderIncludeFqdn
    }
    if ($null -ne $naming.fqdn) {
        $script:NamingFqdnOverride = ([string]$naming.fqdn).Trim().TrimEnd('.').ToLowerInvariant()
    }
    if (-not $script:NamingVmIncludeFqdn) {
        $script:NamingFolderIncludeFqdn = $false
        $script:NamingFqdnOverride = ""
    }
}

function Select-ServersFromConfig {
    param(
        [object[]]$Servers,
        [string[]]$VmNameFilter
    )

    if (-not $VmNameFilter -or $VmNameFilter.Count -eq 0) {
        return @($Servers)
    }

    $wanted = @($VmNameFilter | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ -ne "" } | Select-Object -Unique)
    $selected = @()
    $missing = @()
    foreach ($want in $wanted) {
        $wantShort = Get-NormalizedVmName -Name $want
        $match = @(
            $Servers | Where-Object {
                $cn = Get-ServerComputerName -Server $_
                $hv = Get-HyperVVmName -Server $_
                ($cn -eq $want) -or ($cn -eq $wantShort) -or ($hv -eq $want)
            }
        )
        if ($match.Count -eq 0) {
            $missing += $want
        }
        else {
            $selected += $match[0]
        }
    }

    if ($missing.Count -gt 0) {
        throw "VM name(s) not found in config: $($missing -join ', ')"
    }

    return $selected
}

function Invoke-BuildPreflight {
    param(
        [object]$Defaults,
        [object[]]$Servers,
        [object[]]$GoldImages,
        [string]$VhdxDirectory,
        [string]$VmPath,
        [string]$VhdPath,
        [object[]]$VhdSets = @()
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $ok = New-Object System.Collections.Generic.List[string]

    $ok.Add("Config loaded ($($Servers.Count) server(s) in scope)")
    $ok.Add("Gold folder: $VhdxDirectory ($($GoldImages.Count) hv-*.vhdx)")
    $ok.Add("VM path: $VmPath")
    $ok.Add("VHD path: $VhdPath")

    if (-not (Test-Path -LiteralPath $VmPath)) {
        $warnings.Add("VM path does not exist yet (will be created): $VmPath")
    }
    if (-not (Test-Path -LiteralPath $VhdPath)) {
        $warnings.Add("VHD path does not exist yet (will be created): $VhdPath")
    }

    $placementVolumes = @(Get-StoragePlacementVolumes -Defaults $Defaults)
    if ($placementVolumes.Count -gt 0) {
        $usableVolumes = 0
        foreach ($volume in $placementVolumes) {
            $freeBytes = Get-PathVolumeFreeBytes -Path $volume.VhdPath
            if ($null -eq $freeBytes) {
                $warnings.Add("Placement volume $($volume.Index + 1) '$($volume.VhdPath)' free space is unreadable - it will be skipped")
                continue
            }
            $usableVolumes++
            $ok.Add("Placement volume $($volume.Index + 1): '$($volume.VhdPath)' ($([math]::Round($freeBytes / 1GB)) GB free)")
        }
        if ($usableVolumes -eq 0) {
            $errors.Add("Automatic storage placement is enabled but no volume is usable")
        }
    }
    elseif ($Defaults -and $Defaults.storagePlacement -and ([string]$Defaults.storagePlacement.mode) -eq "auto") {
        $errors.Add("Automatic storage placement is enabled but storagePlacement.volumes is empty")
    }

    $switchCache = @{}
    foreach ($server in $Servers) {
        $computerName = Get-ServerComputerName -Server $server
        if ([string]::IsNullOrWhiteSpace($computerName)) {
            $errors.Add("A server entry is missing name")
            continue
        }
        $hyperVName = Get-HyperVVmName -Server $server
        $folderName = Get-ServerFolderName -Server $server
        $label = if ($hyperVName -ne $computerName) {
            "VM '$hyperVName' (guest $computerName)"
        }
        else {
            "VM '$computerName'"
        }

        $goldForPreview = ""
        try {
            $gold = Resolve-GoldVhdxPath -GoldImages $GoldImages -ImageId ([string]$server.imageId) `
                -ImageHint ([string]$server.imageHint) -ServerName ([string]$server.name)
            $goldForPreview = $gold
            $ok.Add("$label gold -> $(Split-Path -Leaf $gold)")
        }
        catch {
            $errors.Add("$label gold image: $($_.Exception.Message)")
        }

        $pwdPlain = Convert-ToPlainText -Value $server.localUserPassword
        if ([string]::IsNullOrWhiteSpace($pwdPlain)) {
            $errors.Add("$label localUserPassword is empty")
        }
        elseif ([string]::IsNullOrWhiteSpace($goldForPreview)) {
            # The unattend preview reads the gold's sidecar to resolve locale "default".
            # Without a gold it can only fail for a reason already reported above, so it
            # is skipped rather than turned into a second error about the same thing.
            $ok.Add("$label local password present")
            Write-Log "$label unattend preview skipped - no gold" -Tag "Debug"
        }
        else {
            $ok.Add("$label local password present")

            # Generate the real unattend and parse it - the exact content that will
            # be injected. Catches what only shows up in the guest as the Windows
            # Setup "internal error ... unattend answer file" dialog otherwise.
            try {
                $isClientPreview = Test-IsClientProvision -Server $server -GoldPath $goldForPreview
                $unattendPreview = Get-ServerUnattendContent -Server $server -Defaults $Defaults -IsClient:$isClientPreview `
                    -GoldPath $goldForPreview
                Test-UnattendXml -UnattendContent $unattendPreview -Label $label
                if ($isClientPreview) {
                    $ok.Add("$label unattend.xml generates and parses (client OOBE skips)")
                }
                else {
                    $ok.Add("$label unattend.xml generates and parses")
                }
            }
            catch {
                $errors.Add("$label unattend: $($_.Exception.Message)")
            }
        }

        if ([bool]$server.appCompatFod) {
            if (([string]$server.experience).Trim() -ne "Core") {
                $warnings.Add("$label appCompatFod is only valid on Server Core images - ignored on '$($server.experience)'")
            }
            else {
                # The medium was already settled for this run by Resolve-FodPlans.
                $plan = Get-AppCompatPlan -Server $server
                $planMode = if ($plan) { [string]$plan.Mode } else { "Online" }
                if ($planMode -eq "Skip") {
                    $ok.Add("$label Server Core App Compat FOD skipped by choice")
                }
                elseif ($planMode -eq "Offline") {
                    $ok.Add("$label Server Core App Compat FOD from '$($plan.Source)'")
                }
                else {
                    $warnings.Add("$label Server Core App Compat FOD installs online in the guest at first boot (needs internet or a WSUS that allows optional content)")
                }
            }
        }

        # Data disk volumes. Nothing here can be verified against the guest, but a bad
        # letter or file system would only surface as a silent no-op at first boot.
        $diskPlan = @(Get-ServerDataDiskPlan -Server $server)
        $usedLetters = @{}
        foreach ($diskEntry in $diskPlan) {
            $diskLabel = "$label data disk $($diskEntry.FileName)"
            $fileSystem = [string]$diskEntry.FileSystem
            if ($fileSystem -eq "None") {
                $ok.Add("$diskLabel stays raw (no letter, no format)")
                continue
            }
            if ($script:DataDiskFileSystems -notcontains $fileSystem) {
                $errors.Add("$diskLabel has an unknown fileSystem '$fileSystem' (expected: $($script:DataDiskFileSystems -join ', '), or None)")
                continue
            }
            # ReFS creation is an Enterprise capability on the client. Enterprise N and
            # multi-session are Enterprise underneath, so they can; Pro and Pro N cannot.
            if ($fileSystem -eq "ReFS" -and (Test-IsClientProvision -Server $server) -and
                ([string]$server.imageId).ToLowerInvariant() -notmatch "^w1[01]-enterprise") {
                $errors.Add("$diskLabel is ReFS, which '$($server.imageId)' cannot create - use NTFS")
            }

            $letter = [string]$diskEntry.Letter
            if ($letter -notmatch '^[A-Z]$') {
                $errors.Add("$diskLabel has an invalid drive letter '$letter' (single letter A-Z)")
            }
            elseif ($letter -in @("A", "B", "C")) {
                $errors.Add("$diskLabel wants '$letter`:' - reserved for floppies and the OS volume")
            }
            elseif ($usedLetters.ContainsKey($letter)) {
                $errors.Add("$diskLabel wants '$letter`:' but $($usedLetters[$letter]) already claims it")
            }
            else {
                $usedLetters[$letter] = $diskEntry.FileName
                $ok.Add("$diskLabel formats $fileSystem as $letter`: '$($diskEntry.Label)' at first boot")
            }
        }

        $rsatWanted = @()
        if ($server.rsatCapabilities) {
            $rsatWanted = @($server.rsatCapabilities | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" })
        }
        if ($rsatWanted.Count -gt 0) {
            $rsatPlan = Get-RsatPlan
            $rsatMode = if ($rsatPlan) { [string]$rsatPlan.Mode } else { "Online" }
            if ($rsatMode -eq "Skip") {
                $ok.Add("$label $($rsatWanted.Count) RSAT capability(ies) skipped by choice")
            }
            elseif ($rsatMode -eq "Offline") {
                $ok.Add("$label $($rsatWanted.Count) RSAT capability(ies) from '$($rsatPlan.Source)'")
            }
            else {
                $warnings.Add("$label $($rsatWanted.Count) RSAT capability(ies) install online in the guest at first boot - slow, one Windows Update download each")
            }
        }

        $clientFeaturesWanted = @()
        if ($server.clientFeatures) {
            $clientFeaturesWanted = @($server.clientFeatures | ForEach-Object { [string]$_ } | Where-Object { $_ -ne "" })
        }
        if ($clientFeaturesWanted.Count -gt 0) {
            # Client-only, and gated on the imageId shape for the same reason the offline
            # enable is: these feature names exist in a Windows client image and nowhere else.
            if (([string]$server.imageId).ToLowerInvariant() -match "^w1[01]-") {
                $ok.Add("$label $($clientFeaturesWanted.Count) Windows feature(s) enabled offline from the image: $($clientFeaturesWanted -join ', ')")
            }
            else {
                $warnings.Add("$label clientFeatures is only valid on Windows client images - ignored on '$($server.imageId)'")
            }
        }

        if (Test-BuiltInAdminOnly -Server $server) {
            $ok.Add("$label built-in Administrator only (no extra local account)")
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$server.localUserName)) {
            $warnings.Add("$label localUserName empty (will default to localadmin)")
        }

        $sw = [string]$server.switchName
        if (-not [string]::IsNullOrWhiteSpace($sw)) {
            if (-not $switchCache.ContainsKey($sw)) {
                $switchCache[$sw] = [bool](Get-VMSwitch -Name $sw -ErrorAction SilentlyContinue)
            }
            if ($switchCache[$sw]) {
                $ok.Add("$label switch '$sw' exists")
            }
            else {
                $errors.Add("$label switch '$sw' was not found on this host")
            }
        }
        else {
            $warnings.Add("$label has no switchName (VM will have no NIC connected)")
        }

        $existingVm = Get-VM -Name $hyperVName -ErrorAction SilentlyContinue
        if ($existingVm) {
            $errors.Add("$label already exists on this host")
        }
        elseif ($hyperVName -ne $folderName -and (Get-VM -Name $folderName -ErrorAction SilentlyContinue)) {
            $errors.Add("VM '$folderName' already exists (blocks create+rename to '$hyperVName')")
        }
        else {
            $ok.Add("$label name is free")
        }

        $osDiskName = Get-OsDiskFileName -VmName $computerName -ForLinux:(Test-IsLinuxServer -Server $server)
        if (-not [string]::IsNullOrWhiteSpace([string]$server.osDiskFileName)) {
            $osDiskName = [string]$server.osDiskFileName
        }
        # Mirror the per-VM path override the build path applies.
        $serverVmRoot = Resolve-ServerPathRoot -Server $server -Property "vmPath" -Fallback $VmPath
        $serverVhdRoot = Resolve-ServerPathRoot -Server $server -Property "vhdPath" -Fallback $VhdPath
        if ([string]::IsNullOrWhiteSpace($serverVhdRoot)) {
            $serverVhdRoot = $serverVmRoot
        }
        if ($serverVmRoot -ne $VmPath -or $serverVhdRoot -ne $VhdPath) {
            $ok.Add("$label uses per-VM paths: VM '$serverVmRoot' / VHD '$serverVhdRoot'")
        }

        $childVhd = Join-Path -Path (Join-Path -Path $serverVhdRoot -ChildPath $folderName) -ChildPath $osDiskName
        if (Test-Path -LiteralPath $childVhd) {
            $errors.Add("$label OS disk already exists: $childVhd")
        }

        $dj = $null
        $djResolveFailed = $false
        try {
            $dj = Resolve-DomainJoinForServer -Server $server
        }
        catch {
            $errors.Add("$label $($_.Exception.Message)")
            $dj = $null
            $djResolveFailed = $true
        }
        if ($server.domainJoin -and [bool]$server.domainJoin.enabled) {
            $joinIp = ([string]$server.ipAddress).Trim()
            if ($null -eq $dj) {
                if (-not $djResolveFailed) {
                    $errors.Add("$label domainJoin enabled but domain/joinUser/joinPassword incomplete (check accountId)")
                }
            }
            elseif ([string]::IsNullOrWhiteSpace($joinIp)) {
                $errors.Add("$label domainJoin requires ipAddress (static IP before join; no DHCP on target VLAN)")
            }
            else {
                $ou = ([string]$dj.ouPath).Trim()
                $domain = ([string]$dj.domain).Trim()
                $joinVia = if ($dj.mode -eq "deferred") { "VmDeploy-DomainJoin task after first boot (unattend stays join-free)" } else { "specialize (TCPIP + UnattendedJoin)" }
                if ([string]::IsNullOrWhiteSpace($ou)) {
                    $ok.Add("$label domain join via $joinVia -> $domain (default Computers container; OU optional); Hyper-V name = $hyperVName")
                }
                else {
                    $ok.Add("$label domain join via $joinVia -> $domain / $ou; Hyper-V name = $hyperVName")
                }
            }
        }

        $arcCfg = $null
        try {
            $arcCfg = Get-EffectiveAzureArcConfig -Server $server -Defaults $Defaults
        }
        catch {
            if ($server.azureArc -and [bool]$server.azureArc.enabled) {
                $errors.Add("$label $($_.Exception.Message)")
            }
        }
        if ($arcCfg) {
            $ok.Add("$label Azure Arc -> RG '$($arcCfg.resourceGroup)' ($($arcCfg.location)) via $($arcCfg.authMode)")
        }

        $ip = ([string]$server.ipAddress).Trim()
        if (-not [string]::IsNullOrWhiteSpace($ip) -and $ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            $errors.Add("$label invalid ipAddress '$ip'")
        }
    }

    if ($Defaults.cluster -and [bool]$Defaults.cluster.enabled) {
        if (Get-Command -Name "Add-ClusterVirtualMachineRole" -ErrorAction SilentlyContinue) {
            $ok.Add("Failover clustering cmdlets available")
        }
        else {
            $errors.Add("Cluster enabled in config but FailoverClusters module / Add-ClusterVirtualMachineRole is missing")
        }

        # Per-VM opt-in written by the studio's Failover Cluster blade; absent = pre-blade config (all VMs).
        $clusterOptIn = @($Servers | Where-Object { $null -ne $_.cluster })
        if ([bool]$Defaults.cluster.addAllVms) {
            $ok.Add("Clustered VMs: all $($Servers.Count) (config sets addAllVms)")
        }
        elseif ($clusterOptIn.Count -gt 0) {
            $clusterMembers = @($clusterOptIn | Where-Object { [bool]$_.cluster.enabled })
            if ($clusterMembers.Count -eq 0) {
                $warnings.Add("Cluster is enabled but no VM is marked as clustered - nothing will be registered with the cluster")
            }
            else {
                $ok.Add("Clustered VMs: $($clusterMembers.Count) of $($Servers.Count)")
            }
        }
        else {
            $warnings.Add("Config has no per-VM cluster selection - every VM will be registered as a clustered role")
        }
    }

    # VHD Sets need CSV or SMB 3 - local NTFS (e.g. G:\Virtual Hard Disks\vhds) always fails at attach.
    $serverNameSet = @{}
    foreach ($s in $Servers) {
        $cn = (Get-ServerComputerName -Server $s).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($cn)) {
            $serverNameSet[$cn] = $true
        }
    }

    $sequenceByKey = @{}
    foreach ($set in @($VhdSets)) {
        $attachTo = @()
        if ($set.attachTo) {
            $attachTo = @($set.attachTo | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ -ne "" })
        }

        $key = (@($attachTo | ForEach-Object { Get-DiskNameToken -Name $_ } | Sort-Object -Unique) -join "|")
        if (-not $sequenceByKey.ContainsKey($key)) {
            $sequenceByKey[$key] = 0
        }
        $sequenceByKey[$key] = [int]$sequenceByKey[$key] + 1
        $seq = [int]$sequenceByKey[$key]

        $autoFile = Get-VhdSetFileName -AttachTo $attachTo -Sequence $seq
        $setLabel = ([string]$set.name).Trim()
        if ([string]::IsNullOrWhiteSpace($setLabel)) {
            $setLabel = [System.IO.Path]::GetFileNameWithoutExtension($autoFile)
        }

        if ($attachTo.Count -lt 2) {
            $warnings.Add("VHD Set '$setLabel' has fewer than 2 attachTo members (guest cluster usually needs 2+)")
        }

        foreach ($member in $attachTo) {
            if (-not $serverNameSet.ContainsKey($member)) {
                $warnings.Add("VHD Set '$setLabel' attaches to '$member' which is not in the current server selection")
            }
        }

        $path = Resolve-VhdSetTargetPath -Set $set -VhdRoot $VhdPath -AttachTo $attachTo -Sequence $seq
        if (-not (Test-PathSupportsVhdSharing -Path $path)) {
            $errors.Add("VHD Set '$setLabel' path '$path' is not on CSV or SMB 3. Hyper-V refuses shared VHD attach on local NTFS. Use e.g. C:\ClusterStorage\Volume1\vhds\ or \\server\share\vhds\ (custom path in studio).")
        }
        else {
            $ok.Add("VHD Set '$setLabel' shareable path OK ($path)")
        }
    }

    # Quiet by default: passing checks are only interesting in aggregate. Every
    # warning and error is still printed in full (they are what needs acting on),
    # and the per-check detail stays in the -Verbose stream for triage.
    foreach ($line in $ok) {
        Write-Verbose "OK   $line"
    }
    foreach ($line in $warnings) {
        Write-Log "WARN $line" -Tag "Info"
    }
    foreach ($line in $errors) {
        Write-Log "FAIL $line" -Tag "Error"
    }

    if ($errors.Count -eq 0) {
        if ($warnings.Count -eq 0) {
            Write-Log "Preflight: $($ok.Count) check(s)" -Tag "Ok"
        }
        else {
            Write-Log "Preflight: $($ok.Count) check(s), $($warnings.Count) warning(s)" -Tag "Ok"
        }
        return $true
    }

    Write-Log "Preflight failed: $($errors.Count) error(s), $($warnings.Count) warning(s)" -Tag "Error"
    return $false
}

function Invoke-BuildPreflightForGroups {
    <#
        Preflight, run once per config the selection touches, each with its own
        defaults, gold folder and paths. Every group is checked even after one fails -
        somebody fixing a lab wants the whole list, not the first line of it.
    #>
    param(
        [object[]]$Groups,
        [object[]]$VhdSets,
        [object]$FallbackDefaults,
        [string]$FallbackVhdxDirectory,
        [string]$FallbackVmPath,
        [string]$FallbackVhdPath
    )

    $allPassed = $true
    foreach ($group in $Groups) {
        $groupDefaults = $FallbackDefaults
        $groupVhdx = $FallbackVhdxDirectory
        $groupVmPath = $FallbackVmPath
        $groupVhdPath = $FallbackVhdPath

        if ($null -ne $group.Source) {
            Set-ActiveConfigSource -Source $group.Source
            $resolved = Resolve-ConfigSourcePaths -Source $group.Source `
                -FallbackVmPath $FallbackVmPath -FallbackVhdPath $FallbackVhdPath
            $groupDefaults = $group.Source.Defaults
            $groupVhdx = $resolved.VhdxDirectory
            $groupVmPath = $resolved.VmPath
            $groupVhdPath = $resolved.VhdPath
            if ($Groups.Count -gt 1) { Write-Log ("Preflight for '{0}'" -f $group.Source.Name) -Tag "Info" }
        }

        $goldImages = @(Get-HyperVGoldImages -VhdxDirectory $groupVhdx)
        $passed = Invoke-BuildPreflight -Defaults $groupDefaults -Servers $group.Servers `
            -GoldImages $goldImages -VhdxDirectory $groupVhdx -VmPath $groupVmPath -VhdPath $groupVhdPath `
            -VhdSets $VhdSets
        if (-not $passed) { $allPassed = $false }
    }
    return $allPassed
}

function Resolve-ConfigSourcePaths {
    <#
        The gold folder and the VM/VHD roots for one source, with the host defaults the
        caller already resolved standing in for anything the file leaves blank.

        The resolved roots are STAMPED BACK into that source's defaults, which is the
        part that matters. New-ProvisionedVm does not receive a path - it reads
        $Defaults.vmPath itself, several layers down. Startup has always done this for
        the one config it loaded; with several, every source needs it, or a config that
        leaves vmPath blank (relying on the Hyper-V host default) reaches Join-Path with
        an empty string and every VM in it fails with

            Cannot bind argument to parameter 'Path' because it is an empty string.

        Idempotent on purpose: preflight and the build both call it.
    #>
    param([object]$Source, [string]$FallbackVmPath, [string]$FallbackVhdPath)

    $vhdx = Resolve-ConfiguredHostPath -ConfiguredPath ([string]$Source.Defaults.vhdxDirectory) `
        -PromptLabel "Gold VHDX directory" -ExampleHint "vhdx" -DefaultWhenEmpty "vhdx"

    $vmPath = [string]$Source.Defaults.vmPath
    if ([string]::IsNullOrWhiteSpace($vmPath)) { $vmPath = $FallbackVmPath }
    $vhdPath = [string]$Source.Defaults.vhdPath
    if ([string]::IsNullOrWhiteSpace($vhdPath)) { $vhdPath = $vmPath }

    $Source.Defaults | Add-Member -NotePropertyName "vmPath" -NotePropertyValue $vmPath -Force
    $Source.Defaults | Add-Member -NotePropertyName "vhdPath" -NotePropertyValue $vhdPath -Force

    return [pscustomobject]@{ VhdxDirectory = $vhdx; VmPath = $vmPath; VhdPath = $vhdPath }
}

function Get-ServerConfigSource {
    # The config a server came from, or $null for one that was never tagged.
    param([object]$Server)

    if ($null -eq $Server) { return $null }
    if ($Server.PSObject.Properties.Match("_source").Count -eq 0) { return $null }
    return $Server._source
}

function Group-ServersByConfigSource {
    <#
        A selection split back into the configs it came from, in the order the sources
        were loaded so a run reads the same way twice.

        Servers with no source - a caller that built a list by hand - are returned as
        one group with a null Source, which the caller treats as "use the defaults you
        already have".
    #>
    param([object[]]$Servers, [object[]]$Sources)

    $groups = New-Object System.Collections.Generic.List[object]

    foreach ($source in @($Sources)) {
        $mine = @($Servers | Where-Object { (Get-ServerConfigSource -Server $_) -eq $source })
        if ($mine.Count -eq 0) { continue }
        $groups.Add([pscustomobject]@{ Source = $source; Servers = $mine }) | Out-Null
    }

    $orphans = @($Servers | Where-Object { $null -eq (Get-ServerConfigSource -Server $_) })
    if ($orphans.Count -gt 0) {
        $groups.Add([pscustomobject]@{ Source = $null; Servers = $orphans }) | Out-Null
    }

    return $groups.ToArray()
}

function Invoke-BuildServers {
    param(
        [object]$Defaults,
        [object[]]$Servers,
        [object[]]$GoldImages,
        [hashtable]$VhdSetMap,
        [bool]$DoStart,
        [switch]$SlowHost,
        # Set when this is one config's share of a larger run. The closing verdict is
        # then the CALLER's to give, once, at the end - said per group it claimed every
        # selected server was done and was immediately followed by the next config
        # starting, which is a contradiction on two adjacent lines.
        [switch]$PartOfLargerRun
    )

    $failed = 0

    if ($SlowHost) {
        Write-Log "Slow host 1/3 - prepare all disks" -Tag "Info"
        foreach ($server in $Servers) {
            try {
                Initialize-ProvisionVmDisks -Server $server -Defaults $Defaults -GoldImages $GoldImages | Out-Null
            }
            catch {
                $failed++
                Write-Log "Failed to prepare disks for '$(Get-HyperVVmName -Server $server)': $($_.Exception.Message)" -Tag "Error"
            }
        }
        if ($failed -gt 0) {
            Write-Log "$failed server(s) failed during disk prep - aborting before VM create" -Tag "Error"
            return $false
        }

        Write-Log "Slow host 2/3 - create VMs, inject unattend" -Tag "Info"
        $createdServers = @()
        foreach ($server in $Servers) {
            try {
                New-ProvisionedVm -Server $server -Defaults $Defaults -GoldImages $GoldImages `
                    -VhdSetMap $VhdSetMap -DoStart:$false -DisksAlreadyPrepared
                $createdServers += $server
            }
            catch {
                $failed++
                Write-Log "Failed to create '$(Get-HyperVVmName -Server $server)': $($_.Exception.Message)" -Tag "Error"
            }
            Write-Host ""
        }

        # Always start successfully created VMs at the end (unless SkipStart),
        # even when some creates failed.
        if ($DoStart -and $createdServers.Count -gt 0) {
            Write-Log "Slow-host mode: phase 3/3 - start $($createdServers.Count) created VM(s)" -Tag "Info"
            foreach ($server in $createdServers) {
                $name = Get-HyperVVmName -Server $server
                try {
                    if (-not (Test-ShouldStartProvisionedVm -Server $server -DoStart:$true)) {
                        Write-Log "Not starting '$name' - startAfterCreate=false" -Tag "Info"
                        continue
                    }
                    Write-Log "Starting VM '$name'" -Tag "Run"
                    Start-VM -Name $name | Out-Null
                }
                catch {
                    $failed++
                    Write-Log "Failed to start '$name': $($_.Exception.Message)" -Tag "Error"
                }
            }
        }
        elseif (-not $DoStart) {
            Write-Log "Slow-host mode: SkipStart set - VMs left off" -Tag "Info"
        }
        elseif ($createdServers.Count -eq 0) {
            Write-Log "Slow-host mode: no VMs created - nothing to start" -Tag "Error"
        }

        if ($failed -gt 0) {
            if (-not $PartOfLargerRun) { Write-Log "$failed server(s) failed in slow-host mode" -Tag "Error" }
            return $false
        }

        if (-not $PartOfLargerRun) { Write-Log "All selected servers provisioned - slow host" -Tag "Ok" }
        return $true
    }

    # A blank line after EVERY machine, the last one included - the summary that
    # follows it is a statement about the whole run, not about that VM, and it read as
    # though it belonged to it when the two were flush. Written whatever the outcome,
    # because the break is about where a machine ends, not whether it worked.
    foreach ($server in $Servers) {
        try {
            New-ProvisionedVm -Server $server -Defaults $Defaults -GoldImages $GoldImages `
                -VhdSetMap $VhdSetMap -DoStart:$DoStart
        }
        catch {
            $failed++
            Write-Log "Failed to provision '$(Get-HyperVVmName -Server $server)': $($_.Exception.Message)" -Tag "Error"
        }
        Write-Host ""
    }

    if ($failed -gt 0) {
        if (-not $PartOfLargerRun) { Write-Log "$failed server(s) failed" -Tag "Error" }
        return $false
    }

    if (-not $PartOfLargerRun) { Write-Log "All selected servers provisioned" -Tag "Ok" }
    return $true
}

function Get-ServerMenuLabel {
    param([object]$Server)

    $n = Get-HyperVVmName -Server $Server
    $img = [string]$Server.imageId
    if ([string]::IsNullOrWhiteSpace($img)) { $img = "custom" }
    $mem = if ($null -ne $Server.memoryGB) { [string]$Server.memoryGB } else { "4" }
    $cpu = if ($null -ne $Server.cpuCount) { [string]$Server.cpuCount } else { "2" }
    $sw = [string]$Server.switchName
    if ([string]::IsNullOrWhiteSpace($sw)) { $sw = "no switch" }
    # Columns sized for a 15-char NetBIOS name and the longest imageId - a short name
    # used to leave a 25-column gap before the image.
    return ("{0,-17} {1,-26} {2,2} GB / {3} CPU   {4}" -f $n, $img, $mem, $cpu, $sw)
}

function Format-SummaryValueList {
    # "a, b, c" - trimmed to MaxLength with a "(+N more)" tail so a long feature
    # list never wraps the summary column.
    param(
        [string[]]$Values,
        [int]$MaxLength = 44
    )

    $items = @($Values | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne "" })
    if ($items.Count -eq 0) {
        return ""
    }

    $shown = New-Object System.Collections.Generic.List[string]
    $length = 0
    foreach ($item in $items) {
        $cost = $item.Length
        if ($shown.Count -gt 0) { $cost += 2 }
        if ($shown.Count -gt 0 -and ($length + $cost) -gt $MaxLength) {
            break
        }
        $shown.Add($item) | Out-Null
        $length += $cost
    }

    $text = ($shown -join ", ")
    $hidden = $items.Count - $shown.Count
    if ($hidden -gt 0) {
        $text = "{0} (+{1} more)" -f $text, $hidden
    }
    return $text
}

function Get-ServerSummaryRows {
    <#
      Per-VM rows for the confirm screen - deliberately short: os, os disk, cpu, ram,
      vlan, ip, domain join, data disks, vhd sets, cluster. Everything else (features,
      FOD source, DNS, OU, firmware ...) stays in the log and on its own blade; this
      screen is a sanity check, not a config dump. Rows with nothing to say are dropped.
      Never throws - an unresolvable value is reported as text so the summary always
      renders (preflight already ran and is the thing that blocks a bad build).
    #>
    param(
        [object]$Server,
        [object]$Defaults,
        [object[]]$GoldImages,
        [object[]]$VhdSets
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $addRow = {
        param([string]$Name, [string]$Value)
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            $rows.Add([pscustomobject]@{ Name = $Name; Value = $Value }) | Out-Null
        }
    }

    $computerName = Get-ServerComputerName -Server $Server

    & $addRow "os" (Get-ImageDisplayName -Server $Server)

    # The gold file name is implied by the OS label, so only spell it out when the
    # config picked its image by hand or the pick cannot be resolved at all.
    $picksGoldByHand = -not [string]::IsNullOrWhiteSpace(([string]$Server.imageHint).Trim())
    try {
        $goldPath = Resolve-GoldVhdxPath -GoldImages $GoldImages -ImageId ([string]$Server.imageId) `
            -ImageHint ([string]$Server.imageHint) -ServerName ([string]$Server.name)
        if ($picksGoldByHand) {
            & $addRow "gold image" (Split-Path -Leaf $goldPath)
        }
    }
    catch {
        & $addRow "gold image" ("not resolved - {0}" -f $_.Exception.Message)
    }

    $useDiff = $false
    if ($null -ne $Server.useDifferencingDisk) { $useDiff = [bool]$Server.useDifferencingDisk }
    $osDiskName = Get-OsDiskFileName -VmName $computerName -ForLinux:(Test-IsLinuxServer -Server $Server)
    if (-not [string]::IsNullOrWhiteSpace([string]$Server.osDiskFileName)) {
        $osDiskName = [string]$Server.osDiskFileName
    }
    $diskMode = if ($useDiff) { "differencing child" } else { "full copy" }
    & $addRow "os disk" ("{0} - {1}" -f $diskMode, $osDiskName)

    $cpuCount = if ($null -ne $Server.cpuCount) { [int]$Server.cpuCount } else { 2 }
    $memoryGb = if ($null -ne $Server.memoryGB) { [int]$Server.memoryGB } else { 4 }
    & $addRow "cpu" ("{0} vCPU" -f $cpuCount)
    & $addRow "ram" ("{0} GB" -f $memoryGb)

    # Unconfigured means no row: an absent VLAN, no data disks, no VHD Set and no cluster
    # simply do not appear. The IP row is the one exception - "DHCP" is a real outcome
    # worth seeing next to a static address on the VM beside it.
    if ($null -ne $Server.vlanId -and [string]$Server.vlanId -ne "") {
        & $addRow "vlan" ([string]$Server.vlanId)
    }

    $ipAddress = ([string]$Server.ipAddress).Trim()
    & $addRow "ip" $(if ([string]::IsNullOrWhiteSpace($ipAddress)) { "DHCP" } else { $ipAddress })

    # Only worth a row when the VM is not the plain single-NIC, host-independent default.
    $extraNicRows = @()
    try {
        $extraNicRows = @(Get-ServerAdditionalNics -Server $Server | ForEach-Object {
                $where = $_.SwitchName
                if ($null -ne $_.VlanId) { $where = "{0} vlan {1}" -f $where, $_.VlanId }
                $addr = if ([string]::IsNullOrWhiteSpace($_.IpAddress)) { "DHCP" } else { "{0}/{1}" -f $_.IpAddress, $_.PrefixLength }
                "{0} ({1}, {2})" -f $_.Name, $where, $addr
            })
    }
    catch {
        $extraNicRows = @("invalid - see preflight")
    }
    if ($extraNicRows.Count -gt 0) {
        & $addRow "extra nics" (Format-SummaryValueList -Values $extraNicRows -MaxLength 44)
    }

    $summaryStartAction = Get-ServerAutomaticStartAction -Server $Server
    if ($summaryStartAction -ne "Nothing") {
        $summaryStartDelay = Get-ServerAutomaticStartDelay -Server $Server
        & $addRow "auto start" ("{0} ({1}s delay)" -f $summaryStartAction, $summaryStartDelay)
    }

    if (Test-ServerWantsNestedVirtualization -Server $Server) {
        & $addRow "nested virt" "on - MAC spoofing enabled"
    }

    $domainJoin = $null
    $domainJoinError = ""
    try {
        $domainJoin = Resolve-DomainJoinForServer -Server $Server
    }
    catch {
        $domainJoinError = $_.Exception.Message
    }
    if ($domainJoin) {
        $joinText = [string]$domainJoin.domain
        if ($domainJoin.mode -eq "deferred") { $joinText += " (task after first boot)" }
        & $addRow "domain join" $joinText
    }
    elseif (-not [string]::IsNullOrWhiteSpace($domainJoinError)) {
        & $addRow "domain join" "enabled but incomplete - see preflight"
    }

    $dataDisks = @(Get-ServerDataDiskPlan -Server $Server | ForEach-Object { Get-DataDiskPlanText -Entry $_ })
    if ($dataDisks.Count -gt 0) {
        & $addRow "data disks" (Format-SummaryValueList -Values $dataDisks -MaxLength 44)
    }

    $attachedSets = @()
    if ($VhdSets) {
        $lowerName = ([string]$computerName).ToLowerInvariant()
        $attachedSets = @($VhdSets | Where-Object {
                $members = @()
                if ($_.attachTo) {
                    $members = @($_.attachTo | ForEach-Object { ([string]$_).ToLowerInvariant().Trim() })
                }
                $members -contains $lowerName
            } | ForEach-Object {
                $setName = ([string]$_.name).Trim()
                if ([string]::IsNullOrWhiteSpace($setName)) { $setName = "VHD Set" }
                $setSize = if ($null -ne $_.sizeGB) { [int]$_.sizeGB } else { 0 }
                "{0} ({1} GB)" -f $setName, $setSize
            })
    }
    if ($attachedSets.Count -gt 0) {
        & $addRow "vhd sets" (Format-SummaryValueList -Values $attachedSets)
    }

    if ($Defaults.cluster -and [bool]$Defaults.cluster.enabled) {
        $clusterName = ([string]$Defaults.cluster.name).Trim()
        if ([string]::IsNullOrWhiteSpace($clusterName)) { $clusterName = "local cluster" }
        $isMember = $true
        if (-not [bool]$Defaults.cluster.addAllVms -and $null -ne $Server.cluster) {
            $isMember = [bool]$Server.cluster.enabled
        }
        if (-not $isMember) {
            # Not a member - nothing to say, so no row.
        }
        elseif ($null -ne $Defaults.cluster.addAfterCreate -and -not [bool]$Defaults.cluster.addAfterCreate) {
            & $addRow "cluster" ("{0} - add after create is off" -f $clusterName)
        }
        else {
            & $addRow "cluster" $clusterName
        }
    }

    return $rows.ToArray()
}

function Get-SectionLabelWidth {
    # Widest label in a Name/Value section, so its colons line up on one column.
    param(
        [object[]]$Rows,
        [int]$Minimum = 14,
        [int]$Maximum = 34
    )

    $widest = $Minimum
    foreach ($row in @($Rows)) {
        $length = ([string]$row.Name).Length
        if ($length -gt $widest) { $widest = $length }
    }
    if ($widest -gt $Maximum) { return $Maximum }
    return $widest
}

function Get-ServerSummaryCompactLine {
    # One-line form used when the detailed blocks would not fit on screen.
    param([object]$Server)

    $os = Get-ImageDisplayName -Server $Server
    $os = $os -replace '^Windows Server ', ''
    $cpuCount = if ($null -ne $Server.cpuCount) { [int]$Server.cpuCount } else { 2 }
    $memoryGb = if ($null -ne $Server.memoryGB) { [int]$Server.memoryGB } else { 4 }

    $ipAddress = ([string]$Server.ipAddress).Trim()
    if ([string]::IsNullOrWhiteSpace($ipAddress)) { $ipAddress = "DHCP" }

    $parts = @($os, ("{0} CPU / {1} GB" -f $cpuCount, $memoryGb), $ipAddress)

    if ($null -ne $Server.vlanId -and [string]$Server.vlanId -ne "") {
        $parts += ("vlan {0}" -f [string]$Server.vlanId)
    }

    $domain = Get-ServerDomainSuffix -Server $Server
    if (-not [string]::IsNullOrWhiteSpace($domain)) {
        $parts += $domain
    }

    return ($parts -join "   ")
}

function Get-BuildMenuStatusLines {
    param(
        [object[]]$Servers,
        [object[]]$GoldImages,
        [object]$Defaults,
        [object[]]$Sources = @()
    )

    $cluster = "off"
    if ($Defaults.cluster -and [bool]$Defaults.cluster.enabled) {
        $cluster = [string]$Defaults.cluster.name
        if ([string]::IsNullOrWhiteSpace($cluster)) { $cluster = "local" }
        $optIn = @($Servers | Where-Object { $null -ne $_.cluster })
        if ([bool]$Defaults.cluster.addAllVms) {
            $cluster = "{0} (all {1} VMs)" -f $cluster, $Servers.Count
        }
        elseif ($optIn.Count -gt 0) {
            $members = @($optIn | Where-Object { [bool]$_.cluster.enabled })
            $cluster = "{0} ({1}/{2} VMs)" -f $cluster, $members.Count, $Servers.Count
        }
    }

    # One config names itself; several are counted, because a header row is 24 columns
    # wide and a list of file names would be cut to nothing.
    $configText = if (@($Sources).Count -gt 1) {
        "{0} loaded" -f @($Sources).Count
    }
    elseif (@($Sources).Count -eq 1) {
        [string]$Sources[0].Name
    }
    else { "none" }

    $serverText = if (@($Sources).Count -gt 1) {
        "{0} across {1} configs" -f $Servers.Count, @($Sources).Count
    }
    else { "{0} in config" -f $Servers.Count }

    return [ordered]@{
        "config"  = $configText
        "servers" = $serverText
        "gold"    = ("{0} hv-*.vhdx" -f $GoldImages.Count)
        "cluster" = $cluster
    }
}

function Read-SelectedServersInteractive {
    param(
        [object[]]$Servers,
        [System.Collections.IDictionary]$StatusLines
    )

    # Grouped under the config each machine came from, and only when more than one is
    # in play - a single-config run should look exactly as it always did. The Section
    # header is what Show-MultiSelectMenu draws above a group; it is not selectable, so
    # it costs nothing but the line it occupies.
    $sourceNames = @($Servers | ForEach-Object { $s = Get-ServerConfigSource -Server $_; if ($null -ne $s) { $s.Name } } | Sort-Object -Unique)
    $showSource = ($sourceNames.Count -gt 1)

    $items = @()
    for ($i = 0; $i -lt $Servers.Count; $i++) {
        $section = ""
        if ($showSource) {
            $source = Get-ServerConfigSource -Server $Servers[$i]
            $section = if ($null -ne $source) { $source.Name } else { "(no config)" }
        }
        $items += [pscustomobject]@{
            Id      = [string]$i
            Label   = (Get-ServerMenuLabel -Server $Servers[$i])
            Section = $section
        }
    }

    $picked = Show-MultiSelectMenu -Title "Select virtual machines to build" -Items $items -StatusLines $StatusLines
    if ($null -eq $picked) {
        return $null
    }

    $result = @()
    foreach ($idx in $picked) {
        $result += $Servers[[int]$idx]
    }
    return $result
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "$env:COMPUTERNAME | $env:USERNAME | $scriptName" -Tag "Info"
Write-Log "Log file: $logFile" -Tag "Info"

try {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "This script must run elevated (Administrator)" -Tag "Error"
        Complete-Script -ExitCode 1
    }

    if (-not (Get-Command -Name "New-VM" -ErrorAction SilentlyContinue)) {
        Write-Log "Hyper-V cmdlets are not available" -Tag "Error"
        Complete-Script -ExitCode 1
    }

    # -ConfigPath narrows the run to one file. Without it, every config is loaded -
    # config.json beside the script and everything in configs\ - and their machines are
    # offered together. They are NOT merged: each server keeps a tag saying which file
    # it came from, and the build hands every group back its own defaults.
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $sources = @(Get-BuildConfigSources -ScriptRoot $PSScriptRoot)
    }
    else {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            Write-Log "Config not found at '$ConfigPath'" -Tag "Error"
            Write-Log "Export one from html\hyperv-vm-studio.html, then put it beside this script or in configs\" -Tag "Error"
            Complete-Script -ExitCode 1
        }
        $only = Get-ConfigObject -Path $ConfigPath
        if (-not $only.defaults) { throw "'$ConfigPath' is missing the defaults section" }
        $source = [pscustomobject]@{
            Path     = $ConfigPath
            Name     = (Split-Path -Leaf $ConfigPath)
            Config   = $only
            Defaults = $only.defaults
            Servers  = @($only.servers)
        }
        foreach ($server in $source.Servers) {
            if ($server.PSObject.Properties.Match("_source").Count -eq 0) {
                $server | Add-Member -NotePropertyName "_source" -NotePropertyValue $source
            }
        }
        $sources = @($source)
    }

    if ($sources.Count -eq 0) {
        Write-Log "No usable configuration found" -Tag "Error"
        Write-Log "Export one from html\hyperv-vm-studio.html, then put it beside this script or in configs\" -Tag "Error"
        Complete-Script -ExitCode 1
    }

    foreach ($source in $sources) {
        Write-Log ("Loaded '{0}' - {1} VM(s)" -f $source.Name, @($source.Servers).Count) -Tag "Get"
    }

    if (-not (Test-BuildConfigSourcesUnique -Sources $sources)) {
        Complete-Script -ExitCode 1
    }

    # The first source is what anything not yet grouped falls back to - the menu header,
    # the storage placement report, the gold folder listing. Every one of those is
    # re-resolved per group before a machine is built.
    $config = $sources[0].Config
    $defaults = $sources[0].Defaults
    Set-ActiveConfigSource -Source $sources[0]

    $allServers = @()
    foreach ($source in $sources) { $allServers += @($source.Servers) }
    if ($allServers.Count -eq 0) {
        throw "no servers in any configuration"
    }

    $vhdxDirectory = Resolve-ConfiguredHostPath -ConfiguredPath ([string]$defaults.vhdxDirectory) `
        -PromptLabel "Gold VHDX directory" -ExampleHint "vhdx" -DefaultWhenEmpty "vhdx"

    # Config leaves vmPath/vhdPath blank -> fall back to this Hyper-V host's own configured
    # defaults (Get-VMHost) instead of blocking on an interactive prompt, which would hang
    # an unattended/-BuildAll run. Only falls through to the prompt if Get-VMHost itself
    # is unavailable/fails.
    $hyperVHost = $null
    try {
        $hyperVHost = Get-VMHost -ErrorAction Stop
    }
    catch {
        Write-Log "Could not query Get-VMHost for default VM/VHD paths: $($_.Exception.Message)" -Tag "Warn"
    }
    $vmPathDefault = ""
    $vhdPathDefault = ""
    if ($null -ne $hyperVHost) {
        $vmPathDefault = [string]$hyperVHost.VirtualMachinePath
        $vhdPathDefault = [string]$hyperVHost.VirtualHardDiskPath
    }

    # Automatic storage placement: the volume catalog replaces the single global
    # pair. The first volume seeds the fallback defaults so nothing prompts and
    # anything outside the per-VM placement decision (logs, preflight display)
    # still has a sensible root.
    $placementVolumes = @(Get-StoragePlacementVolumes -Defaults $defaults)
    if ($placementVolumes.Count -gt 0) {
        Write-Log "Automatic storage placement: $($placementVolumes.Count) volume(s)" -Tag "Info"
        foreach ($volume in $placementVolumes) {
            $freeBytes = Get-PathVolumeFreeBytes -Path $volume.VhdPath
            $freeNote = if ($null -ne $freeBytes) { "$([math]::Round($freeBytes / 1GB)) GB free" } else { "free space unreadable" }
            Write-Log "  Volume $($volume.Index + 1): '$($volume.VmPath)' | $freeNote" -Tag "Info"
        }
        if ([string]::IsNullOrWhiteSpace([string]$defaults.vmPath)) { $vmPathDefault = $placementVolumes[0].VmPath }
        if ([string]::IsNullOrWhiteSpace([string]$defaults.vhdPath)) { $vhdPathDefault = $placementVolumes[0].VhdPath }
    }
    if ([string]::IsNullOrWhiteSpace([string]$defaults.vmPath) -and -not [string]::IsNullOrWhiteSpace($vmPathDefault)) {
        Write-Log "No vmPath in config - host default '$vmPathDefault'" -Tag "Info"
    }
    if ([string]::IsNullOrWhiteSpace([string]$defaults.vhdPath) -and -not [string]::IsNullOrWhiteSpace($vhdPathDefault)) {
        Write-Log "No vhdPath in config - host default '$vhdPathDefault'" -Tag "Info"
    }

    $vmPath = Resolve-ConfiguredHostPath -ConfiguredPath ([string]$defaults.vmPath) `
        -PromptLabel "VM path (Hyper-V config folders)" -ExampleHint "D:\Hyper-V\VMs" -DefaultWhenEmpty $vmPathDefault
    $vhdPath = Resolve-ConfiguredHostPath -ConfiguredPath ([string]$defaults.vhdPath) `
        -PromptLabel "VHD path (child / differencing disks)" -ExampleHint "D:\Hyper-V\VHDs" -DefaultWhenEmpty $vhdPathDefault
    $defaults | Add-Member -NotePropertyName "vmPath" -NotePropertyValue $vmPath -Force
    $defaults | Add-Member -NotePropertyName "vhdPath" -NotePropertyValue $vhdPath -Force

    Write-Log "VM path: $vmPath" -Tag "Info"
    Write-Log "VHD path: $vhdPath" -Tag "Info"

    # Every source, not only the one whose defaults stood in above. A config that leaves
    # vmPath blank inherits the host default resolved just now; without this it would
    # reach the VM builder as an empty string, because that builder reads
    # $Defaults.vmPath itself rather than being handed a path.
    foreach ($source in $sources) {
        $resolvedSource = Resolve-ConfigSourcePaths -Source $source -FallbackVmPath $vmPath -FallbackVhdPath $vhdPath
        if ($sources.Count -gt 1) {
            Write-Log ("  {0} -> gold '{1}', VMs '{2}'" -f $source.Name, $resolvedSource.VhdxDirectory, $resolvedSource.VmPath) -Tag "Info"
        }
    }
    $namingSuffixSource = if ([string]::IsNullOrWhiteSpace($script:NamingFqdnOverride)) { "per-VM domain join" } else { $script:NamingFqdnOverride }
    Write-Log "Naming: VM FQDN=$($script:NamingVmIncludeFqdn), folder FQDN=$($script:NamingFolderIncludeFqdn)" -Tag "Info"
    $placementVolumes = @(Get-StoragePlacementVolumes -Defaults $defaults)
    if ($placementVolumes.Count -gt 0) {
        Write-Log "Storage placement: automatic across $($placementVolumes.Count) volume(s)" -Tag "Info"
        foreach ($volume in $placementVolumes) {
            $freeBytes = Get-PathVolumeFreeBytes -Path $volume.VhdPath
            $freeText = if ($null -eq $freeBytes) { "free space unreadable" } else { "$([math]::Round($freeBytes / 1GB)) GB free" }
            Write-Log "Volume $($volume.Index + 1): '$($volume.VmPath)' ($freeText)" -Tag "Info"
        }
    }
    if ($defaults.cluster -and [bool]$defaults.cluster.enabled) {
        $cn = [string]$defaults.cluster.name
        if ([string]::IsNullOrWhiteSpace($cn)) { $cn = "(local)" }
        $clusterOptIn = @($allServers | Where-Object { $null -ne $_.cluster })
        $clusterScope = if ([bool]$defaults.cluster.addAllVms) {
            "all {0} VM(s)" -f $allServers.Count
        }
        elseif ($clusterOptIn.Count -gt 0) {
            "{0} of {1} VM(s) selected" -f @($clusterOptIn | Where-Object { [bool]$_.cluster.enabled }).Count, $allServers.Count
        }
        else {
            "no per-VM selection in config - all VMs"
        }
        Write-Log "Failover cluster enabled: $cn | $clusterScope" -Tag "Info"
    }

    $goldImages = Get-HyperVGoldImages -VhdxDirectory $vhdxDirectory
    Write-Log "$($goldImages.Count) gold image(s) in '$vhdxDirectory'" -Tag "Get"
    if ($goldImages.Count -gt 0) {
        Write-Log ($goldImages.Name -join " | ") -Tag "Debug"
    }

    $action = $null
    $selectedServers = @()
    $interactive = $false

    $hasVmFilter = $VmName -and @($VmName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if ($CheckOnly.IsPresent) {
        $action = "Check"
        $selectedServers = @(Select-ServersFromConfig -Servers $allServers -VmNameFilter $VmName)
    }
    elseif ($hasVmFilter) {
        $action = "Build"
        $selectedServers = @(Select-ServersFromConfig -Servers $allServers -VmNameFilter $VmName)
    }
    elseif ($BuildAll.IsPresent) {
        $action = "Build"
        $selectedServers = @($allServers)
    }
    else {
        $interactive = $true
    }

    $statusLines = Get-BuildMenuStatusLines -Servers $allServers -GoldImages $goldImages -Defaults $defaults -Sources $sources

    while ($true) {
        if ($interactive) {
            $action = $null
            $selectedServers = @()

            $configWord = if ($sources.Count -gt 1) { "{0} configs" -f $sources.Count } else { "the config" }
            $menuItems = @(
                [pscustomobject]@{ Id = "all";      Label = ("Build all VMs       provision every server in {0} ({1})" -f $configWord, $allServers.Count) }
                [pscustomobject]@{ Id = "selected"; Label = "Build selected      pick one or more VMs" }
                [pscustomobject]@{ Id = "quit";     Label = "Quit" }
            )

            $menuTitle = if ($sources.Count -gt 1) { "Build VMs" } else { "Build VMs from $($sources[0].Name)" }
            $choice = Show-Menu -Title $menuTitle -Items $menuItems -StatusLines $statusLines
            if ($null -eq $choice -or $choice -eq "quit") {
                Write-Log "Cancelled by user" -Tag "Info"
                Complete-Script -ExitCode 0
            }

            switch ($choice) {
                "all" {
                    $action = "Build"
                    $selectedServers = @($allServers)
                }
                "selected" {
                    $picked = Read-SelectedServersInteractive -Servers $allServers -StatusLines $statusLines
                    if ($null -eq $picked) { continue }
                    $selectedServers = @($picked)
                    $action = "Build"
                }
            }

            # No confirm step here on purpose - the detailed "Confirm build settings"
            # summary below is the single place a build is approved.
        }

        # Slow host (prep ALL disks first) is CLI-only - see -SlowHost in the parameter block.
        $useSlowHost = $SlowHost.IsPresent

        Write-Log "$action | $($selectedServers.Count) server(s) | slow host=$useSlowHost" -Tag "Info"

        # One group per config the selection touches. Everything below that depends on
        # a config - paths, gold folder, VHD Sets, naming - is resolved per group.
        $buildGroups = @(Group-ServersByConfigSource -Servers $selectedServers -Sources $sources)
        if ($buildGroups.Count -gt 1) {
            Write-Log ("Selection spans {0} configs" -f $buildGroups.Count) -Tag "Info"
            foreach ($group in $buildGroups) {
                Write-Log ("  {0} - {1} VM(s)" -f $group.Source.Name, @($group.Servers).Count) -Tag "Info"
            }
        }

        # A VHD Set belongs to one config and names members from that same config, so
        # the sets in scope are gathered per group rather than from a single root.
        $vhdSetsInScope = @()
        $declaredSets = 0
        foreach ($group in $buildGroups) {
            $groupConfig = if ($null -ne $group.Source) { $group.Source.Config } else { $config }
            $declared = @($groupConfig.vhdSets)
            $declaredSets += $declared.Count
            $vhdSetsInScope += @(Select-VhdSetsForServers -VhdSets $declared -Servers $group.Servers)
        }
        if ($declaredSets -gt 0 -and $vhdSetsInScope.Count -eq 0) {
            Write-Log "Skipping $declaredSets VHD Set(s) - no selected members" -Tag "Info"
        }
        elseif ($declaredSets -gt $vhdSetsInScope.Count) {
            Write-Log "VHD Sets in scope: $($vhdSetsInScope.Count) of $declaredSets" -Tag "Info"
        }

        # Decide where the Server Core App Compatibility FOD comes from before anything is
        # checked or built. Interactive runs get asked once per Windows Server release when
        # no offline source is configured; unattended runs stay silent and defer to the guest.
        Resolve-FodPlans -Servers $selectedServers -Interactive:$interactive

        # Same idea for the gold language: preflight resolves golds too, so an image that
        # exists in more than one language has to be settled before it runs rather than
        # during the build it would otherwise abort.
        Resolve-GoldLanguagePlan -Servers $selectedServers -GoldImages $goldImages -Interactive:$interactive

        if ($action -eq "Check") {
            $passed = Invoke-BuildPreflightForGroups -Groups $buildGroups -VhdSets $vhdSetsInScope `
                -FallbackDefaults $defaults -FallbackVhdxDirectory $vhdxDirectory `
                -FallbackVmPath $vmPath -FallbackVhdPath $vhdPath
            if ($interactive) {
                Write-Host ""
                Read-Host "Press Enter to return to the menu"
                continue
            }
            if ($passed) {
                Complete-Script -ExitCode 0
            }
            Complete-Script -ExitCode 1
        }

        # Build path: preflight first, then provision
        $passed = Invoke-BuildPreflightForGroups -Groups $buildGroups -VhdSets $vhdSetsInScope `
            -FallbackDefaults $defaults -FallbackVhdxDirectory $vhdxDirectory `
            -FallbackVmPath $vmPath -FallbackVhdPath $vhdPath
        if (-not $passed) {
            Write-Log "Build aborted - preflight failed" -Tag "Error"
            if ($interactive) {
                Write-Host ""
                Read-Host "Press Enter to return to the menu"
                continue
            }
            Complete-Script -ExitCode 1
        }

        $doStart = -not $SkipStart.IsPresent

        if ($interactive) {
            $vmSummaries = @($selectedServers | ForEach-Object {
                    [pscustomobject]@{
                        Name = (Get-HyperVVmName -Server $_)
                        Rows = @(Get-ServerSummaryRows -Server $_ -Defaults $defaults -GoldImages $goldImages `
                                -VhdSets $vhdSetsInScope)
                        Line = (Get-ServerSummaryCompactLine -Server $_)
                    }
                })

            # This screen is the last stop before anything is written, so mirror every row
            # into the log - a condensed on-screen view then still has a full record.
            foreach ($summary in $vmSummaries) {
                foreach ($row in $summary.Rows) {
                    Write-Log ("Summary $($summary.Name) | $($row.Name): $($row.Value)") -Tag "Info"
                }
            }

            $vhdSetRows = @($vhdSetsInScope | ForEach-Object {
                    $set = $_
                    $attachTo = @()
                    if ($set.attachTo) { $attachTo = @($set.attachTo | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) }
                    $setLabel = ([string]$set.name).Trim()
                    if ([string]::IsNullOrWhiteSpace($setLabel)) { $setLabel = "VHD Set" }
                    $sizeGb = if ($null -ne $set.sizeGB) { [int]$set.sizeGB } else { 0 }
                    $setType = if ([string]::IsNullOrWhiteSpace([string]$set.type)) { "Fixed" } else { [string]$set.type }
                    [pscustomobject]@{
                        Name  = $setLabel
                        Value = ("{0} GB {1} - shared with {2}" -f $sizeGb, $setType, ($attachTo -join ", "))
                    }
                })

            $fodRows = @($script:FodPlanMap.Keys | Sort-Object | ForEach-Object {
                    $key = $_
                    $plan = $script:FodPlanMap[$key]
                    $fodLabel = if ($key -eq "rsat") { "RSAT (Windows 11)" }
                        elseif ($key -eq "appcompat:*") { "App Compat (gold image)" }
                        else { "App Compat (Windows Server $($key.Substring('appcompat:'.Length)))" }
                    $fodValue = switch ([string]$plan.Mode) {
                        "Offline" { "Offline - $(Split-Path -Leaf ([string]$plan.Iso))" }
                        "Skip" { "Skipped" }
                        default { "Online in guest at first boot" }
                    }
                    [pscustomobject]@{ Name = $fodLabel; Value = $fodValue }
                })

            $placementRows = @()
            foreach ($volume in @(Get-StoragePlacementVolumes -Defaults $defaults)) {
                $freeBytes = Get-PathVolumeFreeBytes -Path $volume.VhdPath
                $freeText = if ($null -eq $freeBytes) { "free space unreadable" } else { "{0} GB free" -f [math]::Round($freeBytes / 1GB) }
                $sameRoot = $volume.VmPath -eq $volume.VhdPath
                $pathText = if ($sameRoot) { $volume.VmPath } else { "{0}  +  {1}" -f $volume.VmPath, $volume.VhdPath }
                $placementRows += [pscustomobject]@{
                    Name  = "volume {0}" -f ($volume.Index + 1)
                    Value = "{0}  ({1})" -f $pathText, $freeText
                }
            }

            # The body sits under the same header and separator every other page has, so
            # keep an eye on the height and drop to one line per VM when it will not fit.
            $windowHeight = 40
            try {
                $windowHeight = [int]$Host.UI.RawUI.WindowSize.Height
            }
            catch {
                $windowHeight = 40
            }
            if ($windowHeight -lt 24) { $windowHeight = 24 }

            $buildLines = 7
            if ($useSlowHost) { $buildLines++ }
            if ($placementRows.Count -gt 0) { $buildLines++ }
            # header (logo height + frame) + build block + VM heading + menu/footer.
            $fixedHeight = 18 + $buildLines + 2 + 8
            if ($placementRows.Count -gt 0) { $fixedHeight += $placementRows.Count + 3 }
            if ($vhdSetRows.Count -gt 0) { $fixedHeight += $vhdSetRows.Count + 3 }
            if ($fodRows.Count -gt 0) { $fixedHeight += $fodRows.Count + 3 }
            $detailHeight = 0
            foreach ($summary in $vmSummaries) { $detailHeight += $summary.Rows.Count + 2 }
            # A single VM always gets its full block - the worst case is scrolling past the
            # header to see it, and that one VM is the whole point of the screen.
            $showVmDetail = ((($fixedHeight + $detailHeight) -le $windowHeight) -or ($vmSummaries.Count -eq 1))

            $renderBuildSummary = {
                # Every section reads the same: heading, blank line, then its rows.
                Write-Studio -Text "  Build" -Key "fg"
                Write-Host ""
                Write-FastfetchInfoRow -Label "gold folder" -Value $vhdxDirectory -LabelWidth 20 -IndentWidth 4
                $pathLabelSuffix = if ($placementRows.Count -gt 0) { " (fallback)" } else { "" }
                Write-FastfetchInfoRow -Label ("vm path" + $pathLabelSuffix) -Value $vmPath -LabelWidth 20 -IndentWidth 4
                Write-FastfetchInfoRow -Label ("vhd path" + $pathLabelSuffix) -Value $vhdPath -LabelWidth 20 -IndentWidth 4
                if ($placementRows.Count -gt 0) {
                    Write-FastfetchInfoRow -Label "placement" -Value ("automatic - {0} volume(s), most free space wins" -f $placementRows.Count) -LabelWidth 20 -IndentWidth 4
                }
                if ($useSlowHost) {
                    Write-FastfetchInfoRow -Label "slow host" -Value "Yes" -LabelWidth 20 -IndentWidth 4
                }
                Write-FastfetchInfoRow -Label "start after create" -Value $(if ($doStart) { "Yes" } else { "No" }) -LabelWidth 20 -IndentWidth 4
                Write-Host ""

                Write-Studio -Text "  Virtual machines ($($vmSummaries.Count))" -Key "fg"
                if ($showVmDetail) {
                    foreach ($summary in $vmSummaries) {
                        Write-Host ""
                        Write-Studio -Text ("    " + $summary.Name) -Key "fg"
                        foreach ($row in $summary.Rows) {
                            Write-FastfetchInfoRow -Label $row.Name -Value $row.Value -LabelWidth 13 -IndentWidth 6
                        }
                    }
                }
                else {
                    Write-Studio -Text "    condensed - the window is too short for the full blocks (it is all in the log)" -Key "muted"
                    foreach ($summary in $vmSummaries) {
                        Write-FastfetchInfoRow -Label $summary.Name -Value $summary.Line -LabelWidth 20 -IndentWidth 4
                    }
                }

                # Set names and FOD labels vary wildly in length - size the label column to
                # the section instead of letting a long one shove its colon out of line.
                if ($placementRows.Count -gt 0) {
                    Write-Host ""
                    Write-Studio -Text "  Storage placement ($($placementRows.Count))" -Key "fg"
                    Write-Host ""
                    $placementLabelWidth = Get-SectionLabelWidth -Rows $placementRows
                    foreach ($row in $placementRows) {
                        Write-FastfetchInfoRow -Label $row.Name -Value $row.Value -LabelWidth $placementLabelWidth -IndentWidth 4
                    }
                }
                if ($vhdSetRows.Count -gt 0) {
                    Write-Host ""
                    Write-Studio -Text "  VHD Sets ($($vhdSetRows.Count))" -Key "fg"
                    Write-Host ""
                    $vhdSetLabelWidth = Get-SectionLabelWidth -Rows $vhdSetRows
                    foreach ($row in $vhdSetRows) {
                        Write-FastfetchInfoRow -Label $row.Name -Value $row.Value -LabelWidth $vhdSetLabelWidth -IndentWidth 4
                    }
                }
                if ($fodRows.Count -gt 0) {
                    Write-Host ""
                    Write-Studio -Text "  Features on Demand" -Key "fg"
                    Write-Host ""
                    $fodLabelWidth = Get-SectionLabelWidth -Rows $fodRows
                    foreach ($row in $fodRows) {
                        Write-FastfetchInfoRow -Label $row.Name -Value $row.Value -LabelWidth $fodLabelWidth -IndentWidth 4
                    }
                }

                Write-Host ""
                Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
                Write-Host ""
            }

            $summaryStatus = [ordered]@{}
            foreach ($key in $statusLines.Keys) { $summaryStatus[$key] = $statusLines[$key] }
            $summaryStatus["selected"] = ("{0} of {1} in config" -f $selectedServers.Count, $allServers.Count)

            $summaryItems = @(
                [pscustomobject]@{ Id = "continue"; Label = ("Start build of {0} VM(s)" -f $selectedServers.Count) }
                [pscustomobject]@{ Id = "cancel";   Label = "Cancel - back to menu" }
            )
            $summaryDecision = Show-Menu -Title "Confirm build settings" -Subtitle "Review everything below, then continue" `
                -Items $summaryItems -SelectedIndex 0 -StatusLines $summaryStatus -PreItems $renderBuildSummary
            if ($summaryDecision -ne "continue") {
                Write-Log "Cancelled by user at build summary" -Tag "Info"
                continue
            }
        }

        $vhdSetMap = Initialize-VhdSets -VhdSets $vhdSetsInScope -VhdRoot $vhdPath

        # One group at a time, each with the naming rules, catalogue root, gold folder
        # and paths its own config asked for. A failure in one group does not stop the
        # others: the machines in a different config have nothing to do with it.
        $ok = $true
        $manyGroups = ($buildGroups.Count -gt 1)
        foreach ($group in $buildGroups) {
            $groupDefaults = $defaults
            $groupGolds = $goldImages

            if ($null -ne $group.Source) {
                Set-ActiveConfigSource -Source $group.Source
                $resolved = Resolve-ConfigSourcePaths -Source $group.Source `
                    -FallbackVmPath $vmPath -FallbackVhdPath $vhdPath
                $groupDefaults = $group.Source.Defaults
                $groupGolds = @(Get-HyperVGoldImages -VhdxDirectory $resolved.VhdxDirectory)
                if ($buildGroups.Count -gt 1) {
                    Write-Log ("Building {0} VM(s) from '{1}'" -f @($group.Servers).Count, $group.Source.Name) -Tag "Info"
                }
            }

            $groupOk = Invoke-BuildServers -Defaults $groupDefaults -Servers $group.Servers `
                -GoldImages $groupGolds -VhdSetMap $vhdSetMap -DoStart:$doStart -SlowHost:$useSlowHost `
                -PartOfLargerRun:$manyGroups
            if (-not $groupOk) { $ok = $false }
        }

        # Said once, about the run, after every config has had its turn.
        if ($manyGroups) {
            if ($ok) {
                Write-Log ("All selected servers provisioned - {0} configs" -f $buildGroups.Count) -Tag "Ok"
            }
            else {
                Write-Log "Some servers failed - see the errors above" -Tag "Error"
            }
        }

        if ($ok) {
            Complete-Script -ExitCode 0
        }
        Complete-Script -ExitCode 1
    }
}
catch {
    Write-Log $_.Exception.Message -Tag "Error"
    Complete-Script -ExitCode 1
}
