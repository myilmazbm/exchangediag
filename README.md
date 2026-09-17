# ExchangeDiag

Exchange ortamlarında **kuyruk ve teslim gecikmesi** teşhisi için modül tabanlı, salt okunur tarama aracı.

Tek bir sunucuya bakmak yerine **bütün sunucuları aynı anda, aynı formatta** tarar ve sonuçları yan yana koyar — çünkü kıyas olmadan tek bir ölçüm anlamsızdır. Her bulgunun ham verisi CSV olarak diske yazılır ki sonradan tartışılabilsin.

Ayrıntılı spesifikasyon: [`00-PROJE-BRIEF.md`](00-PROJE-BRIEF.md). Mimari ve performans kararları: aynı dosya, Bölüm 14.

---

## Bu araç ne YAPMAZ

Bu bölüm başta duruyor, çünkü aracın asıl değeri burada.

**Ortamı değiştirmez.** Hiçbir modül yazma işlemi yapmaz. Düzeltme öneren modüller komutu **metin olarak** raporlar, çalıştırmaz:

```
Move-ActiveMailboxDatabase <DB> -ActivateOnServer <tercih-1-sunucu>  --  BU ARAC CALISTIRMAZ
```

**Veriye dayanmayan iddiada bulunmaz.** Bu, her modülde ayrı ayrı uygulanan bir disiplin:

| Durum | Araç ne yapar |
|---|---|
| Referans değer tablosunda yoksa | "Değiştirilmiş" demez, **hiçbir şey demez** (M16, M43) |
| Üçüncü parti antivirüs varsa | "Dışlama yok" demez, `N/A` döner (M42) |
| Tek veritabanı varsa | "Yoğunlaşma var" demez (M12) |
| Pencere 6 saatten darsa | Tepe saat uydurmaz (M13) |
| Medyan sıfırsa | "Yüksek" demez (M23) |
| Disk de yavaşsa | Store'u suçlamaz (M20) |
| `LastFullBackup` boşsa | Yedek alınmadığını **kanıtlanmış** saymaz (M45) |
| Whitespace %70 ise | Eşik uygulamaz — whitespace bir hata değildir (M25) |
| İçerik indeksi bozuksa | Teslim gecikmesiyle ilişkilendirmez (M26) |
| Disk hiç ölçülemediyse | "Disk sağlıklı" demez; P4 örgüsünü **kurmaz** (M20/M21) |
| Bir sayaç/cmdlet okunamadıysa | Hücreye `0` yazmaz, `N/A` yazar ve satırı en az `WARN`'a çeker — `N/A` "sıfır" demek değildir |
| Profil bir bulguyu bastırdıysa | Sessiz kalmaz: hüküm `N/A`'e çekilir, notta `[BASTIRILDI: …]` yazar ve rapora bir `CORE` satırı düşer |

**Ortalamayı tek başına raporlamaz.** Süre ölçen her yerde `min / p50 / p90 / p95 / p99 / max`. Ortalama kuyruğu (tail) gizler ve gecikme teşhisinde asıl mesele kuyruktur.

**`_Total` göstermez.** On diskten dokuzu sağlıklıyken biri boğulmuş olabilir; araç **en kötü** örneği raporlar, sunucu ortalamasını değil.

---

## Gereksinimler

| | |
|---|---|
| PowerShell | 5.1 (Windows PowerShell) |
| .NET | Framework 4.8+ (`Add-Type` derlemesi için) |
| Exchange | 2016 / 2019 / Subscription Edition |
| Yetki | Exchange yönetim uç noktasına erişim + hedef sunucularda WinRM |
| Exchange Management Tools | **Gerekmez** — araç uzak yönetim uç noktasına bağlanır |

Ham tracking log okuma yönetim paylaşımına (`\\sunucu\D$`) erişim ister. Varsayılan `-LogAccess Auto`'da erişim yoksa araç `Get-MessageTrackingLog`'a düşer ve bunu raporda `via=cmdlet` olarak belirtir — hız kaybı gizlenmez. `-LogAccess Smb` **açıkça** verilmişse düşülmez: o sunucu tabloda kalır ve neden okunamadığını yazar. İsteği görmezden gelmek, ham ayrıştırıcıyı zorlamak için o modu seçen kişiyi kör bırakırdı.

