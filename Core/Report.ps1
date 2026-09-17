<#
    ExchangeDiag - Rapor uretimi

    Brief Bolum 8: her modul tum sunucular icin tek satir uretir, sunucular yan
    yana dizilir ve SAPAN HUCRE VURGULANIR. Rapor ilk bakista "hangi sunucu
    farkli" sorusunu cevaplamalidir.
#>

function Get-EDReportColumns {
<#
    .SYNOPSIS
        Sutun sirasi: once topolojideki sunucular, sonra satirlarda gecen
        digerleri.

    .DESCRIPTION
        CELLSTATUS ANAHTARLARI DA SUTUN URETIR. Eskiden yalnizca Values'a
        bakiliyordu; CellStatus'ta olup Values'ta olmayan bir anahtar hic
        sutun almiyor ve ISARETLENMIS SAPAN HUCRE RAPORDAN SESSIZCE
        DUSUYORDU - modul "SRV2 farkli" demis, rapor SRV2'yi hic yazmamis
        oluyordu. Bu aracin tek isi sapani gostermek oldugu icin, kaybolan
        isaret kabul edilebilir bir sonuc degildir.

        Satir kurulumunda GURULTULU DOGRULAMA (throw) bilerek secilmedi:
        anahtar kumeleri uyusmuyorsa bu bir modul hatasidir, ama karsiligi
        modulun DOGRU olan diger satirlarini da ERROR'a cevirip yok etmek
        olmamalidir. Sutun uretilince hucre zaten 'N/A' + vurgu ile cikar:
        "isaretlendi ama degeri okunamadi" dogru ve okunabilir bir ifadedir.
#>
    param($Rows, [string[]]$PreferredOrder)

    $columns = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $PreferredOrder) {
        if ($name -and -not $columns.Contains($name)) { [void]$columns.Add($name) }
    }
    $index = 0
    foreach ($row in $Rows) {
        $index++
        # Bozuk satir buraya ulasmamalidir (bkz. Get-EDModuleResultRows), ama
        # ulasirsa kripto bir "The property 'Keys' cannot be found" yerine
        # hangi satirin sucli oldugunu soyleyen bir hata verilir.
        if ($null -eq $row -or $null -eq $row.PSObject.Properties['Values'] -or
            -not ($row.Values -is [System.Collections.IDictionary])) {
            $label = if ($null -ne $row -and $null -ne $row.PSObject.Properties['Module']) { [string]$row.Module } else { '(bilinmiyor)' }
            throw "Rapor satiri bozuk: $index. satir (modul: $label) Values tablosu tasimiyor. Moduller satirlarini New-EDRow ile uretmelidir."
        }
        foreach ($key in $row.Values.Keys) {
            if (-not $columns.Contains($key)) { [void]$columns.Add($key) }
        }
        if ($null -ne $row.PSObject.Properties['CellStatus'] -and
            ($row.CellStatus -is [System.Collections.IDictionary])) {
            foreach ($key in $row.CellStatus.Keys) {
                if (-not $columns.Contains($key)) { [void]$columns.Add($key) }
            }
        }
    }
    return $columns.ToArray()
}

