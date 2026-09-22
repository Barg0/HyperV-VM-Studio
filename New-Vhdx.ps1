<#
.SYNOPSIS
    Builds Azure Local or Hyper-V ready Windows VHDX images (Server and Client).

.DESCRIPTION
    Applies a Windows image from a mounted ISO to a Gen 2 (UEFI) VHDX, generalizes
    it with sysprep via a temporary Hyper-V VM, then bakes locale, keyboard, GeoID,
    and time zone into the offline image, plus Remote Desktop and ICMP (ping)
    firewall rules (each independently toggleable via -EnableRdp/-EnablePing,
    default on), and a machine-wide policy suppressing - on Server editions only -
    Server Manager auto-launch at logon (-SuppressServerManagerAtLogon, default
    off), or - on client editions only - the Getting Started / Windows Welcome
    Experience screen (-SuppressWelcomeExperience, default off) and the first
    sign-in animation (-SuppressFirstSignInAnimation, default off). Client images
    keep Windows from turning BitLocker on by itself after OOBE
    (-PreventDeviceEncryption, default ON): a qualifying VM encrypts itself once OOBE
    finishes and arms for real at domain join, which pre-empts the policy that is
    supposed to make that call. Client images also take a VM power plan
    (-SetVmPowerPlan, default ON): High performance, display and sleep set to never,
    hibernation off - a lab VM has no battery to save and no screen to blank, and the
    hiberfil.sys it never uses costs the same gigabytes on every differencing disk.
    Client and Server images can also take a Microsoft Edge machine policy baseline
    (-ConfigureEdge, default off): Google as the default and only search engine, no
    first-run experience, no mini menu, a new tab page stripped of Microsoft content,
    background images and default top sites, and diagnostic data held to required only.

    A Windows 11 Pro index can also be built as an Enterprise multi-session gold
    (-MultiSessionImageIndexes) - its own build next to any plain golds, so one run
    can produce both a Pro and a multi-session gold from the same index. The edition
    change is applied offline with DISM /Set-Edition AFTER the
    image has been generalized, not before. A base edition such as Pro has nothing
    staged and syspreps cleanly; the edition packs are staged on that base edition,
    so the change is offered there and not on an image already raised to a higher
    edition. The staged work then completes during specialize on the deployed VM's
    first boot, where a restart costs nothing. Applying the edition first is what
    left the image owing Windows a restart that sysprep refuses to work around.
    DISM lists the edition as ServerRdsh or EnterpriseMultiSession depending on
    where you read it; both names mean the same SKU. The image is asked whether it
    can become one straight after apply, so a build that cannot stops before the
    temporary VM costs twenty minutes, and the gold is named for what it ends up as
    (hv-enus-w11-enterprise-ms.vhdx) with the source index recorded in the sidecar.

    A Windows Server 2025 Datacenter index can be built as a Datacenter: Azure
    Edition gold the same way (-AzureEditionImageIndexes): its own build next to
    any plain golds, edition changed offline after generalize. DISM lists that
    target as ServerTurbine (Desktop) / ServerTurbineCor (Core) - the SKU's
    internal name - and only Server 2025 media carries it, so the rows are
    offered for 2025 Datacenter indexes and nowhere else. The gold leaves as
    hv-<language>-ws2025-datacenter-az-<core|desktop>.vhdx with the SKU's own
    AVMA key baked. Azure Edition is licensed for Azure and Azure Local, where
    Azure verification activates it and hotpatch is on by default; on plain
    Hyper-V the VM deactivates itself once it notices where it runs.

    The locale catalog (-Locale/-KeyboardLayout) comes from data\locales.json
    when present - the generated all-locales catalog written by
    toolbox\New-LocaleCatalog.ps1, whose top-level "default" names the preselected
    locale - and falls back to the hand-verified 14-locale in-script catalog when
    the file is missing or invalid. -UiLanguage is always Auto - there is
    no language-pack source to satisfy anything else. A Hyper-V gold carries no
    boot-time scripts at all; an Azure Local gold carries the first-boot locale
    payload described below, which deletes itself once it has run.

    AzureLocal target: plain sysprep /generalize /oobe /shutdown, RDP and policies
    via offline registry after generalize, and Azure Local owns Panther\unattend.xml
    during provisioning. Locale, keyboard and time zone are NOT baked on this target:
    Azure Local provisions each VM from its own answer file (delivered on two DVDs at
    create time), whose International-Core settings run in specialize / oobeSystem and
    overwrite anything DISM wrote offline, and az stack-hci-vm create has no locale or
    time zone parameter. They are applied instead at the deployed VM's first boot by
    Windows\Setup\Scripts\SetupComplete.cmd, which runs as LOCAL SYSTEM after every
    configuration pass. See Write-AzureLocalLocalePayload.

    HyperV target: sysprep /generalize /oobe /mode:vm /shutdown (same-hypervisor
    VM generalize for faster first boot). Same offline bake. No deploy unattend
    is baked into the gold image - Build-Vms.ps1 injects Panther\unattend.xml
    per VM at provision time.

    The temporary generalize VM is created under '<Hyper-V default VM path>\sysprep'
    (e.g. D:\vms\sysprep) rather than the host default root, so it never sits beside
    real VMs. Both the VM and that folder are removed again when the run finishes,
    including on failure. Only the gold VHDX in -OutputDirectory survives (plus its
    '<name>.vhdx.json' sidecar manifest on the HyperV target, recording the baked
    locale/keyboard/time zone for Build-Vms.ps1), and it is attached in place, never
    moved there.

.NOTES
    Target shell : Windows PowerShell 5.1 and PowerShell 7
    Requires     : Administrator, Hyper-V role, DISM module
#>

[CmdletBinding()]
param (
    [Parameter(HelpMessage = "Drive letter of an already mounted Windows ISO, for example 'E:'. Optional when using the interactive menu or -IsoPath.")]
    [string]$IsoDrive,

    [Parameter(HelpMessage = "Path to a Windows ISO file. The script mounts it automatically. Optional when using the interactive menu.")]
    [string]$IsoPath,

    [Parameter(HelpMessage = "Folder that receives the generated VHDX files. Optional when using the interactive menu.")]
    [string]$OutputDirectory,

    [Parameter(HelpMessage = "Deployment target: HyperV (default) or AzureLocal.")]
    [ValidateSet("AzureLocal", "HyperV")]
    [string]$Target = "HyperV",

    [Parameter(HelpMessage = "install.wim / install.esd image indexes to build. Preferred over -Build.")]
    [ValidateRange(1, 99)]
    [int[]]$ImageIndexes,

    [Parameter(HelpMessage = "Legacy Server selection: Both, Core, or Gui. Used when -ImageIndexes is empty.")]
    [ValidateSet("Both", "Core", "Gui")]
    [string]$Build = "Both",

    [Parameter(HelpMessage = "Legacy install.wim index for Datacenter Core.")]
    [ValidateRange(1, 99)]
    [int]$CoreImageIndex,

    [Parameter(HelpMessage = "Legacy install.wim index for Datacenter Desktop Experience.")]
    [ValidateRange(1, 99)]
    [int]$GuiImageIndex,

    [Parameter(HelpMessage = "UI language. Always Auto (keeps the language of the source image) - there is no language-pack source to satisfy anything else.")]
    [ValidateSet("Auto")]
    [string]$UiLanguage = "Auto",

    [Parameter(HelpMessage = "Regional format (UserLocale / SystemLocale). Validated at runtime against the loaded locale catalog - locales.json next to this script when present, the in-script catalog otherwise. Empty takes the catalog's default.")]
    [string]$Locale = "",

    [Parameter(HelpMessage = "Keyboard input layout, as a locale tag from the same catalog as -Locale. Empty takes the catalog's default.")]
    [string]$KeyboardLayout = "",

    [Parameter(HelpMessage = "Time zone (DISM / tzutil ID) baked into the image.")]
    [ValidateNotNullOrEmpty()]
    [string]$TimeZone = "W. Europe Standard Time",

    [Parameter(HelpMessage = "VHDX size in gigabytes.")]
    [ValidateRange(20, 2048)]
    [int]$VhdSizeGB = 64,

    [Parameter(HelpMessage = "VHDX type: Fixed (default) or Dynamic.")]
    [ValidateSet("Fixed", "Dynamic")]
    [string]$VhdType = "Fixed",

    [Parameter(HelpMessage = "Skip the sysprep generalize step. The resulting image is NOT release-ready.")]
    [switch]$SkipSysprep,

    [Parameter(HelpMessage = "Bake in Remote Desktop (enabled + firewall rules) offline. Default on.")]
    [bool]$EnableRdp = $true,

    [Parameter(HelpMessage = "Bake in inbound ICMP echo (ping) firewall rules offline. Default on.")]
    [bool]$EnablePing = $true,

    [Parameter(HelpMessage = "On Server editions, bake a machine-wide policy suppressing Server Manager auto-launch at logon. No effect on client images. Default off.")]
    [bool]$SuppressServerManagerAtLogon = $false,

    [Parameter(HelpMessage = "On client editions, bake a machine-wide policy suppressing the Getting Started / Windows Welcome Experience screen at logon. No effect on Server images. Default off.")]
    [bool]$SuppressWelcomeExperience = $false,

    [Parameter(HelpMessage = "On client editions, bake a machine-wide policy disabling the first sign-in animation ('Hi / We're getting things ready') so the first logon lands straight on the desktop. No effect on Server images. Default off.")]
    [bool]$SuppressFirstSignInAnimation = $false,

    [Parameter(HelpMessage = "Bake the BlockUserInputMethodsForSignIn policy (STIG WN12-CC-000048): pin the sign-in screen to the baked keyboard and stop per-user input methods (fr-FR etc.) from appearing there. Applies to client and server. Default off.")]
    [bool]$BlockSignInInputMethods = $false,

    [Parameter(HelpMessage = "On client editions, bake PreventDeviceEncryption so Windows does not turn BitLocker on by itself after OOBE. No effect on Server images. Default on: encryption is expected to be armed by policy after deployment, not by the image on its own.")]
    [bool]$PreventDeviceEncryption = $true,

    [Parameter(HelpMessage = "Bake the Microsoft Edge machine policy baseline (Google as default search engine, no first-run experience, no mini menu, a cleared new tab page, required-only diagnostic data). Applies to client and server. Default off.")]
    [bool]$ConfigureEdge = $false,

    [Parameter(HelpMessage = "On client editions, bake the High performance power scheme with display and sleep set to never and hibernation off. No effect on Server images. Default on: the gold runs as a VM, where blanking a console and sleeping a machine nobody is sitting at only gets in the way.")]
    [bool]$SetVmPowerPlan = $true,

    [Parameter(HelpMessage = "Image indexes to build as Windows 11 Enterprise multi-session golds - upgraded offline, after generalize. Each index here is its own build on top of whatever -ImageIndexes lists: the same index in both produces a Pro gold and a multi-session gold. Pass the index of a Windows 11 Pro image; the build aborts early if the image cannot become multi-session.")]
    [ValidateRange(1, 99)]
    [int[]]$MultiSessionImageIndexes,

    [Parameter(HelpMessage = "Image indexes to build as Windows Server 2025 Datacenter: Azure Edition golds - upgraded offline, after generalize, same mechanism as -MultiSessionImageIndexes. Pass the index of a Windows Server 2025 Datacenter image; only Server 2025 media lists the Azure Edition target (DISM calls it ServerTurbine / ServerTurbineCor), and the build aborts early if the image cannot become it.")]
    [ValidateRange(1, 99)]
    [int[]]$AzureEditionImageIndexes
)

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "New-Vhdx"
$logFileName = (Get-Date -Format "yyyyMMdd-HHmm") + ".log"

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
$enableLogFile = $true

$logFileDirectory = Join-Path -Path $PSScriptRoot -ChildPath "logs\new-vhdx"
$logFile          = Join-Path -Path $logFileDirectory -ChildPath $logFileName

# ---------------------------[ Virtual Edition Upgrades ]---------------------------
# The virtual editions a gold can be upgraded to after generalize. Keyed by the
# EditionUpgrade value a build spec carries ("" means a plain build). TargetPattern
# matches DISM /Get-TargetEditions output - every SKU here goes by more than one
# name depending on where you read it, so match the family and hand /Set-Edition
# the exact string DISM printed. ManifestValue is what the sidecar records;
# SourceHint explains which index to pick when a build aborts early.
$script:VirtualEditionCatalog = @{
    MultiSession = @{
        TargetPattern = "(ServerRdsh|EnterpriseMultiSession)"
        DisplayName   = "Windows 11 Enterprise multi-session"
        ManifestValue = "EnterpriseMultiSession"
        SourceHint    = "Use a Windows 11 Pro index: the edition packs are staged on the base edition, and an image already changed to a higher edition has none left to offer."
    }
    AzureEdition = @{
        # Greedy suffix on purpose: the Core SKU is ServerTurbineCor, and a pattern
        # that stops at ServerTurbine would hand /Set-Edition a Desktop SKU for a
        # Core image. Match the whole token DISM printed.
        TargetPattern = "(ServerTurbine[A-Za-z]*|ServerAzure[A-Za-z]*)"
        DisplayName   = "Windows Server 2025 Datacenter: Azure Edition"
        ManifestValue = "DatacenterAzureEdition"
        SourceHint    = "Use a Windows Server 2025 Datacenter index: only Server 2025 media lists the Azure Edition target, and Standard Core does not list it directly."
    }
}

# What DISM said this image can become, asked once during the apply phase and read
# again after generalize. It is per-image state: the build loop does one image at a
# time, and the apply phase overwrites this before anything downstream reads it.
$script:EditionUpgradeTarget = ""

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
# The logo is deliberately NOT part of this: Get-ServerLogoLines keeps its own
# base64 ANSI art and the colours baked into it.

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

# ---------------------------[ Logging Function ]---------------------------
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
        $furniture = $clock.Length + 1 + 2 + $rawTag.Length + 3
        $available = (Get-ConsoleWidth) - 1 - $furniture
        if ($available -lt 12) { $available = 12 }
        if ($shownMessage.Length -gt $available) {
            $shownMessage = $shownMessage.Substring(0, $available - 3) + "..."
        }
    }

    # The clock and the brackets are furniture, not content: they take `muted` so the
    # tag and the message are what the eye lands on.
    Write-Studio -Text "$clock " -Key "muted" -NoNewline
    Write-Studio -Text "[ " -Key "muted" -NoNewline
    Write-Studio -Text "$rawTag" -Key $color -NoNewline
    Write-Studio -Text " ] " -Key "muted" -NoNewline
    Write-Studio -Text $shownMessage -Key "fg"
}

# ---------------------------[ Exit Function ]---------------------------
# Path of an ISO this script mounted (dismounted on exit).
$script:mountedIsoPath = $null

function Complete-Script {
    param([int]$ExitCode)

    if (-not [string]::IsNullOrWhiteSpace($script:mountedIsoPath)) {
        try {
            Write-Log "Dismounting ISO '$($script:mountedIsoPath)'" -Tag "Run"
            Dismount-DiskImage -ImagePath $script:mountedIsoPath -ErrorAction Stop | Out-Null
            $script:mountedIsoPath = $null
        }
        catch {
            Write-Log "ISO dismount failed: $($_.Exception.Message)" -Tag "Debug"
        }
    }

    $scriptEndTime = Get-Date
    $duration      = $scriptEndTime - $scriptStartTime

    Write-Log "Runtime $($duration.ToString('hh\:mm\:ss\.ff'))" -Tag "Info"
    Write-Log "Exit $ExitCode" -Tag "Info"
    Write-Log "==================== End ====================" -Tag "End"

    exit $ExitCode
}

# ---------------------------[ Locale Helpers ]---------------------------
function Get-AvmaKey {
    # AVMA client keys published by Microsoft, per guest version and edition:
    # https://learn.microsoft.com/en-us/windows-server/get-started/automatic-vm-activation
    # Generic keys - they activate against a licensed Datacenter host (a 2025 host
    # activates every version here) or an Azure Local instance with a Windows Server
    # subscription, and baking one also keeps OOBE from stopping at the product key
    # screen. The key must match the guest's own version: /Set-ProductKey refuses
    # one from the wrong version's pkeyconfig, so an unknown pairing returns ""
    # and the gold leaves keyless rather than failing the build.
    param(
        [string]$Year,
        [string]$Edition
    )

    $keys = @{
        "2025-Datacenter"   = "YQB4H-NKHHJ-Q6K4R-4VMY6-VCH67"
        "2025-AzureEdition" = "6NMQ9-T38WF-6MFGM-QYGYM-88J4F"
        "2025-Standard"     = "WWVGQ-PNHV9-B89P4-8GGM9-9HPQ4"
        "2022-Datacenter"   = "W3GNR-8DDXR-2TFRP-H8P33-DV9BG"
        "2022-Standard"     = "YDFWN-MJ9JR-3DYRK-FXXRW-78VHK"
        "2019-Datacenter"   = "H3RNG-8C32Q-Q8FRX-6TDXV-WMBMW"
        "2019-Standard"     = "TNK62-RXVTB-4P47B-2D623-4GF74"
        "2016-Datacenter"   = "TMJ3Y-NTRTM-FJYXT-T22BY-CWG3J"
        "2016-Standard"     = "C3RCX-M6NRP-6CXC9-TW2F2-4RHYD"
    }
    $key = $keys["$Year-$Edition"]
    if ($null -eq $key) { return "" }
    return $key
}

# Full locale catalog: de-DE (default) / en-US, then the rest alphabetically.
# InputLocale/LangId/GeoID verified against Microsoft's own published tables:
# https://learn.microsoft.com/en-us/windows/win32/intl/table-of-geographical-locations
# https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-8.1-and-8/hh825684(v=win.10)
$script:LocaleCatalog = [ordered]@{
    "de-DE" = @{
        LangId = "0407"; Keyboard = "00000407"; Lcid = "00000407"
        GeoNation = "94"; GeoName = "DE"; Currency = ([string][char]0x20AC)
        sCountry = "Germany"; sLanguage = "DEU"; iCountry = "49"
        sShortDate = "dd.MM.yyyy"; sLongDate = "dddd, d. MMMM yyyy"
        sShortTime = "HH:mm"; sTimeFormat = "HH:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = "."; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = "."
    }
    "en-US" = @{
        LangId = "0409"; Keyboard = "00000409"; Lcid = "00000409"
        GeoNation = "244"; GeoName = "US"; Currency = "$"
        sCountry = "United States"; sLanguage = "ENU"; iCountry = "1"
        sShortDate = "M/d/yyyy"; sLongDate = "dddd, MMMM d, yyyy"
        sShortTime = "h:mm tt"; sTimeFormat = "h:mm:ss tt"
        iMeasure = "1"; iFirstDayOfWeek = "6"; iFirstWeekOfYear = "0"
        iNegCurr = "0"; iTime = "0"; iDate = "0"; s1159 = "AM"; s2359 = "PM"
        sDecimal = "."; sThousand = ","; sList = ","
        sMonDecimalSep = "."; sMonThousandSep = ","
    }
    "cs-CZ" = @{
        LangId = "0405"; Keyboard = "00000405"; Lcid = "00000405"
        GeoNation = "75"; GeoName = "CZ"; Currency = ("K" + [string][char]0x010D)
        sCountry = "Czech Republic"; sLanguage = "CSY"; iCountry = "420"
        sShortDate = "d.M.yyyy"; sLongDate = "dddd, d. MMMM yyyy"
        sShortTime = "H:mm"; sTimeFormat = "H:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = " "; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = " "
    }
    "da-DK" = @{
        LangId = "0406"; Keyboard = "00000406"; Lcid = "00000406"
        GeoNation = "61"; GeoName = "DK"; Currency = "kr"
        sCountry = "Denmark"; sLanguage = "DAN"; iCountry = "45"
        sShortDate = "dd-MM-yyyy"; sLongDate = "dddd, d. MMMM yyyy"
        sShortTime = "HH:mm"; sTimeFormat = "HH:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = "."; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = "."
    }
    "en-GB" = @{
        LangId = "0809"; Keyboard = "00000809"; Lcid = "00000809"
        GeoNation = "242"; GeoName = "GB"; Currency = ([string][char]0x00A3)
        sCountry = "United Kingdom"; sLanguage = "ENG"; iCountry = "44"
        sShortDate = "dd/MM/yyyy"; sLongDate = "dddd, d MMMM yyyy"
        sShortTime = "HH:mm"; sTimeFormat = "HH:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "1"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = "."; sThousand = ","; sList = ","
        sMonDecimalSep = "."; sMonThousandSep = ","
    }
    "es-ES" = @{
        LangId = "0c0a"; Keyboard = "0000040a"; Lcid = "00000c0a"
        GeoNation = "217"; GeoName = "ES"; Currency = ([string][char]0x20AC)
        sCountry = "Spain"; sLanguage = "ESN"; iCountry = "34"
        sShortDate = "d/M/yyyy"; sLongDate = "dddd, d' de 'MMMM' de 'yyyy"
        sShortTime = "H:mm"; sTimeFormat = "H:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = "."; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = "."
    }
    "fi-FI" = @{
        LangId = "040b"; Keyboard = "0000040b"; Lcid = "0000040b"
        GeoNation = "77"; GeoName = "FI"; Currency = ([string][char]0x20AC)
        sCountry = "Finland"; sLanguage = "FIN"; iCountry = "358"
        sShortDate = "d.M.yyyy"; sLongDate = "dddd d. MMMM yyyy"
        sShortTime = "H:mm"; sTimeFormat = "H:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = " "; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = " "
    }
    "fr-FR" = @{
        LangId = "040c"; Keyboard = "0000040c"; Lcid = "0000040c"
        GeoNation = "84"; GeoName = "FR"; Currency = ([string][char]0x20AC)
        sCountry = "France"; sLanguage = "FRA"; iCountry = "33"
        sShortDate = "dd/MM/yyyy"; sLongDate = "dddd d MMMM yyyy"
        sShortTime = "HH:mm"; sTimeFormat = "HH:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = " "; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = " "
    }
    "it-IT" = @{
        LangId = "0410"; Keyboard = "00000410"; Lcid = "00000410"
        GeoNation = "118"; GeoName = "IT"; Currency = ([string][char]0x20AC)
        sCountry = "Italy"; sLanguage = "ITA"; iCountry = "39"
        sShortDate = "dd/MM/yyyy"; sLongDate = "dddd d MMMM yyyy"
        sShortTime = "HH:mm"; sTimeFormat = "HH:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = "."; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = "."
    }
    "nb-NO" = @{
        LangId = "0414"; Keyboard = "00000414"; Lcid = "00000414"
        GeoNation = "177"; GeoName = "NO"; Currency = "kr"
        sCountry = "Norway"; sLanguage = "NOR"; iCountry = "47"
        sShortDate = "dd.MM.yyyy"; sLongDate = "dddd d. MMMM yyyy"
        sShortTime = "HH:mm"; sTimeFormat = "HH:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = " "; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = " "
    }
    "nl-NL" = @{
        LangId = "0413"; Keyboard = "00000413"; Lcid = "00000413"
        GeoNation = "176"; GeoName = "NL"; Currency = ([string][char]0x20AC)
        sCountry = "Netherlands"; sLanguage = "NLD"; iCountry = "31"
        sShortDate = "d-M-yyyy"; sLongDate = "dddd d MMMM yyyy"
        sShortTime = "HH:mm"; sTimeFormat = "HH:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = "."; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = "."
    }
    "pl-PL" = @{
        LangId = "0415"; Keyboard = "00000415"; Lcid = "00000415"
        GeoNation = "191"; GeoName = "PL"; Currency = ("z" + [string][char]0x0142)
        sCountry = "Poland"; sLanguage = "PLK"; iCountry = "48"
        sShortDate = "dd.MM.yyyy"; sLongDate = "dddd, d MMMM yyyy"
        sShortTime = "HH:mm"; sTimeFormat = "HH:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = " "; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = " "
    }
    "pt-PT" = @{
        LangId = "0816"; Keyboard = "00000816"; Lcid = "00000816"
        GeoNation = "193"; GeoName = "PT"; Currency = ([string][char]0x20AC)
        sCountry = "Portugal"; sLanguage = "PTG"; iCountry = "351"
        sShortDate = "dd/MM/yyyy"; sLongDate = "dddd, d de MMMM de yyyy"
        sShortTime = "HH:mm"; sTimeFormat = "HH:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = " "; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = " "
    }
    "sv-SE" = @{
        LangId = "041d"; Keyboard = "0000041d"; Lcid = "0000041d"
        GeoNation = "221"; GeoName = "SE"; Currency = "kr"
        sCountry = "Sweden"; sLanguage = "SVE"; iCountry = "46"
        sShortDate = "yyyy-MM-dd"; sLongDate = "dddd d MMMM yyyy"
        sShortTime = "HH:mm"; sTimeFormat = "HH:mm:ss"
        iMeasure = "0"; iFirstDayOfWeek = "0"; iFirstWeekOfYear = "2"
        iNegCurr = "8"; iTime = "1"; iDate = "1"; s1159 = ""; s2359 = ""
        sDecimal = ","; sThousand = " "; sList = ";"
        sMonDecimalSep = ","; sMonThousandSep = " "
    }
}

# What the picker preselects and unknown locales fall back to. locales.json can
# override it; the in-script catalog's own default is de-DE either way.
$script:DefaultLocale = "de-DE"

function Import-LocaleCatalogFile {
    # data\locales.json: the generated all-locales catalog
    # (toolbox\New-LocaleCatalog.ps1), with the default locale named at its top.
    # Absent, unreadable or structurally wrong, the hand-verified in-script
    # catalog above stays in charge - it is the fallback, not a peer, and a bad
    # file must never take the build down with it.
    $path = Join-Path -Path $PSScriptRoot -ChildPath "data\locales.json"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log "No locales.json - using the built-in catalog" -Tag "Info"
        return
    }

    $data = $null
    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log "locales.json is not valid JSON ($($_.Exception.Message)) - using the in-script locale catalog" -Tag "Warn"
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$data.default) -or $null -eq $data.locales) {
        Write-Log "locales.json is missing 'default' or 'locales' - using the in-script locale catalog" -Tag "Warn"
        return
    }

    # Every field the offline registry bake and the picker read. An entry missing
    # one is dropped alone; the file only loses to the fallback when nothing valid
    # is left or its own default is among the casualties.
    $requiredFields = @(
        "LangId", "Keyboard", "Lcid", "GeoNation", "GeoName", "Currency",
        "sCountry", "sLanguage", "sShortDate", "sLongDate", "sShortTime",
        "sTimeFormat", "iMeasure", "iFirstDayOfWeek", "iFirstWeekOfYear",
        "iNegCurr", "iTime", "iDate", "sDecimal", "sThousand", "sList",
        "sMonDecimalSep", "sMonThousandSep"
    )

    $catalog = [ordered]@{}
    $dropped = 0
    foreach ($property in ($data.locales.PSObject.Properties | Sort-Object Name)) {
        $entry = $property.Value
        $missing = @($requiredFields | Where-Object { $null -eq $entry.PSObject.Properties[$_] })
        if ($missing.Count -gt 0) {
            $dropped++
            Write-Log "Dropped locale '$($property.Name)': no $($missing -join ', ')" -Tag "Debug"
            continue
        }
        $values = @{}
        foreach ($field in $entry.PSObject.Properties) {
            $values[$field.Name] = [string]$field.Value
        }
        $catalog[$property.Name] = $values
    }

    if ($catalog.Count -eq 0) {
        Write-Log "locales.json carries no usable entries - using the in-script locale catalog" -Tag "Warn"
        return
    }
    if (-not $catalog.Contains([string]$data.default)) {
        Write-Log "locales.json default '$($data.default)' is not among its own entries - using the in-script locale catalog" -Tag "Warn"
        return
    }

    $script:LocaleCatalog = $catalog
    $script:DefaultLocale = [string]$data.default
    $droppedText = if ($dropped -gt 0) { ", $dropped dropped" } else { "" }
    Write-Log "locales.json: $($catalog.Count) locales$droppedText, default $($script:DefaultLocale)" -Tag "Info"
}

function Get-LocaleCatalogEntry {
    param([string]$Locale)

    if ($script:LocaleCatalog.Contains($Locale)) {
        return $script:LocaleCatalog[$Locale]
    }
    Write-Log "Unknown locale '$Locale' - using $($script:DefaultLocale)" -Tag "Info"
    return $script:LocaleCatalog[$script:DefaultLocale]
}

function Get-LocaleDisplayName {
    # "German (Germany)" when the catalog carries the language name (generated
    # locales.json does), the bare country otherwise (the in-script fallback
    # predates the field). The tag alone never says the language - de-DE next to
    # dsb-DE both read "Germany" without this.
    param([string]$Locale)

    $entry = Get-LocaleCatalogEntry -Locale $Locale
    if (-not [string]::IsNullOrWhiteSpace([string]$entry.languageName)) {
        return [string]$entry.languageName
    }
    return [string]$entry.sCountry
}

function Get-InputLocaleId {
    param([string]$KeyboardLayout)

    $entry = Get-LocaleCatalogEntry -Locale $KeyboardLayout
    return "$($entry.LangId):$($entry.Keyboard)"
}

function Get-CurrencySymbol {
    param([string]$Locale)

    return (Get-LocaleCatalogEntry -Locale $Locale).Currency
}

function Resolve-UiLanguage {
    param(
        [string]$UiLanguage,
        [string]$ImageLanguage
    )

    if ($UiLanguage -eq "Auto") {
        if ([string]::IsNullOrWhiteSpace($ImageLanguage)) {
            return "en-US"
        }
        return $ImageLanguage
    }

    return $UiLanguage
}

function Test-IsServerDatacenterImage {
    param([string]$ImageName)

    if ([string]::IsNullOrWhiteSpace($ImageName)) {
        return $false
    }

    $name = $ImageName.ToLowerInvariant()
    return (($name -match "server") -and ($name -match "datacenter"))
}

function Test-IsServerCoreImage {
    # Server Core, i.e. a Server image that is not Desktop Experience. WIM names never say
    # "Core" - the GUI ones say "Desktop Experience" and Core is what is left, which is the
    # same test Get-VhdxFileName slugs with.
    param([string]$ImageName)

    if ([string]::IsNullOrWhiteSpace($ImageName)) {
        return $false
    }

    $name = $ImageName.ToLowerInvariant()
    if ($name -notmatch "server") {
        return $false
    }
    return ($name -notmatch "desktop")
}

function Test-IsClientImage {
    param([string]$ImageName)

    if ([string]::IsNullOrWhiteSpace($ImageName)) {
        return $false
    }

    $name = $ImageName.ToLowerInvariant()
    if ($name -match "server") {
        return $false
    }
    return (($name -match "windows 1") -or ($name -match "windows 11") -or ($name -match "enterprise") -or ($name -match "professional") -or ($name -match "pro") -or ($name -match "home"))
}

function Get-ImageNameSlug {
    # Turns a WIM image name into the imageId that identifies it everywhere else:
    # the studio's image catalog, config.json, and Build-Vms.ps1's match rules all
    # use these exact strings. The gold filename carries the same token, so resolving
    # a gold is a string comparison rather than a guess about what its name contains.
    # Examples: w11-enterprise, ws2025-datacenter-core, ws2025-standard-desktop
    param(
        [string]$ImageName,
        [int]$ImageIndex
    )

    if ([string]::IsNullOrWhiteSpace($ImageName)) {
        return ("image-{0}" -f $ImageIndex)
    }

    $name = $ImageName.ToLowerInvariant()

    # The Azure Local media still names its image "Azure Stack HCI". Build it under the
    # product's current name so the gold does not carry a retired one, abbreviated the
    # way every other id is - "azl" is to Azure Local what "ws" is to Windows Server.
    if ($name -match "azure\s+stack\s+hci" -or $name -match "azure\s+local") {
        return "azl"
    }

    if ($name -match "windows\s+server\s+(\d{4})") {
        $slug = "ws$($Matches[1])"

        if ($name -match "datacenter") {
            $slug = "$slug-datacenter"
        }
        elseif ($name -match "standard") {
            $slug = "$slug-standard"
        }

        # WIM names omit "Core"; Desktop Experience is the GUI marker.
        if ($name -match "desktop") {
            $slug = "$slug-desktop"
        }
        else {
            $slug = "$slug-core"
        }

        return $slug
    }

    if ($name -match "windows\s+(1[01])") {
        $version = $Matches[1]
        $edition = "unknown"

        # "Windows 11 Enterprise multi-session" is a separate SKU that also says
        # "Enterprise", so it has to be recognised before the plain edition tests -
        # otherwise both images slug the same and the second bake overwrites the first.
        if ($name -match "multi[\s-]*session") {
            return "w$version-enterprise-ms"
        }

        if ($name -match "enterprise\s*n\b") {
            $edition = "enterprise-n"
        }
        elseif ($name -match "\benterprise\b") {
            $edition = "enterprise"
        }
        elseif ($name -match "education\s*n\b") {
            $edition = "education-n"
        }
        elseif ($name -match "\beducation\b") {
            $edition = "education"
        }
        elseif ($name -match "professional\s*n\b" -or $name -match "\bpro\s*n\b") {
            $edition = "pro-n"
        }
        elseif ($name -match "\bprofessional\b" -or $name -match "\bpro\b") {
            $edition = "pro"
        }
        elseif ($name -match "\bhome\s*n\b") {
            $edition = "home-n"
        }
        elseif ($name -match "\bhome\b") {
            $edition = "home"
        }

        return "w$version-$edition"
    }

    $safeName = $name
    $safeName = $safeName -replace "[^a-z0-9]+", "-"
    $safeName = $safeName.Trim("-")
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = "image-$ImageIndex"
    }
    if ($safeName.Length -gt 60) {
        $safeName = $safeName.Substring(0, 60).Trim("-")
    }
    return $safeName
}

function Get-LanguageSlug {
    # "en-US" -> "enus". Flattened on purpose: every other separator in the filename is a
    # hyphen, so a language that kept its own would be indistinguishable from the tokens
    # around it. Unknown stays "unk" rather than collapsing the field - a name with a
    # missing segment is one Build-Vms.ps1 cannot parse.
    param([string]$ImageLanguage)

    $tag = ([string]$ImageLanguage) -replace "[^A-Za-z0-9]", ""
    if ([string]::IsNullOrWhiteSpace($tag)) {
        return "unk"
    }
    return $tag.ToLowerInvariant()
}

function Get-VhdxFileName {
    # <hv|azl>-<language>-<imageId>.vhdx
    # hv-enus-ws2025-datacenter-core.vhdx / azl-dede-w11-enterprise-ms.vhdx
    #
    # The language sits second so the tail stays free for the imageId, which ends in the
    # tokens that distinguish editions (-core, -desktop, -ms, -n). Two bakes of the same
    # image in different languages get different names instead of overwriting each other;
    # Build-Vms.ps1 asks which one to use when both are on disk.
    param(
        [string]$ImageName,
        [int]$ImageIndex,
        [string]$Target,
        [string]$ImageLanguage,
        [string]$EditionUpgrade = ""
    )

    $methodPrefix = "azl"
    if ($Target -eq "HyperV") {
        $methodPrefix = "hv"
    }

    $slug = Get-ImageNameSlug -ImageName $ImageName -ImageIndex $ImageIndex
    # The gold is named for what it is when a VM boots it, not for the index it was
    # applied from. A Pro image that leaves here as multi-session is w11-enterprise-ms
    # to everything downstream, a Standard image that leaves as Azure Edition is
    # ws2025-datacenter-az-*; the sidecar keeps the source index honest.
    if ($EditionUpgrade -eq "MultiSession") {
        $slug = $slug -replace "^(w\d+)-.*$", '$1-enterprise-ms'
    }
    elseif ($EditionUpgrade -eq "AzureEdition") {
        # Keeps the -core / -desktop tail: /Set-Edition changes the SKU, not the
        # install type, so a Desktop Experience source stays Desktop Experience.
        $slug = $slug -replace "^(ws\d+)-(standard|datacenter)", '$1-datacenter-az'
    }
    $language = Get-LanguageSlug -ImageLanguage $ImageLanguage
    return ("{0}-{1}-{2}.vhdx" -f $methodPrefix, $language, $slug).ToLowerInvariant()
}