---

## Hızlı başlangıç

```powershell
# Bu ortamda hangi moduller gecerli? (hicbir kontrol calistirmaz)
.\Invoke-ExchangeDiag.ps1 -ListModules

# Hizli saglik taramasi
.\Invoke-ExchangeDiag.ps1 -Quick

# ASIL TESHIS: gecikme avi. YOGUN SAATTE calistirin.
.\Invoke-ExchangeDiag.ps1 -Module M10,M11,M12,M13,M20,M21,M22,M23 -Heavy

# Tam tarama
.\Invoke-ExchangeDiag.ps1 -All -Heavy

# Sakin saat vs yogun saat karsilastirmasi
.\Invoke-ExchangeDiag.ps1 -All -CompareWith .\output\20260917-030000
```

> **Sakin saatte alınan ölçüm yanıltır.** Araç yoğun saatte çalıştırılmak üzere tasarlandı. `-CompareWith` ile iki ölçümü karşılaştırmak tek bir ölçümden daha değerlidir: tek ölçüm bir sayıdır, iki ölçüm bir **yön**dür.

---

## Parametreler

| Parametre | Açıklama |
|---|---|
| `-Module M10,M11,...` | Belirli modüller |
| `-All` | Tüm modüller (ağır olanlar için ayrıca `-Heavy`) |
| `-Quick` | Hızlı sağlık taraması (varsayılan) |
| `-ListModules` | Kuru çalıştırma: hangi modüller geçerli, hangileri neden atlanıyor |
| `-Heavy` | Pahalı modülleri de çalıştırır. **Bilerek kapalı gelir** |
| `-Server <ad>` | Tek sunucu. Kıyas kaybolacağı için derin inceleme dışında önerilmez |
| `-WindowHours <n>` | Tracking log penceresi |
| `-LogAccess Auto\|Smb\|Cmdlet` | Ham dosya okuma vs cmdlet |
| `-VerifyParser` | Ham ayrıştırıcıyı `Get-MessageTrackingLog`'a karşı doğrular (%1 tolerans). **`-Heavy` ile kullanılmalı** — doğrulama M10 içinden çalışır; M10 planda yoksa hiçbir şey doğrulanmaz ve rapora *"gecikme türetimi DOĞRULANMIŞ SAYILMAZ"* diyen bir `WARN` satırı düşer. Ham yol hiç veri üretemediyse karşılaştırma yapılamaz ve kök nedene göre hüküm verilir: ayrıştırıcı regresyonu `FAIL`, saat kayması `WARN`, zaman sınırı `N/A` |
| `-CompareWith <klasör>` | Önceki çalıştırmayla delta |
| `-Parallelism <n>` | Eşzamanlılık (throttling tavanından türetilir) |
| `-Credential` | Alternatif kimlik |
| `-OutputRoot <yol>` | Çıktı kökü |
| `-Quiet` | Yalnızca uyarı ve hataları yazdırır |

### Çıkış kodları

| Kod | Anlamı |
|---|---|
| `0` | Tarama **tamamlandı**, eşikleri aşan bulgu yok |
| `1` | Tarama **tamamlandı**, en kötü bulgu `WARN`/`ERROR`/`TIMEOUT` |
| `2` | Tarama **tamamlandı**, en az bir `FAIL` var |
| `3` | **Araç çalışamadı**: tarama hiç yapılamadı veya yarıda kaldı. `SUMMARY.csv`/`SUMMARY.html` ve `run-meta.json` **üretilmedi** |

