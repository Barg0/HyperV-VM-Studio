<#
.SYNOPSIS
    Generates locales.json for New-Vhdx.ps1 - every Windows locale, derived from
    the host's own NLS data.

.DESCRIPTION
    Enumerates [System.Globalization.CultureInfo]::GetCultures('SpecificCultures')
    and derives, per locale, the same schema New-Vhdx.ps1's in-script catalog
    carries: language/keyboard/LCID identifiers, GeoID and country, currency,
    date/time/number formats and the Control Panel International fields. The one
    thing Windows cannot answer is the phone code (iCountry) - that comes from the
    ITU table embedded below.

    Excluded on purpose:
      - ja / zh / ko: their input profiles are IMEs, and a generated keyboard hex
        is not a valid input profile there. Deploying those needs the TIP strings
        from Microsoft's default input profile table - out of scope until the lab
        actually deploys one.
      - Supplemental locales (LCID 0x1000): they share one placeholder LCID, so
        LangId and the default keyboard carry no real NLS identity.

    Run on a Windows host - the data comes from Windows, not from this script.
    The output lands in the repo's data\ folder as data\locales.json; New-Vhdx.ps1
    loads it from there at start and falls back to its hand-verified in-script
    catalog when the file is missing or invalid. Entries here are generated, not
    hardware-verified.

.NOTES
    Target shell : Windows PowerShell 5.1 and PowerShell 7 (Windows only)
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Where locales.json lands. Default: the repo's data\ folder, next to New-Vhdx.ps1's other read-only inputs.")]
    [string]$OutputPath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "data\locales.json"),

    [Parameter(HelpMessage = "The locale New-Vhdx.ps1 preselects and falls back to. Must be in the generated set.")]
    [string]$DefaultLocale = "de-DE"
)

$ErrorActionPreference = "Stop"

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq "Core" -and $env:OS -ne "Windows_NT") {
    throw "This generator reads Windows NLS data and must run on a Windows host."
}

# ITU E.164 dial codes by ISO 3166-1 alpha-2 region. The one field .NET has no API
# for. Regions without an assignment (AQ) or outside the table fall back to "".
$dialCodes = @{
    "AD"="376"; "AE"="971"; "AF"="93";  "AG"="1";   "AI"="1";   "AL"="355"; "AM"="374"; "AO"="244"
    "AR"="54";  "AS"="1";   "AT"="43";  "AU"="61";  "AW"="297"; "AX"="358"; "AZ"="994"; "BA"="387"
    "BB"="1";   "BD"="880"; "BE"="32";  "BF"="226"; "BG"="359"; "BH"="973"; "BI"="257"; "BJ"="229"
    "BL"="590"; "BM"="1";   "BN"="673"; "BO"="591"; "BQ"="599"; "BR"="55";  "BS"="1";   "BT"="975"
    "BW"="267"; "BY"="375"; "BZ"="501"; "CA"="1";   "CC"="61";  "CD"="243"; "CF"="236"; "CG"="242"
    "CH"="41";  "CI"="225"; "CK"="682"; "CL"="56";  "CM"="237"; "CN"="86";  "CO"="57";  "CR"="506"
    "CU"="53";  "CV"="238"; "CW"="599"; "CX"="61";  "CY"="357"; "CZ"="420"; "DE"="49";  "DJ"="253"
    "DK"="45";  "DM"="1";   "DO"="1";   "DZ"="213"; "EC"="593"; "EE"="372"; "EG"="20";  "ER"="291"
    "ES"="34";  "ET"="251"; "FI"="358"; "FJ"="679"; "FK"="500"; "FM"="691"; "FO"="298"; "FR"="33"
    "GA"="241"; "GB"="44";  "GD"="1";   "GE"="995"; "GF"="594"; "GG"="44";  "GH"="233"; "GI"="350"
    "GL"="299"; "GM"="220"; "GN"="224"; "GP"="590"; "GQ"="240"; "GR"="30";  "GT"="502"; "GU"="1"
    "GW"="245"; "GY"="592"; "HK"="852"; "HN"="504"; "HR"="385"; "HT"="509"; "HU"="36";  "ID"="62"
    "IE"="353"; "IL"="972"; "IM"="44";  "IN"="91";  "IO"="246"; "IQ"="964"; "IR"="98";  "IS"="354"
    "IT"="39";  "JE"="44";  "JM"="1";   "JO"="962"; "JP"="81";  "KE"="254"; "KG"="996"; "KH"="855"
    "KI"="686"; "KM"="269"; "KN"="1";   "KP"="850"; "KR"="82";  "KW"="965"; "KY"="1";   "KZ"="7"
    "LA"="856"; "LB"="961"; "LC"="1";   "LI"="423"; "LK"="94";  "LR"="231"; "LS"="266"; "LT"="370"
    "LU"="352"; "LV"="371"; "LY"="218"; "MA"="212"; "MC"="377"; "MD"="373"; "ME"="382"; "MF"="590"
    "MG"="261"; "MH"="692"; "MK"="389"; "ML"="223"; "MM"="95";  "MN"="976"; "MO"="853"; "MP"="1"
    "MQ"="596"; "MR"="222"; "MS"="1";   "MT"="356"; "MU"="230"; "MV"="960"; "MW"="265"; "MX"="52"
    "MY"="60";  "MZ"="258"; "NA"="264"; "NC"="687"; "NE"="227"; "NF"="672"; "NG"="234"; "NI"="505"
    "NL"="31";  "NO"="47";  "NP"="977"; "NR"="674"; "NU"="683"; "NZ"="64";  "OM"="968"; "PA"="507"
    "PE"="51";  "PF"="689"; "PG"="675"; "PH"="63";  "PK"="92";  "PL"="48";  "PM"="508"; "PR"="1"
    "PS"="970"; "PT"="351"; "PW"="680"; "PY"="595"; "QA"="974"; "RE"="262"; "RO"="40";  "RS"="381"
    "RU"="7";   "RW"="250"; "SA"="966"; "SB"="677"; "SC"="248"; "SD"="249"; "SE"="46";  "SG"="65"
    "SH"="290"; "SI"="386"; "SJ"="47";  "SK"="421"; "SL"="232"; "SM"="378"; "SN"="221"; "SO"="252"
    "SR"="597"; "SS"="211"; "ST"="239"; "SV"="503"; "SX"="1";   "SY"="963"; "SZ"="268"; "TC"="1"
    "TD"="235"; "TG"="228"; "TH"="66";  "TJ"="992"; "TK"="690"; "TL"="670"; "TM"="993"; "TN"="216"
    "TO"="676"; "TR"="90";  "TT"="1";   "TV"="688"; "TW"="886"; "TZ"="255"; "UA"="380"; "UG"="256"
    "US"="1";   "UY"="598"; "UZ"="998"; "VA"="379"; "VC"="1";   "VE"="58";  "VG"="1";   "VI"="1"
    "VN"="84";  "VU"="678"; "WF"="681"; "WS"="685"; "XK"="383"; "YE"="967"; "YT"="262"; "ZA"="27"
    "ZM"="260"; "ZW"="263"
}

