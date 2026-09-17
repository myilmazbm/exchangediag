<#
    -CompareWith delta motoru testleri.

    Delta motorunun asil isi fark hesaplamak DEGIL, hangi farkin anlamsiz
    oldugunu soylemektir. Testlerin agirligi da oradadir:

      - Kapsam farki (pencere, heavy, log erisimi) kiyasi GECERSIZ kilar
      - N/A <-> deger gecisi iyilesme/gerileme DEGILDIR
      - Kucuk mutlak degerlerde yuzde YANILTIR ve gizlenir
      - Metin degerlerde yuzde hesaplanmaz
      - Kaybolan kontrol "sorun gecti" anlamina GELMEZ
      - Deger ayni ama durum degistiyse satir yine gorunur

    Ayrica PowerShell tuzagi: switch icindeki 'continue' kapsayan foreach'i
    DEGIL switch'i sonlandirir. Ilk uygulamada bu, degismemis 20 satiri
    "fark" diye raporlamisti - 1a testi tam olarak bunu koruyor.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $projectRoot 'Core\CoreLoader.ps1')
. (Join-Path $projectRoot 'Core\Config.ps1')
. (Join-Path $projectRoot 'Core\Framework.ps1')
. (Join-Path $projectRoot 'Core\Report.ps1')
. (Join-Path $projectRoot 'Core\Compare.ps1')
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

Initialize-ExchangeDiagCore -CoreRoot (Join-Path $projectRoot 'Core') | Out-Null

$script:Root = Join-Path $env:TEMP ("ed-cmp-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

$config = Get-EDConfig -ProjectRoot $projectRoot

function New-PreviousRun {
    <# Sahte bir onceki calistirma klasoru uretir. #>
    param(
        $Rows,
        [string[]]$Columns = @('MBX1'),
        [hashtable]$Meta = @{},
        # Eski surumle uretilmis bir run-meta.json'i taklit etmek icin:
        # adi verilen alanlar dosyaya HIC yazilmaz (bos yazilmaz - yok).
        [string[]]$OmitMetaFields = @(),
        # Ayni sey SUMMARY.csv icin: adi verilen KOLONLAR basliktan silinir.
        # Import-Csv boyle bir kolonu satir nesnesine hic eklemez (olculdu),
        # yani erisim StrictMode altinda istisna firlatir.
        [string[]]$DropCsvColumns = @(),
        # SUMMARY.csv'ye fazladan sutun ekler (ad -> her satirdaki deger).
        # Yeni bir ust veri sutununu ya da tanimadigimiz bir cikti bicimini
        # taklit etmek icin.
        [hashtable]$ExtraCsvColumns = @{},
        [switch]$NoMeta
    )

    $folder = Join-Path $script:Root ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $csvPath = Join-Path $folder 'SUMMARY.csv'
    Export-EDSummaryCsv -Rows $Rows -Columns $Columns -Path $csvPath | Out-Null

    if ($DropCsvColumns.Count -gt 0) {
        $written = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8)
        if ($written.Count -gt 0) {
            $keep = @($written[0].PSObject.Properties.Name | Where-Object { $_ -notin $DropCsvColumns })
            $written | Select-Object -Property $keep |
                Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
        }
    }

    if ($ExtraCsvColumns.Count -gt 0) {
        $written = @(Import-Csv -LiteralPath $csvPath -Encoding UTF8)
        foreach ($item in $written) {
            foreach ($name in $ExtraCsvColumns.Keys) {
                $item | Add-Member -NotePropertyName $name -NotePropertyValue $ExtraCsvColumns[$name] -Force
            }
        }
        if ($written.Count -gt 0) {
            $written | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
        }
    }

    if (-not $NoMeta) {
        # servers VARSAYILANI sutunlarla ayni: gercek kosumda da ikisi ayni
        # topolojiden uretilir (Save-EDRunMeta topolojiyi, Export-EDSummaryCsv
        # ayni sunucu listesini yazar). Fixture'in bunlari ayirmasi, gercekte
        # olmayan bir durumu test etmek olurdu.
        $defaults = [ordered]@{
            runId = 'onceki'; startedLocal = '2026-09-17 03:00:00'; startedHour = 3
            utcOffsetHours = 3; windowHours = 1; heavy = $true; logAccess = 'smb'
            serverFilter = @(); servers = @($Columns); profile = 'production'; modules = @('M10')
        }
        foreach ($key in $Meta.Keys) { $defaults[$key] = $Meta[$key] }
        foreach ($field in $OmitMetaFields) { $defaults.Remove($field) }
        $json = ([pscustomobject]$defaults) | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText((Join-Path $folder 'run-meta.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $folder
}

function New-CompareContext {
    param([int]$Hour = 3, [double]$WindowHours = 1, [bool]$Heavy = $true, [string]$LogAccess = 'smb', $Servers = $null,
          [string[]]$ServerFilter = @())
    if ($null -eq $Servers) { $Servers = @((New-EDTestServer -Name 'MBX1')) }
    $context = New-EDTestContext -Config $config -Executor $null -Servers $Servers `
        -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:Root
    $context.WindowHours = $WindowHours
    $context.Heavy = $Heavy
    $context.LogAccess = $LogAccess
    $context.ServerFilter = @($ServerFilter)
    $context.StartTime = (Get-Date).Date.AddHours($Hour)
    $context.RunId = 'simdiki'
    return $context
}

function Get-EDHighlightCount {
    <#
        Ozet kovasini ADIYLA sayar. Dogrudan $highlights.X yazmak StrictMode
        altinda, kova HIC YOKKEN testi "coktu"ye cevirir ve hangi iddianin
        kaldigi gorunmez; burada eksik kova -1 olarak raporlanir.
    #>
    param($Highlights, [string]$Name)
    $property = $Highlights.PSObject.Properties[$Name]
    if (-not $property) { return -1 }
    return @($property.Value).Count
}

function Get-EDFirstField {
    <#
        Ilk satirin bir alanini okur. Dogrudan $rows[0].Alan yazmak, satir HIC
        YOKKEN (aranan satirin uretilmedigi hata durumunda) StrictMode altinda
        paketi coktururdu; boyle bir cokme hangi iddianin kaldigini gizler.
    #>
    param($Rows, [string]$Name)
    $first = @($Rows) | Select-Object -First 1
    if ($null -eq $first) { return '(satir yok)' }
    $property = $first.PSObject.Properties[$Name]
    if (-not $property) { return '(alan yok)' }
    return "$($property.Value)"
}

# ===========================================================================
Write-Host "`n=== 1. Fark yoksa delta uretilmez ===" -ForegroundColor Cyan

# 1a. AYNI degerler - switch/continue tuzaginin regresyon testi
$sameRows = @(
    New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 12.5 } -Unit 'sn' -Status 'OK'
    New-EDRow -Module 'M01' -Check 'Rol' -Values @{ MBX1 = 'Mailbox' } -Status 'OK'
    New-EDRow -Module 'M14' -Check 'Kuyruk' -Values @{ MBX1 = 0 } -Status 'OK'
)
$previous = New-PreviousRun -Rows $sameRows
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $sameRows -Context (New-CompareContext)
Assert-Equal 'Degisiklik yokken 0 delta' 0 @($comparison.Deltas).Count
Assert-True 'Kapsam ayni -> kiyaslanabilir' ($comparison.Scope.Comparable) 'blocking yok'

# ===========================================================================
Write-Host "`n=== 2. Sayisal farklar ===" -ForegroundColor Cyan

# 2a. Anlamli artis yuzdeyle raporlanir
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK'))
$current = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 25 } -Unit 'sn' -Status 'WARN'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$delta = @($comparison.Deltas)[0]
Assert-Equal 'Yon ARTTI' 'ARTTI' $delta.Yon
Assert-True 'Mutlak ve yuzde birlikte' ($delta.Fark -like '*+15*' -and $delta.Fark -like '*150*') $delta.Fark
Assert-Equal 'Durum gecisi yazildi' 'OK -> WARN' $delta.Durum

# 2b. KUCUK MUTLAK DEGERDE YUZDE GIZLENIR (0.001 -> 0.002 = %100 ama anlamsiz)
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M21' -Check 'Disk' -Values @{ MBX1 = 0.001 } -Unit 'sn' -Status 'OK'))
$current = @((New-EDRow -Module 'M21' -Check 'Disk' -Values @{ MBX1 = 0.002 } -Unit 'sn' -Status 'OK'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$delta = @($comparison.Deltas)[0]
Assert-True 'Yuzde YAZILMADI' ($delta.Fark -notlike '*%*') $delta.Fark
Assert-True 'Yaniltici oldugu soylendi' ($delta.Aciklama -like '*yuzde YANILTIR*') $delta.Aciklama

# 2c. Buyuk degerde kucuk degisim gurultu olarak isaretlenir
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 100 } -Unit 'sn' -Status 'OK'))
$current = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 102 } -Unit 'sn' -Status 'OK'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
Assert-True 'Kucuk degisim gurultu denildi' (@($comparison.Deltas)[0].Aciklama -like '*gurultusu olabilir*') @($comparison.Deltas)[0].Aciklama

