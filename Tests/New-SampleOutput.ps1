<#
    Anonimlestirilmis ornek rapor uretir: Sample-Output\

    NEDEN SENTETIK?
    Gercek bir calistirmanin ciktisi sunucu, kullanici ve posta kutusu adlari
    tasir; bu yuzden output\ ve Config\ .gitignore icindedir. Ornek rapor
    depoyla birlikte dagitilacagi icin GERCEK VERIDEN URETILEMEZ.

    Bu betik gercek ortama HIC DOKUNMAZ - hicbir baglanti acmaz, hicbir
    cmdlet cagirmaz. Uydurma bir uc sunuculu ortamin bulgularini kurar ve
    rapor katmanini oldugu gibi kullanir.

    Uretilen senaryo kasitli olarak "ders kitabi" bir vakadir:
      MBX02 belirgin yavas (P1)
      Gecikme Store fazinda yogunlasiyor (P2)
      Yavas teslimler DB03'te toplaniyor (P3)
      Yuksek RPC + SAGLIKLI disk -> suclu store (P4)
      DB02 ve DB03 ayni volume'u paylasiyor ve volume yavas (P5)
      Ortalama 8 sn, p99 240 sn (P6)
      09:00'da belirgin tepe (P7)
      Iki aktif kopya ActivationPreference disinda (P8)