# Windows iFirstDayOfWeek counts Monday=0..Sunday=6; .NET DayOfWeek counts
# Sunday=0..Saturday=6.
function ConvertTo-WindowsFirstDay {
    param([System.DayOfWeek]$Day)
    return (([int]$Day + 6) % 7).ToString()
}

# The keyboard layout ids Windows can actually load - the KLID must exist here or
# Windows silently falls back at first boot.
$script:ValidKlids = @{}
foreach ($klidKey in (Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts")) {
    $script:ValidKlids[$klidKey.PSChildName.ToLowerInvariant()] = $true
}

function Resolve-KeyboardId {
    # CultureInfo.KeyboardLayoutId echoes the culture's LCID, and for alt-sort and
    # regional variants (es-AR = 0x2C0A, ar-DZ = 0x1401, ...) that is not a KLID any
    # keyboard DLL answers to. Approximate Microsoft's default input profiles:
    # a couple of known exceptions, one language-wide rule for Latin American
    # Spanish, then the primary language's own default layout, then US.
    param([System.Globalization.CultureInfo]$Culture)

    $overrides = @{
        # Microsoft's default for English (Canada) is the US layout, even though
        # the Canadian French KLID exists and would otherwise win the as-is check.
        "en-CA" = "00000409"
        # French (Canada) defaults to Canadian French, not the legacy 00000c0c.
        "fr-CA" = "00001009"
    }
    if ($overrides.Contains($Culture.Name)) { return $overrides[$Culture.Name] }

    # Serbian Cyrillic shares its primary language id with Croatian; without this
    # the fallback below would hand a Cyrillic locale the Croatian Latin layout.
    if ($Culture.Name -like "sr-Cyrl-*" -and $script:ValidKlids.Contains("00000c1a")) {
        return "00000c1a"
    }
    # Latin American Spanish is one layout for the whole continent.
    if ($Culture.TwoLetterISOLanguageName -eq "es" -and $Culture.Name -notlike "*-ES" -and $script:ValidKlids.Contains("0000080a")) {
        return "0000080a"
    }

    $asIs = "{0:x8}" -f $Culture.KeyboardLayoutId
    if ($script:ValidKlids.Contains($asIs)) { return $asIs }

    # The primary language's default variant (sublanguage 1): ar-DZ -> 00000401,
    # de-LI -> 00000407, es-ES modern sort -> 0000040a.
    $primaryDefault = "{0:x8}" -f (0x0400 -bor ($Culture.KeyboardLayoutId -band 0x3FF))
    if ($script:ValidKlids.Contains($primaryDefault)) { return $primaryDefault }

    return "00000409"
}

# .NET CalendarWeekRule (FirstDay=0, FirstFullWeek=1, FirstFourDayWeek=2) matches
# the Windows iFirstWeekOfYear values one to one.

$excludedLanguages = @("ja", "zh", "ko")
$cultures = [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::SpecificCultures)

$entries = [ordered]@{}
$skippedIme = 0
$skippedSupplemental = 0
$skippedNoRegion = 0

foreach ($ci in ($cultures | Sort-Object Name)) {
    if ($ci.TwoLetterISOLanguageName -in $excludedLanguages) { $skippedIme++; continue }
    # Supplemental locales all share the 0x1000 placeholder LCID - no NLS identity.
    if ($ci.LCID -eq 0x1000) { $skippedSupplemental++; continue }

    $ri = $null
    try { $ri = New-Object System.Globalization.RegionInfo($ci.Name) }
    catch { $skippedNoRegion++; continue }

    $df = $ci.DateTimeFormat
    $nf = $ci.NumberFormat

    # 0 = month first, 1 = day first, 2 = year first - read off the short pattern.
    $iDate = "0"
    foreach ($ch in $df.ShortDatePattern.ToCharArray()) {
        if ($ch -eq "d") { $iDate = "1"; break }
        if ($ch -eq "M") { $iDate = "0"; break }
        if ($ch -eq "y") { $iDate = "2"; break }
    }

    $geoName = $ri.TwoLetterISORegionName
    $entries[$ci.Name] = [ordered]@{
        LangId          = ("{0:x4}" -f $ci.LCID)
        Keyboard        = (Resolve-KeyboardId -Culture $ci)
        Lcid            = ("{0:x8}" -f $ci.LCID)
        GeoNation       = [string]$ri.GeoId
        GeoName         = $geoName
        Currency        = $ri.CurrencySymbol
        sCountry        = $ri.EnglishName
        sLanguage       = $ci.ThreeLetterWindowsLanguageName
        iCountry        = [string]$dialCodes[$geoName]
        sShortDate      = $df.ShortDatePattern
        sLongDate       = $df.LongDatePattern
        sShortTime      = $df.ShortTimePattern
        sTimeFormat     = $df.LongTimePattern
        iMeasure        = $(if ($ri.IsMetric) { "0" } else { "1" })
        iFirstDayOfWeek = (ConvertTo-WindowsFirstDay -Day $df.FirstDayOfWeek)
        iFirstWeekOfYear = ([int]$df.CalendarWeekRule).ToString()
        iNegCurr        = ([int]$nf.CurrencyNegativePattern).ToString()
        iTime           = $(if ($df.ShortTimePattern -cmatch "H") { "1" } else { "0" })
        iDate           = $iDate
        s1159           = $df.AMDesignator
        s2359           = $df.PMDesignator
        sDecimal        = $nf.NumberDecimalSeparator
        sThousand       = $nf.NumberGroupSeparator
        sList           = $ci.TextInfo.ListSeparator
        sMonDecimalSep  = $nf.CurrencyDecimalSeparator
        sMonThousandSep = $nf.CurrencyGroupSeparator
    }
}

if (-not $entries.Contains($DefaultLocale)) {
    throw "Default locale '$DefaultLocale' is not in the generated set - nothing was written."
}

$missingDial = @($entries.Keys | Where-Object { $entries[$_].iCountry -eq "" })

$document = [ordered]@{
    default   = $DefaultLocale
    generated = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    source    = "toolbox\New-LocaleCatalog.ps1 on $([System.Environment]::OSVersion.VersionString)"
    locales   = $entries
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$json = $document | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($OutputPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Wrote $($entries.Count) locale(s) to '$OutputPath' (default: $DefaultLocale)"
Write-Host "Skipped: $skippedIme IME (ja/zh/ko), $skippedSupplemental supplemental (LCID 0x1000), $skippedNoRegion without region data"
if ($missingDial.Count -gt 0) {
    Write-Host "No dial code for: $($missingDial -join ', ') - iCountry left empty there"
}