# 2d. Azalma dogru isaretlenir
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 60 } -Unit 'sn' -Status 'WARN'))
$current = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 12 } -Unit 'sn' -Status 'OK'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
Assert-Equal 'Yon AZALDI' 'AZALDI' @($comparison.Deltas)[0].Yon

# ===========================================================================
Write-Host "`n=== 3. N/A siniri ve metin degerler ===" -ForegroundColor Cyan

# 3a. N/A -> deger IYILESME DEGILDIR
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M20' -Check 'RPC' -Values @{ MBX1 = 'N/A' } -Status 'N/A'))
$current = @((New-EDRow -Module 'M20' -Check 'RPC' -Values @{ MBX1 = 45 } -Unit 'ms' -Status 'OK'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$delta = @($comparison.Deltas)[0]
Assert-Equal 'Yon OLCUM (ARTTI/AZALDI degil)' 'OLCUM' $delta.Yon
Assert-True 'Iyilesme olmadigi acikca yazildi' ($delta.Aciklama -like '*iyilesme veya gerileme DEGILDIR*') $delta.Aciklama
Assert-Equal 'Yuzde hesaplanmadi' '-' $delta.Fark

# 3b. Ikisi de N/A ise fark uretilmez
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M20' -Check 'RPC' -Values @{ MBX1 = 'N/A' } -Status 'N/A'))
$current = @((New-EDRow -Module 'M20' -Check 'RPC' -Values @{ MBX1 = 'N/A' } -Status 'N/A'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
Assert-Equal 'Iki N/A -> fark yok' 0 @($comparison.Deltas).Count

# 3c. Metin degisiminde yuzde hesaplanmaz
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M02' -Check 'Build' -Values @{ MBX1 = '15.02.2562.017' } -Status 'OK'))
$current = @((New-EDRow -Module 'M02' -Check 'Build' -Values @{ MBX1 = '15.02.2562.049' } -Status 'OK'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$delta = @($comparison.Deltas)[0]
Assert-Equal 'Metin degisimi DEGISTI' 'DEGISTI' $delta.Yon
Assert-Equal 'Yuzde yok' '-' $delta.Fark

# 3d. Deger AYNI ama DURUM degistiyse satir yine gorunur (esik degismis olabilir)
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 55 } -Unit 'sn' -Status 'OK'))
$current = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 55 } -Unit 'sn' -Status 'WARN'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
Assert-Equal 'Deger ayni, durum degisti -> satir var' 1 @($comparison.Deltas).Count
Assert-Equal 'Yon DURUM' 'DURUM' @($comparison.Deltas)[0].Yon
Assert-True 'Esik degismis olabilir denildi' (@($comparison.Deltas)[0].Aciklama -like '*esik*') @($comparison.Deltas)[0].Aciklama

# 3e. Deger DEGISTIYSE "deger ayni" DENMEZ.
# Ornek raporda yakalandi: 16.8 -> 82.6 farkinin yanina "deger ayni"
# yazilmisti; rapor kendi verisini yalanliyordu.
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M05' -Check 'CPU' -Values @{ MBX1 = 16.8 } -Unit '%' -Status 'OK'))
$current = @((New-EDRow -Module 'M05' -Check 'CPU' -Values @{ MBX1 = 82.6 } -Unit '%' -Status 'WARN'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$delta = @($comparison.Deltas)[0]
Assert-True 'Degisen degere "ayni" DENMEDI' ($delta.Aciklama -notlike '*Deger ayni*') $delta.Aciklama
Assert-True 'Fark yine de yazildi' ($delta.Fark -like ('*+' + ('{0:N1}' -f 65.8) + '*')) $delta.Fark

# 3f. IKI calistirmada da deger okunamadi ama DURUM degisti.
# Deger yoksa satiri tamamen atlamak gercek bir gerilemeyi rapordan siler:
# ornekte OK -> FAIL gecisi hic yazilmiyor, DELTA.html "Durum gerilemesi yok"
# diyordu. "Olculemedi" olcumun kaybi demektir, hukmun kaybi degil.
$previous = New-PreviousRun -Rows @(
    (New-EDRow -Module 'M30' -Check 'Kopya kuyrugu' -Values @{ SRV1 = 'N/A'; SRV2 = 'N/A' } -Status 'OK')
) -Columns @('SRV1', 'SRV2')
$current = @((New-EDRow -Module 'M30' -Check 'Kopya kuyrugu' -Values @{ SRV1 = 'N/A'; SRV2 = 'N/A' } -Status 'FAIL'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current `
    -Context (New-CompareContext -Servers @((New-EDTestServer -Name 'SRV1'), (New-EDTestServer -Name 'SRV2')))
$statusRows = @($comparison.Deltas | Where-Object { $_.Durum -eq 'OK -> FAIL' })
Assert-Equal 'Degerler N/A olsa da durum satiri uretildi' 1 $statusRows.Count
Assert-Equal 'Yon DURUM' 'DURUM' (Get-EDFirstField $statusRows 'Yon')
$highlights = Get-EDDeltaHighlights -Comparison $comparison
Assert-Equal 'Gerileme ozete girdi' 1 @($highlights.Regressions).Count

# ===========================================================================
Write-Host "`n=== 4. Kapsam korumasi ===" -ForegroundColor Cyan

$rows = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK'))

# 4a. Pencere farki kiyasi GECERSIZ kilar
$previous = New-PreviousRun -Rows $rows -Meta @{ windowHours = 1 }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext -WindowHours 24)
Assert-True 'Pencere farki blocking' (-not $comparison.Scope.Comparable) 'kiyaslanabilir degil'
Assert-True 'Olcum farki oldugu yazildi' ((@($comparison.Scope.Blocking) -join ' ') -like '*OLCUM FARKIDIR*') (@($comparison.Scope.Blocking) -join ' ')

# 4b. -Heavy farki blocking
$previous = New-PreviousRun -Rows $rows -Meta @{ heavy = $false }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext -Heavy $true)
Assert-True 'Heavy farki blocking' (-not $comparison.Scope.Comparable)
Assert-True 'Kayboldu sanilmasin uyarisi' ((@($comparison.Scope.Blocking) -join ' ') -like "*'kayboldu' sanilmamalidir*")

# 4c. Log erisim yolu farki blocking
$previous = New-PreviousRun -Rows $rows -Meta @{ logAccess = 'cmdlet' }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext -LogAccess 'smb')
Assert-True 'Log erisim farki blocking' (-not $comparison.Scope.Comparable)

# 4d. run-meta.json YOKSA kapsam denetlenemez - bu da bildirilir
$previous = New-PreviousRun -Rows $rows -NoMeta
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext)
Assert-True 'Meta yoksa kiyaslanabilir degil' (-not $comparison.Scope.Comparable)
Assert-True 'Denetlenemedigi yazildi' ((@($comparison.Scope.Blocking) -join ' ') -like '*DENETLENEMEDI*')

# 4e. SAAT farki blocking DEGIL, advisory - cunku kiyasin AMACI budur
$previous = New-PreviousRun -Rows $rows -Meta @{ startedHour = 3 }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext -Hour 14)
Assert-True 'Saat farki kiyasi gecersiz KILMAZ' ($comparison.Scope.Comparable) 'blocking yok'
$advisory = @($comparison.Scope.Advisory) -join ' '
Assert-True 'Saat farki advisory olarak bildirildi' ($advisory -like '*03:00 -> 14:00*') $advisory
Assert-True 'Yuk olabilecegi hatirlatildi' ($advisory -like '*YUK olabilir*')

# 4f. Sunucu kumesi farki advisory
$previous = New-PreviousRun -Rows $rows -Meta @{ servers = @('MBX1', 'MBX2') }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext)
Assert-True 'Eksilen sunucu bildirildi' ((@($comparison.Scope.Advisory) -join ' ') -like '*MBX2*') (@($comparison.Scope.Advisory) -join ' ')
Assert-True 'Sunucu farki kiyasi gecersiz kilmaz' ($comparison.Scope.Comparable)

