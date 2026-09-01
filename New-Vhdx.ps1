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
    supposed to make that call.

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

    14 locales are
    supported (-Locale/-KeyboardLayout); -UiLanguage is always Auto - there is
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

    [Parameter(HelpMessage = "Regional format (UserLocale / SystemLocale).")]
    [ValidateSet("de-DE", "en-US", "cs-CZ", "da-DK", "en-GB", "es-ES", "fi-FI", "fr-FR", "it-IT", "nb-NO", "nl-NL", "pl-PL", "pt-PT", "sv-SE")]
    [string]$Locale = "de-DE",

    [Parameter(HelpMessage = "Keyboard input layout.")]
    [ValidateSet("de-DE", "en-US", "cs-CZ", "da-DK", "en-GB", "es-ES", "fi-FI", "fr-FR", "it-IT", "nb-NO", "nl-NL", "pl-PL", "pt-PT", "sv-SE")]
    [string]$KeyboardLayout = "de-DE",

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
            Write-Log "Could not dismount ISO '$($script:mountedIsoPath)': $($_.Exception.Message)" -Tag "Debug"
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

function Get-LocaleCatalogEntry {
    param([string]$Locale)

    if ($script:LocaleCatalog.Contains($Locale)) {
        return $script:LocaleCatalog[$Locale]
    }
    Write-Log "Unknown locale '$Locale' - falling back to de-DE" -Tag "Info"
    return $script:LocaleCatalog["de-DE"]
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
        Write-Log "Azure Local gold - no sidecar manifest written (nothing reads one on that path)" -Tag "Info"
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
        [int]$IndentWidth = 0
    )

    if ($IndentWidth -gt 0) {
        Write-Host (" " * $IndentWidth) -NoNewline
    }
    $paddedLabel = ("{0,-$LabelWidth}" -f $Label)
    Write-Host $paddedLabel -NoNewline -ForegroundColor DarkCyan
    Write-Host ": " -NoNewline -ForegroundColor DarkCyan
    Write-Host $Value -ForegroundColor Gray
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

    $index = $SelectedIndex
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $Items.Count) { $index = $Items.Count - 1 }

    $useRawUi = Test-MenuHostSupported
    $maxVisible = 16

    while ($true) {
        Show-MenuHeader -Title $Title -StatusLines $StatusLines -Subtitle $Subtitle

        if ($PreItems) {
            & $PreItems
        }

        if (-not [string]::IsNullOrWhiteSpace($Heading)) {
            Write-Host "  $Heading" -ForegroundColor White
            if (-not [string]::IsNullOrWhiteSpace($HeadingHint)) {
                Write-Host "  $HeadingHint" -ForegroundColor DarkGray
            }
            Write-Host ""
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
            Write-Host "    ..." -ForegroundColor DarkGray
        }

        for ($i = $windowStart; $i -le $windowEnd; $i++) {
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

        if ($windowEnd -lt ($Items.Count - 1)) {
            Write-Host "    ..." -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
        if ($useRawUi) {
            Write-Host "  Up/Down move   PgUp/PgDn/Home/End jump   Enter select   Esc/Q cancel" -ForegroundColor DarkGray
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
            if ($virtualKey -eq 33) {
                $index = [Math]::Max(0, $index - $maxVisible)
                continue
            }
            if ($virtualKey -eq 34) {
                $index = [Math]::Min($Items.Count - 1, $index + $maxVisible)
                continue
            }
            if ($virtualKey -eq 36) {
                $index = 0
                continue
            }
            if ($virtualKey -eq 35) {
                $index = $Items.Count - 1
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

    while ($true) {
        Show-MenuHeader -Title $Title -StatusLines $StatusLines -Subtitle $Subtitle

        if (-not [string]::IsNullOrWhiteSpace($NoteHeadline)) {
            if (Test-MenuAnsiSupported) {
                $esc = [char]27
                Write-Host "  $esc[1m$NoteHeadline$esc[0m" -ForegroundColor White
            }
            else {
                Write-Host "  $NoteHeadline" -ForegroundColor White
            }
            Write-Host ""
        }

        if ($Note.Count -gt 0) {
            foreach ($line in $Note) {
                # A blank entry is a paragraph break, not two spaces of trailing whitespace.
                if ([string]::IsNullOrWhiteSpace($line)) { Write-Host "" }
                else { Write-Host "  $line" -ForegroundColor DarkGray }
            }
            Write-Host ""
        }

        $lastSection = $null
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $item  = $rows[$i]
            $isSelectedRow = ($i -eq $index)
            $indent = if ($hasSections) { "  " } else { "" }

            if ($item.IsContinue) {
                Write-Host ""
                if ($isSelectedRow) {
                    Write-Host "  $indent> " -NoNewline -ForegroundColor Cyan
                    Write-Host $item.Label -ForegroundColor White
                }
                else {
                    Write-Host "    $indent" -NoNewline
                    Write-Host $item.Label -ForegroundColor Gray
                }
                continue
            }

            $section = [string]$item.Section
            if (-not [string]::IsNullOrWhiteSpace($section) -and $section -ne $lastSection) {
                if ($null -ne $lastSection) { Write-Host "" }
                Write-Host "  $section" -ForegroundColor White
                if ($SectionNotes.ContainsKey($section)) {
                    Write-Host ""
                    foreach ($line in @($SectionNotes[$section])) {
                        if ([string]::IsNullOrWhiteSpace($line)) { Write-Host "" }
                        else { Write-Host "  $line" -ForegroundColor DarkGray }
                    }
                }
                Write-Host ""
                $lastSection = $section
            }

            $id    = [string]$item.Id
            $mark  = if ($selected[$id]) { "[x]" } else { "[ ]" }
            $label = "$mark  $($item.Label)"

            if ($isSelectedRow) {
                Write-Host "  $indent> " -NoNewline -ForegroundColor Cyan
                Write-Host $label -ForegroundColor White
            }
            else {
                Write-Host "    $indent" -NoNewline
                Write-Host $label -ForegroundColor Gray
            }
        }

        Write-Host ""
        Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
        if ($useRawUi) {
            Write-Host "  Up/Down move   Space toggle   Enter continue   Esc/Q cancel" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  Number toggles, Enter continues, Q cancels" -ForegroundColor DarkGray
        }
        Write-Host ""

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

    while ($true) {
        Show-MenuHeader -Title $Title -Subtitle $Subtitle -StatusLines $StatusLines

        Write-Host "  Disk size (GB)" -ForegroundColor White
        Write-Host "  Editable - type digits to change it, Backspace deletes." -ForegroundColor DarkGray
        Write-Host ""
        if ($cursor -eq 0) {
            Write-Host "    > " -NoNewline -ForegroundColor Cyan
            Write-Host "$($sizeText)_" -NoNewline -ForegroundColor White
            Write-Host "   (default $DefaultSizeGB, range $MinSizeGB-$MaxSizeGB)" -ForegroundColor DarkGray
        }
        else {
            Write-Host "      " -NoNewline
            $shownSize = if ([string]::IsNullOrWhiteSpace($sizeText)) { "$DefaultSizeGB" } else { $sizeText }
            Write-Host $shownSize -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host "  Type" -ForegroundColor White
        for ($i = 0; $i -lt $typeOptions.Count; $i++) {
            $opt = $typeOptions[$i]
            $rowIndex = $i + 1
            $mark = if ($opt.Id -eq $selectedType) { "(*)" } else { "( )" }
            $label = "$mark $($opt.Label)  - $($opt.Description)"
            if ($cursor -eq $rowIndex) {
                Write-Host "    > " -NoNewline -ForegroundColor Cyan
                Write-Host $label -ForegroundColor White
            }
            else {
                Write-Host "      " -NoNewline
                Write-Host $label -ForegroundColor Gray
            }
        }

        if ($errorMessage) {
            Write-Host ""
            Write-Host "  $errorMessage" -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
        Write-Host "  Up/Down move   Space select type   Type digits for size   Enter confirm   Esc cancel" -ForegroundColor DarkGray
        Write-Host ""

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

    Write-Host "  $Prompt" -ForegroundColor White
    if (-not [string]::IsNullOrWhiteSpace($DefaultPath)) {
        Write-Host "    (blank keeps default: $DefaultPath)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "    > " -NoNewline -ForegroundColor Cyan

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
    Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
    Write-Host "  Type a path, then Enter   (blank keeps default)" -ForegroundColor DarkGray
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
        Write-Host "  Enter a whole number between $MinValue and $MaxValue." -ForegroundColor Yellow
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
        Show-MenuHeader -Title "Select Windows ISO file" -Subtitle "Enter opens folder / selects .iso" `
            -StatusLines $status

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
            Write-Host "    ..." -ForegroundColor DarkGray
        }

        for ($i = $windowStart; $i -le $windowEnd; $i++) {
            $entry = $entries[$i]
            $selected = ($i -eq $index)
            $prefix = "    "
            $color = "Gray"

            if ($entry.Kind -eq "iso") {
                $color = "Cyan"
            }
            elseif ($entry.Kind -eq "dir" -or $entry.Kind -eq "drive") {
                $color = "Yellow"
            }
            elseif ($entry.Kind -eq "nav") {
                $color = "DarkGray"
            }

            if ($selected) {
                Write-Host "  > " -NoNewline -ForegroundColor Cyan
                Write-Host $entry.Label -ForegroundColor White
            }
            else {
                Write-Host $prefix -NoNewline
                Write-Host $entry.Label -ForegroundColor $color
            }
        }

        if ($windowEnd -lt ($entries.Count - 1)) {
            Write-Host "    ..." -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
        if ($useRawUi) {
            Write-Host "  Up/Down move   Enter open/select   Backspace up   Esc cancel" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  Number + Enter selects   B = up   Q = cancel" -ForegroundColor DarkGray
        }
        Write-Host ""

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
    # de-DE default/top, en-US next, then the rest alphabetically.
    return @("de-DE", "en-US", "cs-CZ", "da-DK", "en-GB", "es-ES", "fi-FI", "fr-FR", "it-IT", "nb-NO", "nl-NL", "pl-PL", "pt-PT", "sv-SE")
}

function Get-OrderedTimeZoneCatalog {
    # Live Windows time zone database (Id = DISM /Set-TimeZone value), sorted
    # by UTC offset then display name - the same order Windows' own Date &
    # Time settings uses, so the picker feels familiar.
    try {
        $zones = [System.TimeZoneInfo]::GetSystemTimeZones() | Sort-Object BaseUtcOffset, DisplayName
    }
    catch {
        Write-Log "Could not enumerate system time zones: $($_.Exception.Message)" -Tag "Debug"
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
        [int[]]$CurrentMultiSessionImageIndexes = @(),
        [int[]]$CurrentAzureEditionImageIndexes = @()
    )

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
        $entry = Get-LocaleCatalogEntry -Locale $tag
        $localeItems += [PSCustomObject]@{ Id = $tag; Label = "$tag - $($entry.sCountry)" }
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
    $localeSummary = "$locale - $((Get-LocaleCatalogEntry -Locale $locale).sCountry)"

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
    }
    # Applies to both client and server: pin sign-in keyboard to the baked layout.
    $featureItems += [PSCustomObject]@{ Id = "signin"; Label = "Block per-user input methods on sign-in screen (STIG)"; Selected = $CurrentBlockSignInInputMethods; Section = "Optional" }
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
    $preventDeviceEncryption = $featureChoice -contains "autode"

    # Dedicated VHDX window: size and type together on one form.
    $vhdxConfig = Show-VhdxConfigForm -Title "Configure VHDX" -Subtitle "Disk size and provisioning type" `
        -StatusLines ([ordered]@{ iso = $isoStatus; target = $targetId; locale = $locale; timezone = $timeZone }) `
        -DefaultSizeGB $CurrentVhdSizeGB -MinSizeGB 20 -MaxSizeGB 2048 -DefaultType $CurrentVhdType
    if ($null -eq $vhdxConfig) { return $null }
    $vhdSizeGB = $vhdxConfig.SizeGB
    $vhdType = $vhdxConfig.Type

    # Final confirmation screen - every selected setting, then Continue/Cancel.
    $renderSummary = {
        Write-Host "  Source" -ForegroundColor White
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
        Write-Host "  Region" -ForegroundColor White
        Write-FastfetchInfoRow -Label "locale"    -Value $localeSummary -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "time zone" -Value $timeZoneSummary -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "applied" -Value $(if ($targetId -eq "AzureLocal") {
            "At the VM's first boot - Azure Local overwrites a baked locale"
        } else { "Baked into the image offline" }) -LabelWidth 24 -IndentWidth 2
        Write-Host ""
        Write-Host "  Features" -ForegroundColor White
        Write-FastfetchInfoRow -Label "remote desktop (rdp)" -Value $(if ($enableRdp) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "icmp echo (ping)"     -Value $(if ($enablePing) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "block sign-in imes"   -Value $(if ($blockSignIn) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
        if ($buildHasServer) {
            Write-FastfetchInfoRow -Label "suppress server mgr" -Value $(if ($suppressServerManager) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
        }
        if ($buildHasClient) {
            Write-FastfetchInfoRow -Label "suppress welcome exp" -Value $(if ($suppressWelcome) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
            Write-FastfetchInfoRow -Label "suppress signin anim" -Value $(if ($suppressSignInAnimation) { "Enabled" } else { "Disabled" }) -LabelWidth 24 -IndentWidth 2
            Write-FastfetchInfoRow -Label "auto bitlocker" -Value $(if ($preventDeviceEncryption) { "Prevented" } else { "Left to Windows" }) -LabelWidth 24 -IndentWidth 2
        }
        Write-Host ""
        Write-Host "  Disk" -ForegroundColor White
        Write-FastfetchInfoRow -Label "vhdx size" -Value "$vhdSizeGB GB" -LabelWidth 24 -IndentWidth 2
        Write-FastfetchInfoRow -Label "vhdx type" -Value $vhdType -LabelWidth 24 -IndentWidth 2
        Write-Host ""
        Write-Host ("  " + ("-" * 62)) -ForegroundColor DarkGray
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
        PreventDeviceEncryption      = $preventDeviceEncryption
        MultiSessionImageIndexes     = @($multiSessionIndexes)
        AzureEditionImageIndexes     = @($azureEditionIndexes)
    }
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
    Write-Log "Creating $VhdType VHDX '$VhdPath' ($sizeGb GB)" -Tag "Run"

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

    Write-Log "Writing temporary boot unattend to '$unattendPath'" -Tag "Run"
    Write-Utf8NoBomFile -Path $unattendPath -Content $Content
}

function Set-HyperVDeployUnattend {
    param([string]$Content)

    $deployPath = "W:\Windows\Deploy\unattend.xml"
    Write-Log "Writing Hyper-V deploy unattend to '$deployPath'" -Tag "Run"
    Write-Utf8NoBomFile -Path $deployPath -Content $Content
}

function Set-BootFiles {
    Write-Log "Writing UEFI boot files" -Tag "Run"
    & "W:\Windows\System32\bcdboot.exe" "W:\Windows" /s "S:" /f UEFI | Out-Null
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
        Write-Log "Image reports current edition '$currentEdition' after the change" -Tag "Info"

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
            catch { Write-Log "Could not dismount '$VhdPath' after the edition change" -Tag "Debug" }
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
        Write-Log "Baking PreventDeviceEncryption=1 - Windows will not turn BitLocker on by itself" -Tag "Run"
        & reg.exe add "$hiveRoot\ControlSet001\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f | Out-Null
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

    Write-Log "Suppressing Getting Started / Windows Welcome Experience at logon" -Tag "Run"
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

    Write-Log "First-boot locale payload written: $Locale / $inputLocale / $TimeZone" -Tag "Run"
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
        [bool]$EnableRdp = $true,
        [bool]$EnablePing = $true,
        [bool]$SuppressServerManagerAtLogon = $false,
        [bool]$SuppressWelcomeExperience = $false,
        [bool]$SuppressFirstSignInAnimation = $false,
        [bool]$BlockSignInInputMethods = $false,
        [bool]$PreventDeviceEncryption = $false
    )

    Write-Log "Applying offline customization to '$VhdPath'" -Tag "Run"

    $mounted = $false
    try {
        $mountRoot = Get-MountedOsRoot -VhdPath $VhdPath
        $mounted = $true

        if ($RemovePantherUnattend) {
            $leftoverUnattend = Join-Path -Path $mountRoot -ChildPath "Windows\Panther\unattend.xml"
            if (Test-Path -Path $leftoverUnattend) {
                Write-Log "Removing leftover Panther\unattend.xml (Build-Vms injects at provision time)" -Tag "Run"
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
            Write-Log "Baking locale/keyboard/format via DISM ($Locale / $inputLocale)" -Tag "Run"
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
        }
        else {
            # Device encryption is a client feature; Server never turns BitLocker on by
            # itself, so the opt-out has nothing to opt out of here.
            Write-Log "Server image - Welcome Experience, sign-in animation and device encryption policies not applicable" -Tag "Debug"
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
            Write-Log "Could not dismount '$VhdPath' during cleanup" -Tag "Debug"
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

    Write-Log "Waiting up to $TimeoutMinutes minutes for '$VmName' to shut down" -Tag "Run"
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
            Write-Log "Leaving '$vmFolder' in place - it still holds $($disks.Count) virtual disk(s)" -Tag "Info"
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
    Write-Log "Generalizing '$VhdPath' using temporary VM '$vmName' under '$vmRoot'" -Tag "Info"

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
            Write-Log "Removed $($adapters.Count) network adapter(s) - the sysprep VM stays offline" -Tag "Run"
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

    Write-Log "Preflight passed - elevation, Hyper-V cmdlets, DISM, Windows image" -Tag "Ok"
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

    Write-Log "No install image at the default name, searching '$sourcesPath'" -Tag "Debug"
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
        Write-Log "Could not read language metadata for index $ImageIndex - $($_.Exception.Message)" -Tag "Debug"
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
        [string]$EditionUpgrade = ""
    )

    $isDatacenter = Test-IsServerDatacenterImage -ImageName $ImageName
    $isClient = Test-IsClientImage -ImageName $ImageName
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
            Write-Log "Server $serverYear Datacenter detected; AVMA key will be applied offline" -Tag "Info"
        }
        else {
            Write-Log "Server Datacenter without a published AVMA key ('$ImageName') - none applied" -Tag "Info"
        }
    }
    elseif (-not $isClient -and ([string]$ImageName) -match "(?i)\bstandard\b") {
        $avmaKey = Get-AvmaKey -Year $serverYear -Edition "Standard"
        if ($avmaKey -ne "") {
            Write-Log "Server $serverYear Standard detected; AVMA key will be applied offline" -Tag "Info"
        }
        else {
            Write-Log "Server Standard without a published AVMA key ('$ImageName') - none applied" -Tag "Info"
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
        Write-Log "Skipping generalize for '$VhdPath' (SkipSysprep set)" -Tag "Info"
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
            -RemovePantherUnattend:$removePanther -IsClient $isClient `
            -EnableRdp $EnableRdp -EnablePing $EnablePing `
            -SuppressServerManagerAtLogon $SuppressServerManagerAtLogon `
            -SuppressWelcomeExperience $SuppressWelcomeExperience `
            -SuppressFirstSignInAnimation $SuppressFirstSignInAnimation `
            -BlockSignInInputMethods $BlockSignInInputMethods `
            -PreventDeviceEncryption $PreventDeviceEncryption
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
        -CurrentMultiSessionImageIndexes @($MultiSessionImageIndexes) `
        -CurrentAzureEditionImageIndexes @($AzureEditionImageIndexes)

    if ($null -eq $config) {
        Write-Log "Cancelled at the configuration menu - nothing was built" -Tag "Info"
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

Write-Log "Target: $Target | Locale: $Locale | Keyboard: $KeyboardLayout" -Tag "Info"
Write-Log "Time zone: $TimeZone | VHD: $VhdSizeGB GB $VhdType" -Tag "Info"
Write-Log "RDP: $EnableRdp | Ping: $EnablePing" -Tag "Info"
# What this run can actually act on. Half of the offline policies are Server-only and
# half are client-only, and a summary that lists all of them reports decisions that were
# never available - a Server build has no Welcome Experience to suppress and does not
# encrypt itself.
$runHasClient = $false
$runHasServer = $false
foreach ($index in $buildIndexes) {
    $match = $availableImages | Where-Object { $_.ImageIndex -eq $index } | Select-Object -First 1
    if ($null -eq $match) { continue }
    if (Test-IsClientImage -ImageName $match.ImageName) { $runHasClient = $true } else { $runHasServer = $true }
}

$suppressParts = @()
if ($runHasServer) { $suppressParts += "Server Manager: $SuppressServerManagerAtLogon" }
if ($runHasClient) {
    $suppressParts += "Welcome: $SuppressWelcomeExperience"
    $suppressParts += "sign-in animation: $SuppressFirstSignInAnimation"
}
$suppressParts += "sign-in IMEs: $BlockSignInInputMethods"
Write-Log ("Suppress at logon - " + ($suppressParts -join " | ")) -Tag "Info"

if ($runHasClient) {
    Write-Log "Automatic BitLocker device encryption: $(if ($PreventDeviceEncryption) { 'prevented in the image' } else { 'left to Windows' })" -Tag "Info"
}
if (@($MultiSessionImageIndexes).Count -gt 0) {
    Write-Log "Upgrading to Enterprise multi-session after generalize: index $(@($MultiSessionImageIndexes) -join ', ')" -Tag "Info"
}
if (@($AzureEditionImageIndexes).Count -gt 0) {
    Write-Log "Upgrading to Datacenter: Azure Edition after generalize: index $(@($AzureEditionImageIndexes) -join ', ')" -Tag "Info"
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