function Write-GoldImageManifest {
    # Sidecar manifest next to the gold VHDX ("<name>.vhdx.json"). Records the region
    # settings the image carries so Build-Vms.ps1 can resolve locale/keyboard from the
    # gold itself when config.json says locale "default" instead of trusting the studio
    # picker to match the bake.
    #
    # HyperV target only. Build-Vms.ps1 enumerates hv-*.vhdx and reads the sidecar
    # beside the gold it picked, so an azl-*.vhdx never has a reader: it goes to Azure
    # Local, which provisions from its own answer file and never sees a file sitting
    # next to the disk. Its region settings travel inside the image instead, applied at
    # first boot by the SetupComplete payload. Writing one there would only imply a
    # consumer that does not exist.
    param(
        [string]$VhdPath,
        [string]$ImageName,
        [int]$ImageIndex,
        [string]$Target,
        [string]$Locale,
        [string]$KeyboardLayout,
        [string]$TimeZone,
        [string]$ImageLanguage,
        [string]$EditionUpgrade = ""
    )

    if ($Target -eq "AzureLocal") {
        Write-Log "Azure Local gold - no sidecar manifest" -Tag "Info"
        return $true
    }

    $manifestPath = "$VhdPath.json"
    $manifest = [ordered]@{
        imageName      = $ImageName
        imageIndex     = $ImageIndex
        target         = $Target
        locale         = $Locale
        keyboardLayout = $KeyboardLayout
        inputLocale    = (Get-InputLocaleId -KeyboardLayout $KeyboardLayout)
        timeZone       = $TimeZone
        localeMode     = "offline"
        imageLanguage  = $ImageLanguage
        createdUtc     = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    if (-not [string]::IsNullOrWhiteSpace($EditionUpgrade)) {
        # imageName and imageIndex above describe the index that was applied. The
        # gold's file name describes what it became. Both are true and neither implies
        # the other, so the sidecar says so out loud.
        $manifest["sourceEdition"] = $ImageName
        $manifest["editionUpgrade"] = $script:VirtualEditionCatalog[$EditionUpgrade].ManifestValue
    }

    try {
        $json = $manifest | ConvertTo-Json
        [System.IO.File]::WriteAllText($manifestPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "Wrote gold image manifest '$manifestPath'" -Tag "Info"
        return $true
    }
    catch {
        Write-Log "Failed to write gold image manifest '$manifestPath': $($_.Exception.Message)" -Tag "Error"
        return $false
    }
}

# ---------------------------[ Unattend Content ]---------------------------
function Get-TempBootUnattendContent {
    # Minimal audit-mode answer file for the temporary sysprep VM only.
    # Generalize WITHOUT /unattend so the gold image does not cache a Deploy
    # answer file / UnattendFile registry pointer. Build-Vms.ps1 injects the
    # real per-VM unattend into Panther at provision time.
    param(
        [string]$Target,
        [string]$DeployUnattendPath = "C:\Windows\Deploy\unattend.xml"
    )

    # $DeployUnattendPath kept for call-site compatibility; neither target
    # passes /unattend to sysprep (avoids first-boot answer-file conflicts).
    $null = $DeployUnattendPath

    # HyperV: /mode:vm - faster first boot when VHD stays on Hyper-V with a
    # matching Gen2 profile. Azure Local: plain generalize (image may land on
    # different node/SKU profiles).
    $sysprepPath = if ($Target -eq "HyperV") {
        "%WINDIR%\System32\Sysprep\Sysprep.exe /generalize /oobe /mode:vm /shutdown"
    }
    else {
        "%WINDIR%\System32\Sysprep\Sysprep.exe /generalize /oobe /shutdown"
    }

    $content = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <Reseal>
        <Mode>Audit</Mode>
      </Reseal>
    </component>
  </settings>
  <settings pass="auditUser">
    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd /c if exist %WINDIR%\Panther rmdir /S /Q %WINDIR%\Panther</Path>
          <Description>Remove Panther before generalize</Description>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>$sysprepPath</Path>
          <Description>Generalize and shut down</Description>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
"@

    return $content
}

function Get-HyperVDeployUnattendContent {
    # Declarative deploy answer file for traditional Hyper-V first boot.
    # No Administrator password is baked (option A).
    param(
        [string]$Locale,
        [string]$KeyboardLayout,
        [string]$UiLanguage,
        [string]$TimeZone,
        [string]$ProductKey
    )

    $inputLocale = Get-InputLocaleId -KeyboardLayout $KeyboardLayout
    $productKeyXml = ""
    if (-not [string]::IsNullOrWhiteSpace($ProductKey)) {
        $productKeyXml = @"

      <ProductKey>$ProductKey</ProductKey>
"@
    }

    $content = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <InputLocale>$inputLocale</InputLocale>
      <SystemLocale>$Locale</SystemLocale>
      <UILanguage>$UiLanguage</UILanguage>
      <UserLocale>$Locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <ComputerName>*</ComputerName>
      <TimeZone>$TimeZone</TimeZone>$productKeyXml
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
    <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <UserAuthentication>1</UserAuthentication>
    </component>
    <component name="Networking-MPSSVC-Svc"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <FirewallGroups>
        <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
          <Active>true</Active>
          <Group>@FirewallAPI.dll,-28752</Group>
          <Profile>all</Profile>
        </FirewallGroup>
      </FirewallGroups>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <InputLocale>$inputLocale</InputLocale>
      <SystemLocale>$Locale</SystemLocale>
      <UILanguage>$UiLanguage</UILanguage>
      <UserLocale>$Locale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
    </component>
  </settings>
</unattend>
"@

    return $content
}

function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# ---------------------------[ Console Menu ]---------------------------
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
"@ -Name VhdxVtConsole -Namespace VhdxBuild -PassThru -ErrorAction Stop
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
    # badly is worse than one that says the path ends in three dots.
    # The label is measured, not assumed. $LabelWidth is the column it is padded TO,
    # and a longer label simply overruns it - budgeting for eight when twelve are
    # written leaves the value four columns too long, which is exactly enough to wrap
    # it into the logo.
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
    Write-Studio -Text $Value -Key "fg"
}

function Show-MenuHeader {
    # Fastfetch-style header: colored server logo (left) + aligned facts (right).
    param(
        [string]$Title = "Builder",
        [hashtable]$StatusLines,
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
# blink; on the 251-locale and 419-zone lists it is a full page of writing per arrow
# key, and the screen visibly flashes.
#
# The header and the heading do not change while a list is being walked, so they are
# drawn ONCE and the cursor is parked underneath them. Each keypress rewinds to that
# spot, wipes what is below it and writes the list again - the top of the screen is
# never touched, so there is nothing to flash.
#
# Where the host cannot report or set a cursor position - ISE, a redirected console,
# a terminal with no VT - every one of these returns false and the caller falls back
# to the full redraw it always did.

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
    # A repaint that pushes past the bottom scrolls the buffer, and every row above -
    # the anchor included - moves up by however far it went. The anchor is then a lie,
    # so the caller is told to take a fresh one.
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
        [hashtable]$StatusLines,
        [string]$Subtitle,
        [scriptblock]$PreItems,
        # Field label printed immediately above the option list, same shape as the
        # VHDX form. The fastfetch header alone is too far from the list to read as
        # a question - without this, pickers get mistaken for something else.
        [string]$Heading,
        [string]$HeadingHint
    )

    if (-not $Items -or $Items.Count -eq 0) {
        throw "Show-Menu requires at least one item."
    }

    # An item carrying Separator = $true is drawn but never lands under the caret: it is
    # a blank line or a plain label used to group a long list. Navigation steps over it,
    # so the arrow keys never stop on something that cannot be chosen.
    $isSelectable = {
        param([int]$At)
        if ($At -lt 0 -or $At -ge $Items.Count) { return $false }
        return -not [bool]$Items[$At].Separator
    }
    # $Step is ALWAYS passed parenthesised at the call sites: a bare -1 is read as a
    # parameter name, lands in $args, and leaves $Step at zero - a walk that never walks.
    $nextSelectable = {
        param([int]$From, [int]$Step)
        $at = $From
        # One full lap at most - a list that is nothing but separators has no answer,
        # and walking for ever looking for one is the wrong way to say so.
        #
        # The counter is $hops and NOT $step: PowerShell variable names are case
        # insensitive, so a `for ($step = 0; ...)` here is the same variable as the
        # $Step parameter and zeroes it on the loop's first statement. The walk then
        # adds nothing each time round and every caret movement silently does nothing.
        for ($hops = 0; $hops -lt $Items.Count; $hops++) {
            $at = $at + $Step
            if ($at -lt 0) { $at = $Items.Count - 1 }
            if ($at -ge $Items.Count) { $at = 0 }
            if (& $isSelectable $at) { return $at }
        }
        return $From
    }

    $index = $SelectedIndex
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $Items.Count) { $index = $Items.Count - 1 }
    if (-not (& $isSelectable $index)) { $index = & $nextSelectable $index 1 }

    $useRawUi = Test-MenuHostSupported
    $maxVisible = 16

    # The header and the heading are the same on every pass, so they are written once
    # and the list below them is what a keypress rewrites. $anchor is where that list
    # starts; a null one means "draw the whole screen", which is also what happens when
    # the host cannot place a cursor or the buffer has scrolled under us.
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

            if (-not [string]::IsNullOrWhiteSpace($Heading)) {
                Write-Studio -Text "  $Heading" -Key "fg"
                if (-not [string]::IsNullOrWhiteSpace($HeadingHint)) {
                    Write-Studio -Text "  $HeadingHint" -Key "muted"
                }
                Write-Host ""
            }

            $anchor = Get-MenuCursorAnchor
        }

        $windowStart = 0
        if ($Items.Count -gt $maxVisible) {
            $windowStart = $index - [math]::Floor($maxVisible / 2)
            if ($windowStart -lt 0) { $windowStart = 0 }
            if (($windowStart + $maxVisible) -gt $Items.Count) {
                $windowStart = $Items.Count - $maxVisible
            }
        }
        $windowEnd = [Math]::Min(($windowStart + $maxVisible - 1), ($Items.Count - 1))

        if ($windowStart -gt 0) {
            Write-Studio -Text "    ..." -Key "muted"
        }

        for ($i = $windowStart; $i -le $windowEnd; $i++) {
            $item  = $Items[$i]
            $label = if ($item.Label) { [string]$item.Label } else { [string]$item }
            $selected = ($i -eq $index)

            if ($item.Separator) {
                # Read the label off the item, NOT from $label above. That line falls
                # back to [string]$item when Label is empty - which is what lets a menu
                # be given plain strings instead of objects - and a blank separator has
                # exactly that empty Label, so it was rendering as the object's own
                # ToString: "@{Id=__gap__; Label=; Separator=True}".
                $separatorText = [string]$item.Label
                # Two spaces of indent so a separator that carries text lines up with
                # the rows around it, and a blank one is simply a blank line.
                if ([string]::IsNullOrWhiteSpace($separatorText)) { Write-Host "" }
                else { Write-Studio -Text "  $separatorText" -Key "muted" }
                continue
            }

            if ($selected) {
                Write-Studio -Text "  > " -Key "accent" -NoNewline
                Write-Studio -Text $label -Key "fg"
            }
            else {
                Write-Host "    " -NoNewline
                Write-Studio -Text $label -Key "muted"
            }
        }

        if ($windowEnd -lt ($Items.Count - 1)) {
            Write-Studio -Text "    ..." -Key "muted"
        }

        Write-Host ""
        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
        if ($useRawUi) {
            Write-Studio -Text "  Up/Down move   PgUp/PgDn/Home/End jump   Enter select   Esc/Q cancel" -Key "muted"
        }
        else {
            Write-Studio -Text "  Enter number + Enter   (Q to cancel)" -Key "muted"
        }
        Write-Host ""

        # Read when the frame is COMPLETE, never half way through it. A frame taller
        # than the window scrolls as its last lines are written, so a top measured
        # before the list was drawn always disagrees with the one measured after - and
        # the guard then declared a scroll on every single keypress and redrew the
        # whole screen. That is the flicker coming back on exactly the tall blades:
        # the build summary, a long feature list. Measured here the number settles
        # after the first paint and the repaint path is used from then on.
        $windowTop = Get-MenuWindowTop

        if ($useRawUi) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            $virtualKey = [int]$key.VirtualKeyCode
            $charKey = [string]$key.Character

            if ($virtualKey -eq 38) {
                $index = & $nextSelectable $index (-1)
                continue
            }
            if ($virtualKey -eq 40) {
                $index = & $nextSelectable $index 1
                continue
            }
            if ($virtualKey -eq 33) {
                $target = [Math]::Max(0, $index - $maxVisible)
                if (& $isSelectable $target) { $index = $target }
                else { $index = & $nextSelectable $target 1 }
                continue
            }
            if ($virtualKey -eq 34) {
                $target = [Math]::Min($Items.Count - 1, $index + $maxVisible)
                if (& $isSelectable $target) { $index = $target }
                else { $index = & $nextSelectable $target (-1) }
                continue
            }
            if ($virtualKey -eq 36) {
                $index = if (& $isSelectable 0) { 0 } else { & $nextSelectable 0 1 }
                continue
            }
            if ($virtualKey -eq 35) {
                $last = $Items.Count - 1
                $index = if (& $isSelectable $last) { $last } else { & $nextSelectable $last (-1) }
                continue
            }
            if ($virtualKey -eq 13) {
                if (-not (& $isSelectable $index)) { continue }
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
                if ($num -ge 1 -and $num -le $Items.Count -and (& $isSelectable ($num - 1))) {
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
        [hashtable]$StatusLines,
        [switch]$AllowEmpty,
        [string]$Subtitle = "Space toggles selection",
        # Free lines rendered above the list, for a menu whose consequences do not fit
        # in a subtitle. Kept as an array so the caller controls where each line breaks
        # rather than trusting a terminal width nobody measured.
        [string[]]$Note = @(),
        # One emphasised line above the note - bold where the host can draw it, bright
        # white where it cannot. For the sentence a reader must not skim past.
        [string]$NoteHeadline = "",
        # When set, a real row the cursor can land on that confirms the selection. A menu
        # whose sane answer is "none of these" needs somewhere to press Enter that reads
        # like continuing, not like giving up.
        [string]$ContinueLabel = "",
        # Free lines rendered directly under a section header, keyed by section name.
        # For the sentence that belongs to one group of rows rather than the whole menu.
        [hashtable]$SectionNotes = @{}
    )

    if (-not $Items -or $Items.Count -eq 0) {
        throw "Show-MultiSelectMenu requires at least one item."
    }

    $index = 0
    $selected = @{}
    foreach ($item in $Items) {
        $selected[[string]$item.Id] = [bool]$item.Selected
    }

    $useRawUi = Test-MenuHostSupported
    $hasSections = (@($Items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Section) })).Count -gt 0

    # Rows are what the cursor walks; items are what can be ticked. They differ by the
    # continue row, which is navigable but carries no checkbox.
    $rows = @($Items)
    if (-not [string]::IsNullOrWhiteSpace($ContinueLabel)) {
        $rows += [PSCustomObject]@{ Id = "__continue__"; Label = $ContinueLabel; IsContinue = $true }
    }

    # Header and notes once, the rows on every keypress - see the repaint helpers.
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

            if (-not [string]::IsNullOrWhiteSpace($NoteHeadline)) {
                if (Test-MenuAnsiSupported) {
                    $esc = [char]27
                    Write-Studio -Text "  $esc[1m$NoteHeadline$esc[0m" -Key "fg"
                }
                else {
                    Write-Studio -Text "  $NoteHeadline" -Key "fg"
                }
                Write-Host ""
            }

            if ($Note.Count -gt 0) {
                foreach ($line in $Note) {
                    # A blank entry is a paragraph break, not two spaces of trailing whitespace.
                    if ([string]::IsNullOrWhiteSpace($line)) { Write-Host "" }
                    else { Write-Studio -Text "  $line" -Key "muted" }
                }
                Write-Host ""
            }

            $anchor = Get-MenuCursorAnchor
        }

        $lastSection = $null
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $item  = $rows[$i]
            $isSelectedRow = ($i -eq $index)
            $indent = if ($hasSections) { "  " } else { "" }

            if ($item.IsContinue) {
                Write-Host ""
                if ($isSelectedRow) {
                    Write-Studio -Text "  $indent> " -Key "accent" -NoNewline
                    Write-Studio -Text $item.Label -Key "fg"
                }
                else {
                    Write-Host "    $indent" -NoNewline
                    Write-Studio -Text $item.Label -Key "muted"
                }
                continue
            }

            $section = [string]$item.Section
            if (-not [string]::IsNullOrWhiteSpace($section) -and $section -ne $lastSection) {
                if ($null -ne $lastSection) { Write-Host "" }
                Write-Studio -Text "  $section" -Key "fg"
                if ($SectionNotes.ContainsKey($section)) {
                    Write-Host ""
                    foreach ($line in @($SectionNotes[$section])) {
                        if ([string]::IsNullOrWhiteSpace($line)) { Write-Host "" }
                        else { Write-Studio -Text "  $line" -Key "muted" }
                    }
                }
                Write-Host ""
                $lastSection = $section
            }

            $id    = [string]$item.Id
            $mark  = if ($selected[$id]) { "[x]" } else { "[ ]" }
            $label = "$mark  $($item.Label)"

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
            Write-Studio -Text "  Up/Down move   Space toggle   Enter continue   Esc/Q cancel" -Key "muted"
        }
        else {
            Write-Studio -Text "  Number toggles, Enter continues, Q cancels" -Key "muted"
        }
        Write-Host ""

        # Read when the frame is COMPLETE, never half way through it. A frame taller
        # than the window scrolls as its last lines are written, so a top measured
        # before the list was drawn always disagrees with the one measured after - and
        # the guard then declared a scroll on every single keypress and redrew the
        # whole screen. That is the flicker coming back on exactly the tall blades:
        # the build summary, a long feature list. Measured here the number settles
        # after the first paint and the repaint path is used from then on.
        $windowTop = Get-MenuWindowTop

        if ($useRawUi) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            $virtualKey = [int]$key.VirtualKeyCode
            $charKey = [string]$key.Character

            if ($virtualKey -eq 38) {
                $index = if ($index -le 0) { $rows.Count - 1 } else { $index - 1 }
                continue
            }
            if ($virtualKey -eq 40) {
                $index = if ($index -ge ($rows.Count - 1)) { 0 } else { $index + 1 }
                continue
            }
            if ($virtualKey -eq 32) {
                # Nothing to toggle on the continue row.
                if ($rows[$index].IsContinue) { continue }
                $id = [string]$rows[$index].Id
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
                if ($chosen.Count -eq 0 -and -not $AllowEmpty) {
                    continue
                }
                # Comma operator: a bare `return @()` unrolls to $null at the call site,
                # which every caller reads as "cancelled". An empty selection is an
                # answer - it means continue with none of these - and has to survive the
                # return intact to say so.
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
                if ($chosen.Count -eq 0 -and -not $AllowEmpty) { continue }
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

function Show-VhdxConfigForm {
    # Single-screen VHDX config: size is a typed field, type is a toggle -
    # both live on one form instead of two sequential menu screens.
    param(
        [string]$Title = "Configure VHDX",
        [string]$Subtitle = "Disk size and provisioning type",
        [hashtable]$StatusLines,
        [int]$DefaultSizeGB = 64,
        [int]$MinSizeGB = 20,
        [int]$MaxSizeGB = 2048,
        [string]$DefaultType = "Fixed"
    )

    $typeOptions = @(
        [PSCustomObject]@{ Id = "Fixed";   Label = "Fixed";   Description = "pre-allocated, best performance" }
        [PSCustomObject]@{ Id = "Dynamic"; Label = "Dynamic"; Description = "grows on demand, saves host space" }
    )

    if (-not (Test-MenuHostSupported)) {
        Show-MenuHeader -Title $Title -Subtitle $Subtitle -StatusLines $StatusLines
        $sizeGB = Read-BoundedInt -Prompt "VHDX size in GB" -DefaultValue $DefaultSizeGB -MinValue $MinSizeGB -MaxValue $MaxSizeGB
        $typeChoice = Read-Host "VHDX type: Fixed or Dynamic [$DefaultType]"
        if ([string]::IsNullOrWhiteSpace($typeChoice)) { $typeChoice = $DefaultType }
        if ($typeChoice -notin @("Fixed", "Dynamic")) { $typeChoice = $DefaultType }
        return [PSCustomObject]@{ SizeGB = $sizeGB; Type = $typeChoice }
    }

    $sizeText = [string]$DefaultSizeGB
    $selectedType = if ($DefaultType -eq "Dynamic") { "Dynamic" } else { "Fixed" }
    # Rows: 0 = size field, 1 = Fixed, 2 = Dynamic - Up/Down walks all three so
    # the cursor can reach Dynamic directly instead of bouncing back to size.
    # Always open on the size field: parking on a type radio made the size look
    # like a fixed label nobody could edit.
    $cursor = 0
    $rowCount = 3
    $errorMessage = $null

    # Typing a digit redraws this form. Redrawing the header with it made every
    # keystroke blink the screen - see the repaint helpers above Show-Menu.
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
            Show-MenuHeader -Title $Title -Subtitle $Subtitle -StatusLines $StatusLines
            $anchor = Get-MenuCursorAnchor
        }

        Write-Studio -Text "  Disk size (GB)" -Key "fg"
        Write-Studio -Text "  Editable - type digits to change it, Backspace deletes." -Key "muted"
        Write-Host ""
        if ($cursor -eq 0) {
            Write-Studio -Text "    > " -Key "accent" -NoNewline
            Write-Studio -Text "$($sizeText)_" -Key "fg" -NoNewline
            Write-Studio -Text "   (default $DefaultSizeGB, range $MinSizeGB-$MaxSizeGB)" -Key "muted"
        }
        else {
            Write-Host "      " -NoNewline
            $shownSize = if ([string]::IsNullOrWhiteSpace($sizeText)) { "$DefaultSizeGB" } else { $sizeText }
            Write-Studio -Text $shownSize -Key "muted"
        }
        Write-Host ""
        Write-Studio -Text "  Type" -Key "fg"
        for ($i = 0; $i -lt $typeOptions.Count; $i++) {
            $opt = $typeOptions[$i]
            $rowIndex = $i + 1
            $mark = if ($opt.Id -eq $selectedType) { "(*)" } else { "( )" }
            $label = "$mark $($opt.Label)  - $($opt.Description)"
            if ($cursor -eq $rowIndex) {
                Write-Studio -Text "    > " -Key "accent" -NoNewline
                Write-Studio -Text $label -Key "fg"
            }
            else {
                Write-Host "      " -NoNewline
                Write-Studio -Text $label -Key "muted"
            }
        }

        if ($errorMessage) {
            Write-Host ""
            Write-Studio -Text "  $errorMessage" -Key "warn"
        }

        Write-Host ""
        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
        Write-Studio -Text "  Up/Down move   Space select type   Type digits for size   Enter confirm   Esc cancel" -Key "muted"
        Write-Host ""

        # Read when the frame is COMPLETE, never half way through it. A frame taller
        # than the window scrolls as its last lines are written, so a top measured
        # before the list was drawn always disagrees with the one measured after - and
        # the guard then declared a scroll on every single keypress and redrew the
        # whole screen. That is the flicker coming back on exactly the tall blades:
        # the build summary, a long feature list. Measured here the number settles
        # after the first paint and the repaint path is used from then on.
        $windowTop = Get-MenuWindowTop

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        $virtualKey = [int]$key.VirtualKeyCode
        $charKey = [string]$key.Character

        if ($virtualKey -eq 27 -or $charKey -eq "q" -or $charKey -eq "Q") {
            return $null
        }
        if ($virtualKey -eq 38) {
            $cursor = if ($cursor -le 0) { $rowCount - 1 } else { $cursor - 1 }
            continue
        }
        if ($virtualKey -eq 40) {
            $cursor = if ($cursor -ge ($rowCount - 1)) { 0 } else { $cursor + 1 }
            continue
        }
        if ($cursor -eq 0) {
            if ($virtualKey -eq 8) {
                if ($sizeText.Length -gt 0) { $sizeText = $sizeText.Substring(0, $sizeText.Length - 1) }
                continue
            }
            if ($charKey -match "^\d$") {
                if ($sizeText.Length -lt 5) { $sizeText += $charKey }
                continue
            }
        }
        else {
            if ($virtualKey -eq 32) {
                $selectedType = $typeOptions[$cursor - 1].Id
                continue
            }
        }
        if ($virtualKey -eq 13) {
            $candidate = if ([string]::IsNullOrWhiteSpace($sizeText)) { $DefaultSizeGB } else { 0 }
            if ($candidate -eq 0 -and $sizeText -match "^\d+$") { $candidate = [int]$sizeText }
            if ($candidate -lt $MinSizeGB -or $candidate -gt $MaxSizeGB) {
                $errorMessage = "Enter a whole number between $MinSizeGB and $MaxSizeGB."
                $cursor = 0
                continue
            }
            return [PSCustomObject]@{ SizeGB = $candidate; Type = $selectedType }
        }
    }
}

function Test-WindowsInstallSources {
    param([string]$DriveRoot)

    if ([string]::IsNullOrWhiteSpace($DriveRoot)) {
        return $false
    }

    $root = $DriveRoot.TrimEnd('\')
    if (-not $root.EndsWith(':')) {
        $root = "${root}:"
    }

    # Test-Path -LiteralPath avoids Join-Path throwing on missing drives.
    if (-not (Test-Path -LiteralPath "$root\" -ErrorAction SilentlyContinue)) {
        return $false
    }

    return (
        (Test-Path -LiteralPath "$root\sources\install.wim" -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath "$root\sources\install.esd" -ErrorAction SilentlyContinue)
    )
}

function Get-MountedIsoDriveCandidates {
    # Finds drives that look like a mounted Windows ISO (sources\install.wim|esd).
    # Scans every lettered volume, then A-Z. Missing drives are skipped quietly.
    $candidates = @()
    $seen = @{}

    $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })
    foreach ($volume in $volumes) {
        $drive = "$($volume.DriveLetter):".ToUpperInvariant()
        if ($seen.ContainsKey($drive)) { continue }
        if (-not (Test-WindowsInstallSources -DriveRoot $drive)) { continue }

        $label = $volume.FileSystemLabel
        if ([string]::IsNullOrWhiteSpace($label)) {
            if ($volume.DriveType -eq "CD-ROM") {
                $label = "ISO"
            }
            else {
                $label = [string]$volume.DriveType
            }
        }

        $seen[$drive] = $true
        $candidates += [PSCustomObject]@{
            Id    = $drive
            Label = "$drive  $label"
        }
    }

    foreach ($code in 65..90) {
        $drive = "$([char]$code):"
        if ($seen.ContainsKey($drive)) { continue }
        if (-not (Test-WindowsInstallSources -DriveRoot $drive)) { continue }

        $seen[$drive] = $true
        $candidates += [PSCustomObject]@{
            Id    = $drive
            Label = "$drive  Windows sources"
        }
    }

    return $candidates
}

function Read-ConsolePath {
    # Styled to match the arrow-key menus (white label, gray hint, cyan
    # input row) instead of a bare Read-Host prompt.
    param(
        [string]$Prompt,
        [string]$DefaultPath
    )

    Write-Studio -Text "  $Prompt" -Key "fg"
    if (-not [string]::IsNullOrWhiteSpace($DefaultPath)) {
        Write-Studio -Text "    (blank keeps default: $DefaultPath)" -Key "muted"
    }
    Write-Host ""
    Write-Studio -Text "    > " -Key "accent" -NoNewline

    # Capture the input row so it can be re-drawn on after the footer prints
    # below it - console output is linear, so drawing order isn't display order.
    $inputPosition = $null
    try {
        $inputPosition = $Host.UI.RawUI.CursorPosition
    }
    catch {
        $inputPosition = $null
    }

    # First blank line ends the input row (its Write-Host was -NoNewline); the second
    # is the same breathing room every menu leaves above its footer divider.
    Write-Host ""
    Write-Host ""
    Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
    Write-Studio -Text "  Type a path, then Enter   (blank keeps default)" -Key "muted"
    Write-Host ""

    if ($null -ne $inputPosition) {
        try { $Host.UI.RawUI.CursorPosition = $inputPosition } catch { }
    }

    $raw = Read-Host
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $DefaultPath
    }
    return $raw.Trim().Trim('"')
}

function Write-BladeFooterAbove {
    <#
        Draws the closing rule BELOW the rows the caller is about to type into, then
        puts the cursor back on the first of them - so the frame is on screen while the
        question is still unanswered. Console output is linear and drawing order is not
        display order; Read-ConsolePath does the same thing for the same reason.

        $ReserveLines is how many input rows follow.

        The rewind is GUARDED. The cursor only goes back when the console advanced by
        exactly the number of lines that were written: a host that answers
        CursorPosition with a terminal query can report 1;1 (observed under a pty), and
        a rule drawn from there lands on top of the header. When the numbers disagree
        the rule simply stays where it was drawn, which is the older behaviour - the
        frame closes after the answer rather than before it. Ugly, never wrong.
    #>
    param([int]$ReserveLines = 1)

    $before = $null
    try { $before = $Host.UI.RawUI.CursorPosition } catch { $before = $null }

    for ($i = 0; $i -lt $ReserveLines; $i++) { Write-Host "" }
    Write-Host ""
    Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
    Write-Host ""

    if ($null -eq $before) { return }

    $after = $null
    try { $after = $Host.UI.RawUI.CursorPosition } catch { $after = $null }
    if ($null -eq $after) { return }

    # Reserve blanks + the blank above the rule + the rule + the blank below it.
    $expected = $ReserveLines + 3
    if (($after.Y - $before.Y) -ne $expected) { return }

    try { $Host.UI.RawUI.CursorPosition = $before } catch { }
}

function Read-BoundedInt {
    # Loops until a whole number within [MinValue, MaxValue] is entered; blank keeps the default.
    param(
        [string]$Prompt,
        [int]$DefaultValue,
        [int]$MinValue,
        [int]$MaxValue
    )

    while ($true) {
        $raw = Read-Host "$Prompt [$DefaultValue] (range $MinValue-$MaxValue)"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultValue
        }
        if ($raw -match "^\d+$") {
            $value = [int]$raw
            if ($value -ge $MinValue -and $value -le $MaxValue) {
                return $value
            }
        }
        Write-Studio -Text "  Enter a whole number between $MinValue and $MaxValue." -Key "warn"
    }
}

function Read-ConsoleIpAddress {
    # Loops until a dotted-quad IPv4 address is entered. Blank returns the default,
    # which for an optional field is an empty string - a gateway or a DNS server that
    # nobody wants is a legitimate answer, an address with five octets is not.
    param(
        [string]$Prompt,
        [string]$DefaultValue = "",
        [switch]$AllowEmpty
    )

    while ($true) {
        $shown = if ([string]::IsNullOrWhiteSpace($DefaultValue)) { "" } else { " [$DefaultValue]" }
        $raw = Read-Host "$Prompt$shown"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) { return $DefaultValue }
            if ($AllowEmpty) { return "" }
            Write-Studio -Text "  An address is required here." -Key "warn"
            continue
        }

        $candidate = $raw.Trim()
        $parsed = [System.Net.IPAddress]::None
        if ([System.Net.IPAddress]::TryParse($candidate, [ref]$parsed) -and
            $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
            ($candidate -split "\.").Count -eq 4) {
            return $candidate
        }
        # TryParse alone is too generous: it accepts "10.1" and reads it as 10.0.0.1,
        # which is never what somebody typing a lab address meant.
        Write-Studio -Text "  Enter an IPv4 address as four numbers, for example 10.10.10.25." -Key "warn"
    }
}

function Get-FilePickerEntries {
    # Builds the current folder listing for the arrow-key ISO browser.
    param([string]$CurrentPath)

    $entries = @()

    if ([string]::IsNullOrWhiteSpace($CurrentPath) -or $CurrentPath -eq ":DRIVES") {
        $entries += [PSCustomObject]@{
            Id       = ":CANCEL"
            Kind     = "action"
            Label    = "[ Cancel ]"
            FullPath = ""
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
                Id       = $root
                Kind     = "drive"
                Label    = ("{0}\{1}" -f $root, $labelExtra).TrimEnd()
                FullPath = "$root\"
            }
        }

        return $entries
    }

    $normalized = $CurrentPath
    if (-not (Test-Path -LiteralPath $normalized -ErrorAction SilentlyContinue)) {
        return @(
            [PSCustomObject]@{
                Id       = ":DRIVES"
                Kind     = "nav"
                Label    = "..  (drives)"
                FullPath = ":DRIVES"
            }
        )
    }

    $parent = Split-Path -Path $normalized -Parent
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $normalized) {
        $entries += [PSCustomObject]@{
            Id       = ":DRIVES"
            Kind     = "nav"
            Label    = "..  (drives)"
            FullPath = ":DRIVES"
        }
    }
    else {
        $entries += [PSCustomObject]@{
            Id       = $parent
            Kind     = "nav"
            Label    = ".."
            FullPath = $parent
        }
    }

    try {
        $dirs = @(Get-ChildItem -LiteralPath $normalized -Directory -Force -ErrorAction Stop |
            Sort-Object -Property Name)
        foreach ($dir in $dirs) {
            $entries += [PSCustomObject]@{
                Id       = $dir.FullName
                Kind     = "dir"
                Label    = "[+] $($dir.Name)"
                FullPath = $dir.FullName
            }
        }
    }
    catch {
        $entries += [PSCustomObject]@{
            Id       = ":ERROR"
            Kind     = "action"
            Label    = "(cannot list folders: $($_.Exception.Message))"
            FullPath = ""
        }
    }

    try {
        $isos = @(Get-ChildItem -LiteralPath $normalized -File -Force -ErrorAction Stop |
            Where-Object { $_.Extension -match '^\.iso$' } |
            Sort-Object -Property Name)
        foreach ($iso in $isos) {
            $sizeGb = [math]::Round($iso.Length / 1GB, 2)
            $entries += [PSCustomObject]@{
                Id       = $iso.FullName
                Kind     = "iso"
                Label    = "$($iso.Name)  (${sizeGb} GB)"
                FullPath = $iso.FullName
            }
        }
    }
    catch { }

    return $entries
}