#>
[CmdletBinding()]
param([string]$OutputPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\Report.ps1')
. (Join-Path $projectRoot 'Core\Compare.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

if (-not $OutputPath) { $OutputPath = Join-Path $projectRoot 'Sample-Output' }
$previousPath = Join-Path $OutputPath 'onceki-sakin-saat'
$currentPath = Join-Path $OutputPath 'simdiki-yogun-saat'
foreach ($path in @($OutputPath, $previousPath, $currentPath)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$config = Get-EDConfig -ProjectRoot $projectRoot

function New-SampleServer {
    param([string]$Name, [string]$Site = 'Merkez', [switch]$PassiveSite)
    return [pscustomobject]@{
        Name = $Name; Fqdn = "$Name.ornek.local"; Site = $Site; Roles = 'Mailbox'
        Version = '15.2.2562.17'; Edition = 'Enterprise'; IsMailbox = $true; IsEdge = $false
        IsTransport = $true; ActiveDbs = 2; DbCopies = 4; IsPassiveSite = [bool]$PassiveSite
    }
}

$servers = @(
    (New-SampleServer -Name 'MBX01')
    (New-SampleServer -Name 'MBX02')
    (New-SampleServer -Name 'MBX03')
    (New-SampleServer -Name 'DR01' -Site 'Felaket' -PassiveSite)
)
$serverNames = @($servers | ForEach-Object { $_.Name })

function New-SampleContext {
    param([string]$Path, [int]$Hour, [string]$RunId)
    $executor = [pscustomobject]@{ ExchangeConnection = 'remote http://mbx01.ornek.local/PowerShell/ (Kerberos)'; Parallelism = 6 }
    return [pscustomobject]@{
        Config = $config; Executor = $executor
        Log = (New-EDLogger -LogPath (Join-Path $Path 'run.log') -Quiet)
        ProjectRoot = $projectRoot; OutputDir = $Path; RunId = $RunId
        StartTime = (Get-Date).Date.AddHours($Hour)
        Heavy = $true; WindowHours = 2; LogAccess = 'smb'
        VerifyParser = $false; ServerFilter = @(); Cache = @{}
        Topology = [pscustomobject]@{
            Servers = $servers
            Sites = @([pscustomobject]@{ Name = 'Merkez'; IsPassive = $false }, [pscustomobject]@{ Name = 'Felaket'; IsPassive = $true })
            Dags = @([pscustomobject]@{ Name = 'DAG01'; Members = $serverNames })
            Databases = @(); HasDag = $true
        }
    }
}

# ===========================================================================
# YOGUN SAAT (asil rapor)
# ===========================================================================
$rows = @()

# --- Faz A ---
$rows += New-EDRow -Module 'M01' -Check 'AD sitesi' -Status 'OK' `
    -Values @{ MBX01 = 'Merkez'; MBX02 = 'Merkez'; MBX03 = 'Merkez'; DR01 = 'Felaket' }
$rows += New-EDRow -Module 'M01' -Check 'Aktif (mounted) DB' -Unit 'adet' -Status 'OK' `
    -Values @{ MBX01 = 2; MBX02 = 4; MBX03 = 2; DR01 = 0 } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'OK'; DR01 = 'PASSIVE' }
$rows += New-EDRow -Module 'M02' -Check 'Gercek build (ExSetup.exe)' -Status 'WARN' `
    -Values @{ MBX01 = '15.02.2562.049'; MBX02 = '15.02.2562.017'; MBX03 = '15.02.2562.049'; DR01 = '15.02.2562.049' } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'WARN'; MBX03 = 'OK'; DR01 = 'OK' } `
    -Note 'Sunucular arasi build farki var: 15.02.2562.049 / 15.02.2562.017. MBX02 geride. Yama seviyesi tum sunucularda esitlenmeli.'
$rows += New-EDRow -Module 'M04' -Check 'SMTP sertifikasi kalan sure' -Unit 'gun' -Status 'WARN' `
    -Values @{ MBX01 = 210; MBX02 = 210; MBX03 = 18; DR01 = 210 } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'WARN'; DR01 = 'OK' } `
    -Note "MBX03: SMTP sertifikasi 'Posta' 18 gun icinde doluyor - TLS el sikismasi basarisiz olur ve giden posta KUYRUKTA BIRIKIR. M14 ile birlikte okuyun."
$rows += New-EDRow -Module 'M05' -Check 'CPU (p95)' -Unit '%' -Status 'WARN' `
    -Values @{ MBX01 = 38.2; MBX02 = 82.6; MBX03 = 41.0; DR01 = 6.4 } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'WARN'; MBX03 = 'OK'; DR01 = 'OK' } `
    -Note 'MBX02: CPU p95 %83 - bu bir SONUCTUR; sebebi icin M23 (agir kullanici) ve M24 (buyuk klasor). CPU ORTALAMA degil P95 gosterilir.'
$rows += New-EDRow -Module 'M05' -Check 'Calisma suresi' -Status 'OK' `
    -Values @{ MBX01 = '31.4 gun'; MBX02 = '31.4 gun'; MBX03 = '31.2 gun'; DR01 = '44.8 gun' } `
    -Note 'Calisma suresi bir hata olcusu DEGIL, diger tum bulgulari okurken gereken BAGLAMDIR.'

# --- Faz B: ORGU P1 + P6 ---
$rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p50' -Unit 'sn' -Status 'OK' `
    -Values @{ MBX01 = 1.8; MBX02 = 4.2; MBX03 = 1.9; DR01 = 'N/A' }
$rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p95' -Unit 'sn' -Status 'FAIL' `
    -Values @{ MBX01 = 22.4; MBX02 = 186.5; MBX03 = 24.1; DR01 = 'N/A' } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'FAIL'; MBX03 = 'OK'; DR01 = 'N/A' } `
    -Patterns @('P1') `
    -Note 'ORGU P1: MBX02 diger sunuculardan belirgin yavas (p95 186.5 sn, ortam medyani 23.3 sn - 8.0x). Okuma yolu: smb. Ayrinti: M10-latency.csv'
$rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p99' -Unit 'sn' -Status 'FAIL' `
    -Values @{ MBX01 = 48.0; MBX02 = 240.3; MBX03 = 51.7; DR01 = 'N/A' } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'FAIL'; MBX03 = 'OK'; DR01 = 'N/A' }
$rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi ortalama' -Unit 'sn' -Status 'OK' `
    -Values @{ MBX01 = 4.1; MBX02 = 8.0; MBX03 = 4.3; DR01 = 'N/A' } `
    -Patterns @('P6') `
    -Note 'ORGU P6: ortalama 8.0 sn "iyi" gorunuyor ama p99 240.3 sn (30x). ORTALAMA TAIL''I GIZLER - hukum persentile gore verilmelidir.'
