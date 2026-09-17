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

    ALTI AYRI SEY DENETLENIR:

      1. Cagrilan PowerShell komutlari (kisayollar dahil - 'del' de
         Remove-Item'dir).
      2. New-EDExchangeTask -Command '<ad>' ile Exchange'e GONDERILEN cmdlet
         adlari. Asil risk buradadir: modul kendi icinde masum gorunup
         uzak uca 'Set-...' gonderebilir.
      3. .NET uye cagrilari. PowerShell komutu hic kullanmadan
         [System.IO.File]::WriteAllText(...) ya da $proc.Kill() yazmak
         mumkundur; bunlar CommandAst DEGILDIR.
      4. New-Object ile uretilen tipler. StreamWriter uretip .Write() cagirmak
         "New-Object izinli" diye mesru sayilamaz.
      5. Izinli yazma komutlarinin HEDEF YOLU. Izin gerekceleri "kendi cikti
         dosyasi" diyor; Set-Content C:\Windows\... bu gerekcenin disindadir.
      6. Brief'in mimari kurali: moduller kendileri baglanti/paralellik
         yonetmez, yurutucuye devreder.

    STATIK OLARAK KARAR VERILEMEYEN SEY SESSIZ GECILMEZ.
    & $cmd, iex, splat edilmis parametre kumesi, degiskenden gelen scriptblock:
    bunlarin ne yaptigi kaynaktan BILINEMEZ. Vaadi mutlak olan bir aracta
    "dogrulayamiyorum" bir bulgudur - DOGRULANAMAZ turu tam olarak budur.
    Bir denetim betiginin sessizligi temizlikten ayirt edilemez oldugu icin
    sessiz gecmek, yakalamamaktan daha kotudur.

    Kullanim:
        .\Tests\Assert-ReadOnly.ps1              # depoyu denetler, 0/1 doner
        .\Tests\Assert-ReadOnly.ps1 -Root <yol>  # baska bir agaci denetler
        .\Tests\Assert-ReadOnly.ps1 -AsObject    # bulgulari nesne olarak dondurur

    Cikis kodu: 0 temiz, 1 ihlal var.
#>
[CmdletBinding()]
param(
    # Denetlenecek agac. Varsayilan: depo koku. Test paketi bunu dusman bir
    # fixture deposuna yoneltir; denetim boylece KENDISI test edilebilir.
    [string]$Root,

    # Bulgulari yazdirmak yerine nesne olarak dondur (cikis kodu uretmez).
    [switch]$AsObject
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath

# Ortami degistirebilecek fiiller. Exchange kanalinda bunlardan biri
# calistirilirsa arac artik salt okunur degildir.
$script:MutatingVerbs = @(
    'Set', 'New', 'Remove', 'Add', 'Clear', 'Enable', 'Disable',
    'Start', 'Stop', 'Restart', 'Suspend', 'Resume', 'Move',
    'Mount', 'Dismount', 'Update', 'Install', 'Uninstall',
    'Register', 'Unregister', 'Rename', 'Reset', 'Repair',
    'Invoke', 'Send', 'Export', 'Import',
    # Asagidakiler listede YOKTU ve hepsi uretim ortamina yazar:
    'Limit',      # Limit-EventLog uretim olay gunlugunu YENIDEN BOYUTLANDIRIR
    'Write',      # Write-EventLog uretim gunlugune kayit duser
    'Copy', 'Restore', 'Backup', 'Format', 'Initialize', 'Optimize',
    'Publish', 'Grant', 'Revoke', 'Compress', 'Merge', 'Save', 'Submit'
)

# FIILI MASUM AMA KENDISI YIKICI olan komutlar. Fiil listesi bunlari
# yakalayamaz; bu yuzden ADLARIYLA yasaklanirlar. Izin listesinden ONCE
# bakilir: hicbir gerekce bunlari mesru kilamaz.
$script:DangerousCommands = @{
    'Search-Mailbox'     = '-DeleteContent postayi KALICI olarak siler; fiili "Search" diye masum degildir'
    'Test-Mailflow'      = 'GERCEK bir sonda iletisi gonderir - ortama yazar'
    'Test-OutlookConnectivity' = 'sunucuda sonda oturumu acar'
    'Invoke-Expression'  = 'calisma aninda uretilen kod hicbir bicimde denetlenemez'
    'Invoke-WebRequest'  = 'dis aga cikar; indirilen icerik denetlenemez'
    'Invoke-RestMethod'  = 'dis aga cikar; indirilen icerik denetlenemez'
    'Invoke-WmiMethod'   = 'uzak makinede yontem calistirir'
    'Invoke-CimMethod'   = 'uzak makinede yontem calistirir'
    'Out-GridView'       = 'etkilesimli pencere acar; toplu calistirmayi kilitler'
}

# Kisayollar. Fiil kontrolu adi '-' karakterinden bolerek yapar; kisayolda
# '-' YOKTUR, dolayisiyla 'del' ve 'iex' denetimden sessizce geciyordu.
# Bu tablo kisayolu kanonik ada cevirir; denetim kanonik ad uzerinden isler.
$script:CommandAliases = @{
    'iex' = 'Invoke-Expression'; 'icm' = 'Invoke-Command'
    'iwr' = 'Invoke-WebRequest'; 'curl' = 'Invoke-WebRequest'; 'wget' = 'Invoke-WebRequest'
    'irm' = 'Invoke-RestMethod'
    'del' = 'Remove-Item'; 'erase' = 'Remove-Item'; 'rd' = 'Remove-Item'
    'rmdir' = 'Remove-Item'; 'ri' = 'Remove-Item'; 'rm' = 'Remove-Item'
    'ni' = 'New-Item'; 'md' = 'New-Item'; 'mkdir' = 'New-Item'
    'cpi' = 'Copy-Item'; 'copy' = 'Copy-Item'; 'cp' = 'Copy-Item'
    'mi' = 'Move-Item'; 'move' = 'Move-Item'; 'mv' = 'Move-Item'
    'rni' = 'Rename-Item'; 'ren' = 'Rename-Item'
    'sc' = 'Set-Content'; 'ac' = 'Add-Content'; 'clc' = 'Clear-Content'
    'gc' = 'Get-Content'; 'cat' = 'Get-Content'; 'type' = 'Get-Content'
    'sp' = 'Set-ItemProperty'; 'rp' = 'Remove-ItemProperty'; 'gp' = 'Get-ItemProperty'
    'si' = 'Set-Item'; 'gi' = 'Get-Item'; 'gci' = 'Get-ChildItem'
    'ls' = 'Get-ChildItem'; 'dir' = 'Get-ChildItem'
    'kill' = 'Stop-Process'; 'spps' = 'Stop-Process'; 'saps' = 'Start-Process'
    'start' = 'Start-Process'; 'sasv' = 'Start-Service'; 'spsv' = 'Stop-Service'
    'sleep' = 'Start-Sleep'
    'sl' = 'Set-Location'; 'cd' = 'Set-Location'; 'chdir' = 'Set-Location'
    'epcsv' = 'Export-Csv'; 'ipcsv' = 'Import-Csv'
    'ipmo' = 'Import-Module'; 'rmo' = 'Remove-Module'
    'sv' = 'Set-Variable'; 'rv' = 'Remove-Variable'; 'gv' = 'Get-Variable'
    'echo' = 'Write-Output'; 'write' = 'Write-Output'
    'ogv' = 'Out-GridView'; 'oh' = 'Out-Host'
    'gwmi' = 'Get-WmiObject'; 'gcim' = 'Get-CimInstance'
    'where' = 'Where-Object'; 'foreach' = 'ForEach-Object'
    'select' = 'Select-Object'; 'sort' = 'Sort-Object'; 'group' = 'Group-Object'
    'measure' = 'Measure-Object'; 'compare' = 'Compare-Object'
    'ft' = 'Format-Table'; 'fl' = 'Format-List'; 'fw' = 'Format-Wide'
    '%' = 'ForEach-Object'; '?' = 'Where-Object'
}

# Yerel ve zararsiz kullanimlar. Her biri GEREKCESIYLE burada durur;
# gerekcesiz ekleme yapilmamalidir - bu liste denetimin kendisidir.
$script:AllowedCommands = @{
    # Bellekte nesne/veri olusturma - ortama dokunmaz
    'New-Object'         = 'Bellekte .NET nesnesi (uretilen TIP ayrica denetlenir)'
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

    # Cikti yazimi - yalnizca kendi output klasorune.
    # DIKKAT: bu gerekce ("kendi cikti dosyasi") artik DENETLENIR; asagidaki
    # PathConstrainedCommands listesi mutlak sistem yollarini reddeder.
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

    # Konsola yazan cmdlet'ler. 'Write' fiili artik degistirici sayildigi icin
    # (Write-EventLog yuzunden) bunlarin tek tek gerekcelenmesi gerekir.
    'Write-Host'         = 'Konsol ciktisi - ortama dokunmaz'
    'Write-Output'       = 'Pipeline ciktisi'
    'Write-Verbose'      = 'Ayrintili gunluk'
    'Write-Warning'      = 'Uyari'
    'Write-Error'        = 'Hata bildirimi'
    'Write-Debug'        = 'Hata ayiklama'
    'Write-Progress'     = 'Ilerleme cubugu'
    'Write-Information'  = 'Bilgi akisi'

    # 'Format' fiili de degistirici sayiliyor (Format-Volume diski siler).
    'Format-Table'       = 'Konsol bicimlendirme'
    'Format-List'        = 'Konsol bicimlendirme'
    'Format-Wide'        = 'Konsol bicimlendirme'

    # Invoke-Command burada yalnizca WINRM TASIYICISIDIR. Ne yaptigi degil, NE
    # TASIDIGI onemlidir. Ama bu muafiyet YALNIZCA INLINE scriptblock icin
    # gecerlidir: AST yalnizca kaynakta yazili bloklarin icine girebilir.
    # Degiskenden gelen blok ([scriptblock]::Create(...) gibi) gorunmezdir ve
    # asagida ayrica DOGRULANAMAZ olarak isaretlenir.
    'Invoke-Command'     = 'WinRM tasiyicisi; YALNIZCA inline scriptblock tasidiginda'
}

# Hedef yolu denetlenen komutlar. Izin gerekceleri "kendi cikti dosyasi" diyor;
# mutlak bir sistem yolu bu gerekcenin disindadir. Aracin gercek cikti yollari
# HER ZAMAN hesaplanir (Join-Path $OutputDir ...), hicbiri kaynakta mutlak
# sabit degildir - bu yuzden "mutlak sabit yol" guvenli bir isarettir.
$script:PathConstrainedCommands = @(
    'Set-Content', 'Add-Content', 'Clear-Content', 'Export-Csv', 'Out-File',
    # Tee-Object fiili masum gorunur ('Tee' degistirici fiil listesinde yok)
    # ama -FilePath ile DOSYAYA YAZAR. Fiil listesine guvenmek yetmiyor.
    'Tee-Object',
    'New-Item', 'Remove-Item', 'Copy-Item', 'Move-Item', 'Rename-Item',
    'Set-ItemProperty', 'Remove-ItemProperty'
)
$script:PathParameterNames = @('Path', 'LiteralPath', 'FilePath', 'Destination', 'OutputAssembly')
$script:AbsolutePathPattern = '^(?:[A-Za-z]:[\\/]|\\\\)'

# Parametrelerinin ICERIGI denetlenen komutlar. Bunlara splat edilmis bir
# hashtable verilirse denetim hicbir sey goremez ve SESSIZ KALIR; o yuzden
# splat burada bulgu sayilir.
$script:SplatSensitiveCommands = @(
    'New-EDExchangeTask', 'New-EDLocalTask', 'Invoke-Command'
) + $script:PathConstrainedCommands

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

# ---------------------------------------------------------------------------
# .NET uye cagrilari
#
# Eski ziyaretci yalnizca CommandAst topluyordu. Oysa tek bir PowerShell
# komutu kullanmadan da yazmak mumkundur:
#     [System.IO.File]::WriteAllText(...)   $service.StopService()   $proc.Kill()
# Bunlarin hicbiri CommandAst degildir ve hicbiri denetlenmiyordu.
# ---------------------------------------------------------------------------

# Adi tek basina yeterli olan yikici uyeler. Burada AMBIGU olanlar bilerek
# YOKTUR: Stop (Stopwatch.Stop), Add/Clear/Remove (bellekteki koleksiyonlar),
# Dispose. Onlarin yerine uretim ortamina dokunan, bu aracta mesru karsiligi
# olmayan adlar listelenir.
$script:MutatingMembers = @(
    'WriteAllText', 'WriteAllBytes', 'WriteAllLines',
    'AppendAllText', 'AppendAllLines', 'AppendText',
    'Write', 'WriteLine', 'WriteByte', 'WriteEntry',
    'Delete', 'DeleteValue', 'DeleteSubKey', 'DeleteSubKeyTree',
    'MoveTo', 'CopyTo', 'Encrypt', 'Decrypt',
    'Create', 'CreateDirectory', 'CreateSubKey', 'CreateText', 'CreateNew',
    'Kill', 'Terminate', 'Close',
    'Start', 'StartService', 'StopService', 'PauseService', 'ChangeStartMode', 'Change',
    'SetValue', 'SetAccessControl', 'SetAttributes',
    'SetCreationTime', 'SetLastWriteTime', 'SetOwner', 'SetEnvironmentVariable',
    'InvokeMethod', 'Put'
)

# Bu tiplerin STATIK uyelerinde varsayilan REDDETMEKTIR: yalnizca asagidaki
# okuma uyeleri gecer. Boylece [System.IO.File]::Open(...) gibi ileride
# eklenecek yazma yollari da otomatik yakalanir.
$script:DangerousStaticTypes = @(
    'System.IO.File', 'System.IO.Directory', 'System.IO.FileInfo', 'System.IO.DirectoryInfo',
    'System.IO.StreamWriter', 'System.IO.FileStream', 'System.IO.BinaryWriter',
    'System.Diagnostics.Process', 'System.Diagnostics.EventLog',
    'System.ServiceProcess.ServiceController',
    'Microsoft.Win32.Registry', 'Microsoft.Win32.RegistryKey',
    'System.Net.WebClient', 'System.Net.Sockets.TcpClient',
    'System.Management.ManagementObject',
    'scriptblock', 'System.Management.Automation.ScriptBlock'
)
$script:ReadOnlyStaticMembers = @(
    'ReadAllBytes', 'ReadAllText', 'ReadAllLines', 'ReadLines',
    'OpenRead', 'OpenText', 'Exists',
    'GetFiles', 'GetDirectories', 'GetFileSystemEntries',
    'GetLastWriteTime', 'GetLastWriteTimeUtc', 'GetCreationTime', 'GetCreationTimeUtc',
    'GetAttributes', 'GetProcesses', 'GetProcessById', 'GetCurrentProcess', 'GetServices'
)

# New-Object ile uretilmesi tek basina yazma niyeti olan tipler. 'New-Object
# izinli' oldugu icin StreamWriter uretip .Write() cagirmak eskiden tamamen
# mesru gorunuyordu.
$script:DangerousObjectTypes = @(
    'System.IO.StreamWriter', 'System.IO.FileStream', 'System.IO.BinaryWriter',
    'System.IO.StreamReader',          # FileShare'siz acilir; yazilan log'u kilitler
    'System.Diagnostics.Process', 'System.Diagnostics.EventLog',
    'System.ServiceProcess.ServiceController',
    'System.Net.WebClient', 'System.Net.Sockets.TcpClient',
    'System.Management.ManagementObject', 'System.Management.ManagementClass',
    'System.IO.FileSystemWatcher'
)

# Yikici gorunen ama GEREKCESIYLE mesru olan uye cagrilari.
# Anahtar: '<dosya adi>|<tip>.<uye>'  (ornek uye cagrilarinda tip bos kalir)
$script:AllowedMembers = @{
    'Compare.ps1|System.IO.File.WriteAllText'                 = 'Kendi delta durum dosyasi ve kendi delta HTML raporu'
    'Report.ps1|System.IO.File.WriteAllText'                  = 'Kendi HTML raporu'
    'CoreLoader.ps1|System.Security.Cryptography.SHA256.Create' = 'Kaynak hash hesabi - bellekte'
    'CoreLoader.ps1|.Write'                                   = 'MemoryStream.Write: hash tamponu, diske dokunmaz'
    'Framework.ps1|.Write'                                    = 'New-EDLogger ic yontemi; run.log satirini yazar'
}

# Komut adi kaynaktan cozulemeyen cagrilar. Her biri GEREKCESIYLE burada
# durur; gerekcesi olan yoksa DOGRULANAMAZ bulgusu uretilir.
# Anahtar: '<dosya adi>|<cagrilan ifadenin metni>'
$script:AllowedDynamicInvocations = @{
    'Framework.ps1|$file.FullName'            = 'Import-EDModules: Modules\ altindaki dosyalari dot-source eder; o dosyalar da bu denetimden gecer'
    'Invoke-ExchangeDiag.ps1|$moduleInfo.Run' = 'Modul dagitimi: Run bloklari Modules\ dosyalarindan gelir ve ayrica taranir'
    'Invoke-ExchangeDiag.ps1|$topologyModule[0].Run' = 'Modul dagitimi (ayni gerekce)'
}

# DIKKAT: ArrayList + $script: bilerek secildi. Fonksiyon icinde "$bulgular +="
# yazmak PowerShell'de YEREL bir kopya olusturur ve bulgular her cagri sonunda
# sessizce KAYBOLUR. Bir denetim betiginin sessizce hicbir sey bulmamasi, en
# kotu basarisizlik bicimidir.
$script:Violations = New-Object System.Collections.ArrayList
$script:ExchangeCommands = New-Object System.Collections.ArrayList

# Islenmekte olan cagri bir kisayolla yazildiysa ('del' gibi) bulgunun
# metninde KAYNAKTAKI yazim da gorunmelidir; aksi halde raporda 'Remove-Item'
# yazar ama dosyada o metin hic gecmez ve bulgu aranamaz hale gelir.
$script:AliasNote = ''

function Add-EDViolation {
    param([string]$File, [int]$Line, [string]$Kind, [string]$Command, [string]$Detail)
    [void]$script:Violations.Add([pscustomobject]@{
        Dosya = $File; Satir = $Line; Tur = $Kind; Komut = $Command
        Detay = $Detail + $script:AliasNote
    })
}

function Resolve-EDCommandName {
    <#
        Kisayolu kanonik ada cevirir. Cozulemeyen ve '-' icermeyen bir ad
        harici bir program ya da bilinmeyen bir kisayol demektir; cagiran
        taraf bunu bulgu sayar.
    #>
    param([string]$Name)
    $key = $Name.ToLowerInvariant()
    if ($script:CommandAliases.ContainsKey($key)) { return $script:CommandAliases[$key] }
    return $Name
}

function Get-EDParameterValue {
    <#
        Bir komut elemani listesinde adi verilen parametrenin DEGERINI dondurur.

        IKI BICIM DE OKUNUR:
          -Command 'Get-Foo'   -> deger bir sonraki elemandadir
          -Command:'Get-Foo'   -> deger CommandParameterAst.Argument icindedir
        Ikincisi eskiden HIC okunmuyordu; bulgu uretiliyordu ama "ad sabit
        degil" diye YANLIS gerekceyle ve cmdlet adi denetim izine hic girmiyordu.
    #>
    param($Elements, [string]$ParameterName)

    for ($i = 0; $i -lt $Elements.Count; $i++) {
        $element = $Elements[$i]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
        if ($element.ParameterName -ne $ParameterName) { continue }
        if ($null -ne $element.Argument) { return $element.Argument }
        if ($i + 1 -lt $Elements.Count) { return $Elements[$i + 1] }
        return $null
    }
    return $null
}

function Test-EDSplatted {
    param($Elements)
    foreach ($element in $Elements) {
        if ($element -is [System.Management.Automation.Language.VariableExpressionAst] -and $element.Splatted) { return $true }
    }
    return $false
}

function Test-EDWriteMarked {
    <#
        Yazim satiri acikca muaf tutulmus mu? Isaret satirin KENDISINDE ya da
        hemen ustundeki satirda aranir - gerekce yazimdan uzaklasirsa
        okuyan onu dogrulayamaz.
    #>
    param([int]$Line)

    foreach ($offset in 0, 1) {
        $index = $Line - 1 - $offset
        if ($index -lt 0 -or $index -ge $script:CurrentLines.Count) { continue }
        if ($script:CurrentLines[$index] -match '#\s*ED-WRITE-OK:') { return $true }
    }
    return $false
}

function Test-EDPathArguments {
    <#
        Izinli yazma komutlarinin hedef yolunu denetler. Kaynakta MUTLAK SABIT
        bir yol varsa bu "kendi cikti dosyasi" gerekcesinin disindadir.
    #>
    param([string]$File, [int]$Line, [string]$CommandName, $Elements)

    $candidates = @()
    foreach ($parameterName in $script:PathParameterNames) {
        $value = Get-EDParameterValue -Elements $Elements -ParameterName $parameterName
        if ($null -ne $value) { $candidates += $value }
    }
    # Konumsal ilk arguman da hedef olabilir: Add-Content 'C:\...' 'x'
    if ($Elements.Count -gt 1) { $candidates += $Elements[1] }

    # AYNI HEDEF IKI KEZ BULUNABILIR: adlandirilmis parametre ile konumsal
    # arguman ayni dugume isaret edebilir. Ayni ihlali iki kez raporlamak
    # bulgu sayisini sisirir ve okuyanin gercek kapsami kestirmesini
    # zorlastirir - bir denetimin gurultusu de guvenilirligini dusurur.
    $seen = @{}
    $unique = @()
    foreach ($candidate in $candidates) {
        if ($null -eq $candidate) { continue }
        # PARAMETRE ADI HEDEF DEGILDIR. Konumsal aday olarak alinan
        # $Elements[1], `-LiteralPath $p` yaziminda parametrenin KENDISIDIR
        # (CommandParameterAst). Onu "sabit olmayan yol" sayarsak her mesru
        # cagri icin ikinci bir sahte bulgu ureririz - denetimin gurultusu
        # de guvenilirligini dusurur.
        if ($candidate -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
        $key = "$($candidate.Extent.StartOffset)|$($candidate.Extent.Text)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $unique += $candidate
    }
    $candidates = $unique

    foreach ($candidate in $candidates) {
        # STATIK OLARAK KARAR VERILEMEYEN SEY SESSIZ GECILMEZ.
        #
        # Eski kod sabit olmayan her yolu `continue` ile atliyordu, yani
        # $p = 'C:\Windows\Temp\x'; Set-Content -LiteralPath $p ... yazimi
        # denetimden HIC IZ BIRAKMADAN geciyordu. Olculdu: boyle bir modul
        # sifir bulgu uretti.
        #
        # Cozum "hepsini ihlal say" DEGIL: aracin kendi cikti yollari da
        # hesaplanmis degiskenlerdir (Join-Path $OutputDir ...) ve onlari
        # kirmizi yapmak denetimi kalici kirmiziya cevirirdi - kalici
        # kirmizi bir denetim, susturulmus denetimle aynidir. Bunun yerine
        # mesru olanlar satirinda GEREKCESIYLE isaretlenir; isaretsiz her
        # degisken yol DOGRULANAMAZ bulgusu uretir.
        if ($candidate -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            if (Test-EDWriteMarked -Line $Line) { continue }
            Add-EDViolation -File $File -Line $Line -Kind 'DOGRULANAMAZ' -Command $CommandName `
                -Detail ("Hedef yol SABIT DEGIL ({0}); nereye yazildigi kaynaktan bilinemez. Mesruysa satirina '# ED-WRITE-OK: <gerekce>' yazin." -f $candidate.Extent.Text)
            continue
        }
        if ($candidate.Value -notmatch $script:AbsolutePathPattern) { continue }
        Add-EDViolation -File $File -Line $Line -Kind 'YOL' -Command $CommandName `
            -Detail ("Mutlak sabit yola yaziliyor: '{0}'. Izin gerekcesi yalnizca KENDI cikti klasorunu kapsar." -f $candidate.Value)
    }
}

function Test-EDCommandName {
    <#
        Yerel olarak cagrilan bir komutun adini denetler. Exchange kanali
        ayrica denetlenir; bu fonksiyon HER IKI kanal icin de kullanilir.
    #>
    param([string]$File, [int]$Line, [string]$Kind, [string]$CommandName)

    if ($script:DangerousCommands.ContainsKey($CommandName)) {
        Add-EDViolation -File $File -Line $Line -Kind $Kind -Command $CommandName `
            -Detail ("Yikici komut: {0}" -f $script:DangerousCommands[$CommandName])
        return
    }
    if ($script:AllowedCommands.ContainsKey($CommandName)) { return }

    $verb = ($CommandName -split '-')[0]
    $isOwnHelper = ($CommandName -match '^\w+-ED' -or $CommandName -match '^\w+-ExchangeDiag')

    if ($isOwnHelper) {
        # Kendi yardimcimiz olmasi her fiili mesru kilmaz.
        if ($verb -notin $script:SafeHelperVerbs) {
            Add-EDViolation -File $File -Line $Line -Kind $Kind -Command $CommandName `
                -Detail "Aracin kendi yardimcisi ama fiil '$verb' guvenli yardimci fiilleri arasinda degil."
        }
        return
    }
    if ($verb -in $script:MutatingVerbs) {
        Add-EDViolation -File $File -Line $Line -Kind $Kind -Command $CommandName `
            -Detail "Degistirici fiil '$verb'. Mesruysa Assert-ReadOnly.ps1 izin listesine GEREKCESIYLE eklenmeli."
    }
}

function Test-EDFileReadOnly {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $name = $DisplayName
    $leaf = Split-Path -Leaf $Path
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    # Muafiyet isaretini satir bazinda arayabilmek icin kaynak satirlari
    # tutulur. Dosya BAZINDA aramak (ED-LOCAL-OK'un yaptigi gibi) burada
    # fazla kaba olurdu: tek bir mesru yazim, ayni dosyadaki butun
    # yazimlari muaf kilardi.
    $script:CurrentLines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)

    if ($errors.Count -gt 0) {
        Add-EDViolation -File $name -Line $errors[0].Extent.StartLineNumber -Kind 'SOZDIZIMI' `
            -Command '' -Detail $errors[0].Message
        return
    }

    # --- A. Cagrilan komutlar ---
    $commands = @($ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))

    foreach ($command in $commands) {
        $line = $command.Extent.StartLineNumber
        $rawName = $command.GetCommandName()

        if (-not $rawName) {
            # & $cmd / . $path : komut adi kaynaktan BILINEMEZ. Eski kod burada
            # sessizce continue ederdi; denetimin sessizligi temizlikten ayirt
            # edilemez oldugu icin bu, en tehlikeli kacis yoluydu.
            $target = $command.CommandElements[0]
            $targetText = $target.Extent.Text

            # Proje icindeki bir dosyanin dot-source edilmesi dogrulanabilir:
            # hedef (Join-Path $projectRoot '<sabit>') ise ve o dosya bu
            # taramanin KAPSAMINDA ise, icerigi zaten ayrica denetlenir.
            $isVerifiedDotSource = $false
            if ($command.InvocationOperator -eq 'Dot' -and
                $target -is [System.Management.Automation.Language.ParenExpressionAst]) {
                $literals = @($target.FindAll(
                    { param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
                foreach ($literal in $literals) {
                    $probe = Join-Path $Root $literal.Value
                    if (Test-Path -LiteralPath $probe -PathType Leaf) { $isVerifiedDotSource = $true }
                }
            }

            if (-not $isVerifiedDotSource -and -not $script:AllowedDynamicInvocations.ContainsKey("$leaf|$targetText")) {
                Add-EDViolation -File $name -Line $line -Kind 'DOGRULANAMAZ' -Command '(dinamik)' `
                    -Detail ("Komut adi calisma aninda belirleniyor: '{0}'. Ne cagrildigi kaynaktan dogrulanamaz." -f $targetText)
            }
            continue
        }

        $commandName = Resolve-EDCommandName -Name $rawName
        if ($commandName -ne $rawName) {
            # Kisayol cozuldu; bulgu metninde HER IKISI de gorunmelidir ki
            # okuyan kisi kaynakta neyi arayacagini bilsin.
            $script:AliasNote = " (kaynakta kisayol: '$rawName')"
        }
        else {
            $script:AliasNote = ''
        }

        if ($commandName -notmatch '-') {
            # Ne kanonik bir cmdlet ne de bilinen bir kisayol: harici program
            # olabilir. Fiil cikarilamadigi icin denetlenemez.
            if (-not $script:AllowedCommands.ContainsKey($commandName)) {
                Add-EDViolation -File $name -Line $line -Kind 'DOGRULANAMAZ' -Command $commandName `
                    -Detail 'Fiil-isim bicimi degil (harici program ya da bilinmeyen kisayol); ne yaptigi denetlenemez.'
                continue
            }
        }

        Test-EDCommandName -File $name -Line $line -Kind 'KOMUT' -CommandName $commandName

        $elements = @($command.CommandElements)

        # --- Splat: parametre kumesi gorunmez olur ---
        if ($commandName -in $script:SplatSensitiveCommands -and (Test-EDSplatted -Elements $elements)) {
            Add-EDViolation -File $name -Line $line -Kind 'DOGRULANAMAZ' -Command $commandName `
                -Detail 'Parametreler splat edilmis hashtable ile veriliyor; hangi komut/yol gonderildigi kaynaktan gorunmez.'
        }

        # --- Yol kisiti ---
        if ($commandName -in $script:PathConstrainedCommands) {
            Test-EDPathArguments -File $name -Line $line -CommandName $commandName -Elements $elements
        }

        # --- Invoke-Command: muafiyet YALNIZCA inline blok icin ---
        if ($commandName -eq 'Invoke-Command') {
            $filePathArg = Get-EDParameterValue -Elements $elements -ParameterName 'FilePath'
            if ($null -ne $filePathArg) {
                Add-EDViolation -File $name -Line $line -Kind 'DOGRULANAMAZ' -Command 'Invoke-Command' `
                    -Detail 'Uzak uca -FilePath ile dosya gonderiliyor; tasidigi kod AST tarafindan goruntulenemez.'
            }
            $scriptArg = Get-EDParameterValue -Elements $elements -ParameterName 'ScriptBlock'
            if ($null -ne $scriptArg -and
                $scriptArg -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                Add-EDViolation -File $name -Line $line -Kind 'DOGRULANAMAZ' -Command 'Invoke-Command' `
                    -Detail 'Tasinan scriptblock INLINE degil; AST icine giremez, uzak uca ne gittigi dogrulanamaz.'
            }
        }

        # --- New-Object: uretilen tip ---
        if ($commandName -eq 'New-Object') {
            $typeArg = Get-EDParameterValue -Elements $elements -ParameterName 'TypeName'
            if ($null -eq $typeArg -and $elements.Count -gt 1) { $typeArg = $elements[1] }
            $comArg = Get-EDParameterValue -Elements $elements -ParameterName 'ComObject'

            if ($null -ne $comArg) {
                Add-EDViolation -File $name -Line $line -Kind 'NESNE' -Command 'New-Object -ComObject' `
                    -Detail 'COM nesnesi uretiliyor; yaptigi is kaynaktan denetlenemez.'
            }
            elseif ($null -eq $typeArg) {
                Add-EDViolation -File $name -Line $line -Kind 'DOGRULANAMAZ' -Command 'New-Object' `
                    -Detail 'Uretilen tip kaynaktan okunamiyor.'
            }
            elseif ($typeArg -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                Add-EDViolation -File $name -Line $line -Kind 'DOGRULANAMAZ' -Command 'New-Object' `
                    -Detail 'Uretilen tip SABIT DEGIL; degiskenden gelen tip denetlenemez.'
            }
            else {
                # 'System.IO.StreamWriter(...)' gibi yapici cagrisi da tek
                # bareword olarak gelebilir; tip adi ilk parantezde biter.
                $typeName = ($typeArg.Value -split '\(')[0].Trim().Trim("'", '"')
                if ($typeName -in $script:DangerousObjectTypes) {
                    Add-EDViolation -File $name -Line $line -Kind 'NESNE' -Command $typeName `
                        -Detail 'Bu tipin tek isi ortama yazmak/baglanmaktir; New-Object izni onu mesru kilmaz.'
                }
            }
        }

        # --- Mimari kural (moduller icin) ---
        # Invoke-Command burada YOK: o bir tasiyicidir, havuz yonetimi degil.
        # Asil kural kendi OTURUMUNU/IS PARCACIGINI acmamaktir.
        if ($leaf -like 'M*' -and $commandName -in @('New-PSSession', 'Start-Job', 'Start-ThreadJob', 'New-RunspacePool')) {
            Add-EDViolation -File $name -Line $line -Kind 'MIMARI' -Command $commandName `
                -Detail 'Moduller kendileri baglanti/paralellik yonetmez; yurutucuye devreder.'
        }

        # --- Exchange'e GONDERILEN cmdlet adi ---
        if ($commandName -ne 'New-EDExchangeTask') { continue }

        $value = Get-EDParameterValue -Elements $elements -ParameterName 'Command'
        if ($null -eq $value) {
            # Splat zaten yukarida bulgu uretti; burada ayrica "hicbir sey
            # kaydedilmedi" gercegini isaretliyoruz. Eskiden bu durum denetim
            # izinde HIC IZ BIRAKMIYORDU.
            if (-not (Test-EDSplatted -Elements $elements)) {
                Add-EDViolation -File $name -Line $line -Kind 'DOGRULANAMAZ' -Command 'New-EDExchangeTask' `
                    -Detail 'Exchange gorevi -Command olmadan kuruluyor; gonderilen cmdlet adi denetim izine girmiyor.'
            }
            continue
        }

        if ($value -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            Add-EDViolation -File $name -Line $line -Kind 'DOGRULANAMAZ' -Command '(degisken)' `
                -Detail 'Exchange komut adi SABIT DEGIL; degiskenden gelen ad denetlenemez.'
            continue
        }

        $cmdletName = $value.Value
        [void]$script:ExchangeCommands.Add([pscustomobject]@{ Dosya = $name; Cmdlet = $cmdletName })
        Test-EDCommandName -File $name -Line $line -Kind 'EXCHANGE' -CommandName $cmdletName
    }

    # --- B. .NET uye cagrilari ---
    $script:AliasNote = ''
    $members = @($ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))

    foreach ($member in $members) {
        $line = $member.Extent.StartLineNumber

        if ($member.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            Add-EDViolation -File $name -Line $line -Kind 'DOGRULANAMAZ' -Command '(dinamik uye)' `
                -Detail ("Uye adi calisma aninda belirleniyor: {0}" -f $member.Extent.Text)
            continue
        }

        $memberName = $member.Member.Value
        $typeName = ''
        if ($member.Static -and $member.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) {
            $typeName = $member.Expression.TypeName.FullName
        }

        if ($script:AllowedMembers.ContainsKey("$leaf|$typeName.$memberName")) { continue }

        $qualified = $(if ($typeName) { "$typeName::$memberName" } else { $memberName })

        if ($memberName -in $script:MutatingMembers) {
            Add-EDViolation -File $name -Line $line -Kind 'UYE' -Command $qualified `
                -Detail 'Ortama yazan .NET uye cagrisi. Mesruysa AllowedMembers listesine GEREKCESIYLE eklenmeli.'
            continue
        }

        if ($typeName -in $script:DangerousStaticTypes -and $memberName -notin $script:ReadOnlyStaticMembers) {
            Add-EDViolation -File $name -Line $line -Kind 'UYE' -Command $qualified `
                -Detail 'Bu tipte varsayilan reddetmektir; yalnizca acikca okuma olan uyeler gecer.'
        }
    }

    # --- C. YONLENDIRME OPERATORLERI ---
    #
    # EN GENIS KACIS YOLUYDU. `$data > 'C:\Windows\Temp\x.txt'` bir KOMUT
    # DEGILDIR: AST'de CommandAst yoktur, FileRedirectionAst vardir ve
    # denetim bu dugum turunu HIC ziyaret etmiyordu. Olculdu: C:\Windows'a
    # dort ayri yoldan yazan bir modul SIFIR bulguyla gecti.
    #
    # Yonlendirme tek basina yazmadir; hedefin ne oldugu onemli degildir,
    # cunku salt okunur bir aracin DOSYAYA YAZMASI icin mesru bir sebep
    # yoktur - kendi ciktisini bile Export-Csv / Out-File ile yazar ve o
    # yollar yol kisitiyla ayrica denetlenir.
    $redirections = @($ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FileRedirectionAst] }, $true))

    foreach ($redirection in $redirections) {
        $line = $redirection.Extent.StartLineNumber
        $text = $redirection.Extent.Text

        # 2>$null / *>$null gibi SUSTURMALAR dosyaya yazmaz. $null hedefi
        # PowerShell'de ozel bir bit kovasidir; bunu ihlal saymak denetimi
        # yanlis alarma bogar ve susturulan bir denetim yok demektir.
        $target = $redirection.Location
        $targetText = $(if ($target) { [string]$target.Extent.Text } else { '' })
        if ($targetText -match '^\$null$') { continue }

        Add-EDViolation -File $name -Line $line -Kind 'YONLENDIRME' -Command $text `
            -Detail ("Yonlendirme operatoru DOSYAYA YAZAR (hedef: {0}). Salt okunur arac dosyaya yalnizca kendi cikti yoluna, Export-Csv/Out-File ile yazar." -f $targetText)
    }
}

# ---------------------------------------------------------------------------

if (-not $AsObject) { Write-Host "`n=== SALT OKUNURLUK DENETIMI ===" -ForegroundColor Cyan }

# Tarama -Recurse'suzdu ve yalnizca Modules\*.ps1 + Core\*.ps1 + giris
# dosyasina bakiyordu: Modules\alt\*.ps1, herhangi bir *.psm1 ve Config\*.ps1
# HIC goruntulenmiyordu. Artik agacin tamami taranir; disarida kalanlar
# yalnizca URUN OLMAYAN klasorlerdir ve her biri gerekcelidir.
#   Tests\         -> testler bilerek dosya yazar (fixture); urun kodu degildir
#   Sample-Output\ -> uretilmis ornek cikti
#   .git\ .claude\ -> surum kontrolu / arac meta verisi
$script:SkipPattern = '^(Tests|Sample-Output|\.git|\.claude)($|\\)'

function Get-EDScanFile {
    <#
        Agaci kendi gezer ve her dosyanin KOKE GORE yolunu birlikte dondurur.

        NEDEN Get-ChildItem -Recurse + Substring DEGIL: $env:TEMP gibi yollar
        8.3 kisa ad iceriyorsa ($env:TEMP = ...\ADMINI~1.YIL\...) kok metni
        ile dosyanin FullName'i FARKLI UZUNLUKTA olur ve Substring dosya adini
        ortasindan keser. Gezerken ad biriktirmek bu sorunu tumden yok eder.
        Ayrica atlanan klasorlere (orn. .git) hic girilmez.
    #>
    param([string]$Directory, [string]$Prefix)

    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)) {
        $relative = $(if ($Prefix) { Join-Path $Prefix $item.Name } else { $item.Name })
        if ($relative -match $script:SkipPattern) { continue }

        if ($item.PSIsContainer) {
            Get-EDScanFile -Directory $item.FullName -Prefix $relative
        }
        elseif ($item.Extension -in '.ps1', '.psm1') {
            [pscustomobject]@{ Path = $item.FullName; Display = $relative }
        }
    }
}

$scanFiles = @(Get-EDScanFile -Directory $Root -Prefix '' | Sort-Object Display)

foreach ($file in $scanFiles) {
    Test-EDFileReadOnly -Path $file.Path -DisplayName $file.Display
}

if ($AsObject) { return @($script:Violations) }

$distinctCmdlets = @($script:ExchangeCommands | ForEach-Object { $_.Cmdlet } | Sort-Object -Unique)

Write-Host ("Taranan: {0} betik dosyasi (*.ps1, *.psm1 - alt klasorler dahil)" -f $scanFiles.Count)
Write-Host "`nExchange kanalindan cagrilan cmdlet'ler ($($distinctCmdlets.Count) farkli):" -ForegroundColor Cyan
foreach ($cmdlet in $distinctCmdlets) {
    $verb = ($cmdlet -split '-')[0]
    $isBad = ($verb -in $script:MutatingVerbs) -or $script:DangerousCommands.ContainsKey($cmdlet)
    $color = $(if ($isBad) { 'Red' } else { 'Gray' })
    Write-Host "  $cmdlet" -ForegroundColor $color
}

if ($script:Violations.Count -eq 0) {
    Write-Host "`n[TEMIZ] Salt okunurluk ihlali bulunamadi." -ForegroundColor Green
    Write-Host "        M32 gibi moduller duzeltme komutunu METIN olarak raporlar;" -ForegroundColor DarkGray
    Write-Host "        AST bunlari komut cagrisi saymaz - dogru davranis budur.`n" -ForegroundColor DarkGray
    exit 0
}

Write-Host "`n[IHLAL] $($script:Violations.Count) bulgu:" -ForegroundColor Red
Write-Host "        DOGRULANAMAZ da bir bulgudur: vaadi mutlak olan bir aracta" -ForegroundColor DarkGray
Write-Host "        'ne yaptigini goremiyorum' ile 'temiz' ayni sey degildir.`n" -ForegroundColor DarkGray
@($script:Violations) | Sort-Object Dosya, Satir | Format-Table -AutoSize -Wrap
exit 1