function Get-DefaultIsoBrowseRoot {
    <#
      isos\ next to the script is the project's convention for keeping Windows and Features
      on Demand media together. Nothing requires it - but when that folder exists and holds
      at least one .iso, open the browser there instead of at the drive list.
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
        [string]$StartPath = ":DRIVES"
    )

    $currentPath = $StartPath
    $index = 0
    $useRawUi = Test-MenuHostSupported
    $anchor = $null
    $windowTop = $null
    $anchoredPath = $null

    while ($true) {
        $entries = @(Get-FilePickerEntries -CurrentPath $currentPath)
        if ($entries.Count -eq 0) {
            $entries = @(
                [PSCustomObject]@{
                    Id       = ":DRIVES"
                    Kind     = "nav"
                    Label    = "..  (drives)"
                    FullPath = ":DRIVES"
                }
            )
        }

        if ($index -ge $entries.Count) { $index = $entries.Count - 1 }
        if ($index -lt 0) { $index = 0 }

        $displayPath = $currentPath
        if ($displayPath -eq ":DRIVES") {
            $displayPath = "This PC (drives)"
        }

        $status = [ordered]@{ path = $displayPath }

        # Unlike the menus, this header is not constant: it carries the folder being
        # browsed. Walking the rows inside one folder repaints the list alone; stepping
        # into a folder changes the header, so the anchor is dropped and the whole
        # screen is drawn again - once per folder rather than once per arrow key.
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
            Show-MenuHeader -Title "Select Windows ISO file" -Subtitle "Enter opens folder / selects .iso" `
                -StatusLines $status
            $anchor = Get-MenuCursorAnchor
            $anchoredPath = $displayPath
        }

        $maxVisible = 16
        $windowStart = 0
        if ($entries.Count -gt $maxVisible) {
            $windowStart = $index - [math]::Floor($maxVisible / 2)
            if ($windowStart -lt 0) { $windowStart = 0 }
            if (($windowStart + $maxVisible) -gt $entries.Count) {
                $windowStart = $entries.Count - $maxVisible
            }
        }
        $windowEnd = [Math]::Min(($windowStart + $maxVisible - 1), ($entries.Count - 1))

        if ($windowStart -gt 0) {
            Write-Studio -Text "    ..." -Key "muted"
        }

        for ($i = $windowStart; $i -le $windowEnd; $i++) {
            $entry = $entries[$i]
            $selected = ($i -eq $index)
            $prefix = "    "
            # Palette keys, not ConsoleColor names. The four that were here - Cyan,
            # Yellow, DarkGray, Gray - are not in the table, so Write-Studio fell back
            # to `fg` for every one of them and the list has been drawn in a single
            # colour all along.
            $color = "fg"

            if ($entry.Kind -eq "dir" -or $entry.Kind -eq "drive") {
                $color = "warn"
            }
            elseif ($entry.Kind -eq "nav") {
                # ".." is the way out, so it takes the accent the caret takes.
                $color = "accent"
            }

            if ($selected) {
                Write-Studio -Text "  > " -Key "accent" -NoNewline
                Write-Studio -Text $entry.Label -Key "fg"
            }
            else {
                Write-Host $prefix -NoNewline
                Write-Studio -Text $entry.Label -Key $color
            }
        }

        if ($windowEnd -lt ($entries.Count - 1)) {
            Write-Studio -Text "    ..." -Key "muted"
        }

        Write-Host ""
        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
        if ($useRawUi) {
            Write-Studio -Text "  Up/Down move   Enter open/select   Backspace up   Esc cancel" -Key "muted"
        }
        else {
            Write-Studio -Text "  Number + Enter selects   B = up   Q = cancel" -Key "muted"
        }
        Write-Host ""

        # Read once the frame is complete - a top measured mid-frame disagrees with
        # itself the moment the list is long enough to scroll the window.
        $windowTop = Get-MenuWindowTop

        if ($useRawUi) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            $virtualKey = [int]$key.VirtualKeyCode
            $charKey = [string]$key.Character

            if ($virtualKey -eq 38) {
                $index = if ($index -le 0) { $entries.Count - 1 } else { $index - 1 }
                continue
            }
            if ($virtualKey -eq 40) {
                $index = if ($index -ge ($entries.Count - 1)) { 0 } else { $index + 1 }
                continue
            }
            if ($virtualKey -eq 8) {
                # Backspace = go up
                if ($currentPath -eq ":DRIVES") { continue }
                $parent = Split-Path -Path $currentPath -Parent
                if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $currentPath) {
                    $currentPath = ":DRIVES"
                }
                else {
                    $currentPath = $parent
                }
                $index = 0
                continue
            }
            if ($virtualKey -eq 27 -or $charKey -eq "q" -or $charKey -eq "Q") {
                return $null
            }
            if ($virtualKey -ne 13) {
                continue
            }

            $chosen = $entries[$index]
        }
        else {
            $raw = Read-Host "Select"
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            if ($raw -match '^[Qq]$') { return $null }
            if ($raw -match '^[Bb]$') {
                if ($currentPath -eq ":DRIVES") { continue }
                $parent = Split-Path -Path $currentPath -Parent
                if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $currentPath) {
                    $currentPath = ":DRIVES"
                }
                else {
                    $currentPath = $parent
                }
                $index = 0
                continue
            }
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
        if ($chosen.Kind -eq "iso") {
            return $chosen.FullPath
        }
    }
}

function Mount-WindowsIsoFile {
    # Mounts an ISO and returns the drive letter root (e.g. E:). Tracks path for cleanup.
    param([string]$IsoFilePath)

    if (-not (Test-Path -LiteralPath $IsoFilePath -PathType Leaf)) {
        throw "ISO file not found: $IsoFilePath"
    }

    Write-Log "Mounting ISO '$IsoFilePath'" -Tag "Run"

    $existing = Get-DiskImage -ImagePath $IsoFilePath -ErrorAction SilentlyContinue
    if ($existing -and $existing.Attached) {
        Write-Log "ISO is already mounted" -Tag "Debug"
    }
    else {
        Mount-DiskImage -ImagePath $IsoFilePath -ErrorAction Stop | Out-Null
        $script:mountedIsoPath = $IsoFilePath
    }

    $volume = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $diskImage = Get-DiskImage -ImagePath $IsoFilePath -ErrorAction SilentlyContinue
        if ($diskImage) {
            $volume = $diskImage | Get-Volume -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter } |
                Select-Object -First 1
        }
        if ($volume) { break }
        Start-Sleep -Milliseconds 300
    }

    if (-not $volume -or -not $volume.DriveLetter) {
        throw "ISO mounted but no drive letter was assigned"
    }

    $drive = "$($volume.DriveLetter):"
    Write-Log "ISO mounted at '$drive'" -Tag "Ok"

    if (-not (Test-WindowsInstallSources -DriveRoot $drive)) {
        throw "Mounted ISO at '$drive' has no sources\install.wim or install.esd"
    }

    return $drive
}

function Get-OrderedLocaleTags {
    # Catalog default on top, en-US next, then the rest alphabetically - same
    # shape whether the catalog is the in-script 14 or a loaded locales.json.
    $tags = @($script:LocaleCatalog.Keys)
    $head = @($script:DefaultLocale)
    if ($script:DefaultLocale -ne "en-US" -and $tags -contains "en-US") {
        $head += "en-US"
    }
    $rest = @($tags | Where-Object { $_ -notin $head } | Sort-Object)
    return @($head + $rest)
}

function Get-OrderedTimeZoneCatalog {
    # Live Windows time zone database (Id = DISM /Set-TimeZone value), sorted
    # by UTC offset then display name - the same order Windows' own Date &
    # Time settings uses, so the picker feels familiar.
    try {
        $zones = [System.TimeZoneInfo]::GetSystemTimeZones() | Sort-Object BaseUtcOffset, DisplayName
    }
    catch {
        Write-Log "Time zone list: $($_.Exception.Message)" -Tag "Debug"
        return @()
    }

    $catalog = @()
    foreach ($zone in $zones) {
        $catalog += [PSCustomObject]@{ Id = $zone.Id; Label = $zone.DisplayName }
    }
    return $catalog
}

function Start-InteractiveConfiguration {
    param(
        [string]$CurrentTarget,
        [string]$CurrentLocale,
        [string]$CurrentKeyboard,
        [string]$CurrentUiLanguage,
        [string]$CurrentTimeZone,
        [int]$CurrentVhdSizeGB,
        [string]$CurrentVhdType,
        [string]$CurrentOutputDirectory,
        [bool]$CurrentEnableRdp = $true,
        [bool]$CurrentEnablePing = $true,
        [bool]$CurrentSuppressServerManagerAtLogon = $false,
        [bool]$CurrentSuppressWelcomeExperience = $false,
        [bool]$CurrentSuppressFirstSignInAnimation = $false,
        [bool]$CurrentBlockSignInInputMethods = $false,
        [bool]$CurrentPreventDeviceEncryption = $true,
        [bool]$CurrentSetVmPowerPlan = $true,
        [bool]$CurrentConfigureEdge = $false,
        [int[]]$CurrentMultiSessionImageIndexes = @(),
        [int[]]$CurrentAzureEditionImageIndexes = @()
    )

    # The first blade. Everything below this point is the Windows path; Linux returns
    # its own configuration object and the caller branches on OsFamily.
    $familyItems = @(
        [PSCustomObject]@{ Id = "Windows"; Label = "Windows" }
        [PSCustomObject]@{ Id = "Linux";   Label = "Linux" }
    )
    $familyId = Show-Menu -Title "What kind of gold is this?" -Items $familyItems `
        -Heading "Operating system" -HeadingHint "Windows builds from an ISO; Linux fetches a cloud image"
    if ($null -eq $familyId) { return $null }

    if ($familyId -eq "Linux") {
        return Start-LinuxInteractiveConfiguration -CurrentLocale $CurrentLocale `
            -CurrentKeyboard $CurrentKeyboard -CurrentOutputDirectory $CurrentOutputDirectory
    }

    $isoCandidates = @(Get-MountedIsoDriveCandidates)
    $pickerItems = @()
    $pickerItems += [PSCustomObject]@{
        Id    = "__browse__"
        Label = "Browse for ISO file..."
    }
    foreach ($candidate in $isoCandidates) {
        $pickerItems += [PSCustomObject]@{
            Id    = $candidate.Id
            Label = "Already mounted: $($candidate.Label)"
        }
    }

    $isoChoice = Show-Menu -Title "Select Windows ISO source" -Items $pickerItems
    if ($null -eq $isoChoice) { return $null }

    $isoId = $null
    $isoFilePath = $null

    if ($isoChoice -eq "__browse__") {
        $isoFilePath = Show-IsoFilePicker -StartPath (Get-DefaultIsoBrowseRoot)
        if ($null -eq $isoFilePath) {
            Write-Log "ISO file selection cancelled - nothing was built" -Tag "Info"
            return $null
        }

        try {
            $isoId = Mount-WindowsIsoFile -IsoFilePath $isoFilePath
        }
        catch {
            Write-Log "Failed to mount ISO '$isoFilePath': $($_.Exception.Message)" -Tag "Error"
            return $null
        }
    }
    else {
        $isoId = $isoChoice
    }

    $isoStatus = $isoId
    if (-not [string]::IsNullOrWhiteSpace($isoFilePath)) {
        $isoStatus = Split-Path -Path $isoFilePath -Leaf
    }

    $targetItems = @(
        [PSCustomObject]@{ Id = "HyperV";     Label = "Hyper-V" }
        [PSCustomObject]@{ Id = "AzureLocal"; Label = "Azure Local" }
    )
    $targetDefault = 0
    if ($CurrentTarget -eq "AzureLocal") { $targetDefault = 1 }
    $targetId = Show-Menu -Title "Select deployment target" -Items $targetItems -SelectedIndex $targetDefault `
        -Heading "Target platform" -HeadingHint "Where the golds built here will be deployed" `
        -StatusLines ([ordered]@{ iso = $isoStatus })
    if ($null -eq $targetId) { return $null }

    $wimPath = Resolve-WindowsImagePath -DriveLetter $isoId
    if ($wimPath -eq "") {
        Write-Log "No install image found under '$isoId\sources'" -Tag "Error"
        return $null
    }

    $images = @(Get-WindowsImage -ImagePath $wimPath)

    # Plain Pro only. Enterprise, Education, Pro for Workstations and the rest are
    # virtual editions already staged on top of Pro, and DISM's own rule is to change
    # the lowest edition in the family and never one that has already been raised -
    # such an image has no packs left to offer. Pro N is excluded on purpose: only
    # plain Pro is verified to list a multi-session target, and a media-less N gold
    # is nothing this lab deploys.
    $msCandidates = @($images | Where-Object {
            (Test-IsClientImage -ImageName $_.ImageName) -and
            ([string]$_.ImageName) -match "(?i)\bpro\s*$"
        })

    # Server 2025 Datacenter only. Probed on retail 26100 media: Datacenter Core
    # lists ServerTurbineCor and Datacenter Desktop lists ServerTurbine directly,
    # while Standard Core lists only ServerDatacenterCor - no direct Azure Edition
    # hop. Standard Desktop does list ServerTurbine, but it would build the same
    # gold as the Datacenter row and collide with it on disk, so one source edition
    # carries the rows. Only Server 2025 media lists the target at all - 2022 ships
    # Azure Edition as a separate image with no conversion path - so older Server
    # ISOs get no rows.
    $azCandidates = @($images | Where-Object {
            ([string]$_.ImageName) -match "(?i)windows\s+server\s+2025\s+datacenter"
        })

    $editionItems = @()
    foreach ($image in $images) {
        $editionItems += [PSCustomObject]@{
            Id      = [string]$image.ImageIndex
            Label   = "Index $($image.ImageIndex): $($image.ImageName)"
            Section = "Editions in this ISO"
        }
    }
    # Virtual edition rows share the screen with the real indexes because they decide
    # what a gold IS, same as picking an index. A row is its own build: the same Pro
    # index can leave once as Pro and once as multi-session, and the gold names
    # (w11-pro / w11-enterprise-ms) keep the two from colliding on disk.
    foreach ($image in $msCandidates) {
        $editionItems += [PSCustomObject]@{
            Id       = "ms:$($image.ImageIndex)"
            Label    = "Index $($image.ImageIndex): Windows 11 Enterprise multi-session"
            Selected = ($CurrentMultiSessionImageIndexes -contains [int]$image.ImageIndex)
            Section  = "Virtual editions"
        }
    }
    foreach ($image in $azCandidates) {
        # Core and Desktop Experience are separate rows from separate indexes, so the
        # label carries the install type the source has - the edition change keeps it.
        $installType = if (([string]$image.ImageName) -match "(?i)desktop") { " (Desktop Experience)" } else { "" }
        $editionItems += [PSCustomObject]@{
            Id       = "az:$($image.ImageIndex)"
            Label    = "Index $($image.ImageIndex): Windows Server 2025 Datacenter: Azure Edition$installType"
            Selected = ($CurrentAzureEditionImageIndexes -contains [int]$image.ImageIndex)
            Section  = "Virtual editions"
        }
    }

    # The licensing caveat sits under the section header it belongs to, not at the top
    # of the whole menu. On Azure Local the SKU is where it is licensed to run, so
    # there is nothing to warn about.
    $editionSectionNotes = @{}
    if ($targetId -ne "AzureLocal") {
        $noteLines = @()
        if ($msCandidates.Count -gt 0) {
            $noteLines += "This build targets Hyper-V. Multi-session is licensed for Azure Virtual Desktop,"
            $noteLines += "so a gold built here is a lab image - not supported in production."
        }
        if ($azCandidates.Count -gt 0) {
            $noteLines += "Azure Edition is supported on Azure and Azure Local only - on plain Hyper-V"
            $noteLines += "the VM deactivates itself once it notices where it runs."
        }
        if ($noteLines.Count -gt 0) {
            $editionSectionNotes["Virtual editions"] = $noteLines
        }
    }

    $editionChoice = Show-MultiSelectMenu -Title "Select edition(s) to build" -Items $editionItems `
        -SectionNotes $editionSectionNotes `
        -StatusLines ([ordered]@{ iso = $isoStatus; target = $targetId })
    if ($null -eq $editionChoice) { return $null }

    $selectedIndexes = @($editionChoice | Where-Object { $_ -notlike "ms:*" -and $_ -notlike "az:*" })
    $multiSessionIndexes = @($editionChoice | Where-Object { $_ -like "ms:*" } | ForEach-Object { [int]($_ -replace "^ms:", "") })
    $azureEditionIndexes = @($editionChoice | Where-Object { $_ -like "az:*" } | ForEach-Object { [int]($_ -replace "^az:", "") })

    # All editions in one ISO share a product line, but detect per selected image so a
    # mixed/unusual WIM still gates features correctly. Virtual edition builds count
    # too: their source index gates the same even when no plain row is ticked.
    $chosenIndexUnion = @(@($selectedIndexes | ForEach-Object { [int]$_ }) + $multiSessionIndexes + $azureEditionIndexes | Sort-Object -Unique)
    $selectedImageObjects = @($images | Where-Object { $chosenIndexUnion -contains [int]$_.ImageIndex })
    $summaryParts = @(foreach ($image in $images) {
            if ($selectedIndexes -contains [string]$image.ImageIndex) { "#$($image.ImageIndex) $($image.ImageName)" }
            if ($multiSessionIndexes -contains [int]$image.ImageIndex) { "#$($image.ImageIndex) Windows 11 Enterprise multi-session" }
            if ($azureEditionIndexes -contains [int]$image.ImageIndex) { "#$($image.ImageIndex) Windows Server 2025 Datacenter: Azure Edition" }
        })
    $editionsSummary = $summaryParts -join "; "
    $buildHasServer = (@($selectedImageObjects | Where-Object { -not (Test-IsClientImage -ImageName $_.ImageName) })).Count -gt 0
    $buildHasClient = (@($selectedImageObjects | Where-Object { Test-IsClientImage -ImageName $_.ImageName })).Count -gt 0
    # Anything that ships a browser: every client image, and Server with Desktop Experience.
    $buildHasEdge = (@($selectedImageObjects | Where-Object { -not (Test-IsServerCoreImage -ImageName $_.ImageName) })).Count -gt 0

    # Status-line value for every later screen: plain indexes as-is, virtual edition
    # builds marked so "5, 5 ms, 2 az" reads as separate golds from their indexes.
    $imagesStatus = (@($selectedIndexes) + @($multiSessionIndexes | ForEach-Object { "$_ ms" }) + @($azureEditionIndexes | ForEach-Object { "$_ az" })) -join ", "

    Show-MenuHeader -Title "Output location" -Subtitle "Enter keeps the default" `
        -StatusLines ([ordered]@{
            iso    = $isoStatus
            target = $targetId
            images = $imagesStatus
        })

    $defaultOutput = $CurrentOutputDirectory
    if ([string]::IsNullOrWhiteSpace($defaultOutput)) {
        $defaultOutput = Join-Path -Path $PSScriptRoot -ChildPath "vhdx"
    }

    $outputDirectory = Read-ConsolePath -Prompt "Where should the finished VHDX file(s) land?" -DefaultPath $defaultOutput

    $localeTags = Get-OrderedLocaleTags
    $localeItems = @()
    foreach ($tag in $localeTags) {
        $localeItems += [PSCustomObject]@{ Id = $tag; Label = "$tag - $(Get-LocaleDisplayName -Locale $tag)" }
    }
    $localeDefaultIndex = [array]::IndexOf($localeTags, $CurrentLocale)
    if ($localeDefaultIndex -lt 0) { $localeDefaultIndex = 0 }
    $localeChoice = Show-Menu -Title "Select locale / keyboard" -Items $localeItems -SelectedIndex $localeDefaultIndex `
        -Heading "Regional format and keyboard layout" `
        -HeadingHint "NOT the display language - the image keeps whatever UI language the ISO shipped with." `
        -StatusLines ([ordered]@{ iso = $isoStatus; target = $targetId; images = $imagesStatus })
    if ($null -eq $localeChoice) { return $null }
    $locale = $localeChoice
    $keyboard = $localeChoice
    $localeSummary = "$locale - $(Get-LocaleDisplayName -Locale $locale)"

    # Time zone picker - same style as the locale picker above, backed by the
    # live Windows time zone database instead of a hardcoded list.
    $timeZoneCatalog = @(Get-OrderedTimeZoneCatalog)
    if ($timeZoneCatalog.Count -gt 0) {
        $tzDefaultIndex = [array]::IndexOf(@($timeZoneCatalog | ForEach-Object { $_.Id }), $CurrentTimeZone)
        if ($tzDefaultIndex -lt 0) { $tzDefaultIndex = 0 }
        $tzChoice = Show-Menu -Title "Select time zone" -Items $timeZoneCatalog -SelectedIndex $tzDefaultIndex `
            -Heading "Default time zone" `
            -HeadingHint "Baked into the image with DISM /Set-TimeZone. Sorted by UTC offset." `
            -StatusLines ([ordered]@{ iso = $isoStatus; target = $targetId; locale = $locale })
        if ($null -eq $tzChoice) { return $null }
        $timeZone = $tzChoice
        $timeZoneSummary = ($timeZoneCatalog | Where-Object { $_.Id -eq $timeZone } | Select-Object -First 1).Label
    }
    else {
        $timeZone = Read-ConsolePath -Prompt "Time zone" -DefaultPath $CurrentTimeZone
        $timeZoneSummary = $timeZone
    }

    # Recommended features apply to every build; optional ones are gated to
    # the build type actually present in the selected edition(s).
    $featureItems = @(
        [PSCustomObject]@{ Id = "rdp";  Label = "Remote Desktop (RDP)"; Selected = $CurrentEnableRdp;  Section = "Recommended" }
        [PSCustomObject]@{ Id = "ping"; Label = "ICMP echo (ping)";     Selected = $CurrentEnablePing; Section = "Recommended" }
    )
    # Recommended on the client path, and ticked: a qualifying VM encrypts itself once
    # OOBE finishes and arms for real at domain join, before any policy has had a say.
    # BitLocker is meant to be turned on deliberately, by GPO after deployment, so the
    # gold stays out of the decision rather than pre-empting it.
    if ($buildHasClient) {
        $featureItems += [PSCustomObject]@{ Id = "autode"; Label = "Prevent automatic BitLocker device encryption"; Selected = $CurrentPreventDeviceEncryption; Section = "Recommended (Client)" }
        # Also recommended on the client path: the gold's whole life is as a VM, where the
        # console blanking after ten minutes and the machine sleeping after thirty are
        # settings written for a laptop lid, and hiberfil.sys is dead weight on every disk
        # cloned from it.
        $featureItems += [PSCustomObject]@{ Id = "power"; Label = "VM power plan (High performance, display/sleep never, no hibernation)"; Selected = $CurrentSetVmPowerPlan; Section = "Recommended (Client)" }
    }
    # Applies to both client and server: pin sign-in keyboard to the baked layout.
    $featureItems += [PSCustomObject]@{ Id = "signin"; Label = "Block per-user input methods on sign-in screen (STIG)"; Selected = $CurrentBlockSignInInputMethods; Section = "Optional" }
    # Edge ships on both sides of the client/server line, but not on Server Core - that
    # install has no browser to manage, so a build made only of Core images is never asked.
    if ($buildHasEdge) {
        $featureItems += [PSCustomObject]@{ Id = "edge"; Label = "Microsoft Edge Config (Google search, no first run, clean new tab)"; Selected = $CurrentConfigureEdge; Section = "Optional" }
    }
    if ($buildHasServer) {
        $featureItems += [PSCustomObject]@{ Id = "svrmgr"; Label = "Suppress Server Manager at logon"; Selected = $CurrentSuppressServerManagerAtLogon; Section = "Optional (Server)" }
    }
    if ($buildHasClient) {
        $featureItems += [PSCustomObject]@{ Id = "welcome"; Label = "Suppress Getting Started / Welcome Experience"; Selected = $CurrentSuppressWelcomeExperience; Section = "Optional (Client)" }
        $featureItems += [PSCustomObject]@{ Id = "signinanim"; Label = "Suppress first sign-in animation"; Selected = $CurrentSuppressFirstSignInAnimation; Section = "Optional (Client)" }
    }
    $featureChoice = Show-MultiSelectMenu -Title "Recommended & optional features" -Items $featureItems -AllowEmpty `
        -Subtitle "Space toggles selection - grouped by relevance to this build" `
        -ContinueLabel "Continue" `
        -StatusLines ([ordered]@{ iso = $isoStatus; target = $targetId; locale = $locale })
    if ($null -eq $featureChoice) { return $null }
    $enableRdp = $featureChoice -contains "rdp"
    $enablePing = $featureChoice -contains "ping"
    $suppressServerManager = $featureChoice -contains "svrmgr"
    $suppressWelcome = $featureChoice -contains "welcome"
    $suppressSignInAnimation = $featureChoice -contains "signinanim"
    $blockSignIn = $featureChoice -contains "signin"
    $configureEdge = $featureChoice -contains "edge"
    $preventDeviceEncryption = $featureChoice -contains "autode"
    $setVmPowerPlan = $featureChoice -contains "power"

    # Dedicated VHDX window: size and type together on one form.
    $vhdxConfig = Show-VhdxConfigForm -Title "Configure VHDX" -Subtitle "Disk size and provisioning type" `
        -StatusLines ([ordered]@{ iso = $isoStatus; target = $targetId; locale = $locale; timezone = $timeZone }) `
        -DefaultSizeGB $CurrentVhdSizeGB -MinSizeGB 20 -MaxSizeGB 2048 -DefaultType $CurrentVhdType
    if ($null -eq $vhdxConfig) { return $null }
    $vhdSizeGB = $vhdxConfig.SizeGB
    $vhdType = $vhdxConfig.Type

    # Final confirmation screen - every selected setting, then Continue/Cancel.
    $renderSummary = {
        Write-Studio -Text "  Source" -Key "fg"
        Write-FastfetchInfoRow -Label "iso"      -Value $isoStatus -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "target"   -Value $targetId -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "editions" -Value $editionsSummary -LabelWidth 24 -IndentWidth 2
        # Shown only where the rows were actually offered - an ISO with no Pro index
        # never had virtual edition rows, and a row reading "No" implies it did.
        if ($msCandidates.Count -gt 0) {
            Write-FastfetchInfoRow -Label "multi-session" -Value $(if ($multiSessionIndexes.Count -gt 0) {
                "index " + ($multiSessionIndexes -join ", ") + " built as own gold, upgraded after generalize"
            } else { "No" }) -LabelWidth 24 -IndentWidth 2
        }
        if ($azCandidates.Count -gt 0) {
            Write-FastfetchInfoRow -Label "azure edition" -Value $(if ($azureEditionIndexes.Count -gt 0) {
                "index " + ($azureEditionIndexes -join ", ") + " built as own gold, upgraded after generalize"
            } else { "No" }) -LabelWidth 24 -IndentWidth 2
        }
        Write-FastfetchInfoRow -Label "output"   -Value $outputDirectory -LabelWidth 24 -IndentWidth 2
        Write-Host ""
        Write-Studio -Text "  Region" -Key "fg"
        Write-FastfetchInfoRow -Label "locale"    -Value $localeSummary -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "time zone" -Value $timeZoneSummary -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "applied" -Value $(if ($targetId -eq "AzureLocal") {
            "At the VM's first boot - Azure Local overwrites a baked locale"
        } else { "Baked into the image offline" }) -LabelWidth 24 -IndentWidth 2
        Write-Host ""
        Write-Studio -Text "  Features" -Key "fg"
        Write-FastfetchInfoRow -Label "remote desktop (rdp)" -Value $(if ($enableRdp) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "icmp echo (ping)"     -Value $(if ($enablePing) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "block sign-in imes"   -Value $(if ($blockSignIn) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
        if ($buildHasEdge) {
            Write-FastfetchInfoRow -Label "edge config"          -Value $(if ($configureEdge) { "Baked (Google, no first run, clean new tab)" } else { "Not baked" }) -LabelWidth 24 -IndentWidth 2
        }
        if ($buildHasServer) {
            Write-FastfetchInfoRow -Label "suppress server mgr" -Value $(if ($suppressServerManager) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
        }
        if ($buildHasClient) {
            Write-FastfetchInfoRow -Label "suppress welcome exp" -Value $(if ($suppressWelcome) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
            Write-FastfetchInfoRow -Label "suppress signin anim" -Value $(if ($suppressSignInAnimation) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
            Write-FastfetchInfoRow -Label "auto bitlocker" -Value $(if ($preventDeviceEncryption) { "Prevented" } else { "Left to Windows" }) -LabelWidth 24 -IndentWidth 2
            Write-FastfetchInfoRow -Label "power plan" -Value $(if ($setVmPowerPlan) { "High performance, display/sleep never, no hibernation" } else { "Windows default (Balanced)" }) -LabelWidth 24 -IndentWidth 2
        }
        Write-Host ""
        Write-Studio -Text "  Disk" -Key "fg"
        Write-FastfetchInfoRow -Label "vhdx size" -Value "$vhdSizeGB GB" -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "vhdx type" -Value $vhdType -LabelWidth 24 -IndentWidth 2
        Write-Host ""
        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
        Write-Host ""
    }

    $confirmItems = @(
        [PSCustomObject]@{ Id = "continue"; Label = "Continue - start the build" }
        [PSCustomObject]@{ Id = "cancel";   Label = "Cancel" }
    )
    $decision = Show-Menu -Title "Confirm build settings" -Subtitle "Review everything below, then continue" `
        -Items $confirmItems -SelectedIndex 0 -PreItems $renderSummary
    if ($decision -ne "continue") { return $null }

    return [PSCustomObject]@{
        IsoDrive                     = $isoId
        IsoPath                      = $isoFilePath
        OutputDirectory              = $outputDirectory
        Target                       = $targetId
        ImageIndexes                 = @($selectedIndexes)
        Locale                       = $locale
        KeyboardLayout               = $keyboard
        UiLanguage                   = "Auto"
        TimeZone                     = $timeZone
        VhdSizeGB                    = $vhdSizeGB
        VhdType                      = $vhdType
        WimPath                      = $wimPath
        AvailableImages              = $images
        EnableRdp                    = $enableRdp
        EnablePing                   = $enablePing
        SuppressServerManagerAtLogon = $suppressServerManager
        SuppressWelcomeExperience    = $suppressWelcome
        SuppressFirstSignInAnimation = $suppressSignInAnimation
        BlockSignInInputMethods      = $blockSignIn
        ConfigureEdge                = $configureEdge
        PreventDeviceEncryption      = $preventDeviceEncryption
        SetVmPowerPlan               = $setVmPowerPlan
        MultiSessionImageIndexes     = @($multiSessionIndexes)
        AzureEditionImageIndexes     = @($azureEditionIndexes)
    }
}

# ---------------------------[ Image Download ]---------------------------
#
# Cloud images are fetched by this script rather than by hand, which means a progress
# bar, which on Windows PowerShell 5.1 means NOT using Invoke-WebRequest.
#
# The reason is written down in guest-files\GuestProvision.ps1 as well: IWR repaints
# its Write-Progress bar per chunk and the console I/O dominates, so a large download
# runs many times slower than the link. Setting $ProgressPreference alone fixes the
# speed and leaves no progress at all. 5.1's IWR also has no -Resume and no retry.
#
# So the bytes are moved by hand with HttpWebRequest. Owning the read loop is what
# makes every number on the bar available - bytes, rate, ETA - and it lets the SHA256
# run over the same buffers on the way past, which saves a second pass over a file
# that can be 3 GB.

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

function Invoke-ImageDownload {
    <#
        Downloads one file, draws the bar, and returns the checksum it computed on
        the way past.

        The algorithm is a parameter because the distributions do not agree: Ubuntu
        publishes SHA256SUMS and Debian publishes SHA512SUMS, with no SHA256 listing
        anywhere beside it.

        Writes to <name>.part and renames only after the stream has closed cleanly, so
        an interrupted download can never be mistaken for a finished one - which for a
        gold image input is the failure that actually costs something.

        Returns a PSCustomObject with Path, Bytes, Checksum, Algorithm and Seconds.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$ExpectedChecksum,
        [ValidateSet("SHA256", "SHA512")][string]$Algorithm = "SHA256",
        [int]$BufferSize = 262144
    )

    # .NET Framework 4.x can still negotiate TLS 1.0 by default, and the distribution
    # mirrors are 1.2 or better. Without this the failure is a bare "connection closed"
    # that says nothing about why.
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.SecurityProtocolType]::Tls12 -bor `
            [System.Net.SecurityProtocolType]::Tls11 -bor `
            [System.Net.SecurityProtocolType]::Tls
    }
    catch {
        Write-Log "TLS version unchanged - download may fail" -Tag "Debug"
    }

    $partPath = "$Destination.part"
    if (Test-Path -LiteralPath $partPath) { Remove-Item -LiteralPath $partPath -Force }

    $directory = Split-Path -Path $Destination -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    # The file, not the URL. A mirror URL is three lines of console for one piece of
    # information - which file is being fetched - and the full address is in the log.
    $downloadName = [System.IO.Path]::GetFileName(([System.Uri]$Uri).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($downloadName)) { $downloadName = [string]$Uri }
    Write-Log "Downloading $downloadName" -Tag "Get"

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = "GET"
    # Some mirrors answer a bare .NET user agent with a 403.
    $request.UserAgent = "HyperV-VM-Studio/1.0 (PowerShell)"
    $request.AllowAutoRedirect = $true
    $request.Timeout = 60000
    # .Timeout only covers getting the first response. A mirror that accepts the
    # connection and then goes quiet is caught by this one instead of hanging forever.
    $request.ReadWriteTimeout = 120000

    $response = $null
    $responseStream = $null
    $fileStream = $null
    $sha = $null

    try {
        $response = $request.GetResponse()

        # After redirects, which the Ubuntu 26.04 URL always takes - it answers 302 to
        # the codename path - the length that matters is the one on the FINAL response.
        # A HEAD against the original URL would describe the wrong thing.
        $totalBytes = [int64]$response.ContentLength
        if ($response.ResponseUri.AbsoluteUri -ne $Uri) {
            Write-Log "Redirected to $($response.ResponseUri.AbsoluteUri)" -Tag "Debug"
        }
        if ($totalBytes -gt 0) {
            Write-Log "$(Format-ByteSize -Bytes $totalBytes) to fetch" -Tag "Debug"
        }
        else {
            Write-Log "No content length - progress shows bytes only" -Tag "Debug"
        }

        $responseStream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Open($partPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $sha = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
        if ($null -eq $sha) { throw "No provider for $Algorithm on this host" }

        $buffer = [byte[]]::new($BufferSize)
        $bytesRead = [int64]0
        $clock = [System.Diagnostics.Stopwatch]::StartNew()

        # Redraw on a clock, not per buffer. Repainting per chunk is precisely what
        # makes Invoke-WebRequest slow, and rebuilding that by hand would be a poor joke.
        $lastDraw = [double]0
        $drawEveryMs = 80

        # Rate over a sliding window rather than since the start: a cumulative average
        # keeps quoting a speed the transfer no longer has after a stall.
        $sampleTimes = New-Object System.Collections.ArrayList
        $sampleBytes = New-Object System.Collections.ArrayList
        $windowSeconds = 3.0

        # The bar gets a line to itself, top and bottom - it is the one thing on screen
        # that redraws in place, and it should not look like another log row.
        Write-Host ""
        Write-DownloadProgressLine -BytesRead 0 -TotalBytes $totalBytes -BytesPerSecond 0

        while ($true) {
            $got = $responseStream.Read($buffer, 0, $BufferSize)
            if ($got -le 0) { break }

            $fileStream.Write($buffer, 0, $got)
            # Hash the same bytes on the way past. A second pass with Get-FileHash would
            # mean re-reading up to 3 GB for a number we can have for nothing.
            [void]$sha.TransformBlock($buffer, 0, $got, $null, 0)
            $bytesRead += $got

            $now = $clock.Elapsed.TotalSeconds
            [void]$sampleTimes.Add($now)
            [void]$sampleBytes.Add($bytesRead)
            while ($sampleTimes.Count -gt 2 -and ($now - $sampleTimes[0]) -gt $windowSeconds) {
                $sampleTimes.RemoveAt(0)
                $sampleBytes.RemoveAt(0)
            }

            if ((($now - $lastDraw) * 1000) -ge $drawEveryMs) {
                $lastDraw = $now
                $rate = 0.0
                $span = $now - $sampleTimes[0]
                if ($span -gt 0.2) { $rate = ($bytesRead - $sampleBytes[0]) / $span }
                Write-DownloadProgressLine -BytesRead $bytesRead -TotalBytes $totalBytes -BytesPerSecond $rate
            }
        }

        $clock.Stop()
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $hash = ($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join ""

        $average = 0.0
        if ($clock.Elapsed.TotalSeconds -gt 0) { $average = $bytesRead / $clock.Elapsed.TotalSeconds }
        Write-DownloadProgressLine -BytesRead $bytesRead -TotalBytes $totalBytes -BytesPerSecond $average -Final
        Write-Host ""

        $fileStream.Dispose(); $fileStream = $null

        if ($totalBytes -gt 0 -and $bytesRead -ne $totalBytes) {
            throw "The server promised $totalBytes bytes and sent $bytesRead"
        }

        if (-not [string]::IsNullOrWhiteSpace($ExpectedChecksum)) {
            if ($hash -ne $ExpectedChecksum.Trim().ToLowerInvariant()) {
                throw "$Algorithm mismatch - expected $ExpectedChecksum but the download hashes to $hash"
            }
            # Worth being exact about what this proves: the checksum came over the same
            # TLS connection as the file, from the same mirror. It catches corruption,
            # not a compromised mirror, and must never be logged as a verified signature.
            Write-Log "$Algorithm matches the published checksum" -Tag "ok"
        }

        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
        Move-Item -LiteralPath $partPath -Destination $Destination -Force

        Write-Log "Downloaded $(Format-ByteSize -Bytes $bytesRead) in $(Format-Duration -Seconds $clock.Elapsed.TotalSeconds) ($(Format-ByteSize -Bytes ([int64]$average))/s)" -Tag "ok"

        return [PSCustomObject]@{
            Path      = $Destination
            Bytes     = $bytesRead
            Checksum  = $hash
            Algorithm = $Algorithm
            Seconds   = $clock.Elapsed.TotalSeconds
        }
    }
    finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Close() }
        if ($sha) { $sha.Dispose() }
        # A .part left behind is a failed attempt, and leaving it would let a later run
        # mistake it for something. The finished file has already been renamed by here.
        if (Test-Path -LiteralPath $partPath) { Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------[ Cloud Image Conversion ]---------------------------
#
# Linux golds start life as a cloud image: Ubuntu publishes qcow2, Debian publishes
# both qcow2 and a bare raw. Hyper-V reads neither, and Convert-VHD only converts
# between disk formats it already understands - so the qcow2 has to become a raw
# disk first, and the raw disk has to be given the 512-byte footer that makes it a
# fixed VHD before Convert-VHD will touch it.
#
# Doing that in PowerShell rather than with qemu-img is a deliberate choice. A
# standalone qemu-img.exe does not exist: the current Windows build is a 197 MB
# installer whose qemu-img links about twenty MinGW DLLs, and the only true
# standalone zip is frozen at QEMU 2.3.0 from 2015. On a public repo, "download this
# exe from a third party" is a worse story than a few hundred auditable lines, and
# the decode below runs within a factor of two of qemu-img's own speed anyway.

function Get-BigEndianUInt32 {
    # qcow2 is big-endian throughout. These read from a byte[] rather than a stream
    # because every structure here - the header, the L1 table, an L2 table - is
    # slurped once and then indexed.
    param([byte[]]$Buffer, [int]$Offset)

    return ([uint32]$Buffer[$Offset] * 16777216) + `
           ([uint32]$Buffer[$Offset + 1] * 65536) + `
           ([uint32]$Buffer[$Offset + 2] * 256) + `
           ([uint32]$Buffer[$Offset + 3])
}

function Get-BigEndianInt64 {
    # For header fields whose top bit cannot be set - sizes and offsets. A table
    # entry carries flag bits up there and is read inline in the decode loop, which
    # masks them off first.
    param([byte[]]$Buffer, [int]$Offset)

    $value = [int64]0
    for ($i = 0; $i -lt 8; $i++) {
        $value = ($value * 256) + [int64]$Buffer[$Offset + $i]
    }
    return $value
}

function Set-BigEndianUInt32 {
    param([byte[]]$Buffer, [int]$Offset, [uint32]$Value)

    $Buffer[$Offset]     = [byte](($Value -shr 24) -band 0xFF)
    $Buffer[$Offset + 1] = [byte](($Value -shr 16) -band 0xFF)
    $Buffer[$Offset + 2] = [byte](($Value -shr 8) -band 0xFF)
    $Buffer[$Offset + 3] = [byte]($Value -band 0xFF)
}

function Set-BigEndianInt64 {
    param([byte[]]$Buffer, [int]$Offset, [int64]$Value)

    for ($i = 7; $i -ge 0; $i--) {
        $Buffer[$Offset + $i] = [byte]($Value -band 0xFF)
        $Value = $Value -shr 8
    }
}

function Convert-Qcow2ToRawImage {
    <#
        qcow2 -> raw, in place of qemu-img convert -O raw.

        Scope is the qcow2 the distributions actually publish: version 2 or 3, one
        file, no backing file, no encryption, no snapshots, incompatible_features
        of zero. That last field is the one that matters - it declares external data
        files, extended L2 entries and zstd compression, and Ubuntu's and Debian's
        cloud images have all three off, which is what makes a short decoder
        possible. Every one of those conditions is asserted below rather than
        assumed: an image that breaks one throws instead of producing a disk that is
        quietly wrong.

        Only non-zero clusters are written. The output is created at full virtual
        size and unallocated clusters are left as holes, which on a measured Ubuntu
        26.04 image is 1.4 GiB of the 3.5 GiB that never has to be written at all.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Qcow2Path,
        [Parameter(Mandatory = $true)][string]$RawPath
    )

    $inStream = [System.IO.File]::Open($Qcow2Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $header = [byte[]]::new(104)
        $read = 0
        while ($read -lt 104) {
            $got = $inStream.Read($header, $read, 104 - $read)
            if ($got -le 0) { throw "'$Qcow2Path' is too short to be a qcow2 image" }
            $read += $got
        }

        if ($header[0] -ne 0x51 -or $header[1] -ne 0x46 -or $header[2] -ne 0x49 -or $header[3] -ne 0xFB) {
            throw "'$Qcow2Path' is not a qcow2 image - the magic is not QFI\xfb"
        }

        $version           = Get-BigEndianUInt32 -Buffer $header -Offset 4
        $backingFileOffset = Get-BigEndianInt64  -Buffer $header -Offset 8
        $clusterBits       = Get-BigEndianUInt32 -Buffer $header -Offset 20
        $virtualSize       = Get-BigEndianInt64  -Buffer $header -Offset 24
        $cryptMethod       = Get-BigEndianUInt32 -Buffer $header -Offset 32
        $l1Size            = Get-BigEndianUInt32 -Buffer $header -Offset 36
        $l1TableOffset     = Get-BigEndianInt64  -Buffer $header -Offset 40
        $snapshotCount     = Get-BigEndianUInt32 -Buffer $header -Offset 60

        # Version 2 has no incompatible_features field - its header stops at 72.
        $incompatible = [int64]0
        if ($version -ge 3) { $incompatible = Get-BigEndianInt64 -Buffer $header -Offset 72 }

        if ($version -lt 2 -or $version -gt 3) { throw "Unsupported qcow2 version $version in '$Qcow2Path'" }
        if ($backingFileOffset -ne 0)          { throw "'$Qcow2Path' has a backing file, which is not supported" }
        if ($cryptMethod -ne 0)                { throw "'$Qcow2Path' is encrypted, which is not supported" }
        if ($snapshotCount -ne 0)              { throw "'$Qcow2Path' carries $snapshotCount snapshot(s), which is not supported" }
        if ($incompatible -ne 0)               { throw "'$Qcow2Path' sets incompatible_features = $incompatible (external data file, extended L2 entries or zstd compression) - none of which are supported" }
        if ($clusterBits -lt 9 -or $clusterBits -gt 21) { throw "'$Qcow2Path' has an out-of-range cluster size of 2^$clusterBits bytes" }
        if (($virtualSize % 512) -ne 0)        { throw "'$Qcow2Path' has a virtual size of $virtualSize bytes, which is not a whole number of sectors" }

        $clusterSize = [int]1 -shl [int]$clusterBits
        $l2Entries   = [int]($clusterSize / 8)
        $l2Bits      = [int]$clusterBits - 3

        # Where a compressed cluster's host offset stops and its length begins, per
        # the spec: x = 62 - (cluster_bits - 8), offset in bits 0..x-1 and the
        # 512-byte sector count in the bits above it up to 61.
        $csizeShift = 62 - ([int]$clusterBits - 8)
        $offsetMask = ([int64]1 -shl $csizeShift) - 1
        $csizeMask  = ([int64]1 -shl (62 - $csizeShift)) - 1

        Write-Log "qcow2 v$version - $clusterSize B clusters, $l1Size L1" -Tag "Debug"

        $l1Bytes = [int]$l1Size * 8
        $l1Table = [byte[]]::new($l1Bytes)
        [void]$inStream.Seek($l1TableOffset, [System.IO.SeekOrigin]::Begin)
        $read = 0
        while ($read -lt $l1Bytes) {
            $got = $inStream.Read($l1Table, $read, $l1Bytes - $read)
            if ($got -le 0) { throw "Unexpected end of file reading the L1 table of '$Qcow2Path'" }
            $read += $got
        }

        # Ask NTFS for a sparse file so the holes cost nothing on disk as well as
        # nothing to write - on a measured Ubuntu image that is 1.4 GiB of the 3.5 GiB.
        # It has to happen BEFORE the write handle exists: fsutil opens the file
        # itself, and it cannot while this script holds it unshared. Best effort only,
        # because a volume that will not do it still produces a correct image.
        $created = [System.IO.File]::Create($RawPath)
        $created.Dispose()
        try {
            $null = & fsutil.exe sparse setflag "$RawPath" 2>&1
        }
        catch {
            Write-Log "Sparse flag refused - writing '$RawPath' in full" -Tag "Debug"
        }

        $outStream = [System.IO.File]::Open($RawPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $outStream.SetLength($virtualSize)

            # Two buffers, allocated once. Allocating per cluster is what made an
            # early version of this take six minutes instead of four seconds: on an
            # image with 32813 compressed clusters the allocations and the per-cluster
            # function calls cost far more than the inflate does.
            $plainBuffer = [byte[]]::new($clusterSize)
            $compressedBuffer = [byte[]]::new(([int]$csizeMask + 1) * 512)

            $plainCount = 0; $compressedCount = 0; $zeroCount = 0; $unallocatedCount = 0
            $totalClusters = [int64][Math]::Ceiling($virtualSize / [double]$clusterSize)

            for ($l1Index = 0; $l1Index -lt $l1Size; $l1Index++) {
                $l1At = $l1Index * 8
                $l1Entry = [int64]($l1Table[$l1At] -band 0x3F)
                for ($i = 1; $i -lt 8; $i++) { $l1Entry = ($l1Entry * 256) + [int64]$l1Table[$l1At + $i] }
                $l2Offset = $l1Entry -band 0x00FFFFFFFFFFFE00

                if ($l2Offset -eq 0) {
                    # No L2 table: every guest cluster it would have covered is a hole.
                    $unallocatedCount += $l2Entries
                    continue
                }

                $l2Table = [byte[]]::new($clusterSize)
                [void]$inStream.Seek($l2Offset, [System.IO.SeekOrigin]::Begin)
                $read = 0
                while ($read -lt $clusterSize) {
                    $got = $inStream.Read($l2Table, $read, $clusterSize - $read)
                    if ($got -le 0) { throw "Unexpected end of file reading an L2 table of '$Qcow2Path'" }
                    $read += $got
                }

                for ($l2Index = 0; $l2Index -lt $l2Entries; $l2Index++) {
                    $guestCluster = ([int64]$l1Index -shl $l2Bits) + $l2Index
                    if ($guestCluster -ge $totalClusters) { break }

                    $entryAt = $l2Index * 8
                    $flagByte = $l2Table[$entryAt]

                    # The entry with its two flag bits - 63 copied, 62 compressed -
                    # masked off, so it stays a positive Int64. Read inline rather
                    # than through a function: this runs once per cluster.
                    $entry = [int64]($flagByte -band 0x3F)
                    $entry = ($entry * 4294967296) + `
                             ([int64]$l2Table[$entryAt + 1] * 16777216) + `
                             ([int64]$l2Table[$entryAt + 2] * 65536) + `
                             ([int64]$l2Table[$entryAt + 3] * 256) + `
                             [int64]$l2Table[$entryAt + 4]
                    $entry = ($entry * 16777216) + `
                             ([int64]$l2Table[$entryAt + 5] * 65536) + `
                             ([int64]$l2Table[$entryAt + 6] * 256) + `
                             [int64]$l2Table[$entryAt + 7]

                    # An unallocated entry is eight zero bytes, which after masking is
                    # an entry of zero with no compressed flag.
                    if ($entry -eq 0 -and ($flagByte -band 0x40) -eq 0) { $unallocatedCount++; continue }

                    $guestOffset = $guestCluster * [int64]$clusterSize

                    if (($flagByte -band 0x40) -ne 0) {
                        # Compressed. The run starts mid-sector as often as not, so
                        # its length is the sector-rounded span less that leading slack.
                        $coffset = $entry -band $offsetMask
                        $sectors = (($entry -shr $csizeShift) -band $csizeMask) + 1
                        $csize = [int](($sectors * 512) - ($coffset -band 511))

                        [void]$inStream.Seek($coffset, [System.IO.SeekOrigin]::Begin)
                        $read = 0
                        while ($read -lt $csize) {
                            $got = $inStream.Read($compressedBuffer, $read, $csize - $read)
                            if ($got -le 0) { throw "Unexpected end of file reading a compressed cluster of '$Qcow2Path'" }
                            $read += $got
                        }

                        # The buffer still holds the previous cluster. A deflate run is
                        # allowed to end before it has filled a whole cluster - the rest
                        # is zero - so without this clear, a short one would inherit the
                        # bytes behind it.
                        [array]::Clear($plainBuffer, 0, $clusterSize)

                        # qcow2 compresses with RAW deflate, no zlib header and no
                        # trailer, which is exactly what DeflateStream reads. ZLibStream
                        # is .NET 6 and would be the wrong reader even if it were here.
                        $memory = [System.IO.MemoryStream]::new($compressedBuffer, 0, $csize, $false)
                        $deflate = [System.IO.Compression.DeflateStream]::new($memory, [System.IO.Compression.CompressionMode]::Decompress)
                        try {
                            $filled = 0
                            while ($filled -lt $clusterSize) {
                                $got = $deflate.Read($plainBuffer, $filled, $clusterSize - $filled)
                                if ($got -le 0) { break }
                                $filled += $got
                            }
                        }
                        finally {
                            $deflate.Dispose()
                            $memory.Dispose()
                        }

                        [void]$outStream.Seek($guestOffset, [System.IO.SeekOrigin]::Begin)
                        $outStream.Write($plainBuffer, 0, $clusterSize)
                        $compressedCount++
                        continue
                    }

                    # Version 3 marks a read-as-zero cluster with bit 0. Version 2 has
                    # no such flag, so it is only honoured for v3.
                    if ($version -ge 3 -and ($l2Table[$entryAt + 7] -band 0x01) -ne 0) {
                        $zeroCount++
                        continue
                    }

                    $hostOffset = $entry -band 0x00FFFFFFFFFFFE00
                    if ($hostOffset -eq 0) { $unallocatedCount++; continue }

                    [void]$inStream.Seek($hostOffset, [System.IO.SeekOrigin]::Begin)
                    $read = 0
                    while ($read -lt $clusterSize) {
                        $got = $inStream.Read($plainBuffer, $read, $clusterSize - $read)
                        if ($got -le 0) { throw "Unexpected end of file reading a cluster of '$Qcow2Path'" }
                        $read += $got
                    }
                    [void]$outStream.Seek($guestOffset, [System.IO.SeekOrigin]::Begin)
                    $outStream.Write($plainBuffer, 0, $clusterSize)
                    $plainCount++
                }
            }

            $outStream.Flush()
            Write-Log "Clusters: $compressedCount zip, $plainCount raw, $zeroCount zero, $unallocatedCount gap" -Tag "Debug"
        }
        finally {
            $outStream.Dispose()
        }
    }
    finally {
        $inStream.Dispose()
    }

    return $virtualSize
}