$rows += New-EDRow -Module 'M11' -Check 'Baskin faz' -Status 'WARN' `
    -Values @{ MBX01 = 'Transport'; MBX02 = 'Store'; MBX03 = 'Transport'; DR01 = 'N/A' } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'WARN'; MBX03 = 'OK'; DR01 = 'N/A' } `
    -Patterns @('P2') `
    -Note 'ORGU P2: MBX02 sunucusunda gecikme STORE fazinda (DeliveryToMailbox) yogunlasiyor. Darbogaz transport degil Store tarafi - arastirmayi M20 (RPC latency), M21 (disk latency) ve M22 (paylasilan volume) ile surdurun.'
$rows += New-EDRow -Module 'M11' -Check 'Store fazi p95' -Unit 'sn' -Status 'FAIL' `
    -Values @{ MBX01 = 6.2; MBX02 = 171.8; MBX03 = 7.0; DR01 = 'N/A' } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'FAIL'; MBX03 = 'OK'; DR01 = 'N/A' }
$rows += New-EDRow -Module 'M12' -Check 'Yavas teslimlerin DB dagilimi' -Unit 'teslim' -Status 'WARN' `
    -Values @{ DB01 = 42; DB02 = 88; DB03 = 1174; DB04 = 31 } `
    -CellStatus @{ DB01 = 'OK'; DB02 = 'OK'; DB03 = 'WARN'; DB04 = 'OK' } `
    -Patterns @('P3') `
    -Note 'ORGU P3: yavas teslimlerin %88''i DB03 uzerinde yogunlasiyor (esik 60 sn). 1335 yavas teslim, 412 benzersiz alici; 400 tanesi sorgulandi (%97 kapsam). Ayrinti: M12-slow-databases.csv'
$rows += New-EDRow -Module 'M13' -Check 'Yogun saat (p95)' -Unit 'sn' -Status 'WARN' `
    -Values @{ MBX01 = '09:00 -> 44.1'; MBX02 = '09:00 -> 305.0'; MBX03 = '09:00 -> 46.8'; DR01 = 'N/A' } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'WARN'; MBX03 = 'OK'; DR01 = 'N/A' } `
    -Patterns @('P7') `
    -Note 'ORGU P7: yogun saatte belirgin tepe var - MBX02: 09:00 -> p95 305.0 sn, 07:00 -> p95 14.4 sn (21.2x). Kapasite/eszamanlilik siniri suphesi: M16 (MaxConcurrentMailboxDeliveries) ve M14 (kuyruk derinligi) ile surdurun.'
$rows += New-EDRow -Module 'M14' -Check 'Kuyruk derinligi (golge haric)' -Unit 'mesaj' -Status 'OK' `
    -Values @{ MBX01 = 12; MBX02 = 31; MBX03 = 9; DR01 = 0 } `
    -Note 'Kuyruk bir ANLIK GORUNTUDUR; tek olcum yaniltir. M13 ve -CompareWith ile birlikte okuyun.'
$rows += New-EDRow -Module 'M16' -Check 'MaxConcurrentMailboxDeliveries' -Status 'WARN' `
    -Values @{ MBX01 = 20; MBX02 = 20; MBX03 = 20; DR01 = 20 } `
    -Note 'Referans varsayilan 20, bu ortamda 20. Farkli olmasi tek basina hata degildir. M13 yogun saatte tepe gordugu icin bu ayar incelenmeye deger.'

# --- Faz C: ORGU P4 + P5 ---
$rows += New-EDRow -Module 'M20' -Check 'Store RPC latency (p95)' -Unit 'ms' -Status 'FAIL' `
    -Values @{ MBX01 = 21; MBX02 = 162; MBX03 = 24; DR01 = 4 } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'FAIL'; MBX03 = 'OK'; DR01 = 'OK' } `
    -Patterns @('P4') `
    -Note 'ORGU P4: MBX02 - RPC p95 162 ms, en kotu disk okuma 0.0032 sn / yazma 0.0043 sn, kuyruk 0.4. Disk SAGLIKLI ve kuyruk bos oldugu icin darbogaz STORE ICINDEDIR; disk degistirmek ise yaramaz. Sonraki adim M23 (agir kullanici) ve M24 (buyuk klasor).'