# 4g. MODUL KUMESI farki bildirilir.
# run-meta.json'a modul listesi YAZILIYOR ama geri OKUNMUYORDU: -Modules M10,M11
# ile alinmis bir taban tam bir kosuyla kiyaslandiginda diger butun moduller
# "YENI", tersinde "KAYBOLDU" gorunuyor ve tek bir uyari cikmiyordu.
$previous = New-PreviousRun -Rows $rows -Meta @{ modules = @('M10', 'M11', 'M12', 'M14', 'M20') }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext) `
    -ModuleTimings @([pscustomobject]@{ Id = 'M10'; Seconds = 1 })
$advisory = @($comparison.Scope.Advisory) -join ' '
Assert-True 'Modul kumesi farki bildirildi' ($advisory -like '*Modul kumesi farkli*') $advisory
Assert-True 'Eksik moduller sayildi' ($advisory -like '*M11*') $advisory
Assert-True 'Modul farki kiyasi gecersiz KILMAZ' ($comparison.Scope.Comparable)

# 4h. Modul listesi bilinmiyorsa (eski meta / timing verilmedi) uydurma uyari cikmaz.
$previous = New-PreviousRun -Rows $rows -Meta @{ modules = @('M10', 'M11') }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext)
Assert-True 'Bilinmeyen modul listesi uyari uretmez' ((@($comparison.Scope.Advisory) -join ' ') -notlike '*Modul kumesi*') `
    (@($comparison.Scope.Advisory) -join ' ')

# 4i. SUNUCU FILTRESI farki bildirilir: -Servers ile daraltilmis bir kosu,
# tam kosuyla kiyaslandiginda eksik sunuculari "kayboldu" gibi gosterir.
$previous = New-PreviousRun -Rows $rows -Meta @{ serverFilter = @('MBX1') }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext -ServerFilter @())
$advisory = @($comparison.Scope.Advisory) -join ' '
Assert-True 'Sunucu filtresi farki bildirildi' ($advisory -like '*Sunucu filtresi farkli*') $advisory
Assert-True 'Filtre farki kiyasi gecersiz kilmaz' ($comparison.Scope.Comparable)

# ===========================================================================
Write-Host "`n=== 4B. Eksik meta alanlari (eski surumle uretilmis run-meta.json) ===" -ForegroundColor Cyan

# Test-EDRunComparable, onceki kosumun meta alanlarini KORUMASIZ okuyordu
# ($Previous.logAccess gibi). StrictMode altinda olmayan bir ozellik
# PropertyNotFoundException firlatir; yani delta raporunun TAMAMI dusuyordu -
# hem de tam olarak fonksiyonun ilk dalinin kabul ettigi senaryoda: "onceki
# kosum eski surumle uretilmis olabilir".
#
# Duzeltme yalnizca "cokmesin" degil: eksik bir alani sessizce varsayilanla
# doldurmak, pencere farkini gizleyip operatore SAHTE bir delta gostermek
# olurdu. Bu yuzden asagidaki iddialar eksigin ADIYLA bildirildigini ve
# DOGRU kovaya dustugunu de test eder.

function Get-EDDetailSnippet {
    <#
        Kapsam uyarilari uzundur; test ciktisinda tam metin ekrani doldurup
        hangi iddianin kaldigini gizler. Kisaltilmis metin yine de hangi
        alanin adlandirildigini gosterir.
    #>
    param([AllowNull()][string]$Text, [int]$Max = 150)
    if (-not $Text) { return '(bos)' }
    if ($Text.Length -le $Max) { return $Text }
    return ($Text.Substring(0, $Max) + '...')
}

function New-EDFullCurrentMeta {
    <# Compare-EDRuns'in urettigi "simdiki" meta nesnesiyle ayni sekil. #>
    param([double]$WindowHours = 1)
    return [pscustomobject]@{
        windowHours  = $WindowHours
        heavy        = $true
        logAccess    = 'smb'
        profile      = 'production'
        startedHour  = 3
        servers      = @('MBX1')
        serverFilter = @()
        modules      = @('M10')
    }
}

# 4B-a. YALNIZCA windowHours tasiyan meta. Duzeltme olmadan bu cagri
# istisnayla cokuyordu; testin ilk iddiasi tam olarak budur.
$partialScope = $null
$partialThrew = $false
$partialError = ''
try { $partialScope = Test-EDRunComparable -Previous ([pscustomobject]@{ windowHours = 1 }) -Current (New-EDFullCurrentMeta) }
catch { $partialThrew = $true; $partialError = "$_" }
Assert-True 'Eksik alanli meta ISTISNA firlatmaz' (-not $partialThrew) $partialError