function Get-VhdDiskGeometry {
    # The CHS geometry a VHD footer carries, straight out of the VHD specification's
    # own pseudo-code. It stopped describing real hardware decades ago, but the
    # footer has the field and a parser may check it against the size, so it is
    # calculated rather than invented.
    param([Parameter(Mandatory = $true)][int64]$DiskSize)

    # PowerShell has no integer division operator, and a cast ROUNDS rather than
    # truncates - [int](116508 / 16) is 7282, not 7281. Every division in this
    # function is meant to be integer division, and a geometry that rounds up
    # describes more sectors than the disk has. Subtracting the remainder first
    # makes the division exact, so the cast has nothing left to round.
    $divide = {
        param([int64]$Numerator, [int64]$Denominator)
        return [int64](($Numerator - ($Numerator % $Denominator)) / $Denominator)
    }

    $totalSectors = & $divide $DiskSize 512

    # The format tops out at 65535 x 16 x 255 sectors, a little over 127 GB.
    $maxSectors = [int64]65535 * 16 * 255
    if ($totalSectors -gt $maxSectors) { $totalSectors = $maxSectors }

    if ($totalSectors -ge ([int64]65535 * 16 * 63)) {
        $sectorsPerTrack = 255
        $heads = 16
        $cylinderTimesHeads = & $divide $totalSectors $sectorsPerTrack
    }
    else {
        $sectorsPerTrack = 17
        $cylinderTimesHeads = & $divide $totalSectors $sectorsPerTrack
        $heads = & $divide ($cylinderTimesHeads + 1023) 1024
        if ($heads -lt 4) { $heads = 4 }

        if ($cylinderTimesHeads -ge ($heads * 1024) -or $heads -gt 16) {
            $sectorsPerTrack = 31
            $heads = 16
            $cylinderTimesHeads = & $divide $totalSectors $sectorsPerTrack
        }
        if ($cylinderTimesHeads -ge ($heads * 1024)) {
            $sectorsPerTrack = 63
            $heads = 16
            $cylinderTimesHeads = & $divide $totalSectors $sectorsPerTrack
        }
    }

    return [PSCustomObject]@{
        Cylinders       = [int](& $divide $cylinderTimesHeads $heads)
        Heads           = [int]$heads
        SectorsPerTrack = [int]$sectorsPerTrack
    }
}

function Add-FixedVhdFooter {
    <#
        Appends the 512-byte footer that turns a raw disk image into a fixed VHD,
        which is the one image format Convert-VHD will read that can be produced
        without a Hyper-V API.

        The checksum is the part worth getting right: it is the one's complement of
        the sum of all 512 footer bytes with the checksum field itself zeroed. A
        footer with a wrong checksum is rejected outright, and the error says
        nothing about which field was wrong.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RawPath,
        [Parameter(Mandatory = $true)][int64]$DiskSize
    )

    if (($DiskSize % 512) -ne 0) {
        throw "A VHD must be a whole number of sectors - $DiskSize bytes is not"
    }

    $footer = [byte[]]::new(512)

    [System.Text.Encoding]::ASCII.GetBytes("conectix").CopyTo($footer, 0)
    Set-BigEndianUInt32 -Buffer $footer -Offset 8  -Value ([uint32]2)          # features: the reserved bit, which must be set
    Set-BigEndianUInt32 -Buffer $footer -Offset 12 -Value ([uint32]0x00010000) # file format version 1.0

    # A fixed disk has no dynamic header to point at, and the spec spells that as
    # every bit set rather than zero.
    for ($i = 16; $i -lt 24; $i++) { $footer[$i] = 0xFF }

    # The VHD epoch is 2000-01-01, not 1970.
    $epoch = New-Object System.DateTime(2000, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $stamp = [int64]([System.DateTime]::UtcNow - $epoch).TotalSeconds
    Set-BigEndianUInt32 -Buffer $footer -Offset 24 -Value ([uint32]$stamp)

    [System.Text.Encoding]::ASCII.GetBytes("win ").CopyTo($footer, 28)         # creator application
    Set-BigEndianUInt32 -Buffer $footer -Offset 32 -Value ([uint32]0x000A0000) # creator version 10.0
    [System.Text.Encoding]::ASCII.GetBytes("Wi2k").CopyTo($footer, 36)         # creator host OS: Windows

    Set-BigEndianInt64 -Buffer $footer -Offset 40 -Value $DiskSize             # original size
    Set-BigEndianInt64 -Buffer $footer -Offset 48 -Value $DiskSize             # current size

    $geometry = Get-VhdDiskGeometry -DiskSize $DiskSize
    $footer[56] = [byte](($geometry.Cylinders -shr 8) -band 0xFF)
    $footer[57] = [byte]($geometry.Cylinders -band 0xFF)
    $footer[58] = [byte]$geometry.Heads
    $footer[59] = [byte]$geometry.SectorsPerTrack

    Set-BigEndianUInt32 -Buffer $footer -Offset 60 -Value ([uint32]2)          # disk type: fixed
    (New-Object System.Guid((New-Guid).ToString())).ToByteArray().CopyTo($footer, 68)
    $footer[84] = 0                                                            # not in saved state

    # Checksum last, over the footer as it now stands with bytes 64..67 still zero.
    # 0xFFFFFFFF written as a literal is Int32 -1 in PowerShell, not UInt32
    # 4294967295, and the subtraction then lands somewhere below zero. The mask has
    # to be spelled in decimal to stay unsigned.
    $sum = [uint32]0
    foreach ($byte in $footer) { $sum = [uint32]($sum + $byte) }
    Set-BigEndianUInt32 -Buffer $footer -Offset 64 -Value ([uint32]([uint32]4294967295 - $sum))

    $stream = [System.IO.File]::Open($RawPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        if ($stream.Length -ne $DiskSize) {
            throw "'$RawPath' is $($stream.Length) bytes but the footer declares $DiskSize - refusing to write a footer that does not describe the file"
        }
        [void]$stream.Seek(0, [System.IO.SeekOrigin]::End)
        $stream.Write($footer, 0, 512)
        $stream.Flush()
    }
    finally {
        $stream.Dispose()
    }

    Write-Log "VHD footer: $DiskSize bytes, CHS $($geometry.Cylinders)/$($geometry.Heads)/$($geometry.SectorsPerTrack)" -Tag "Debug"
}

# ---------------------------[ Linux Golds ]---------------------------
#
# A Linux gold is built from a distribution cloud image rather than from installation
# media: there is no unattended setup to run, because a cloud image is already
# installed. What it needs instead is a format conversion and, later, one boot with a
# cloud-init seed attached.
#
# The images used here are the GENERIC ones, not the vendor's azure builds. Ubuntu
# only publishes an azure variant for 24.04, and that variant pins cloud-init to the
# Azure datasource, which would mean provisioning through an ovf-env.xml and a wire
# server this lab does not have. The generic route costs a decode and a bake boot and
# buys every release, Debian as well, and one seed format for all of them.

function Get-LinuxImageCatalog {
    <#
        One entry per gold this script can build.

        The three distributions do not publish alike and the catalog says so rather
        than pretending they do: Ubuntu republishes a release directory in place,
        while Debian cuts dated snapshots and keeps a `latest/` alias beside them.
        The download URL is therefore per-entry, never a template with the version
        substituted in.

        DiskGB is what the gold - and so every VM differencing off it - will be. The
        cloud images themselves are 3 GiB or so and grow on first boot; the number
        here is the size the disk is expanded to before that ever happens.
    #>

    return @(
        [PSCustomObject]@{
            Id            = "ubuntu-2604"
            Name          = "Ubuntu 26.04 LTS (Resolute)"
            ImageId       = "ubuntu2604"
            Distro        = "ubuntu"
            Version       = "26.04"
            Url           = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
            ChecksumUrl   = "https://cloud-images.ubuntu.com/releases/26.04/release/SHA256SUMS"
            Algorithm     = "SHA256"
            SourceFormat  = "qcow2"
            DefaultDiskGB = 32
            # Ubuntu's cloud image carries grub-efi-amd64-signed AND grub-pc, so it
            # boots either generation. Gen2 is the default anyway.
            Generation    = 2
            BakePackages  = @("linux-azure", "linux-cloud-tools-azure")
        }
        [PSCustomObject]@{
            Id            = "ubuntu-2404"
            Name          = "Ubuntu 24.04 LTS (Noble)"
            ImageId       = "ubuntu2404"
            Distro        = "ubuntu"
            Version       = "24.04"
            Url           = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
            ChecksumUrl   = "https://cloud-images.ubuntu.com/releases/24.04/release/SHA256SUMS"
            Algorithm     = "SHA256"
            SourceFormat  = "qcow2"
            DefaultDiskGB = 32
            Generation    = 2
            BakePackages  = @("linux-azure", "linux-cloud-tools-azure")
        }
        [PSCustomObject]@{
            Id            = "debian-13"
            Name          = "Debian 13 (Trixie)"
            ImageId       = "debian13"
            Distro        = "debian"
            Version       = "13"
            # genericcloud, NOT the variant Debian calls `nocloud`. That one contains no
            # cloud-init at all and boots to a passwordless root console - a pure naming
            # collision with cloud-init's NoCloud datasource, which is what we do use.
            Url           = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
            # Debian publishes SHA512SUMS and no SHA256SUMS, and no signature beside
            # either - checked again on 2026-09-21.
            ChecksumUrl   = "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
            Algorithm     = "SHA512"
            SourceFormat  = "qcow2"
            DefaultDiskGB = 32
            # Debian ships no grub-pc in ANY trixie cloud variant, so it is UEFI only.
            Generation    = 2
            # hyperv-daemons for the integration services, and the keyboard machinery
            # because Debian's genericcloud image ships NONE of it - no kbd, no
            # console-setup, no keyboard-configuration - so cloud-init's keyboard module
            # has nothing to work with and the keymap silently does nothing. Ubuntu's
            # image already carries all three.
            BakePackages  = @("hyperv-daemons", "kbd", "console-setup", "keyboard-configuration")
        }
    )
}

function Get-WebText {
    # For the small text files beside an image - a SHA256SUMS is a few kilobytes. The
    # image itself goes through Invoke-ImageDownload, which draws a bar; drawing one
    # for four kilobytes would be silly.
    param([Parameter(Mandatory = $true)][string]$Uri)

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.SecurityProtocolType]::Tls12 -bor `
            [System.Net.SecurityProtocolType]::Tls11 -bor `
            [System.Net.SecurityProtocolType]::Tls
    }
    catch { }

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = "GET"
    $request.UserAgent = "HyperV-VM-Studio/1.0 (PowerShell)"
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000

    $response = $null
    $reader = $null
    try {
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        return $reader.ReadToEnd()
    }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Close() }
    }
}

function Get-PublishedChecksum {
    <#
        Pulls one file's checksum out of a SHA256SUMS / SHA512SUMS listing.

        Returns an empty string when the listing cannot be fetched or the file is not
        in it. That is not fatal on purpose: a mirror being briefly unreachable should
        not stop a build, it should mean the download is unverified and says so.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ChecksumUrl,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    try {
        $text = Get-WebText -Uri $ChecksumUrl
    }
    catch {
        Write-Log "Could not fetch '$ChecksumUrl': $($_.Exception.Message)" -Tag "Warn"
        return ""
    }

    foreach ($line in ($text -split "`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        # "<hash> *<name>" or "<hash>  <name>" - the star marks binary mode and is not
        # part of the name.
        $parts = $trimmed -split "\s+", 2
        if ($parts.Count -lt 2) { continue }
        $name = $parts[1].TrimStart("*").Trim()
        if ($name -eq $FileName) { return $parts[0].Trim().ToLowerInvariant() }
    }

    Write-Log "'$FileName' is not listed in $ChecksumUrl" -Tag "Warn"
    return ""
}

function Get-CachedLinuxImage {
    <#
        Returns the path to a usable copy of the image, downloading it only when there
        is not one already. A cached file counts as usable when it hashes to the
        published checksum; with no published checksum to compare against, a cached
        file is re-used on the strength of its existence and the run says so.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$CacheDirectory
    )

    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        Write-Log "Creating image cache directory '$CacheDirectory'" -Tag "Run"
        New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
    }

    $fileName = [System.IO.Path]::GetFileName(([System.Uri]$Entry.Url).AbsolutePath)
    $imagePath = Join-Path -Path $CacheDirectory -ChildPath $fileName

    Write-Log "Published checksum for $fileName" -Tag "Get"
    $expected = Get-PublishedChecksum -ChecksumUrl $Entry.ChecksumUrl -FileName $fileName

    if (Test-Path -LiteralPath $imagePath) {
        if ([string]::IsNullOrWhiteSpace($expected)) {
            Write-Log "Re-using the cached '$fileName' - there is no published checksum to check it against" -Tag "Warn"
            return $imagePath
        }
        Write-Log "Hashing cached '$fileName'" -Tag "Run"
        $actual = (Get-FileHash -LiteralPath $imagePath -Algorithm $Entry.Algorithm).Hash.ToLowerInvariant()
        if ($actual -eq $expected) {
            Write-Log "Cached '$fileName' is current - reusing" -Tag "ok"
            return $imagePath
        }
        # Debian re-cuts its images a few times a month and `latest/` moves with them,
        # so a stale cache is expected rather than suspicious.
        Write-Log "Cached '$fileName' is stale - fetching" -Tag "Info"
    }

    $null = Invoke-ImageDownload -Uri $Entry.Url -Destination $imagePath `
        -ExpectedChecksum $expected -Algorithm $Entry.Algorithm
    return $imagePath
}

function Write-LinuxGoldManifest {
    # The Linux counterpart to Write-GoldImageManifest. Build-Vms.ps1 reads the sidecar
    # beside a gold to learn what it is; for a Linux gold the decisive field is
    # osFamily, which is what tells the builder not to go looking for a language slug
    # in the file name or an unattend.xml to write into the disk.
    param(
        [Parameter(Mandatory = $true)][string]$VhdPath,
        [Parameter(Mandatory = $true)][object]$Entry,
        [string]$Target = "HyperV",
        [string]$Language,
        [string]$Locale,
        [string]$KeyboardLayout,
        [string]$TimeZone,
        [string]$VhdType,
        [string]$SourceChecksum
    )

    if ($Target -eq "AzureLocal") {
        # Same rule as Write-GoldImageManifest: Build-Vms.ps1 reads the sidecar beside a
        # gold it picked, and it only ever picks hv-*. An azl- gold has no reader, so a
        # manifest there would imply a consumer that does not exist.
        Write-Log "Azure Local gold - no sidecar manifest" -Tag "Info"
        return $true
    }

    $manifestPath = "$VhdPath.json"
    $manifest = [ordered]@{
        osFamily       = "linux"
        distro         = $Entry.Distro
        distroVersion  = $Entry.Version
        imageName      = $Entry.Name
        target         = $Target
        generation     = $Entry.Generation
        vhdType        = $VhdType
        # language and locale are SEPARATE on Linux: language becomes LANG, locale
        # becomes the LC_* format family. A reader that conflates them gets German
        # error messages it did not ask for.
        language       = $Language
        locale         = $Locale
        keyboardLayout = $KeyboardLayout
        timeZone       = $TimeZone
        localeMode     = "cloud-init"
        sourceUrl      = $Entry.Url
        sourceFormat   = $Entry.SourceFormat
        sourceChecksum = $SourceChecksum
        checksumAlgorithm = $Entry.Algorithm
        createdUtc     = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    try {
        $json = $manifest | ConvertTo-Json
        [System.IO.File]::WriteAllText($manifestPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "Wrote gold image manifest '$manifestPath'" -Tag "Info"
        return $true
    }
    catch {
        Write-Log "Failed to write gold image manifest '$manifestPath': $($_.Exception.Message)" -Tag "Error"
        return $false
    }
}

function New-LinuxGoldImage {
    <#
        cloud image -> gold VHDX.

        Four steps, and the middle two are the ones that do not exist anywhere else in
        this project: decode the qcow2 to a raw disk, give the raw disk a fixed-VHD
        footer, hand the result to Convert-VHD, then grow it.

        Convert-VHD reads a fixed VHD and writes a dynamic VHDX, which is why the
        footer is worth the trouble - it is the one image format that can be produced
        from PowerShell alone and that Hyper-V will then take seriously.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [Parameter(Mandatory = $true)][int]$DiskSizeGB,
        [ValidateSet("Dynamic", "Fixed")][string]$VhdType = "Dynamic",
        [string]$GoldName,
        [string]$WorkDirectory
    )

    # The caller always names the gold now, because the name carries the language and
    # only the caller knows it. The bare imageId is a last resort, not a default.
    if ([string]::IsNullOrWhiteSpace($GoldName)) { $GoldName = [string]$Entry.ImageId }

    if ([string]::IsNullOrWhiteSpace($WorkDirectory)) { $WorkDirectory = $OutputDirectory }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $vhdxPath = Join-Path -Path $OutputDirectory -ChildPath ("{0}.vhdx" -f $GoldName)
    $intermediateVhd = Join-Path -Path $WorkDirectory -ChildPath ("{0}.tmp.vhd" -f $GoldName)

    if (Test-Path -LiteralPath $vhdxPath) {
        Write-Log "Replacing the existing gold '$vhdxPath'" -Tag "Info"
        Remove-Item -LiteralPath $vhdxPath -Force
    }
    if (Test-Path -LiteralPath $intermediateVhd) { Remove-Item -LiteralPath $intermediateVhd -Force }

    try {
        if ($Entry.SourceFormat -eq "qcow2") {
            Write-Log "Decoding $($Entry.SourceFormat) to a raw disk" -Tag "Run"
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $virtualSize = Convert-Qcow2ToRawImage -Qcow2Path $ImagePath -RawPath $intermediateVhd
            $clock.Stop()
            Write-Log "Decoded $(Format-ByteSize -Bytes $virtualSize) in $(Format-Duration -Seconds $clock.Elapsed.TotalSeconds)" -Tag "ok"
        }
        else {
            # Debian also publishes a bare .raw. Nothing to decode - it only needs the
            # footer, so it takes the same path from here on.
            Write-Log "Copying the raw disk image" -Tag "Run"
            Copy-FileWithProgress -Source $ImagePath -Destination $intermediateVhd -Activity "copying image"
            $virtualSize = (Get-Item -LiteralPath $intermediateVhd).Length
        }

        Add-FixedVhdFooter -RawPath $intermediateVhd -DiskSize $virtualSize

        # Fixed writes the whole file out here rather than growing on demand, so this
        # step and the resize below are both slower and land the full size on disk.
        Write-Log "Converting to a $($VhdType.ToLowerInvariant()) VHDX" -Tag "Run"
        Convert-VHD -Path $intermediateVhd -DestinationPath $vhdxPath -VHDType $VhdType -ErrorAction Stop

        $targetBytes = [int64]$DiskSizeGB * 1GB
        if ($targetBytes -gt $virtualSize) {
            Write-Log "Growing the gold to $DiskSizeGB GB" -Tag "Run"
            # Only the disk grows here. The partition and the filesystem inside it are
            # grown by the guest on first boot - cloud-init's growpart and resizefs,
            # which every one of these images ships with enabled.
            Resize-VHD -Path $vhdxPath -SizeBytes $targetBytes -ErrorAction Stop
        }
        else {
            Write-Log "The image is already $(Format-ByteSize -Bytes $virtualSize) - not shrinking it to $DiskSizeGB GB" -Tag "Warn"
        }

        Write-Log "Built '$vhdxPath'" -Tag "ok"
        return $vhdxPath
    }
    finally {
        if (Test-Path -LiteralPath $intermediateVhd) {
            Remove-Item -LiteralPath $intermediateVhd -Force -ErrorAction SilentlyContinue
        }
    }
}

function Import-LinuxTimeZoneCatalog {
    <#
        The IANA zone list, from data\linux-timezones.json.

        It is a separate catalog from the Windows one on purpose. Windows names a zone
        "W. Europe Standard Time"; cloud-init wants "Europe/Berlin", and the two are
        not mechanically convertible on this host - TimeZoneInfo.TryConvertWindowsIdToIanaId
        is .NET 6 and up, so Windows PowerShell 5.1 cannot do it. The alternative was
        shipping a CLDR windowsZones mapping of some 450 rows; a native list is smaller,
        exact, and never goes stale against a Windows ID that was renamed.

        The cost, stated: an IANA list carries no offsets, so it sorts by region and
        city rather than by UTC offset the way the Windows picker does.
    #>
    if ($script:LinuxTimeZones -and $script:LinuxTimeZones.Count -gt 0) { return }

    $script:LinuxTimeZones = @()
    $catalogPath = Join-Path -Path $PSScriptRoot -ChildPath "data\linux-timezones.json"

    if (-not (Test-Path -LiteralPath $catalogPath)) {
        Write-Log "No data\linux-timezones.json - falling back to UTC only" -Tag "Warn"
        $script:LinuxTimeZones = @([PSCustomObject]@{ Id = "UTC"; Label = "UTC" })
        return
    }

    try {
        $doc = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Log "data\linux-timezones.json is not valid JSON ($($_.Exception.Message)) - falling back to UTC only" -Tag "Warn"
        $script:LinuxTimeZones = @([PSCustomObject]@{ Id = "UTC"; Label = "UTC" })
        return
    }

    $zones = @()
    foreach ($zone in @($doc.zones)) {
        $offset = [int]$zone.offsetMinutes
        $sign = "+"
        if ($offset -lt 0) { $sign = "-"; $offset = -$offset }
        # [Math]::Floor, not a cast: [int](330 / 60) is 6, because a PowerShell cast
        # rounds. India would read UTC+06:30 instead of +05:30, and every half-hour and
        # three-quarter-hour zone with it.
        $label = "{0,-32} UTC{1}{2:00}:{3:00}" -f $zone.id, $sign, [int][Math]::Floor($offset / 60), ($offset % 60)
        $zones += [PSCustomObject]@{
            Id        = [string]$zone.id
            Label     = $label
            Countries = @($zone.countries)
        }
    }

    $script:LinuxTimeZones = @($zones)
    Write-Log "Loaded $($zones.Count) IANA time zones" -Tag "Debug"
}

function Get-LinuxGoldFeatureCatalog {
    <#
        The Linux half of the optional features picker, and the same idea as the Windows
        one next door: decisions baked into the gold once, rather than repeated per VM.

        Nothing here installs a package. Every entry is a file the bake writes or a line
        it edits, so none of them need a mirror to be reachable - which matters, because
        a feature that only works when apt does is a feature that fails on the day the
        network is the problem.

        Ubuntu-only entries carry Distro; the picker leaves them out for Debian rather
        than offering a tick that would do nothing.
    #>

    return @(
        [PSCustomObject]@{
            Id        = "aliases"
            Label     = "Shell aliases (ll, la, l, cls, .., cd.., colour ls/grep)"
            DefaultOn = $true
            Distro    = ""
        }
        [PSCustomObject]@{
            # Off by default: both images ship it commented out, and a gold should not
            # quietly disagree with the distribution about how a shell looks. Still on
            # the list for anyone who wants it - it is one tick.
            Id        = "colorprompt"
            Label     = "Colour prompt (force_color_prompt)"
            DefaultOn = $false
            Distro    = ""
        }
        [PSCustomObject]@{
            # Measured, not assumed: /etc/default/motd-news ships ENABLED=1 with
            # URLS="https://motd.ubuntu.com" and WAIT=5, so every login on an isolated
            # network waits up to five seconds on a fetch that cannot succeed. The
            # adverts beside it are the Pro/ESM contract line, landscape sysinfo, the
            # updates-available count and the HWE end-of-life notice.
            # Off by default like the colour prompt: it edits files the distribution
            # ships and disables scripts it installed, which is a decision to take on
            # purpose rather than to inherit. The five-second login stall is the reason
            # to take it, and it is one tick away.
            Id        = "quietmotd"
            Label     = "Quiet the login banner (no motd-news fetch, no Pro/ESM adverts)"
            DefaultOn = $false
            Distro    = "ubuntu"
        }
    )
}

function Get-LinuxGoldName {
    <#
        The gold's file name: <hv|azl>-<language>-<imageId>, which is the SAME three
        segments Get-VhdxFileName builds for Windows - hv-enus-ubuntu2604 beside
        hv-dede-ws2025-datacenter-core.

        That is not cosmetic. Get-GoldNameParts in Build-Vms.ps1 parses exactly this
        shape, so a Linux gold is resolved by the ordinary imageId lookup and takes part
        in language selection like any other: two golds of one distribution in two
        languages can sit in the folder and be told apart.
    #>
    param([object]$Entry, [string]$Target, [string]$Language)

    $prefix = "azl"
    if ($Target -ne "AzureLocal") { $prefix = "hv" }
    $slug = Get-LanguageSlug -ImageLanguage $Language
    return ("{0}-{1}-{2}" -f $prefix, $slug, $Entry.ImageId).ToLowerInvariant()
}

function Get-AptMirrorCatalog {
    <#
        Country mirrors for the bake, because the stock cloud image points at
        archive.ubuntu.com / deb.debian.org and a badly routed one turns a five minute
        kernel install into a long wait.

        Ubuntu and Debian do NOT use the same host names, and neither has a mirror
        everywhere. Every entry below was probed on 2026-09-22 and only the ones that
        answered are listed; a blank means that distribution has no country mirror there
        and the run falls back to the distribution's own default, which is correct
        rather than broken.

        The pair worth remembering: the United Kingdom is `gb.archive.ubuntu.com` on
        Ubuntu and `ftp.uk.debian.org` on Debian. Ubuntu has nothing usable for Denmark
        or Portugal, and Debian has nothing for India, South Africa, Latvia, Argentina,
        Indonesia, Vietnam or Israel.
    #>

    return @(
        [PSCustomObject]@{ Code = "ar"; Name = "Argentina"; Ubuntu = "ar.archive.ubuntu.com"; Debian = "" }
        [PSCustomObject]@{ Code = "au"; Name = "Australia"; Ubuntu = "au.archive.ubuntu.com"; Debian = "ftp.au.debian.org" }
        [PSCustomObject]@{ Code = "at"; Name = "Austria"; Ubuntu = "at.archive.ubuntu.com"; Debian = "ftp.at.debian.org" }
        [PSCustomObject]@{ Code = "be"; Name = "Belgium"; Ubuntu = "be.archive.ubuntu.com"; Debian = "ftp.be.debian.org" }
        [PSCustomObject]@{ Code = "br"; Name = "Brazil"; Ubuntu = "br.archive.ubuntu.com"; Debian = "ftp.br.debian.org" }
        [PSCustomObject]@{ Code = "bg"; Name = "Bulgaria"; Ubuntu = "bg.archive.ubuntu.com"; Debian = "ftp.bg.debian.org" }
        [PSCustomObject]@{ Code = "ca"; Name = "Canada"; Ubuntu = "ca.archive.ubuntu.com"; Debian = "ftp.ca.debian.org" }
        [PSCustomObject]@{ Code = "cl"; Name = "Chile"; Ubuntu = "cl.archive.ubuntu.com"; Debian = "ftp.cl.debian.org" }
        [PSCustomObject]@{ Code = "cn"; Name = "China"; Ubuntu = "cn.archive.ubuntu.com"; Debian = "ftp.cn.debian.org" }
        [PSCustomObject]@{ Code = "hr"; Name = "Croatia"; Ubuntu = "hr.archive.ubuntu.com"; Debian = "ftp.hr.debian.org" }
        [PSCustomObject]@{ Code = "cz"; Name = "Czechia"; Ubuntu = "cz.archive.ubuntu.com"; Debian = "ftp.cz.debian.org" }
        [PSCustomObject]@{ Code = "dk"; Name = "Denmark"; Ubuntu = ""; Debian = "ftp.dk.debian.org" }
        [PSCustomObject]@{ Code = "ee"; Name = "Estonia"; Ubuntu = "ee.archive.ubuntu.com"; Debian = "ftp.ee.debian.org" }
        [PSCustomObject]@{ Code = "fi"; Name = "Finland"; Ubuntu = "fi.archive.ubuntu.com"; Debian = "ftp.fi.debian.org" }
        [PSCustomObject]@{ Code = "fr"; Name = "France"; Ubuntu = "fr.archive.ubuntu.com"; Debian = "ftp.fr.debian.org" }
        [PSCustomObject]@{ Code = "de"; Name = "Germany"; Ubuntu = "de.archive.ubuntu.com"; Debian = "ftp.de.debian.org" }
        [PSCustomObject]@{ Code = "gr"; Name = "Greece"; Ubuntu = "gr.archive.ubuntu.com"; Debian = "ftp.gr.debian.org" }
        [PSCustomObject]@{ Code = "hk"; Name = "Hong Kong"; Ubuntu = "hk.archive.ubuntu.com"; Debian = "ftp.hk.debian.org" }
        [PSCustomObject]@{ Code = "hu"; Name = "Hungary"; Ubuntu = "hu.archive.ubuntu.com"; Debian = "ftp.hu.debian.org" }
        [PSCustomObject]@{ Code = "is"; Name = "Iceland"; Ubuntu = "is.archive.ubuntu.com"; Debian = "ftp.is.debian.org" }
        [PSCustomObject]@{ Code = "in"; Name = "India"; Ubuntu = "in.archive.ubuntu.com"; Debian = "" }
        [PSCustomObject]@{ Code = "id"; Name = "Indonesia"; Ubuntu = "id.archive.ubuntu.com"; Debian = "" }
        [PSCustomObject]@{ Code = "ie"; Name = "Ireland"; Ubuntu = "ie.archive.ubuntu.com"; Debian = "ftp.ie.debian.org" }
        [PSCustomObject]@{ Code = "il"; Name = "Israel"; Ubuntu = "il.archive.ubuntu.com"; Debian = "" }
        [PSCustomObject]@{ Code = "it"; Name = "Italy"; Ubuntu = "it.archive.ubuntu.com"; Debian = "ftp.it.debian.org" }
        [PSCustomObject]@{ Code = "jp"; Name = "Japan"; Ubuntu = "jp.archive.ubuntu.com"; Debian = "ftp.jp.debian.org" }
        [PSCustomObject]@{ Code = "lv"; Name = "Latvia"; Ubuntu = "lv.archive.ubuntu.com"; Debian = "" }
        [PSCustomObject]@{ Code = "lt"; Name = "Lithuania"; Ubuntu = "lt.archive.ubuntu.com"; Debian = "ftp.lt.debian.org" }
        [PSCustomObject]@{ Code = "mx"; Name = "Mexico"; Ubuntu = "mx.archive.ubuntu.com"; Debian = "ftp.mx.debian.org" }
        [PSCustomObject]@{ Code = "nl"; Name = "Netherlands"; Ubuntu = "nl.archive.ubuntu.com"; Debian = "ftp.nl.debian.org" }
        [PSCustomObject]@{ Code = "nz"; Name = "New Zealand"; Ubuntu = "nz.archive.ubuntu.com"; Debian = "ftp.nz.debian.org" }
        [PSCustomObject]@{ Code = "no"; Name = "Norway"; Ubuntu = "no.archive.ubuntu.com"; Debian = "ftp.no.debian.org" }
        [PSCustomObject]@{ Code = "pl"; Name = "Poland"; Ubuntu = "pl.archive.ubuntu.com"; Debian = "ftp.pl.debian.org" }
        [PSCustomObject]@{ Code = "pt"; Name = "Portugal"; Ubuntu = ""; Debian = "ftp.pt.debian.org" }
        [PSCustomObject]@{ Code = "ro"; Name = "Romania"; Ubuntu = "ro.archive.ubuntu.com"; Debian = "ftp.ro.debian.org" }
        [PSCustomObject]@{ Code = "ru"; Name = "Russia"; Ubuntu = "ru.archive.ubuntu.com"; Debian = "ftp.ru.debian.org" }
        [PSCustomObject]@{ Code = "sg"; Name = "Singapore"; Ubuntu = "sg.archive.ubuntu.com"; Debian = "ftp.sg.debian.org" }
        [PSCustomObject]@{ Code = "sk"; Name = "Slovakia"; Ubuntu = "sk.archive.ubuntu.com"; Debian = "ftp.sk.debian.org" }
        [PSCustomObject]@{ Code = "si"; Name = "Slovenia"; Ubuntu = "si.archive.ubuntu.com"; Debian = "ftp.si.debian.org" }
        [PSCustomObject]@{ Code = "za"; Name = "South Africa"; Ubuntu = "za.archive.ubuntu.com"; Debian = "" }
        [PSCustomObject]@{ Code = "kr"; Name = "South Korea"; Ubuntu = "kr.archive.ubuntu.com"; Debian = "ftp.kr.debian.org" }
        [PSCustomObject]@{ Code = "es"; Name = "Spain"; Ubuntu = "es.archive.ubuntu.com"; Debian = "ftp.es.debian.org" }
        [PSCustomObject]@{ Code = "se"; Name = "Sweden"; Ubuntu = "se.archive.ubuntu.com"; Debian = "ftp.se.debian.org" }
        [PSCustomObject]@{ Code = "ch"; Name = "Switzerland"; Ubuntu = "ch.archive.ubuntu.com"; Debian = "ftp.ch.debian.org" }
        [PSCustomObject]@{ Code = "tw"; Name = "Taiwan"; Ubuntu = "tw.archive.ubuntu.com"; Debian = "ftp.tw.debian.org" }
        [PSCustomObject]@{ Code = "th"; Name = "Thailand"; Ubuntu = "th.archive.ubuntu.com"; Debian = "ftp.th.debian.org" }
        [PSCustomObject]@{ Code = "tr"; Name = "Turkey"; Ubuntu = "tr.archive.ubuntu.com"; Debian = "ftp.tr.debian.org" }
        [PSCustomObject]@{ Code = "ua"; Name = "Ukraine"; Ubuntu = "ua.archive.ubuntu.com"; Debian = "ftp.ua.debian.org" }
        [PSCustomObject]@{ Code = "gb"; Name = "United Kingdom"; Ubuntu = "gb.archive.ubuntu.com"; Debian = "ftp.uk.debian.org" }
        [PSCustomObject]@{ Code = "us"; Name = "United States"; Ubuntu = "us.archive.ubuntu.com"; Debian = "ftp.us.debian.org" }
        [PSCustomObject]@{ Code = "vn"; Name = "Vietnam"; Ubuntu = "vn.archive.ubuntu.com"; Debian = "" }
    )
}

function Get-AptMirrorUri {
    <#
        The apt URI for a distribution in a region, or an empty string when there is no
        mirror for that pair - which is the signal to leave the image's own default
        alone rather than to invent a host name that does not resolve.
    #>
    param([object]$Entry, [string]$RegionCode)

    if ($null -eq $Entry) { return "" }
    if ([string]::IsNullOrWhiteSpace($RegionCode) -or $RegionCode -eq "default") { return "" }

    $region = @(Get-AptMirrorCatalog) | Where-Object { $_.Code -eq $RegionCode } | Select-Object -First 1
    if ($null -eq $region) { return "" }

    if ($Entry.Distro -eq "ubuntu") {
        if ([string]::IsNullOrWhiteSpace($region.Ubuntu)) { return "" }
        return "http://$($region.Ubuntu)/ubuntu/"
    }
    if ($Entry.Distro -eq "debian") {
        if ([string]::IsNullOrWhiteSpace($region.Debian)) { return "" }
        return "http://$($region.Debian)/debian/"
    }
    return ""
}

function Get-UbuntuLanguagePack {
    # language-pack-de for de-DE, and nothing at all for English or for Debian. Returns
    # an empty string when no package is needed.
    param([object]$Entry, [string]$LanguageTag)

    if ($null -eq $Entry -or $Entry.Distro -ne "ubuntu") { return "" }
    if ([string]::IsNullOrWhiteSpace($LanguageTag)) { return "" }

    $language = ($LanguageTag -split "-")[0].ToLowerInvariant()
    # en is already there: the image is built in English.
    if ($language -eq "en") { return "" }
    return "language-pack-$language"
}

function Get-DefaultLinuxTimeZone {
    <#
        The zone a picker should open on, worked out from the regional format's own
        country - de-DE opens on Europe/Berlin, en-GB on Europe/London.

        zone1970.tab lists the countries each zone covers and puts the zone's PRIMARY
        country first, which is the whole reason the catalog keeps that array: Europe/Berlin
        covers DE first, while Europe/Zurich also lists DE further down. Matching the
        first entry gets the country's own zone rather than a neighbour's.

        Returns an empty string when nothing matches, and the caller falls back.
    #>
    param([string]$LocaleTag)

    if ([string]::IsNullOrWhiteSpace($LocaleTag)) { return "" }
    $parts = $LocaleTag -split "-"
    if ($parts.Count -lt 2) { return "" }
    $country = $parts[$parts.Count - 1].ToUpperInvariant()

    # A country with several zones is listed alphabetically, which makes the United
    # States open on America/Adak - a handful of Aleutian islands - and Brazil on
    # America/Araguaina. Neither is a defensible default, and the file carries nothing
    # that says which zone a country mostly lives in, so the big ones are named here.
    $primary = @{
        "US" = "America/New_York";  "BR" = "America/Sao_Paulo";  "CA" = "America/Toronto"
        "AU" = "Australia/Sydney";  "RU" = "Europe/Moscow";      "CN" = "Asia/Shanghai"
        "MX" = "America/Mexico_City"; "ES" = "Europe/Madrid";    "PT" = "Europe/Lisbon"
        "ID" = "Asia/Jakarta";      "AR" = "America/Argentina/Buenos_Aires"
        "CL" = "America/Santiago";  "NZ" = "Pacific/Auckland";   "KZ" = "Asia/Almaty"
        "UA" = "Europe/Kyiv";       "CD" = "Africa/Kinshasa";    "PF" = "Pacific/Tahiti"
    }
    if ($primary.ContainsKey($country)) {
        $named = $primary[$country]
        foreach ($zone in @($script:LinuxTimeZones)) {
            if ([string]$zone.Id -eq $named) { return $named }
        }
    }

    foreach ($zone in @($script:LinuxTimeZones)) {
        if (@($zone.Countries).Count -gt 0 -and [string]$zone.Countries[0] -eq $country) { return [string]$zone.Id }
    }
    # Nothing has this country as its primary - take any zone that covers it at all.
    foreach ($zone in @($script:LinuxTimeZones)) {
        if (@($zone.Countries) -contains $country) { return [string]$zone.Id }
    }
    return ""
}

function Get-LinuxLocaleName {
    # de-DE -> de_DE.UTF-8. The locale catalog is keyed by the Windows tag, and glibc
    # spells the same thing with an underscore and an explicit charset.
    param([string]$LocaleTag)

    if ([string]::IsNullOrWhiteSpace($LocaleTag)) { return "en_US.UTF-8" }
    return ($LocaleTag -replace "-", "_") + ".UTF-8"
}

function Get-LinuxKeymap {
    <#
        de-DE -> de, en-GB -> gb, en-US -> us.

        A console keymap is named after the LAYOUT, which usually - not always -
        matches the region half of the tag lowercased. The exceptions that matter are
        listed; anything not listed falls back to the region half, and a wrong keymap
        is a cosmetic problem on a machine reached over SSH.
    #>
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

function Get-BakeUserData {
    <#
        The bake boot's cloud-config.

        This is where a generic cloud image gets what the vendor's azure image would
        have come with: the azure kernel on Ubuntu, hyperv-daemons on Debian. Then it
        erases its own first-boot identity - cloud-init state, machine-id, SSH host keys
        - so that every VM cloned from this gold generates its own rather than sharing
        the gold's. That is the Linux half of what sysprep /generalize does for Windows.

        walinuxagent is deliberately NOT installed. That package is what pins cloud-init
        to the Azure datasource, and the whole point of the generic route is to keep
        NoCloud working.

        BAKE-OK is the sentinel the host greps the serial console for. It is echoed only
        after the installs have returned, so its absence means the bake did not finish -
        which is the difference between shipping a gold and shipping a broken one.
    #>
    param(
        [object]$Entry,
        [bool]$ApplyUpdates,
        [string[]]$ExtraPackages,
        [string]$MirrorUri,
        [string[]]$Features = @()
    )

    $wantAliases = (@($Features) -contains "aliases")
    $wantColorPrompt = (@($Features) -contains "colorprompt")
    $wantQuietMotd = (@($Features) -contains "quietmotd")

    $packages = @()
    foreach ($package in @($Entry.BakePackages)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$package)) { $packages += [string]$package }
    }
    foreach ($package in @($ExtraPackages)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$package)) { $packages += ([string]$package).Trim() }
    }
    $packages = @($packages | Select-Object -Unique)

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("#cloud-config")
    # A console login, purely so a bake that stalls can be looked at. The first run that
    # hung sat at a login prompt nobody could get past, which turned a five-minute
    # diagnosis into guesswork.
    #
    # It is DELETED at the end of the bake, and that deletion is not optional.
    # `cloud-init clean` does not remove users - its source only clears logs, the
    # generated net and ssh config, /var/lib/cloud and machine-id - so without an
    # explicit userdel this account, with this password and passwordless sudo, would
    # survive into the gold and into every VM built from it. Reachable over SSH, too,
    # now that the bake fixes Ubuntu's password-auth drop-in.
    #
    # The deletion runs LAST on purpose: a bake that hangs never reaches it, so the
    # login is still there on exactly the runs where it is needed.
    [void]$lines.Add("users:")
    [void]$lines.Add("  - name: bake")
    [void]$lines.Add("    groups: [sudo]")
    [void]$lines.Add("    shell: /bin/bash")
    [void]$lines.Add("    sudo: 'ALL=(ALL) NOPASSWD:ALL'")
    [void]$lines.Add("    lock_passwd: false")
    [void]$lines.Add("chpasswd:")
    [void]$lines.Add("  expire: false")
    [void]$lines.Add("  users:")
    [void]$lines.Add("    - name: bake")
    [void]$lines.Add("      password: 'bake'")
    [void]$lines.Add("      type: text")
    # The mirror, through cloud-init's own apt module rather than by editing files.
    # That matters on these images: Ubuntu 26.04 and Debian 13 both write their sources
    # in deb822 format (/etc/apt/sources.list.d/*.sources), not the one-line format, and
    # the module knows which one this release uses. A sed over sources.list would edit a
    # file that is no longer read.
    #
    # It is set on the BAKE, so it persists into the gold - cloud-init clean does not
    # revert sources - and every VM built from the gold inherits the same mirror.
    # `security` is deliberately left alone: security.ubuntu.com and security.debian.org
    # are single well-served hosts, and pointing them at a country mirror is how a lab
    # ends up lagging on security updates.
    [void]$lines.Add("apt:")
    if (-not [string]::IsNullOrWhiteSpace($MirrorUri)) {
        [void]$lines.Add("  primary:")
        [void]$lines.Add("    - arches: [default]")
        [void]$lines.Add("      uri: $MirrorUri")
    }
    # Bounded timeouts, so an unreachable mirror costs minutes rather than most of an
    # hour. Read out of the image itself: package_update_upgrade_install is the FIRST
    # module in cloud_final_modules and power_state_change is the LAST, so nothing after
    # apt runs until apt is done - no runcmd, no sentinel, no poweroff. And nothing
    # outside will cut it short either: cloud-final.service is Type=oneshot, for which
    # systemd disables the start timeout by default.
    #
    # apt does NOT wait for ever on its own - its HTTP method carries a timeout of its
    # own (ServerState starts at 30 s) - but that is per connection, and it is spent
    # again on every index file and every retry, which is how a dead mirror turns into
    # a VM that looks hung for a long time without ever being hung.
    #
    # Acquire::http::Timeout covers both the connection and the data timer, so shrinking
    # it and capping the retries bounds the whole thing. A failed apt still lets
    # cloud-init reach power_state, which is what turns a long silence into a verdict.
    [void]$lines.Add("  conf: |")
    [void]$lines.Add("    Acquire::http::Timeout `"20`";")
    [void]$lines.Add("    Acquire::https::Timeout `"20`";")
    [void]$lines.Add("    Acquire::Retries `"2`";")
    [void]$lines.Add("package_update: true")
    if ($ApplyUpdates) { [void]$lines.Add("package_upgrade: true") }
    if ($packages.Count -gt 0) {
        [void]$lines.Add("packages:")
        foreach ($package in $packages) { [void]$lines.Add("  - '$package'") }
    }
    if ($wantAliases) {
        # profile.d covers an SSH session, which is a login shell, and every user that
        # already exists. /etc/skel is what the per-VM user gets: cloud-init creates that
        # account on FIRST BOOT, which is after this bake, so skel reaches it - and skel
        # is also what covers a non-login interactive shell, where profile.d is not read.
        # Hence both, and the skel line sources the same file rather than copying it, so
        # there is one place to read and no chance of the two drifting.
        [void]$lines.Add("write_files:")
        [void]$lines.Add("  - path: /etc/profile.d/99-hv-studio-aliases.sh")
        [void]$lines.Add("    permissions: '0644'")
        [void]$lines.Add("    content: |")
        [void]$lines.Add("      # Baked by HyperV-VM-Studio. Same aliases on every distribution this builds,")
        [void]$lines.Add("      # which is the point: Ubuntu ships ll/la/l and Debian ships them commented out.")
        [void]$lines.Add("      alias ls='ls --color=auto'")
        [void]$lines.Add("      alias grep='grep --color=auto'")
        [void]$lines.Add("      alias ll='ls -alF'")
        [void]$lines.Add("      alias la='ls -A'")
        [void]$lines.Add("      alias l='ls -CF'")
        [void]$lines.Add("      alias cls='clear'")
        [void]$lines.Add("      alias ..='cd ..'")
        [void]$lines.Add("      alias cd..='cd ..'")
    }

    [void]$lines.Add("runcmd:")
    # Everything below prints to the console, which is ttyS0 on these images, which is
    # the pipe the host is reading.
    # SINGLE quotes. In a double-quoted PowerShell string $(uname -r) is a subexpression
    # and expands HERE, stamping the build host's own kernel into the guest's config -
    # which on a Windows host is not even a sensible string. It has to reach the guest
    # shell literally.
    [void]$lines.Add('  - [ sh, -c, ''echo BAKE-KERNEL $(uname -r)'' ]')
    [void]$lines.Add("  - [ sh, -c, 'dpkg -l | grep -c hyperv || true' ]")

    # No sshd edits here, and that is a correction rather than an omission.
    #
    # An earlier version commented `PasswordAuthentication` out of the image's
    # /etc/ssh/sshd_config.d/60-cloudimg-settings.conf, on the reading that cloud-init
    # wrote ssh_pwauth into the MAIN sshd_config and therefore lost to that drop-in.
    # That reading was wrong. cloud-init's update_ssh_config calls
    # _ensure_cloud_init_ssh_config_file first, which - whenever sshd_config carries the
    # `Include sshd_config.d/*.conf` line - redirects the write to
    # /etc/ssh/sshd_config.d/50-cloud-init.conf. 50 sorts before 60, sshd keeps the
    # FIRST value it obtains, so cloud-init's file already wins. `ssh_pwauth` in the
    # per-VM seed works on these images with nothing baked in to help it.
    #
    # Removing that edit also removes a way to be less safe: with the vendor line
    # commented out, a VM that ever boots WITHOUT a seed would fall back to sshd's own
    # default of yes, rather than staying closed the way the image shipped.
    [void]$lines.Add("  - [ sh, -c, 'systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true' ]")
    # Generalize: the gold must carry no identity of its own.
    if ($wantAliases) {
        [void]$lines.Add('  - [ sh, -c, "grep -q 99-hv-studio-aliases /etc/skel/.bashrc || echo \". /etc/profile.d/99-hv-studio-aliases.sh\" >> /etc/skel/.bashrc" ]')
    }
    if ($wantColorPrompt) {
        # Both images ship this line commented out; uncommenting it in skel is what the
        # per-VM user inherits when cloud-init creates the account at first boot.
        [void]$lines.Add('  - [ sh, -c, "sed -i s/^#force_color_prompt=yes/force_color_prompt=yes/ /etc/skel/.bashrc || true" ]')
    }
    if ($wantQuietMotd) {
        # ENABLED=0 stops the fetch itself; the chmod stops the scripts that print the
        # adverts. 00-header and the reboot-required notice are deliberately left alone -
        # the first says what the machine is and the second is the one line on a login
        # banner that has ever mattered.
        [void]$lines.Add('  - [ sh, -c, "sed -i s/^ENABLED=1/ENABLED=0/ /etc/default/motd-news 2>/dev/null || true" ]')
        [void]$lines.Add('  - [ sh, -c, "chmod -x /etc/update-motd.d/50-motd-news /etc/update-motd.d/91-contract-ua-esm-status /etc/update-motd.d/50-landscape-sysinfo /etc/update-motd.d/90-updates-available /etc/update-motd.d/95-hwe-eol /etc/update-motd.d/10-help-text 2>/dev/null || true" ]')
    }
    [void]$lines.Add("  - [ cloud-init, clean, '--logs', '--machine-id' ]")
    [void]$lines.Add("  - [ sh, -c, 'rm -f /etc/ssh/ssh_host_*' ]")
    [void]$lines.Add("  - [ sh, -c, 'rm -f /etc/netplan/50-cloud-init.yaml' ]")
    [void]$lines.Add("  - [ sh, -c, 'truncate -s 0 /etc/machine-id' ]")
    # The diagnostic account goes here, at the end, once everything that might have
    # needed it has succeeded. -f because the account may own a running process, -r to
    # take its home directory with it, and the sudoers drop-in is cloud-init's own file
    # for the users it provisioned - it names this account and nothing else.
    [void]$lines.Add("  - [ sh, -c, 'userdel -f -r bake 2>/dev/null || true' ]")
    [void]$lines.Add("  - [ sh, -c, 'rm -f /etc/sudoers.d/90-cloud-init-users' ]")
    # Both, on purpose. /dev/console resolves to whichever console= came LAST on the
    # kernel command line, so on an image that ends up with console=tty1 the sentinel
    # would land on the video console and never reach the pipe the host is reading -
    # and a bake that worked would be reported as a failure. Naming the port directly
    # removes the guess; the redirect to /dev/console stays for the operator watching
    # the Hyper-V window.
    [void]$lines.Add("  - [ sh, -c, 'echo BAKE-OK > /dev/console' ]")
    [void]$lines.Add("  - [ sh, -c, 'echo BAKE-OK > /dev/ttyS0 || true' ]")
    [void]$lines.Add("power_state:")
    [void]$lines.Add("  mode: poweroff")
    [void]$lines.Add("  timeout: 30")
    [void]$lines.Add("  condition: true")

    return ($lines -join "`n") + "`n"
}

