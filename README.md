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

Ham tracking log okuma (`-LogAccess Smb`) yönetim paylaşımına (`\\sunucu\D$`) erişim ister. Erişim yoksa araç sessizce `Get-MessageTrackingLog`'a düşer ve bunu raporda `via=cmdlet` olarak belirtir.

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
| `-VerifyParser` | Ham ayrıştırıcıyı `Get-MessageTrackingLog`'a karşı doğrular (%1 tolerans) |
| `-CompareWith <klasör>` | Önceki çalıştırmayla delta |
| `-Parallelism <n>` | Eşzamanlılık (throttling tavanından türetilir) |
| `-Credential` | Alternatif kimlik |
| `-OutputRoot <yol>` | Çıktı kökü |
| `-Quiet` | Yalnızca uyarı ve hataları yazdırır |

**Çıkış kodları:** `0` temiz · `1` WARN/ERROR/TIMEOUT · `2` FAIL

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
| M14 | Transport kuyrukları |
| M15 | Back pressure |
| M16 | Transport eşzamanlılık ayarları |

### Faz C — store ve depolama
| ID | Ne bakar |
|---|---|
| M20 | Store RPC latency — **örgü P4** |
| M21 | Disk latency (`_Total` değil, en kötü volume) |
| M22 | DB → volume haritası — **örgü P5** |
| M23 | Ağır kullanıcılar + yorum tablosu |
| M24 | Büyük klasörler (kanıtı takip eder, körlemesine taramaz) |
| M25 | DB boyutu ve birim kapasitesi |
| M26 | İçerik indeksi (DAG gerektirmez) |

### Faz D — DAG ve replikasyon
| ID | Ne bakar |
|---|---|
| M30 | Kopya durumu |
| M31 | Kopya ve replay kuyrukları (ikisi **ayrı** şeylerdir) |
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

| | Örgü | Anlamı |
|---|---|---|
| **P1** | Bir sunucu belirgin yavaş | Kıyas tablosunda tek sütun sapar |
| **P2** | Store fazı baskın | Darboğaz transport değil store tarafında |
| **P3** | Gecikme belirli DB'lerde yoğunlaşıyor | Kök neden DB seviyesinde |
| **P4** | Yüksek RPC + **sağlıklı** disk + boş kuyruk | Suçlu store; disk değiştirmek işe yaramaz |
| **P5** | Paylaşılan volume + yavaş disk | Komşu DB'ler birbirini etkiliyor |
| **P6** | Ortalama düşük, p99 yüksek | Ortalama kuyruğu gizliyor |
| **P7** | Yoğun saatte belirgin tepe | Kapasite / eşzamanlılık sınırı |
| **P8** | Aktif kopyalar `ActivationPreference` dışında | Failover sonrası dengelenmemiş |

Her örgü, iddia edildiğinde **hangi modülle sürdürüleceğini** de yazar.

---

## Yapılandırma

`Config\` klasörü yoksa araç `Config.sample\` içindeki değerleri kullanır ve bunu raporda belirtir.

```powershell
Copy-Item .\Config.sample .\Config -Recurse
```

| Dosya | İçerik |
|---|---|
| `environment.json` | Pencere, eşzamanlılık, log erişimi, pasif siteler, tarama sınırları |
| `thresholds.json` | Eşikler. **Hepsi öneridir** |
| `reference.json` | Üretici varsayılanları, sistem posta kutusu deseni, SU listesi, AV dışlama listesi |
| `profiles.json` | Ortam profilleri (`lab`, `production`) |
| `known-issues.json` | Bastırılan bulgular — **gerekçe ve son kullanma tarihi zorunlu** |

Dosyalar yorum satırı (`//`, `/* */`) kabul eder.

**Eşik yönü** ayrıca belirtilmez, iki sayı kendini anlatır:
- `warn < fail` → yüksek kötü (gecikme, kuyruk, CPU)
- `warn > fail` → düşük kötü (sertifika ömrü, boş disk)

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

Anonimleştirilmiş bir örnek rapor üretmek için (gerçek ortama hiç dokunmaz):

