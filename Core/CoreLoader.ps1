<#
    ExchangeDiag - Core yukleyici

    Core\*.cs kaynaklarini calisma aninda derler ve oturuma yukler.

    Teslimat .ps1 dosyalaridir; imzasiz .exe tasinmaz, tum kaynak okunabilir.
    Derleme maliyeti yalnizca ilk calistirmada odenir: kaynaklarin SHA256'si
    ile adlandirilmis assembly cache'lenir, sonraki calistirmalar dogrudan
    yukler.

    DIL KISITI: Add-Type, Windows PowerShell 5.1'de .NET Framework'un
    csc.exe'sini kullanir -> C# 5. Kaynaklarda string interpolation, ?.,
    nameof, tuple, pattern matching KULLANILAMAZ.
    Tests\ExchangeDiag.Core.Tests.csproj bu kisiti <LangVersion>5</LangVersion>
    ile derleme aninda dogrular.
#>

# NOT: Set-StrictMode burada BILEREK cagrilmaz. Bu dosya dot-source edilir;
# strict mode'u burada acmak cagiranin oturumunu da degistirir. Strict mode
# yalnizca giris noktasinda (Invoke-ExchangeDiag.ps1) acilir.

# Yuklendigini anlamak icin bakilan tip. Yeni bir cekirdek sinifi eklenirse
# bu isim degismez; cache anahtari kaynak hash'inden gelir.
$script:CoreMarkerType = 'ExchangeDiag.ParallelExecutor'

function Get-ExchangeDiagCoreSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CoreRoot)

    $files = @(Get-ChildItem -LiteralPath $CoreRoot -Filter '*.cs' -File | Sort-Object Name)
    if ($files.Count -eq 0) {
        throw "Core kaynak dosyasi bulunamadi: $CoreRoot\*.cs"
    }
    return $files
}

function Get-ExchangeDiagCoreHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.IO.FileInfo[]]$SourceFiles)

    # Hash'e dosya adi da girer; bir dosyanin silinmesi de cache'i gecersiz kilar.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $buffer = New-Object System.IO.MemoryStream
        foreach ($file in $SourceFiles) {
            $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($file.Name + "`0")
            $buffer.Write($nameBytes, 0, $nameBytes.Length)
            $content = [System.IO.File]::ReadAllBytes($file.FullName)
            $buffer.Write($content, 0, $content.Length)
        }
        $bytes = $sha.ComputeHash($buffer.ToArray())
        $buffer.Dispose()
        return -join ($bytes | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

function Initialize-ExchangeDiagCore {
<#
    .SYNOPSIS
        C# cekirdegi derler/yukler. Idempotent - ayni oturumda tekrar cagrilabilir.

    .OUTPUTS
        Yukleme hakkinda bilgi veren PSCustomObject (kaynak, sure, cache yolu).
#>
    [CmdletBinding()]
    param(
        [string]$CoreRoot = $PSScriptRoot,
        [switch]$Force
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not $Force -and ($script:CoreMarkerType -as [type])) {
        $watch.Stop()
        return [pscustomobject]@{
            Source     = 'already-loaded'
            CachePath  = $null
            DurationMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 1)
        }
    }

    $files = Get-ExchangeDiagCoreSource -CoreRoot $CoreRoot
    $hash  = Get-ExchangeDiagCoreHash -SourceFiles $files
    $paths = @($files | ForEach-Object { $_.FullName })

    $references = @(
        [psobject].Assembly.Location          # System.Management.Automation.dll
        'System.dll'
        'System.Core.dll'
    )

    $cacheDir  = Join-Path $env:LOCALAPPDATA 'ExchangeDiag\cache'
    $cacheFile = Join-Path $cacheDir "$hash.dll"

    # 1) Cache'te hazir assembly var mi?
    if (-not $Force -and (Test-Path -LiteralPath $cacheFile)) {
        try {
            Add-Type -Path $cacheFile -ErrorAction Stop
            $watch.Stop()
            return [pscustomobject]@{
                Source     = 'cache'
                CachePath  = $cacheFile
                DurationMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 1)
            }
        }
        catch {
            Write-Verbose "Cache'lenmis assembly yuklenemedi, yeniden derlenecek: $($_.Exception.Message)"
        }
    }

    # 2) Derleyip cache'le.
    try {
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction Stop | Out-Null
        }
        Add-Type -Path $paths -ReferencedAssemblies $references -OutputAssembly $cacheFile -ErrorAction Stop
        Add-Type -Path $cacheFile -ErrorAction Stop
        $watch.Stop()
        return [pscustomobject]@{
            Source     = 'compiled'
            CachePath  = $cacheFile
            DurationMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 1)
        }
    }
    catch {
        $cacheError = $_.Exception.Message
        Write-Verbose "Cache'e derleme basarisiz ($cacheError). Bellek ici derlemeye dusuluyor."
    }

    # 3) Cache dizinine yazilamiyorsa (AppLocker / kisitli ortam) bellek icinde derle.
    Add-Type -Path $paths -ReferencedAssemblies $references -ErrorAction Stop
    $watch.Stop()
    return [pscustomobject]@{
        Source     = 'in-memory'
        CachePath  = $null
        DurationMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 1)
    }
}

function Clear-ExchangeDiagCoreCache {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $cacheDir = Join-Path $env:LOCALAPPDATA 'ExchangeDiag\cache'
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        Write-Verbose "Cache dizini yok: $cacheDir"
        return
    }
    if ($PSCmdlet.ShouldProcess($cacheDir, 'Cache temizle')) {
        Get-ChildItem -LiteralPath $cacheDir -Filter '*.dll' -File | Remove-Item -Force
    }
}