function ConvertTo-EDCsvSafeText {
<#
    .SYNOPSIS
        Excel'in FORMUL sanabilecegi hucre metnini etkisizlestirir.

    .DESCRIPTION
        SUMMARY.csv'nin okuyucusu Excel'dir. Excel bir hucre '=', '+', '-',
        '@' ya da sekme/satirbasi ile basliyorsa onu formul sayar; "=cmd|'
        /C calc'!A1" bicimindeki bir deger DDE ile komut calistirir. Bu
        metinler bizim degil, EXCHANGE'in uretimidir: kuyruk LastError,
        ContentIndexErrorMessage, mesaj konusu. Kanit toplayan salt okunur
        bir arac, kanitini acan kisiyi vurmamalidir.

        Tek tirnak on eki Excel'in "bu hucre metindir" isaretidir: hucre
        ekranda AYNEN gorunur ama degerlendirilmez - yani kanit da kaybolmaz.

        NEGATIF SAYILAR KACIRILMAZ. '-' ile baslayan her sey kacirilirsa
        "-3.5" -> "'-3.5" olur; SUMMARY.csv makine tarafindan da okunur
        (-CompareWith) ve delta motoru sayiyi kaybederdi. Bu yuzden once
        "bu bir sayi mi" diye bakilir: sayilar ve siradan metinler
        dokunulmadan gecer, yalnizca formul gibi baslayan METIN kacirilir.

        HTML tarafi ayri bir sorundur ve zaten HtmlEncode ile cozuludur;
        orada kacirma YAPILMAZ, cunku rapor metni oldugu gibi gostermelidir.
#>
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $Value }
    $text = [string]$Value
    if ($text.Length -eq 0) { return $Value }
    if ($text[0] -notin @('=', '+', '-', '@', "`t", "`r", "`n")) { return $Value }
    if ($null -ne (ConvertTo-EDNumber $text)) { return $Value }
    return "'" + $text
}

$script:EDStatusClassPattern = '[^A-Za-z0-9_-]'

function ConvertTo-EDStatusClass {
<#
    .SYNOPSIS
        Durum adini CSS SINIF ADINA cevirir.

    .DESCRIPTION
        'N/A' TEK bir sinif jetonudur ve icindeki '/' yuzunden '.NA'
        seciciyle ESLESMEZ: class="num N/A" yazan hucre hicbir kural
        yakalamaz ve olculmus bir hucreyle ayni gorunur. Raporun "neyin
        olculemedigi ilk bakista gorulsun" vaadi tam burada kiriliyordu -
        hem de her satirda sessizce.

        Sinif adi jetonlastirilir: bosluk iceren bir durum adi ikinci bir
        sinif jetonuna bolunur ve ayni sekilde kaybolurdu.

        -creplace kullanilir cunku CSS sinif adi buyuk/kucuk harfe DUYARLI
        bir tanimlayicidir; burada harf katlamasinin bir anlami yoktur ve
        kulture bagli davranis riskini bastan almamak dogrudur.
        NOT: "Turkce I" tuzagi bu desende OLCULDU ve BULUNMADI - tr-TR
        altinda -replace da PASSIVE/FAIL degerlerini bozmuyor, cunku .NET
        ASCII araliklarinda bu katlamayi ozel olarak ele aliyor. Tuzak
        GERCEKTIR ama baska islemlerde: .ToUpper()/.ToLower() cagrilari
        tr-TR'de 'i' -> 'Ä°' ve 'I' -> 'Ä±' uretir. Durum adlarini bir yerde
        buyuk/kucuk harfe cevirip sonra [A-Za-z] ile suzen bir kod eklenirse
        sinif adlari orada bozulur.
#>
    param([AllowNull()][string]$Status)

    $token = ([string]$Status) -creplace $script:EDStatusClassPattern, ''
    # Durumsuz hucre de olculmemis hucredir; renksiz birakilmaz.
    if (-not $token) { return 'NA' }
    return $token
}

