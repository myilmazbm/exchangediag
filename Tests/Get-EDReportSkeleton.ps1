<#
    Bir kosumun TANISAL ISKELETINI cikarir; gercek sunucu, posta kutusu ve
    veritabani adlarini MASKELER.

    NEDEN VAR: prod raporu paylasilamaz (sunucu/kullanici adi tasir) ama
    teshisin kendisi bu adlara BAGLI DEGILDIR - hangi orgulerin kuruldugu,
    kapsam oranlari ve durum dagilimi adsiz da okunur. Bu betik o iskeleti
    verir ki uzaktan yorum yapilabilsin.

    Kullanim:
        .\Tests\Get-EDReportSkeleton.ps1 -RunPath .\output\20260920-091500

    CIKTIYI YAPISTIRMADAN ONCE GOZDEN GECIRIN. Maskeleme sunucu sutunlarini
    ve e-posta adreslerini kapsar; ortaminiza ozgu baska bir ad (proje kodu,
    sirket adi) notlarda gecerse onu elle temizleyin.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunPath)

$csv = Join-Path $RunPath 'SUMMARY.csv'
if (-not (Test-Path -LiteralPath $csv)) { throw "SUMMARY.csv bulunamadi: $csv" }
$rows = @(Import-Csv -LiteralPath $csv)
if ($rows.Count -eq 0) { throw 'SUMMARY.csv bos.' }

$meta = @('Modul', 'Kontrol', 'Birim', 'Orgu', 'Durum', 'Not')
$serverColumns = @($rows[0].PSObject.Properties.Name | Where-Object { $_ -notin $meta })

# SUNUCU ile VERITABANI AYRILIR. Rapor sutunlari her zaman sunucu DEGILDIR:
# M12 ve M23 satirlari veritabani adlariyla anahtarlanir. Hepsine 'SRV'
# demek okuyani yanlis yere bakmaya goturur. run-meta.json sunucu listesini
# ayrica tasir; ayrimi oradan alinir.
$realServers = @()
$metaPath = Join-Path $RunPath 'run-meta.json'
if (Test-Path -LiteralPath $metaPath) {
    try {
        $runMeta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($runMeta.PSObject.Properties['servers']) { $realServers = @($runMeta.servers) }
        # Notlarda gecen ama sutun OLMAYAN varlik adlari da maskelenmeli.
        if ($runMeta.PSObject.Properties['entities']) {
            $serverColumns = @(@($serverColumns) + @($runMeta.entities) | Select-Object -Unique)
        }
    }
    catch { }
}

# SUTUN OLMAYAN ADLAR DA SIZAR. M32'nin notu "DB05 aktif SRV2 uzerinde"
# der; DB05 hicbir sutunda gecmez, yani sutun listesine bakan bir maske
# onu KACIRIR. Aracin kendi kanit dosyalari tam listeyi tasiyor.
$maskWarnings = @()
foreach ($evidence in @('M01-databases', 'M01-servers', 'M01-dags')) {
    $path = Join-Path $RunPath "$evidence.csv"
    if (-not (Test-Path -LiteralPath $path)) {
        $maskWarnings += $evidence
        continue
    }
    foreach ($record in @(Import-Csv -LiteralPath $path)) {
        foreach ($field in @('Name', 'Server', 'MountedOnServer', 'Witness')) {
            $property = $record.PSObject.Properties[$field]
            if ($null -eq $property) { continue }
            $value = [string]$property.Value
            if ($value -and $value -notin $serverColumns) { $serverColumns += $value }
        }
    }
}

# Uzun addan kisaya degistirilir ki 'MBX1' ile 'MBX10' birbirine karismasin.
$map = @{}
$srvNo = 0; $dbNo = 0
foreach ($name in @($serverColumns | Where-Object { $_ } | Sort-Object -Property Length -Descending)) {
    if ($name -in $realServers) { $srvNo++; $map[$name] = "SRV$srvNo" }
    else { $dbNo++; $map[$name] = "DB$dbNo" }
}

function Protect-EDText {
    param([string]$Text)
    if (-not $Text) { return '' }
    foreach ($real in @($map.Keys | Sort-Object -Property Length -Descending)) {
        $Text = $Text -replace [regex]::Escape($real), $map[$real]
    }
    # E-posta adresleri ve DB adlari
    $Text = $Text -replace '[\w\.\-\+]+@[\w\.\-]+', 'kullanici@ornek'
    return $Text
}

Write-Output "=== KOSUM ISKELETI (adlar maskelendi) ==="
Write-Output ("sunucu: {0}   diger varlik (DB/volume): {1}   satir: {2}" -f $srvNo, $dbNo, $rows.Count)
if ($maskWarnings.Count -gt 0) {
    # Maskenin EKSIK olabilecegi SOYLENIR: sessizce eksik maskelemek,
    # gozden gecirmeden yapistirmaya davettir.
    Write-Output ("UYARI: su kanit dosyalari yok, maskeleme EKSIK olabilir: {0}. Ciktiyi gozden gecirmeden paylasmayin." -f ($maskWarnings -join ', '))
}
Write-Output ("durum dagilimi: {0}" -f (@($rows | Group-Object Durum | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '  '))

Write-Output "`n=== ORGULER (hangi iddia kuruldu) ==="
$any = $false
foreach ($row in @($rows | Where-Object { $_.Orgu })) {
    $any = $true
    $tags = (@($row.Orgu -split '\|' | ForEach-Object { ($_ -split ':')[0].Trim() }) -join '+')
    Write-Output ("  [{0,-5}] {1,-4} {2,-34} {3}" -f $row.Durum, $row.Modul, $row.Kontrol, $tags)
}
if (-not $any) { Write-Output '  (hicbir orgu kurulmadi)' }

Write-Output "`n=== CORE SATIRLARI (raporun ne kadarina guvenilir) ==="
$core = @($rows | Where-Object { $_.Modul -eq 'CORE' })
if ($core.Count -eq 0) { Write-Output '  (CORE satiri YOK - kapsam eksigi/bastirma/butce sorunu bildirilmemis)' }
foreach ($row in $core) { Write-Output ("  [{0}] {1}: {2}" -f $row.Durum, $row.Kontrol, (Protect-EDText $row.Not)) }

Write-Output "`n=== WARN/FAIL/ERROR/TIMEOUT SATIRLARI ==="
foreach ($row in @($rows | Where-Object { $_.Durum -in 'FAIL','ERROR','TIMEOUT','WARN' })) {
    Write-Output ("  [{0,-7}] {1,-4} {2}" -f $row.Durum, $row.Modul, $row.Kontrol)
    Write-Output ("      NOT: {0}" -f (Protect-EDText $row.Not))
}

Write-Output "`n=== KAPSAM CUMLELERI (orneklem mi, sayim mi) ==="
foreach ($row in @($rows | Where-Object { $_.Not -match 'KAPSAM|ORNEKLEM|kapsam|Sunucu basina taranan' })) {
    Write-Output ("  {0} / {1}" -f $row.Modul, $row.Kontrol)
    Write-Output ("      {0}" -f (Protect-EDText $row.Not))
}