`0/1/2` "rapora bak" demektir; `3` "bakacak rapor yok, önce aracı çalışır hale getir" demektir. Tipik `3` sebepleri: bozuk `Config\`, Exchange'e bağlanılamaması, geçersiz parametre, M01 topoloji keşfinin başarısız olması — gerekçe `run.log`'un sonundadır. İkisi aynı kod olursa (bir süre ikisi de `1` idi) zamanlanmış bir görev, **hiç üretilmemiş bir raporu** bekler durur.

---

## Modüller

### Faz A — envanter
| ID | Ne bakar |
|---|---|
| M01 | Topoloji keşfi: sunucu, site, rol, DAG, DB haritası. Diğer her şeyin girdisi |
| M02 | Gerçek build — **yalnızca `ExSetup.exe` dosya sürümü güvenilirdir** |
| M03 | Zorunlu servisler ayakta mı |
| M04 | Sertifikalar: süre, atanmış servisler. SMTP ayrıca vurgulanır |
| M05 | CPU, RAM, pagefile, **çalışma süresi**, .NET sürümü |

### Faz B — gecikme tespiti
| ID | Ne bakar |
|---|---|
| M10 | Teslim gecikmesi persentilleri (ham log ayrıştırma) |
| M11 | Faz kırılımı: Ingress / Transport / Store — **örgü P2** |
| M12 | Yavaş teslimlerin veritabanı dağılımı — **örgü P3** |
| M13 | Saat bazlı dağılım — **örgü P7** |
| M14 | Transport kuyrukları: derinlik **yerel teslim** ve **uzak hedef** olarak ayrı satırlarda, ayrıca retry ve poison |
| M15 | Back pressure |
| M16 | Transport eşzamanlılık ayarları |

### Faz C — store ve depolama
| ID | Ne bakar |
|---|---|
| M20 | Store RPC latency — **örgü P4** |
| M21 | Disk latency (`_Total` değil, en kötü volume; **ham sayaçtan** türetilir) |
| M22 | DB → volume haritası — **örgü P5** |
| M23 | Ağır kullanıcılar + yorum tablosu |
| M24 | Büyük klasörler (kanıtı takip eder, körlemesine taramaz) |
| M25 | DB boyutu ve birim kapasitesi |
| M26 | İçerik indeksi (DAG gerektirmez) |

### Faz D — DAG ve replikasyon
| ID | Ne bakar |
|---|---|
| M30 | Kopya durumu |
| M31 | Kopya ve replay kuyrukları (ikisi **ayrı** şeylerdir; kasıtlı gecikmeli *lagged* kopyalar replay hükmüne girmez — orada büyük kuyruk tasarımdır) |
| M32 | Aktif kopya dağılımı — **örgü P8** |
| M33 | `Test-ReplicationHealth` |
| M34 | Siteler arası replikasyon (WAN ayrımı) |

> DAG yoksa Faz D'nin tamamı temiz `N/A` döner — hata değildir.

### Faz E — sağlık ve ortam
| ID | Ne bakar |
|---|---|
| M40 | Managed Availability sağlık setleri |
| M41 | Olay günlüğü (gruplanmış, gürültü filtreli) |
| M42 | AV dışlamaları (yalnızca Defender okunabilir) |
| M43 | Yama durumu (referans liste boşsa hüküm vermez) |
| M44 | Lisans / deneme süresi / Windows aktivasyonu |
| M45 | Yedekleme durumu ve günlük kesme zinciri |

---

## Teşhis örgüleri

Araç ham sayı basmaz; **örüntü** arar. Brief Bölüm 3'te tanımlı:

| | Örgü | Anlamı | Ne zaman iddia edilir |
|---|---|---|---|
| **P1** | Bir sunucu belirgin yavaş | Kıyas tablosunda tek sütun sapar | En yavaş / ortanca **≥ 3x**; kıyasa yalnızca 20+ teslim ölçülmüş, pasif site olmayan sunucular girer |
| **P2** | Store fazı baskın | Darboğaz transport değil store tarafında | Store baskın **ve** uçtan uca p95 ≥ eşiğin yarısı — iç trafikte Store payının en büyük olması normaldir |
| **P3** | Gecikme belirli DB'lerde yoğunlaşıyor | Kök neden DB seviyesinde | En az 2 DB **ve** en yüksek pay, beklenen 1/N payının iki katını aşıyor (%50-80 arasına kırpılır) |
| **P4** | Yüksek RPC + **sağlıklı** disk + boş kuyruk | Suçlu store; disk değiştirmek işe yaramaz | Disk **gerçekten ölçüldüyse**; ölçülemeyen disk sağlıklı sayılmaz |
| **P5** | Paylaşılan volume + yavaş disk | Komşu DB'ler birbirini etkiliyor | Aynı volume'da 2+ DB **ve** o volume'un disk hükmü `WARN`/`FAIL`; M20/M21 koşmadıysa `N/A` |
| **P6** | Ortalama düşük, p99 yüksek | Ortalama kuyruğu gizliyor | p99 / ortalama ≥ 10 |
| **P7** | Yoğun saatte belirgin tepe | Kapasite / eşzamanlılık sınırı | En az 6 saatte 20+ teslim, tepe/sakin oranı ≥ 3x. **Kapasite** iddiası yalnızca tepe saat aynı zamanda yoğunsa |
| **P8** | Aktif kopyalar `ActivationPreference` dışında | Failover sonrası dengelenmemiş | Tercih 1 dışında çalışan her aktif kopya. Yük dengesizliği **ayrı** hükümdür |

Her örgü, iddia edildiğinde **hangi modülle sürdürüleceğini** de yazar. Tersi de geçerlidir: koşul tutmuyorsa örgü kurulmaz ve rapor bunu söyler — P7'de tepe saat düşük hacimliyse "gecikme yük kaynaklı DEĞİL" diye karşı-uyarı yazar, P3 tek DB'li ortamda yoğunlaşma iddia etmez.

---

## Yapılandırma

`Config\` klasörü yoksa araç `Config.sample\` içindeki değerleri kullanır ve bunu raporda belirtir.

```powershell
Copy-Item .\Config.sample .\Config -Recurse
```

| Dosya | İçerik |
|---|---|
| `environment.json` | Pencere, eşzamanlılık, log erişimi, Exchange uç noktası, pasif siteler, tarama sınırları |
| `thresholds.json` | Eşikler. **Hepsi öneridir** |
| `reference.json` | Üretici varsayılanları, sistem posta kutusu deseni, SU listesi, AV dışlama listesi |
| `profiles.json` | Ortam profilleri (`lab`, `production`) |
| `known-issues.json` | Bastırılan bulgular — **gerekçe ve son kullanma tarihi zorunlu** |

Dosyalar yorum satırı (`//`, `/* */`) kabul eder.