function Export-EDSummaryCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)][string[]]$Columns,
        [Parameter(Mandatory)][string]$Path
    )

    # SUTUN ADLARI BURADA IKINCI KEZ TANIMLANMAZ. Yazan (bu dosya) ve okuyan
    # (Compare.ps1) taraf ayni listeyi ayri ayri tasidigi icin, rapora yeni
    # eklenen bir ust veri sutunu okuyan tarafta SUNUCU sanilmis ve olmayan
    # bir sunucu adina "olculmedi" kaydi uretilmisti. Liste artik tek yerde:
    # Framework.ps1 -> $script:EDSummaryMetaColumns.
    #
    # Sunucu sutunlari 'Durum'dan ONCE girer; listenin o noktaya kadarki
    # bolumu bas blok, kalani son bloktur. Boylece sutun SIRASI da paylasilan
    # listeden gelir.
    $statusIndex = [array]::IndexOf([string[]]$script:EDSummaryMetaColumns, 'Durum')
    if ($statusIndex -lt 1) {
        # Bolme noktasi yoksa sutun sirasi kurulamaz. Sessizce devam etmek
        # basliklari karisik bir CSV yazardi ve o dosya -CompareWith ile
        # MAKINE tarafindan okunuyor: bozuk sira, yanlis sunucuya yazilmis
        # deger demektir. Bu yuzden neden acikca soylenir.
        throw "Ust veri sutun listesi bozuk: 'Durum' bulunamadi. Framework.ps1 -> `$script:EDSummaryMetaColumns sirasini koruyun (once satir kimligi, sonra sunucular, en sonda Durum/Not)."
    }
    $leadingMeta = @($script:EDSummaryMetaColumns[0..($statusIndex - 1)])
    $trailingMeta = @($script:EDSummaryMetaColumns[$statusIndex..($script:EDSummaryMetaColumns.Count - 1)])

    $records = foreach ($row in $Rows) {
        # Ad -> deger eslemesi. Listede olup burada karsiligi olmayan bir ad
        # BOS hucre uretir (uydurma deger degil); eksik esleme Tests\
        # Test-ReportLayer.ps1 ve Test-CompareEngine.ps1 tarafindan yakalanir.
        $metaValues = @{
            Modul   = $row.Module
            Kontrol = $row.Check
            Birim   = $row.Unit
            # Orgusuz satirda bos metin: '-' ya da 'YOK' yazmak, bir orgunun
            # arastirilip bulunamadigi izlenimi verirdi.
            Orgu    = (Format-EDPatternList -Patterns (Get-EDRowPatterns $row))
            Durum   = $row.Status
            # Not alani Exchange metnini en sik tasiyan alandir (LastError,
            # ContentIndexErrorMessage, mesaj konusu).
            Not     = $row.Note
        }

        $record = [ordered]@{}
        foreach ($name in $leadingMeta) {
            $record[$name] = ConvertTo-EDCsvSafeText $metaValues[$name]
        }
        foreach ($column in $Columns) {
            # SUMMARY.csv makine tarafindan da okunur (-CompareWith). Sayilar
            # CurrentCulture ile yazilirsa tr-TR'de "12,5" olur ve delta motoru
            # onu 125 okur. Sunum bicimi HTML'in isi; burasi veri sozlesmesi.
            $cell = if ($row.Values.ContainsKey($column)) { $row.Values[$column] } else { '' }
            if ($cell -is [double] -or $cell -is [single] -or $cell -is [decimal]) {
                $cell = ([double]$cell).ToString([System.Globalization.CultureInfo]::InvariantCulture)
            }
            # Kacirma sayiya cevirmeden SONRA yapilir: invariant bicimdeki
            # "-3.5" sayi olarak taninir ve dokunulmadan gecer.
            $record[$column] = ConvertTo-EDCsvSafeText $cell
        }
        foreach ($name in $trailingMeta) {
            $record[$name] = ConvertTo-EDCsvSafeText $metaValues[$name]
        }
        [pscustomobject]$record
    }

    # ED-WRITE-OK: SUMMARY.csv; yol cagirandan gelir ve cikti klasorune baglidir
    $records | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    return $Path
}

function ConvertTo-EDHtmlEncoded {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Web.HttpUtility]::HtmlEncode($Text)
}