if ($null -ne $partialScope) {
    $blockingText = @($partialScope.Blocking) -join ' '
    $advisoryText = @($partialScope.Advisory) -join ' '

    # Eksiklik SESSIZCE yutulmaz: uyarinin metninde alanin ADI gecmeli,
    # yoksa operator raporun hangi boyutunun dogrulanmadigini bilemez.
    Assert-True 'Eksik logAccess alan ADIYLA bildirildi' ($blockingText -like "*'logAccess'*") (Get-EDDetailSnippet $blockingText)
    Assert-True 'Eksik heavy alan ADIYLA bildirildi' ($blockingText -like "*'heavy'*") (Get-EDDetailSnippet $blockingText)
    Assert-True 'Eksik alan icin DENETLENEMEDI yazildi' ($blockingText -like '*DENETLENEMEDI*') (Get-EDDetailSnippet $blockingText)
    # Eksik alan "fark yok" DEGILDIR: kiyas guvenilir sayilmaz.
    Assert-True 'Eksik alan kiyasi guvenilir BIRAKMAZ' (-not $partialScope.Comparable) 'blocking var'
    # Var olan ve esit olan alan icin uyari cikmamali; gurultu gercek eksigi gizler.
    Assert-True 'Var olan alan icin eksik uyarisi cikmaz' ($blockingText -notlike "*'windowHours'*") (Get-EDDetailSnippet $blockingText)
    Assert-True 'Eksik servers advisory kovasinda bildirildi' ($advisoryText -like "*'servers'*") (Get-EDDetailSnippet $advisoryText)
    # Olmayan sunucu listesinden fark UYDURULMAZ.
    Assert-True 'Olmayan listeden sunucu farki uydurulmadi' ($advisoryText -notlike '*Simdi eklenen sunucu*') (Get-EDDetailSnippet $advisoryText)
    Assert-True 'Bilinmeyen kosum saati 00:00 sayilmadi' ($advisoryText -notlike '*Calistirma saatleri farkli*') (Get-EDDetailSnippet $advisoryText)
}
else {
    Assert-True 'Eksik alanli metadan kapsam sonucu uretildi' $false 'sonuc yok'
}

# 4B-b. logAccess EKSIKSE kova Blocking'dir, Advisory degil: kiyasi anlamsiz
# kilan bir boyut denetlenemiyorsa "dikkat et ama guvenebilirsin" denemez.
$noLogAccess = [pscustomobject]@{
    windowHours = 1; heavy = $true; profile = 'production'; startedHour = 3
    servers = @('MBX1'); serverFilter = @(); modules = @('M10')
}
$scope = Test-EDRunComparable -Previous $noLogAccess -Current (New-EDFullCurrentMeta)
Assert-True 'Denetlenemeyen log erisimi BLOCKING' (-not $scope.Comparable) (@($scope.Blocking) -join ' ')
Assert-True 'logAccess eksigi advisory kovasina DUSMEDI' ((@($scope.Advisory) -join ' ') -notlike '*logAccess*') (@($scope.Advisory) -join ' ')

# 4B-c. profile EKSIKSE Advisory: profil FARKI da kiyasi gecersiz kilmiyordu.
$noProfile = [pscustomobject]@{
    windowHours = 1; heavy = $true; logAccess = 'smb'; startedHour = 3
    servers = @('MBX1'); serverFilter = @(); modules = @('M10')
}
$scope = Test-EDRunComparable -Previous $noProfile -Current (New-EDFullCurrentMeta)
Assert-True 'Denetlenemeyen profil kiyasi GECERSIZ KILMAZ' ($scope.Comparable) (@($scope.Blocking) -join ' ')
Assert-True 'Profil eksigi yine de bildirildi' ((@($scope.Advisory) -join ' ') -like "*'profile'*") (@($scope.Advisory) -join ' ')

# 4B-d. Eksik alan varsayilanla DOLDURULMAZ: pencere gercekten farkliysa
# ve heavy alani yoksa iki ayri blocking cikmali - biri digerini yutmamali.
$noHeavy = [pscustomobject]@{
    windowHours = 1; logAccess = 'smb'; profile = 'production'; startedHour = 3
    servers = @('MBX1'); serverFilter = @(); modules = @('M10')
}
$scope = Test-EDRunComparable -Previous $noHeavy -Current (New-EDFullCurrentMeta -WindowHours 24)
$blockingText = @($scope.Blocking) -join ' '
Assert-True 'Gercek pencere farki hala bildiriliyor' ($blockingText -like '*OLCUM FARKIDIR*') (Get-EDDetailSnippet $blockingText)
Assert-True 'Eksik heavy ayrica bildiriliyor' ($blockingText -like "*'heavy'*") (Get-EDDetailSnippet $blockingText)

# 4B-e. UCTAN UCA: diskteki run-meta.json alan eksigiyle okunuyor.
$previous = New-PreviousRun -Rows $rows -OmitMetaFields @('logAccess', 'startedHour', 'profile')
$partialComparison = $null
$partialThrew = $false
$partialError = ''
try { $partialComparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext) }
catch { $partialThrew = $true; $partialError = "$_" }
Assert-True 'Eksik alanli run-meta.json delta motorunu COKERTMEZ' (-not $partialThrew) $partialError

if ($null -ne $partialComparison) {
    $partialPath = Join-Path $script:Root 'DELTA-eksik-meta.html'
    Export-EDDeltaHtml -Comparison $partialComparison -Path $partialPath -Context (New-CompareContext) | Out-Null
    $partialHtml = Get-Content $partialPath -Raw -Encoding UTF8
    # Bilinmeyen kosum saati UYDURULMAZ: baslikta '?' kalir.
    Assert-True 'Bilinmeyen kosum saati raporda ? olarak yazildi' ($partialHtml -match '\(\?\)') 'saat uydurulmadi'
    Assert-True 'Kapsam denetlenemedigi raporun ustunde' ($partialHtml -like '*KIYAS GUVENILIR DEGIL*') 'blocking blogu basildi'
}
else {
    Assert-True 'Eksik meta ile delta raporu uretilebildi' $false 'kiyas kurulamadi'
}

# 4B-f. runId eksikse klasor adina duselir (o da korumasiz okunuyordu).
$previous = New-PreviousRun -Rows $rows -OmitMetaFields @('runId')
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext)
Assert-Equal 'runId yoksa klasor adi kullanilir' (Split-Path -Leaf $previous) "$($comparison.PreviousRunId)"

# ===========================================================================
Write-Host "`n=== 4C. Onceki SUMMARY.csv'nin SEKLI ===" -ForegroundColor Cyan

# Meta alanlarindaki kusurun kardesi: Compare-EDRuns onceki kosumun
# SUMMARY.csv'sinden Modul / Kontrol / Durum alanlarini korumasiz okuyordu.
# Import-Csv olculdu: BASLIKTA olmayan bir kolon satir nesnesine hic eklenmez
# (ozellik yoktur, degeri $null da degildir), yani StrictMode altinda erisim
# PropertyNotFoundException firlatir ve delta raporunun tamami duser.
#
# Ama ayrim meta'dakiyle AYNI DEGIL: eksik bir kolon BUTUN satirlarda
# eksiktir, yani tek bir boyut degil DOSYANIN BICIMI sorunludur. Bu yuzden
# satir basina uyari beklenmez; tek ve net bir sinyal beklenir.

$shapePrevRow = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK'))

# 4C-a. Durum kolonu YOK: cokmez, tek bir Blocking verir, hukum uydurmaz.
$previous = New-PreviousRun -Rows $shapePrevRow -DropCsvColumns @('Durum')
$shapeComparison = $null
$shapeThrew = $false
$shapeError = ''
try {
    $shapeComparison = Compare-EDRuns -PreviousFolder $previous `
        -CurrentRows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'FAIL')) `
        -Context (New-CompareContext)
}
catch { $shapeThrew = $true; $shapeError = "$_" }
Assert-True 'Durum kolonu olmayan CSV delta motorunu COKERTMEZ' (-not $shapeThrew) $shapeError

