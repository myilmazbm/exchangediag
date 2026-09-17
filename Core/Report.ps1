<#
    ExchangeDiag - Rapor uretimi

    Brief Bolum 8: her modul tum sunucular icin tek satir uretir, sunucular yan
    yana dizilir ve SAPAN HUCRE VURGULANIR. Rapor ilk bakista "hangi sunucu
    farkli" sorusunu cevaplamalidir.
#>

function Get-EDReportColumns {
    <# Sutun sirasi: once topolojideki sunucular, sonra satirlarda gecen digerleri. #>
    param($Rows, [string[]]$PreferredOrder)

    $columns = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $PreferredOrder) {
        if ($name -and -not $columns.Contains($name)) { [void]$columns.Add($name) }
    }
    foreach ($row in $Rows) {
        foreach ($key in $row.Values.Keys) {
            if (-not $columns.Contains($key)) { [void]$columns.Add($key) }
        }
    }
    return $columns.ToArray()
}

function Export-EDSummaryCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)][string[]]$Columns,
        [Parameter(Mandatory)][string]$Path
    )

    $records = foreach ($row in $Rows) {
        $record = [ordered]@{
            Modul   = $row.Module
            Kontrol = $row.Check
            Birim   = $row.Unit
        }
        foreach ($column in $Columns) {
            # SUMMARY.csv makine tarafindan da okunur (-CompareWith). Sayilar
            # CurrentCulture ile yazilirsa tr-TR'de "12,5" olur ve delta motoru
            # onu 125 okur. Sunum bicimi HTML'in isi; burasi veri sozlesmesi.
            $cell = if ($row.Values.ContainsKey($column)) { $row.Values[$column] } else { '' }
            if ($cell -is [double] -or $cell -is [single] -or $cell -is [decimal]) {
                $cell = ([double]$cell).ToString([System.Globalization.CultureInfo]::InvariantCulture)
            }
            $record[$column] = $cell
        }
        $record['Durum'] = $row.Status
        $record['Not']   = $row.Note
        [pscustomobject]$record
    }

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
 .NA, .PASSIVE { background:#f0f0f4 !important; color:#777; }
 .outlier { outline: 2px solid #d43b3b; outline-offset: -2px; font-weight: 700; }
 .note { color:#666; font-size: 12px; white-space: normal; max-width: 420px; }
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
        [void]$builder.AppendLine('<table><tr><th>Durum</th><th>Modul</th><th>Kontrol</th><th>Aciklama</th></tr>')
        foreach ($row in ($findings | Sort-Object @{ e = { @{FAIL=0;ERROR=1;TIMEOUT=2;WARN=3}[$_.Status] } }, Module)) {
            [void]$builder.AppendLine("<tr><td class=""st $($row.Status)"">$($row.Status)</td><td>$(ConvertTo-EDHtmlEncoded $row.Module)</td><td>$(ConvertTo-EDHtmlEncoded $row.Check)</td><td class=""note"">$(ConvertTo-EDHtmlEncoded $row.Note)</td></tr>")
        }
        [void]$builder.AppendLine('</table>')
    }

    # --- Ozet tablo ---
    [void]$builder.AppendLine('<h2>Ozet &mdash; tum sunucular yan yana</h2>')
    [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Kontrol</th><th>Birim</th>')
    foreach ($column in $Columns) { [void]$builder.AppendLine("<th>$(ConvertTo-EDHtmlEncoded $column)</th>") }
    [void]$builder.AppendLine('<th>Durum</th><th>Not</th></tr>')

    foreach ($row in $Rows) {
        [void]$builder.Append("<tr><td>$(ConvertTo-EDHtmlEncoded $row.Module)</td><td>$(ConvertTo-EDHtmlEncoded $row.Check)</td><td>$(ConvertTo-EDHtmlEncoded $row.Unit)</td>")
        foreach ($column in $Columns) {
            $value = if ($row.Values.ContainsKey($column)) { $row.Values[$column] } else { $null }
            $text = if ($null -eq $value -or "$value" -eq '') { 'N/A' } else { "$value" }
            $class = 'num'
            if ($text -eq 'N/A') { $class = 'num NA' }
            if ($row.CellStatus.ContainsKey($column)) {
                $cellStatus = $row.CellStatus[$column]
                $class = "num $cellStatus"
                if ($cellStatus -in @('WARN', 'FAIL')) { $class += ' outlier' }
            }
            [void]$builder.Append("<td class=""$class"">$(ConvertTo-EDHtmlEncoded $text)</td>")
        }
        [void]$builder.AppendLine("<td class=""st $($row.Status)"">$($row.Status)</td><td class=""note"">$(ConvertTo-EDHtmlEncoded $row.Note)</td></tr>")
    }
    [void]$builder.AppendLine('</table>')

    # --- Modul sureleri (maliyet bilinci, brief ilke 10) ---
    if ($ModuleTimings.Count -gt 0) {
        [void]$builder.AppendLine('<h2>Modul sureleri</h2>')
        [void]$builder.AppendLine('<table><tr><th>Modul</th><th>Ad</th><th>Sure (sn)</th><th>Satir</th><th>Durum</th></tr>')
        foreach ($timing in ($ModuleTimings | Sort-Object -Property Seconds -Descending)) {
            [void]$builder.AppendLine("<tr><td>$(ConvertTo-EDHtmlEncoded $timing.Id)</td><td>$(ConvertTo-EDHtmlEncoded $timing.Name)</td><td class=""num"">$($timing.Seconds)</td><td class=""num"">$($timing.RowCount)</td><td class=""st $($timing.Status)"">$($timing.Status)</td></tr>")
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