$rows += New-EDRow -Module 'M21' -Check 'En kotu volume - yazma' -Unit 'sn' -Status 'WARN' `
    -Values @{ MBX01 = 0.0041; MBX02 = 0.0043; MBX03 = 0.0312; DR01 = 0.0038 } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'WARN'; DR01 = 'OK' } `
    -Note 'MBX03/E:: okuma 0.0289 sn, yazma 0.0312 sn, kuyruk 3.1. _Total DEGIL en kotu volume gosterilir; on diskten dokuzu saglikliyken biri bogulmus olabilir.'
$rows += New-EDRow -Module 'M22' -Check 'DB paylasan volume sayisi' -Unit 'adet' -Status 'WARN' `
    -Values @{ MBX01 = 0; MBX02 = 0; MBX03 = 1; DR01 = 0 } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'WARN'; DR01 = 'OK' } `
    -Patterns @('P5') `
    -Note 'ORGU P5: MBX03/E:\: 2 DB ayni volume uzerinde ve volume yavas (okuma 0.0289 sn, yazma 0.0312 sn) -> DB02; DB03. Bu volume uzerindeki TUM veritabanlari kendi kullanici profillerinden bagimsiz olarak etkilenir. Agir kullanici yalnizca bir veritabaninda gorunse bile komsu veritabaninin yavasligi buradan gelir - M23 ile birlikte okuyun.'
$rows += New-EDRow -Module 'M23' -Check 'Teshis (yorum tablosu)' -Status 'WARN' `
    -Values @{ MBX01 = 'Belirgin bir oruntu yok'; MBX02 = 'BEKLIYOR (TimeInServer >> TimeInCPU): kilit cekismesi veya I/O -> M21/M22 ; BUYUK TARAMA (PageRead 9,400, ortanca 60)'; MBX03 = 'Belirgin bir oruntu yok'; DR01 = 'N/A' } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'WARN'; MBX03 = 'OK'; DR01 = 'N/A' } `
    -Note 'TimeInServer MILISANIYEDIR (50.000 = 50 sn). Hukumler ortamin kendi ortancasina gore verilir; mutlak esik degil goreli kiyas esastir.'
$rows += New-EDRow -Module 'M25' -Check 'En buyuk DB' -Unit 'GB' -Status 'OK' `
    -Values @{ MBX01 = 412.8; MBX02 = 388.1; MBX03 = 501.4; DR01 = 0 } `
    -Note 'Hicbir veritabani, bulundugu birimdeki bos alandan buyuk degil. Sunucu sutununda o sunucunun EN BUYUK veritabani gosterilir.'
$rows += New-EDRow -Module 'M25' -Check 'En buyuk DB bos alan orani' -Unit '%' -Status 'OK' `
    -Values @{ MBX01 = 8.2; MBX02 = 11.7; MBX03 = 31.9; DR01 = 0 } `
    -Note 'BOS ALAN (whitespace) BIR HATA DEGILDIR ve bu deger icin esik UYGULANMAZ. Veritabani dosyasi icindeki yeniden kullanilabilir alandir; Exchange yeni postalari oraya yazar. Cevrimdisi defrag (eseutil /d) rutin bir cozum DEGILDIR.'
$rows += New-EDRow -Module 'M26' -Check 'Icerik indeksi durumu' -Status 'OK' `
    -Values @{ MBX01 = '4 saglikli / 4'; MBX02 = '4 saglikli / 4'; MBX03 = '4 saglikli / 4'; DR01 = '4 saglikli / 4' }