if ($null -ne $shapeComparison) {
    $shapeNotes = @(@($shapeComparison.Scope.Blocking) | Where-Object { $_ -like "*'Durum' kolonu YOK*" })
    Assert-Equal 'Bicim uyarisi TEK BIR kez verildi' 1 $shapeNotes.Count
    Assert-True 'Hukum okunamayan kiyas guvenilir SAYILMADI' (-not $shapeComparison.Scope.Comparable) 'blocking var'
    Assert-True 'Sayilarin guvenilmez oldugu yazildi' ((@($shapeNotes) -join ' ') -like '*GUVENILIR DEGILDIR*') `
        (Get-EDDetailSnippet (@($shapeNotes) -join ' '))

    # Eksik hukum 'OK' ya da "degismedi" SAYILMADI: ne sahte bir gerileme
    # ne de sahte bir iyilesme uretildi. (Gercekte OK -> FAIL vardi ama
    # onceki hukum okunamadigi icin bu BILINEMEZ; uydurulmaz.)
    $shapeHighlights = Get-EDDeltaHighlights -Comparison $shapeComparison
    Assert-Equal 'Okunamayan hukumden gerileme uretilmedi' 0 (Get-EDHighlightCount $shapeHighlights 'Regressions')
    Assert-Equal 'Okunamayan hukumden iyilesme uretilmedi' 0 (Get-EDHighlightCount $shapeHighlights 'Improvements')

    # Satir basina TEKRARLAYAN uyari yok: 500 satirin her birinde ayni
    # cumleyi gormek uyariyi okunmaz hale getirirdi.
    $shapeNoteText = @(@($shapeComparison.Deltas) | ForEach-Object { $_.Aciklama }) -join ' '
    Assert-True 'Satir basina tekrarlayan bicim uyarisi yok' ($shapeNoteText -notlike '*kolonu YOK*') 'satirlar temiz'

    $shapePath = Join-Path $script:Root 'DELTA-bicim.html'
    Export-EDDeltaHtml -Comparison $shapeComparison -Path $shapePath -Context (New-CompareContext) | Out-Null
    $shapeHtml = Get-Content $shapePath -Raw -Encoding UTF8
    Assert-True 'Bicim uyarisi raporun EN USTUNDE' ($shapeHtml -like '*KIYAS GUVENILIR DEGIL*') 'blocking blogu basildi'
}
else {
    Assert-True 'Durum kolonu olmadan kiyas kuruldu' $false 'sonuc yok'
}

# 4C-b. Hukum okunamasa da DEGER farklari gecerlidir ve gizlenmez.
$previous = New-PreviousRun -Rows $shapePrevRow -DropCsvColumns @('Durum')
$shapeComparison = Compare-EDRuns -PreviousFolder $previous `
    -CurrentRows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 25 } -Unit 'sn' -Status 'FAIL')) `
    -Context (New-CompareContext)
$valueDeltas = @(@($shapeComparison.Deltas) | Where-Object { $_.Yon -eq 'ARTTI' })
Assert-Equal 'Deger farki yine de raporlandi' 1 $valueDeltas.Count
# Gecis metni uydurulmaz: 'N/A -> FAIL' yazmak, okunamayan hukmu okunmus
# gibi gosterip satiri OLCUM kovasina sokardi.
Assert-Equal 'Okunamayan hukumden gecis metni uydurulmadi' '' (Get-EDFirstField $valueDeltas 'Durum')

# 4C-c. Kaybolan kontrolun okunamayan hukmu bos degil N/A yazilir
# (brief: okunamayan deger 0 ya da bos degil, N/A'dir).
$previous = New-PreviousRun -Rows @(
    New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK'
    New-EDRow -Module 'M12' -Check 'Yogunlasma' -Values @{ MBX1 = 5 } -Status 'FAIL'
) -DropCsvColumns @('Durum')
$shapeComparison = Compare-EDRuns -PreviousFolder $previous `
    -CurrentRows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK')) `
    -Context (New-CompareContext)
$lostRows = @(@($shapeComparison.Deltas) | Where-Object { $_.Yon -eq 'KAYBOLDU' })
Assert-Equal 'Kaybolan kontrolun okunamayan hukmu N/A' 'N/A' (Get-EDFirstField $lostRows 'Onceki')

# 4C-d. ANAHTAR kolon (Modul / Kontrol) yoksa kiyas hic kurulmaz: acik hata.
# Bu ikisi olmadan hicbir satir eslenemez; her kontrol 'YENI' ve karsiligi
# 'KAYBOLDU' gorunurdu - yani tamamen uydurma bir rapor.
foreach ($keyColumn in @('Modul', 'Kontrol')) {
    $previous = New-PreviousRun -Rows $shapePrevRow -DropCsvColumns @($keyColumn)
    $keyThrew = $false
    $keyMessage = ''
    try {
        Compare-EDRuns -PreviousFolder $previous -CurrentRows $shapePrevRow -Context (New-CompareContext) | Out-Null
    }
    catch { $keyThrew = $true; $keyMessage = "$_" }
    Assert-True ("Anahtar kolon '$keyColumn' yoksa acik hata") $keyThrew 'istisna firlatildi'
    Assert-True ("Hata eksik kolonu adlandiriyor ($keyColumn)") ($keyMessage -like "*$keyColumn*") (Get-EDDetailSnippet $keyMessage)
    Assert-True ("Degisim degil DOSYA BICIMI farki dendi ($keyColumn)") ($keyMessage -like '*DOSYA BICIMI*') (Get-EDDetailSnippet $keyMessage)
}

# 4C-e. Satirsiz (bos) bir onceki SUMMARY.csv bicim hatasi DEGILDIR: hicbir
# kontrolu olmayan mesru bir kosum boyle gorunur ve her kontrol 'YENI' olur.
$emptyFolder = Join-Path $script:Root ([guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $emptyFolder -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $emptyFolder 'SUMMARY.csv'), '', (New-Object System.Text.UTF8Encoding($false)))
$emptyThrew = $false
$emptyError = ''
$emptyComparison = $null
try { $emptyComparison = Compare-EDRuns -PreviousFolder $emptyFolder -CurrentRows $shapePrevRow -Context (New-CompareContext) }
catch { $emptyThrew = $true; $emptyError = "$_" }
Assert-True 'Bos onceki CSV bicim hatasi sayilmadi' (-not $emptyThrew) $emptyError
if ($null -ne $emptyComparison) {
    Assert-Equal 'Bos onceki kosumda kontrol YENI gorunur' 'YENI' (Get-EDFirstField @($emptyComparison.Deltas) 'Yon')
}

# ===========================================================================
Write-Host "`n=== 4D. Varlik (olcum anahtari) sutunu TAHMIN EDILMEZ ===" -ForegroundColor Cyan

# Kiyas motoru sunucu sutununu "sabit listede olmamak" ile tanimliyordu:
# CSV'ye eklenen her yeni ust veri sutunu sessizce bir SUNUCU sayiliyordu ve
# onceki kosumda olup simdikinde olmadiginda "bu sunucu simdiki calistirmada
# olculmedi" diyen UYDURMA bir KAYBOLDU deltasi uretiliyordu. Bu teorik
# degildi: rapor katmani gercek bir 'Orgu' sutunu acmaktan bu yuzden
# vazgecmisti.

$columnRow = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK'))
$columnCurrent = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK'))