function Format-BakeMacWithColons {
    # Hyper-V reports a MAC as 00155D0A0B0C; netplan matches on 00:15:5d:0a:0b:0c.
    param([string]$MacAddress)

    $clean = ([string]$MacAddress) -replace "[^0-9A-Fa-f]", ""
    if ($clean.Length -ne 12) { return "" }
    # All zeroes is what Hyper-V reports for an adapter whose DYNAMIC address has not
    # been generated yet, which is the case for every VM that has not started. It
    # passes every format check and matches no adapter on earth, so it is rejected
    # here rather than written into a netplan file that silently matches nothing.
    if ($clean -eq "000000000000") { return "" }
    $pairs = @()
    for ($i = 0; $i -lt 12; $i += 2) { $pairs += $clean.Substring($i, 2).ToLowerInvariant() }
    return ($pairs -join ":")
}

function New-BakeMacAddress {
    # Hyper-V OUI 00-15-5D plus three random bytes - the same shape Build-Vms.ps1 uses
    # for the VMs it provisions.
    $bytes = 1..3 | ForEach-Object { Get-Random -Minimum 0 -Maximum 256 }
    return ("00155D{0:X2}{1:X2}{2:X2}" -f $bytes[0], $bytes[1], $bytes[2])
}

function Get-BakeNetworkConfig {
    <#
        The bake VM's network-config, netplan v2, as NoCloud's THIRD seed file - not
        inside user-data, where cloud-init would ignore it and the VM would come up on
        DHCP with nothing said about why.

        Returns an empty string for DHCP, and no file is written: the image's own
        default already is DHCP, so saying it again only adds something to get wrong.

        The adapter is matched by MAC because the kernel's name for it is not knowable
        from the host - which is why the VM has to exist before this is rendered.
    #>
    param(
        [object]$Config,
        [string]$MacAddress
    )

    if ([bool]$Config.BakeUseDhcp) { return "" }

    $ipAddress = ([string]$Config.BakeIpAddress).Trim()
    if ([string]::IsNullOrWhiteSpace($ipAddress)) { return "" }

    $prefix = 24
    if ($Config.BakePrefixLength) { $prefix = [int]$Config.BakePrefixLength }
    $gateway = ([string]$Config.BakeGateway).Trim()

    $dns = @()
    foreach ($server in @($Config.BakeDnsServers)) {
        $trimmed = ([string]$server).Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $dns += $trimmed }
    }

    $mac = Format-BakeMacWithColons -MacAddress $MacAddress

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("version: 2")
    [void]$lines.Add("ethernets:")
    [void]$lines.Add("  primary:")
    [void]$lines.Add("    match:")
    if (-not [string]::IsNullOrWhiteSpace($mac)) {
        [void]$lines.Add("      macaddress: '$mac'")
    }
    else {
        # No usable MAC. netplan needs SOME match or it treats the key as an interface
        # name and matches nothing at all - so match every ethernet instead. The bake VM
        # has exactly one adapter, which is what makes that safe here and not elsewhere.
        [void]$lines.Add("      name: 'e*'")
    }
    [void]$lines.Add("    dhcp4: false")
    [void]$lines.Add("    dhcp6: false")
    [void]$lines.Add("    addresses: ['$ipAddress/$prefix']")
    if (-not [string]::IsNullOrWhiteSpace($gateway)) {
        # `gateway4` is deprecated; a default route says the same thing and keeps working.
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

function Read-VmSerialConsole {
    <#
        Reads the guest's serial console from the named pipe a VM's COM1 is bound to,
        and returns everything it saw.

        This exists because the bake boot is otherwise BLIND. cloud-init powers the VM
        off whether it succeeded or apt could not reach a mirror; the host sees `Off`
        either way and would ship the gold regardless. Ubuntu and Debian cloud kernels
        already carry console=ttyS0, so the whole boot log arrives here for nothing.

        Returns the transcript. The caller decides what the absence of a sentinel means.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PipeName,
        [Parameter(Mandatory = $true)][string]$VmName,
        [int]$TimeoutMinutes = 30
    )

    $transcript = New-Object System.Text.StringBuilder
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $pipe = $null

    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $PipeName, [System.IO.Pipes.PipeDirection]::In)
        # The VM creates the pipe when it starts, so the first connect can lose the race.
        $pipe.Connect(120000)

        $buffer = New-Object byte[] 4096
        $started = Get-Date
        $lastReport = Get-Date
        while ((Get-Date) -lt $deadline) {
            # The VM powering off closes the pipe, which is what ends this loop - a read
            # returning zero is the normal exit, not a failure.
            $read = $pipe.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            [void]$transcript.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $read))

            # Say something every couple of minutes. A bake installs a kernel over a
            # network and can legitimately take a while; a console that prints nothing
            # for half an hour is indistinguishable from one that has hung.
            if (((Get-Date) - $lastReport).TotalSeconds -ge 120) {
                $lastReport = Get-Date
                $elapsed = [int]((Get-Date) - $started).TotalMinutes
                Write-Log "Bake running $elapsed min, $($transcript.Length) bytes" -Tag "Info"
            }
        }
    }
    catch {
        # A serial transcript is diagnostics. Losing it must not fail a bake that the
        # power state can still speak for.
        Write-Log "Serial console '$VmName': $($_.Exception.Message)" -Tag "Debug"
    }
    finally {
        if ($pipe) { $pipe.Dispose() }
    }

    return $transcript.ToString()
}