**Eşik yönü** ayrıca belirtilmez, iki sayı kendini anlatır:
- `warn < fail` → yüksek kötü (gecikme, kuyruk, CPU)
- `warn > fail` → düşük kötü (sertifika ömrü, boş disk)

Bir eşikte `warn`/`fail` eksikse veya sayısal değilse araç **açık hata verir**; eksik anahtarı sessizce `0` saymak yönü tersine çevirir ve boş bir kuyruğu `FAIL` yapardı.

`profiles.json` → `ignoreFindings` bir bulguyu bastırdığında hüküm `N/A`'e çekilir, satırın notu `[BASTIRILDI: profil …, desen …]` ile başlar ve raporun sonuna `CORE / Bastirilan bulgu` satırı düşer. **Görünmeyen bastırma, yanlış negatifle aynıdır.** Desen `M45:NoRecentBackup` biçiminde yazılırsa yalnızca o modülde geçerli olur.

Bastırma kalıcı olamaz; süresi dolan bastırmalar otomatik yok sayılır ve raporda görünür:

```jsonc
{ "module": "M40", "match": "SomeHealthSet\\\\SomeMonitor",
  "reason": "Uretici tarafinda acik known issue #12345", "expires": "2026-12-31" }
```

---

## Çıktı

```
output\20260917-121102\
├─ SUMMARY.html        ← bulgular + tüm sunucular yan yana + modül süreleri
├─ SUMMARY.csv
├─ DELTA.html          ← yalnızca -CompareWith ile
├─ DELTA.csv
├─ run-meta.json       ← çalıştırmanın KAPSAMI (delta bunu okur)
├─ run.log
└─ M*-*.csv            ← her bulgunun ham kanıtı
```

