<#
    Tum test paketlerini KULTUR BASINA calistirir.

    NEDEN: Bu arac Turkce Exchange ortamlari icin yazildi, ama testler
    gelistiricinin makinesinde (cogunlukla en-US) kosuyordu. .NET'in
    sayi/tarih ayristirmasi kulture duyarlidir ve PowerShell sayilari
    HER ZAMAN invariant bicimde string'e cevirir; ikisi karsilastiginda
    tr-TR'de "0.07" degeri 7 olarak okunur. Bu, her esik hukmunu 100 kat
    kaydiran sessiz bir hataydi ve tek bir test bile kirmizi olmuyordu.

    Bu yuzden gecmek YETMEZ: ayni paketler ikinci kez tr-TR altinda da
    gecmelidir. Bir iddia yalnizca tek kulturde geciyorsa ya urun kulture
    bagimlidir (hata) ya da iddianin kendisi gelistiricinin ondalik ayracini
    varsayiyordur (test hatasi). Ikisi de duzeltilmelidir.

    Kullanim:
        .\Tests\Invoke-EDTests.ps1
        .\Tests\Invoke-EDTests.ps1 -Culture en-US,tr-TR,de-DE
        .\Tests\Invoke-EDTests.ps1 -Name Test-CompareEngine.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Culture = @('en-US', 'tr-TR'),
    [string[]]$Name,
    # HER KOSUM KENDI KLASORUNU KULLANIR.
    #
    # Sabit bir yol iki esZAMANLI kosumu birbirine karistirir ve sonuc
    # SESSIZCE yanlis olur: fixture uretici dosyalari klasore EKLER,
    # ayristirici da klasordeki TUM MSGTRK* dosyalarini tarar. Olculdu -
    # iki kosum ayni anda calisirken "gecikmesi hesaplanan kayit" 189.827
    # yerine 204.920 cikti, yani test kendi fixture'inin disindaki veriyi
    # sayip kirmiziya dustu. Yanlis sebepten KALAN bir test, yanlis
    # sebepten GECEN kadar zararlidir.
    [string]$FixtureRoot = (Join-Path $env:TEMP ('ed-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
)

$ErrorActionPreference = 'Stop'
$testRoot = $PSScriptRoot

$suites = @(Get-ChildItem -LiteralPath $testRoot -Filter 'Test-*.ps1' -File | Sort-Object Name)
if ($Name) { $suites = @($suites | Where-Object { $_.Name -in $Name }) }
if ($suites.Count -eq 0) { throw "Calistirilacak paket bulunamadi." }

if (-not (Test-Path -LiteralPath $FixtureRoot)) {
    New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
}

$results = @()
foreach ($cultureName in $Culture) {
    foreach ($suite in $suites) {
        # Kultur ALT SUREC'te ayarlanir: ayni oturumda degistirmek, daha once
        # yuklenmis tipleri ve bicimlendiricileri yarim yamalak birakir.
        $arguments = @{ Path = $suite.FullName }
        $command = @"
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('$cultureName')
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::GetCultureInfo('$cultureName')
& '$($suite.FullName)' @args
"@
        # Fixture'lari destekleyen paketlere gecici klasor verilir; hicbir paket
        # depo icine yazmamalidir.
        $suiteArgs = @()
        $parameters = (Get-Command -Name $suite.FullName).Parameters
        if ($parameters.ContainsKey('FixtureDir')) {
            $suiteArgs += @('-FixtureDir', (Join-Path $FixtureRoot ($suite.BaseName + '-' + $cultureName)))
        }

        $output = & powershell.exe -NoProfile -Command $command @suiteArgs *>&1 | Out-String -Width 250
        $match = [regex]::Match($output, 'Gecen:\s*(\d+)\s+Kalan:\s*(\d+)')
        $failures = @([regex]::Matches($output, '\[KALDI\][^\r\n]*') | ForEach-Object { $_.Value.Trim() })

        if ($match.Success) {
            $passed = [int]$match.Groups[1].Value
            $failed = [int]$match.Groups[2].Value
        }
        else {
            # Sonuc satiri yoksa paket cokmustur; bunu "0 hata" saymak en kotu yalan olur.
            $passed = 0
            $failed = -1
        }

        $results += [pscustomobject]@{
            Kultur   = $cultureName
            Paket    = $suite.Name
            Gecen    = $passed
            Kalan    = $failed
            Hatalar  = $failures
            Cikti    = $output
        }
    }
}

Write-Host ''
Write-Host '=== Kultur basina sonuc ===' -ForegroundColor Cyan
foreach ($result in $results) {
    $state = if ($result.Kalan -lt 0) { 'COKTU' } elseif ($result.Kalan -eq 0) { 'gecti' } else { "KALDI ($($result.Kalan))" }
    $color = if ($result.Kalan -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-8} {1,-30} {2,-14} gecen={3}" -f $result.Kultur, $result.Paket, $state, $result.Gecen) -ForegroundColor $color
    foreach ($failure in ($result.Hatalar | Select-Object -First 6)) {
        Write-Host ("      " + $failure) -ForegroundColor Red
    }
    if ($result.Kalan -lt 0) {
        Write-Host ("      son cikti: " + (($result.Cikti -split "`n" | Select-Object -Last 3) -join ' | ').Trim()) -ForegroundColor Red
    }
}

# Kendi klasorunu temizler; $env:TEMP birikmemeli.
if (Test-Path -LiteralPath $FixtureRoot) {
    Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$totalPassed = ($results | Measure-Object -Property Gecen -Sum).Sum
$broken = @($results | Where-Object { $_.Kalan -ne 0 })

Write-Host ''
Write-Host ("Toplam gecen: {0}   Sorunlu paket/kultur: {1}" -f $totalPassed, $broken.Count) `
    -ForegroundColor $(if ($broken.Count -eq 0) { 'Green' } else { 'Red' })

if ($broken.Count -gt 0) { exit 1 }
exit 0