```powershell
.\Tests\New-SampleOutput.ps1
```

---

## `-CompareWith` delta motoru

Delta motorunun asıl işi fark hesaplamak değil, **hangi farkın anlamsız olduğunu söylemektir.**

Sessizce yanlış kıyas yapmanın dört yolu engellenir:

1. **Kapsam farkı.** Önceki çalıştırma 1 saatlik pencereyle, yenisi 24 saatlikse persentiller zaten farklı çıkar — bu bir değişim değil **ölçüm farkıdır**. Aynısı `-Heavy` ve log erişim yolu için de geçerli. Rapor bu durumda en üste `KIYAS GUVENILIR DEGIL` uyarısı basar. `run-meta.json` tam olarak bunun için yazılır.
2. **N/A sınırı.** "Ölçülemedi" ile "sıfır" aynı şey değildir. `N/A` → değer geçişi **iyileşme değildir**; yüzde hesaplanmaz.
3. **Küçük sayıda büyük yüzde.** `0.001 → 0.002` yüzde olarak %100 artıştır ama hiçbir şey ifade etmez. Mutlak taban altında yüzde gizlenir.
4. **Saat farkı.** Farklı saatlerde alınan iki ölçüm arasındaki fark gerilemeye değil **yüke** bağlı olabilir. Kıyasın amacı bu olduğu için engellenmez, ama hatırlatılır.

Kaybolan bir kontrol `KAYBOLDU` olarak işaretlenir ve açıkça *"sorunun geçtiği anlamına gelmez"* der — modül atlanmış olabilir.

---

## Testler

```powershell
# Salt okunurluk guvencesi - once bu
.\Tests\Assert-ReadOnly.ps1

# Modul ve motor testleri
Get-ChildItem .\Tests\Test-*.ps1 | ForEach-Object { & $_.FullName }
```

**`Assert-ReadOnly.ps1`** brief 1. ilkesinin otomatik güvencesidir. Tüm modüllerin ve çekirdeğin AST'sini tarar ve üç şey denetler: çağrılan komutların fiilleri, **Exchange'e gönderilen cmdlet adları**, ve modüllerin kendi oturum/iş parçacığı açmaması.

Grep değil AST kullanmasının sebebi şu: M32 düzeltme komutunu `'Move-ActiveMailboxDatabase ...'` diye **metin olarak** raporlar. Düz metin araması bunu ihlal sanar; AST metin sabitini komut çağrısından ayırır.

Şu an Exchange kanalından çağrılan **15 cmdlet'in tamamı `Get-` veya `Test-`** — asıl güvence bu listedir:

```
Get-DatabaseAvailabilityGroup   Get-MailboxTransportService   Get-ServerHealth
Get-ExchangeCertificate         Get-MessageTrackingLog        Get-StoreUsageStatistics
Get-ExchangeServer              Get-Queue                     Get-TransportService
Get-MailboxDatabase             Get-Recipient                 Test-ReplicationHealth
Get-MailboxDatabaseCopyStatus   Get-MailboxFolderStatistics   Test-ServiceHealth
```

| Suit | Kapsam |
|---|---|
| `Test-TrackingLogParser` | C# ayrıştırıcı: `#Fields:` eşlemesi, tırnaklı CSV, UTC, gecikme türetimi, performans |
| `Test-LatencyModules` | M10-M13 + sürüklenme tespiti |
| `Test-PerfModules` | M20-M22, örgü P4 ve P5 |
| `Test-StoreModules` | M23-M24, yorum tablosu |
| `Test-DagModules` | M30-M34 (sentetik DAG) |
| `Test-HealthModules` | M40-M45 |
| `Test-BaselineModules` | M04, M05, M25, M26 |
| `Test-CompareEngine` | Delta motoru ve kapsam koruması |

Toplam **392 test**. Testler gerçek sunucuya hiç sorgu göndermez: sahte yürütücü gerçek `ExchangeDiag.ExecResult` nesneleri üretir, sentetik tracking log'lar geçici klasöre yazılır.

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
