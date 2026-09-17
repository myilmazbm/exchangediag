<#
    SALT OKUNURLUK DENETIMI - brief ilke 1'in otomatik guvencesi.

    Bu aracin tek mutlak vaadi ortami DEGISTIRMEMESIDIR. Bir kod incelemesi
    bunu gozden kacirabilir; bu betik kacirmaz.

    NEDEN AST, NEDEN GREP DEGIL:
    M32 duzeltme komutunu METIN olarak raporlar:

        'Move-ActiveMailboxDatabase <DB> -ActivateOnServer <sunucu>'

    Duz metin aramasi bunu ihlal sanar ve her calistirmada yanlis alarm
    uretir. AST ise metin sabitini komut cagrisindan ayirir: yalnizca
    GERCEKTEN CAGRILAN komutlar denetlenir.

    UC AYRI SEY DENETLENIR:

      1. Cagrilan PowerShell komutlari. Uzak sunucuya gonderilen inline
         scriptblock'lar da AST'ye girdigi icin onlar da taranir.
      2. New-EDExchangeTask -Command '<ad>' ile Exchange'e GONDERILEN cmdlet
         adlari. Asil risk buradadir: modul kendi icinde masum gorunup
         uzak uca 'Set-...' gonderebilir.
      3. Brief'in mimari kurali: moduller kendileri baglanti/paralellik
         yonetmez, yurutucuye devreder.

    Cikis kodu: 0 temiz, 1 ihlal var.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot

# Ortami degistirebilecek fiiller. Exchange kanalinda bunlardan biri
# calistirilirsa arac artik salt okunur degildir.
$script:MutatingVerbs = @(
    'Set', 'New', 'Remove', 'Add', 'Clear', 'Enable', 'Disable',
    'Start', 'Stop', 'Restart', 'Suspend', 'Resume', 'Move',
    'Mount', 'Dismount', 'Update', 'Install', 'Uninstall',
    'Register', 'Unregister', 'Rename', 'Reset', 'Repair',
    'Invoke', 'Send', 'Export', 'Import'
)

# Yerel ve zararsiz kullanimlar. Her biri GEREKCESIYLE burada durur;
# gerekcesiz ekleme yapilmamalidir - bu liste denetimin kendisidir.
$script:AllowedCommands = @{
    # Bellekte nesne/veri olusturma - ortama dokunmaz
    'New-Object'         = 'Bellekte .NET nesnesi'
    'New-TimeSpan'       = 'Hesaplama'
    'New-Guid'           = 'Kimlik uretimi'
    'New-Variable'       = 'Yerel degisken'
    'Add-Member'         = 'Bellekteki nesneye uye ekler'
    'Add-Type'           = 'C# cekirdegin derlenmesi'

    # Aracin kendi yardimcilari - hepsi salt okunur
    'New-EDRow'          = 'Rapor satiri'
    'New-EDExchangeTask' = 'Is tanimi (komut adi ayrica denetlenir)'
    'New-EDLocalTask'    = 'Is tanimi'
    'New-EDLogger'       = 'Gunlukleyici'

    # Cikti yazimi - yalnizca kendi output klasorune
    'New-Item'           = 'Cikti klasoru'
    'Out-Null'           = 'Cikti bastirma'
    'Out-String'         = 'Bicimlendirme'
    'Export-Csv'         = 'Kanit dosyasi yazimi'
    'Import-Csv'         = 'Onceki calistirmayi OKUR'
    'Add-Content'        = 'run.log satiri'
    'Set-Content'        = 'Kendi cikti dosyasi'
    'Set-StrictMode'     = 'Betik davranisi'
    'Set-Location'       = 'Yerel dizin'
    'Remove-PSSession'   = 'Kendi oturumunu kapatir'
    'Remove-Item'        = 'Yalnizca kendi derleme cache klasoru (CoreLoader)'
    'Import-Module'      = 'Modul yukleme'
    'Start-Sleep'        = 'Ornekleme araligi'
    'Start-Process'      = 'Rapor tarayicida acilir'

    # Invoke-Command burada yalnizca WINRM TASIYICISIDIR. Ne yaptigi degil, NE
    # TASIDIGI onemlidir - tasidigi scriptblock inline oldugu icin AST zaten
    # icine girer ve icindeki her komut ayrica denetlenir. Bu yuzden taşıyıcının
    # kendisi ihlal sayilmaz; icerigi sayilir.
    'Invoke-Command'     = 'WinRM tasiyicisi; icerigi AST tarafindan ayrica taranir'
}