function Invoke-LinuxBakeBoot {
    <#
        Boots the gold once with a throwaway seed attached, so it can install what the
        generic cloud image does not ship, and then erase its own identity.

        The VM is temporary in every sense: it is created here, it is removed in the
        finally block whatever happens, and it exists only to give the image a kernel
        and a CPU for a few minutes.

        Needs a vSwitch with a route to the distribution mirrors. There is no way to
        install a kernel without one, so a missing switch fails loudly here rather than
        producing a gold that looks finished and is not.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$VhdxPath,
        [Parameter(Mandatory = $true)][string]$SwitchName,
        [object]$Config,
        [bool]$ApplyUpdates = $false,
        [string[]]$ExtraPackages = @(),
        [int]$TimeoutMinutes = 30
    )

    $vmName = "bake-" + $Entry.ImageId + "-" + ([Guid]::NewGuid().ToString("N").Substring(0, 6))
    $pipeName = "bake-" + [Guid]::NewGuid().ToString("N").Substring(0, 12)
    $seedPath = [System.IO.Path]::ChangeExtension($VhdxPath, ".bake-seed.vhdx")
    $created = $false

    try {
        # The VM is created BEFORE the seed, because a static address has to be pinned to
        # the adapter's MAC and that MAC does not exist until Hyper-V has assigned one.
        Write-Log "Creating the temporary bake VM '$vmName'" -Tag "Run"
        New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 2GB -VHDPath $VhdxPath -SwitchName $SwitchName -ErrorAction Stop | Out-Null
        $created = $true

        Set-VMProcessor -VMName $vmName -Count 2 -ErrorAction Stop
        Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false -ErrorAction Stop

        # The third-party UEFI CA, not the Windows template - these images are signed
        # through shim, and the Windows template simply does not boot them.
        Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority" -ErrorAction Stop

        # Pin a static MAC before reading one. A dynamic MAC is generated by the host
        # when the VM first STARTS, so reading it straight after New-VM gives all
        # zeroes - and the seed has to be written before the VM boots. Build-Vms.ps1
        # settles the same problem the same way for every VM it provisions.
        $adapter = Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop | Select-Object -First 1
        try {
            Set-VMNetworkAdapter -VMNetworkAdapter $adapter -StaticMacAddress (New-BakeMacAddress) -ErrorAction Stop
            $adapter = Get-VMNetworkAdapter -VMName $vmName -ErrorAction Stop | Select-Object -First 1
        }
        catch {
            Write-Log "Could not pin a static MAC on the bake adapter: $($_.Exception.Message) - the seed will match by adapter name instead" -Tag "Warn"
        }
        $bakeVlanId = 0
        if ($Config -and $Config.BakeVlanId) { $bakeVlanId = [int]$Config.BakeVlanId }
        if ($bakeVlanId -gt 0) {
            Set-VMNetworkAdapterVlan -VMNetworkAdapter $adapter -Access -VlanId $bakeVlanId -ErrorAction Stop
            Write-Log "Bake adapter tagged with VLAN $bakeVlanId" -Tag "Run"
        }

        $networkConfig = ""
        if ($Config) { $networkConfig = Get-BakeNetworkConfig -Config $Config -MacAddress ([string]$adapter.MacAddress) }
        if ([string]::IsNullOrWhiteSpace($networkConfig)) {
            Write-Log "Bake network: DHCP" -Tag "Info"
        }
        else {
            Write-Log ("Bake IP {0}/{1} via {2}" -f $Config.BakeIpAddress, $Config.BakePrefixLength, $Config.BakeGateway) -Tag "Info"
        Write-Log ("Bake DNS {0}" -f (@($Config.BakeDnsServers) -join ", ")) -Tag "Info"
        }

        $mirrorUri = ""
        if ($Config) { $mirrorUri = Get-AptMirrorUri -Entry $Entry -RegionCode ([string]$Config.BakeMirrorRegion) }
        if ([string]::IsNullOrWhiteSpace($mirrorUri)) {
            Write-Log "apt mirror: the distribution's default" -Tag "Info"
        }
        else {
            Write-Log "apt mirror: $mirrorUri" -Tag "Info"
        }

        $bakeFeatures = @()
        if ($Config) { $bakeFeatures = @($Config.BakeFeatures) }
        if (@($bakeFeatures).Count -gt 0) { Write-Log "Baking optional features: $(@($bakeFeatures) -join ', ')" -Tag "Info" }

        $userData = Get-BakeUserData -Entry $Entry -ApplyUpdates $ApplyUpdates -ExtraPackages $ExtraPackages -MirrorUri $mirrorUri -Features $bakeFeatures
        $metaData = "instance-id: bake-" + [DateTime]::UtcNow.ToString("yyyyMMddHHmmss") + "`nlocal-hostname: bake`n"
        $null = New-CloudInitSeedDisk -VhdxPath $seedPath -UserData $userData -MetaData $metaData -NetworkConfig $networkConfig

        # The boot device is named BEFORE the seed is attached, and by path rather than
        # by position: with two disks on the controller, "the first one" stops meaning
        # the gold, and a VM that boots the 64 MB seed finds no operating system on it.
        $bootDisk = Get-VMHardDiskDrive -VMName $vmName -ErrorAction Stop |
            Where-Object { $_.Path -eq $VhdxPath } | Select-Object -First 1
        if ($null -eq $bootDisk) { throw "The bake VM has no disk at '$VhdxPath' to boot from" }
        Set-VMFirmware -VMName $vmName -FirstBootDevice $bootDisk -ErrorAction Stop

        Add-VMHardDiskDrive -VMName $vmName -Path $seedPath -ErrorAction Stop

        Set-VMComPort -VMName $vmName -Number 1 -Path "\\.\pipe\$pipeName" -ErrorAction Stop

        Write-Log "Starting the bake boot - installing $($Entry.BakePackages -join ', ')" -Tag "Run"
        Start-VM -Name $vmName -ErrorAction Stop

        $transcript = Read-VmSerialConsole -PipeName $pipeName -VmName $vmName -TimeoutMinutes $TimeoutMinutes

        # The pipe closing usually means the guest went down, but wait on the power state
        # as well: that is the thing that actually says the disk is no longer in use.
        $deadline = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $deadline) {
            $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if ($null -eq $vm -or $vm.State -eq "Off") { break }
            Start-Sleep -Seconds 5
        }

        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -ne "Off") {
            Write-Log "The bake VM did not power off within the timeout - stopping it" -Tag "Warn"
            Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
            Write-Log "The gold may be incomplete: cloud-init never reported finishing" -Tag "Error"
            return $false
        }

        # Beside the run's own log, not beside the gold. The vhdx folder holds disks
        # and their sidecars; a 127 KB console transcript is neither, and leaving it
        # there means every gold ships with a stray file that looks like part of it.
        # Named for the gold and stamped, so several bakes of the same image do not
        # overwrite each other the way a fixed name would.
        $logPath = Join-Path -Path $logFileDirectory -ChildPath (
            "{0}-bake-{1}.log" -f [System.IO.Path]::GetFileNameWithoutExtension($VhdxPath), (Get-Date -Format "yyyyMMdd-HHmm"))
        if (-not (Test-Path -LiteralPath $logFileDirectory)) {
            New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null
        }
        try {
            [System.IO.File]::WriteAllText($logPath, $transcript, (New-Object System.Text.UTF8Encoding($false)))
            Write-Log "Bake transcript -> '$logPath'" -Tag "Info"
        }
        catch {
            Write-Log "Bake transcript: $($_.Exception.Message)" -Tag "Debug"
        }

        if ($transcript -match "BAKE-OK") {
            $kernel = ""
            if ($transcript -match "BAKE-KERNEL\s+(\S+)") { $kernel = $Matches[1] }
            if ($kernel) { Write-Log "Bake finished - guest kernel $kernel" -Tag "ok" }
            else { Write-Log "Bake finished" -Tag "ok" }
            return $true
        }

        # Powered off without the sentinel: cloud-init ran and something in it failed,
        # most often apt with no route to a mirror.
        Write-Log "The bake VM powered off without reporting BAKE-OK - the gold is NOT baked. See '$logPath'" -Tag "Error"
        return $false
    }
    catch {
        Write-Log "Bake boot failed: $($_.Exception.Message)" -Tag "Error"
        return $false
    }
    finally {
        if ($created) {
            # The VM must go before anything else touches the VHDX, and it must go even
            # when the bake threw - a bake VM left attached to a gold quietly locks it.
            try {
                $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
                if ($vm) {
                    if ($vm.State -ne "Off") { Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue }
                    # -RemoveVHD is NOT passed: the VHDX is the gold, not a scratch disk.
                    Remove-VM -Name $vmName -Force -ErrorAction Stop
                    Write-Log "Removed the temporary bake VM '$vmName'" -Tag "Run"
                }
            }
            catch {
                Write-Log "Could not remove the bake VM '$vmName': $($_.Exception.Message) - remove it by hand before using this gold" -Tag "Error"
            }
        }
        if (Test-Path -LiteralPath $seedPath) {
            Remove-Item -LiteralPath $seedPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-LinuxInteractiveConfiguration {
    <#
        The Linux half of the first blade.

        Deliberately much shorter than the Windows form, because most of what that one
        asks does not exist here: there is no UI language to choose (a cloud image
        carries one locale and no MUI packs), no RDP or ping toggle (ufw is inactive on
        these images, so there is nothing to open), no Server Manager, Welcome screen,
        first-sign-in or sign-in-keyboard policy, no device encryption, no AVMA key, no
        Edge policy and no virtual edition hop. What is left is the machine's region
        settings and its disk.
    #>
    param(
        [string]$CurrentLocale,
        [string]$CurrentKeyboard,
        [string]$CurrentOutputDirectory
    )

    $catalog = @(Get-LinuxImageCatalog)
    $distroItems = @()
    foreach ($entry in $catalog) {
        $distroItems += [PSCustomObject]@{ Id = $entry.Id; Label = $entry.Name }
    }

    $distroId = Show-Menu -Title "Select a Linux distribution" -Items $distroItems `
        -Heading "Distribution" -HeadingHint "The cloud image this gold is built from"
    if ($null -eq $distroId) { return $null }
    $entry = $catalog | Where-Object { $_.Id -eq $distroId } | Select-Object -First 1

    # The same question the Windows path asks, and it decides the same two things: the
    # gold's prefix, and whether a sidecar manifest is written at all.
    $targetItems = @(
        [PSCustomObject]@{ Id = "HyperV";     Label = "Hyper-V" }
        [PSCustomObject]@{ Id = "AzureLocal"; Label = "Azure Local" }
    )
    $targetDefault = 0
    if ($CurrentTarget -eq "AzureLocal") { $targetDefault = 1 }
    $targetId = Show-Menu -Title "Select deployment target" -Items $targetItems -SelectedIndex $targetDefault `
        -Heading "Target platform" -HeadingHint "Where this gold will be deployed - it decides the gold's name prefix" `
        -StatusLines ([ordered]@{ distro = $entry.Name })
    if ($null -eq $targetId) { return $null }
    # Worked out after the language blade below, because the name now carries it.
    $goldName = ""

    if ($targetId -eq "AzureLocal") {
        # Worth saying once, plainly. Build-Vms.ps1 enumerates hv-*.vhdx and nothing
        # else, so an azl- gold never meets this project's seed machinery: whatever
        # Azure Local does for cloud-init is what that VM gets. The bake still runs -
        # it happens on this Hyper-V host - so the kernel, the daemons and the SSH
        # settings baked in are the only ones such a VM will ever have.
        Show-MenuHeader -Title "Azure Local" -StatusLines ([ordered]@{ distro = $entry.Name })
        Write-Studio -Text "  An Azure Local gold is not provisioned by Build-Vms.ps1 - it only builds hv-* golds." -Key "muted"
        Write-Studio -Text "  No per-VM seed is written for it, and no sidecar manifest: nothing on that path reads one." -Key "muted"
        Write-Studio -Text "  What the bake puts in is all such a VM carries, so pick the bake options with that in mind." -Key "muted"
        Write-Host ""
        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
        Write-Host ""
    }

    # Three separate questions, because on Linux they really are three separate things.
    #
    # glibc splits what Windows calls "display language" and "regional format" across
    # LC_* variables: LANG (and LC_MESSAGES under it) decides what language a program
    # SPEAKS, while LC_TIME, LC_NUMERIC, LC_MONETARY, LC_PAPER and the rest decide how
    # it FORMATS. Setting one locale sets both, which is why asking once was wrong -
    # wanting German dates without German error messages is the normal case, and it is
    # exactly what a single `locale:` line cannot express.
    #
    # All three pick from the same catalog. What differs is which variable each one
    # ends up in, and that is decided in Get-CloudInitUserData rather than here.
    $localeItems = @()
    foreach ($tag in (Get-OrderedLocaleTags)) {
        # -Locale, not -LocaleTag. Get-LocaleDisplayName is a simple function, so an
        # unknown parameter name is NOT rejected - it goes into $args and the real
        # parameter keeps its default, which here meant every row looked up the empty
        # string and logged a fallback. The Linux helpers beside it do take -LocaleTag;
        # the two spellings sitting next to each other are what made this easy to write.
        $localeItems += [PSCustomObject]@{ Id = $tag; Label = "$tag - $(Get-LocaleDisplayName -Locale $tag)" }
    }
    # 1. Language - LANG, so what the system SAYS, and the gold's middle segment.
    # en-US by default: English logs stay
    # greppable and every upstream error message matches what a search engine has seen.
    $languageDefault = [array]::IndexOf(@($localeItems.Id), "en-US")
    if ($languageDefault -lt 0) { $languageDefault = 0 }
    $language = Show-Menu -Title "Select the system language" -Items $localeItems -SelectedIndex $languageDefault `
        -Heading "Language" -HeadingHint "LANG - the language of messages, logs and man pages. Leave it on en-US unless you want translated error text" `
        -StatusLines ([ordered]@{ distro = $entry.Name })
    if ($null -eq $language) { return $null }
    $goldName = Get-LinuxGoldName -Entry $entry -Target $targetId -Language $language

    # 2. Locale - the LC_* format family, so what the system SHOWS. Dates, decimal
    # separators, currency, paper size.
    $localeDefault = [array]::IndexOf(@($localeItems.Id), $CurrentLocale)
    if ($localeDefault -lt 0) { $localeDefault = 0 }
    $locale = Show-Menu -Title "Select the regional format" -Items $localeItems -SelectedIndex $localeDefault `
        -Heading "Locale" -HeadingHint "LC_TIME, LC_NUMERIC, LC_MONETARY and the rest - dates, numbers and currency, not the language" `
        -StatusLines ([ordered]@{ distro = $entry.Name; language = (Get-LinuxLocaleName -LocaleTag $language) })
    if ($null -eq $locale) { return $null }

    # 3. Keyboard - the console keymap.
    $keyboardDefault = [array]::IndexOf(@($localeItems.Id), $CurrentKeyboard)
    if ($keyboardDefault -lt 0) { $keyboardDefault = $localeDefault }
    $keyboard = Show-Menu -Title "Select the console keyboard layout" -Items $localeItems -SelectedIndex $keyboardDefault `
        -Heading "Keyboard" -HeadingHint "The console keymap - irrelevant over SSH, it matters at the Hyper-V console" `
        -StatusLines ([ordered]@{
            distro   = $entry.Name
            language = (Get-LinuxLocaleName -LocaleTag $language)
            format   = (Get-LinuxLocaleName -LocaleTag $locale)
        })
    if ($null -eq $keyboard) { return $null }

    # Loaded HERE rather than at the top of this function. It parses a 54 KB catalogue
    # into 419 objects and logs a line when it is done, and at the top that line landed
    # on the PREVIOUS menu's screen - so choosing Linux printed a log row, paused, and
    # only then cleared and drew the next blade. Three paints for one keypress, which
    # reads as a flicker. Here the pause belongs to the blade that needs the data, and
    # the log line is cleared by the menu that follows it.
    Import-LinuxTimeZoneCatalog

    # 419 zones sorted by region put UTC near the bottom and Europe in the middle, which
    # meant scrolling a long way to reach the one this lab actually uses. The default is
    # the configured locale's own zone where that can be worked out, Europe/Berlin
    # otherwise - and either way Home/End still reach the ends of the list.
    $timeZoneDefault = [array]::IndexOf(@($script:LinuxTimeZones.Id), (Get-DefaultLinuxTimeZone -LocaleTag $locale))
    if ($timeZoneDefault -lt 0) { $timeZoneDefault = [array]::IndexOf(@($script:LinuxTimeZones.Id), "Europe/Berlin") }
    if ($timeZoneDefault -lt 0) { $timeZoneDefault = [array]::IndexOf(@($script:LinuxTimeZones.Id), "UTC") }
    if ($timeZoneDefault -lt 0) { $timeZoneDefault = 0 }
    $timeZone = Show-Menu -Title "Select the time zone" -Items $script:LinuxTimeZones -SelectedIndex $timeZoneDefault `
        -Heading "Time zone" -HeadingHint "IANA name, as cloud-init and systemd want it" `
        -StatusLines ([ordered]@{
            distro   = $entry.Name
            language = (Get-LinuxLocaleName -LocaleTag $language)
            format   = (Get-LinuxLocaleName -LocaleTag $locale)
            keyboard = (Get-LinuxKeymap -LocaleTag $keyboard)
        })
    if ($null -eq $timeZone) { return $null }

    # The same single-screen form the Windows path uses - size and provisioning type
    # together - rather than a second way of asking the same two questions. Fixed and
    # Dynamic mean exactly what they mean for a Windows gold, and both targets take
    # either: an Azure Local gold is a VHDX like any other.
    $vhdxConfig = Show-VhdxConfigForm -Title "Configure VHDX" `
        -Subtitle "Size applies to every VM built from this gold" `
        -StatusLines ([ordered]@{
            distro   = $entry.Name
            target   = $targetId
            language = (Get-LinuxLocaleName -LocaleTag $language)
            format   = (Get-LinuxLocaleName -LocaleTag $locale)
            timezone = $timeZone
        }) `
        -DefaultSizeGB $entry.DefaultDiskGB -MinSizeGB 8 -MaxSizeGB 2048 -DefaultType "Dynamic"
    if ($null -eq $vhdxConfig) { return $null }
    $diskGB = $vhdxConfig.SizeGB
    $vhdType = $vhdxConfig.Type

    # The bake boot needs a switch with a route to the distribution mirrors. There is no
    # way to install a kernel without one, so the question is asked rather than guessed,
    # and "skip" is an explicit answer rather than something that happens by accident.
    $switchItems = @()
    foreach ($switch in @(Get-VMSwitch -ErrorAction SilentlyContinue)) {
        $switchItems += [PSCustomObject]@{ Id = $switch.Name; Label = "$($switch.Name)  ($($switch.SwitchType))" }
    }
    $switchItems += [PSCustomObject]@{ Id = "__skip__"; Label = "Skip the bake boot - leave the stock kernel and no hyperv-daemons" }

    $switchName = Show-Menu -Title "Select a virtual switch for the bake boot" -Items $switchItems `
        -Heading "Bake network" -HeadingHint "The gold boots once to install $($entry.BakePackages -join ', ') - it needs to reach the mirrors" `
        -StatusLines ([ordered]@{ distro = $entry.Name; disk = "$diskGB GB" })
    if ($null -eq $switchName) { return $null }

    $applyUpdates = $false
    $bakeExtraPackages = @()
    $bakeUseDhcp = $true
    $bakeIpAddress = ""
    $bakePrefixLength = 24
    $bakeGateway = ""
    $bakeDnsServers = @()
    $bakeVlanId = 0
    $bakeMirrorRegion = "default"

    if ($switchName -ne "__skip__") {
        # The bake VM has to reach the distribution mirrors, and a switch alone does not
        # promise that. A lab with no DHCP leaves apt retrying mirrors it cannot see,
        # cloud-init's final stage never finishes, power_state never fires, and the VM
        # sits at a login prompt looking like a hang - which is exactly what it did.
        $addressItems = @(
            [PSCustomObject]@{ Id = "dhcp";   Label = "DHCP - the network hands out an address" }
            [PSCustomObject]@{ Id = "static"; Label = "Static address - enter it here" }
        )
        $addressChoice = Show-Menu -Title "How does the bake VM get an address?" -Items $addressItems `
            -Heading "Bake addressing" -HeadingHint "It only has to last one boot, but it does have to reach the mirrors" `
            -StatusLines ([ordered]@{ distro = $entry.Name; switch = $switchName })
        if ($null -eq $addressChoice) { return $null }
        $bakeUseDhcp = ($addressChoice -eq "dhcp")

        Show-MenuHeader -Title "Bake network" -StatusLines ([ordered]@{
            distro    = $entry.Name
            switch    = $switchName
            addressing = $(if ($bakeUseDhcp) { "DHCP" } else { "static" })
        })
        Write-Studio -Text "  These settings are thrown away with the bake VM." -Key "muted"
        Write-Studio -Text "  The gold keeps none of them - every VM built from it is addressed on its own card." -Key "muted"
        Write-Host ""

        Write-BladeFooterAbove -ReserveLines $(if ($bakeUseDhcp) { 1 } else { 5 })

        if (-not $bakeUseDhcp) {
            $bakeIpAddress = Read-ConsoleIpAddress -Prompt "  IP address"
            $bakePrefixLength = Read-BoundedInt -Prompt "  Prefix length" -DefaultValue 24 -MinValue 1 -MaxValue 32
            $bakeGateway = Read-ConsoleIpAddress -Prompt "  Default gateway" -AllowEmpty
            $dnsRaw = Read-Host "  DNS servers (space separated)"
            foreach ($dnsEntry in @($dnsRaw -split "[\s,]+")) {
                $trimmedDns = ([string]$dnsEntry).Trim()
                if (-not [string]::IsNullOrWhiteSpace($trimmedDns)) { $bakeDnsServers += $trimmedDns }
            }
        }

        # VLAN is asked either way: a tagged port with DHCP behind it still needs the tag.
        $bakeVlanId = Read-BoundedInt -Prompt "  VLAN ID (0 for untagged)" -DefaultValue 0 -MinValue 0 -MaxValue 4094

        # Review, then continue or fix one field. Typed-in addresses are the one place in
        # this blade where a single wrong character costs a whole bake - the VM boots,
        # apt cannot resolve anything, and the run only says so half an hour later. So
        # they get read back before they are used, and any one of them can be changed
        # without walking through the other four again.
        while ($true) {
            $dnsShown = if ($bakeDnsServers.Count -gt 0) { $bakeDnsServers -join " " } else { "(none)" }
            $gatewayShown = if ([string]::IsNullOrWhiteSpace($bakeGateway)) { "(none)" } else { $bakeGateway }
            $vlanShown = if ($bakeVlanId -gt 0) { [string]$bakeVlanId } else { "untagged" }

            # Settings first, then a blank line, then the way out. Continue sits under
            # what it is confirming rather than above it, and it starts selected so the
            # common answer is one keypress.
            $reviewItems = @()
            $reviewItems += [PSCustomObject]@{ Id = "mode"; Label = ("Addressing        {0}" -f $(if ($bakeUseDhcp) { "DHCP" } else { "static" })) }
            if (-not $bakeUseDhcp) {
                $reviewItems += [PSCustomObject]@{ Id = "ip";      Label = ("IP address        {0}" -f $bakeIpAddress) }
                $reviewItems += [PSCustomObject]@{ Id = "prefix";  Label = ("Prefix length     /{0}" -f $bakePrefixLength) }
                $reviewItems += [PSCustomObject]@{ Id = "gateway"; Label = ("Default gateway   {0}" -f $gatewayShown) }
                $reviewItems += [PSCustomObject]@{ Id = "dns";     Label = ("DNS servers       {0}" -f $dnsShown) }
            }
            $reviewItems += [PSCustomObject]@{ Id = "vlan"; Label = ("VLAN              {0}" -f $vlanShown) }
            $reviewItems += [PSCustomObject]@{ Id = "__gap__"; Label = ""; Separator = $true }
            $reviewItems += [PSCustomObject]@{ Id = "__ok__"; Label = "Continue with these settings" }

            $reviewHint = "Enter on a row to change it, or continue"
            if (-not $bakeUseDhcp -and $bakeDnsServers.Count -eq 0) {
                # Not a hard block - a mirror named by IP would still work - but apt
                # resolves host names, so this is the setting that quietly kills a bake.
                $reviewHint = "No DNS server - apt resolves by name, so the bake will almost certainly fail"
            }

            $reviewChoice = Show-Menu -Title "Review the bake network" -Items $reviewItems `
                -SelectedIndex ($reviewItems.Count - 1) `
                -Heading "Bake network" -HeadingHint $reviewHint `
                -StatusLines ([ordered]@{ distro = $entry.Name; switch = $switchName })
            if ($null -eq $reviewChoice) { return $null }
            if ($reviewChoice -eq "__ok__") {
                if (-not $bakeUseDhcp -and [string]::IsNullOrWhiteSpace($bakeIpAddress)) {
                    # Static with no address is the one combination that cannot proceed:
                    # netplan would be handed an empty addresses list.
                    continue
                }
                break
            }

            Show-MenuHeader -Title "Bake network" -StatusLines ([ordered]@{
                distro     = $entry.Name
                switch     = $switchName
                addressing = $(if ($bakeUseDhcp) { "DHCP" } else { "static" })
            })
            Write-Host ""

            switch ($reviewChoice) {
                "mode" {
                    $bakeUseDhcp = -not $bakeUseDhcp
                    if ($bakeUseDhcp) {
                        # Keep what was typed rather than discarding it: switching back
                        # to static should not mean typing the address again.
                        Write-Studio -Text "  Addressing switched to DHCP - the static values are kept in case you switch back." -Key "muted"
                        Write-Host ""
                        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
                    }
                    else {
                        if ([string]::IsNullOrWhiteSpace($bakeIpAddress)) {
                            $bakeIpAddress = Read-ConsoleIpAddress -Prompt "  IP address"
                            Write-Host ""
                            Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
                        }
                    }
                }
                "ip" {
                    Write-BladeFooterAbove -ReserveLines 1
                    $bakeIpAddress = Read-ConsoleIpAddress -Prompt "  IP address" -DefaultValue $bakeIpAddress
                }
                "prefix" {
                    Write-BladeFooterAbove -ReserveLines 1
                    $bakePrefixLength = Read-BoundedInt -Prompt "  Prefix length" -DefaultValue $bakePrefixLength -MinValue 1 -MaxValue 32
                }
                "gateway" {
                    Write-BladeFooterAbove -ReserveLines 1
                    $bakeGateway = Read-ConsoleIpAddress -Prompt "  Default gateway (blank for none)" -AllowEmpty
                }
                "dns" {
                    Write-BladeFooterAbove -ReserveLines 1
                    $dnsRaw = Read-Host "  DNS servers (space separated)"
                    $bakeDnsServers = @()
                    foreach ($dnsEntry in @($dnsRaw -split "[\s,]+")) {
                        $trimmedDns = ([string]$dnsEntry).Trim()
                        if (-not [string]::IsNullOrWhiteSpace($trimmedDns)) { $bakeDnsServers += $trimmedDns }
                    }
                }
                "vlan" {
                    Write-BladeFooterAbove -ReserveLines 1
                    $bakeVlanId = Read-BoundedInt -Prompt "  VLAN ID (0 for untagged)" -DefaultValue $bakeVlanId -MinValue 0 -MaxValue 4094
                }
            }
        }

        # Which mirror apt talks to. The stock cloud image points at archive.ubuntu.com
        # or deb.debian.org, and a badly routed one turns a kernel install into a long
        # wait - which is what a slow bake usually is.
        $mirrorItems = @([PSCustomObject]@{ Id = "default"; Label = "Default - archive.ubuntu.com / deb.debian.org" })
        foreach ($region in @(Get-AptMirrorCatalog)) {
            # NOT $host. That is the automatic variable holding the host object, and
            # PowerShell resolves variables dynamically - shadowing it here would hand a
            # string to every function called from this scope, including the one that
            # reads $Host.UI to decide whether the console can do colour.
            $mirrorHost = if ($entry.Distro -eq "ubuntu") { [string]$region.Ubuntu } else { [string]$region.Debian }
            # A region with no mirror for THIS distribution is not offered: picking it
            # would silently fall back, which looks like the setting did nothing.
            if ([string]::IsNullOrWhiteSpace($mirrorHost)) { continue }
            $mirrorItems += [PSCustomObject]@{ Id = $region.Code; Label = "$($region.Name)  -  $mirrorHost" }
        }

        # Default from the region the format locale already named - de-DE means Germany,
        # and typing that twice is the kind of question a picker should answer itself.
        $localeCountry = ""
        $localeParts = $locale -split "-"
        if ($localeParts.Count -ge 2) { $localeCountry = $localeParts[$localeParts.Count - 1].ToLowerInvariant() }
        $mirrorDefault = [array]::IndexOf(@($mirrorItems.Id), $localeCountry)
        if ($mirrorDefault -lt 0) { $mirrorDefault = 0 }

        $bakeMirrorRegion = Show-Menu -Title "Which apt mirror should the bake use?" -Items $mirrorItems -SelectedIndex $mirrorDefault `
            -Heading "Package mirror" -HeadingHint "Pre-selected from the regional format. It is baked into the gold, so every VM inherits it" `
            -StatusLines ([ordered]@{ distro = $entry.Name; switch = $switchName })
        if ($null -eq $bakeMirrorRegion) { return $null }

        $updateItems = @(
            [PSCustomObject]@{ Id = "no";  Label = "No - install only what the image is missing" }
            [PSCustomObject]@{ Id = "yes"; Label = "Yes - full package upgrade (slower, and the gold ages the moment it is built)" }
        )
        $updateChoice = Show-Menu -Title "Apply all available updates during the bake?" -Items $updateItems `
            -Heading "Updates" -HeadingHint "A full upgrade can add a lot of minutes to the bake"
        if ($null -eq $updateChoice) { return $null }
        $applyUpdates = ($updateChoice -eq "yes")

        Show-MenuHeader -Title "Extra packages" -StatusLines ([ordered]@{ distro = $entry.Name; switch = $switchName })
        Write-Studio -Text "  Anything every VM from this gold should already have." -Key "muted"
        Write-Studio -Text "  Space separated. Blank for none." -Key "muted"
        Write-Host ""
        Write-BladeFooterAbove -ReserveLines 1
        $extraRaw = Read-Host "  Extra packages"
        if (-not [string]::IsNullOrWhiteSpace($extraRaw)) {
            $bakeExtraPackages = @($extraRaw -split "[\s,]+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }

    # Optional features, the Linux counterpart to the Windows picker. Asked even when
    # the bake is skipped: these are file edits, not package installs, so they cost
    # nothing and work without a mirror - but they DO need a boot to be applied, so a
    # skipped bake means a skipped feature, and the picker says so rather than pretending.
    $bakeFeatures = @()
    if ($switchName -ne "__skip__") {
        $featureItems = @()
        foreach ($feature in @(Get-LinuxGoldFeatureCatalog)) {
            if (-not [string]::IsNullOrWhiteSpace($feature.Distro) -and $feature.Distro -ne $entry.Distro) { continue }
            $featureItems += [PSCustomObject]@{
                Id       = $feature.Id
                Label    = $feature.Label
                Selected = [bool]$feature.DefaultOn
                Section  = "Optional"
            }
        }
        if ($featureItems.Count -gt 0) {
            $bakeFeatures = Show-MultiSelectMenu -Title "Optional features" -Items $featureItems -AllowEmpty `
                -Subtitle "Space toggles - baked into the gold, not per VM" `
                -ContinueLabel "Continue" `
                -StatusLines ([ordered]@{ distro = $entry.Name; gold = "$goldName.vhdx" })
            if ($null -eq $bakeFeatures) { return $null }
        }
    }

    $outputDirectory = $CurrentOutputDirectory
    if ([string]::IsNullOrWhiteSpace($outputDirectory)) {
        $outputDirectory = Join-Path -Path $PSScriptRoot -ChildPath "vhdx"
    }
    # Worked out once: the summary shows it and the config carries it, and two
    # Join-Path calls for one path is one of them waiting to disagree with the other.
    $cacheDirectory = Join-Path -Path $PSScriptRoot -ChildPath "lnx-images"

    # Final confirmation, the same shape the Windows path uses: every setting rendered
    # above a Continue/Cancel menu, so the last thing before a build that downloads
    # hundreds of megabytes and boots a VM is a chance to read it back.
    $renderLinuxSummary = {
        Write-Studio -Text "  Image" -Key "fg"
        Write-FastfetchInfoRow -Label "distribution" -Value $entry.Name -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "target"       -Value $targetId -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "gold name"    -Value "$goldName.vhdx" -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "source"       -Value $entry.Url -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "image cache"  -Value $cacheDirectory -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "output"       -Value $outputDirectory -LabelWidth 24 -IndentWidth 2
        Write-Host ""

        Write-Studio -Text "  Region" -Key "fg"
        Write-FastfetchInfoRow -Label "language (LANG)" -Value (Get-LinuxLocaleName -LocaleTag $language) -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "format (LC_*)"   -Value (Get-LinuxLocaleName -LocaleTag $locale) -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "keyboard"        -Value (Get-LinuxKeymap -LocaleTag $keyboard) -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "time zone"       -Value $timeZone -LabelWidth 24 -IndentWidth 2
        Write-Host ""

        Write-Studio -Text "  Disk" -Key "fg"
        Write-FastfetchInfoRow -Label "gold size" -Value "$diskGB GB" -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "vhdx type" -Value $vhdType -LabelWidth 24 -IndentWidth 2
        Write-Host ""

        Write-Studio -Text "  Bake" -Key "fg"
        if ([string]::IsNullOrWhiteSpace($switchName) -or $switchName -eq "__skip__") {
            Write-FastfetchInfoRow -Label "bake boot" -Value "Skipped - stock kernel, no hyperv-daemons" -LabelWidth 24 -IndentWidth 2
        }
        else {
            Write-FastfetchInfoRow -Label "switch"   -Value $switchName -LabelWidth 24 -IndentWidth 2
            if ($bakeUseDhcp) {
                Write-FastfetchInfoRow -Label "addressing" -Value "DHCP" -LabelWidth 24 -IndentWidth 2
            }
            else {
                Write-FastfetchInfoRow -Label "addressing" -Value "$bakeIpAddress/$bakePrefixLength" -LabelWidth 24 -IndentWidth 2
                Write-FastfetchInfoRow -Label "gateway" -Value $(if ([string]::IsNullOrWhiteSpace($bakeGateway)) { "(none)" } else { $bakeGateway }) -LabelWidth 24 -IndentWidth 2
                Write-FastfetchInfoRow -Label "dns" -Value $(if (@($bakeDnsServers).Count -gt 0) { @($bakeDnsServers) -join " " } else { "(none)" }) -LabelWidth 24 -IndentWidth 2
            }
            Write-FastfetchInfoRow -Label "vlan" -Value $(if ($bakeVlanId -gt 0) { [string]$bakeVlanId } else { "untagged" }) -LabelWidth 24 -IndentWidth 2

            $mirrorShown = Get-AptMirrorUri -Entry $entry -RegionCode $bakeMirrorRegion
            if ([string]::IsNullOrWhiteSpace($mirrorShown)) { $mirrorShown = "distribution default" }
            Write-FastfetchInfoRow -Label "apt mirror" -Value $mirrorShown -LabelWidth 24 -IndentWidth 2

            Write-FastfetchInfoRow -Label "installs" -Value (@($entry.BakePackages) -join ", ") -LabelWidth 24 -IndentWidth 2
            $languagePackShown = Get-UbuntuLanguagePack -Entry $entry -LanguageTag $language
            if (-not [string]::IsNullOrWhiteSpace($languagePackShown)) {
                Write-FastfetchInfoRow -Label "language pack" -Value $languagePackShown -LabelWidth 24 -IndentWidth 2
            }
            if (@($bakeExtraPackages).Count -gt 0) {
                Write-FastfetchInfoRow -Label "extra packages" -Value (@($bakeExtraPackages) -join ", ") -LabelWidth 24 -IndentWidth 2
            }
            Write-FastfetchInfoRow -Label "apply updates" -Value $(if ($applyUpdates) { "Yes - full package upgrade" } else { "No" }) -LabelWidth 24 -IndentWidth 2
            $featureShown = "none"
            if (@($bakeFeatures).Count -gt 0) {
                $featureLabels = @()
                foreach ($feature in @(Get-LinuxGoldFeatureCatalog)) {
                    if (@($bakeFeatures) -contains $feature.Id) { $featureLabels += $feature.Id }
                }
                $featureShown = $featureLabels -join ", "
            }
            Write-FastfetchInfoRow -Label "features" -Value $featureShown -LabelWidth 24 -IndentWidth 2
        }
        Write-Host ""
        Write-Studio -Text ("  " + ("-" * 62)) -Key "muted"
        Write-Host ""
    }

    $confirmItems = @(
        [PSCustomObject]@{ Id = "continue"; Label = "Continue - start the build" }
        [PSCustomObject]@{ Id = "cancel";   Label = "Cancel" }
    )
    $decision = Show-Menu -Title "Confirm build settings" -Subtitle "Review everything below, then continue" `
        -Items $confirmItems -SelectedIndex 0 -PreItems $renderLinuxSummary
    if ($decision -ne "continue") { return $null }

    return [PSCustomObject]@{
        OsFamily        = "Linux"
        Entry           = $entry
        Target          = $targetId
        GoldName        = $goldName
        Language        = $language
        Locale          = $locale
        KeyboardLayout  = $keyboard
        TimeZone        = $timeZone
        DiskSizeGB      = $diskGB
        VhdType         = $vhdType
        OutputDirectory = $outputDirectory
        CacheDirectory  = $cacheDirectory
        BakeSwitchName  = $(if ($switchName -eq "__skip__") { "" } else { $switchName })
        BakeApplyUpdates = $applyUpdates
        BakeExtraPackages = $bakeExtraPackages
        BakeUseDhcp      = $bakeUseDhcp
        BakeIpAddress    = $bakeIpAddress
        BakePrefixLength = $bakePrefixLength
        BakeGateway      = $bakeGateway
        BakeDnsServers   = $bakeDnsServers
        BakeVlanId       = $bakeVlanId
        BakeMirrorRegion = $bakeMirrorRegion
        BakeFeatures     = $bakeFeatures
    }
}

function Invoke-LinuxGoldRun {
    # The whole Linux path, from a finished configuration to a gold on disk. Kept apart
    # from the Windows body rather than threaded through it: the two share the output
    # directory and nothing else.
    param([Parameter(Mandatory = $true)][object]$Config)

    $entry = $Config.Entry

    $target = [string]$Config.Target
    if ([string]::IsNullOrWhiteSpace($target)) { $target = "HyperV" }
    $goldName = [string]$Config.GoldName
    if ([string]::IsNullOrWhiteSpace($goldName)) {
        $goldName = Get-LinuxGoldName -Entry $entry -Target $target -Language ([string]$Config.Language)
    }

    Write-Log "$($entry.Name) -> '$goldName' ($target)" -Tag "Info"
    Write-Log ("Language {0}, format {1}" -f $Config.Language, $Config.Locale) -Tag "Info"
    Write-Log ("Keymap {0}, time zone {1}" -f (Get-LinuxKeymap -LocaleTag $Config.KeyboardLayout), $Config.TimeZone) -Tag "Info"
    $diskType = if ($Config.VhdType) { $Config.VhdType } else { "Dynamic" }
    Write-Log ("Disk {0} GB {1}" -f $Config.DiskSizeGB, $diskType) -Tag "Info"
    Write-Log ("Output {0}" -f $Config.OutputDirectory) -Tag "Info"

    foreach ($command in @("Convert-VHD", "Resize-VHD")) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            Write-Log "'$command' is not available - the Hyper-V PowerShell module is required to build a gold" -Tag "Error"
            return $false
        }
    }

    try {
        $imagePath = Get-CachedLinuxImage -Entry $entry -CacheDirectory $Config.CacheDirectory
    }
    catch {
        Write-Log "Could not obtain the cloud image: $($_.Exception.Message)" -Tag "Error"
        return $false
    }

    try {
        $checksum = (Get-FileHash -LiteralPath $imagePath -Algorithm $entry.Algorithm).Hash.ToLowerInvariant()
        $vhdxPath = New-LinuxGoldImage -Entry $entry -ImagePath $imagePath `
            -OutputDirectory $Config.OutputDirectory -DiskSizeGB $Config.DiskSizeGB `
            -VhdType $(if ($Config.VhdType) { [string]$Config.VhdType } else { "Dynamic" }) -GoldName $goldName
    }
    catch {
        Write-Log "Failed to build the gold: $($_.Exception.Message)" -Tag "Error"
        return $false
    }

    $null = Write-LinuxGoldManifest -VhdPath $vhdxPath -Entry $entry -Target $target `
        -Language $Config.Language -Locale $Config.Locale -KeyboardLayout $Config.KeyboardLayout `
        -TimeZone $Config.TimeZone -VhdType $(if ($Config.VhdType) { [string]$Config.VhdType } else { "Dynamic" }) `
        -SourceChecksum $checksum

    if ([string]::IsNullOrWhiteSpace([string]$Config.BakeSwitchName)) {
        # Said plainly rather than left for a puzzled reader: without the bake the gold
        # still carries the distribution's stock kernel and no Hyper-V integration
        # daemons, so no heartbeat, no shutdown integration and no KVP from its VMs.
        Write-Log "Bake skipped - this gold keeps the stock kernel and has no hyperv-daemons" -Tag "Warn"
        return $true
    }

    # Ubuntu keeps translations out of the packages and in language-pack-<lang>, and its
    # cloud image ships none of them - so a gold asked for a language other than English
    # would set LANG and still speak English. Debian ships translations inside the
    # packages themselves and needs nothing extra. The bake is where this belongs: it is
    # the one boot with a network.
    $bakePackages = @($Config.BakeExtraPackages)
    $languagePack = Get-UbuntuLanguagePack -Entry $entry -LanguageTag ([string]$Config.Language)
    if (-not [string]::IsNullOrWhiteSpace($languagePack)) {
        Write-Log "Adding $languagePack for $($Config.Language)" -Tag "Info"
        $bakePackages += $languagePack
    }

    $baked = Invoke-LinuxBakeBoot -Entry $entry -VhdxPath $vhdxPath -SwitchName ([string]$Config.BakeSwitchName) `
        -Config $Config -ApplyUpdates ([bool]$Config.BakeApplyUpdates) -ExtraPackages $bakePackages
    if (-not $baked) {
        Write-Log "'$vhdxPath' was built but the bake did not finish - do not deploy it as it stands" -Tag "Error"
        return $false
    }

    return $true
}

# ---------------------------[ Disk Helpers ]---------------------------
function New-ImageVhdx {
    param(
        [string]$VhdPath,
        [int64]$SizeBytes,
        [string]$VhdType
    )

    if (Test-Path -Path $VhdPath) {
        Write-Log "Removing existing file '$VhdPath'" -Tag "Run"
        Remove-Item -Path $VhdPath -Force
    }

    $sizeGb = [math]::Round($SizeBytes / 1GB)
    Write-Log "$VhdType VHDX '$VhdPath' ($sizeGb GB)" -Tag "Run"

    if ($VhdType -eq "Dynamic") {
        New-VHD -Path $VhdPath -SizeBytes $SizeBytes -Dynamic | Out-Null
    }
    else {
        New-VHD -Path $VhdPath -SizeBytes $SizeBytes -Fixed | Out-Null
    }
}

function Initialize-VhdxLayout {
    param([string]$VhdPath)

    Write-Log "Mounting and partitioning '$VhdPath'" -Tag "Run"

    $mountedDisk = Mount-VHD -Path $VhdPath -Passthru | Get-Disk
    Initialize-Disk -Number $mountedDisk.Number -PartitionStyle GPT

    $efiPartition = New-Partition -DiskNumber $mountedDisk.Number -Size 200MB `
        -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
    Format-Volume -Partition $efiPartition -FileSystem FAT32 `
        -NewFileSystemLabel "System" -Confirm:$false | Out-Null
    $efiPartition | Set-Partition -NewDriveLetter S

    Write-Log "Creating Microsoft Reserved (MSR) partition" -Tag "Debug"
    New-Partition -DiskNumber $mountedDisk.Number -Size 128MB `
        -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" | Out-Null

    $osPartition = New-Partition -DiskNumber $mountedDisk.Number -UseMaximumSize
    Format-Volume -Partition $osPartition -FileSystem NTFS `
        -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null
    $osPartition | Set-Partition -NewDriveLetter W

    Write-Log "EFI partition on S:, MSR partition, OS partition on W:" -Tag "Debug"
}

function Install-WindowsImageToVhdx {
    param(
        [string]$WimPath,
        [int]$ImageIndex
    )

    Write-Log "Applying image index $ImageIndex from '$WimPath'" -Tag "Run"
    Expand-WindowsImage -ImagePath $WimPath -Index $ImageIndex -ApplyPath "W:\" | Out-Null
}

function Set-TempBootUnattend {
    param([string]$Content)

    $pantherPath = "W:\Windows\Panther"
    $unattendPath = Join-Path -Path $pantherPath -ChildPath "unattend.xml"

    if (-not (Test-Path -Path $pantherPath)) {
        New-Item -ItemType Directory -Path $pantherPath -Force | Out-Null
    }

    Write-Log "Boot unattend -> '$unattendPath'" -Tag "Run"
    Write-Utf8NoBomFile -Path $unattendPath -Content $Content
}

function Set-HyperVDeployUnattend {
    param([string]$Content)

    $deployPath = "W:\Windows\Deploy\unattend.xml"
    Write-Log "Deploy unattend -> '$deployPath'" -Tag "Run"
    Write-Utf8NoBomFile -Path $deployPath -Content $Content
}

function Get-BcdBootFailureReason {
    # bcdboot that never ran prints nothing, so the exit code is the only evidence there
    # is. 0xC0E90002 is STATUS_SYSTEM_INTEGRITY_POLICY_VIOLATION: the kernel refused to
    # launch the binary. Here that means a code integrity policy (WDAC, Smart App
    # Control) blocked the copy of bcdboot.exe living inside the mounted image.
    param([int]$ExitCode)

    if ($ExitCode -eq -1058471934) {
        return " / 0xC0E90002 STATUS_SYSTEM_INTEGRITY_POLICY_VIOLATION - a code integrity policy on this host blocked the executable"
    }

    return ""
}

function Invoke-BcdBoot {
    # Returns the exit code and the output rather than throwing, so the caller can try
    # the other copy of the tool before it gives up on the disk.
    param(
        [string]$BcdBootPath,
        [string]$OsRoot,
        [string]$SystemVolume
    )

    Write-Log "$BcdBootPath $OsRoot /s $SystemVolume /f UEFI" -Tag "Debug"
    $output = & $BcdBootPath $OsRoot /s $SystemVolume /f UEFI 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Set-BootFiles {
    # Two copies of bcdboot can do this job: the host's, and the one inside the image
    # that was just applied. The host's goes first, because a code integrity policy on
    # the host refuses to execute a binary that lives on a mounted VHDX - the kernel
    # stops it before its first instruction, so it prints nothing at all and returns
    # 0xC0E90002. The image's copy is still the better tool when the image is newer
    # than the host, so it is tried second rather than dropped.
    param(
        [string]$OsRoot = "W:\Windows",
        [string]$SystemVolume = "S:"
    )

    Write-Log "Writing UEFI boot files" -Tag "Run"

    $candidates = @(
        [pscustomobject]@{ Name = "host"; Path = (Join-Path -Path $env:SystemRoot -ChildPath "System32\bcdboot.exe") },
        [pscustomobject]@{ Name = "image"; Path = "W:\Windows\System32\bcdboot.exe" }
    )

    $lastResult = $null
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.Path)) {
            Write-Log "No $($candidate.Name) bcdboot at '$($candidate.Path)'" -Tag "Debug"
            continue
        }

        $lastResult = Invoke-BcdBoot -BcdBootPath $candidate.Path -OsRoot $OsRoot -SystemVolume $SystemVolume
        if ($lastResult.ExitCode -eq 0) {
            Write-Log "Boot files written with the $($candidate.Name) bcdboot" -Tag "Ok"
            break
        }

        $reason = Get-BcdBootFailureReason -ExitCode $lastResult.ExitCode
        $detail = ($lastResult.Output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "no output" }
        Write-Log "The $($candidate.Name) bcdboot failed (exit $($lastResult.ExitCode)$reason): $detail" -Tag "Warn"
    }

    # Judged on what is actually on the EFI partition, not on an exit code. A gold that
    # leaves here without a loader boots to the Hyper-V UEFI summary and nothing else,
    # and it is cheaper to lose the build than to find that out from a VM.
    $loaderPath = "$SystemVolume\EFI\Microsoft\Boot\bootmgfw.efi"
    if (-not (Test-Path -LiteralPath $loaderPath)) {
        $why = if ($null -eq $lastResult) {
            "no bcdboot.exe was found to run"
        }
        else {
            "last exit $($lastResult.ExitCode)$(Get-BcdBootFailureReason -ExitCode $lastResult.ExitCode)"
        }
        throw "No boot loader at '$loaderPath' after bcdboot - $why. The disk would not boot."
    }

    Write-Log "Boot loader present at '$loaderPath'" -Tag "Ok"
}

function Invoke-DismRaw {
    # Every dism.exe call goes through here, including the ones whose output is the
    # point. Returns the exit code and the output instead of throwing, so a caller that
    # asks the image a question can read the answer.
    #
    # Retries exit 87 once or twice, and only that. Two DISM sessions against the same
    # offline image in quick succession can collide: the first still has the image's
    # registry hives mapped ("Hive already mounted at HKLM\{guid}W:/Windows/..."), the
    # second cannot get write access to them, and the provider reports error 5, access
    # denied - which dism.exe surfaces to the caller as 87. Nothing was applied when
    # that happens, so trying again after the first session lets go is safe.
    #
    # 87 is also plain "invalid parameter", which no amount of waiting fixes. The cost
    # of not telling them apart is a few wasted seconds on a call that was wrong anyway.
    param(
        [string[]]$Arguments,
        [int]$MaxAttempts = 3,
        [int]$RetryDelaySeconds = 10
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "dism.exe $($Arguments -join ' ')" -Tag "Debug"
        $output = & dism.exe @Arguments 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0 -or $exitCode -ne 87 -or $attempt -eq $MaxAttempts) {
            return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
        }

        Write-Log "dism.exe exit 87 - the image's hives may still be held by the previous session; retrying in $RetryDelaySeconds s ($attempt of $($MaxAttempts - 1))" -Tag "Warn"
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

function Invoke-Dism {
    # For the calls that only have to succeed.
    param([string[]]$Arguments)

    $result = Invoke-DismRaw -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "dism.exe failed (exit $($result.ExitCode)): $($result.Output)"
    }
}

function Dismount-ImageHive {
    param([string]$HiveRoot)

    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    & reg.exe unload $HiveRoot | Out-Null
}

function Get-VirtualEditionTarget {
    # What DISM would let this image become, filtered down to the one edition the
    # build spec asks for. Every SKU here goes by more than one name - the registry
    # calls multi-session ServerRdsh where DISM says EnterpriseMultiSession, and
    # Azure Edition surfaces as ServerTurbine - so match the family and hand back
    # the string DISM printed, because that is what /Set-Edition has to be given.
    #
    # Returns $null when the image cannot become the target. That is an answer, not
    # a failure: an image whose edition packs were never staged simply has no path
    # there, and the caller decides what to do about it.
    param(
        [string]$OsRoot,
        [string]$EditionUpgrade
    )

    Write-Log "Checking via DISM which editions the image can become" -Tag "Get"
    $result = Invoke-DismRaw -Arguments @("/Image:$OsRoot", "/Get-TargetEditions")
    if ($result.ExitCode -ne 0) {
        throw "dism.exe /Get-TargetEditions failed (exit $($result.ExitCode)): $($result.Output)"
    }

    $pattern = [string]$script:VirtualEditionCatalog[$EditionUpgrade].TargetPattern
    # No log line for the hit itself - every caller reports the answer with its own
    # context (index, or the reason a build stopped), and two lines saying the same
    # thing four seconds apart read like a stutter.
    foreach ($line in $result.Output) {
        if ("$line" -match $pattern) {
            return $Matches[1]
        }
    }
    return $null
}

function Get-TargetEditionSummary {
    # Just the edition ids, for the message that says why a build stopped. A list of
    # what the image CAN become is the only useful thing to print next to what it
    # cannot.
    param([string]$OsRoot)

    $result = Invoke-DismRaw -Arguments @("/Image:$OsRoot", "/Get-TargetEditions")
    $editions = @()
    foreach ($line in $result.Output) {
        if ("$line" -match "Target Edition\s*:\s*(\S+)") {
            $editions += $Matches[1]
        }
    }
    if ($editions.Count -eq 0) { return "none" }
    return ($editions -join ", ")
}

function Convert-ToVirtualEdition {
    # Runs AFTER generalize, on purpose. Applying the edition before sysprep is what
    # left the image owing Windows a restart that sysprep refuses to work around; a
    # base edition generalizes cleanly and takes the edition change afterwards, and
    # the staged work then completes during specialize on the deployed VM's first
    # boot, where a restart costs nothing.
    #
    # No product key: offline edition changes don't take one, and on Azure Local the
    # VM activates from the host's verification token rather than from anything baked
    # in here.
    param(
        [string]$VhdPath,
        [string]$EditionUpgrade
    )

    $converted = $false
    $mounted = $false
    try {
        $mountRoot = Get-MountedOsRoot -VhdPath $VhdPath
        $mounted = $true

        # The apply phase already asked which edition this image can become, and stored
        # the answer. Asking again would be the same question about the same disk -
        # sysprep does not stage or unstage edition packs. If /Set-Edition disagrees it
        # says so itself, and that error lands in the catch below.
        $targetEdition = [string]$script:EditionUpgradeTarget
        if ([string]::IsNullOrWhiteSpace($targetEdition)) {
            # Only reachable if this is called outside the build pipeline.
            $targetEdition = Get-VirtualEditionTarget -OsRoot $mountRoot -EditionUpgrade $EditionUpgrade
        }
        if ([string]::IsNullOrWhiteSpace($targetEdition)) {
            throw "No $($script:VirtualEditionCatalog[$EditionUpgrade].DisplayName) target edition for this image (can become: $(Get-TargetEditionSummary -OsRoot $mountRoot))"
        }

        Write-Log "Changing offline edition to '$targetEdition'" -Tag "Run"
        Invoke-Dism -Arguments @("/Image:$mountRoot", "/Set-Edition:$targetEdition")

        # DISM, not the SOFTWARE hive. EditionID is a string anyone can write - the
        # registry method of faking a virtual edition writes exactly that and nothing
        # else - while /Get-CurrentEdition resolves the virtual edition to its base and
        # checks the edition package is really installed. The extra session is what can
        # collide with the next one; Invoke-DismRaw retries that.
        $editionRead = Invoke-DismRaw -Arguments @("/Image:$mountRoot", "/Get-CurrentEdition")
        $currentEdition = @($editionRead.Output |
                Where-Object { "$_" -match "Current Edition\s*:\s*(\S+)" } |
                ForEach-Object { $Matches[1] }) | Select-Object -First 1
        Write-Log "Edition now '$currentEdition'" -Tag "Info"

        $statePath = Join-Path -Path $mountRoot -ChildPath "Windows\Setup\State\State.ini"
        if (Test-Path -LiteralPath $statePath) {
            $stateLine = (Get-Content -LiteralPath $statePath -ErrorAction SilentlyContinue |
                Where-Object { $_ -match "ImageState" } | Select-Object -First 1)
            Write-Log "Generalized state after the edition change: $stateLine" -Tag "Info"
            if ("$stateLine" -notmatch "GENERALIZE") {
                Write-Log "Image no longer reports a generalized state - the gold is not release-ready" -Tag "Warn"
            }
        }
        else {
            Write-Log "No Windows\Setup\State\State.ini to read the generalized state from" -Tag "Warn"
        }

        $converted = $true
        Write-Log "Edition change to '$targetEdition' applied offline" -Tag "Ok"
    }
    catch {
        Write-Log "Edition change failed for '$VhdPath': $($_.Exception.Message)" -Tag "Error"
    }
    finally {
        if ($mounted) {
            try { Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue }
            catch { Write-Log "Dismount failed after edition change: '$VhdPath'" -Tag "Debug" }
        }
    }

    return $converted
}

function Set-OfflineDeviceEncryptionPolicy {
    # Windows 11 24H2 dropped the HSTI/Modern Standby and DMA prerequisites for
    # automatic device encryption, and a Gen 2 VM with Secure Boot and a vTPM meets
    # everything that is left. So a client VM built from this gold encrypts itself
    # once OOBE finishes - with a clear key at first, then for real the moment the
    # machine joins a domain or Entra, because that is when the recovery key can be
    # escrowed and the TPM protector created. Nobody is asked.
    #
    # This lab arms BitLocker by policy after deployment, so the image opting itself in
    # first is a race, not a head start: it encrypts under whatever defaults Windows
    # picked, before any GPO has said which method or which recovery destination. The
    # tick is therefore on by default on the client path. A generalized 24H2 image can
    # also carry a BCD that only boots while the volume is unencrypted, and an image
    # that encrypts itself is the one that finds out.
    param([string]$MountRoot)

    $systemHive = Join-Path -Path $MountRoot -ChildPath "Windows\System32\config\SYSTEM"
    $hiveRoot = "HKLM\OfflineImageBitLocker"

    Write-Log "Loading offline SYSTEM hive for device encryption policy" -Tag "Run"
    & reg.exe load $hiveRoot $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SYSTEM hive (exit $LASTEXITCODE)"
    }

    try {
        Write-Log "Baking PreventDeviceEncryption=1" -Tag "Run"
        & reg.exe add "$hiveRoot\ControlSet001\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f | Out-Null
    }
    finally {
        Dismount-ImageHive -HiveRoot $hiveRoot
    }
}

function Set-OfflineEdgePolicy {
    <#
      A Microsoft Edge baseline, written as machine policy into the offline SOFTWARE hive.

      Every value below is an Edge policy under HKLM\SOFTWARE\Policies\Microsoft\Edge -
      the same keys the Microsoft Edge ADMX writes - so Edge reads them as managed settings,
      the pages show "managed by your organization", and a real domain GPO overrides them
      later without a fight. Edge is not installed on Server Core and the key is inert
      there, which is why the tick is offered for every image rather than gated on client.

      Search: ManagedSearchEngines is the list, with Google marked is_default. The
      DefaultSearchProvider* values ride along because NewTabPageSearchBox is documented to
      take effect only when DefaultSearchProviderEnabled and DefaultSearchProviderSearchURL
      are set; "redirect" then hands the new tab box to the address bar, which searches with
      the default engine instead of Bing.
    #>
    param([string]$MountRoot)

    # One source for the URLs - the ManagedSearchEngines JSON repeats them.
    $googleSearchUrl  = "https://www.google.com/search?q={searchTerms}"
    $googleSuggestUrl = "https://www.google.com/complete/search?output=chrome&q={searchTerms}"
    $managedSearchEngines = '[{"suggest_url": "' + $googleSuggestUrl + '", "image_search_url": "", "name": "Google", "keyword": "google", "is_default": true, "search_url": "' + $googleSearchUrl + '"}]'

    # Name / value / type, each with the Group Policy setting it corresponds to, so a row
    # here can be matched against gpedit without going looking for it.
    $edgePolicies = @(
        @{ Name = "ManagedSearchEngines";             Value = $managedSearchEngines; Type = "String"; Policy = "Manage Search Engines - Google only, set as default" }
        @{ Name = "DefaultSearchProviderEnabled";     Value = 1;                     Type = "DWord";  Policy = "Enable the default search provider" }
        @{ Name = "DefaultSearchProviderName";        Value = "Google";              Type = "String"; Policy = "Default search provider name" }
        @{ Name = "DefaultSearchProviderSearchURL";   Value = $googleSearchUrl;      Type = "String"; Policy = "Default search provider search URL" }
        @{ Name = "DefaultSearchProviderSuggestURL";  Value = $googleSuggestUrl;     Type = "String"; Policy = "Default search provider URL for suggestions" }
        @{ Name = "QuickSearchShowMiniMenu";          Value = 0;                     Type = "DWord";  Policy = "Enables Microsoft Edge mini menu - Disabled" }
        @{ Name = "HideFirstRunExperience";           Value = 1;                     Type = "DWord";  Policy = "Hide the First-run experience and splash screen - Enabled" }
        @{ Name = "NewTabPageSearchBox";              Value = "redirect";            Type = "String"; Policy = "Configure the new tab page search box experience - Address bar" }
        @{ Name = "NewTabPageContentEnabled";         Value = 0;                     Type = "DWord";  Policy = "Allow Microsoft content on the new tab page - Disabled" }
        @{ Name = "NewTabPageAllowedBackgroundTypes"; Value = 3;                     Type = "DWord";  Policy = "Background types allowed for the new tab page layout - Disable all background image types" }
        @{ Name = "NewTabPageHideDefaultTopSites";    Value = 1;                     Type = "DWord";  Policy = "Hide the default top sites from the new tab page - Enabled" }
        @{ Name = "DiagnosticData";                   Value = 1;                     Type = "DWord";  Policy = "Send required and optional diagnostic data about browser usage - Required data" }
    )

    $softwareHive = Join-Path -Path $MountRoot -ChildPath "Windows\System32\config\SOFTWARE"
    $hiveRoot = "HKLM\OfflineImageEdge"

    Write-Log "Loading offline SOFTWARE hive for Edge policy" -Tag "Run"
    & reg.exe load $hiveRoot $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SOFTWARE hive for the Edge policy (exit $LASTEXITCODE)"
    }

    try {
        $edgeKey = "Registry::$hiveRoot\Policies\Microsoft\Edge"
        if (-not (Test-Path -Path $edgeKey)) {
            New-Item -Path $edgeKey -Force | Out-Null
        }

        foreach ($policy in $edgePolicies) {
            Write-Log "Edge policy: $($policy.Policy)" -Tag "Run"
            Set-ItemProperty -Path $edgeKey -Name $policy.Name -Value $policy.Value -Type $policy.Type -Force
        }

        Write-Log "Baked $($edgePolicies.Count) Microsoft Edge policy value(s)" -Tag "Ok"
    }
    finally {
        Dismount-ImageHive -HiveRoot $hiveRoot
    }
}

function Set-OfflinePowerPolicy {
    # The gold only ever runs as a VM. Windows still arrives with the settings written for
    # a laptop: Balanced, console off after ten minutes, asleep after thirty. Neither helps
    # a machine nobody is sitting at, and a VM that has put itself to sleep is a VM that
    # stopped answering.
    #
    # Written as machine policy, into SOFTWARE\Policies, and not into the scheme itself.
    # Control\Power\User\PowerSchemes is ACL'd against Administrators - powercfg reaches
    # it through the power manager, a direct write does not, and those ACLs travel with the
    # hive when it is loaded offline, so every write there came back "Access is denied".
    # Taking ownership of a protected key in every gold to get around that is fighting the
    # OS. The policy keys are the same knobs a GPO would set (Administrative Templates >
    # System > Power Management), they live in a hive this script already writes, and a
    # real domain GPO later overrides them on its own.
    #
    # DISM has no power verb and powercfg has no offline mode, so the registry is the only
    # offline lever here; the choice was only which key.
    #
    # Cost: the deployed VM's Settings page says power is managed by the organization.
    param([string]$MountRoot)

    # Scheme and setting GUIDs are Windows' own, identical on every install.
    $highPerformance = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    $videoIdle       = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e"  # Turn off display after
    $standbyIdle     = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da"  # Sleep after

    $softwareHive = Join-Path -Path $MountRoot -ChildPath "Windows\System32\config\SOFTWARE"
    $hiveRoot = "HKLM\OfflineImagePower"

    Write-Log "Loading offline SOFTWARE hive for the power plan" -Tag "Run"
    & reg.exe load $hiveRoot $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SOFTWARE hive for the power plan (exit $LASTEXITCODE)"
    }

    try {
        $policyRoot = "Registry::$hiveRoot\Policies\Microsoft\Power\PowerSettings"
        if (-not (Test-Path -Path $policyRoot)) {
            New-Item -Path $policyRoot -Force | Out-Null
        }

        Write-Log "Policy: active power scheme = High performance" -Tag "Run"
        Set-ItemProperty -Path $policyRoot -Name "ActivePowerScheme" -Value $highPerformance -Type String -Force

        # 0 means never. AC and DC both: a Gen 2 VM reports no battery and Windows still
        # keeps a DC column, so leaving it at the default is leaving half the setting.
        foreach ($setting in @(
            @{ Guid = $videoIdle;   Label = "turn off display after" },
            @{ Guid = $standbyIdle; Label = "sleep after" }
        )) {
            Write-Log "Policy: $($setting.Label) = 0 (never), AC and DC" -Tag "Run"
            $settingPath = "$policyRoot\$($setting.Guid)"
            if (-not (Test-Path -Path $settingPath)) {
                New-Item -Path $settingPath -Force | Out-Null
            }
            Set-ItemProperty -Path $settingPath -Name "ACSettingIndex" -Value 0 -Type DWord -Force
            Set-ItemProperty -Path $settingPath -Name "DCSettingIndex" -Value 0 -Type DWord -Force
        }
    }
    finally {
        Dismount-ImageHive -HiveRoot $hiveRoot
    }

    Set-OfflineHibernationPolicy -MountRoot $MountRoot
}

function Set-OfflineHibernationPolicy {
    # Hibernation has no policy equivalent - it is one value in the SYSTEM hive, and the
    # same ACLs that block the scheme tree may block this one too. So it is attempted on
    # its own and reported rather than assumed: a failure here costs a hiberfil.sys the VM
    # was probably never going to create anyway (a Gen 2 guest is not offered S4), and it
    # must not take a finished gold down with it.
    param([string]$MountRoot)

    $systemHive = Join-Path -Path $MountRoot -ChildPath "Windows\System32\config\SYSTEM"
    $hiveRoot = "HKLM\OfflineImagePowerSys"

    & reg.exe load $hiveRoot $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Could not load the offline SYSTEM hive for hibernation (exit $LASTEXITCODE) - hibernation left at the Windows default" -Tag "Warn"
        return
    }

    try {
        Write-Log "Disabling hibernation (no hiberfil.sys)" -Tag "Run"
        $powerKey = "Registry::$hiveRoot\ControlSet001\Control\Power"
        Set-ItemProperty -Path $powerKey -Name "HibernateEnabled" -Value 0 -Type DWord -Force -ErrorAction Stop
        Set-ItemProperty -Path $powerKey -Name "HibernateEnabledDefault" -Value 0 -Type DWord -Force -ErrorAction Stop
        Write-Log "Hibernation disabled in the image" -Tag "Ok"
    }
    catch {
        Write-Log "Hibernation left at the Windows default: $($_.Exception.Message)" -Tag "Warn"
    }
    finally {
        Dismount-ImageHive -HiveRoot $hiveRoot
    }
}