# 4D-a. Paylasilan ust veri listesindeki bir sutun ('Orgu') VARLIK SAYILMAZ.
$previous = New-PreviousRun -Rows $columnRow -ExtraCsvColumns @{ Orgu = 'P1' }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $columnCurrent -Context (New-CompareContext)
$fabricated = @(@($comparison.Deltas) | Where-Object { $_.Sunucu -eq 'Orgu' })
Assert-Equal "Ust veri sutunundan uydurma varlik deltasi uretilmedi" 0 $fabricated.Count
Assert-Equal 'Ust veri sutunu hic delta uretmedi' 0 @($comparison.Deltas).Count
Assert-True 'Taninan ust veri sutunu icin uyari da cikmaz' `
    ((@($comparison.Scope.Advisory) -join ' ') -notlike '*TANIMSIZ*') (Get-EDDetailSnippet (@($comparison.Scope.Advisory) -join ' '))

# 4D-b. TANIMADIGI bir sutun: ne ust veridir ne de bilinen bir varlik adi.
# Varlik SAYILMAZ (uydurma delta yok) ama SUSULMAZ da.
$previous = New-PreviousRun -Rows $columnRow -ExtraCsvColumns @{ Tuhaf = 'deger' }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $columnCurrent -Context (New-CompareContext)
Assert-Equal 'Tanimsiz sutundan uydurma varlik deltasi uretilmedi' 0 @(@($comparison.Deltas) | Where-Object { $_.Sunucu -eq 'Tuhaf' }).Count
$columnAdvisory = @($comparison.Scope.Advisory) -join ' '
Assert-True 'Tanimsiz sutun ADIYLA bildirildi' ($columnAdvisory -like '*Tuhaf*') (Get-EDDetailSnippet $columnAdvisory)
Assert-True 'Varlik oldugu VARSAYILMADI denildi' ($columnAdvisory -like '*VARSAYILMADI*') (Get-EDDetailSnippet $columnAdvisory)
# Tanimsiz sutun raporlanan hicbir seyi yanlislamaz; kiyas gecerli kalir.
Assert-True 'Tanimsiz sutun kiyasi gecersiz KILMAZ' ($comparison.Scope.Comparable) 'blocking yok'

# 4D-c. run-meta'da servers alani yoksa TAHMINE geri donulmez; siniflamanin
# dogrulanamadigi acikca yazilir.
$previous = New-PreviousRun -Rows $columnRow -ExtraCsvColumns @{ Tuhaf = 'deger' } -OmitMetaFields @('servers')
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $columnCurrent -Context (New-CompareContext)
# Iddia SUTUN notunun kendisine yapilir: meta'nin ayri "servers alani yok"
# uyarisiyla karisirsa test, olcmedigi bir seyi gecmis sayar.
$columnNote = @(@($comparison.Scope.Advisory) | Where-Object { $_ -like '*TANIMSIZ sutun*' }) -join ' '
Assert-True 'Servers yoksa siniflamanin dogrulanamadigi yazildi' ($columnNote -like '*DOGRULANAMADI*') (Get-EDDetailSnippet $columnNote)
Assert-Equal 'Servers yoksa da uydurma varlik deltasi yok' 0 @(@($comparison.Deltas) | Where-Object { $_.Sunucu -eq 'Tuhaf' }).Count

# 4D-d. GERCEK bir sunucunun (varligin) kaybolmasi hala raporlanir - tahmin kaldirilirken
# olculmus bir degerin kaybi da susturulmus olmamali.
$previous = New-PreviousRun -Rows @(
    (New-EDRow -Module 'M14' -Check 'Kuyruk' -Values @{ MBX1 = 10; MBX2 = 999 } -Status 'FAIL')
) -Columns @('MBX1', 'MBX2')
$comparison = Compare-EDRuns -PreviousFolder $previous `
    -CurrentRows @((New-EDRow -Module 'M14' -Check 'Kuyruk' -Values @{ MBX1 = 10 } -Status 'OK')) `
    -Context (New-CompareContext)
Assert-Equal 'Kaybolan GERCEK sunucu hala raporlaniyor' 1 @(@($comparison.Deltas) | Where-Object { $_.Sunucu -eq 'MBX2' }).Count

# 4D-e. SUNUCU ADI TASIMAYAN mesru olcum sutunlari da kiyaslanir.
#
# Rapor satirlarinin anahtari her zaman sunucu DEGILDIR: M12 satirlarini
# DB adiyla (DB01..DB04), M23 de oyle anahtarlar. Bu adlar ne ust veri
# listesinde ne topolojide ne de run-meta.servers icindedir. "Bilinen
# varlik = sunucu" denildiginde bu sutunlar TANIMSIZ'a dusuyor ve olculmus
# gercek bir degisim (ornek raporda M12/DB03: 3 -> 1174, %+39033) delta
# raporundan tamamen dusuyordu - uzerine "YENI sutun" etiketi yaziliyordu.
#
# Kume GOZLEM ile genisletilir: bir ad simdiki kosumun satirlarinda olcum
# anahtari olarak geciyorsa o ad kesinlikle bir varliktir (degeri o anahtara
# yazan aracin kendisidir). Bu tahmin degildir; "listede olmayan her sey
# varliktir" kuralina geri donus de degildir.
$previous = New-PreviousRun -Rows @(
    (New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK')
    (New-EDRow -Module 'M12' -Check 'Yavas teslimlerin DB dagilimi' -Values @{ DB01 = 1; DB03 = 3 } -Status 'OK')
) -Columns @('MBX1', 'DB01', 'DB03') -Meta @{ servers = @('MBX1') }   # meta YALNIZCA sunuculari tasir
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows @(
    (New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK')
    (New-EDRow -Module 'M12' -Check 'Yavas teslimlerin DB dagilimi' -Values @{ DB01 = 1; DB03 = 1174 } -Status 'WARN')
) -Context (New-CompareContext)
$dbDeltas = @(@($comparison.Deltas) | Where-Object { $_.Sunucu -eq 'DB03' })
Assert-Equal 'DB anahtarli sutun icin delta uretildi' 1 $dbDeltas.Count
Assert-Equal 'Onceki DB degeri GERCEKTEN okundu' '3' (Get-EDFirstField $dbDeltas 'Onceki')
Assert-Equal 'DB sutunu YENI sanilmadi, kiyaslandi' 'ARTTI' (Get-EDFirstField $dbDeltas 'Yon')
Assert-True 'DB gerilemesi ozete girdi' (@((Get-EDDeltaHighlights -Comparison $comparison).Regressions).Count -ge 1) 'gerileme goruldu'
Assert-True 'Mesru DB sutunu TANIMSIZ diye disarida birakilmadi' `
    ((@($comparison.Scope.Advisory) -join ' ') -notlike '*DB03*') (Get-EDDetailSnippet (@($comparison.Scope.Advisory) -join ' '))

# 4D-f. Simdiki kosumda HIC gecmeyen bir sutun (orn. kaldirilmis DB) yine
# TANIMSIZ'dir: elimizde onu "yeni surumun ust veri sutunu"ndan ayirt edecek
# kanit yoktur ve ayirt edemedigimiz iki durumdan birini secip satir basina
# KAYBOLDU uretmek uydurma olurdu. Ama not, kaldirilmis varlik okumasini
# acikca soyler - susmak da yanlis olurdu.
$previous = New-PreviousRun -Rows @(
    (New-EDRow -Module 'M12' -Check 'Yavas teslimlerin DB dagilimi' -Values @{ DB01 = 1; DB09 = 500 } -Status 'WARN')
) -Columns @('DB01', 'DB09') -Meta @{ servers = @('MBX1') }
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows @(
    (New-EDRow -Module 'M12' -Check 'Yavas teslimlerin DB dagilimi' -Values @{ DB01 = 1 } -Status 'OK')
) -Context (New-CompareContext)
Assert-Equal 'Kaldirilmis varlik icin uydurma satir uretilmedi' 0 @(@($comparison.Deltas) | Where-Object { $_.Sunucu -eq 'DB09' }).Count
$removedNote = @(@($comparison.Scope.Advisory) | Where-Object { $_ -like '*TANIMSIZ sutun*' }) -join ' '
Assert-True 'Kaldirilmis varlik adiyla bildirildi' ($removedNote -like '*DB09*') (Get-EDDetailSnippet $removedNote)
Assert-True 'Sorun gecti sanilmasin uyarisi var' ($removedNote -like '*anlamina GELMEZ*') (Get-EDDetailSnippet $removedNote)

