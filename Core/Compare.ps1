<#
    ExchangeDiag - Calistirmalar arasi delta (-CompareWith)

    Amaci "sakin saat vs yogun saat" kiyasidir (brief ilke 8). Tek bir olcum
    bir sayidir; iki olcum bir YONDUR ve teshiste asil deger yondedir.

    ===================================================================
    BU MOTORUN ASIL ISI DELTA HESAPLAMAK DEGIL, HANGI DELTANIN ANLAMSIZ
    OLDUGUNU SOYLEMEKTIR.
    ===================================================================

    Sessizce yanlis kiyas yapmanin dort yolu vardir ve dordu de engellenir:

    1. KAPSAM FARKI. Onceki calistirma 1 saatlik pencereyle, yenisi 24
       saatlikse persentiller zaten farkli cikar - bu bir degisim DEGIL,
       olcum farkidir. Ayni sey -Heavy, sunucu filtresi ve modul kumesi
       icin de gecerlidir. run-meta.json bu yuzden yazilir.

    2. N/A SINIRI. "Olculemedi" ile "sifir" ayni sey degildir. N/A'dan bir
       degere gecis IYILESME DEGILDIR; yalnizca artik olcebiliyoruz demektir.
       Bu gecisler yuzde olarak raporlanmaz.

    3. KUCUK SAYIDA BUYUK YUZDE. 0.001 -> 0.002 yuzde olarak %100 artistir
       ama hicbir sey ifade etmez. Mutlak taban altinda kalan degisimler
       yuzdesiz, yalnizca mutlak farkla raporlanir.

    4. SAAT FARKI. Farkli saatlerde alinan iki olcum arasindaki fark
       gerilemeye degil YUKE bagli olabilir. Bu, kiyasin amaci oldugu icin
       hata sayilmaz ama HATIRLATILIR.

    Metin degerlerde (Mounted, build numarasi, teshis cumlesi) yuzde
    hesaplanmaz; yalnizca "degisti / degismedi" denir.
#>

# Yuzde hesabinin anlamli oldugu mutlak taban. Bunun altindaki degerlerde
# yuzde yaniltir ve yalnizca mutlak fark yazilir.
$script:EDDeltaFloor = 0.5

function Save-EDRunMeta {
<#
    .SYNOPSIS
        Calistirmanin KAPSAMINI diske yazar.

    .DESCRIPTION
        Delta motorunun "bu iki calistirma kiyaslanabilir mi?" sorusunu
        cevaplayabilmesi icin gereklidir. Bu dosya olmadan yapilan kiyas,
        farkli pencerelerle alinmis olcumleri sessizce yan yana koyar.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        $ModuleTimings = @()
    )

    $servers = @()
    if ($Context.Topology) { $servers = @($Context.Topology.Servers | ForEach-Object { $_.Name }) }

    $meta = [ordered]@{
        runId          = $Context.RunId
        startedLocal   = $Context.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
        startedHour    = [int]$Context.StartTime.Hour
        utcOffsetHours = [math]::Round([System.TimeZoneInfo]::Local.GetUtcOffset($Context.StartTime).TotalHours, 2)
        windowHours    = $Context.WindowHours
        heavy          = [bool]$Context.Heavy
        logAccess      = [string]$Context.LogAccess
        serverFilter   = @($Context.ServerFilter)
        servers        = @($servers | Sort-Object)
        profile        = [string]$Context.Config.Environment['profile']
        modules        = @(@($ModuleTimings | ForEach-Object { $_.Id }) | Sort-Object)
    }

    $json = $meta | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Read-EDRunMeta {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Folder)

    $path = Join-Path $Folder 'run-meta.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Test-EDRunComparable {
<#
    .SYNOPSIS
        Iki calistirmanin kiyaslanabilirligini denetler.

    .OUTPUTS
        Blocking : kiyasi anlamsiz kilan farklar (pencere, heavy, log erisimi)
        Advisory : dikkat edilmesi gereken ama kiyasi gecersiz kilmayan farklar