# --- Faz D: ORGU P8 ---
$rows += New-EDRow -Module 'M30' -Check 'Kopya sagligi' -Status 'OK' `
    -Values @{ MBX01 = '4 saglikli'; MBX02 = '4 saglikli'; MBX03 = '4 saglikli'; DR01 = '4 saglikli' }
$rows += New-EDRow -Module 'M31' -Check 'CopyQueueLength (en kotu)' -Unit 'log' -Status 'OK' `
    -Values @{ MBX01 = 2; MBX02 = 0; MBX03 = 1; DR01 = 6 } `
    -Note 'EN KOTU kopya gosterilir, sunucu ortalamasi degil.'
$rows += New-EDRow -Module 'M32' -Check 'Aktif DB sayisi' -Unit 'adet' -Status 'WARN' `
    -Values @{ MBX01 = 2; MBX02 = 4; MBX03 = 2; DR01 = 0 } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'WARN'; MBX03 = 'OK'; DR01 = 'PASSIVE' } `
    -Patterns @('P8') `
    -Note 'ORGU P8: 2 veritabani ActivationPreference disinda calisiyor - DB05 aktif MBX02 uzerinde (tercih 2), DB07 aktif MBX02 uzerinde (tercih 3). Failover sonrasi dengelenmemis olabilir. DENGESIZ YUK: MBX02 sunucusunda 4 aktif DB var, ortalama 2.7. Duzeltme komutu METIN olarak: Move-ActiveMailboxDatabase <DB> -ActivateOnServer <tercih-1-sunucu>  --  BU ARAC CALISTIRMAZ.'
$rows += New-EDRow -Module 'M34' -Check 'Siteler arasi kopya kuyrugu (en kotu)' -Unit 'log' -Status 'OK' `
    -Values @{ MBX01 = 'N/A'; MBX02 = 'N/A'; MBX03 = 'N/A'; DR01 = 6 } `
    -CellStatus @{ MBX01 = 'N/A'; MBX02 = 'N/A'; MBX03 = 'N/A'; DR01 = 'OK' } `
    -Note '4 kopya uzak sitede. En kotu siteler arasi kuyruk 6 log, ayni site icindeki en kotu kuyruk 2 log. Siteler arasi kuyruklar esik icinde.'

# --- Faz E ---
$rows += New-EDRow -Module 'M40' -Check 'Saglikli olmayan monitor' -Unit 'adet' -Status 'OK' `
    -Values @{ MBX01 = 0; MBX02 = 0; MBX03 = 0; DR01 = 0 }
$rows += New-EDRow -Module 'M41' -Check 'Hata olayi' -Unit 'adet' -Status 'WARN' `
    -Values @{ MBX01 = 4; MBX02 = 11; MBX03 = 62; DR01 = 2 } `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'WARN'; DR01 = 'OK' } `
    -Note 'MBX03: DEPOLAMA kaynakli hata - disk #153, Ntfs #55. Depolama hatalari M21 (disk latency) ve M22 (volume) ile birlikte okunmalidir. Olay sayisinin yuksek olmasi tek basina hata DEGILDIR - hangi olayin gecikmeye sebep oldugu hukmu verilmez.'
$rows += New-EDRow -Module 'M42' -Check 'Dislanmamis yol' -Unit 'adet' -Status 'N/A' `
    -Values @{ MBX01 = 'N/A'; MBX02 = 'N/A'; MBX03 = 'N/A'; DR01 = 'N/A' } `
    -CellStatus @{ MBX01 = 'N/A'; MBX02 = 'N/A'; MBX03 = 'N/A'; DR01 = 'N/A' } `
    -Note "Ucuncu parti AV var (Ornek Endpoint Protection) - dislamalari bu aractan GORULEMEZ, 'dislama yok' anlamina gelmez."