# Aracin kendi yardimcilari (Verb-ED*). Bunlar Exchange'e dokunmaz; ortama
# dokunan tek kanal New-EDExchangeTask -Command'dir ve o AYRICA denetlenir.
# Yine de gercekten tehlikeli fiiller ED onekiyle bile gecerli sayilmaz.
$script:SafeHelperVerbs = @(
    'New', 'Get', 'Test', 'Read', 'Find', 'Convert', 'ConvertTo', 'ConvertFrom',
    'Compare', 'Merge', 'Measure', 'Save', 'Export', 'Import', 'Register',
    'Reset', 'Initialize', 'Clear', 'Write', 'Add', 'Select', 'Format',
    'Resolve',   # Resolve-EDVolume: saf yol eslemesi, diske dokunmaz
    'Connect'    # Connect-EDExchange: oturum acar, Exchange verisini DEGISTIRMEZ
)

# DIKKAT: ArrayList + $script: bilerek secildi. Fonksiyon icinde "$bulgular +="
# yazmak PowerShell'de YEREL bir kopya olusturur ve bulgular her cagri sonunda
# sessizce KAYBOLUR. Bir denetim betiginin sessizce hicbir sey bulmamasi, en
# kotu basarisizlik bicimidir.
$script:Violations = New-Object System.Collections.ArrayList
$script:ExchangeCommands = New-Object System.Collections.ArrayList

function Add-EDViolation {
    param([string]$File, [int]$Line, [string]$Kind, [string]$Command, [string]$Detail)
    [void]$script:Violations.Add([pscustomobject]@{
        Dosya = $File; Satir = $Line; Tur = $Kind; Komut = $Command; Detay = $Detail
    })
}