#>
    [CmdletBinding()]
    param($Previous, $Current)

    $blocking = @()
    $advisory = @()

    if (-not $Previous) {
        $blocking += 'Onceki calistirmada run-meta.json yok (eski surumle uretilmis olabilir); kapsam farki DENETLENEMEDI. Delta yalnizca bilgi amaclidir.'
        return [pscustomobject]@{ Blocking = $blocking; Advisory = $advisory; Comparable = $false }
    }

    # --- Kiyasi gecersiz kilan farklar ---
    if ([double]$Previous.windowHours -ne [double]$Current.windowHours) {
        $blocking += ("Log penceresi farkli: onceki {0} saat, simdiki {1} saat. Persentiller zaten farkli cikar; bu bir DEGISIM degil OLCUM FARKIDIR." -f `
            $Previous.windowHours, $Current.windowHours)
    }
    if ([bool]$Previous.heavy -ne [bool]$Current.heavy) {
        $blocking += ("-Heavy farkli (onceki {0}, simdiki {1}): agir moduller yalnizca birinde kosmus; eksik satirlar 'kayboldu' sanilmamalidir." -f `
            $Previous.heavy, $Current.heavy)
    }
    if ([string]$Previous.logAccess -ne [string]$Current.logAccess) {
        $blocking += ("Log erisim yolu farkli (onceki '{0}', simdiki '{1}'): ham ayristirici ile cmdlet ayni pencerede farkli sayida kayit gorebilir." -f `
            $Previous.logAccess, $Current.logAccess)
    }

    # --- Dikkat gerektiren ama kiyasi gecersiz kilmayan farklar ---
    $previousServers = @($Previous.servers)
    $currentServers = @($Current.servers)
    $gone = @($previousServers | Where-Object { $_ -notin $currentServers })
    $added = @($currentServers | Where-Object { $_ -notin $previousServers })
    if ($gone.Count -gt 0) { $advisory += ("Onceki calistirmada olup simdi olmayan sunucu: {0}" -f ($gone -join ', ')) }
    if ($added.Count -gt 0) { $advisory += ("Simdi eklenen sunucu: {0}" -f ($added -join ', ')) }

    if ([string]$Previous.profile -ne [string]$Current.profile) {
        $advisory += ("Profil farkli (onceki '{0}', simdiki '{1}'): esikler ve bastirilan bulgular degismis olabilir." -f $Previous.profile, $Current.profile)
    }

    # Saat farki: kiyasin AMACI budur, ama yorumlanirken bilinmelidir.
    $previousHour = [int]$Previous.startedHour
    $currentHour = [int]$Current.startedHour
    if ($previousHour -ne $currentHour) {
        $advisory += ("Calistirma saatleri farkli ({0:d2}:00 -> {1:d2}:00). Bu kiyasin AMACIDIR (sakin vs yogun saat); ancak farkin sebebi gerileme degil YUK olabilir." -f `
            $previousHour, $currentHour)
    }

    return [pscustomobject]@{
        Blocking   = $blocking
        Advisory   = $advisory
        Comparable = ($blocking.Count -eq 0)
    }
}

function Get-EDDeltaKind {
    <# Iki degerin karsilastirma turunu belirler. #>
    param([AllowNull()]$Previous, [AllowNull()]$Current)

    $previousText = "$Previous".Trim()
    $currentText = "$Current".Trim()

    $previousMissing = (-not $previousText -or $previousText -in @('N/A', 'PASSIVE', '-'))
    $currentMissing = (-not $currentText -or $currentText -in @('N/A', 'PASSIVE', '-'))

    if ($previousMissing -and $currentMissing) { return 'both-missing' }
    if ($previousMissing -or $currentMissing) { return 'measurement-change' }

    # "Sayi mi?" testi ile aritmetigin AYNI ayristiriciyi kullanmasi sart.
    # Eskiden test CurrentCulture, aritmetik invariant idi: tr-TR'de yazilan
    # "12,5" once 12.5 sonra 125 okunuyor, iki OZDES kosu hayalet delta
    # uretiyordu.
    $previousNumber = ConvertTo-EDNumber $previousText
    $currentNumber = ConvertTo-EDNumber $currentText

    if ($null -ne $previousNumber -and $null -ne $currentNumber) { return 'numeric' }
    return 'text'
}