$rows += New-EDRow -Module 'M43' -Check 'Yama durumu' -Status 'N/A' `
    -Note 'Config\reference.json -> securityUpdates listesi BOS. Yama durumu hakkinda hukum verilmedi - "guncel" iddiasi da yapilmadi. Liste surumle degistigi icin araca sabit kodlanmamistir.'
$rows += New-EDRow -Module 'M45' -Check 'Son yedekten bu yana' -Status 'OK' `
    -Values @{ MBX01 = '0.4 gun'; MBX02 = '0.4 gun'; MBX03 = '0.4 gun'; DR01 = '0.4 gun' } `
    -Note 'Tum veritabanlarinda guncel yedek kaydi var.'

$timings = @(
    [pscustomobject]@{ Id = 'M01'; Name = 'Topoloji kesfi'; Seconds = 0.9; RowCount = 6; Status = 'OK' }
    [pscustomobject]@{ Id = 'M10'; Name = 'Teslim gecikmesi persentili'; Seconds = 3.4; RowCount = 4; Status = 'FAIL' }
    [pscustomobject]@{ Id = 'M11'; Name = 'Faz kirilimi'; Seconds = 5.1; RowCount = 2; Status = 'WARN' }
    [pscustomobject]@{ Id = 'M12'; Name = 'Gecikmeli teslimlerin DB dagilimi'; Seconds = 8.8; RowCount = 1; Status = 'WARN' }
    [pscustomobject]@{ Id = 'M20'; Name = 'Store RPC latency'; Seconds = 21.2; RowCount = 1; Status = 'FAIL' }
    [pscustomobject]@{ Id = 'M23'; Name = 'Agir kullanicilar'; Seconds = 2.6; RowCount = 1; Status = 'WARN' }
    [pscustomobject]@{ Id = 'M24'; Name = 'Buyuk klasorler'; Seconds = 14.9; RowCount = 0; Status = 'OK' }
)

$context = New-SampleContext -Path $currentPath -Hour 9 -RunId '20260917-090000'
$columns = Get-EDReportColumns -Rows $rows -PreferredOrder $serverNames
Export-EDSummaryCsv  -Rows $rows -Columns $columns -Path (Join-Path $currentPath 'SUMMARY.csv') | Out-Null
Export-EDSummaryHtml -Rows $rows -Columns $columns -Path (Join-Path $currentPath 'SUMMARY.html') -Context $context -ModuleTimings $timings | Out-Null
Save-EDRunMeta -Context $context -Path (Join-Path $currentPath 'run-meta.json') -ModuleTimings $timings | Out-Null

# ===========================================================================
# SAKIN SAAT (kiyas tabani) - ayni kapsam, daha dusuk degerler
# ===========================================================================
$quietRows = @()
foreach ($row in $rows) {
    $clone = New-EDRow -Module $row.Module -Check $row.Check -Unit $row.Unit -Status $row.Status -Note $row.Note
    foreach ($key in @($row.Values.Keys)) { $clone.Values[$key] = $row.Values[$key] }
    foreach ($key in @($row.CellStatus.Keys)) { $clone.CellStatus[$key] = $row.CellStatus[$key] }
    $quietRows += $clone
}

function Set-QuietValue {
    param($Rows, [string]$Module, [string]$CheckLike, [hashtable]$Values, [string]$Status, [hashtable]$CellStatus)
    $row = @($Rows | Where-Object { $_.Module -eq $Module -and $_.Check -like $CheckLike })[0]
    if (-not $row) { return }
    foreach ($key in $Values.Keys) { $row.Values[$key] = $Values[$key] }
    if ($Status) { $row.Status = $Status }
    if ($CellStatus) { foreach ($key in $CellStatus.Keys) { $row.CellStatus[$key] = $CellStatus[$key] } }
}

# Sakin saatte her sey esik icinde: yogun saat kiyasinin anlami burada ortaya cikar.
Set-QuietValue -Rows $quietRows -Module 'M10' -CheckLike 'Teslim gecikmesi p95*' `
    -Values @{ MBX01 = 8.1; MBX02 = 11.2; MBX03 = 8.6 } -Status 'OK' `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'OK' }
Set-QuietValue -Rows $quietRows -Module 'M10' -CheckLike 'Teslim gecikmesi p99*' `
    -Values @{ MBX01 = 14.0; MBX02 = 19.8; MBX03 = 15.1 } -Status 'OK' `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'OK' }
Set-QuietValue -Rows $quietRows -Module 'M11' -CheckLike 'Baskin faz*' `
    -Values @{ MBX01 = 'Transport'; MBX02 = 'Transport'; MBX03 = 'Transport' } -Status 'OK' `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'OK' }
Set-QuietValue -Rows $quietRows -Module 'M11' -CheckLike 'Store fazi p95*' `
    -Values @{ MBX01 = 2.9; MBX02 = 3.4; MBX03 = 3.1 } -Status 'OK' `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'OK' }
Set-QuietValue -Rows $quietRows -Module 'M20' -CheckLike 'Store RPC latency*' `
    -Values @{ MBX01 = 14; MBX02 = 19; MBX03 = 16; DR01 = 4 } -Status 'OK' `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'OK'; DR01 = 'OK' }
Set-QuietValue -Rows $quietRows -Module 'M05' -CheckLike 'CPU*' `
    -Values @{ MBX01 = 11.4; MBX02 = 16.8; MBX03 = 12.2; DR01 = 5.9 } -Status 'OK' `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'OK'; DR01 = 'OK' }
Set-QuietValue -Rows $quietRows -Module 'M12' -CheckLike 'Yavas teslimlerin*' `
    -Values @{ DB01 = 1; DB02 = 0; DB03 = 3; DB04 = 0 } -Status 'OK' `
    -CellStatus @{ DB01 = 'OK'; DB02 = 'OK'; DB03 = 'OK'; DB04 = 'OK' }
Set-QuietValue -Rows $quietRows -Module 'M14' -CheckLike 'Kuyruk derinligi*' `
    -Values @{ MBX01 = 1; MBX02 = 2; MBX03 = 0; DR01 = 0 } -Status 'OK'
