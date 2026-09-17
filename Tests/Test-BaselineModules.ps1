<#
    M04 / M05 / M25 / M26 modul testleri.

    Bu lab'da bulgularin hicbiri olusmaz: sertifikalar 2031'e kadar gecerli,
    sunucu bos, veritabani 247 MB, icerik indeksi NotApplicable. Modullerin
    cokmemesi mantiklarinin dogru oldugunu GOSTERMEZ.

    Test edilen asil kararlar:
      M04: enum degerleri uzak oturumda TAMSAYIYA doner ve cozumlenmelidir;
           tanimadigimiz bayrak sessizce yutulmaz; ATANMAMIS sertifika hukme
           girmez; kendinden imzali olmak hata degildir; SMTP ayri vurgulanir
      M05: calisma suresi bir hata olcusu degil BAGLAMDIR; CPU ortalama degil
           p95; dusuk bos bellek tek basina hata degildir; .NET icin hukum yok
      M25: "247.9 MB (259,981,312 bytes)" bicimi ve KULTURE GORE degisen
           binlik ayraci; whitespace'e esik UYGULANMAZ; kapasite iddiasi
           yalnizca birim envanteri varken kurulur
      M26: NotApplicable NORMALDIR; bozuk indeks teslimi gecikmez - bu kisa
           devre kurulmamalidir
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\PerfCounter.ps1')
. (Join-Path $projectRoot 'Core\Replication.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$script:OutputDir = Join-Path $env:TEMP ("ed-base-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot
Reset-EDModuleRegistry
Import-EDModules -ModuleRoot (Join-Path $projectRoot 'Modules')
$m04 = @(Get-EDModules -Id 'M04')[0]
$m05 = @(Get-EDModules -Id 'M05')[0]
$m25 = @(Get-EDModules -Id 'M25')[0]
$m26 = @(Get-EDModules -Id 'M26')[0]

function New-BaseContext {
    param($Executor = $null, $Databases = @(), $Servers = $null)
    if ($null -eq $Servers) { $Servers = @((New-EDTestServer -Name 'MBX1')) }
    return New-EDTestContext -Config $config -Executor $Executor -Servers $Servers `
        -Databases $Databases -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:OutputDir
}

# ===========================================================================
Write-Host "`n=== 0. ConvertFrom-EDByteQuantified ===" -ForegroundColor Cyan

Assert-Equal 'Virgul ayracli bicim' 259981312 (ConvertFrom-EDByteQuantified '247.9 MB (259,981,312 bytes)')
# Turkce yerel ayarli bir sunucuda ayrac NOKTA olur; ayraci yorumlamak yerine
# rakam disi her karakter atildigi icin ikisi de dogru cozulur.
Assert-Equal 'Nokta ayracli bicim (tr-TR)' 259981312 (ConvertFrom-EDByteQuantified '247,9 MB (259.981.312 bytes)')
Assert-Equal 'Bosluk ayracli bicim' 259981312 (ConvertFrom-EDByteQuantified '247.9 MB (259 981 312 bytes)')
Assert-Equal 'Duz sayi' 12345 (ConvertFrom-EDByteQuantified '12345')
Assert-Equal 'Zaten sayisal' 500 (ConvertFrom-EDByteQuantified ([long]500))
Assert-True 'Bos deger null doner' ($null -eq (ConvertFrom-EDByteQuantified '')) 'cozulemeyen deger uydurulmuyor'
Assert-True 'Null deger null doner' ($null -eq (ConvertFrom-EDByteQuantified $null))
Assert-True 'Parantezsiz metin null doner' ($null -eq (ConvertFrom-EDByteQuantified 'Unlimited')) 'Unlimited sayiya cevrilmiyor'

# ===========================================================================
Write-Host "`n=== 1. M04 sertifikalar ===" -ForegroundColor Cyan

function New-Cert {
    param(
        [string]$FriendlyName, [int]$Services, [int]$DaysLeft,
        [int]$Status = 1, [bool]$SelfSigned = $true
    )
    # AddMinutes(1) sart: modul kalan sureyi ASAGI yuvarlar (dogru yon -
    # kalan sureyi oldugundan uzun soylememek icin). Tam gun sinirinda
    # uretilen bir tarih, test kosarken gecen milisaniyeler yuzunden bir gun
    # eksik cozulur. Bir dakikalik tampon bu olcum kaymasini kaldirir.
    return [pscustomobject]@{
        Thumbprint = ([guid]::NewGuid().ToString('N')); Subject = "CN=$FriendlyName"
        FriendlyName = $FriendlyName; NotAfter = (Get-Date).AddDays($DaysLeft).AddMinutes(1)
        NotBefore = (Get-Date).AddDays(-365); Services = $Services; Status = $Status
        IsSelfSigned = $SelfSigned; CertificateDomains = 'test.local'; RootCAType = 3
    }
}

function New-CertContext {
    param($Certificates)
    $script:Certs = $Certificates
    $mock = New-EDMockExecutor @{ 'Get-ExchangeCertificate' = { param($Key, $Identity) return $script:Certs } }
    return New-BaseContext -Executor $mock
}

# 1a. CANLI ORTAMDA DOGRULANAN bayrak cozumlemesi: 27 = IMAP+POP+IIS+SMTP
$rows = @(& $m04.Run (New-CertContext -Certificates @(
    (New-Cert -FriendlyName 'Microsoft Exchange' -Services 27 -DaysLeft 1731)
    (New-Cert -FriendlyName 'Auth' -Services 16 -DaysLeft 1705)
)))
$soonRow = Get-EDTestRow $rows 'En yakin biten'
Assert-Equal 'Uzun omurlu sertifikalar OK' 'OK' $soonRow.Status
Assert-Equal 'Atanmis sertifika sayisi' 2 (Get-EDTestRow $rows 'Atanmis sertifika').Values['MBX1']
Assert-True 'Kendinden imzali UYARI URETMEDI' ($soonRow.Status -eq 'OK') 'tasarim geregi normal'

# 1b. Tanimadigimiz bayrak SESSIZCE YUTULMAZ
$evidencePath = Join-Path $script:OutputDir 'M04-certificates.csv'
$rows = @(& $m04.Run (New-CertContext -Certificates @((New-Cert -FriendlyName 'Garip' -Services 1024 -DaysLeft 500))))
$evidence = @(Import-Csv $evidencePath)
Assert-True 'Bilinmeyen bayrak isaretlendi' (@($evidence | Where-Object { $_.Servisler -like '*bilinmeyen(1024)*' }).Count -eq 1) `
    ($evidence[0].Servisler)
Assert-Equal 'Ham deger kanitta korundu' '1024' $evidence[0].ServisHam

# 1c. ATANMAMIS sertifikanin suresi dolsa da hukum uretmez
$rows = @(& $m04.Run (New-CertContext -Certificates @(
    (New-Cert -FriendlyName 'Kullanilmayan' -Services 0 -DaysLeft 2)      # yarin doluyor
    (New-Cert -FriendlyName 'Aktif' -Services 16 -DaysLeft 900)
)))
$soonRow = Get-EDTestRow $rows 'En yakin biten'
Assert-Equal 'Atanmamis sertifika hukme girmedi' 'OK' $soonRow.Status
Assert-Equal 'En yakin biten ATANMIS olan' '900 gun' $soonRow.Values['MBX1']
Assert-Equal 'Atanmamis sayisi ayri raporlandi' 1 (Get-EDTestRow $rows 'Atanmamis sertifika').Values['MBX1']

# 1d. SMTP sertifikasi doluyor -> kuyruk baglantisi kurulur
$rows = @(& $m04.Run (New-CertContext -Certificates @((New-Cert -FriendlyName 'SMTP-Cert' -Services 16 -DaysLeft 3))))
$soonRow = Get-EDTestRow $rows 'En yakin biten'
Assert-Equal 'Uc gun kalan sertifika FAIL' 'FAIL' $soonRow.Status
Assert-True 'TLS ve kuyruk baglantisi kuruldu' ($soonRow.Note -like '*KUYRUKTA BIRIKIR*') $soonRow.Note
Assert-Equal 'SMTP satiri ayri gosterdi' '3 gun' (Get-EDTestRow $rows 'SMTP sertifikasi').Values['MBX1']

# 1e. Esik yonu dogru: 45 gun OK, 20 gun WARN
$rows = @(& $m04.Run (New-CertContext -Certificates @((New-Cert -FriendlyName 'C' -Services 8 -DaysLeft 45))))
Assert-Equal '45 gun OK' 'OK' (Get-EDTestRow $rows 'En yakin biten').Status
$rows = @(& $m04.Run (New-CertContext -Certificates @((New-Cert -FriendlyName 'C' -Services 8 -DaysLeft 20))))
Assert-Equal '20 gun WARN' 'WARN' (Get-EDTestRow $rows 'En yakin biten').Status

# 1f. Gecerli olmayan durum (Revoked = 2) -> FAIL
$rows = @(& $m04.Run (New-CertContext -Certificates @((New-Cert -FriendlyName 'Iptal' -Services 16 -DaysLeft 800 -Status 2))))
$soonRow = Get-EDTestRow $rows 'En yakin biten'
Assert-Equal 'Revoked sertifika FAIL' 'FAIL' $soonRow.Status
Assert-True 'Durum adiyla cozumlendi' ($soonRow.Note -like '*Revoked*') $soonRow.Note

# 1g. Hicbir sertifika atanmamissa sure hakkinda hukum verilmez
$rows = @(& $m04.Run (New-CertContext -Certificates @((New-Cert -FriendlyName 'Bos' -Services 0 -DaysLeft 5))))
Assert-Equal 'Atanmis sertifika yoksa N/A' 'N/A' (Get-EDTestRow $rows 'En yakin biten').Status

# ===========================================================================
Write-Host "`n=== 2. M05 OS / kaynak ===" -ForegroundColor Cyan

function New-OsContext {
    param([double]$UptimeHours, [int]$TotalMb = 24000, [int]$FreeMb = 10000, [double]$CpuP95 = 5.0)
    $script:OsRow = [pscustomobject]@{
        TotalMemoryMb = $TotalMb; FreeMemoryMb = $FreeMb; LogicalCpus = 8
        UptimeHours = $UptimeHours; PageFileTotalMb = 3584; PageFileUsedMb = 1000; PageFilePeakMb = 1100
        OsCaption = 'Windows Server 2025'; NetRelease = 533509; NetVersion = '4.8.09221'; ReadError = ''
    }
    $mock = [pscustomobject]@{ ExchangeConnection = 'mock'; Parallelism = 1 }
    $mock | Add-Member -MemberType ScriptMethod -Name RunLocal -Value {
        param($Tasks)
        $out = @()
        foreach ($task in $Tasks) {
            $result = New-Object ExchangeDiag.ExecResult
            $result.Key = $task.Key
            $result.Output = [System.Management.Automation.PSObject[]]@([psobject]$script:OsRow)
            $out += $result
        }
        return $out
    }
    $context = New-BaseContext -Executor $mock
    # Perf ornegi enjekte edilir: M05 YENI bir ornekleme turu acmamali.
    $stats = New-Object ExchangeDiag.Stats
    $stats.Count = 20; $stats.P95 = $CpuP95; $stats.Mean = $CpuP95 / 3.0; $stats.Max = $CpuP95
    $context.Cache['PerfSamples'] = @{ 'MBX1' = [pscustomobject]@{
        Server = 'MBX1'; Error = $null; MissingClasses = @(); SampleCount = 20; AchievedInterval = 1.0
        Stats = @{ cpu = @{ '_Total' = @{ PercentProcessorTime = $stats } } }
    } }
    return $context
}

# 2a. Calisma suresi BAGLAMDIR: yakin zamanda yeniden baslatilmis sunucu
$rows = @(& $m05.Run (New-OsContext -UptimeHours 0.5))
$uptimeRow = Get-EDTestRow $rows 'Calisma suresi'
Assert-Equal 'Yakin reboot WARN' 'WARN' $uptimeRow.Status
Assert-Equal 'Saat olarak gosterildi' ('{0:N1} saat' -f 0.5) $uptimeRow.Values['MBX1']
Assert-True 'Diger bulgularin bu bilgiyle okunmasi soylendi' ($uptimeRow.Note -like '*Diger modullerin bulgularini bu bilgiyle okuyun*') $uptimeRow.Note
Assert-True 'Kuyrugun dolu olmasinin normal olabilecegi yazildi' ($uptimeRow.Note -like '*NORMAL olabilir*')

# 2b. Uzun calisma suresi OK ve gun olarak gosterilir
$rows = @(& $m05.Run (New-OsContext -UptimeHours 72))
$uptimeRow = Get-EDTestRow $rows 'Calisma suresi'
Assert-Equal 'Uzun uptime OK' 'OK' $uptimeRow.Status
Assert-Equal 'Gun olarak gosterildi' ('{0:N1} gun' -f 3.0) $uptimeRow.Values['MBX1']

# 2c. CPU p95 kullanilir, ortalama DEGIL
$rows = @(& $m05.Run (New-OsContext -UptimeHours 72 -CpuP95 95.0))
$cpuRow = Get-EDTestRow $rows 'CPU (p95)'
Assert-Equal 'CPU p95 okundu (ortalama 31.7 degil)' 95 $cpuRow.Values['MBX1']
Assert-Equal 'Yuksek CPU FAIL' 'FAIL' $cpuRow.Status
Assert-True 'CPU bir SONUC oldugu soylendi' ($cpuRow.Note -like '*SONUCTUR*') $cpuRow.Note
Assert-True 'Sebep icin M23/M24 gosterildi' ($cpuRow.Note -like '*M23*' -and $cpuRow.Note -like '*M24*')

# 2d. Dusuk bos bellek tek basina hata degildir (ESE onbellegi)
$rows = @(& $m05.Run (New-OsContext -UptimeHours 72 -TotalMb 24000 -FreeMb 6000))   # %25 bos
$memoryRow = Get-EDTestRow $rows 'Bellek'
Assert-Equal '%25 bos bellek OK' 'OK' $memoryRow.Status
Assert-True 'ESE onbellegi aciklandi' ($memoryRow.Note -like '*ESE onbellegi*') $memoryRow.Note
$rows = @(& $m05.Run (New-OsContext -UptimeHours 72 -TotalMb 24000 -FreeMb 500))    # %2 bos
Assert-Equal '%2 bos bellek WARN' 'WARN' (Get-EDTestRow $rows 'Bellek').Status

# 2e. .NET raporlanir ama hukum verilmez
$rows = @(& $m05.Run (New-OsContext -UptimeHours 72))
$netRow = Get-EDTestRow $rows '.NET Framework'
Assert-Equal '.NET surumu raporlandi' '4.8.09221 (Release 533509)' $netRow.Values['MBX1']
Assert-Equal '.NET icin hukum verilmedi' 'OK' $netRow.Status
Assert-True 'Uygun/uygun degil denmedigi yazili' ($netRow.Note -like '*hukmu VERMEZ*') $netRow.Note

# ===========================================================================
Write-Host "`n=== 3. M25 DB boyut / bos alan ===" -ForegroundColor Cyan

function New-Db {
    param([string]$Name, [string]$Size, [string]$Whitespace, [string]$Edb = 'E:\DB\db.edb')
    return [pscustomobject]@{
        Name = $Name; Server = 'MBX1'; MountedOnServer = 'MBX1'; Mounted = $true; Copies = @('MBX1')
        EdbFilePath = $Edb; LogFolderPath = 'E:\Logs'; CircularLogging = $false; LastFullBackup = $null
        Size = $Size; Whitespace = $Whitespace; IsRecovery = $false
    }
}

# 3a. Boyut ve whitespace dogru cozuluyor
$sizeContext = New-BaseContext -Databases @((New-Db -Name 'DB1' -Size '107.4 GB (115,321,372,672 bytes)' -Whitespace '10.74 GB (11,532,137,267 bytes)'))
$rows = @(& $m25.Run $sizeContext)
$sizeRow = Get-EDTestRow $rows 'En buyuk DB'
Assert-Equal 'Boyut GB olarak cozuldu' 107.4 $sizeRow.Values['MBX1']
Assert-Equal 'Bos alan orani hesaplandi' 10 (Get-EDTestRow $rows 'En buyuk DB bos alan orani').Values['MBX1']

# 3b. WHITESPACE'E ESIK UYGULANMAZ - %70 bos alan bile hukum uretmez
$hugeWhitespaceContext = New-BaseContext -Databases @((New-Db -Name 'DB1' -Size '100 GB (107,374,182,400 bytes)' -Whitespace '70 GB (75,161,927,680 bytes)'))
$rows = @(& $m25.Run $hugeWhitespaceContext)
$whitespaceRow = Get-EDTestRow $rows 'En buyuk DB bos alan orani'
Assert-Equal '%70 whitespace icin hukum YOK' 'OK' $whitespaceRow.Status
Assert-True 'Whitespace hata degil denildi' ($whitespaceRow.Note -like '*BIR HATA DEGILDIR*') $whitespaceRow.Note
Assert-True 'Defrag onerilmedigi yazili' ($whitespaceRow.Note -like '*rutin bir cozum DEGILDIR*')
Assert-Equal 'Genel satir da OK' 'OK' (Get-EDTestRow $rows 'En buyuk DB').Status

# 3c. Birim envanteri YOKSA kapasite iddiasi kurulmaz
$rows = @(& $m25.Run (New-BaseContext -Databases @((New-Db -Name 'DB1' -Size '900 GB (966,367,641,600 bytes)' -Whitespace '1 GB (1,073,741,824 bytes)'))))
$sizeRow = Get-EDTestRow $rows 'En buyuk DB'
Assert-Equal 'Birim bilgisi yokken OK' 'OK' $sizeRow.Status
Assert-True 'Hukum verilmedigi yazildi' ($sizeRow.Note -like '*hukum VERILMEDI*') $sizeRow.Note

# 3d. DB, birimdeki bos alandan BUYUKSE -> WARN ve dismount zinciri
$capacityContext = New-BaseContext -Databases @((New-Db -Name 'DB-BUYUK' -Size '900 GB (966,367,641,600 bytes)' -Whitespace '1 GB (1,073,741,824 bytes)'))
$capacityContext.Cache['VolumeInventory'] = @{ 'MBX1' = @(
    [pscustomobject]@{ Name = 'E:\'; Label = 'Data'; CapacityGB = 1000.0; FreeGB = 50.0; FreePct = 5.0 }
) }
$rows = @(& $m25.Run $capacityContext)
$sizeRow = Get-EDTestRow $rows 'En buyuk DB'
Assert-Equal 'DB > bos alan -> WARN' 'WARN' $sizeRow.Status
Assert-True 'Dismount zinciri aciklandi' ($sizeRow.Note -like '*dismount olur ve teslim durur*') $sizeRow.Note
Assert-True 'Birim adi yazildi' ($sizeRow.Note -like '*E:\*')

# 3e. Bol bos alan varken iddia kurulmaz
$roomyContext = New-BaseContext -Databases @((New-Db -Name 'DB1' -Size '100 GB (107,374,182,400 bytes)' -Whitespace '1 GB (1,073,741,824 bytes)'))
$roomyContext.Cache['VolumeInventory'] = @{ 'MBX1' = @(
    [pscustomobject]@{ Name = 'E:\'; Label = 'Data'; CapacityGB = 1000.0; FreeGB = 800.0; FreePct = 80.0 }
) }
$rows = @(& $m25.Run $roomyContext)
$sizeRow = Get-EDTestRow $rows 'En buyuk DB'
Assert-Equal 'Bol alan varken OK' 'OK' $sizeRow.Status
Assert-True 'Hicbiri buyuk degil denildi' ($sizeRow.Note -like '*bos alandan buyuk degil*') $sizeRow.Note

# 3f. Boyutu okunamayan DB gizlenmez
$rows = @(& $m25.Run (New-BaseContext -Databases @((New-Db -Name 'DB-BOZUK' -Size 'Unlimited' -Whitespace ''))))
$sizeRow = Get-EDTestRow $rows 'En buyuk DB'
Assert-True 'Okunamayan DB bildirildi' ($sizeRow.Note -like '*Boyutu okunamayan*DB-BOZUK*') $sizeRow.Note

# ===========================================================================
Write-Host "`n=== 4. M26 icerik indeksi ===" -ForegroundColor Cyan

function New-IndexContext {
    param($Copies)
    $context = New-BaseContext
    $context.Cache['CopyStatus'] = [pscustomobject]@{ Copies = @($Copies); FailedServers = @() }
    return $context
}

function New-IndexCopy {
    param([string]$Database, [string]$Index, [string]$Status = 'Mounted')
    return [pscustomobject]@{
        Server = 'MBX1'; QueriedFrom = 'MBX1'; Database = $Database; Status = $Status
        CopyQueue = 0; ReplayQueue = 0; ContentIndexState = $Index; IndexError = ''
        IsActive = $true; Preference = 1; LastInspected = (Get-Date); ErrorMessage = ''
    }
}

# 4a. NotApplicable NORMALDIR (canli lab'da tam olarak bu doner)
$rows = @(& $m26.Run (New-IndexContext -Copies @((New-IndexCopy -Database 'DB1' -Index 'NotApplicable'))))
$indexRow = Get-EDTestRow $rows 'Icerik indeksi durumu'
Assert-Equal 'NotApplicable N/A (FAIL degil)' 'N/A' $indexRow.Status
Assert-True 'Normal oldugu acikca yazildi' ($indexRow.Note -like '*NORMALDIR ve hata DEGILDIR*') $indexRow.Note

# 4b. Saglikli indeks OK
$rows = @(& $m26.Run (New-IndexContext -Copies @((New-IndexCopy -Database 'DB1' -Index 'Healthy'))))
Assert-Equal 'Healthy indeks OK' 'OK' (Get-EDTestRow $rows 'Icerik indeksi durumu').Status

# 4c. Bozuk indeks FAIL AMA teslimi geciktirmedigi soylenir
$rows = @(& $m26.Run (New-IndexContext -Copies @(
    (New-IndexCopy -Database 'DB1' -Index 'Failed')
    (New-IndexCopy -Database 'DB2' -Index 'Healthy')
)))
$indexRow = Get-EDTestRow $rows 'Icerik indeksi durumu'
Assert-Equal 'Bozuk indeks FAIL' 'FAIL' $indexRow.Status
Assert-True 'Hangi DB oldugu yazildi' ($indexRow.Note -like '*DB1=Failed*') $indexRow.Note
Assert-True 'KISA DEVRE KURULMADI' ($indexRow.Note -like '*teslim gecikmesi yaratmaz*') 'indeks bozuk != posta gecikiyor'
Assert-True 'Dolayli CPU/disk iliskisi aciklandi' ($indexRow.Note -like '*M05*' -and $indexRow.Note -like '*M21*')

# 4d. Crawling WARN ve CPU/disk yukune baglanir
$rows = @(& $m26.Run (New-IndexContext -Copies @((New-IndexCopy -Database 'DB1' -Index 'Crawling'))))
$indexRow = Get-EDTestRow $rows 'Icerik indeksi durumu'
Assert-Equal 'Crawling WARN' 'WARN' $indexRow.Status
Assert-Equal 'Crawling sayisi ayri satirda' 1 (Get-EDTestRow $rows 'Olusturulan (crawling)').Values['MBX1']
Assert-True 'CPU/disk yuku uyarisi verildi' ($indexRow.Note -like '*CPU ve disk yukunu artirir*') $indexRow.Note

# 3f. TAM DOLU birim: en tehlikeli durum, atlanacak durum DEGIL.
# Eskiden "FreeGB -le 0 -> continue" tam dolu birimi kontrolun disinda
# birakiyor, ardindan "hicbir veritabani bos alandan buyuk degil" deniyordu.
$fullContext = New-BaseContext -Databases @((New-Db -Name 'DB1' -Size '450 GB (483,183,820,800 bytes)' -Whitespace '1 GB (1,073,741,824 bytes)'))
$fullContext.Cache['VolumeInventory'] = @{ 'MBX1' = @(
    [pscustomobject]@{ Name = 'E:\'; Label = 'Data'; CapacityGB = 1000.0; FreeGB = 0.0; FreePct = 0.0 }
) }
$rows = @(& $m25.Run $fullContext)
$sizeRow = Get-EDTestRow $rows 'En buyuk DB'
Assert-Equal 'Bos alani BITMIS birim FAIL' 'FAIL' $sizeRow.Status
Assert-True 'Bos alan YOK oldugu yazildi' ($sizeRow.Note -like '*bos alan YOK*') $sizeRow.Note
Assert-True 'Tam dolu birim icin "hicbiri buyuk degil" DENMEDI' `
    ($sizeRow.Note -notlike '*hicbiri bulundugu birimdeki bos alandan buyuk degil*') $sizeRow.Note

# 3g. Yol hicbir birimle eslesmezse "hepsi temiz" DENMEZ.
$mismatchContext = New-BaseContext -Databases @((New-Db -Name 'DB1' -Size '100 GB (107,374,182,400 bytes)' -Whitespace '1 GB (1,073,741,824 bytes)'))
$mismatchContext.Cache['VolumeInventory'] = @{ 'MBX1' = @(
    [pscustomobject]@{ Name = 'Z:\'; Label = 'Baska'; CapacityGB = 1000.0; FreeGB = 900.0; FreePct = 90.0 }
) }
$rows = @(& $m25.Run $mismatchContext)
$sizeRow = Get-EDTestRow $rows 'En buyuk DB'
Assert-True 'Eslesmeyen yol icin olumlu iddia yok' `
    ($sizeRow.Note -notlike '*hicbiri bulundugu birimdeki bos alandan buyuk degil*') $sizeRow.Note
Assert-True 'Kontrol EDILEMEDIGI yazildi' ($sizeRow.Note -like '*kontrol EDILEMEDI*') $sizeRow.Note

# 4e. Kopya durumu okunamazsa temiz N/A
$emptyContext = New-BaseContext
$emptyContext.Cache['CopyStatus'] = [pscustomobject]@{ Copies = @(); FailedServers = @('MBX1') }
$rows = @(& $m26.Run $emptyContext)
Assert-Equal 'Veri yoksa N/A' 'N/A' $rows[0].Status

# 4f. YARIM okunmus ortam: bir sunucu okundu, digeri okunamadi.
# Eskiden M26 FailedServers'a hic bakmiyor ve "Tum icerik indeksleri
# saglikli" diyordu - okunamayan sunucu hakkinda hicbir sey bilmeden.
$partialContext = New-BaseContext
$partialContext.Cache['CopyStatus'] = [pscustomobject]@{
    Copies = @([pscustomobject]@{
        Server = 'MBX1'; Database = 'DB1'; Status = 'Mounted'
        ContentIndexState = 'Healthy'; IndexError = ''; IsActive = $true
    })
    FailedServers = @('MBX9')
}
$rows = @(& $m26.Run $partialContext)
$indexRow = $rows[0]
Assert-True 'Yarim okunmus ortamda "hepsi saglikli" DENMEDI' `
    ($indexRow.Note -notlike '*Tum icerik indeksleri saglikli*') $indexRow.Note
Assert-True 'Okunamayan sunucu adiyla bildirildi' ($indexRow.Note -like '*MBX9*') $indexRow.Note

# ===========================================================================
Write-EDTestSummary
Remove-Item -Path $script:OutputDir -Recurse -Force -ErrorAction SilentlyContinue
if (Get-EDTestFailed -gt 0) { exit 1 }