function Set-OfflineRdpAndFirewall {
    param(
        [string]$MountRoot,
        [bool]$EnableRdp = $true,
        [bool]$EnablePing = $true
    )

    if (-not $EnableRdp -and -not $EnablePing) {
        Write-Log "RDP and ping both disabled - no SYSTEM hive bake" -Tag "Debug"
        return
    }

    $systemHive = Join-Path -Path $MountRoot -ChildPath "Windows\System32\config\SYSTEM"
    $hiveRoot = "HKLM\OfflineImageSys"
    $controlSet = "$hiveRoot\ControlSet001"
    $fwKey = "$controlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"

    Write-Log "Loading offline SYSTEM hive for RDP and firewall" -Tag "Run"
    & reg.exe load $hiveRoot $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SYSTEM hive (exit $LASTEXITCODE)"
    }

    try {
        if ($EnablePing) {
            Write-Log "Adding ICMP echo (ping) firewall rules" -Tag "Run"
            $icmpV4 = "v2.31|Action=Allow|Active=TRUE|Dir=In|Protocol=1|ICMP4=8:*|Name=Allow ICMPv4 Echo Request (ping)|Desc=Allow inbound ping IPv4|EmbedCtxt=Ping|"
            $icmpV6 = "v2.31|Action=Allow|Active=TRUE|Dir=In|Protocol=58|ICMP6=128:*|Name=Allow ICMPv6 Echo Request (ping)|Desc=Allow inbound ping IPv6|EmbedCtxt=Ping|"
            & reg.exe add "$fwKey" /v "Baked-ICMPv4-Echo-In" /t REG_SZ /d "$icmpV4" /f | Out-Null
            & reg.exe add "$fwKey" /v "Baked-ICMPv6-Echo-In" /t REG_SZ /d "$icmpV6" /f | Out-Null
        }
        else {
            Write-Log "Ping disabled - no ICMP echo rules" -Tag "Debug"
        }

        if ($EnableRdp) {
            Write-Log "Enabling Remote Desktop (fDenyTSConnections=0, NLA on)" -Tag "Run"
            & reg.exe add "$controlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f | Out-Null
            & reg.exe add "$controlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 1 /f | Out-Null

            Write-Log "Adding Remote Desktop firewall rules (TCP/UDP 3389)" -Tag "Run"
            $rdpTcp = "v2.31|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=3389|Name=Remote Desktop (TCP-In)|Desc=Allow inbound RDP over TCP|EmbedCtxt=Remote Desktop|"
            $rdpUdp = "v2.31|Action=Allow|Active=TRUE|Dir=In|Protocol=17|LPort=3389|Name=Remote Desktop (UDP-In)|Desc=Allow inbound RDP over UDP|EmbedCtxt=Remote Desktop|"
            & reg.exe add "$fwKey" /v "Baked-RDP-TCP-In" /t REG_SZ /d "$rdpTcp" /f | Out-Null
            & reg.exe add "$fwKey" /v "Baked-RDP-UDP-In" /t REG_SZ /d "$rdpUdp" /f | Out-Null
        }
        else {
            Write-Log "RDP disabled - Remote Desktop left off" -Tag "Debug"
        }
    }
    finally {
        Dismount-ImageHive -HiveRoot $hiveRoot
    }
}

function Set-OfflineServerManagerPolicy {
    param([string]$MountRoot)

    $softwareHive = Join-Path -Path $MountRoot -ChildPath "Windows\System32\config\SOFTWARE"
    $hiveRoot = "HKLM\OfflineImageSvrMgr"

    Write-Log "Suppressing Server Manager auto-launch at logon" -Tag "Run"
    & reg.exe load $hiveRoot $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SOFTWARE hive for Server Manager policy (exit $LASTEXITCODE)"
    }

    try {
        # Machine-wide Group Policy equivalent (Computer Configuration > Administrative
        # Templates > System > Server Manager > "Do not display Server Manager
        # automatically at logon"). Deliberately not an HKCU tweak - there is no real
        # user hive to target reliably on a generalized/offline image.
        $policyPath = "Registry::$hiveRoot\Policies\Microsoft\Windows\Server\ServerManager"
        if (-not (Test-Path -Path $policyPath)) {
            New-Item -Path $policyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $policyPath -Name "DoNotOpenAtLogon" -Value 1 -Type DWord -Force
    }
    finally {
        Dismount-ImageHive -HiveRoot $hiveRoot
    }
}

function Set-OfflineWelcomeExperiencePolicy {
    param([string]$MountRoot)

    $softwareHive = Join-Path -Path $MountRoot -ChildPath "Windows\System32\config\SOFTWARE"
    $hiveRoot = "HKLM\OfflineImageWelcome"

    Write-Log "Suppressing Windows Welcome Experience at logon" -Tag "Run"
    & reg.exe load $hiveRoot $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SOFTWARE hive for Welcome Experience policy (exit $LASTEXITCODE)"
    }

    try {
        # Machine-wide Group Policy equivalent (Computer Configuration > Administrative
        # Templates > Windows Components > Cloud Content > "Turn off the Windows Welcome
        # Experience"). Same rationale as the Server Manager policy above - HKLM policy
        # key, not an HKCU tweak, since there is no real user hive to target offline.
        $policyPath = "Registry::$hiveRoot\Policies\Microsoft\Windows\CloudContent"
        if (-not (Test-Path -Path $policyPath)) {
            New-Item -Path $policyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $policyPath -Name "DisableWindowsSpotlightWindowsWelcomeExperience" -Value 1 -Type DWord -Force
    }
    finally {
        Dismount-ImageHive -HiveRoot $hiveRoot
    }
}

function Set-OfflineFirstSignInAnimationPolicy {
    param([string]$MountRoot)

    $softwareHive = Join-Path -Path $MountRoot -ChildPath "Windows\System32\config\SOFTWARE"
    $hiveRoot = "HKLM\OfflineImageSignInAnim"

    Write-Log "Disabling the first sign-in animation" -Tag "Run"
    & reg.exe load $hiveRoot $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SOFTWARE hive for first sign-in animation policy (exit $LASTEXITCODE)"
    }

    try {
        # Machine-wide Group Policy equivalent (Computer Configuration > Administrative
        # Templates > System > Logon > "Show first sign-in animation"), disabled. Kills
        # the "Hi / We're getting things ready" full-screen intro so the first logon
        # lands on the desktop. Note this lives under CurrentVersion\Policies\System,
        # not the Policies\Microsoft\Windows tree the other policies here use.
        $policyPath = "Registry::$hiveRoot\Microsoft\Windows\CurrentVersion\Policies\System"
        if (-not (Test-Path -Path $policyPath)) {
            New-Item -Path $policyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $policyPath -Name "EnableFirstLogonAnimation" -Value 0 -Type DWord -Force
    }
    finally {
        Dismount-ImageHive -HiveRoot $hiveRoot
    }
}

function Set-OfflineSignInKeyboardPolicy {
    param([string]$MountRoot)

    $softwareHive = Join-Path -Path $MountRoot -ChildPath "Windows\System32\config\SOFTWARE"
    $hiveRoot = "HKLM\OfflineImageSoft"

    Write-Log "Setting BlockUserInputMethodsForSignIn policy" -Tag "Run"
    & reg.exe load $hiveRoot $softwareHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SOFTWARE hive (exit $LASTEXITCODE)"
    }

    try {
        $policyPath = "Registry::$hiveRoot\Policies\Microsoft\Control Panel\International"
        if (-not (Test-Path -Path $policyPath)) {
            New-Item -Path $policyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $policyPath -Name "BlockUserInputMethodsForSignIn" -Value 1 -Type DWord -Force
    }
    finally {
        Dismount-ImageHive -HiveRoot $hiveRoot
    }
}

function Get-MountedOsRoot {
    param([string]$VhdPath)

    $mountedDisk = Mount-VHD -Path $VhdPath -Passthru | Get-Disk
    $osVolume = Get-Partition -DiskNumber $mountedDisk.Number |
        Get-Volume |
        Where-Object { $_.FileSystem -eq "NTFS" -and $_.DriveLetter } |
        Sort-Object -Property Size -Descending |
        Select-Object -First 1

    if ($null -eq $osVolume) {
        throw "Could not locate the OS volume in the mounted image"
    }

    return "$($osVolume.DriveLetter):\"
}