Set-QuietValue -Rows $quietRows -Module 'M41' -CheckLike 'Hata olayi*' `
    -Values @{ MBX01 = 1; MBX02 = 2; MBX03 = 9; DR01 = 0 } -Status 'OK' `
    -CellStatus @{ MBX01 = 'OK'; MBX02 = 'OK'; MBX03 = 'OK'; DR01 = 'OK' }

$quietContext = New-SampleContext -Path $previousPath -Hour 3 -RunId '20260917-030000'
$quietColumns = Get-EDReportColumns -Rows $quietRows -PreferredOrder $serverNames
Export-EDSummaryCsv  -Rows $quietRows -Columns $quietColumns -Path (Join-Path $previousPath 'SUMMARY.csv') | Out-Null
Export-EDSummaryHtml -Rows $quietRows -Columns $quietColumns -Path (Join-Path $previousPath 'SUMMARY.html') -Context $quietContext -ModuleTimings $timings | Out-Null
Save-EDRunMeta -Context $quietContext -Path (Join-Path $previousPath 'run-meta.json') -ModuleTimings $timings | Out-Null

# ===========================================================================
# DELTA: sakin saat -> yogun saat
# ===========================================================================
$comparison = Compare-EDRuns -PreviousFolder $previousPath -CurrentRows $rows -Context $context -ModuleTimings $timings
@($comparison.Deltas) | Export-Csv -LiteralPath (Join-Path $currentPath 'DELTA.csv') -NoTypeInformation -Encoding UTF8
Export-EDDeltaHtml -Comparison $comparison -Path (Join-Path $currentPath 'DELTA.html') -Context $context | Out-Null

$highlights = Get-EDDeltaHighlights -Comparison $comparison

Write-Host ''
Write-Host 'Ornek rapor uretildi (tamami sentetiktir; gercek ortama dokunulmadi):' -ForegroundColor Green
Write-Host "  $currentPath\SUMMARY.html   <- asil rapor"
Write-Host "  $currentPath\DELTA.html     <- sakin saat -> yogun saat"
Write-Host "  $previousPath\SUMMARY.html  <- kiyas tabani"
Write-Host ''
Write-Host ("  Bulgu  : {0} WARN/FAIL" -f @($rows | Where-Object { $_.Status -in @('WARN', 'FAIL') }).Count)
Write-Host ("  Delta  : {0} fark, {1} gerileme, {2} iyilesme" -f `
    @($comparison.Deltas).Count, @($highlights.Regressions).Count, @($highlights.Improvements).Count)
Write-Host ("  Orguler: {0}" -f ((@($rows | Where-Object { $_.Patterns } | ForEach-Object { $_.Patterns }) | Select-Object -Unique | Sort-Object) -join ', '))
Write-Host ''