function Compare-EDRuns {
<#
    .SYNOPSIS
        Onceki calistirma klasoru ile simdiki satirlari karsilastirir.

    .OUTPUTS
        Satir basina delta kayitlari + kapsam denetimi sonucu.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PreviousFolder,
        [Parameter(Mandatory)]$CurrentRows,
        [Parameter(Mandatory)]$Context,
        $ModuleTimings = @()
    )

    $previousCsv = Join-Path $PreviousFolder 'SUMMARY.csv'
    if (-not (Test-Path -LiteralPath $previousCsv)) {
        throw "Karsilastirilacak calistirma bulunamadi: $previousCsv"
    }

    $previousRows = @(Import-Csv -LiteralPath $previousCsv -Encoding UTF8)
    $previousMeta = Read-EDRunMeta -Folder $PreviousFolder

    $currentMeta = [pscustomobject]@{
        windowHours = $Context.WindowHours
        heavy       = [bool]$Context.Heavy
        logAccess   = [string]$Context.LogAccess
        profile     = [string]$Context.Config.Environment['profile']
        startedHour = [int]$Context.StartTime.Hour
        servers     = @(@($Context.Topology.Servers | ForEach-Object { $_.Name }) | Sort-Object)
    }
    $scope = Test-EDRunComparable -Previous $previousMeta -Current $currentMeta

    # --- Onceki satirlari (Modul, Kontrol) ile indeksle ---
    $previousIndex = @{}
    $previousColumns = @()
    if ($previousRows.Count -gt 0) {
        $previousColumns = @($previousRows[0].PSObject.Properties.Name |
            Where-Object { $_ -notin @('Modul', 'Kontrol', 'Birim', 'Durum', 'Not') })
    }
    foreach ($row in $previousRows) {
        $previousIndex["$($row.Modul)|$($row.Kontrol)"] = $row
    }

    $deltas = @()
    $seenKeys = @{}

    foreach ($row in $CurrentRows) {
        $key = "$($row.Module)|$($row.Check)"
        $seenKeys[$key] = $true
        $previous = $previousIndex[$key]

        if (-not $previous) {
            $deltas += [pscustomobject]@{
                Modul     = $row.Module
                Kontrol   = $row.Check
                Sunucu    = '-'
                Onceki    = '(yok)'
                Simdiki   = $row.Status
                Fark      = '-'
                Yon       = 'YENI'
                Durum     = ("{0} -> {1}" -f '-', $row.Status)
                Aciklama  = 'Bu kontrol onceki calistirmada yok. Modul kumesi degismis olabilir; bir degisim DEGILDIR.'
            }
            continue
        }

        $statusChanged = ([string]$previous.Durum -ne [string]$row.Status)

        foreach ($column in @($row.Values.Keys)) {
            # Sutun onceki calistirmada yoksa (yeni sunucu) kiyas kurulmaz.
            if ($column -notin $previousColumns) {
                $deltas += [pscustomobject]@{
                    Modul = $row.Module; Kontrol = $row.Check; Sunucu = $column
                    Onceki = '(sutun yok)'; Simdiki = "$($row.Values[$column])"; Fark = '-'
                    Yon = 'YENI'; Durum = ''
                    Aciklama = 'Bu sutun onceki calistirmada yoktu; kiyas kurulamaz.'
                }
                continue
            }

            $previousValue = $previous.$column
            $currentValue = $row.Values[$column]
            $kind = Get-EDDeltaKind -Previous $previousValue -Current $currentValue

            if ($kind -eq 'both-missing') { continue }

            $record = [ordered]@{
                Modul   = $row.Module
                Kontrol = $row.Check
                Sunucu  = $column
                Onceki  = "$previousValue"
                Simdiki = "$currentValue"
                Fark    = ''
                Yon     = ''
                Durum   = $(if ($statusChanged) { "$($previous.Durum) -> $($row.Status)" } else { '' })
                Aciklama = ''
            }

            # DIKKAT: burada switch KULLANILMAZ. PowerShell'de switch icindeki
            # 'continue' kapsayan foreach'i degil SWITCH'i sonlandirir; bu
            # yuzden "fark yok" durumlari da delta olarak yazilir ve rapor
            # degismemis 20 satiri "fark" diye gosterir. Acik bir bayrak
            # kullanmak bu tuzagi tamamen kaldirir.
            $hasDifference = $true

            if ($kind -eq 'measurement-change') {
                $record.Fark = '-'
                $record.Yon = 'OLCUM'
                # N/A -> deger "iyilesme" DEGILDIR; yalnizca artik olcebiliyoruz.
                $record.Aciklama = 'Olcum durumu degisti (N/A <-> deger). Bu bir iyilesme veya gerileme DEGILDIR; yalnizca olcum yapilabilirligi degismistir.'
            }
            elseif ($kind -eq 'text') {
                if ("$previousValue" -eq "$currentValue") {
                    $hasDifference = $false
                }
                else {
                    $record.Fark = '-'
                    $record.Yon = 'DEGISTI'
                    $record.Aciklama = 'Metin deger degisti; yuzde hesaplanmaz.'
                }
            }
            elseif ($kind -eq 'numeric') {
                # 'numeric' hukmunu veren ayristiricinin ta kendisi.
                $previousNumber = ConvertTo-EDNumber $previousValue
                $currentNumber = ConvertTo-EDNumber $currentValue
                $difference = $currentNumber - $previousNumber

                if ($difference -eq 0) {
                    $hasDifference = $false
                }
                else {
                    $record.Yon = $(if ($difference -gt 0) { 'ARTTI' } else { 'AZALDI' })

                    # Kucuk sayilarda yuzde yaniltir: 0.001 -> 0.002 = %100.
                    if ([math]::Abs($previousNumber) -lt $script:EDDeltaFloor) {
                        $record.Fark = ("{0:+0.###;-0.###}" -f $difference)
                        $record.Aciklama = ("Onceki deger cok kucuk ({0}); yuzde YANILTIR, yalnizca mutlak fark verildi." -f $previousNumber)
                    }
                    else {
                        $percent = 100.0 * $difference / [math]::Abs($previousNumber)
                        $record.Fark = ("{0:+0.###;-0.###} (%{1:+0.#;-0.#})" -f $difference, $percent)
                        if ([math]::Abs($percent) -lt 5) {
                            $record.Aciklama = 'Degisim %5 altinda; olcum gurultusu olabilir.'
                        }
                    }
                }
            }

            # Deger ayni ama DURUM degistiyse (esik degismis olabilir) satir
            # yine gosterilir - aksi halde gercek bir bulgu gizlenir.
            $valueUnchanged = (-not $hasDifference)
            if ($valueUnchanged -and $statusChanged) {
                $hasDifference = $true
                $record.Fark = '0'
                $record.Yon = 'DURUM'
            }

            if (-not $hasDifference) { continue }

            if ($statusChanged -and -not $record.Aciklama) {
                # DIKKAT: "deger ayni" cumlesi yalnizca deger GERCEKTEN ayniyken
                # kurulabilir. Aksi halde rapor, 16.8 -> 82.6 gibi bariz bir
                # degisimin yanina "deger ayni" yazar ve kendi verisini yalanlar.
                $record.Aciklama = $(if ($valueUnchanged) {
                    'Deger ayni, DURUM degisti; esik veya kiyas tabani degismis olabilir.'
                } else {
                    'Durum degisti; bulguyu ozet raporun Not sutunuyla birlikte okuyun.'
                })
            }

            $deltas += [pscustomobject]$record
        }

        # Degeri olmayan ama durumu degisen satirlar da gorunmeli.
        if ($statusChanged -and @($row.Values.Keys).Count -eq 0) {
            $deltas += [pscustomobject]@{
                Modul = $row.Module; Kontrol = $row.Check; Sunucu = '-'
                Onceki = "$($previous.Durum)"; Simdiki = "$($row.Status)"; Fark = '-'
                Yon = 'DURUM'; Durum = "$($previous.Durum) -> $($row.Status)"
                Aciklama = 'Deger yok, yalnizca durum degisti.'
            }
        }
    }

    # --- Onceki calistirmada olup simdi olmayan kontroller ---
    foreach ($key in @($previousIndex.Keys)) {
        if ($seenKeys.ContainsKey($key)) { continue }
        $previous = $previousIndex[$key]
        $deltas += [pscustomobject]@{
            Modul = $previous.Modul; Kontrol = $previous.Kontrol; Sunucu = '-'
            Onceki = "$($previous.Durum)"; Simdiki = '(yok)'; Fark = '-'
            Yon = 'KAYBOLDU'; Durum = ''
            Aciklama = 'Bu kontrol simdiki calistirmada yok. Modul atlanmis veya kapsam degismis olabilir - sorunun gectigi anlamina GELMEZ.'
        }
    }

    return [pscustomobject]@{
        Deltas          = @($deltas)
        Scope           = $scope
        PreviousFolder  = $PreviousFolder
        PreviousMeta    = $previousMeta
        PreviousRunId   = $(if ($previousMeta) { $previousMeta.runId } else { Split-Path -Leaf $PreviousFolder })
    }
}

