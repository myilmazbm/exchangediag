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
        [switch]$NoMeta
    )

    $folder = Join-Path $script:Root ([guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    Export-EDSummaryCsv -Rows $Rows -Columns $Columns -Path (Join-Path $folder 'SUMMARY.csv') | Out-Null

    if (-not $NoMeta) {
        $defaults = [ordered]@{
            runId = 'onceki'; startedLocal = '2026-09-17 03:00:00'; startedHour = 3
            utcOffsetHours = 3; windowHours = 1; heavy = $true; logAccess = 'smb'
            serverFilter = @(); servers = @('MBX1'); profile = 'production'; modules = @('M10')
        }
        foreach ($key in $Meta.Keys) { $defaults[$key] = $Meta[$key] }
        $json = ([pscustomobject]$defaults) | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText((Join-Path $folder 'run-meta.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $folder
}

function New-CompareContext {
    param([int]$Hour = 3, [double]$WindowHours = 1, [bool]$Heavy = $true, [string]$LogAccess = 'smb', $Servers = $null)
    if ($null -eq $Servers) { $Servers = @((New-EDTestServer -Name 'MBX1')) }
    $context = New-EDTestContext -Config $config -Executor $null -Servers $Servers `
        -Sites @([pscustomobject]@{ Name = 'Site1' }) -OutputDir $script:Root
    $context.WindowHours = $WindowHours
    $context.Heavy = $Heavy
    $context.LogAccess = $LogAccess
    $context.StartTime = (Get-Date).Date.AddHours($Hour)
    $context.RunId = 'simdiki'
    return $context
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

# N/A -> OK gerileme veya iyilesme SAYILMAZ (ikisi de "hukum yok" tarafinda)
$previous = New-PreviousRun -Rows @((New-EDRow -Module 'M26' -Check 'Indeks' -Values @{ MBX1 = 'N/A' } -Status 'N/A'))
$current = @((New-EDRow -Module 'M26' -Check 'Indeks' -Values @{ MBX1 = 'Healthy' } -Status 'OK'))
$comparison = Compare-EDRuns -PreviousFolder $previous -CurrentRows $current -Context (New-CompareContext)
$highlights = Get-EDDeltaHighlights -Comparison $comparison
Assert-Equal 'N/A -> OK iyilesme sayilmadi' 0 @($highlights.Improvements).Count
Assert-Equal 'N/A -> OK gerileme de sayilmadi' 0 @($highlights.Regressions).Count

# ===========================================================================
Write-Host "`n=== 7. Rapor uretimi ===" -ForegroundColor Cyan

$htmlPath = Join-Path $script:Root 'DELTA-test.html'
Export-EDDeltaHtml -Comparison $comparison -Path $htmlPath -Context (New-CompareContext) | Out-Null
Assert-True 'DELTA.html yazildi' (Test-Path $htmlPath)
$html = Get-Content $htmlPath -Raw -Encoding UTF8
Assert-True 'Onceki calistirma kimligi raporda' ($html -like '*onceki*') 'runId gecti'
Assert-True 'Uyari bolumu var' ($html -like '*sebep gostermez*')

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