# 4D-g. YAZAN ile OKUYAN ayni kaynaga bakiyor mu? Export-EDSummaryCsv'nin
# urettigi her baslik ya bir sunucu adi ya da paylasilan ust veri
# listesindedir. Bu iddia, rapor katmani yeni bir sutun ekleyip listeyi
# guncellemedigi gun KALIR - kusur sessizce delta motoruna sizmadan once.
$contractPath = Join-Path $script:Root 'SUMMARY-sozlesme.csv'
Export-EDSummaryCsv -Rows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK')) `
    -Columns @('MBX1') -Path $contractPath | Out-Null
$contractHeaders = @(@(Import-Csv -LiteralPath $contractPath -Encoding UTF8)[0].PSObject.Properties.Name)
$unlisted = @($contractHeaders | Where-Object { $_ -ne 'MBX1' -and $_ -notin $script:EDSummaryMetaColumns })
Assert-Equal 'CSV yazicisinin ust veri sutunlari paylasilan listede' 0 $unlisted.Count
Assert-True "Paylasilan liste 'Orgu' sutununun onunu aciyor" ('Orgu' -in $script:EDSummaryMetaColumns) 'rapor katmani sutunu acabilir'

# 4D-h. Okuyan taraf listeyi KENDI kopyasindan okumasin: tek kaynak kurali
# yorumla degil, kodla korunur.
$compareText = Get-Content -LiteralPath (Join-Path $projectRoot 'Core\Compare.ps1') -Raw -Encoding UTF8
Assert-True 'Compare.ps1 paylasilan listeyi kullaniyor' ($compareText -like '*$script:EDSummaryMetaColumns*') 'referans var'
Assert-True 'Compare.ps1 kendi sutun kopyasini tasimiyor' ($compareText -notlike "*'Modul', 'Kontrol', 'Birim'*") 'yerel kopya yok'

# ===========================================================================
Write-Host "`n=== 5. Yeni / kaybolan kontroller ===" -ForegroundColor Cyan

# 5a. Yeni kontrol "degisim" sayilmaz
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Status 'OK'))
$current = @(
    New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Status 'OK'
    New-EDRow -Module 'M44' -Check 'Deneme suresi' -Values @{ MBX1 = '85 gun' } -Status 'WARN'
)
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$new = @($comparison.Deltas | Where-Object { $_.Yon -eq 'YENI' })
Assert-Equal 'Yeni kontrol isaretlendi' 1 $new.Count
Assert-True 'Degisim olmadigi yazildi' ($new[0].Aciklama -like '*bir degisim DEGILDIR*') $new[0].Aciklama

# 5b. Kaybolan kontrol "sorun gecti" ANLAMINA GELMEZ
$previous = New-PreviousRun -Rows @(
    New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Status 'OK'
    New-EDRow -Module 'M12' -Check 'Yogunlasma' -Values @{ MBX1 = 5 } -Status 'FAIL'
)
$current = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Status 'OK'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$gone = @($comparison.Deltas | Where-Object { $_.Yon -eq 'KAYBOLDU' })
Assert-Equal 'Kaybolan kontrol isaretlendi' 1 $gone.Count
Assert-True 'Sorun gecti sanilmasin' ($gone[0].Aciklama -like '*sorunun gectigi anlamina GELMEZ*') $gone[0].Aciklama

# 5c. Onceki calistirmada olmayan SUTUN (yeni sunucu) kiyasa girmez
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Status 'OK')) -Columns @('MBX1')
$current = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10; MBX2 = 99 } -Status 'OK'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current `
    -Context (New-CompareContext -Servers @((New-EDTestServer -Name 'MBX1'), (New-EDTestServer -Name 'MBX2')))
$newColumn = @($comparison.Deltas | Where-Object { $_.Sunucu -eq 'MBX2' })
Assert-Equal 'Yeni sutun icin kiyas kurulmadi' 1 $newColumn.Count
Assert-True 'Sutun yoktu denildi' ($newColumn[0].Aciklama -like '*kiyas kurulamaz*') $newColumn[0].Aciklama

# 5d. KAYBOLAN SUTUN (5c'nin ayna goruntusu): onceki calistirmada olculmus
# 999 degeri rapordan tamamen dusuyordu. Geriye yalnizca "FAIL -> OK" satiri
# kaliyor ve operator sorunun cozuldugunu saniyordu; oysa sorunlu sunucu
# artik hic olculmuyor.
$previous = New-PreviousRun -Rows @(
    (New-EDRow -Module 'M14' -Check 'Kuyruk' -Values @{ MBX1 = 10; MBX2 = 999 } -Status 'FAIL')
) -Columns @('MBX1', 'MBX2')
$current = @((New-EDRow -Module 'M14' -Check 'Kuyruk' -Values @{ MBX1 = 10 } -Status 'OK'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$lost = @($comparison.Deltas | Where-Object { $_.Sunucu -eq 'MBX2' })
Assert-Equal 'Kaybolan sutun icin satir uretildi' 1 $lost.Count
Assert-Equal 'Onceki deger korundu' '999' (Get-EDFirstField $lost 'Onceki')
Assert-Equal 'Yon KAYBOLDU' 'KAYBOLDU' (Get-EDFirstField $lost 'Yon')
Assert-True 'Sorun gecti sanilmasin' ((Get-EDFirstField $lost 'Aciklama') -like '*anlamina GELMEZ*') (Get-EDFirstField $lost 'Aciklama')

# 5e. Sutunlar TAMAMEN degistiginde (sunucu degisimi) durum gerilemesi yine
# ozete girmelidir. "Yeni sutun" dali Durum'u bos biraktigi icin 900 ms'lik
# gerileme gerileme listesinde hic gorunmuyordu.
$previous = New-PreviousRun -Rows @(
    (New-EDRow -Module 'M20' -Check 'RPC gecikmesi' -Values @{ SRV1 = 12; SRV2 = 14 } -Unit 'ms' -Status 'OK')
) -Columns @('SRV1', 'SRV2')
$current = @((New-EDRow -Module 'M20' -Check 'RPC gecikmesi' -Values @{ SRV3 = 900; SRV4 = 950 } -Unit 'ms' -Status 'FAIL'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current `
    -Context (New-CompareContext -Servers @((New-EDTestServer -Name 'SRV3'), (New-EDTestServer -Name 'SRV4')))
$highlights = Get-EDDeltaHighlights -Comparison $comparison
Assert-Equal 'Sutunlar degisse de gerileme ozete girdi' 1 @($highlights.Regressions).Count
Assert-Equal 'Gecis yazildi' 'OK -> FAIL' (Get-EDFirstField $highlights.Regressions 'Gecis')

# ===========================================================================
Write-Host "`n=== 6. Gerileme / iyilesme ozeti ===" -ForegroundColor Cyan

