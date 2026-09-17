<#
    SALT OKUNURLUK DENETIMININ KENDI TESTI.

    NEDEN BU PAKET VAR
    Assert-ReadOnly.ps1 aracin tek mutlak vaadini (ortami DEGISTIRMEMEK)
    koruyan tek otomatik guvencedir. Ama denetimin KENDISI test edilmemisti:
    depoya dusmanca bir modul birakilip denetim calistirildiginda, yaklasik
    yirmi ayri yazma yolundan yalnizca ikisi yakalaniyordu. Geri kalani
    SESSIZCE geciyordu - ve bir denetim betiginin sessizligi, temizlikten
    ayirt edilemez oldugu icin en kotu basarisizlik bicimidir.

    Bu paket, denetimi GERCEK bir dusman deposuna karsi calistirir. Fixture'lar
    $env:TEMP altinda uretilir; DEPO ICINE hicbir sey yazilmaz - zaten denetimin
    kendisi Tests\ klasorunu taramaz, dolayisiyla fixture'i depo icinde tutmak
    testi anlamsiz kilardi.

    Her iddia bir KACIS YOLUNA karsilik gelir. Bir iddia kirmizi olursa, o kacis
    yolu yeniden acilmis demektir.
#>
[CmdletBinding()]
param(
    [string]$FixtureDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'EDTestHelpers.ps1')

$lintPath = Join-Path $PSScriptRoot 'Assert-ReadOnly.ps1'

if (-not $FixtureDir) { $FixtureDir = Join-Path $env:TEMP 'ed-readonly-lint' }
if (Test-Path -LiteralPath $FixtureDir) { Remove-Item -LiteralPath $FixtureDir -Recurse -Force }
New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null

function New-EDLintFixtureFile {
    <#
        Dusman depoya bir dosya birakir. Yol GORECELIDIR (orn. 'Modules\M90.ps1')
        boylece alt klasor / .psm1 taramasi da sinanabilir.
    #>
    param([string]$RelativePath, [string]$Content)

    $full = Join-Path $FixtureDir $RelativePath
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $full -Value $Content -Encoding ASCII
}

function Get-EDLintFindings {
    <#
        Denetimi dusman depoya karsi calistirir ve bulgulari nesne olarak alir.
        AYRI SUREC KULLANILMAZ: denetim -AsObject ile cikis kodu uretmeden
        doner, boylece bulgular dogrudan iddia edilebilir.
    #>
    param([string]$Root)
    return (& $lintPath -Root $Root -AsObject)
}