function Export-EDSummaryHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)][string[]]$Columns,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Context,
        $ModuleTimings = @()
    )

    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

    $environment = $Context.Config.Environment
    $topology = $Context.Topology
    $passiveSites = @()
    if ($topology) { $passiveSites = @($topology.Sites | Where-Object { $_.IsPassive } | ForEach-Object { $_.Name }) }

    $findings = @($Rows | Where-Object { $_.Status -in @('WARN', 'FAIL', 'ERROR', 'TIMEOUT') })
    $timeZone = [System.TimeZoneInfo]::Local.DisplayName

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('<!DOCTYPE html><html lang="tr"><head><meta charset="utf-8">')
    [void]$builder.AppendLine('<title>Exchange Teshis Raporu</title>')
    [void]$builder.AppendLine(@'
<style>
 :root { color-scheme: light dark; }
 body { font-family: Segoe UI, system-ui, sans-serif; margin: 24px; background:#fbfbfd; color:#1a1a1a; }
 h1 { font-size: 20px; margin: 0 0 4px; }
 h2 { font-size: 15px; margin: 28px 0 8px; border-bottom: 1px solid #d8d8e0; padding-bottom: 4px; }
 .meta { font-size: 12px; color:#555; line-height: 1.7; }
 .meta code { background:#eceef3; padding:1px 5px; border-radius:3px; }
 table { border-collapse: collapse; font-size: 13px; width: 100%; margin-top: 8px; }
 th, td { border: 1px solid #dcdce4; padding: 5px 9px; text-align: left; white-space: nowrap; }
 th { background: #eef0f5; font-weight: 600; position: sticky; top: 0; }
 td.num { text-align: right; font-variant-numeric: tabular-nums; }
 tr:nth-child(even) td { background: #f7f7fb; }
 .st { font-weight: 700; text-align:center; }
 .OK    { background:#e4f6e4 !important; color:#1c6b1c; }
 .WARN  { background:#fff4d6 !important; color:#8a5d00; }
 .FAIL  { background:#fde3e3 !important; color:#a51414; }
 .ERROR { background:#f0e2fb !important; color:#63278f; }
 .TIMEOUT { background:#e6e9f5 !important; color:#3a4a8a; }
 /* .NA = 'N/A' durumunun sinif adi; jetonlastirma ConvertTo-EDStatusClass'tadir. */
 .NA, .PASSIVE { background:#f0f0f4 !important; color:#777; }
 .outlier { outline: 2px solid #d43b3b; outline-offset: -2px; font-weight: 700; }
 .note { color:#666; font-size: 12px; white-space: normal; max-width: 420px; }
 /* Orgu hucresi: etiket + brief'teki anlami. Sarmalanmazsa tek satirda
    tabloyu yatay kaydirmaya zorlar ve aciklama ekranin disinda kalir. */
 .orgu { font-size: 12px; white-space: normal; max-width: 300px; color:#3a4a8a; }
 .empty { color:#888; font-style: italic; }
</style>
'@)
    [void]$builder.AppendLine('</head><body>')
    [void]$builder.AppendLine('<h1>Exchange Teshis Raporu</h1>')

    [void]$builder.AppendLine('<div class="meta">')
    [void]$builder.AppendLine("Calistirma: <code>$(ConvertTo-EDHtmlEncoded $Context.RunId)</code> &middot; Baslangic: $($Context.StartTime.ToString('yyyy-MM-dd HH:mm:ss')) &middot; Saat dilimi: $(ConvertTo-EDHtmlEncoded $timeZone)<br>")
    [void]$builder.AppendLine("Baglanti: <code>$(ConvertTo-EDHtmlEncoded $Context.Executor.ExchangeConnection)</code> &middot; Esme derecesi: $($Context.Executor.Parallelism)<br>")
    [void]$builder.AppendLine("Profil: <code>$(ConvertTo-EDHtmlEncoded $environment.profile)</code> &middot; Log erisimi: <code>$(ConvertTo-EDHtmlEncoded $Context.LogAccess)</code> &middot; Log penceresi: $($Context.WindowHours) saat &middot; Heavy: $($Context.Heavy)<br>")
    if ($passiveSites.Count -gt 0) {
        [void]$builder.AppendLine("Pasif/DR site: <code>$(ConvertTo-EDHtmlEncoded ($passiveSites -join ', '))</code> &mdash; bu sitelerdeki dusuk is yuku normaldir, FAIL sayilmaz.<br>")
    }
    if ($Context.Config.UsingSampleConfig) {
        [void]$builder.AppendLine('<strong>Not:</strong> <code>Config\</code> klasoru yok; ornek/varsayilan esikler kullanildi. Esikler ONERIDIR, ortaminiza gore ayarlayin.<br>')
    }
    [void]$builder.AppendLine('Persentil yontemi: siralanmis dizide dogrusal interpolasyon. Ortalama bilerek raporlanmaz (tail gizlenir).')
    [void]$builder.AppendLine('</div>')

    # --- Bulgular ---
    [void]$builder.AppendLine("<h2>Bulgular ($($findings.Count))</h2>")
    if ($findings.Count -eq 0) {
        [void]$builder.AppendLine('<p class="empty">Esikleri asan bulgu yok.</p>')
    }
    else {
        # ORGU SUTUNU: brief Bolum 3'un P1-P8 orgusu, bulgunun yaninda ve
        # ANLAMIYLA BIRLIKTE yazilir. Etiket tek basina ('P6') operatore
        # hicbir sey soylemez; aciklama Framework.ps1'deki tek sozlukten
        # gelir, modul basina tekrarlanmaz. Orgusu olmayan satirda hucre
        # BOS kalir - '-' ya da 'YOK' yazmak, bir orgunun arastirilip
        # bulunamadigi izlenimi verirdi.
        [void]$builder.AppendLine('<table><tr><th>Durum</th><th>Modul</th><th>Kontrol</th><th>Orgu</th><th>Aciklama</th></tr>')
        foreach ($row in ($findings | Sort-Object @{ e = { @{FAIL=0;ERROR=1;TIMEOUT=2;WARN=3}[$_.Status] } }, Module)) {
            # Bir satirin birden fazla orgusu olabilir; her biri kendi
            # satirinda yazilir ki uzun aciklamalar birbirine karismasin.
            $patternCell = (@(Get-EDPatternLines -Patterns (Get-EDRowPatterns $row)) |
                ForEach-Object { ConvertTo-EDHtmlEncoded $_ }) -join '<br>'
            [void]$builder.AppendLine("<tr><td class=""st $(ConvertTo-EDStatusClass $row.Status)"">$($row.Status)</td><td>$(ConvertTo-EDHtmlEncoded $row.Module)</td><td>$(ConvertTo-EDHtmlEncoded $row.Check)</td><td class=""orgu"">$patternCell</td><td class=""note"">$(ConvertTo-EDHtmlEncoded $row.Note)</td></tr>")
        }
        [void]$builder.AppendLine('</table>')
    }

    # --- Ozet tablo ---
    # Orgu sutunu burada da vardir ve SUMMARY.csv ile ayni siradadir (Birim'den
    # sonra). Yalnizca bulgu tablosuna konsaydi, hukmu 'OK' olan orgu satirlari
    # (ornegin M10 ortalama, M13 sakin saat p95) HTML'de orgusuz gorunur, ayni
    # satir CSV'de orgulu olurdu; iki cikti ayni veriyi farkli anlatirdi.
    [void]$builder.AppendLine('<h2>Ozet &mdash; tum sunucular yan yana</h2>')
    [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Kontrol</th><th>Birim</th><th>Orgu</th>')
    foreach ($column in $Columns) { [void]$builder.AppendLine("<th>$(ConvertTo-EDHtmlEncoded $column)</th>") }
    [void]$builder.AppendLine('<th>Durum</th><th>Not</th></tr>')

    foreach ($row in $Rows) {
        $summaryPatternCell = (@(Get-EDPatternLines -Patterns (Get-EDRowPatterns $row)) |
            ForEach-Object { ConvertTo-EDHtmlEncoded $_ }) -join '<br>'
        [void]$builder.Append("<tr><td>$(ConvertTo-EDHtmlEncoded $row.Module)</td><td>$(ConvertTo-EDHtmlEncoded $row.Check)</td><td>$(ConvertTo-EDHtmlEncoded $row.Unit)</td><td class=""orgu"">$summaryPatternCell</td>")
        foreach ($column in $Columns) {
            $value = if ($row.Values.ContainsKey($column)) { $row.Values[$column] } else { $null }
            $text = if ($null -eq $value -or "$value" -eq '') { 'N/A' } else { "$value" }
            $class = 'num'
            if ($text -eq 'N/A') { $class = 'num NA' }
            if ($row.CellStatus.ContainsKey($column)) {
                $cellStatus = $row.CellStatus[$column]
                # Durum adi degil, SINIF adi yazilir: 'N/A' bir sinif jetonu
                # olarak '.NA' ile eslesmez ve hucre renksiz kalirdi.
                $class = "num $(ConvertTo-EDStatusClass $cellStatus)"
                if ($cellStatus -in @('WARN', 'FAIL')) { $class += ' outlier' }
            }
            [void]$builder.Append("<td class=""$class"">$(ConvertTo-EDHtmlEncoded $text)</td>")
        }
        [void]$builder.AppendLine("<td class=""st $(ConvertTo-EDStatusClass $row.Status)"">$($row.Status)</td><td class=""note"">$(ConvertTo-EDHtmlEncoded $row.Note)</td></tr>")
    }
    [void]$builder.AppendLine('</table>')

    # --- Modul sureleri (maliyet bilinci, brief ilke 10) ---
    if ($ModuleTimings.Count -gt 0) {
        [void]$builder.AppendLine('<h2>Modul sureleri</h2>')
        [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Ad</th><th>Sure (sn)</th><th>Satir</th><th>Durum</th></tr>')
        foreach ($timing in ($ModuleTimings | Sort-Object -Property Seconds -Descending)) {
            [void]$builder.AppendLine("<tr><td>$(ConvertTo-EDHtmlEncoded $timing.Id)</td><td>$(ConvertTo-EDHtmlEncoded $timing.Name)</td><td class=""num"">$($timing.Seconds)</td><td class=""num"">$($timing.RowCount)</td><td class=""st $(ConvertTo-EDStatusClass $timing.Status)"">$($timing.Status)</td></tr>")
        }
        [void]$builder.AppendLine('</table>')
    }

    [void]$builder.AppendLine('<h2>Uyari</h2>')
    [void]$builder.AppendLine('<p class="meta">Bu arac SALT OKUNURDUR; ortamda hicbir degisiklik yapmaz. Esik degerleri onerilerdir ve her ortama gore ayarlanmalidir. Sakin saatte alinan olcum yaniltir &mdash; yogun saatte tekrar calistirip <code>-CompareWith</code> ile karsilastirin.</p>')
    [void]$builder.AppendLine('</body></html>')

    [System.IO.File]::WriteAllText($Path, $builder.ToString(), [System.Text.Encoding]::UTF8)
    return $Path
}

function Write-EDConsoleSummary {
    <# Terminalde hizli okunur ozet. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rows, [Parameter(Mandatory)][string[]]$Columns)

    if ($Rows.Count -eq 0) { return }

    $table = foreach ($row in $Rows) {
        $record = [ordered]@{ Modul = $row.Module; Kontrol = $row.Check }
        foreach ($column in $Columns) {
            $record[$column] = if ($row.Values.ContainsKey($column)) { $row.Values[$column] } else { '' }
        }
        $record['Durum'] = $row.Status
        [pscustomobject]$record
    }
    $table | Format-Table -AutoSize | Out-String -Width 240 | Write-Host
}