`output\` ve gerçek `Config\` **`.gitignore` içindedir** — sunucu, kullanıcı ve posta kutusu adları taşırlar.

`SUMMARY.csv` iki okuyucuyu birden gözetir. Sayılar **invariant** biçimde yazılır, çünkü dosyayı `-CompareWith` makine olarak okur; tr-TR'de `12,5` yazılıp `125` okunsaydı iki özdeş koşu hayalet delta üretirdi. Buna karşılık `=`, `+`, `-`, `@` ile başlayan **metin** hücreler tek tırnakla kaçırılır: bu metinler bizim değil Exchange'in ürettiği metinlerdir (`LastError`, `ContentIndexErrorMessage`, mesaj konusu) ve Excel onları formül sayıp çalıştırabilir. **Kanıt toplayan salt okunur bir araç, kanıtını açan kişiyi vurmamalıdır.** Sayılar bu kaçırmadan muaftır, yoksa `-3.5` bozulurdu.

Anonimleştirilmiş örnek rapor `Sample-Output\` altında depoyla birlikte gelir; yeniden üretmek için (gerçek ortama hiç dokunmaz):

```powershell
.\Tests\New-SampleOutput.ps1
```

---

## `-CompareWith` delta motoru

Delta motorunun asıl işi fark hesaplamak değil, **hangi farkın anlamsız olduğunu söylemektir.**

Sessizce yanlış kıyas yapmanın yolları engellenir:

1. **Kapsam farkı.** Önceki çalıştırma 1 saatlik pencereyle, yenisi 24 saatlikse persentiller zaten farklı çıkar — bu bir değişim değil **ölçüm farkıdır**. Aynısı `-Heavy` ve log erişim yolu için de geçerli. Rapor bu durumda en üste `KIYAS GUVENILIR DEGIL` uyarısı basar. `run-meta.json` tam olarak bunun için yazılır.
2. **N/A sınırı.** "Ölçülemedi" ile "sıfır" aynı şey değildir. `N/A` → değer geçişi **iyileşme değildir**; yüzde hesaplanmaz.
3. **Küçük sayıda büyük yüzde.** `0.001 → 0.002` yüzde olarak %100 artıştır ama hiçbir şey ifade etmez. Mutlak taban altında yüzde gizlenir.
4. **Saat farkı.** Farklı saatlerde alınan iki ölçüm arasındaki fark gerilemeye değil **yüke** bağlı olabilir. Kıyasın amacı bu olduğu için engellenmez, ama hatırlatılır.
5. **Hükümsüz durumlar sıraya girmez.** `FAIL → N/A` geçişi, yani **sorunu artık görememek**, bir iyileşme değildir. `N/A` ve `PASSIVE` iyileşme/gerileme sayaçlarına hiç girmez; bu geçişler üçüncü bir kovada, **ÖLÇÜM DEĞİŞİMİ** olarak raporlanır. Başlık sayaçları ile satır metni artık aynı şeyi söyler.
6. **Renk yönden değil DURUMDAN gelir.** "Arttı kırmızı, azaldı yeşil" her metriğin "yüksek olan kötüdür" olduğunu varsayar: boş disk %40 → %8 düşüşü, durum `OK → FAIL` olmasına rağmen yeşil basılıyordu. Renk artık satırın kendi durum geçişinden alınır; geçiş yoksa nötr bırakılır — **bilmediğimiz yönü renkle uydurmayız.**
7. **Kapsam farkı yalnızca engellemez, bildirir de.** Modül kümesi, sunucu filtresi ve profil farkı `run-meta.json`'dan okunur ve "Dikkat" notu olarak yazılır: `-Module M10,M11` ile alınmış bir tabanı tam koşuyla kıyaslarsanız diğer bütün modüller `YENİ`/`KAYBOLDU` görünür — bu bir **değişim değil kapsam** farkıdır. Eski meta dosyalarında liste boşsa uydurma uyarı üretilmez.

Kaybolan bir kontrol `KAYBOLDU` olarak işaretlenir ve açıkça *"sorunun geçtiği anlamına gelmez"* der — modül atlanmış olabilir. Sütunu kaybolan sunucunun **ölçülmüş değeri de korunur**: yoksa `MBX2 = 999 (FAIL)` kapsam dışı kalınca geriye yalnızca "FAIL → OK" kalır ve sorun çözülmüş gibi görünür.

---

## Testler

```powershell
# Butun paketler, HER KULTUR icin ayri ayri (varsayilan: en-US + tr-TR)
.\Tests\Invoke-EDTests.ps1