function Test-EDFileReadOnly {
    param([Parameter(Mandatory)][string]$Path)

    $name = Split-Path -Leaf $Path
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)

    if ($errors.Count -gt 0) {
        Add-EDViolation -File $name -Line $errors[0].Extent.StartLineNumber -Kind 'SOZDIZIMI' `
            -Command '' -Detail $errors[0].Message
        return
    }

    $commands = @($ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))

    foreach ($command in $commands) {
        $commandName = $command.GetCommandName()
        if (-not $commandName) { continue }
        $line = $command.Extent.StartLineNumber

        # --- 1. Cagrilan komutun fiili ---
        if (-not $script:AllowedCommands.ContainsKey($commandName)) {
            $verb = ($commandName -split '-')[0]
            $isOwnHelper = ($commandName -match '^\w+-ED' -or $commandName -match '^\w+-ExchangeDiag')

            if ($isOwnHelper) {
                # Kendi yardimcimiz olmasi her fiili mesru kilmaz.
                if ($verb -notin $script:SafeHelperVerbs) {
                    Add-EDViolation -File $name -Line $line -Kind 'KOMUT' -Command $commandName `
                        -Detail "Aracin kendi yardimcisi ama fiil '$verb' guvenli yardimci fiilleri arasinda degil."
                }
            }
            elseif ($verb -in $script:MutatingVerbs) {
                Add-EDViolation -File $name -Line $line -Kind 'KOMUT' -Command $commandName `
                    -Detail "Degistirici fiil '$verb'. Mesruysa Assert-ReadOnly.ps1 izin listesine GEREKCESIYLE eklenmeli."
            }
        }

        # --- 3. Mimari kural (moduller icin) ---
        # Invoke-Command burada YOK: o bir tasiyicidir, havuz yonetimi degil.
        # Asil kural kendi OTURUMUNU/IS PARCACIGINI acmamaktir.
        if ($name -like 'M*' -and $commandName -in @('New-PSSession', 'Start-Job', 'Start-ThreadJob', 'New-RunspacePool')) {
            Add-EDViolation -File $name -Line $line -Kind 'MIMARI' -Command $commandName `
                -Detail 'Moduller kendileri baglanti/paralellik yonetmez; yurutucuye devreder.'
        }

        # --- 2. Exchange'e GONDERILEN cmdlet adi ---
        if ($commandName -ne 'New-EDExchangeTask') { continue }

        $elements = @($command.CommandElements)
        for ($i = 0; $i -lt $elements.Count - 1; $i++) {
            $element = $elements[$i]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($element.ParameterName -ne 'Command') { continue }

            $value = $elements[$i + 1]
            if ($value -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                Add-EDViolation -File $name -Line $line -Kind 'EXCHANGE' -Command '(degisken)' `
                    -Detail 'Exchange komut adi SABIT DEGIL; degiskenden gelen ad denetlenemez.'
                continue
            }

            $cmdletName = $value.Value
            [void]$script:ExchangeCommands.Add([pscustomobject]@{ Dosya = $name; Cmdlet = $cmdletName })

            $verb = ($cmdletName -split '-')[0]
            if ($verb -in $script:MutatingVerbs) {
                Add-EDViolation -File $name -Line $line -Kind 'EXCHANGE' -Command $cmdletName `
                    -Detail "Exchange'e DEGISTIRICI cmdlet gonderiliyor. Arac salt okunurdur."
            }
        }
    }
}

# ---------------------------------------------------------------------------

Write-Host "`n=== SALT OKUNURLUK DENETIMI ===" -ForegroundColor Cyan

$moduleFiles = @(Get-ChildItem (Join-Path $projectRoot 'Modules') -Filter '*.ps1')
$coreFiles = @(Get-ChildItem (Join-Path $projectRoot 'Core') -Filter '*.ps1')
$entryFile = @(Get-Item (Join-Path $projectRoot 'Invoke-ExchangeDiag.ps1'))

foreach ($file in @($moduleFiles + $coreFiles + $entryFile)) {
    Test-EDFileReadOnly -Path $file.FullName
}

$distinctCmdlets = @($script:ExchangeCommands | ForEach-Object { $_.Cmdlet } | Sort-Object -Unique)

Write-Host ("Taranan: {0} modul + {1} cekirdek + 1 giris dosyasi" -f $moduleFiles.Count, $coreFiles.Count)
Write-Host "`nExchange kanalindan cagrilan cmdlet'ler ($($distinctCmdlets.Count) farkli):" -ForegroundColor Cyan
foreach ($cmdlet in $distinctCmdlets) {
    $verb = ($cmdlet -split '-')[0]
    $color = $(if ($verb -in $script:MutatingVerbs) { 'Red' } else { 'Gray' })
    Write-Host "  $cmdlet" -ForegroundColor $color
}

if ($script:Violations.Count -eq 0) {
    Write-Host "`n[TEMIZ] Salt okunurluk ihlali bulunamadi." -ForegroundColor Green
    Write-Host "        M32 gibi moduller duzeltme komutunu METIN olarak raporlar;" -ForegroundColor DarkGray
    Write-Host "        AST bunlari komut cagrisi saymaz - dogru davranis budur.`n" -ForegroundColor DarkGray
    exit 0
}

Write-Host "`n[IHLAL] $($script:Violations.Count) bulgu:" -ForegroundColor Red
@($script:Violations) | Sort-Object Dosya, Satir | Format-Table -AutoSize -Wrap
exit 1
