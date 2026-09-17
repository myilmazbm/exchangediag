<#
    M10 - Sunucu bazli teslim gecikmesi persentili

    "Hangi sunucu yavas?" sorusunun cevabi. Orgu P1 ve P6.

    ⚠️ ORTALAMA RAPORLANMAZ. Tek bir ortalama sayi tail'i gizleyerek sorunun
    varligini inkar ettirir: sunucu ortalamasi birkac saniye cikarken kullanici
    sikayeti dakikalar olabilir. Bu modul min/p50/p90/p95/p99/max dondurur;
    ortalama yalnizca "ortalama ne kadar yaniltiyor" oranini gostermek icin
    kullanilir.

    Veri kaynagi: Core\TrackingLog.ps1 (ham MSGTRKMD*.LOG veya cmdlet fallback).
    Hangi yolun kullanildigi rapora via= olarak yazilir; hiz kaybi gizlenmez.
#>

Register-EDModule @{
    Id          = 'M10'
    Name        = 'Teslim gecikmesi persentili'
    Phase       = 'B'
    Description = 'Hangi sunucu yavas - sunucu bazli p50/p95/p99'
    Heavy       = $true
    Patterns    = @('P1', 'P6')

    Run = {
        param($Context)

        $log = $Context.Log
        $analyses = Get-EDDeliveryAnalysis -Context $Context
        $window = $Context.Cache['AnalysisWindow']

        if ($analyses.Count -eq 0) {
            return @(New-EDRow -Module 'M10' -Check 'Teslim gecikmesi' -Status 'N/A' `
                -Note 'Sorgulanabilir sunucu yok.')
        }

        $p50 = @{}; $p95 = @{}; $p99 = @{}; $maxValues = @{}
        $counts = @{}; $meanValues = @{}; $viaValues = @{}
        $cellStatus = @{}
        # 'Olculen teslim sayisi' satirinin HUCRE hukumleri. Bu satir uzun
        # sure sabit 'OK' idi: okunamayan sunucu icin "0 teslim / OK" yaziyor,
        # yani olcum basarisizligi bir SAGLIK BEYANINA donusuyordu.
        $countStatus = @{}
        $evidence = @()
        $slowEvidence = @()
        $noDataServers = @()
        # Zaman siniri kesen sunucular: persentilleri EKSIK bir pencereden
        # hesaplanmistir ve bu, rapora cikmadan yalnizca log'a yazilirsa
        # aracin uretebilecegi en tehlikeli ciktidir (yanlis sunucuyu suclar).
        $partialServers = @()
        # KISMILIGIN SEBEBI DE TASINIR. Ayristirici artik zaman sinirini
        # (TruncatedByDeadline) okunamayan dosyadan (TruncatedByReadFailure)
        # ayiriyor ve ikisinin TAVSIYESI TERSTIR: birinde pencereyi daraltmak
        # coz, digerinde hicbir sey degistirmez. Tek bir "PENCERE KISMI"
        # cumlesi, yanlis sebebi yanlis eyleme baglardi.
        $partialDetails = @()
        $deadlineServers = @()
        $fileFailServers = @()
        $coverageValues = @{}
        $coverageStatus = @{}
        # DELIVER okundu ama hicbirinden gecikme turetilemedi: "olay yok" ile
        # ayni sey DEGIL ve rapor ikisini karistirmamali.
        $eventsNoLatency = @()
        $readFailedServers = @()
        $readFailedDetails = @()
        $cmdletReadFailure = $false
        $rawReadFailure = $false
        $anyData = $false

        foreach ($server in @($analyses.Keys | Sort-Object)) {
            $analysis = $analyses[$server]
            $stats = $analysis.Overall
            $viaValues[$server] = $analysis.Via

            foreach ($warning in $analysis.Warnings) { $log.Info("M10/$server : $warning") }

            # KISMILIK TEK BAYRAKTAN OKUNUR: IsPartial. Eskiden yalnizca
            # Truncated'a bakiliyordu ve not kosulsuz "zaman siniri kesti"
            # diyordu; okunamayan bir dosyada bu YANLIS SEBEPTIR ve yanlis
            # eyleme (pencereyi daralt) baglar.
            $partialReason = [string](Get-EDProperty $analysis 'PartialReason' '')
            $filesFailed = [long](Get-EDProperty $analysis 'FilesFailed' 0)
            if ([bool](Get-EDProperty $analysis 'IsPartial' $analysis.Truncated)) {
                $partialServers += $server
                $partialDetails += $(if ($partialReason) { "$server ($partialReason)" } else { $server })
                if ([bool](Get-EDProperty $analysis 'TruncatedByDeadline' $false)) { $deadlineServers += $server }
                if ($filesFailed -gt 0 -or [bool](Get-EDProperty $analysis 'TruncatedByReadFailure' $false)) {
                    $fileFailServers += $server
                }
                $cell = "KISMI $($analysis.FilesProcessed)/$($analysis.FilesScanned) dosya"
                if ($filesFailed -gt 0) { $cell += " ($filesFailed okunamadi)" }
                $coverageValues[$server] = $cell
                $coverageStatus[$server] = 'WARN'
                $log.Warn("M10/$server : SONUC KISMI ($partialReason); persentiller EKSIK pencereden hesaplandi.")
            }
            elseif ($analysis.Via -eq 'smb') {
                $coverageValues[$server] = "tam $($analysis.FilesScanned) dosya"
                $coverageStatus[$server] = 'OK'
            }
            else {
                # Cmdlet yolunda dosya kavrami yok; "tam 0 dosya" yaniltir.
                $coverageValues[$server] = 'cmdlet yolu'
                $coverageStatus[$server] = 'OK'
            }

            if ($stats.Count -eq 0) {
                $p50[$server] = 'N/A'; $p95[$server] = 'N/A'; $p99[$server] = 'N/A'
                $maxValues[$server] = 'N/A'; $meanValues[$server] = 'N/A'
                # OKUMA BASARISIZ: "olay yok" ile ayni sey degil ve tavsiyesi
                # de TERSTIR (pencereyi genisletmek, timeout'u kotulestirir).
                if ([bool](Get-EDProperty $analysis 'ReadFailed' $false)) {
                    $readFailedServers += $server
                    # SEBEP ve OKUMA YOLU birlikte yazilir: dogru EYLEM ikisine
                    # birden baglidir (cmdlet yolunda sorgu zaman asimi -
                    # pencereyi daraltmak ise yarar; ham yolda okunamayan dosya -
                    # daraltmak hicbir sey degistirmez, kilit/izin/AV aranir).
                    $detailText = "$server ($(if ($partialReason) { $partialReason } else { 'okuma hatasi' }), yol: $($analysis.Via)"
                    if ($filesFailed -gt 0) { $detailText += ", $filesFailed dosya okunamadi" }
                    $readFailedDetails += ($detailText + ')')
                    if ($analysis.Via -eq 'cmdlet') { $cmdletReadFailure = $true } else { $rawReadFailure = $true }
                    # OKUNAMAYAN SAYI 0 DEGILDIR. Ayni satirda hem 'N/A' hem
                    # 0 yazmak, sunucuyu "teslim yapmadi ama saglikli" diye
                    # okutuyordu; oysa hicbir sey OLCULMEDI.
                    $counts[$server] = 'N/A'
                    # Olcum basarisizligi en az WARN'dir: hucre 'N/A' yazsa da
                    # yesil kalirsa operator o sunucuyu taranmis sayar.
                    $cellStatus[$server] = 'WARN'
                    $countStatus[$server] = 'WARN'
                }
                elseif ($analysis.DeliverEvents -gt 0) {
                    # Olaylar okundu ama gecikme turetilemedi: olculen teslim
                    # sayisi 0 degil BILINMIYOR - sayi da hukum de gecersiz.
                    $eventsNoLatency += $server
                    $counts[$server] = 'N/A'
                    $cellStatus[$server] = 'WARN'
                    $countStatus[$server] = 'WARN'
                }
                else {
                    # Okuma BASARILI ve pencerede teslim YOK. Buradaki 0
                    # gercekten olculmus bir sayidir; kavram gecerli ama
                    # persentil hesaplanacak veri yoktur (gercek N/A).
                    $noDataServers += $server
                    $counts[$server] = 0
                    $cellStatus[$server] = 'N/A'
                }
                continue
            }

            $anyData = $true
            $p50[$server] = [math]::Round($stats.P50, 2)
            $p95[$server] = [math]::Round($stats.P95, 2)
            $p99[$server] = [math]::Round($stats.P99, 2)
            $maxValues[$server] = [math]::Round($stats.Max, 2)
            $meanValues[$server] = [math]::Round($stats.Mean, 2)
            $counts[$server] = $stats.Count

            # Pasif/DR sitedeki sunucuda dusuk hacim normaldir; FAIL sayilmaz.
            $topologyServer = @($Context.Topology.Servers | Where-Object { $_.Name -eq $server })
            $isPassive = ($topologyServer.Count -gt 0 -and $topologyServer[0].IsPassiveSite)

            $status = Get-EDStatus -Value $stats.P95 -ThresholdName 'deliveryLatencyP95Sec' -Config $Context.Config
            if ($isPassive -and $status -in @('WARN', 'FAIL')) {
                $log.Info("M10/$server : pasif sitede, $status bulgusu PASSIVE olarak etiketlendi.")
                $status = 'PASSIVE'
            }
            if ([bool](Get-EDProperty $analysis 'IsPartial' $analysis.Truncated)) {
                # Satiri WARN yapmak yetmez: hucre esik hukmunu (yesil OK)
                # gostermeye devam ederse operator o sayiya guvenir.
                $status = Get-EDWorstStatus @($status, 'WARN')
            }
            $cellStatus[$server] = $status

            $evidence += [pscustomobject]@{
                Server           = $server
                Via              = $analysis.Via
                Kayit            = $stats.Count
                Min              = [math]::Round($stats.Min, 3)
                P50              = [math]::Round($stats.P50, 3)
                P90              = [math]::Round($stats.P90, 3)
                P95              = [math]::Round($stats.P95, 3)
                P99              = [math]::Round($stats.P99, 3)
                Max              = [math]::Round($stats.Max, 3)
                Ortalama         = [math]::Round($stats.Mean, 3)
                P99OrtalamaOrani = [math]::Round($stats.P99 / [math]::Max($stats.Mean, 0.001), 1)
                # "Kismi mi" sorusunun cevabi tek bayrakta; SEBEBI ayri
                # sutunda. Kanit dosyasinda da ikisi birlikte durmali, cunku
                # tartisma cikinca sorulan ilk sey "neden eksikti" olur.
                Kismi            = [bool](Get-EDProperty $analysis 'IsPartial' $analysis.Truncated)
                KismiSebep       = $partialReason
                DosyaBulunan     = $analysis.FilesScanned
                DosyaIslenen     = $analysis.FilesProcessed
                DosyaOkunamayan  = $filesFailed
                DeliverOlayi     = $analysis.DeliverEvents
                GecikmeYok       = $analysis.LatencyMissing
                SaatKaymasi      = $analysis.NegativeLatency
                TarananSatir     = $analysis.LinesScanned
                SureMs           = [math]::Round($analysis.ElapsedMs)
            }

            foreach ($slow in $analysis.Slowest) {
                $slowEvidence += [pscustomobject]@{
                    Server    = $server
                    ZamanUtc  = $slow.TimestampUtc.ToString('yyyy-MM-dd HH:mm:ss')
                    ZamanYerel = $slow.TimestampUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
                    Saniye    = [math]::Round($slow.LatencySeconds, 2)
                    Alici     = $slow.Recipient
                    Gonderen  = $slow.Sender
                    Konu      = $slow.Subject
                    Kaynak    = $slow.Source
                    NetworkMesajId = $slow.NetworkMessageId
                    SmtpMesajId    = $slow.MessageId
                }
            }
        }

        Save-EDEvidence -Context $Context -Name 'M10-latency' -Data $evidence | Out-Null
        if ($slowEvidence.Count -gt 0) {
            Save-EDEvidence -Context $Context -Name 'M10-slowest-deliveries' -Data @($slowEvidence | Sort-Object -Property Saniye -Descending) | Out-Null
        }

        # --- OLCUM BASARISIZLIKLARI: her iki yolda da ayni metin ------------
        #
        # Bu listeler dogru dolduruluyordu ama YALNIZCA "hic veri yok"
        # dalinda kullaniliyordu. Yani TEK bir sunucu veri verdigi anda
        # okunamayan sunucularin adi rapora HIC girmiyor, gecikme avinin
        # merkez modulunde bir sunucu sessizce kayboluyordu. Metnin kendisi
        # zaten dogruydu; yeri yanlisti. Artik tek yerde uretilir ve her iki
        # yol da ayni cumleyi kullanir.
        $failureNotes = @()
        $failureStatus = 'OK'
        if ($readFailedServers.Count -gt 0) {
            $note = "OLCULEMEDI - tracking log OKUNAMADI ($($readFailedDetails -join ', ')). "
            $note += 'Bu bir bulgu YOKLUGU degil, olcum eksikligidir: bu sunucularin hucreleri N/A, teslim sayilari BILINMIYOR '
            $note += 've kiyasa (ORGU P1) girmezler. Pencereyi GENISLETMEYIN. '
            # TAVSIYE SEBEBE GORE AYRILIR. Ayni cumleyi iki sebebe birden
            # vermek, birinde kesin ise yaramayan bir eylem onermek demektir.
            if ($cmdletReadFailure) {
                $note += 'Cmdlet yolunda sorgu hata verdi veya zaman asimina ugradi: once -WindowHours ile DARALTIP tekrar deneyin; '
                $note += 'ham log erisimi (-LogAccess Smb) acilabiliyorsa cok daha hizlidir. '
            }
            if ($rawReadFailure) {
                $note += 'Ham log yolunda dosya okunamadi: pencereyi daraltmak ya da genisletmek bunu COZMEZ - '
                $note += 'dosya kilidi (baska bir surec dosyayi paylasimsiz acmis), NTFS/share izni, antivirus ya da kopmus SMB baglantisi arayin. '
            }
            $failureNotes += $note.TrimEnd()
            $failureStatus = 'WARN'
        }
        if ($eventsNoLatency.Count -gt 0) {
            $note = "OLCULEMEDI - DELIVER olaylari okundu ama hicbirinden gecikme turetilemedi ($($eventsNoLatency -join ', ')). "
            $note += 'Saat kaymasi veya ayristirici regresyonu olabilir; -VerifyParser satirina ve log kayitlarina bakin.'
            $failureNotes += $note
            $failureStatus = 'WARN'
        }
        # Bu SONUNCUSU bir olcum basarisizligi DEGILDIR: okuma calisti, teslim
        # yoktu. Hucrede 0 yazar ve satirin hukmunu yukseltmez - ama yine de
        # adlandirilir, cunku "veri yok" ile "sifir teslim" arasindaki farki
        # ancak sunucu adini goren operator dogrulayabilir.
        # KISMILIK CUMLESI DE TEK YERDE kurulur ve EYLEMI sebebe gore verir.
        # Bu cumle dort ayri yerde kullaniliyor; metin oralara kopyalanirsa
        # biri gunceldigi gun digerleri eski sebebi soylemeye devam eder.
        $partialNote = ''
        $partialTagShort = ''
        if ($partialServers.Count -gt 0) {
            $partialNote = "SONUC KISMI ($($partialDetails -join ', ')): bu sunucularin persentilleri pencerenin "
            $partialNote += 'TAMAMINI temsil etmez ve sunucular arasi kiyas (ORGU P1) yaniltici olabilir. '
            if ($deadlineServers.Count -gt 0) {
                $partialNote += "Zaman siniri kesenlerde ($($deadlineServers -join ', ')) pencereyi -WindowHours ile DARALTIN. "
            }
            if ($fileFailServers.Count -gt 0) {
                $partialNote += "Dosyasi okunamayanlarda ($($fileFailServers -join ', ')) pencereyi daraltmak ya da genisletmek COZMEZ - "
                $partialNote += 'dosya kilidi, NTFS/share izni, antivirus ya da kopmus SMB baglantisi arayin. '
            }
            $partialNote = $partialNote.TrimEnd()
            $partialTagShort = "SONUC KISMI ($($partialDetails -join ', ')). "
        }

        $noEventNote = ''
        if ($noDataServers.Count -gt 0) {
            $noEventNote = "Pencerede DELIVER olayi bulunamadi ($($noDataServers -join ', ')); bu sunucularda okuma BASARILI, teslim sayisi gercekten 0."
        }

        # Kapsam ve parser dogrulama satirlari VERI CIKMASA DA uretilmelidir:
        # "veri yok"un sebebi tam da bu satirlarda yaziyor. Erken return
        # bunlari dusurursek operator hicbir bulgu gormeden "temiz" rapor alir.
        $contextRows = @()
        if ($partialServers.Count -gt 0) {
            $contextRows += New-EDRow -Module 'M10' -Check 'Pencere kapsami' -Values $coverageValues -CellStatus $coverageStatus `
                -Status 'WARN' -Note ('Isaretli sunucularda persentiller EKSIK pencereden hesaplandi. ' + $partialNote)
        }
        if ($Context.VerifyParser) {
            $log.Info('M10: -VerifyParser istendi; ham ayristirici cmdlet ile karsilastiriliyor.')
            $verification = Test-EDParserAgreement -Context $Context
            $verifyValues = @{}
            $verifyCellStatus = @{}
            $details = @()
            foreach ($finding in $verification) {
                $verifyValues[$finding.Server] = $finding.Status
                $verifyCellStatus[$finding.Server] = $finding.Status
                $details += "$($finding.Server): $($finding.Detail)"
            }
            $contextRows += New-EDRow -Module 'M10' -Check 'Parser dogrulama (-VerifyParser)' -Values $verifyValues `
                -CellStatus $verifyCellStatus -Status (Get-EDWorstStatus @($verifyValues.Values)) `
                -Note ($details -join ' | ')
        }

        if (-not $anyData) {
            # Neden uc ayri sey olabilir ve tavsiye her birinde FARKLI.
            if ($partialServers.Count -gt 0) {
                $detail = 'Okuma EKSIK kaldi ve gecikme hesaplanamadi. ' + $partialNote
                $noDataStatus = 'WARN'
            }
            elseif ($failureNotes.Count -gt 0) {
                # Ayni metin, veri cikan yolda da kullanilan metindir.
                $detail = ($failureNotes -join ' ')
                if ($noEventNote) { $detail += " $noEventNote" }
                $noDataStatus = 'WARN'
            }
            else {
                $detail = 'Pencerede DELIVER olayi bulunamadi'
                if ($noDataServers.Count -gt 0) { $detail += " ($($noDataServers -join ', '))" }
                $detail += ". Pencereyi -WindowHours ile genisletin veya tracking log'un acik oldugunu dogrulayin."
                $noDataStatus = 'N/A'
            }
            return @(New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p95' -Values $p95 -CellStatus $cellStatus `
                -Unit 'sn' -Status $noDataStatus -Patterns @('P1', 'P6') -Note $detail) + $contextRows
        }

        # P1 kiyasina girmek icin gereken en az olcum sayisi. Tek teslimden
        # persentil cikmaz; bu esik "istatistik" ile "anekdot" arasindaki sinir.
        $minimumSamplesForComparison = 20

        # --- P1: bir sunucu digerlerinden kat kat yavas mi? ---
        $numericP95 = @{}
        foreach ($server in @($p95.Keys)) {
            if ($p95[$server] -ne 'N/A') { $numericP95[$server] = [double]$p95[$server] }
        }

        $outlierNote = ''
        # ORGU P1: bir sunucu digerlerinden kat kat yavas mi?
        #
        # KIYAS KUMESI pasif siteyi DISLAR. Pasif sitede dusuk hacim ve yuksek
        # gecikme normaldir (modul bunu zaten PASSIVE etiketiyle kabul ediyor);
        # ayni sunucuyu hem "dusuk hacim normal" deyip hem de ortancayi
        # bozmasina izin verip sonra "200x yavas" diye suclamak kendi icinde
        # celiskiydi - ustelik satir OK kaldigi icin iddia bulgu tablosuna
        # hic girmiyor, yalnizca detay notunda gomulu kaliyordu.
        # Pasif site sunuculari TOPOLOJIDEN okunur, hucre etiketinden DEGIL.
        # 'PASSIVE' etiketi yalnizca sunucunun kendi hukmu WARN/FAIL oldugunda
        # yaziliyor; OK olcen bir pasif site sunucusu etiketsiz kaliyor ve
        # kiyas kumesine giriyordu. Yani "pasif site kiyasa girmez" kurali
        # tam da kuralin en sik gecerli oldugu durumda uygulanmiyordu.
        $passiveServers = @($Context.Topology.Servers | Where-Object { $_.IsPassiveSite } | ForEach-Object { $_.Name })
        $comparable = @{}
        foreach ($server in @($numericP95.Keys)) {
            if ($server -in $passiveServers) { continue }
            # ORNEK SAYISI ESIGI: tek teslimden persentil cikmaz. n=1 iken
            # PercentileEngine her persentil icin o tek degeri dondurur, yani
            # az kullanilan bir sunucudaki TEK bir NDR "150x yavas" iddiasina
            # donusebiliyordu - "yanlis persentil yanlis sunucuyu suclar"in
            # ta kendisi.
            if ([int]$counts[$server] -lt $minimumSamplesForComparison) { continue }
            $comparable[$server] = $numericP95[$server]
        }

        $excludedFromComparison = @($numericP95.Keys | Where-Object { -not $comparable.ContainsKey($_) })

        if ($comparable.Count -ge 3) {
            # Ortanca yalnizca 3+ sunucuda anlamlidir. Iki sunucuda "ortanca"
            # diye bir sey yoktur: eski kod $sorted[floor(2/2)] = $sorted[1]
            # ile BUYUK elemani seciyordu, yani oran DAIMA 1.0 cikiyor ve P1
            # iki dugumlu ortamda hic tetiklenemiyordu. 30x fark bile gorunmez
            # kaliyordu.
            $sorted = @($comparable.GetEnumerator() | Sort-Object -Property Value)
            $middle = $sorted.Count / 2
            $median = $(if ($sorted.Count % 2 -eq 1) {
                $sorted[[int][math]::Floor($middle)].Value
            } else {
                ($sorted[[int]$middle - 1].Value + $sorted[[int]$middle].Value) / 2
            })
            $slowestEntry = $sorted[-1]
            if ($median -gt 0 -and ($slowestEntry.Value / $median) -ge 3) {
                $ratio = [math]::Round($slowestEntry.Value / $median, 1)
                $outlierNote = "ORGU P1: $($slowestEntry.Key) diger sunuculardan ${ratio}x yavas (p95 $($slowestEntry.Value) sn, ortanca $([math]::Round($median, 2)) sn, $($comparable.Count) sunucu kiyaslandi). Sorun topolojide degil, bu sunucuda."
                $log.Warn("M10: $outlierNote")
                $cellStatus[$slowestEntry.Key] = Get-EDWorstStatus @($cellStatus[$slowestEntry.Key], 'WARN')
            }
        }
        elseif ($comparable.Count -eq 2) {
            # Iki sunucuda ortanca yok ama DOGRUDAN kiyas anlamlidir.
            # Iddia daha temkinli kurulur: "digerlerinden" degil "digerinden".
            $sorted = @($comparable.GetEnumerator() | Sort-Object -Property Value)
            $faster = $sorted[0]; $slowestEntry = $sorted[1]
            if ($faster.Value -gt 0 -and ($slowestEntry.Value / $faster.Value) -ge 3) {
                $ratio = [math]::Round($slowestEntry.Value / $faster.Value, 1)
                $outlierNote = "ORGU P1: $($slowestEntry.Key) sunucusu $($faster.Key) sunucusundan ${ratio}x yavas (p95 $($slowestEntry.Value) sn / $($faster.Value) sn). Iki sunuculu ortamda ortanca yoktur; bu DOGRUDAN kiyastir. Sorun topolojide degil, bu sunucuda."
                $log.Warn("M10: $outlierNote")
                $cellStatus[$slowestEntry.Key] = Get-EDWorstStatus @($cellStatus[$slowestEntry.Key], 'WARN')
            }
        }

        if ($excludedFromComparison.Count -gt 0 -and $numericP95.Count -ge 2) {
            $outlierNote += (" Kiyas disi birakilan sunucular: {0} (pasif site veya {1} olcumden az)." -f `
                ($excludedFromComparison -join ', '), $minimumSamplesForComparison)
        }

        # --- P6: ortalama tail'i ne kadar gizliyor? ---
        $tailNotes = @()
        foreach ($server in @($numericP95.Keys)) {
            $analysis = $analyses[$server]
            if ($analysis.Overall.Mean -le 0) { continue }
            $ratio = $analysis.Overall.P99 / $analysis.Overall.Mean
            if ($ratio -ge 10) {
                $tailNotes += ('{0}: ortalama {1:N1} sn ama p99 {2:N1} sn ({3:N0}x)' -f `
                    $server, $analysis.Overall.Mean, $analysis.Overall.P99, $ratio)
            }
        }

        $viaList = @($viaValues.Values | Select-Object -Unique)
        $windowNote = "Pencere: $($window.StartUtc.ToLocalTime().ToString('HH:mm')) - $($window.EndUtc.ToLocalTime().ToString('HH:mm')) yerel saat ($($Context.WindowHours) saat), okuma: $($viaList -join '/')."
        if ($viaList -contains 'cmdlet') {
            $windowNote += ' Cmdlet yolu kullanildi - ham log erisimi acilirsa cok daha hizli olur.'
        }

        # Okunamayan sunucunun hucresi zaten WARN; yine de hukum ACIKCA
        # yukseltilir: hucre etiketlemesi ileride degisirse satir sessizce
        # OK'e donmemeli.
        $overallStatus = Get-EDWorstStatus (@($cellStatus.Values) + @($failureStatus))
        if ($partialServers.Count -gt 0) {
            # Kismi pencere hukmu gecersiz kilmaz ama en az WARN olmalidir:
            # aksi halde OK satiri raporun bulgu tablosuna hic girmez.
            $overallStatus = Get-EDWorstStatus @($overallStatus, 'WARN')
        }

        $rows = @()
        # OLCULEMEYEN SUNUCU EN ONDE yazilir: bir kiyas notu, kiyasa hic
        # giremeyen sunucularin adini gormeden okunamaz.
        $p95Note = (@(@($failureNotes) + @($noEventNote, $partialNote, $outlierNote, $windowNote)) | Where-Object { $_ }) -join ' '
        $p99Note = ''
        if ($tailNotes.Count -gt 0) {
            $p99Note = 'ORGU P6 - ortalama tail gizliyor: ' + ($tailNotes -join ' | ')
        }

        $rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p95' -Values $p95 -CellStatus $cellStatus `
            -Unit 'sn' -Status $overallStatus -Patterns @('P1', 'P6') -Note $p95Note
        # p50/p99/max/ortalama da ayni eksik pencereden geliyor; notsuz
        # birakilirsa "yetkili sayi" gibi okunurlar.
        $partialTag = $partialTagShort
        # Olculemeyen sunucular bu satirlarda da N/A yazar; SEBEBI yazmazsak
        # okuyucu N/A'i "bu sunucuda sorun yok" diye gecistirebilir. Hukum
        # burada yukseltilmez - bulgu tablosunu ayni olaydan turemis bes
        # satirla doldurmak, olayin kendisini gorunmez yapardi; iddiayi p95
        # ve teslim sayisi satirlari tasir.
        $unreadTag = $(if ($readFailedServers.Count + $eventsNoLatency.Count -gt 0) {
            "OLCULEMEYEN SUNUCU ($(@(@($readFailedServers) + @($eventsNoLatency)) -join ', ')): hucre N/A, sifir DEGIL - ayrinti p95 satirinda. "
        } else { '' })
        $partialOnlyTag = $partialTag
        $partialTag = $unreadTag + $partialTag
        $rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p50' -Values $p50 -Unit 'sn' -Status 'OK' -Note $partialTag
        # ORGU P6 metni bu satirdaydi ama satirin durumu sabit 'OK' idi ve
        # Report.ps1 bulgu tablosuna yalnizca WARN/FAIL/ERROR/TIMEOUT satirlarini
        # alir: yani P6 bulgusu tabloya HIC giremiyor, sadece detay notunda
        # kaliyordu. Ortalamanin tail'i gizledigi bir ortam tam da operatorun
        # gormesi gereken seydir.
        $p99Status = $(if ($tailNotes.Count -gt 0) { 'WARN' } else { 'OK' })
        $rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi p99' -Values $p99 -Unit 'sn' -Status $p99Status -Patterns @('P6') -Note ($partialTag + $p99Note)
        $rows += New-EDRow -Module 'M10' -Check 'Teslim gecikmesi max' -Values $maxValues -Unit 'sn' -Status 'OK' -Note $partialTag
        # Orgu P6 "ortalama dusuk, p99 cok yuksek" iddiasinin OTEKI yarisi bu
        # satirdir; etiketi yalnizca p99'a koymak, kiyasin dayandigi sayiyi
        # orguden kopuk birakirdi.
        $rows += New-EDRow -Module 'M10' -Check 'Ortalama (tek basina YANILTIR)' -Values $meanValues -Unit 'sn' -Status 'OK' `
            -Patterns @('P6') -Note ($partialTag + 'Yalnizca p99 ile kiyas icin gosterilir; karar verirken kullanilmaz.')
        # Bu satirin hukmu SABIT 'OK' idi. Okunamayan sunucu icin hucrede 0
        # yazip satiri OK birakmak, olcum basarisizligini "0 teslim, sorun
        # yok" diye okutan tam da o kusurdu: hucre N/A oldu, hukum de artik
        # okunamayan sunucu varken WARN.
        $countNote = (@(@($failureNotes) + @($noEventNote, $partialOnlyTag)) | Where-Object { $_ }) -join ' '
        $rows += New-EDRow -Module 'M10' -Check 'Olculen teslim sayisi' -Values $counts -CellStatus $countStatus `
            -Unit 'adet' -Status (Get-EDWorstStatus @('OK', $failureStatus)) -Note $countNote
        $rows += New-EDRow -Module 'M10' -Check 'Okuma yolu' -Values $viaValues -Status 'OK'
        $rows += $contextRows

        return $rows
    }
}