# Tek paket
.\Tests\Invoke-EDTests.ps1 -Name Test-CompareEngine.ps1
```

**Neden kültür başına?** Bu araç Türkçe Exchange ortamları için yazıldı ama testler geliştiricinin makinesinde (en-US) koşuyordu. `.NET`'in sayı ayrıştırması kültüre duyarlıdır, PowerShell ise sayıları **her zaman** invariant biçimde string'e çevirir; ikisi karşılaştığında tr-TR'de `0.07` değeri `7` okunur. Bu, **her eşik hükmünü 100 kat kaydıran** bir hataydı ve tek bir test bile kırmızı olmuyordu: 12,5 ms RPC `FAIL`, üç gün sonra dolacak sertifika `OK` görünüyordu. Bu yüzden geçmek yetmez — aynı paketler ikinci kez `tr-TR` altında da geçmelidir. Sonuç satırı üretmeyen paket "0 hata" sayılmaz, `COKTU` raporlanır.

**`Assert-ReadOnly.ps1`** brief 1. ilkesinin otomatik güvencesidir ve artık paketin içinden de koşar (`Test-ReadOnlyLint.ps1`). Tüm modüllerin ve çekirdeğin AST'sini tarar; denetlediği altı şey: çağrılan komutların fiilleri (**takma adlar dâhil** — `del` de `Remove-Item`'dır), **Exchange'e gönderilen cmdlet adları**, `.NET` üye çağrıları, `New-Object` ile üretilen tipler, yazma izni olan komutların **hedef yolu**, ve modüllerin kendi oturum/iş parçacığı açmaması. Üstüne üç "doğrulanamaz" kuralı vardır: dinamik çağrı (`& $cmd`, `iex`), splat edilmiş parametre kümesi ve `Invoke-Command -FilePath` — çözülemeyen bir çağrı **temiz sayılmaz**, bulgu sayılır.

Grep değil AST kullanmasının sebebi şu: M32 düzeltme komutunu `'Move-ActiveMailboxDatabase ...'` diye **metin olarak** raporlar. Düz metin araması bunu ihlal sanar; AST metin sabitini komut çağrısından ayırır.

Denetimin kendisi de sınanır. Düşmanca bir sahte depoya karşı koşturulduğunda yirmi kadar yazma yolundan **yalnızca ikisini** yakaladığı görüldü — bir denetim betiğinin sessizliği, temizlikten ayırt edilemediği için en kötü başarısızlık biçimidir.

Şu an Exchange kanalından çağrılan **15 cmdlet'in tamamı `Get-` veya `Test-`** — asıl güvence bu listedir:

```
Get-DatabaseAvailabilityGroup   Get-MailboxTransportService   Get-ServerHealth
Get-ExchangeCertificate         Get-MessageTrackingLog        Get-StoreUsageStatistics
Get-ExchangeServer              Get-Queue                     Get-TransportService
Get-MailboxDatabase             Get-Recipient                 Test-ReplicationHealth
Get-MailboxDatabaseCopyStatus   Get-MailboxFolderStatistics   Test-ServiceHealth
```

| Paket | Doğrulama | Kapsam |
|---|---|---|
| `Test-TrackingLogParser` | 137 | C# ayrıştırıcı: `#Fields:` eşlemesi, tırnaklı CSV, UTC, gecikme türetimi, zaman bütçesi, performans |
| `Test-CoreUnits` | 130 | C# çekirdek: `PercentileEngine`, `StatsAccumulator`, `CsvLineSplitter` |
| `Test-LatencyModules` | 47 | M10-M13 uçtan uca — **canlı Exchange uç noktası ister** |
| `Test-LatencyPatterns` | 69 | Örgü P1/P2/P3/P7'nin karar mantığı (sahte yürütücü) |
| `Test-TransportModules` | 71 | M14-M16 |
| `Test-PerfModules` | 52 | M20-M22, örgü P4 ve P5 |
| `Test-StoreModules` | 50 | M23-M24, yorum tablosu |
| `Test-BaselineModules` | 103 | M04, M05, M25, M26 |
| `Test-DagModules` | 100 | M30-M34 (sentetik DAG) |
| `Test-HealthModules` | 79 | M40-M45 |
| `Test-CompareEngine` | 145 | Delta motoru ve kapsam koruması |
| `Test-ReportLayer` | 110 | Rapor katmanı: CSV kaçırma, `N/A` sınıfı, çıkış kodları |
| `Test-ReadOnlyLint` | 38 | Salt okunurluk denetiminin kendi testi |
| `Test-ModuleContracts` | 33 | Yapısal sözleşme: makine verisi isteyen modül ve Core toplayıcısı hedef sunucuya gidiyor mu |
| `Test-TimeoutVerdict` | 28 | `TIMEOUT` sıralaması ve etrafındaki kararlar |