$previous = New-PreviousRun -Rows @(
    New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Status 'OK'
    New-EDRow -Module 'M14' -Check 'Kuyruk' -Values @{ MBX1 = 5000 } -Status 'FAIL'
    New-EDRow -Module 'M20' -Check 'RPC' -Values @{ MBX1 = 40 } -Status 'OK'
)
$current = @(
    New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 300 } -Status 'FAIL'    # gerileme
    New-EDRow -Module 'M14' -Check 'Kuyruk' -Values @{ MBX1 = 3 } -Status 'OK'     # iyilesme
    New-EDRow -Module 'M20' -Check 'RPC' -Values @{ MBX1 = 42 } -Status 'OK'       # degisim yok
)
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$highlights = Get-EDDeltaHighlights -Comparison $comparison
Assert-Equal 'Bir gerileme' 1 @($highlights.Regressions).Count
Assert-Equal 'Gerileyen modul M10' 'M10' @($highlights.Regressions)[0].Modul
Assert-Equal 'Gecis yazildi' 'OK -> FAIL' @($highlights.Regressions)[0].Gecis
Assert-Equal 'Bir iyilesme' 1 @($highlights.Improvements).Count
Assert-Equal 'Iyilesen modul M14' 'M14' @($highlights.Improvements)[0].Modul

# N/A <-> hukum gecisi UCUNCU bir kovaya girer: ne gerileme ne iyilesme.
#
# DIKKAT: eski test yalnizca "N/A -> OK iyilesme sayilmadi" diyordu ve bu
# iddia, N/A ile OK ayni siraya konuldugu SURECE de geciyordu; yani hatayi
# gormesi yapisal olarak imkansizdi. Sinav ters yonde verilir: FAIL -> N/A.
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M26' -Check 'Indeks' -Values @{ MBX1 = 'N/A' } -Status 'N/A'))
$current = @((New-EDRow -Module 'M26' -Check 'Indeks' -Values @{ MBX1 = 'Healthy' } -Status 'OK'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$highlights = Get-EDDeltaHighlights -Comparison $comparison
Assert-Equal 'N/A -> OK iyilesme sayilmadi' 0 @($highlights.Improvements).Count
Assert-Equal 'N/A -> OK gerileme de sayilmadi' 0 @($highlights.Regressions).Count
Assert-Equal 'N/A -> OK olcum degisimi olarak sayildi' 1 (Get-EDHighlightCount $highlights 'MeasurementChanges')

# FAIL -> N/A OLCUMUN KAYBIDIR, iyilesme DEGILDIR. Eskiden N/A, OK ile ayni
# sirada oldugu icin bu gecis "iyilesme" sayiliyordu; satirin kendi metni
# "iyilesme veya gerileme DEGILDIR" derken baslik 1 iyilesme gosteriyordu.
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M20' -Check 'RPC' -Values @{ MBX1 = 900 } -Unit 'ms' -Status 'FAIL'))
$current = @((New-EDRow -Module 'M20' -Check 'RPC' -Values @{ MBX1 = 'N/A' } -Status 'N/A'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$highlights = Get-EDDeltaHighlights -Comparison $comparison
Assert-Equal 'FAIL -> N/A iyilesme SAYILMADI' 0 @($highlights.Improvements).Count
Assert-Equal 'FAIL -> N/A gerileme de sayilmadi' 0 @($highlights.Regressions).Count
Assert-Equal 'FAIL -> N/A olcum degisimi olarak sayildi' 1 (Get-EDHighlightCount $highlights 'MeasurementChanges')
Assert-Equal 'Satir metni ile baslik ayni seyi soyluyor' 'OLCUM' @($comparison.Deltas)[0].Yon

# ===========================================================================
Write-Host "`n=== 7. Rapor uretimi ===" -ForegroundColor Cyan

$htmlPath = Join-Path $script:Root 'DELTA-test.html'
Export-EDDeltaHtml -Comparison $comparison -Path $htmlPath -Context (New-CompareContext) | Out-Null
Assert-True 'DELTA.html yazildi' (Test-Path $htmlPath)
$html = Get-Content $htmlPath -Raw -Encoding UTF8
Assert-True 'Onceki calistirma kimligi raporda' ($html -like '*onceki*') 'runId gecti'
Assert-True 'Uyari bolumu var' ($html -like '*sebep gostermez*')

# 7b. DUSMESI KOTU olan metrikte AZALDI yesile boyanmaz.
# Bos disk %40 -> %8 bir felakettir; "AZALDI = yesil" kurali her metrigin
# "yuksek kotudur" oldugunu varsayar ve raporu tersine cevirir.
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M21' -Check 'Bos disk' -Values @{ MBX1 = 40 } -Unit '%' -Status 'OK'))
$current = @((New-EDRow -Module 'M21' -Check 'Bos disk' -Values @{ MBX1 = 8 } -Unit '%' -Status 'FAIL'))
$toneComparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$tonePath = Join-Path $script:Root 'DELTA-tone.html'
Export-EDDeltaHtml -Comparison $toneComparison -Path $tonePath -Context (New-CompareContext) | Out-Null
$toneHtml = Get-Content $tonePath -Raw -Encoding UTF8
Assert-True 'Gerileyen AZALDI iyilesme rengi ALMADI' ($toneHtml -notlike '*class="iyi">AZALDI*') 'yesil degil'
Assert-True 'Gerileyen AZALDI gerileme rengi aldi' ($toneHtml -like '*class="kotu">AZALDI*') 'kirmizi'

# 7c. Gercek iyilesmede yesil korunur (gecikme 60 -> 12, WARN -> OK)
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 60 } -Unit 'sn' -Status 'WARN'))
$current = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 12 } -Unit 'sn' -Status 'OK'))
$toneComparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
Export-EDDeltaHtml -Comparison $toneComparison -Path $tonePath -Context (New-CompareContext) | Out-Null
$toneHtml = Get-Content $tonePath -Raw -Encoding UTF8
Assert-True 'Iyilesen AZALDI yesil kaldi' ($toneHtml -like '*class="iyi">AZALDI*') 'yesil'

# 7d. DURUM gecisi yoksa yon RENKLE yorumlanmaz: hangi yonun kotu oldugunu
# bilmiyoruz ve bilmedigimiz seyi renkle uydurmayiz.
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 10 } -Unit 'sn' -Status 'OK'))
$current = @((New-EDRow -Module 'M10' -Check 'p95' -Values @{ MBX1 = 25 } -Unit 'sn' -Status 'OK'))
$toneComparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
Export-EDDeltaHtml -Comparison $toneComparison -Path $tonePath -Context (New-CompareContext) | Out-Null
$toneHtml = Get-Content $tonePath -Raw -Encoding UTF8
Assert-True 'Durumsuz ARTTI notr birakildi' ($toneHtml -like '*class="notr">ARTTI*') 'notr'

# Blocking uyarisi raporun ustunde gorunmeli
$previous = New-PreviousRun -Rows $rows -Meta @{ windowHours = 1 }
$blockedComparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $rows -Context (New-CompareContext -WindowHours 24)
$blockedPath = Join-Path $script:Root 'DELTA-blocked.html'
Export-EDDeltaHtml -Comparison $blockedComparison -Path $blockedPath -Context (New-CompareContext -WindowHours 24) | Out-Null
$blockedHtml = Get-Content $blockedPath -Raw -Encoding UTF8
Assert-True 'Kapsam uyarisi raporda' ($blockedHtml -like '*KIYAS GUVENILIR DEGIL*') 'blocking blogu basildi'

# Olmayan klasor temiz hata verir
$threw = $false
try { Compare-EDRuns -PreviousFolder (Join-Path $script:Root 'yok-boyle-bir-sey') -CurrentRows $rows -Context (New-CompareContext) | Out-Null }
catch { $threw = $true }
Assert-True 'Olmayan klasor icin acik hata' $threw

# ===========================================================================
Write-EDTestSummary
Remove-Item -Path $script:Root -Recurse -Force -ErrorAction SilentlyContinue
if (Get-EDTestFailed -gt 0) { exit 1 }