# ---------------------------[ Azure Local First-Boot Locale ]---------------------------
function Write-AzureLocalLocalePayload {
    <#
    .SYNOPSIS
        Bakes the first-boot locale payload into an Azure Local gold image.
    .DESCRIPTION
        Azure Local forbids a custom answer file in the image (sysprep /generalize
        /oobe /shutdown only) and provisions the guest from its own answer file,
        delivered on two DVDs at VM creation. That file carries International-Core
        settings, so anything DISM wrote offline is overwritten during specialize /
        oobeSystem, and az stack-hci-vm create exposes no locale or time zone knob.

        SetupComplete.cmd runs after Setup finishes, before the logon screen, as
        LOCAL SYSTEM - after every configuration pass - so it has the last word.
        Three entry points call one idempotent payload:
          Windows\Setup\Scripts\SetupComplete.cmd   the documented hook
          Windows\OEM\SetupComplete2.cmd            what a platform-owned
                                                    SetupComplete.cmd would call
          RunOnce                                   if neither ran
        A marker under ProgramData stops the second and third from repeating the work.

        The payload applies settings through control.exe intl.cpl,,/f:<answer file>,
        which copies them to the default user profile and the system account in one
        call - the reason it is not the International cmdlets, which would configure
        the SYSTEM account this runs as. intl.cpl and timedate.cpl are the two
        applets Server Core ships, so Core golds are covered.

        It must not reboot: Setup cannot resume a SetupComplete.cmd that restarts the
        machine. The system locale therefore takes effect at the guest's next restart;
        keyboard, formats, GeoID and time zone apply immediately.

        Logs land where GuestProvision.ps1's do - C:\ProgramData\VmDeployLogs, one
        'locale-<yyyyMMdd-HHmm>.log' per run, same timestamp and tag format - so a
        guest has one folder to look in whichever payload wrote the line.
    #>
    param(
        [string]$MountRoot,
        [string]$Locale,
        [string]$KeyboardLayout,
        [string]$TimeZone
    )

    $entry = Get-LocaleCatalogEntry -Locale $Locale
    $inputLocale = Get-InputLocaleId -KeyboardLayout $KeyboardLayout
    $geoId = [string]$entry.GeoNation

    $scriptsDir = Join-Path -Path $MountRoot -ChildPath "Windows\Setup\Scripts"
    $oemDir = Join-Path -Path $MountRoot -ChildPath "Windows\OEM"
    foreach ($dir in @($scriptsDir, $oemDir)) {
        if (-not (Test-Path -Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # urn:longhornGlobalizationUnattend is the schema intl.cpl reads. UserID="Current"
    # is the account the payload runs as; the two Copy attributes push the same
    # settings to the default profile every later user is cloned from, and to the
    # system account behind the logon screen.
    $intlXml = @"
<gs:GlobalizationServices xmlns:gs="urn:longhornGlobalizationUnattend">
  <gs:UserList>
    <gs:User UserID="Current" CopySettingsToDefaultUserAcct="true" CopySettingsToSystemAcct="true"/>
  </gs:UserList>
  <gs:LocationPreferences>
    <gs:GeoID Value="$geoId"/>
  </gs:LocationPreferences>
  <gs:SystemLocale Name="$Locale"/>
  <gs:InputPreferences>
    <gs:InputLanguageID Action="add" ID="$inputLocale" Default="true"/>
  </gs:InputPreferences>
  <gs:UserLocale>
    <gs:Locale Name="$Locale" SetAsCurrent="true" ResetAllSettings="true"/>
  </gs:UserLocale>
</gs:GlobalizationServices>
"@

    $payload = @"
# Applies the locale this gold was built for, once, at the first boot of a deployed
# Azure Local VM. Runs as LOCAL SYSTEM from SetupComplete.cmd, before the logon
# screen, which is after the platform's own answer file has had its say.
`$ErrorActionPreference = "Stop"
`$logFileDirectory = Join-Path -Path `$env:ProgramData -ChildPath "VmDeployLogs"
`$logPath = Join-Path -Path `$logFileDirectory -ChildPath ("locale-" + (Get-Date -Format "yyyyMMdd-HHmm") + ".log")
`$marker = Join-Path -Path `$logFileDirectory -ChildPath "locale.applied"
`$scriptsDir = Join-Path -Path `$env:WINDIR -ChildPath "Setup\Scripts"
`$intlPath = Join-Path -Path `$scriptsDir -ChildPath "gold-locale.xml"

if (-not (Test-Path -Path `$logFileDirectory)) {
    New-Item -ItemType Directory -Path `$logFileDirectory -Force | Out-Null
}

# Same shape as GuestProvision.ps1's Write-Log: timestamp, five-wide lower-case tag,
# message. File only - nothing is watching a console at this point in Setup.
function Write-PayloadLog {
    param([string]`$Message, [string]`$Tag = "info")
    "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [ `$(`$Tag.PadRight(5)) ] `$Message" | Out-File -FilePath `$logPath -Append -Encoding ascii
}

if (Test-Path -Path `$marker) { exit 0 }

Write-PayloadLog "==================== Start ====================" -Tag "start"
Write-PayloadLog "`$env:COMPUTERNAME | Set-GoldLocale" -Tag "info"

try {
    Write-PayloadLog "Applying $Locale / $inputLocale / $TimeZone (GeoID $geoId)" -Tag "run"

    if (Test-Path -Path `$intlPath) {
        `$control = Join-Path -Path `$env:WINDIR -ChildPath "System32\control.exe"
        Start-Process -FilePath `$control -ArgumentList "intl.cpl,,/f:```"`$intlPath```"" -Wait -WindowStyle Hidden
        Write-PayloadLog "intl.cpl applied '`$intlPath'" -Tag "o.k."
    }
    else {
        Write-PayloadLog "gold-locale.xml missing - locale not applied" -Tag "error"
    }

    # Machine-wide, and the one setting the guest has to restart to pick up. The
    # restart is deliberately not forced here: Setup cannot resume a SetupComplete.cmd
    # that reboots, and the guest gets one soon enough.
    Set-WinSystemLocale -SystemLocale "$Locale"
    Set-TimeZone -Id "$TimeZone"
    Write-PayloadLog "System locale $Locale (takes effect at next restart), time zone $TimeZone" -Tag "o.k."

    # Read the default profile back - intl.cpl reports nothing, and this is the hive
    # every later user is cloned from, so it is the setting worth proving.
    `$defaultHive = Join-Path -Path `$env:SystemDrive -ChildPath "Users\Default\NTUSER.DAT"
    if (Test-Path -Path `$defaultHive) {
        & reg.exe load "HKLM\GoldLocaleVerify" `$defaultHive | Out-Null
        if (`$LASTEXITCODE -eq 0) {
            try {
                `$applied = (Get-ItemProperty -Path "HKLM:\GoldLocaleVerify\Control Panel\International" -Name "LocaleName" -ErrorAction SilentlyContinue).LocaleName
                if (`$applied) { Write-PayloadLog "Default profile locale is `$applied" -Tag "get" }
                else { Write-PayloadLog "Default profile carries no LocaleName" -Tag "warn" }
            }
            finally {
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                & reg.exe unload "HKLM\GoldLocaleVerify" | Out-Null
            }
        }
    }

    "$Locale|$inputLocale|$TimeZone|`$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')" | Out-File -FilePath `$marker -Encoding ascii
}
catch {
    Write-PayloadLog "Failed: `$(`$_.Exception.Message)" -Tag "error"
}
finally {
    # The gold carries no boot-time scripts once this has run.
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name "NewVhdxGoldLocale" -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path -Path `$env:WINDIR -ChildPath "OEM\SetupComplete2.cmd") -Force -ErrorAction SilentlyContinue
    Remove-Item -Path `$intlPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path -Path `$scriptsDir -ChildPath "SetupComplete.cmd") -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path -Path `$scriptsDir -ChildPath "Set-GoldLocale.ps1") -Force -ErrorAction SilentlyContinue
    Write-PayloadLog "==================== End ====================" -Tag "end"
}
"@

    $launcher = ("@echo off", "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%WINDIR%\Setup\Scripts\Set-GoldLocale.ps1""", "exit /b 0", "") -join "`r`n"

    $ascii = New-Object System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllText((Join-Path -Path $scriptsDir -ChildPath "gold-locale.xml"), $intlXml, $ascii)
    [System.IO.File]::WriteAllText((Join-Path -Path $scriptsDir -ChildPath "Set-GoldLocale.ps1"), $payload, $ascii)
    [System.IO.File]::WriteAllText((Join-Path -Path $scriptsDir -ChildPath "SetupComplete.cmd"), $launcher, $ascii)
    [System.IO.File]::WriteAllText((Join-Path -Path $oemDir -ChildPath "SetupComplete2.cmd"), $launcher, $ascii)

    # Third entry point, in case the platform lands its own SetupComplete.cmd on top
    # of ours and does not call SetupComplete2. RunOnce fires at the first
    # administrator logon; the marker keeps it from repeating work already done.
    $softwareHive = Join-Path -Path $MountRoot -ChildPath "Windows\System32\config\SOFTWARE"
    if (Test-Path -Path $softwareHive) {
        $hiveRoot = "HKLM\OfflineGoldLocale"
        & reg.exe load $hiveRoot $softwareHive | Out-Null
        if ($LASTEXITCODE -eq 0) {
            try {
                $runOnce = "$hiveRoot\Microsoft\Windows\CurrentVersion\RunOnce"
                $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\Set-GoldLocale.ps1"'
                & reg.exe add $runOnce /v "NewVhdxGoldLocale" /t REG_EXPAND_SZ /d $command /f | Out-Null
            }
            finally {
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                & reg.exe unload $hiveRoot | Out-Null
            }
        }
    }

    Write-Log "Locale payload: $Locale / $inputLocale / $TimeZone" -Tag "Run"
}

function Set-OfflineImageCustomization {
    param(
        [string]$VhdPath,
        [string]$Target,
        [string]$Locale,
        [string]$KeyboardLayout,
        [string]$TimeZone,
        [string]$AvmaKey,
        [bool]$RemovePantherUnattend,
        [bool]$IsClient = $false,
        [bool]$IsServerCore = $false,
        [bool]$EnableRdp = $true,
        [bool]$EnablePing = $true,
        [bool]$SuppressServerManagerAtLogon = $false,
        [bool]$SuppressWelcomeExperience = $false,
        [bool]$SuppressFirstSignInAnimation = $false,
        [bool]$BlockSignInInputMethods = $false,
        [bool]$PreventDeviceEncryption = $false,
        [bool]$SetVmPowerPlan = $false,
        [bool]$ConfigureEdge = $false
    )

    Write-Log "Offline customization on '$VhdPath'" -Tag "Run"

    $mounted = $false
    try {
        $mountRoot = Get-MountedOsRoot -VhdPath $VhdPath
        $mounted = $true

        if ($RemovePantherUnattend) {
            $leftoverUnattend = Join-Path -Path $mountRoot -ChildPath "Windows\Panther\unattend.xml"
            if (Test-Path -Path $leftoverUnattend) {
                Write-Log "Removing leftover Panther\unattend.xml" -Tag "Run"
                Remove-Item -Path $leftoverUnattend -Force -ErrorAction SilentlyContinue
            }

            # Also clear any Deploy answer file and UnattendFile registry pointer left
            # by older gold builds that used sysprep /unattend:C:\Windows\Deploy\...
            $deployUnattend = Join-Path -Path $mountRoot -ChildPath "Windows\Deploy\unattend.xml"
            if (Test-Path -Path $deployUnattend) {
                Write-Log "Removing leftover Deploy\unattend.xml" -Tag "Run"
                Remove-Item -Path $deployUnattend -Force -ErrorAction SilentlyContinue
            }

            $systemHive = Join-Path -Path $mountRoot -ChildPath "Windows\System32\config\SYSTEM"
            if (Test-Path -Path $systemHive) {
                $hiveRoot = "HKLM\OfflineClearUnattend"
                & reg.exe load $hiveRoot $systemHive | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    try {
                        # reg.exe returns non-zero when the value was not there, which is
                        # the normal case for a gold this script built. Saying "cleared"
                        # either way claims work that did not happen.
                        & reg.exe delete "$hiveRoot\Setup" /v UnattendFile /f 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            Write-Log "Cleared offline UnattendFile registry pointer" -Tag "Run"
                        }
                        else {
                            Write-Log "No offline UnattendFile registry pointer to clear" -Tag "Debug"
                        }
                    }
                    finally {
                        [gc]::Collect()
                        [gc]::WaitForPendingFinalizers()
                        & reg.exe unload $hiveRoot | Out-Null
                    }
                }
            }
        }

        # DISM international servicing is Microsoft's supported path for offline
        # image locale configuration. /Set-UserLocale (standards & formats),
        # /Set-SysLocale (non-Unicode system locale) and /Set-InputLocale (keyboard)
        # write the same default-user and SYSTEM\Nls locations the previous manual
        # reg.exe hive edits targeted, but via the supported API. Display (UI)
        # language is intentionally left unchanged: the base image ships en-US and
        # no language-pack source is added, so /Set-UILang is omitted.
        #
        # Azure Local is the exception: its VM provisioning delivers its own answer
        # file on two DVDs at create time, and the International-Core settings in it
        # run during specialize / oobeSystem, after everything DISM wrote here. The
        # bake was being overwritten on every deployed VM, so on that target the
        # locale, keyboard and time zone are applied at first boot instead.
        $inputLocale = Get-InputLocaleId -KeyboardLayout $KeyboardLayout
        if ($Target -eq "AzureLocal") {
            Write-AzureLocalLocalePayload -MountRoot $mountRoot -Locale $Locale `
                -KeyboardLayout $KeyboardLayout -TimeZone $TimeZone
        }
        else {
            Write-Log "Baking locale via DISM ($Locale / $inputLocale)" -Tag "Run"
            Invoke-Dism -Arguments @(
                "/Image:$mountRoot",
                "/Set-UserLocale:$Locale",
                "/Set-SysLocale:$Locale",
                "/Set-InputLocale:$inputLocale"
            )
        }

        if ($BlockSignInInputMethods) {
            Set-OfflineSignInKeyboardPolicy -MountRoot $mountRoot
        }
        if ($ConfigureEdge) {
            # Server Core has no Edge to manage. The policy key would be inert rather than
            # harmful, but a gold that carries settings for a browser it cannot run is a
            # gold that lies about itself.
            if ($IsServerCore) {
                Write-Log "Server Core - no Edge to configure" -Tag "Debug"
            }
            else {
                Set-OfflineEdgePolicy -MountRoot $mountRoot
            }
        }
        Set-OfflineRdpAndFirewall -MountRoot $mountRoot -EnableRdp $EnableRdp -EnablePing $EnablePing

        if ($SuppressServerManagerAtLogon -and -not $IsClient) {
            Set-OfflineServerManagerPolicy -MountRoot $mountRoot
        }
        elseif ($IsClient) {
            Write-Log "Client image - Server Manager suppression not applicable" -Tag "Debug"
        }

        if ($IsClient) {
            if ($SuppressWelcomeExperience) {
                Set-OfflineWelcomeExperiencePolicy -MountRoot $mountRoot
            }
            if ($SuppressFirstSignInAnimation) {
                Set-OfflineFirstSignInAnimationPolicy -MountRoot $mountRoot
            }
            if ($PreventDeviceEncryption) {
                Set-OfflineDeviceEncryptionPolicy -MountRoot $mountRoot
            }
            if ($SetVmPowerPlan) {
                Set-OfflinePowerPolicy -MountRoot $mountRoot
            }
        }
        else {
            # Device encryption is a client feature; Server never turns BitLocker on by
            # itself, so the opt-out has nothing to opt out of here.
            # Server has its own power defaults - High performance already, display off at
            # ten minutes - so the client power tick has nothing to do here either.
            Write-Log "Server image - desktop tweaks not applicable" -Tag "Debug"
        }

        if ($Target -ne "AzureLocal") {
            Write-Log "Setting default time zone to '$TimeZone' via DISM" -Tag "Run"
            Invoke-Dism -Arguments @("/Image:$mountRoot", "/Set-TimeZone:$TimeZone")
        }

        if (-not [string]::IsNullOrWhiteSpace($AvmaKey)) {
            Write-Log "Baking AVMA product key into the image" -Tag "Run"
            Invoke-Dism -Arguments @("/Image:$mountRoot", "/Set-ProductKey:$AvmaKey")
        }
    }
    finally {
        if ($mounted) {
            Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------[ Build One Image ]---------------------------
function New-WindowsVhdxImage {
    param(
        [string]$VhdPath,
        [int]$ImageIndex,
        [string]$WimPath,
        [string]$Target,
        [string]$Locale,
        [string]$KeyboardLayout,
        [string]$UiLanguage,
        [string]$TimeZone,
        [int]$VhdSizeGB,
        [string]$VhdType,
        [string]$ProductKey,
        [string]$TempBootUnattendContent,
        [string]$EditionUpgrade = ""
    )

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Stop"
    $buildSucceeded = $false

    try {
        New-ImageVhdx -VhdPath $VhdPath -SizeBytes ([int64]$VhdSizeGB * 1GB) -VhdType $VhdType
        Initialize-VhdxLayout -VhdPath $VhdPath
        Install-WindowsImageToVhdx -WimPath $WimPath -ImageIndex $ImageIndex

        if (-not [string]::IsNullOrWhiteSpace($EditionUpgrade)) {
            # Asked here, while the image is already mounted and before the temporary VM
            # has cost twenty minutes. An image that cannot become the target edition
            # will not become it after a sysprep either, so there is nothing to gain by
            # finding out later.
            $editionInfo = $script:VirtualEditionCatalog[$EditionUpgrade]
            $script:EditionUpgradeTarget = Get-VirtualEditionTarget -OsRoot "W:\" -EditionUpgrade $EditionUpgrade
            $targetEdition = $script:EditionUpgradeTarget
            if ([string]::IsNullOrWhiteSpace($targetEdition)) {
                throw "Index $ImageIndex cannot be upgraded to $($editionInfo.DisplayName) - DISM lists no matching target for it (can become: $(Get-TargetEditionSummary -OsRoot 'W:\')). $($editionInfo.SourceHint)"
            }
            Write-Log "Index $ImageIndex can become '$targetEdition' - continuing" -Tag "Ok"
        }

        # HyperV gold images no longer bake a sysprep /unattend Deploy file.
        # Build-Vms.ps1 injects the per-VM Panther\unattend.xml at provision time.
        # Locales / RDP / firewall are applied offline after generalize.

        Set-TempBootUnattend -Content $TempBootUnattendContent
        Set-BootFiles

        Dismount-VHD -Path $VhdPath
        $buildSucceeded = $true
        Write-Log "Finished apply phase for '$VhdPath'" -Tag "Ok"
    }
    catch {
        Write-Log "Build failed for '$VhdPath': $($_.Exception.Message)" -Tag "Error"
        try {
            Dismount-VHD -Path $VhdPath -ErrorAction SilentlyContinue
            Write-Log "Dismounted '$VhdPath' after failure" -Tag "Debug"
        }
        catch {
            Write-Log "Cleanup dismount failed: '$VhdPath'" -Tag "Debug"
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }

    return $buildSucceeded
}

# ---------------------------[ Sysprep Generalize ]---------------------------
function Wait-VmShutdown {
    param(
        [string]$VmName,
        [int]$TimeoutMinutes = 45
    )

    Write-Log "Waiting $TimeoutMinutes min for '$VmName' to stop" -Tag "Run"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {
        $virtualMachine = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($null -eq $virtualMachine) {
            Write-Log "VM '$VmName' no longer exists while waiting" -Tag "Error"
            return $false
        }

        if ($virtualMachine.State -eq "Off") {
            Write-Log "VM '$VmName' has shut down (sysprep complete)" -Tag "Ok"
            return $true
        }

        Start-Sleep -Seconds 15
    }

    Write-Log "Timed out waiting for '$VmName' to shut down" -Tag "Error"
    return $false
}

function Get-SysprepVmRootPath {
    <#
      Temporary generalize VMs get their own '<Hyper-V default VM path>\sysprep'
      folder instead of landing in the host default root next to real VMs.
      Falls back to the script folder when Get-VMHost is unavailable.
    #>
    $root = ""
    try {
        $root = [string](Get-VMHost -ErrorAction Stop).VirtualMachinePath
    }
    catch {
        Write-Log "Could not query Get-VMHost for the default VM path: $($_.Exception.Message)" -Tag "Warn"
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = $PSScriptRoot
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = (Get-Location).Path
    }

    # Concatenate rather than Join-Path: Join-Path throws "Cannot find drive" when
    # the host default VM path sits on a drive that is not currently present.
    return ($root.TrimEnd('\', '/') + "\sysprep")
}

function Remove-TemporaryVm {
    param(
        [string]$VmName,
        [string]$VmRoot
    )

    $virtualMachine = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($null -ne $virtualMachine) {
        if ($virtualMachine.State -ne "Off") {
            Write-Log "Stopping temporary VM '$VmName'" -Tag "Run"
            Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
        }

        Write-Log "Removing temporary VM '$VmName'" -Tag "Run"
        Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($VmRoot)) {
        return
    }

    # Remove-VM deletes the configuration but leaves the folder tree behind.
    # The gold VHDX lives in -OutputDirectory and is only attached, never moved
    # here - but refuse to recurse anyway if a disk somehow sits under the folder.
    $vmFolder = Join-Path -Path $VmRoot -ChildPath $VmName
    if (Test-Path -LiteralPath $vmFolder) {
        $disks = @(Get-ChildItem -LiteralPath $vmFolder -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @(".vhdx", ".vhd", ".vhds", ".avhdx") })
        if ($disks.Count -gt 0) {
            Write-Log "Keeping '$vmFolder' - $($disks.Count) disk(s) left" -Tag "Info"
        }
        else {
            Remove-Item -LiteralPath $vmFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Drop the sysprep\ folder itself once the last temporary VM is gone.
    if (Test-Path -LiteralPath $VmRoot) {
        $left = @(Get-ChildItem -LiteralPath $VmRoot -Force -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) {
            Remove-Item -LiteralPath $VmRoot -Force -ErrorAction SilentlyContinue
        }
    }
}

function Convert-ToGeneralizedImage {
    param(
        [string]$VhdPath,
        [bool]$EnableTpm
    )

    $vmName = "sysprep-$([System.IO.Path]::GetFileNameWithoutExtension($VhdPath))"
    $vmRoot = Get-SysprepVmRootPath
    Write-Log "Generalizing '$VhdPath' in VM '$vmName'" -Tag "Info"

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Stop"
    $generalizeSucceeded = $false

    try {
        Remove-TemporaryVm -VmName $vmName -VmRoot $vmRoot

        if (-not (Test-Path -LiteralPath $vmRoot)) {
            New-Item -ItemType Directory -Path $vmRoot -Force | Out-Null
        }

        Write-Log "Creating temporary Generation 2 VM '$vmName'" -Tag "Run"
        New-VM -Name $vmName -Generation 2 -MemoryStartupBytes 4GB -VHDPath $VhdPath -Path $vmRoot | Out-Null
        Set-VM -Name $vmName -ProcessorCount 2

        # New-VM without -SwitchName already leaves the adapter disconnected, which is the
        # posture we want - but this VM must not reach Windows Update at all, because an
        # app updated in the background between boot and sysprep is the documented way to
        # make generalize fail. Removing the adapter means a later edit cannot connect one
        # by accident.
        $adapters = @(Get-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue)
        if ($adapters.Count -gt 0) {
            Remove-VMNetworkAdapter -VMName $vmName -ErrorAction SilentlyContinue
            Write-Log "Removed $($adapters.Count) adapter(s) - VM stays offline" -Tag "Run"
        }

        Write-Log "Enabling Secure Boot with the Microsoft UEFI template" -Tag "Run"
        Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftWindows"

        if ($EnableTpm) {
            Write-Log "Enabling vTPM for client image sysprep VM" -Tag "Run"
            try {
                Set-VMKeyProtector -VMName $vmName -NewLocalKeyProtector -ErrorAction Stop
                Enable-VMTPM -VMName $vmName -ErrorAction Stop
            }
            catch {
                Write-Log "Could not enable vTPM - continuing without it: $($_.Exception.Message)" -Tag "Warn"
            }
        }

        Write-Log "Starting temporary VM to run sysprep" -Tag "Run"
        Start-VM -Name $vmName | Out-Null

        if (-not (Wait-VmShutdown -VmName $vmName)) {
            throw "Sysprep did not complete before the timeout"
        }

        $generalizeSucceeded = $true
        Write-Log "Generalized image ready at '$VhdPath'" -Tag "Ok"
    }
    catch {
        Write-Log "Generalize failed for '$VhdPath': $($_.Exception.Message)" -Tag "Error"
    }
    finally {
        Remove-TemporaryVm -VmName $vmName -VmRoot $vmRoot
        $ErrorActionPreference = $previousErrorAction
    }

    return $generalizeSucceeded
}

# ---------------------------[ Validation ]---------------------------
function Test-RequiredCommand {
    $requiredCommands = @("New-VHD", "Mount-VHD", "Dismount-VHD", "New-VM", "Start-VM", "Set-VMFirmware")

    foreach ($requiredCommand in $requiredCommands) {
        if (-not (Get-Command -Name $requiredCommand -ErrorAction SilentlyContinue)) {
            return $false
        }
    }

    return $true
}

function Test-IsServerOperatingSystem {
    $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
    return ($operatingSystem.ProductType -ne 1)
}

function Install-HyperVRole {
    Write-Log "Hyper-V cmdlets missing - installing the Hyper-V role" -Tag "Run"

    if (Test-IsServerOperatingSystem) {
        Write-Log "Detected a server operating system" -Tag "Debug"
        $featureResult = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -ErrorAction Stop
        Write-Log "Installed Hyper-V role on server" -Tag "Ok"

        if ($featureResult.RestartNeeded -eq "Yes") {
            Write-Log "Hyper-V role installed - reboot, then run this script again" -Tag "Error"
            Complete-Script -ExitCode 2
        }
        return
    }

    Write-Log "Detected a client operating system" -Tag "Debug"
    $featureName = "Microsoft-Hyper-V-All"
    $featureResult = Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart -ErrorAction Stop
    Write-Log "Enabled optional feature '$featureName'" -Tag "Ok"

    if ($featureResult.RestartNeeded) {
        Write-Log "Hyper-V feature enabled - reboot, then run this script again" -Tag "Error"
        Complete-Script -ExitCode 2
    }
}

function Confirm-HyperVCmdletAvailable {
    if (Test-RequiredCommand) {
        return $true
    }

    try {
        Install-HyperVRole
    }
    catch {
        Write-Log "Failed to install the Hyper-V role: $($_.Exception.Message)" -Tag "Error"
        return $false
    }

    Import-Module -Name Hyper-V -ErrorAction SilentlyContinue

    if (Test-RequiredCommand) {
        Write-Log "Hyper-V cmdlets are now available" -Tag "Ok"
        return $true
    }

    Write-Log "Hyper-V cmdlets still unavailable after install - reboot, then retry" -Tag "Error"
    return $false
}

function Test-Prerequisite {
    <#
      Quiet preflight: one Success line when everything passes, otherwise only the
      failing check is printed.
    #>
    param([string]$WimPath)

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
    if (-not $currentPrincipal.IsInRole($adminRole)) {
        Write-Log "This script must run in an elevated session (Administrator)" -Tag "Error"
        return $false
    }

    if (-not (Confirm-HyperVCmdletAvailable)) {
        return $false
    }

    if (-not (Get-Command -Name "Expand-WindowsImage" -ErrorAction SilentlyContinue)) {
        Write-Log "Required command 'Expand-WindowsImage' is not available (DISM module missing)" -Tag "Error"
        return $false
    }

    if (-not (Test-Path -Path $WimPath)) {
        Write-Log "Windows image not found at '$WimPath'" -Tag "Error"
        return $false
    }

    Write-Log "Preflight passed - elevation, Hyper-V, DISM, image" -Tag "Ok"
    return $true
}

# ---------------------------[ Image Path Resolver ]---------------------------
function Resolve-WindowsImagePath {
    param([string]$DriveLetter)

    $normalizedDrive = $DriveLetter.TrimEnd("\")
    $sourcesPath = Join-Path -Path $normalizedDrive -ChildPath "sources"

    $wimCandidate = Join-Path -Path $sourcesPath -ChildPath "install.wim"
    if (Test-Path -Path $wimCandidate) {
        Write-Log "Found install.wim" -Tag "Debug"
        return $wimCandidate
    }

    $esdCandidate = Join-Path -Path $sourcesPath -ChildPath "install.esd"
    if (Test-Path -Path $esdCandidate) {
        Write-Log "Found install.esd" -Tag "Debug"
        return $esdCandidate
    }

    Write-Log "Searching '$sourcesPath' for an install image" -Tag "Debug"
    $foundImage = Get-ChildItem -Path $sourcesPath -Include "install.wim", "install.esd" `
        -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($null -ne $foundImage) {
        Write-Log "Found image at '$($foundImage.FullName)'" -Tag "Debug"
        return $foundImage.FullName
    }

    return ""
}

function Get-ImageLanguageTag {
    # Get-WindowsImage without -Index returns summary objects only (ImageIndex,
    # ImageName, ImageDescription, ImageSize) - no Languages. Only the per-index
    # call carries language metadata. Returns "" when DISM cannot say, so callers
    # report "unknown" instead of guessing en-US on a de-DE ISO.
    param(
        [string]$WimPath,
        [int]$ImageIndex
    )

    try {
        $detail = Get-WindowsImage -ImagePath $WimPath -Index $ImageIndex -ErrorAction Stop
    }
    catch {
        Write-Log "Index $ImageIndex language: $($_.Exception.Message)" -Tag "Debug"
        return ""
    }

    if ($detail.Languages -and $detail.Languages.Count -gt 0) {
        $defaultIndex = 0
        if ($null -ne $detail.DefaultLanguageIndex) {
            $candidate = [int]$detail.DefaultLanguageIndex
            if ($candidate -ge 0 -and $candidate -lt $detail.Languages.Count) {
                $defaultIndex = $candidate
            }
        }
        return [string]$detail.Languages[$defaultIndex]
    }

    if ($detail.Language) {
        return [string]$detail.Language
    }

    return ""
}

function Resolve-SelectedImageIndexes {
    param(
        [int[]]$ImageIndexes,
        [string]$Build,
        [int]$CoreImageIndex,
        [int]$GuiImageIndex
    )

    if ($ImageIndexes -and $ImageIndexes.Count -gt 0) {
        return @($ImageIndexes | Select-Object -Unique)
    }

    $resolved = @()
    $buildCore = ($Build -eq "Both") -or ($Build -eq "Core")
    $buildGui = ($Build -eq "Both") -or ($Build -eq "Gui")

    if ($buildCore) {
        if ($CoreImageIndex -lt 1) {
            throw "-Build '$Build' requires a valid -CoreImageIndex (1-99) or use -ImageIndexes"
        }
        $resolved += $CoreImageIndex
    }
    if ($buildGui) {
        if ($GuiImageIndex -lt 1) {
            throw "-Build '$Build' requires a valid -GuiImageIndex (1-99) or use -ImageIndexes"
        }
        $resolved += $GuiImageIndex
    }

    return @($resolved | Select-Object -Unique)
}

function Invoke-ImageBuildPipeline {
    param(
        [string]$VhdPath,
        [int]$ImageIndex,
        [string]$ImageName,
        [string]$WimPath,
        [string]$Target,
        [string]$Locale,
        [string]$KeyboardLayout,
        [string]$UiLanguage,
        [string]$TimeZone,
        [int]$VhdSizeGB,
        [string]$VhdType,
        [bool]$Generalize,
        [bool]$EnableRdp = $true,
        [bool]$EnablePing = $true,
        [bool]$SuppressServerManagerAtLogon = $false,
        [bool]$SuppressWelcomeExperience = $false,
        [bool]$SuppressFirstSignInAnimation = $false,
        [bool]$BlockSignInInputMethods = $false,
        [bool]$PreventDeviceEncryption = $false,
        [bool]$SetVmPowerPlan = $false,
        [bool]$ConfigureEdge = $false,
        [string]$EditionUpgrade = ""
    )

    $isDatacenter = Test-IsServerDatacenterImage -ImageName $ImageName
    $isClient = Test-IsClientImage -ImageName $ImageName
    $isServerCore = Test-IsServerCoreImage -ImageName $ImageName
    $avmaKey = ""
    $productKey = ""

    $serverYear = ""
    if (([string]$ImageName) -match "(?i)windows\s+server\s+(\d{4})") {
        $serverYear = $Matches[1]
    }

    if ($EditionUpgrade -eq "AzureEdition") {
        # Keyed for the SKU the gold ships as, not the index it was applied from -
        # the key is baked by Set-OfflineImageCustomization, which runs after the
        # edition change, so it lands on an image that already is Azure Edition.
        $avmaKey = Get-AvmaKey -Year "2025" -Edition "AzureEdition"
        Write-Log "Azure Edition build; its AVMA key will be applied offline" -Tag "Info"
    }
    elseif ($isDatacenter) {
        $avmaKey = Get-AvmaKey -Year $serverYear -Edition "Datacenter"
        if ($avmaKey -ne "") {
            if ($Target -eq "HyperV") {
                $productKey = $avmaKey
            }
            Write-Log "$serverYear Datacenter - AVMA key applied offline" -Tag "Info"
        }
        else {
            Write-Log "No AVMA key for Datacenter '$ImageName'" -Tag "Info"
        }
    }
    elseif (-not $isClient -and ([string]$ImageName) -match "(?i)\bstandard\b") {
        $avmaKey = Get-AvmaKey -Year $serverYear -Edition "Standard"
        if ($avmaKey -ne "") {
            Write-Log "$serverYear Standard - AVMA key applied offline" -Tag "Info"
        }
        else {
            Write-Log "No AVMA key for Standard '$ImageName'" -Tag "Info"
        }
    }
    elseif (-not $isClient) {
        # Covers Azure Local media and anything else server-shaped that is neither
        # Standard nor Datacenter - those activate through their own channels.
        Write-Log "Server image without a matching AVMA key - none applied" -Tag "Info"
    }
    else {
        # AVMA is a Windows Server Datacenter mechanism. Saying a client image "skipped"
        # it implies it was ever in the running.
        Write-Log "Client image - AVMA does not apply" -Tag "Debug"
    }

    $tempBootUnattend = Get-TempBootUnattendContent -Target $Target

    $built = New-WindowsVhdxImage -VhdPath $VhdPath -ImageIndex $ImageIndex -WimPath $WimPath `
        -Target $Target -Locale $Locale -KeyboardLayout $KeyboardLayout -UiLanguage $UiLanguage `
        -TimeZone $TimeZone -VhdSizeGB $VhdSizeGB -VhdType $VhdType -ProductKey $productKey `
        -TempBootUnattendContent $tempBootUnattend -EditionUpgrade $EditionUpgrade

    if (-not $built) {
        return $false
    }

    if ($Generalize) {
        if (-not (Convert-ToGeneralizedImage -VhdPath $VhdPath -EnableTpm:$isClient)) {
            return $false
        }
    }
    else {
        Write-Log "SkipSysprep - not generalizing '$VhdPath'" -Tag "Info"
    }

    if (-not [string]::IsNullOrWhiteSpace($EditionUpgrade)) {
        if (-not (Convert-ToVirtualEdition -VhdPath $VhdPath -EditionUpgrade $EditionUpgrade)) {
            # The disk carries the upgraded edition's name and does not carry the edition. Leaving it
            # on disk would hand Build-Vms or Azure Local a gold that lies about itself,
            # so it goes.
            Write-Log "Deleting '$VhdPath' - a gold named for an edition it does not carry is worse than no gold" -Tag "Warn"
            Remove-Item -LiteralPath $VhdPath -Force -ErrorAction SilentlyContinue
            return $false
        }
    }

    $removePanther = $true
    try {
        Set-OfflineImageCustomization -VhdPath $VhdPath -Target $Target -Locale $Locale `
            -KeyboardLayout $KeyboardLayout -TimeZone $TimeZone -AvmaKey $avmaKey `
            -RemovePantherUnattend:$removePanther -IsClient $isClient -IsServerCore $isServerCore `
            -EnableRdp $EnableRdp -EnablePing $EnablePing `
            -SuppressServerManagerAtLogon $SuppressServerManagerAtLogon `
            -SuppressWelcomeExperience $SuppressWelcomeExperience `
            -SuppressFirstSignInAnimation $SuppressFirstSignInAnimation `
            -BlockSignInInputMethods $BlockSignInInputMethods `
            -PreventDeviceEncryption $PreventDeviceEncryption `
            -SetVmPowerPlan $SetVmPowerPlan `
            -ConfigureEdge $ConfigureEdge
    }
    catch {
        Write-Log "Failed to apply offline customization to '$VhdPath': $($_.Exception.Message)" -Tag "Error"
        return $false
    }

    return $true
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "$env:COMPUTERNAME | $env:USERNAME | $scriptName" -Tag "Info"
Write-Log "Log file: $logFile" -Tag "Info"

# The locale catalog decides what -Locale/-KeyboardLayout may say, so it loads
# before either is looked at. Empty means "the catalog's default" - the parameter
# cannot name it earlier because the default itself comes from locales.json.
Import-LocaleCatalogFile
if ([string]::IsNullOrWhiteSpace($Locale)) { $Locale = $script:DefaultLocale }
if ([string]::IsNullOrWhiteSpace($KeyboardLayout)) { $KeyboardLayout = $script:DefaultLocale }
foreach ($localeArgument in @(@{ Name = "-Locale"; Value = $Locale }, @{ Name = "-KeyboardLayout"; Value = $KeyboardLayout })) {
    if (-not $script:LocaleCatalog.Contains($localeArgument.Value)) {
        Write-Log "$($localeArgument.Name) '$($localeArgument.Value)' is not in the locale catalog ($($script:LocaleCatalog.Count) locales loaded, default $($script:DefaultLocale))" -Tag "Error"
        Complete-Script -ExitCode 1
    }
}

$availableImages = @()
$wimPath = ""

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path -Path $PSScriptRoot -ChildPath "vhdx"
}

$hasImageSelection = (
    ($ImageIndexes -and $ImageIndexes.Count -gt 0) -or
    ($CoreImageIndex -ge 1) -or
    ($GuiImageIndex -ge 1) -or
    (@($MultiSessionImageIndexes).Count -gt 0) -or
    (@($AzureEditionImageIndexes).Count -gt 0)
)

$needsInteractive = (
    ([string]::IsNullOrWhiteSpace($IsoDrive) -and [string]::IsNullOrWhiteSpace($IsoPath)) -or
    (-not $hasImageSelection)
)

if ($needsInteractive) {
    Write-Log "Starting interactive configuration menu" -Tag "Info"
    $config = Start-InteractiveConfiguration -CurrentTarget $Target -CurrentLocale $Locale `
        -CurrentKeyboard $KeyboardLayout -CurrentUiLanguage $UiLanguage -CurrentTimeZone $TimeZone `
        -CurrentVhdSizeGB $VhdSizeGB -CurrentVhdType $VhdType -CurrentOutputDirectory $OutputDirectory `
        -CurrentEnableRdp $EnableRdp -CurrentEnablePing $EnablePing `
        -CurrentSuppressServerManagerAtLogon $SuppressServerManagerAtLogon `
        -CurrentSuppressWelcomeExperience $SuppressWelcomeExperience `
        -CurrentSuppressFirstSignInAnimation $SuppressFirstSignInAnimation `
        -CurrentBlockSignInInputMethods $BlockSignInInputMethods `
        -CurrentPreventDeviceEncryption $PreventDeviceEncryption `
        -CurrentSetVmPowerPlan $SetVmPowerPlan `
        -CurrentConfigureEdge $ConfigureEdge `
        -CurrentMultiSessionImageIndexes @($MultiSessionImageIndexes) `
        -CurrentAzureEditionImageIndexes @($AzureEditionImageIndexes)

    if ($null -eq $config) {
        Write-Log "Cancelled at the configuration menu - nothing was built" -Tag "Info"
        Complete-Script -ExitCode 1
    }

    # A Linux gold shares the output directory with the Windows path and nothing else -
    # no WIM, no image index, no unattend, no sysprep. It runs here and the script ends.
    if ($config.OsFamily -eq "Linux") {
        if (Invoke-LinuxGoldRun -Config $config) { Complete-Script -ExitCode 0 }
        Complete-Script -ExitCode 1
    }

    $IsoDrive = $config.IsoDrive
    if (-not [string]::IsNullOrWhiteSpace($config.IsoPath)) {
        $IsoPath = $config.IsoPath
    }
    $OutputDirectory = $config.OutputDirectory
    $Target = $config.Target
    $ImageIndexes = $config.ImageIndexes
    $Locale = $config.Locale
    $KeyboardLayout = $config.KeyboardLayout
    $UiLanguage = $config.UiLanguage
    $TimeZone = $config.TimeZone
    $VhdSizeGB = $config.VhdSizeGB
    $VhdType = $config.VhdType
    $wimPath = $config.WimPath
    $availableImages = @($config.AvailableImages)
    $EnableRdp = $config.EnableRdp
    $EnablePing = $config.EnablePing
    $SuppressServerManagerAtLogon = $config.SuppressServerManagerAtLogon
    $SuppressWelcomeExperience = $config.SuppressWelcomeExperience
    $SuppressFirstSignInAnimation = $config.SuppressFirstSignInAnimation
    $BlockSignInInputMethods = $config.BlockSignInInputMethods
    $PreventDeviceEncryption = $config.PreventDeviceEncryption
    $SetVmPowerPlan = $config.SetVmPowerPlan
    $ConfigureEdge = $config.ConfigureEdge
    $MultiSessionImageIndexes = @($config.MultiSessionImageIndexes)
    $AzureEditionImageIndexes = @($config.AzureEditionImageIndexes)
}

if ([string]::IsNullOrWhiteSpace($IsoDrive) -and -not [string]::IsNullOrWhiteSpace($IsoPath)) {
    try {
        $IsoDrive = Mount-WindowsIsoFile -IsoFilePath $IsoPath
    }
    catch {
        Write-Log "Failed to mount ISO '$IsoPath': $($_.Exception.Message)" -Tag "Error"
        Complete-Script -ExitCode 1
    }
}

if ($wimPath -eq "") {
    $wimPath = Resolve-WindowsImagePath -DriveLetter $IsoDrive
}
if ($wimPath -eq "") {
    Write-Log "No install.wim or install.esd found under '$($IsoDrive.TrimEnd('\'))\sources'" -Tag "Error"
    Write-Log "Verify the ISO is mounted and -IsoDrive points to its drive letter" -Tag "Error"
    Complete-Script -ExitCode 1
}
Write-Log "Using Windows image '$wimPath'" -Tag "Info"

if (-not (Test-Prerequisite -WimPath $wimPath)) {
    Complete-Script -ExitCode 1
}

if (-not (Test-Path -Path $OutputDirectory)) {
    Write-Log "Creating output directory '$OutputDirectory'" -Tag "Run"
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

if ($availableImages.Count -eq 0) {
    $availableImages = @(Get-WindowsImage -ImagePath $wimPath)
}
Write-Log "$($availableImages.Count) image(s) in '$wimPath'" -Tag "Get"

# A run may carry only virtual edition builds. Resolve-SelectedImageIndexes falls back
# to -Build/-CoreImageIndex/-GuiImageIndex when -ImageIndexes is empty and would
# demand them, so it is only consulted when a plain selection was actually given.
$selectedIndexes = @()
$hasPlainSelection = (
    ($ImageIndexes -and $ImageIndexes.Count -gt 0) -or
    ($CoreImageIndex -ge 1) -or
    ($GuiImageIndex -ge 1)
)
if ($hasPlainSelection) {
    try {
        $selectedIndexes = Resolve-SelectedImageIndexes -ImageIndexes $ImageIndexes -Build $Build `
            -CoreImageIndex $CoreImageIndex -GuiImageIndex $GuiImageIndex
    }
    catch {
        Write-Log $_.Exception.Message -Tag "Error"
        Complete-Script -ExitCode 1
    }
}

if ($selectedIndexes.Count -eq 0 -and @($MultiSessionImageIndexes).Count -eq 0 -and @($AzureEditionImageIndexes).Count -eq 0) {
    Write-Log "No image indexes selected to build" -Tag "Error"
    Complete-Script -ExitCode 1
}

# One entry per gold that leaves this run. A plain index and a virtual edition
# upgrade of the same index are two entries on purpose: the gold names differ
# (w11-pro / w11-enterprise-ms, ws2025-standard-core / ws2025-datacenter-az-core),
# so one run can produce both from one index.
$buildSpecs = @()
foreach ($imageIndex in $selectedIndexes) {
    $buildSpecs += [PSCustomObject]@{ ImageIndex = [int]$imageIndex; EditionUpgrade = "" }
}
foreach ($imageIndex in @(@($MultiSessionImageIndexes) | Sort-Object -Unique)) {
    $buildSpecs += [PSCustomObject]@{ ImageIndex = [int]$imageIndex; EditionUpgrade = "MultiSession" }
}
foreach ($imageIndex in @(@($AzureEditionImageIndexes) | Sort-Object -Unique)) {
    $buildSpecs += [PSCustomObject]@{ ImageIndex = [int]$imageIndex; EditionUpgrade = "AzureEdition" }
}
$buildIndexes = @($buildSpecs | ForEach-Object { $_.ImageIndex } | Sort-Object -Unique)

Write-Log "$Target | $Locale | $KeyboardLayout" -Tag "Info"
Write-Log "Time zone: $TimeZone | VHD: $VhdSizeGB GB $VhdType" -Tag "Info"
Write-Log "RDP: $EnableRdp | Ping: $EnablePing" -Tag "Info"
# What this run can actually act on. Half of the offline policies are Server-only and
# half are client-only, and a summary that lists all of them reports decisions that were
# never available - a Server build has no Welcome Experience to suppress and does not
# encrypt itself.
$runHasClient = $false
$runHasServer = $false
$runHasEdge = $false
foreach ($index in $buildIndexes) {
    $match = $availableImages | Where-Object { $_.ImageIndex -eq $index } | Select-Object -First 1
    if ($null -eq $match) { continue }
    if (Test-IsClientImage -ImageName $match.ImageName) { $runHasClient = $true } else { $runHasServer = $true }
    if (-not (Test-IsServerCoreImage -ImageName $match.ImageName)) { $runHasEdge = $true }
}

$suppressParts = @()
if ($runHasServer) { $suppressParts += "Server Manager: $SuppressServerManagerAtLogon" }
if ($runHasClient) {
    $suppressParts += "Welcome: $SuppressWelcomeExperience"
    $suppressParts += "sign-in animation: $SuppressFirstSignInAnimation"
}
$suppressParts += "sign-in IMEs: $BlockSignInInputMethods"
Write-Log ("Suppress at logon - " + ($suppressParts -join " | ")) -Tag "Info"
if ($runHasEdge) {
    Write-Log "Microsoft Edge policy baseline: $(if ($ConfigureEdge) { 'baked (Google search, no first run, clean new tab, required-only diagnostics)' } else { 'not baked' })" -Tag "Info"
}

if ($runHasClient) {
    Write-Log "Automatic BitLocker device encryption: $(if ($PreventDeviceEncryption) { 'prevented in the image' } else { 'left to Windows' })" -Tag "Info"
    Write-Log "Power plan: $(if ($SetVmPowerPlan) { 'High performance, display and sleep never, hibernation off' } else { 'left at the Windows default' })" -Tag "Info"
}
if (@($MultiSessionImageIndexes).Count -gt 0) {
    Write-Log "Multi-session after generalize: index $(@($MultiSessionImageIndexes) -join ', ')" -Tag "Info"
}
if (@($AzureEditionImageIndexes).Count -gt 0) {
    Write-Log "Azure Edition after generalize: index $(@($AzureEditionImageIndexes) -join ', ')" -Tag "Info"
}
$selectedNames = foreach ($buildSpec in $buildSpecs) {
    if (-not [string]::IsNullOrWhiteSpace($buildSpec.EditionUpgrade)) {
        "$($buildSpec.ImageIndex) $($script:VirtualEditionCatalog[$buildSpec.EditionUpgrade].DisplayName)"
    }
    else {
        $match = $availableImages | Where-Object { $_.ImageIndex -eq $buildSpec.ImageIndex } | Select-Object -First 1
        if ($match) { "$($buildSpec.ImageIndex) $($match.ImageName)" } else { "$($buildSpec.ImageIndex)" }
    }
}
Write-Log "Building $($buildSpecs.Count) gold(s) from $($availableImages.Count) image(s): $($selectedNames -join ' | ')" -Tag "Info"

# One DISM call per selected index, reused by the Azure Local guidance check and
# by the per-build log line below.
$imageLanguages = @{}
foreach ($imageIndex in $buildIndexes) {
    $imageLanguages[$imageIndex] = Get-ImageLanguageTag -WimPath $wimPath -ImageIndex $imageIndex
}

# Named rather than left as "unchanged": the display language is whatever the selected
# image ships, and the run should say which that is instead of only that nothing touched
# it. More than one language here means the ISO carries indexes that disagree.
$uiLanguages = @($buildIndexes |
        ForEach-Object { [string]$imageLanguages[$_] } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)
$uiLanguageText = if ($uiLanguages.Count -gt 0) { $uiLanguages -join ", " } else { "unknown" }
Write-Log "UI language: $uiLanguageText (image default)" -Tag "Info"

if ($Target -eq "AzureLocal") {
    foreach ($imageIndex in $buildIndexes) {
        $imageLanguage = [string]$imageLanguages[$imageIndex]
        if ([string]::IsNullOrWhiteSpace($imageLanguage)) {
            Write-Log "Index $imageIndex has no language metadata - en-US check skipped" -Tag "Warn"
        }
        elseif ($imageLanguage -notmatch "^en-US") {
            Write-Log "Index $imageIndex is '$imageLanguage' - Azure Local expects en-US" -Tag "Warn"
        }
    }
}

$generalize = -not $SkipSysprep.IsPresent
$allSucceeded = $true

foreach ($buildSpec in $buildSpecs) {
    $imageIndex = $buildSpec.ImageIndex
    $editionUpgrade = [string]$buildSpec.EditionUpgrade
    $imageInfo = $availableImages | Where-Object { $_.ImageIndex -eq $imageIndex } | Select-Object -First 1
    if ($null -eq $imageInfo) {
        Write-Log "Image index $imageIndex was not found in '$wimPath'" -Tag "Error"
        $allSucceeded = $false
        continue
    }

    $imageLanguage = [string]$imageLanguages[$imageIndex]
    $resolvedUi = Resolve-UiLanguage -UiLanguage $UiLanguage -ImageLanguage $imageLanguage
    $vhdxName = Get-VhdxFileName -ImageName $imageInfo.ImageName -ImageIndex $imageIndex -Target $Target `
        -ImageLanguage $imageLanguage -EditionUpgrade $editionUpgrade
    $vhdPath = Join-Path -Path $OutputDirectory -ChildPath $vhdxName

    # Named for what the gold IS when it leaves, not the index it came from - a
    # virtual edition build applies the base edition but ships the upgraded SKU.
    $buildDisplayName = if ($editionUpgrade) { [string]$script:VirtualEditionCatalog[$editionUpgrade].DisplayName } else { $imageInfo.ImageName }
    Write-Log "Building '$buildDisplayName' -> '$vhdPath'" -Tag "Info"

    $ok = Invoke-ImageBuildPipeline -VhdPath $vhdPath -ImageIndex $imageIndex `
        -ImageName $imageInfo.ImageName -WimPath $wimPath -Target $Target `
        -Locale $Locale -KeyboardLayout $KeyboardLayout -UiLanguage $resolvedUi `
        -TimeZone $TimeZone -VhdSizeGB $VhdSizeGB -VhdType $VhdType -Generalize $generalize `
        -EnableRdp $EnableRdp -EnablePing $EnablePing `
        -SuppressServerManagerAtLogon $SuppressServerManagerAtLogon `
        -SuppressWelcomeExperience $SuppressWelcomeExperience `
        -SuppressFirstSignInAnimation $SuppressFirstSignInAnimation `
        -BlockSignInInputMethods $BlockSignInInputMethods `
        -PreventDeviceEncryption $PreventDeviceEncryption `
        -SetVmPowerPlan $SetVmPowerPlan `
        -ConfigureEdge $ConfigureEdge `
        -EditionUpgrade $editionUpgrade

    if (-not $ok) {
        $allSucceeded = $false
        continue
    }

    $manifestOk = Write-GoldImageManifest -VhdPath $vhdPath -ImageName $imageInfo.ImageName `
        -ImageIndex $imageIndex -Target $Target -Locale $Locale -KeyboardLayout $KeyboardLayout `
        -TimeZone $TimeZone -ImageLanguage $imageLanguage -EditionUpgrade $editionUpgrade
    if (-not $manifestOk) {
        $allSucceeded = $false
    }
}

if ($allSucceeded) {
    Write-Log "$($buildSpecs.Count) gold(s) built" -Tag "Ok"
    Complete-Script -ExitCode 0
}

Write-Log "One or more images failed" -Tag "Error"
Complete-Script -ExitCode 1