**15 paket × 2 kültür = 2384 doğrulama.** `Test-LatencyModules` dışındaki paketler gerçek sunucuya hiç sorgu göndermez: sahte yürütücü gerçek `ExchangeDiag.ExecResult` nesneleri üretir, sentetik tracking log'lar `%TEMP%` altına yazılır — hiçbir paket depo içine yazmaz.

Örgülerin **karar** mantığı `Test-LatencyModules`'te değil `Test-LatencyPatterns`'ta sınanır: iki sunuculu, pasif siteli, tek örneklemli, düşük hacimli tepe saatli senaryolar canlı bir ortamda üretilemez.

---

## Performans

Hız tezinin tamamı tek bir yerde: `Get-MessageTrackingLog` her satırı zengin bir .NET nesnesine dönüştürür (~2-10 bin satır/sn). Log'lar diskte zaten CSV olarak durur; ham dosyayı C# ile okumak **~1.100.000 satır/sn** demek.

| Ölçüm | Sonuç |
|---|---|
| 240.000 satır (79 MB) ayrıştırma | **211 ms** |
| M10 hedefi (200k satır < 3 sn) | 211 ms ile karşılandı |
| Tam tarama (tek sunucu, `-All`) | 25 sn — 21 sn'si kasıtlı sayaç örneklemesi |

C# çekirdek `Add-Type` ile çalışma anında derlenir ve SHA256 ile `%LOCALAPPDATA%\ExchangeDiag\cache` altında önbelleklenir. İlk çalıştırma ~1-2 sn, sonrası ~40 ms. Teslimat **yalnızca `.ps1` dosyalarıdır**; imzasız `.exe` güven sorunu yoktur, kaynak okunabilir.

Perf sayacı örneklemesi doğası gereği duvar saati maliyetidir; **tüm sunucular aynı anda** örneklenir, süre sunucu sayısıyla artmaz. M20 ve M21 tek bir örnekleme turunu paylaşır.

---

## Bilinen sınırlar

| Sınır | Not |
|---|---|
| `-VerifyParser` gerçek ortamda doğrulanmadı | Geliştirme lab'ında tracking log boş. Ham ayrıştırıcının cmdlet ile **aynı** sonucu ürettiği ancak gerçek veriyle gösterilebilir |
| Faz D sentetik veriyle doğrulandı | Lab tek sunuculu ve DAG'sız. Gerçek bir DAG'a erişildiğinde M30-M34 yeniden doğrulanmalı |
| M42 üçüncü parti AV göremez | Yalnızca Windows Defender okunabilir; diğerlerinde `N/A` |
| M43 referans listesi boş gelir | SU listesi her ay değişir; araca gömülürse birkaç ay içinde yanlış bilgi verir |
| Edge sunucular org uç noktasından sorgulanamaz | İlgili modüller Edge'i kapsam dışı bırakır |
| Kuyruk bir **anlık görüntüdür** | Tek ölçüm yanıltır; M13 ve `-CompareWith` ile birlikte okuyun |
| `TIMEOUT` "iş durduruldu" demek **değildir** | `PowerShell.Stop()` senkrondur ve yerel kodda çalışan bir işi durduramaz; yürütücü işi **terk eder**. Hücre "terk edildi, arka planda sürüyor olabilir" demektir. Sıra beklerken zaman aşan işler de aynı sayaca düşer, ikisi ayırt edilemez. Terk sayısı `CORE / Terk edilen is` satırı olarak rapora yazılır |
| Uzun süren ham log okuması **kesilebilir** | Gerçek sınır, ayrıştırıcıya verilen kooperatif bütçedir (900 sn'lik görev timeout'una karşı 840 sn). Bütçe dolunca kısmi sonuç döner: M10/M11 satırı en az `WARN` olur, notta "PENCERE KISMI" yazar ve kanıt CSV'sinde hangi dosyaların işlendiği görünür. Kesilmiş bir pencereden hesaplanan persentil yanlış sunucuyu suçlar — pencereyi daraltın |