function Test-EDFinding {
    <#
        Bulgu kumesinde, verilen olculere uyan en az bir kayit var mi?
        Kind/Command/Detail bos birakilabilir - o alan aranmaz.
    #>
    param($Findings, [string]$Kind, [string]$Command, [string]$DetailLike, [string]$FileLike)

    foreach ($finding in @($Findings)) {
        if ($Kind       -and $finding.Tur   -ne $Kind)          { continue }
        if ($Command    -and $finding.Komut -ne $Command)       { continue }
        if ($DetailLike -and $finding.Detay -notlike $DetailLike) { continue }
        if ($FileLike   -and $finding.Dosya -notlike $FileLike) { continue }
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# Dusman depo: her dosya, daha once SESSIZCE gecen bir kacis yoludur.
# ---------------------------------------------------------------------------

# 1. Splat: -Command parametresi CommandParameterAst degil, hashtable icinde.
#    Eski denetim hicbir sey KAYDETMIYOR ve hicbir ihlal URETMIYORDU; modul
#    Exchange'e Remove-Mailbox gonderse denetim izinde tek satir bile olmazdi.
New-EDLintFixtureFile 'Modules\M90-Splat.ps1' @'
$splat = @{ Key = 'evil'; Command = 'Remove-Mailbox' }
New-EDExchangeTask @splat
'@

# 2. Iki nokta bicimi: deger CommandParameterAst.Argument icindedir.
#    Eski denetim yalnizca $elements[$i+1]'e bakiyordu; bulgu uretiyordu ama
#    YANLIS gerekceyle ("ad sabit degil") ve cmdlet adini HIC kaydetmiyordu.
New-EDLintFixtureFile 'Modules\M91-Colon.ps1' @'
New-EDExchangeTask -Key 'evil' -Command:'Set-TransportService'
'@

# 3. Search / Test fiilleri degistirici sayilmiyordu.
#    Search-Mailbox -DeleteContent postayi KALICI siler.
#    Test-Mailflow GERCEK bir sonda iletisi gonderir.
New-EDLintFixtureFile 'Modules\M92-Verbless.ps1' @'
New-EDExchangeTask -Key 'evil' -Command 'Search-Mailbox' -Parameters @{ DeleteContent = $true }
New-EDExchangeTask -Key 'evil2' -Command 'Test-Mailflow'
'@

# 4. .NET uye cagrilari: eski ziyaretci yalnizca CommandAst topluyordu,
#    InvokeMemberExpressionAst'e hic girmiyordu. New-Object izinli oldugu icin
#    StreamWriter uretip .WriteLine() ile yazmak tamamen mesru gorunuyordu.
New-EDLintFixtureFile 'Modules\M93-Members.ps1' @'
function Invoke-EvilMembers {
    param($Service, $Proc, $Writer)
    [System.IO.File]::WriteAllText('C:\Windows\Temp\x.txt', 'x')
    $Service.StopService()
    $Proc.Kill()
    $Writer.WriteLine('x')
    $w = New-Object System.IO.StreamWriter('C:\Windows\Temp\y.txt')
    return $w
}
'@

# 5. Dinamik gonderim: GetCommandName() $null doner, eski kod SESSIZCE
#    continue ederdi. Denetimin sessizligi temizlikten ayirt edilemezdi.
New-EDLintFixtureFile 'Modules\M94-Dynamic.ps1' @'
$cmd = 'Set-Mailbox'
& $cmd -Identity 'kurban@test.local'
'@

# 6. Kisayollar: fiil kontrolu '-' karakterine bolunerek yapiliyordu,
#    kisayolda '-' olmadigi icin hicbiri denetlenmiyordu.
New-EDLintFixtureFile 'Modules\M95-Alias.ps1' @'
iex 'Set-Mailbox -Identity kurban'
del 'C:\Windows\System32\drivers\etc\hosts'
rmdir 'C:\Program Files\Microsoft\Exchange Server'
'@

# 7. Eksik degistirici fiiller. Limit-EventLog uretim olay gunlugunu YENIDEN
#    BOYUTLANDIRIR; Write-EventLog uretim gunlugune kayit yazar.
New-EDLintFixtureFile 'Modules\M96-Verbs.ps1' @'
Limit-EventLog -LogName Application -MaximumSize 1MB
Write-EventLog -LogName Application -Source 'x' -EventId 1 -Message 'm'
Copy-Item -Path 'a' -Destination 'b'
Restore-Computer -RestorePoint 1
Backup-SqlDatabase -Database 'x'
Format-Volume -DriveLetter D
Initialize-Disk -Number 1
Optimize-Volume -DriveLetter D
Publish-Module -Name 'x'
Grant-SmbShareAccess -Name 'x' -AccountName 'y'
Revoke-SmbShareAccess -Name 'x' -AccountName 'y'
Compress-Archive -Path 'a' -DestinationPath 'b'
Merge-CIPolicy -OutputFilePath 'a'
Save-Module -Name 'x'
Submit-CertificateRequest -Path 'a'
'@

# 8. Izin listesi KOMUT duzeyindeydi ve YOL KISITI YOKTU; oysa gerekcelerin
#    hepsi "kendi cikti dosyasi" diyor.
New-EDLintFixtureFile 'Modules\M97-Path.ps1' @'
Set-Content -Path 'C:\Windows\System32\drivers\etc\hosts' -Value '10.0.0.1 exchange'
Add-Content 'C:\inetpub\wwwroot\index.html' 'x'
'@

# 9. Tarama -Recurse'suz ve yalnizca *.ps1 idi: alt klasor, .psm1 ve Config\
#    hic goruntulenmiyordu.
New-EDLintFixtureFile 'Modules\sub\M98-Nested.ps1' @'
New-EDExchangeTask -Key 'evil' -Command 'Remove-Mailbox'
'@
New-EDLintFixtureFile 'Modules\M98-Hidden.psm1' @'
New-EDExchangeTask -Key 'evil' -Command 'Disable-Mailbox'
'@
New-EDLintFixtureFile 'Config\Bootstrap.ps1' @'
New-EDExchangeTask -Key 'evil' -Command 'Set-Mailbox'
'@

# 10. Invoke-Command "tasiyici" muafiyeti yalnizca INLINE blok icin dogruydu.
#     Degiskenden gelen scriptblock AST'ye hic girmez.
New-EDLintFixtureFile 'Modules\M99-Carrier.ps1' @'
$payload = [scriptblock]::Create('Dismount-Database DB01 -Confirm:$false')
Invoke-Command -ComputerName 'EXC01' -ScriptBlock $payload
'@

# 11. Mimari kural: modul kendi oturumunu/paralelligini yonetemez.
New-EDLintFixtureFile 'Modules\M9A-Arch.ps1' @'
$session = New-PSSession -ComputerName 'EXC01'
Start-Job -ScriptBlock { Get-Date }
'@

# ---------------------------------------------------------------------------
$findings = @(Get-EDLintFindings -Root $FixtureDir)

Write-Host "`n=== Dusman depo: $($findings.Count) bulgu ===" -ForegroundColor Cyan
foreach ($finding in ($findings | Sort-Object Dosya, Satir)) {
    Write-Host ("    {0,-26} {1,4}  {2,-14} {3}" -f $finding.Dosya, $finding.Satir, $finding.Tur, $finding.Komut) -ForegroundColor DarkGray
}

Write-Host "`n=== 1. Splat ile gizlenen Exchange komutu ===" -ForegroundColor Cyan
Assert-True 'Splat edilmis New-EDExchangeTask bulgu uretiyor' `
    (Test-EDFinding -Findings $findings -FileLike '*M90-Splat.ps1' -Command 'New-EDExchangeTask') `
    'hashtable icindeki -Command denetlenemez'

Write-Host "`n=== 2. -Command:'...' (iki nokta) bicimi ===" -ForegroundColor Cyan
Assert-True 'Iki nokta bicimindeki cmdlet adi cozuluyor' `
    (Test-EDFinding -Findings $findings -Kind 'EXCHANGE' -Command 'Set-TransportService') `
    'CommandParameterAst.Argument okunuyor'

Write-Host "`n=== 3. Fiilsiz yikicilar: Search-Mailbox / Test-Mailflow ===" -ForegroundColor Cyan
Assert-True 'Search-Mailbox yakalaniyor' `
    (Test-EDFinding -Findings $findings -Kind 'EXCHANGE' -Command 'Search-Mailbox') `
    '-DeleteContent postayi kalici siler'
Assert-True 'Test-Mailflow yakalaniyor' `
    (Test-EDFinding -Findings $findings -Kind 'EXCHANGE' -Command 'Test-Mailflow') `
    'gercek sonda iletisi gonderir'

Write-Host "`n=== 4. .NET uye cagrilari ===" -ForegroundColor Cyan
Assert-True '[System.IO.File]::WriteAllText yakalaniyor' `
    (Test-EDFinding -Findings $findings -Command 'System.IO.File::WriteAllText' -FileLike '*M93-Members.ps1')
Assert-True '$service.StopService() yakalaniyor' `
    (Test-EDFinding -Findings $findings -Command 'StopService')
Assert-True '$proc.Kill() yakalaniyor' `
    (Test-EDFinding -Findings $findings -Command 'Kill')
Assert-True '$writer.WriteLine() yakalaniyor' `
    (Test-EDFinding -Findings $findings -Command 'WriteLine')
Assert-True 'New-Object System.IO.StreamWriter yakalaniyor' `
    (Test-EDFinding -Findings $findings -Kind 'NESNE' -Command 'System.IO.StreamWriter')

Write-Host "`n=== 5. Dinamik gonderim sessiz gecmiyor ===" -ForegroundColor Cyan
Assert-True '& $cmd bulgu uretiyor' `
    (Test-EDFinding -Findings $findings -Kind 'DOGRULANAMAZ' -FileLike '*M94-Dynamic.ps1') `
    'komut adi calisma aninda belirleniyor'

Write-Host "`n=== 6. Kisayollar ===" -ForegroundColor Cyan
Assert-True 'iex cozuluyor' `
    (Test-EDFinding -Findings $findings -Command 'Invoke-Expression')
Assert-True 'del mutlak yola yaziyor' `
    (Test-EDFinding -Findings $findings -Kind 'YOL' -FileLike '*M95-Alias.ps1')
Assert-True 'rmdir cozuluyor' `
    (Test-EDFinding -Findings $findings -FileLike '*M95-Alias.ps1' -DetailLike '*rmdir*')

Write-Host "`n=== 7. Eksik degistirici fiiller ===" -ForegroundColor Cyan
foreach ($evil in @('Limit-EventLog', 'Write-EventLog', 'Copy-Item', 'Restore-Computer',
                    'Backup-SqlDatabase', 'Format-Volume', 'Initialize-Disk', 'Optimize-Volume',
                    'Publish-Module', 'Grant-SmbShareAccess', 'Revoke-SmbShareAccess',
                    'Compress-Archive', 'Merge-CIPolicy', 'Save-Module', 'Submit-CertificateRequest')) {
    Assert-True "$evil degistirici sayiliyor" (Test-EDFinding -Findings $findings -Command $evil)
}

Write-Host "`n=== 8. Izin listesinin yol kisiti ===" -ForegroundColor Cyan
Assert-True 'Set-Content mutlak sistem yoluna yazamiyor' `
    (Test-EDFinding -Findings $findings -Kind 'YOL' -Command 'Set-Content')
Assert-True 'Add-Content konumsal mutlak yol da yakalaniyor' `
    (Test-EDFinding -Findings $findings -Kind 'YOL' -Command 'Add-Content')

Write-Host "`n=== 9. Tarama kapsami ===" -ForegroundColor Cyan
Assert-True 'Alt klasordeki modul taraniyor' `
    (Test-EDFinding -Findings $findings -FileLike '*M98-Nested.ps1' -Command 'Remove-Mailbox')
Assert-True '.psm1 taraniyor' `
    (Test-EDFinding -Findings $findings -FileLike '*M98-Hidden.psm1' -Command 'Disable-Mailbox')
Assert-True 'Config\ altindaki betik taraniyor' `
    (Test-EDFinding -Findings $findings -FileLike '*Bootstrap.ps1' -Command 'Set-Mailbox')

Write-Host "`n=== 10. Invoke-Command tasiyici muafiyeti daraltildi ===" -ForegroundColor Cyan
Assert-True 'Inline olmayan -ScriptBlock bulgu uretiyor' `
    (Test-EDFinding -Findings $findings -Kind 'DOGRULANAMAZ' -Command 'Invoke-Command')
Assert-True '[scriptblock]::Create yakalaniyor' `
    (Test-EDFinding -Findings $findings -Command 'scriptblock::Create')

Write-Host "`n=== 11. Mimari kural ===" -ForegroundColor Cyan
Assert-True 'New-PSSession mimari ihlali' (Test-EDFinding -Findings $findings -Kind 'MIMARI' -Command 'New-PSSession')
Assert-True 'Start-Job mimari ihlali' (Test-EDFinding -Findings $findings -Kind 'MIMARI' -Command 'Start-Job')

# ---------------------------------------------------------------------------
# EN ONEMLI IDDIA: sikilastirma mesru kullanimlari bozmadi.
# Denetim yanlis alarm uretmeye baslarsa susturulur; susturulan denetim yoktur.
Write-Host "`n=== 12. Gercek depo hala temiz ===" -ForegroundColor Cyan
$realFindings = @(Get-EDLintFindings -Root $projectRoot)
Assert-True 'Gercek depoda ihlal yok' ($realFindings.Count -eq 0) `
    (($realFindings | ForEach-Object { "{0}:{1} {2} {3}" -f $_.Dosya, $_.Satir, $_.Tur, $_.Komut }) -join ' | ')

Write-Host "`n=== Sonuc ===" -ForegroundColor Cyan
Write-Host ("  Gecen: {0}   Kalan: {1}" -f (Get-EDTestPassed), (Get-EDTestFailed)) `
    -ForegroundColor $(if ((Get-EDTestFailed) -eq 0) { 'Green' } else { 'Red' })

if ((Get-EDTestFailed) -gt 0) { exit 1 }
exit 0