function Get-EDDeltaHighlights {
    <#
        Durum gerilemeleri (OK -> WARN/FAIL) ve iyilesmeler ayri toplanir.
        Bir delta raporunda ilk okunmasi gereken budur.
    #>
    [CmdletBinding()]
    param($Comparison)

    $rank = @{ 'OK' = 0; 'N/A' = 0; 'PASSIVE' = 0; 'TIMEOUT' = 1; 'WARN' = 2; 'ERROR' = 3; 'FAIL' = 4 }
    $regressions = @()
    $improvements = @()
    $seen = @{}

    foreach ($delta in @($Comparison.Deltas)) {
        if (-not $delta.Durum -or $delta.Durum -notmatch '^(\S+) -> (\S+)$') { continue }
        $key = "$($delta.Modul)|$($delta.Kontrol)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $from = $Matches[1]; $to = $Matches[2]
        if (-not $rank.ContainsKey($from) -or -not $rank.ContainsKey($to)) { continue }

        if ($rank[$to] -gt $rank[$from]) {
            $regressions += [pscustomobject]@{ Modul = $delta.Modul; Kontrol = $delta.Kontrol; Gecis = $delta.Durum }
        }
        elseif ($rank[$to] -lt $rank[$from]) {
            $improvements += [pscustomobject]@{ Modul = $delta.Modul; Kontrol = $delta.Kontrol; Gecis = $delta.Durum }
        }
    }

    return [pscustomobject]@{ Regressions = @($regressions); Improvements = @($improvements) }
}

function Export-EDDeltaHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Comparison,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Context
    )

    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $highlights = Get-EDDeltaHighlights -Comparison $Comparison
    $scope = $Comparison.Scope

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('<!DOCTYPE html><html lang="tr"><head><meta charset="utf-8">')
    [void]$builder.AppendLine('<title>Exchange Teshis &mdash; Delta</title>')
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
 th { background: #eef0f5; font-weight: 600; }
 td.num { text-align: right; font-variant-numeric: tabular-nums; }
 tr:nth-child(even) td { background: #f7f7fb; }
 .blocking { background:#fde3e3; border:1px solid #e8a0a0; padding:10px 14px; border-radius:4px; margin:12px 0; }
 .advisory { background:#fff4d6; border:1px solid #e6c97a; padding:10px 14px; border-radius:4px; margin:12px 0; }
 .blocking h3, .advisory h3 { margin:0 0 6px; font-size:13px; }
 .blocking ul, .advisory ul { margin:4px 0 0 18px; padding:0; font-size:12px; line-height:1.6; }
 .ARTTI   { color:#a51414; font-weight:700; }
 .AZALDI  { color:#1c6b1c; font-weight:700; }
 .OLCUM, .YENI, .KAYBOLDU, .DEGISTI, .DURUM { color:#63278f; font-weight:700; }
 .note { color:#666; font-size:12px; white-space:normal; max-width:460px; }
 .empty { color:#888; font-style:italic; }
</style>
'@)
    [void]$builder.AppendLine('</head><body>')
    [void]$builder.AppendLine('<h1>Exchange Teshis &mdash; Delta</h1>')

    $previousHour = '?'
    if ($Comparison.PreviousMeta) { $previousHour = '{0:d2}:00' -f [int]$Comparison.PreviousMeta.startedHour }
    [void]$builder.AppendLine('<div class="meta">')
    [void]$builder.AppendLine("Onceki: <code>$(ConvertTo-EDHtmlEncoded $Comparison.PreviousRunId)</code> ($previousHour) &rarr; Simdiki: <code>$(ConvertTo-EDHtmlEncoded $Context.RunId)</code> ($('{0:d2}:00' -f $Context.StartTime.Hour))<br>")
    # DIKKAT: TAM YOL YAZILMAZ. Yol kullanici adini icerir (C:\Users\<ad>\...)
    # ve bu rapor e-postayla dolasan, paylasilan bir dosyadir. Klasor adi
    # zaten zaman damgasidir; tanimlayici olan kisim odur, ust dizin degil.
    [void]$builder.AppendLine("Kaynak klasor: <code>$(ConvertTo-EDHtmlEncoded (Split-Path -Leaf $Comparison.PreviousFolder))</code>")
    [void]$builder.AppendLine('</div>')

    # --- Kapsam denetimi: raporun EN USTUNDE ---
    if (@($scope.Blocking).Count -gt 0) {
        [void]$builder.AppendLine('<div class="blocking"><h3>KIYAS GUVENILIR DEGIL &mdash; kapsam farkli</h3><ul>')
        foreach ($item in @($scope.Blocking)) { [void]$builder.AppendLine("<li>$(ConvertTo-EDHtmlEncoded $item)</li>") }
        [void]$builder.AppendLine('</ul><p style="margin:8px 0 0;font-size:12px;">Asagidaki farklar bir DEGISIMI degil, olcum kosullarinin farkini yansitiyor olabilir. Ayni kapsamla tekrar calistirin.</p></div>')
    }
    if (@($scope.Advisory).Count -gt 0) {
        [void]$builder.AppendLine('<div class="advisory"><h3>Dikkat</h3><ul>')
        foreach ($item in @($scope.Advisory)) { [void]$builder.AppendLine("<li>$(ConvertTo-EDHtmlEncoded $item)</li>") }
        [void]$builder.AppendLine('</ul></div>')
    }

    # --- Durum gecisleri ---
    [void]$builder.AppendLine("<h2>Gerilemeler ($(@($highlights.Regressions).Count))</h2>")
    if (@($highlights.Regressions).Count -eq 0) {
        [void]$builder.AppendLine('<p class="empty">Durum gerilemesi yok.</p>')
    }
    else {
        [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Kontrol</th><th>Gecis</th></tr>')
        foreach ($item in @($highlights.Regressions)) {
            [void]$builder.AppendLine("<tr><td>$(ConvertTo-EDHtmlEncoded $item.Modul)</td><td>$(ConvertTo-EDHtmlEncoded $item.Kontrol)</td><td class=""ARTTI"">$(ConvertTo-EDHtmlEncoded $item.Gecis)</td></tr>")
        }
        [void]$builder.AppendLine('</table>')
    }

    [void]$builder.AppendLine("<h2>Iyilesmeler ($(@($highlights.Improvements).Count))</h2>")
    if (@($highlights.Improvements).Count -eq 0) {
        [void]$builder.AppendLine('<p class="empty">Durum iyilesmesi yok.</p>')
    }
    else {
        [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Kontrol</th><th>Gecis</th></tr>')
        foreach ($item in @($highlights.Improvements)) {
            [void]$builder.AppendLine("<tr><td>$(ConvertTo-EDHtmlEncoded $item.Modul)</td><td>$(ConvertTo-EDHtmlEncoded $item.Kontrol)</td><td class=""AZALDI"">$(ConvertTo-EDHtmlEncoded $item.Gecis)</td></tr>")
        }
        [void]$builder.AppendLine('</table>')
    }

    # --- Tum farklar ---
    $deltas = @($Comparison.Deltas)
    [void]$builder.AppendLine("<h2>Tum farklar ($($deltas.Count))</h2>")
    if ($deltas.Count -eq 0) {
        [void]$builder.AppendLine('<p class="empty">Iki calistirma arasinda fark yok.</p>')
    }
    else {
        [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Kontrol</th><th>Sunucu</th><th>Onceki</th><th>Simdiki</th><th>Fark</th><th>Yon</th><th>Durum</th><th>Aciklama</th></tr>')
        foreach ($delta in $deltas) {
            [void]$builder.AppendLine(("<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class=""num"">{3}</td><td class=""num"">{4}</td><td class=""num"">{5}</td><td class=""{6}"">{6}</td><td>{7}</td><td class=""note"">{8}</td></tr>" -f `
                (ConvertTo-EDHtmlEncoded $delta.Modul), (ConvertTo-EDHtmlEncoded $delta.Kontrol), (ConvertTo-EDHtmlEncoded $delta.Sunucu),
                (ConvertTo-EDHtmlEncoded $delta.Onceki), (ConvertTo-EDHtmlEncoded $delta.Simdiki), (ConvertTo-EDHtmlEncoded $delta.Fark),
                (ConvertTo-EDHtmlEncoded $delta.Yon), (ConvertTo-EDHtmlEncoded $delta.Durum), (ConvertTo-EDHtmlEncoded $delta.Aciklama)))
        }
        [void]$builder.AppendLine('</table>')
    }

    [void]$builder.AppendLine('<h2>Uyari</h2>')
    [void]$builder.AppendLine('<p class="meta">Delta bir YON gosterir, sebep gostermez. N/A ile deger arasindaki gecisler iyilesme/gerileme sayilmaz. Kucuk mutlak degerlerde yuzde bilerek gizlenmistir.</p>')
    [void]$builder.AppendLine('</body></html>')

    [System.IO.File]::WriteAllText($Path, $builder.ToString(), [System.Text.Encoding]::UTF8)
    return $Path
}

function Write-EDDeltaConsole {
    [CmdletBinding()]
    param($Comparison, $Log)

    $scope = $Comparison.Scope
    foreach ($item in @($scope.Blocking)) { $Log.Warn("KIYAS: $item") }
    foreach ($item in @($scope.Advisory)) { $Log.Info("Kiyas notu: $item") }

    $highlights = Get-EDDeltaHighlights -Comparison $Comparison
    $regressions = @($highlights.Regressions)
    $improvements = @($highlights.Improvements)

    if ($regressions.Count -gt 0) {
        $Log.Warn("Delta: $($regressions.Count) gerileme - " + (@($regressions | ForEach-Object { "$($_.Modul)/$($_.Kontrol) $($_.Gecis)" }) -join ' | '))
    }
    if ($improvements.Count -gt 0) {
        $Log.Info("Delta: $($improvements.Count) iyilesme - " + (@($improvements | ForEach-Object { "$($_.Modul)/$($_.Kontrol) $($_.Gecis)" }) -join ' | '))
    }
    if ($regressions.Count -eq 0 -and $improvements.Count -eq 0) {
        $Log.Info("Delta: durum gecisi yok; $(@($Comparison.Deltas).Count) deger farki bulundu.")
    }
}
