# Exchange Ortam Teşhis Aracı — Proje Brief

> Bu dosya, yazılacak teşhis script'i/programı için **tek kaynak spesifikasyondur**.
> Yeni bir oturuma başlarken bu dosyayı ilk olarak okut.

**Hedef:** Herhangi bir Exchange ortamındaki tüm sunucuları sırayla, modüler ve tekrarlanabilir şekilde tarayan; bulguları kanıtla raporlayan, **ortamdan bağımsız** bir araç.

**Kapsam:** Mail teslim gecikmesi teşhisi başta olmak üzere; sağlık, performans, replikasyon, güvenlik ve yapılandırma kontrolleri.

---

## 1. Neden bu araç

Exchange'de gecikme ve performans sorunları araştırılırken tekrar eden zorluklar:

- Ölçümler tek tek, elle, farklı zamanlarda alınır → **karşılaştırılabilir olmaz**
- **Ortalamalar kuyruğu gizler.** Sunucu ortalaması birkaç saniye çıkarken kullanıcı şikâyeti dakikalar olabilir. Ortalama yerine **persentil** gerekir
- Ölçüm çoğu zaman sakin saatte alınır, sorun yoğun saatte oluşur
- Bir bulgu (ör. yüksek RPC latency) elde edildiğinde, sağlıklı bir sunucuyla kıyaslamak için aynı ölçümü tekrar elle almak gerekir
- Farklı yöneticiler farklı komutlar/eşikler kullanır → bulgular tartışmalı kalır

Araç bunları çözer: **aynı ölçüm, tüm sunucularda, aynı anda, aynı formatta, tarihli arşivle.**

---

## 2. Desteklenecek ortamlar

Araç ortamı **kendi keşfetmeli**, hiçbir şey sabit kodlanmamalı.

| Boyut | Desteklenecek |
|---|---|
| Sürüm | Exchange 2016, 2019, **Subscription Edition (SE)** |
| Topoloji | Tek sunucu · tek DAG · çoklu DAG · DAG'sız çoklu sunucu |
| Site | Tek site · çoklu site · uzak DR sitesi (pasif-only) |
| Rol dağılımı | Mailbox, Edge Transport |
| Ortam tipi | Üretim · test/lab (profil ile davranış değişir) |

### Keşif mantığı

```powershell
Get-ExchangeServer                  # sunucular, site, sürüm, rol
Get-DatabaseAvailabilityGroup       # DAG var mı, üyeleri kim
Get-MailboxDatabase                 # DB'ler, kopyalar
Get-ADSite / Get-ExchangeServer.Site  # site topolojisi, DR tespiti
```

**DR/pasif-only site tespiti:** Bir sitedeki hiçbir sunucuda aktif (mounted) DB yoksa, o site "pasif" olarak işaretlenir. Bu sunucularda düşük iş yükü metrikleri **normaldir** — `FAIL` sayılmaz, rapora "pasif site" etiketiyle çıkar.

---

## 3. Yakalanması hedeflenen örüntüler

Araç bu tipik teşhis örüntülerini **otomatik olarak** yüzeye çıkarabilmeli. Geliştirme sırasında doğruluk testi olarak kullan.

| # | Örüntü | Anlamı |
|---|---|---|
| P1 | Bir sunucunun teslim gecikmesi diğerlerinden kat kat yüksek | Sunucuya özgü sorun; topoloji değil |
| P2 | Gecikme `DeliveryToMailbox` fazında yoğunlaşıyor | Darboğaz transport'ta değil, **Store tarafında** |
| P3 | Gecikmeli teslimlerin alıcıları belirli DB'lerde toplanıyor | Kök neden DB seviyesinde |
| P4 | Yüksek `RPC Average Latency` + **sağlıklı disk** + **düşük kuyruk** | Darboğaz depolamada değil, Store içinde |
| P5 | Bir DB'de tek bir ağır kullanıcı; komşu DB'de öne çıkan kullanıcı yok ama o da yavaş | Paylaşılan kaynak (aynı volume/LUN) üzerinden dolaylı etki |
| P6 | Ortalama düşük, p95/p99 çok yüksek | Sorun bir **tail** olayı — ortalamaya bakan kaçırır |
| P7 | Yoğun saatte tepe, sakin saatte normal | Kapasite/eşzamanlılık sınırı |
| P8 | Aktif kopyalar `ActivationPreference` dışında dağılmış | Failover sonrası dengelenmemiş yük |

---

## 4. Tasarım ilkeleri

1. **Salt okunur.** Hiçbir modül ortamı değiştirmez. Düzeltme öneren modüller komutu **metin olarak** raporlar, çalıştırmaz.
2. **Sıfır sabit kod.** Sunucu adı, DB adı, sürücü harfi, domain — hiçbiri script içinde geçmez. Hepsi keşif veya config.
3. **Modüler.** Her kontrol bağımsız bir modül; tek tek veya toplu çalışır (`-Module M10,M20`).
4. **Her modül kendi eşiğini bilir.** Çıktı ham veri değil, **yorumlanmış sonuç**: `OK` / `WARN` / `FAIL` / `N/A` + kanıt.
5. **Tüm sunucular, aynı anda.** Kıyas olmadan tek sunucu ölçümü anlamsız. Her modül tüm sunucuları döner, **yan yana** raporlar.
6. **Ortalama yasak, persentil zorunlu.** Süre/gecikme ölçen her yerde min / p50 / p90 / p95 / p99 / max.
7. **Zaman damgalı arşiv.** Her çalıştırma `output\yyyyMMdd-HHmmss\` altına yazılır → yoğun/sakin saat karşılaştırması mümkün olur.
8. **Baseline karşılaştırma.** `-CompareWith <klasör>` ile önceki çalıştırmaya göre delta.
9. **Her modülde timeout.** Yanıt vermeyen sunucu aracı kilitlemez; hücre `TIMEOUT` yazar.
10. **Maliyet bilinci.** Ağır modüller (geniş aralıklı log taramaları) `-Heavy` bayrağı arkasında, varsayılan kapalı.
11. **Kanıt sakla.** Her `WARN`/`FAIL` için ham veri CSV olarak diske yazılır; sonradan tartışılabilsin.
12. **Sürüm duyarlı.** Bir cmdlet/sayaç o sürümde yoksa modül `N/A` döner, hata vermez.
13. **Sıcak yol C#'ta, kabuk PowerShell'de.** Log ayrıştırma, persentil ve paralel yürütme C# çekirdekte; modüller kendi paralelliğini yönetmez, yürütücüye devreder. Bkz. Bölüm 14.

---

## 5. Yapılandırma

Tüm ortama özgü bilgi **config dosyalarında** tutulur; script'te değil.

### `Config\environment.json`

```jsonc
{
  "profile": "production",        // "production" | "lab"
  "discovery": "auto",            // "auto" | "manual"
  "servers": [],                  // boş = otomatik keşif; doluysa sadece bunlar
  "excludeServers": [],           // taranmayacaklar (ör. Edge)
  "passiveSites": [],             // boş = otomatik tespit
  "trackingWindowHours": 1,       // varsayılan log penceresi
  "parallelism": 4,               // eşzamanlı runspace sayısı — ⚠️ tavan 8, bkz. Bölüm 10
  "logAccess": "auto",            // "auto" | "smb" | "cmdlet" — bkz. Bölüm 14
  "maxRecipientLookups": 300,     // M12: sorgulanacak en fazla benzersiz alıcı
  "perfSampleCount": 20,          // M20/M21: kaç örnek (persentil için)
  "perfSampleIntervalSeconds": 1, // örnekler arası hedef aralık
  "maxFolderScans": 50            // M24: taranacak en fazla posta kutusu
}
```

> ⚠️ **`parallelism` keyfi büyütülemez.** Exchange throttling policy'sindeki `PowerShellMaxConcurrency` (varsayılan 18) kullanıcı başına eşzamanlı oturum sayısını sınırlar. Araç bu değeri okuyup kendi tavanını ona göre kısmalı; aksi halde kendi kendini boğar ve diğer yöneticilerin oturum açmasını engeller.

### `Config\thresholds.json`

Tüm eşikler tek yerde, ortama göre ayarlanabilir:

```jsonc
{
  "deliveryLatencyP95Sec":   { "warn": 60,  "fail": 300 },
  "rpcAverageLatencyMs":     { "warn": 50,  "fail": 100 },
  "diskSecPerWrite":         { "warn": 0.020, "fail": 0.050 },
  "diskSecPerRead":          { "warn": 0.020, "fail": 0.050 },
  "copyQueueLength":         { "warn": 10,  "fail": 50 },
  "replayQueueLength":       { "warn": 20,  "fail": 100 },
  "queueMessageCount":       { "warn": 100, "fail": 1000 },
  "folderItemCount":         { "warn": 50000, "fail": 100000 },
  "calendarItemCount":       { "warn": 5000,  "fail": 20000 },
  "certExpiryDays":          { "warn": 30,  "fail": 7 },
  "cpuPercent":              { "warn": 70,  "fail": 90 },
  "storeTimeInServerMs":     { "warn": 30000, "fail": 60000 }
}
```

### `Config\profiles.json`

Ortam tipine göre hangi kontrollerin **geçerli olmadığını** tanımlar:

```jsonc
{
  "lab": {
    "skipModules": ["M04", "M44"],        // sertifika, lisans
    "ignoreFindings": ["NoRecentBackup"]  // yedek almayan lab ortamları
  },
  "production": {
    "skipModules": [],
    "ignoreFindings": []
  }
}
```

### `Config\reference.json`

Sürüme duyarlı **referans** değerler. Eşik değildir; "üretici varsayılanı neydi" sorusunu cevaplar ve yalnızca bilgi amaçlıdır.

```jsonc
{
  // Exchange SE RTM (15.2.2562) üzerinde dokunulmamış kurulumdan doğrulandı
  "transportDefaults": {
    "MaxConcurrentMailboxDeliveries": 20,
    "MaxConcurrentMailboxSubmissions": 20,
    "MaxOutboundConnections": 1000,
    "MaxPerDomainOutboundConnections": 40
  },
  // Exchange'in kendi posta kutuları — adın herhangi bir yerinde aranır
  "systemMailboxPattern": "HealthMailbox|SystemMailbox\\{|…",
  "securityUpdates": {}   // M43'ün SU referans listesi
}
```

> **İlke:** Bir ayar bu tabloda yoksa araç o ayar hakkında varsayılan **iddiasında bulunmaz**. Yanlış bir "değiştirilmiş" etiketi, bulgunun tamamını tartışmalı hale getirir.

### `Config\known-issues.json`

Bilinen false positive'ler — kullanıcı kendi ortamına göre doldurur:

```jsonc
[
  {
    "module": "M40",
    "match": "SomeHealthSet\\SomeMonitor",
    "reason": "Üretici tarafında açık known issue",
    "expires": "2026-12-31"
  }
]
```

> **İlke:** Bir bulguyu bastırmak için **koda dokunmak gerekmesin.** `known-issues.json` yeterli olmalı, ve her bastırma bir **gerekçe** ve **son kullanma tarihi** taşımalı.

---

## 6. Modül listesi

Sıra teşhis mantığına göre: önce "ortam neye benziyor", sonra "neresi bozuk", sonra "neden bozuk".

### Faz A — Envanter ve temel sağlık

| ID | Modül | Ne bakar | Anahtar komutlar | Not |
|---|---|---|---|---|
| **M01** | Topoloji keşfi | Sunucu, site, rol, DAG, DB haritası | `Get-ExchangeServer`, `Get-DatabaseAvailabilityGroup` | Diğer tüm modüllerin girdisi |
| **M02** | Gerçek build | Kurulu CU/SU seviyesi | `(Get-Command ExSetup.exe).FileVersionInfo` **her sunucuda** | ⚠️ Bkz. Bölüm 10 |
| **M03** | Servis durumu | Zorunlu servisler ayakta mı | `Test-ServiceHealth` | Hepsi `Running` |
| **M04** | Sertifikalar | Süre, atanmış servisler, zincir | `Get-ExchangeCertificate` | Eşik: `certExpiryDays` |
| **M05** | OS / kaynak | CPU, RAM, pagefile, uptime, .NET sürümü | `Get-CimInstance`, perfmon | Eşik: `cpuPercent` |

### Faz B — Gecikme tespiti

| ID | Modül | Ne bakar | Anahtar komutlar | Örüntü |
|---|---|---|---|---|
| **M10** | Sunucu bazlı gecikme **persentili** | Hangi sunucu yavaş | `Get-MessageTrackingLog -EventId DELIVER` → `MessageLatency` | P1, P6 |
| **M11** | Faz kırılımı | Gecikme hangi aşamada | `network-message-id` üzerinden RECEIVE/DELIVER join'i — bkz. ↓ | P2 |
| **M12** | Gecikmeli teslimlerin hedef DB'leri | Gecikme belirli DB'lerde mi | Yavaş `DELIVER` → alıcılar → `Get-Recipient`.Database → grupla | P3 |
| **M13** | Saat bazlı dağılım | Yoğun saat korelasyonu | Tracking log → saat bazlı p95 | P7 |
| **M14** | Transport kuyrukları | Kuyruk derinliği, ertelenmiş mesajlar | `Get-Queue`, `Get-QueueDigest` | Eşik: `queueMessageCount` |
| **M15** | Back pressure | Kaynak baskısı olayları | Event 15004 / 15006 / 15007 | Herhangi biri = `FAIL` |
| **M16** | Transport ayarları | Teslim paralelliği ve limitler | `Get-MailboxTransportService`, `Get-TransportService` | `MaxConcurrentMailboxDeliveries` vb. |

#### M11 faz tanımı

Mesajlar `network-message-id` üzerinden birleştirilir ve gecikme üçe ayrılır:

```
gönderim (message-info)
     │  Ingress    — ağ / yukarı akış, çoğu zaman bizim dışımızda
Transport RECEIVE          ← MSGTRK*.LOG
     │  Transport  — kategorize + kuyruk
Mailbox RECEIVE            ← MSGTRKMD*.LOG
     │  Store      — DeliveryToMailbox
DELIVER                    ← MSGTRKMD*.LOG
```

**Store baskınsa** darboğaz transport'ta değil Store tarafındadır (örüntü P2) ve araştırma M20/M21/M22'ye kayar. **Transport baskınsa** M14 ve M16'ya.

Çok alıcılı mesajlar aynı `network-message-id` ile birden çok `DELIVER` satırı üretir: mesajın tamamlanma süresi için **en geç** `DELIVER`, giriş için **en erken** `RECEIVE` alınır.

### Faz C — Store ve veritabanı

| ID | Modül | Ne bakar | Anahtar komutlar | Örüntü |
|---|---|---|---|---|
| **M20** | Store RPC latency | Store içi bekleme | `MSExchangeIS Store(*)\RPC Average Latency` | P4 |
| **M21** | Disk latency | Depolama darboğazı | `Avg. Disk sec/Read`, `Avg. Disk sec/Write` | P4 |
| **M22** | DB → volume haritası | Hangi DB'ler diski paylaşıyor | `Get-MailboxDatabase` → `EdbFilePath`, `LogFolderPath` | **P5 testi** |
| **M23** | Ağır kullanıcılar | DB başına en yoğun tüketiciler | `Get-StoreUsageStatistics` | Yorum tablosu ↓ |
| **M24** | Büyük klasörler | Aşırı öğe sayısı | `Get-MailboxFolderStatistics` | Eşik: `folderItemCount` |
| **M25** | DB boyut / whitespace | Şişme, disk doluluğu | `Get-MailboxDatabase -Status` | — |
| **M26** | İçerik indeksi | Arama sağlığı | `Get-MailboxDatabaseCopyStatus` → `ContentIndexState` | ⚠️ Bkz. Bölüm 10 |

### Faz D — DAG ve replikasyon

> DAG yoksa bu fazın tamamı `N/A` döner — hata değil.

| ID | Modül | Ne bakar | Anahtar komutlar | Örüntü |
|---|---|---|---|---|
| **M30** | Kopya durumu | Tüm kopyaların sağlığı | `Get-MailboxDatabaseCopyStatus` | — |
| **M31** | Kuyruk uzunlukları | Replikasyon gecikmesi | `CopyQueueLength`, `ReplayQueueLength` | Eşik: config |
| **M32** | Aktif kopya dağılımı | Yük dengesi | Aktif DB / sunucu + `ActivationPreference` | **P8** |
| **M33** | Replikasyon sağlığı | Kapsamlı test | `Test-ReplicationHealth` | Hepsi `Passed` |
| **M34** | Siteler arası log trafiği | Uzak siteye giden log hacmi | Log üretim hızı + uzak site kuyruk uzunluğu | WAN darboğazı |

### Faz E — İzleme, güvenlik, yapılandırma

| ID | Modül | Ne bakar | Anahtar komutlar | Not |
|---|---|---|---|---|
| **M40** | Managed Availability | Sağlık setleri | `Get-ServerHealth`, `Get-HealthReport` | `known-issues.json` ile filtrelenir |
| **M41** | Event log taraması | Son 24 saat hata/uyarı | Application + System, ilk N | Gürültü filtresi şart |
| **M42** | AV dışlamaları | Üreticinin önerdiği listeye uyum | Exclusion listesi karşılaştırması | Yol/işlem/uzantı |
| **M43** | Yama durumu | Kaç güncelleme geride | M02 build vs referans SU listesi | Referans liste config'de, güncellenebilir |
| **M44** | Lisans / aktivasyon | Sürüm, aktivasyon, süre | `Get-CimInstance SoftwareLicensingProduct` | Eval ortamlarda süre uyarısı |
| **M45** | Yedekleme durumu | Son başarılı yedek | `Get-MailboxDatabase` → `LastFullBackup` | Lab profilinde bastırılabilir |

---

## 7. `Get-StoreUsageStatistics` yorum tablosu

Modül M23 bu tabloyu uygulamalı — ham sayı değil, **teşhis** üretsin:

| Gözlem | Anlamı | Sonraki adım |
|---|---|---|
| `TimeInServer` ≫ `TimeInCPU` | Mailbox **bekliyor** — kilit çekişmesi veya I/O | M21, M22 |
| `TimeInServer` ≈ `TimeInCPU` | Gerçekten CPU yakıyor — ağır sorgu/arama | M24 |
| Yüksek `ROPCount` | Geveze istemci — döngüdeki uygulama veya hatalı profil | `ClientType` incele |
| Yüksek `PageRead` | Büyük taramalar — devasa klasör, çok öğe | M24 |
| Yüksek `LogRecordCount` | Ağır yazma — toplu taşıma, arşivleme, döngüdeki uygulama | `Get-MoveRequest`, mesaj hacmi |

**Birimler:** `TimeInServer` ve `TimeInCPU` **milisaniyedir**. 50.000 = 50 saniye.

**Kural:** Mutlak eşikten çok, **sağlıklı bir DB ile göreli kıyas** anlamlıdır. Rapor her zaman en sağlıklı DB'yi referans sütun olarak göstersin.

### Göreli kıyas nasıl uygulanır

- **Bekleme oranı** `TimeInServer / TimeInCPU`: **≥5** → "bekliyor", **≤2** → "CPU yakıyor". Arada kalan bölge için hüküm verilmez.
- **"Yüksek"** (ROPCount / PageRead / LogRecordCount): ortamın **kendi ortancasının ≥10 katı**. Sabit bir sayı değil — bir ortamda 5.000 ROP normal, başka bir ortamda felakettir.
- ⚠️ **Ortanca sıfırsa o metrik için hüküm verilmez.** Sıfırın on katı yine sıfırdır; oradan "geveze istemci" çıkarmak uydurma olur.
- Digest birden çok örnek (`SampleId`) içerir; her metriğin **en yüksek** gözlemi alınır. Ortalama almak tepe anını gizlerdi.
- Örüntüler birbirini dışlamaz: bir posta kutusu aynı anda hem "CPU yakıyor" hem "geveze istemci" olabilir ve ikisi de raporlanır.

---

## 8. Çıktı formatı

```
ExchangeDiag\
├─ 00-PROJE-BRIEF.md           ← bu dosya
├─ README.md                   ← kurulum, gereksinimler, hızlı başlangıç
├─ Invoke-ExchangeDiag.ps1     ← ana giriş
├─ Core\                       ← C# çekirdek, çalışma anında derlenir (Bölüm 14)
│   ├─ CoreLoader.ps1          ← derleme + hash cache + tip guard
│   ├─ TrackingLogParser.cs
│   ├─ PercentileEngine.cs
│   ├─ ParallelExecutor.cs
│   ├─ Config.ps1 · Connect.ps1 · Framework.ps1 · Report.ps1
│   ├─ TrackingLog.ps1         ← SMB/cmdlet erişim katmanı
│   └─ PerfCounter.ps1         ← sayaç örnekleme + volume envanteri
├─ Modules\
│   ├─ M01-Topology.ps1
│   ├─ M10-LatencyPercentile.ps1
│   └─ ...
├─ Config\
│   ├─ environment.json
│   ├─ thresholds.json
│   ├─ profiles.json
│   ├─ reference.json
│   └─ known-issues.json
├─ Config.sample\              ← repoda örnek config; gerçekler .gitignore'da
├─ Tests\                      ← yalnızca geliştirme; teslimat için gerekmez
│   ├─ ExchangeDiag.Core.Tests.csproj
│   ├─ fixtures\               ← sentetik MSGTRK*.LOG
│   └─ Assert-ReadOnly.ps1     ← salt okunurluk AST lint'i
└─ output\                     ← .gitignore
    └─ 20260917-143000\
        ├─ SUMMARY.html        ← renkli özet, sunucular yan yana
        ├─ SUMMARY.csv
        ├─ M10-latency.csv     ← ham kanıt
        └─ run.log             ← modül başına süre ölçümü dahil
```

> ⚠️ **`output\` ve gerçek `Config\` dosyaları `.gitignore`'a girmeli.** Çıktı sunucu adı, kullanıcı adı ve mailbox bilgisi içerir — repoya gitmemeli.

### Özet tablo şekli

Her modül tüm sunucular için tek satır üretir:

```
Modül  Kontrol               MBX01   MBX02   MBX03    MBX04   Durum
M10    Teslim p95 (sn)       2.1     1.8     287.4    31.2    FAIL
M20    RPC Avg Latency (ms)  12      9       180      44      FAIL
M21    Disk sec/Write        0.003   0.002   0.004    0.003   OK
```

**Sapan hücre vurgulu.** Rapor ilk bakışta "hangi sunucu farklı" sorusunu cevaplamalı.

---

## 9. Çalıştırma senaryoları

| Senaryo | Komut | Amaç |
|---|---|---|
| Hızlı sağlık | `.\Invoke-ExchangeDiag.ps1 -Quick` | Faz A + D |
| Gecikme avı | `.\Invoke-ExchangeDiag.ps1 -Module M10,M11,M12,M13,M20,M21,M22,M23 -Heavy` | Asıl teşhis |
| Tam tarama | `.\Invoke-ExchangeDiag.ps1 -All -Heavy` | Periyodik |
| **Yoğun saat** | Zamanlanmış görev, iş saatleri içinde birkaç kez | ⚠️ Sakin saat ölçümü yanıltır |
| Karşılaştırma | `-CompareWith .\output\<önceki>` | Sakin vs yoğun delta |
| Tek sunucu | `-Server <ad>` | Derin inceleme |
| Kuru çalıştırma | `-ListModules` | Hangi modüller bu ortamda geçerli |
| Log erişim modu | `-LogAccess Auto\|Smb\|Cmdlet` | Ham dosya okuma vs cmdlet (Bölüm 14) |
| Parser doğrulama | `-VerifyParser` | Ham parse sonucunu cmdlet'e karşı doğrular |

---

## 10. Dikkat edilecekler

Bunlar **sürümden bağımsız, tekrar tekrar yanlış yapılan** noktalar. Modüller bunlara uymak zorunda.

- ⚠️ **Build kontrolü:** Yalnızca `ExSetup.exe` dosya sürümüne güven. Exchange güvenlik güncellemeleri `Get-ExchangeServer`'ın `AdminDisplayVersion` değerini ve Setup registry anahtarındaki `MsiBuildMinor` değerini **güncellemez** — ikisi de CU/RTM taban sürümünü göstermeye devam eder ve güncelleme başarısız olmuş gibi görünür.
  > Geliştirme ortamında ölçülen canlı örnek: `ExSetup.exe` **15.02.2562.049** iken `AdminDisplayVersion` "Build 2562.**17**", `MsiBuildMinor` ise **17**. SU kurulu olduğu hâlde diğer iki kaynak bunu görmüyor.

- ⚠️ **Exchange uzak yönetim uç noktası `NoLanguage` modundadır.** Oraya script metni gönderilemez — `AddScript()` "The syntax is not supported by this runspace" hatası verir. Yalnızca **komut + parametre** gönderilebilir (`AddCommand`). Dahası uç noktada `Where-Object`, `Sort-Object`, `ForEach-Object`, `Group-Object`, `Get-Content` **yoktur**; `Select-Object` ve `Measure-Object` vardır. Sonuç: filtreleme ve gruplama **yerel tarafta** yapılır, ama alan daraltması (`Select-Object`) sunucu tarafında yapılmalıdır — Exchange nesneleri büyüktür ve hepsini tel üzerinden taşımak CliXml serileştirmesinde pahalıya patlar. Makine seviyesindeki her şey (CIM, perf sayaç, registry, dosya okuma) ayrı bir **yerel tam dilli havuzdan** yapılır.

- ⚠️ **`MessageLatency` bir `TimeSpan`'dır.** (Cmdlet yolu için geçerli.) Doğrudan `Measure-Object -Property TotalSeconds` çalışmaz. Dönüşüm:
  ```powershell
  ([TimeSpan]$_.MessageLatency).TotalSeconds
  ```

- ⚠️ **`MessageLatency` log dosyasında bir kolon DEĞİLDİR.** Cmdlet onu hesaplayarak üretir. Ham dosya okuyan parser, `DELIVER` satırının `message-info` alanının başındaki gönderim zaman damgası ile `date-time` farkını alarak aynı değeri yeniden türetmek zorundadır; `MessageLatencyType` (Local / Original / End2End) ayrımı da korunmalıdır. Türetim doğrulanmadan kullanılmaz — bkz. `-VerifyParser`.

- ⚠️ **Tracking log dosya adı, hangi verinin nerede olduğunu belirler.** `DELIVER` olayları Transport log'unda değil, **`MSGTRKMD*.LOG`** (Mailbox Transport Delivery) dosyalarındadır. `MSGTRKMS*` submission, düz `MSGTRK*` ise Transport service'e aittir. Yanlış dosya kümesini taramak "veri yok" sonucu verir.

- ⚠️ **Tracking log'daki `date-time` UTC'dir.** Yerel saate çevrilmeden saat bazlı dağılım (M13) üretilirse yoğun saat korelasyonu kayar. Rapor başlığında kullanılan saat dilimi açıkça yazılmalı.

- ⚠️ **`MessageLatency` uçtan uca süredir.** Faz kırılımı (`DeliveryToMailbox` vb.) ayrı bir hesaplamadır; M11'in tek sorumluluğu budur — aynı `network-message-id` üzerinden RECEIVE → SUBMIT → DELIVER olaylarının join'lenmesiyle çıkarılır.

- ⚠️ **Sürüm ≠ ürün.** Bazı Exchange sürümleri aynı build numarasını paylaşır. Ürün kimliğini **Uninstall registry anahtarındaki `DisplayName`** ile doğrula, build numarasına bakarak karar verme.

- ⚠️ **Pasif/DR sitelerinde aktif DB ve kullanıcı yoktur.** Düşük iş yükü metrikleri normaldir — `FAIL` sayma, "pasif site" etiketiyle raporla.

- ⚠️ **`ContentIndexState: NotApplicable`** DAG'sız / tek kopyalı ortamlarda normaldir.

- ⚠️ **Ağır cmdlet'ler üretimi etkiler.** `Get-MessageTrackingLog` geniş aralıkta pahalıdır. `-Heavy` arkasında tut, varsayılan pencereyi kısa bırak, sunucu başına timeout uygula.

- ⚠️ **Yedek kontrolü her ortamda geçerli değil.** Bazı ortamlar bilinçli olarak yedek almaz (snapshot tabanlı lab'ler). Profil ile bastırılabilir olmalı.

- ⚠️ **Circular logging açıkken** `LastFullBackup` boş kalır — bu tek başına bulgu değildir.

- ⚠️ **Ortalama rapor etme.** Tek bir ortalama sayı, tail'i gizleyerek sorunun varlığını inkâr ettirir. Her süre metriği en az p50/p95/p99 ile raporlanmalı.

- ⚠️ **Faz kırılımında sunucular arası saat kayması.** M11'in `Transport` fazı iki farklı sunucudaki olayın farkıdır (Transport RECEIVE ↔ Mailbox RECEIVE). Sunucu saatleri kaymışsa bu fark **negatif** çıkar. Negatif değer sıfıra kırpılmaz — kırpmak kaymayı gerçek bir ölçüm gibi gösterir. Örnek atılır, sayısı raporlanır; sayı yüksekse bulgu zaman senkronizasyonudur, Exchange değil.

- ⚠️ **Faz kırılımı cmdlet yoluyla yapılamaz.** `MSGTRK` + `MSGTRKMD` birleştirmesi tüm olayları gerektirir; `Get-MessageTrackingLog` ile bunu çekmek üretim ortamında kabul edilemez. M11 yalnızca ham log erişimiyle çalışır, erişim yoksa **temiz `N/A`** döner ve gerekçesini yazar.

- ⚠️ **M12'nin maliyeti alıcı sayısıyla artar.** Her benzersiz yavaş alıcı için bir `Get-Recipient` çağrısı gerekir. Aramalar en çok gecikme yaşayan alıcıdan başlar ve `maxRecipientLookups` (varsayılan 300) ile sınırlanır. **Kapsam oranı rapora yazılmalıdır** — %100'e ulaşmayan bir örneklemi tam tarama gibi sunmak, yoğunlaşma iddiasını dayanaksız bırakır. Tek DB'li ortamda "hepsi aynı DB'de" bir yoğunlaşma kanıtı değildir; araç bunu ayrıca belirtir.

- ⚠️ **Exchange'in kendi sistem posta kutuları "ağır kullanıcı" sanılmamalıdır.** `HealthMailbox`, `SystemMailbox{…}`, `DiscoverySearchMailbox{…}`, `Migration.*`, `FederatedEmail.*` — bunlar Exchange'in kendi trafiğidir ve kullanıcı şikâyetiyle karıştırılmamalıdır. **Desen adın başında değil, herhangi bir yerinde aranmalıdır:** arşiv posta kutusu `In-Place Archive -HealthMailbox-…` biçiminde gelir ve baş-eşlemesi onu gerçek kullanıcı sanar. Geliştirme sırasında bu hatanın canlı örneği görüldü — araç en ağır kullanıcı olarak bir arşiv HealthMailbox'ını gösteriyordu. Desen `Config\reference.json` → `systemMailboxPattern`'dedir; sistem kutuları kanıt dosyasında kalır, özet satırından çıkarılır.

- ⚠️ **M24 tüm posta kutularını taramaz, kanıtı takip eder.** `Get-MailboxFolderStatistics` her posta kutusu için ayrı bir çağrıdır ve büyük kutularda saniyeler sürer; hiçbir dil bunu hızlandırmaz. Tek doğru cevap **kapsamı daraltmaktır**: adaylar M23'ün ağır kullanıcılarından ve M12'nin yavaş teslim alıcılarından gelir, `maxFolderScans` ile sınırlanır. **Kapsam oranı her zaman raporlanmalıdır** — kısıtlı bir örneklemi tam tarama gibi sunmak, "büyük klasör yok" hükmünü dayanaksız bırakır.

- ⚠️ **Perf sayacı yolları işletim sistemi diline göre yerelleşir.** Türkçe bir sunucuda `\LogicalDisk(*)\Avg. Disk sec/Read` **bulunamaz**. `Win32_PerfFormattedData_*` sınıflarının özellik adları ise dil-nötrdür (`AvgDisksecPerRead` her yerde aynı). Araç "ortamdan bağımsız" olacaksa sayaçlara **CIM üzerinden** erişmelidir. Exchange'in kendi sayaçları İngilizce kalır, ama OS sayaçları kalmaz — ikisini aynı mekanizmayla okumak bu tuzağı tamamen kapatır.

- ⚠️ **Hesaplanmış (cooked) sayaçların ilk örneği atılmalıdır.** Bu sayaçlar iki örnek arasındaki farktan üretilir; ilk sorgu çoğu zaman `0` döner. Bu sıfırı gerçek ölçüm saymak "disk mükemmel" gibi yanlış bir sonuç üretir.

- ⚠️ **Örnekleme aralığından sorgu süresini düşün.** Sorgu 0,8 sn sürüyorsa ve aralık 1 sn ise, `Start-Sleep 1` gerçek aralığı 1,8 sn yapar ve toplam süre sessizce ikiye katlanır. Ölçülen örnek: 20 örnek × 1 sn hedefi **37,3 sn** sürüyordu; sorgu süresi düşülünce **21 sn**'ye indi. Ulaşılan gerçek aralık hedefin belirgin üstündeyse bu **raporlanmalıdır** — kadans gizlenmez.

- ⚠️ **Disk latency'de `_Total` raporlanmaz, EN KÖTÜ volume raporlanır.** Sekiz volume'un yedisi sağlıklı biri boğulmuşsa `_Total` sağlıklı görünür ve tek bozuk LUN kaybolur. Ortalamanın tail'i gizlemesiyle aynı hata, yalnızca bir boyut aşağıda. Testte ölçülen: `_Total` yazma 0,018 sn (eşiğin altında, "OK") iken gerçek bozuk volume 0,070 sn (FAIL).

- ⚠️ **Yol → volume eşlemesi en uzun önek ile yapılır.** Sürücü harfine bakmak yetmez: bağlama noktaları (mount point) yüzünden `C:\ExchangeVolumes\Vol1` ile `C:\` **farklı diskler** olabilir. Sürücü harfine göre eşleştirmek hepsini aynı volume sanmaya ve sahte bir "paylaşılan kaynak" bulgusuna yol açar.

- ⚠️ **Saat bazlı dağılım geniş pencere ister.** Varsayılan 1 saatlik pencerede "yoğun saat" diye bir şey yoktur. M13, **en az 6 farklı saatte 20+ teslim** görmeden tepe saat iddia etmez — üç saatin en yükseğiyle en düşüğünü kıyaslayıp "yoğun saat" demek gürültüyü eğri sanmaktır. Yetersiz örneklemde `N/A` döner ve `-WindowHours` önerir.

- ⚠️ **Üretici varsayılanları sürümler arasında değişir.** "Bu ayar değiştirilmiş" demek için elde doğrulanmış bir referans olmalı; yoksa araç **hiçbir iddiada bulunmamalıdır**. Geliştirme sırasında bu hatanın canlı örneği görüldü: hafızadan yazılan varsayılan tablo, hiç dokunulmamış bir SE kurulumuna "değiştirilmiş" etiketi bastı. Referans değerler `Config\reference.json`'a taşındı ve ifade "referans varsayılan X, bu ortamda Y — farklı olması tek başına hata değildir" şeklinde düzeltildi.

- ⚠️ **Kuyruk derinliği anlık bir ölçümdür.** `Get-Queue` tarama anındaki fotoğrafı verir. Sakin saatte boş görünen bir kuyruk yoğun saatte dolup boşalıyor olabilir; M14 tek başına değil M13 ile birlikte okunmalıdır. Ayrıca **gölge (shadow) kuyruklar DAG'da normalde doludur** ve toplam derinliğe katılırsa yanlış alarm üretir.

- ⚠️ **Back pressure sırasında kuyruklar BOŞ görünür.** Mesajlar reddedildiği için kuyruğa hiç alınmamıştır. "Kuyruk boş, demek ki transport iyi" çıkarımı bu yüzden yanlıştır — M14 ve M15 birlikte okunmalıdır.

- ⚠️ **Eşzamanlılık Exchange tarafında sınırlıdır.** Throttling policy'deki `PowerShellMaxConcurrency` (varsayılan 18) aşılırsa yeni oturumlar reddedilir ve araç hem kendini hem diğer yöneticileri kilitler. `parallelism` tavanı bu değerden türetilmeli, sabit büyük bir sayı verilmemeli.

- ⚠️ **`N/A` ve `PASSIVE` birer hüküm değildir**, satır özetini ele geçirmemelidirler. Bir satırda üç sunucudan biri ölçülemediyse (`N/A`) veya pasif sitedeyse (`PASSIVE`), satır başlığı yine de diğer ikisinin gerçek hükmünü göstermelidir. Aksi halde **çalışmış ve geçmiş bir kontrol, hiç çalışmamış gibi görünür.** Kural: gerçek bir hüküm (`OK`/`WARN`/`FAIL`/`TIMEOUT`/`ERROR`) varsa o kazanır; hiçbiri yoksa satır gerçekten ölçülememiştir ve `N/A` döner.
  > **Canlı örnek:** M32'de DR sitesindeki sunucu `PASSIVE` işaretlendiği için, denge kontrolü çalışıp *geçmiş* olmasına rağmen satır başlığı `PASSIVE` çıkıyordu. Faz D testleriyle yakalandı.

- ⚠️ **`Get-ServerHealth`'te hüküm `AlertValue`'dadır, `CurrentHealthSetState` değil.** Bu ikisi farklı şeylerdir ve karıştırılması sessiz bir felakete yol açar.
  > **Canlı örnek:** `CurrentHealthSetState = NotApplicable`'ı "bu monitör geçerli değil" diye yorumlamıştım. Gerçekte bu ortamda **1514 monitörün 1498'i `AlertValue = Healthy` + `CurrentHealthSetState = NotApplicable`** geliyor. Sonuç: 1498 sağlıklı monitör "geçerli değil" sayıldı, kanıt dosyası 1514 satıra şişti ve sunucu hakkında hiçbir hüküm verilemedi. Doğrusu: `AlertValue` hükümdür; `NotApplicable` yalnızca **`Disabled` bir monitörün neden kapalı olduğunu** açıklarken anlam taşır.

- ⚠️ **`[ordered]@{}` içinde TAMSAYI anahtar KONUM demektir, anahtar değil.** `$map[16]`, yedi elemanlı bir `OrderedDictionary`'de **16. öğeyi** arar ve `Index was out of range` verir. Bayrak (flags) enum haritaları gibi tamsayı anahtarlı tablolar **düz `@{}` hashtable** olmalıdır.
  > **Canlı örnek:** M04'ün `AllowedServices` bayrak tablosu `[ordered]` yazıldığı için ilk çalıştırmada `ERROR` verdi.

- ⚠️ **Uzak oturumda enum değerleri TAMSAYIYA döner.** Canlı ortamda doğrulandı: `Get-ExchangeCertificate` → `Services = 27`, `Status = 1`, `RootCAType = 3`. Enum adları serileştirmede kaybolur. Çözümleme araç tarafında yapılmalı, **ham sayı da kanıt dosyasına yazılmalıdır** ki çözümleme yanlışsa denetlenebilsin. Tanınmayan bir bit sessizce yutulmaz, `bilinmeyen(N)` olarak yazılır.

- ⚠️ **`ByteQuantifiedSize` uzak oturumdan METİN gelir: `"247.9 MB (259,981,312 bytes)"`.** Baştaki kısım **yuvarlanmış ve kayıplıdır**; hesapta yalnızca parantez içindeki bayt sayısı kullanılır. Binlik ayracı **kültüre göre değişir** (`259,981,312` / `259.981.312`), bu yüzden ayraç yorumlanmaz — rakam dışı her karakter atılır. Bkz. `ConvertFrom-EDByteQuantified`.

- ⚠️ **Whitespace (`AvailableNewMailboxSpace`) bir hata DEĞİLDİR ve M25 ona eşik uygulamaz.** Veritabanı dosyası içindeki yeniden kullanılabilir alandır; Exchange yeni postaları oraya yazar. Çevrimdışı defrag (`eseutil /d`) rutin bir çözüm değildir. Gerçek bulgu başkadır: **veritabanı, bulunduğu birimdeki boş alandan büyükse** birim dolduğunda dismount olur ve teslim durur — ve bu iddia yalnızca M22'nin birim envanteri varken kurulur.

- ⚠️ **Bozuk içerik indeksi teslim gecikmesi YARATMAZ.** Doğrudan sonucu kullanıcının arama yapamamasıdır. Teslimle ilişkisi yalnızca dolaylıdır: indeks yeniden oluşturulurken (`Crawling`) CPU ve disk yükü artar; M05 ve M21'deki yüksek değerlerin sebebi bu olabilir. "İndeks bozuk, o yüzden posta gecikiyor" kısa devresi kurulmamalıdır. `NotApplicable` ise modern sürümlerde **normaldir** (bu lab tam olarak böyle döner).

- ⚠️ **Çalışma süresi bir hata ölçüsü değil, BAĞLAMDIR.** 20 dakika önce yeniden başlatılmış bir sunucuda kuyruğun dolu, gecikmenin yüksek olması normaldir — sistem hâlâ toparlanıyordur. M05 bunu bulgu olarak değil, **diğer tüm modüllerin bulguları okunurken dikkate alınması gereken bir uyarı** olarak raporlar.

- ⚠️ **M04'te yalnızca BİR SERVİSE ATANMIŞ sertifikalar hükme girer.** Bir sunucuda onlarca sertifika olabilir; atanmamış olanın süresi dolsa da posta akışını etkilemez ve uyarı üretmesi raporu kullanılmaz hale getirir. Ayrıca **kendinden imzalı olmak hata değildir** — Exchange iç transport için bunu tasarım gereği kullanır (bu lab'daki üç sertifikanın üçü de kendinden imzalı ve `Valid`).

- ⚠️ **Kaynak dosyalarda ASCII dışı karakter kullanılmaz.** Proje Türkçe çıktıyı kasıtlı olarak aksansız yazar (`gecikme`, `hukum`); yorumlardaki `⚠️` dışında `ı ö ü ş ğ ç` kaçakları konsolda mojibake üretir (`oranı` → `oranÄ±`). Faz C/E eklenirken beş dosyada bu kaçak oluştu ve temizlendi.

- ⚠️ **`Config.Reference` bir `OrderedDictionary`'dir; `ContainsKey()` metodu YOKTUR.** `[ordered]@{}` bir `Hashtable` değildir. Her ikisinde de çalışan `IDictionary.Contains()` kullanılmalıdır. M42 bu yüzden `ERROR` verdi; aynı hata M43'te de sessizce duruyordu (başka bir dal önce dönüyordu diye fark edilmemişti).

- ⚠️ **PowerShell'de `[int]` YUVARLAR, kesmez.** Kalan süre, kalan gün, kalan alan gibi değerlerde bu **olduğundan iyimser** bir tablo çizer. `[int]85.9` → `86`. Kalan süre her zaman `[math]::Floor` ile aşağı yuvarlanmalıdır.
  > **Canlı örnek:** M44, 85.9 günlük deneme süresini "86 gün" gösteriyordu.

- ⚠️ **"Gürültü" ile "bulgu" arasındaki çizgi orana göre çekilir, sayıya göre değil.** Kapatılmış tek bir monitör için tüm çalıştırmayı `WARN`'a çıkarmak raporu kullanılmaz hale getirir; ama izlemenin **%10'undan fazlası** kapalıysa "sağlıklı" hükmünün kendisi dayanaksızdır ve bu söylenmelidir. Aynı mantık M41'de de geçerlidir: olay sayısının yüksek olması tek başına hata değildir, ama **depolama kaynaklı** tek bir hata bile M21/M22 ile birlikte okunmalıdır.

- ⚠️ **M42 üçüncü parti antivirüsü GÖREMEZ.** Yalnızca Windows Defender okunabilir. Defender yoksa modül `N/A` döner ve **"dışlama yok" DEMEZ** — böyle bir iddia yanlış olurdu. Ayrıca Defender gerçek zamanlı koruması kapalıysa eksik dışlama zararsızdır ve bu ayrıca belirtilir.

- ⚠️ **M45'in zinciri yalnızca dairesel günlükleme KAPALIYKEN kurulur.** "Yedek yok → günlükler kesilmez → birim dolar → veritabanı dismount olur → teslim durur" zinciri gerçektir, ama dairesel günlükleme açıksa günlükler zaten kesilir ve **günlük büyümesi iddiası yapılamaz**. Ayrıca `LastFullBackup` boş olması yedek alınmadığını kanıtlamaz: VSS dışı bir çözüm (dosya seviyesi veya VM anlık görüntüsü) Exchange'e kendini bildirmez.

- ⚠️ **Faz D'nin doğruluğu tek sunuculu bir lab'da kanıtlanamaz.** DAG yokken modüllerin temiz `N/A` dönmesi yalnızca *zarif bozulmayı* gösterir, mantığın doğru olduğunu **göstermez**. Bu yüzden kopya envanteri `Context.Cache['CopyStatus']` üzerinden, `Test-ReplicationHealth` ise sahte yürütücüden sentetik olarak beslenir (`Tests\Test-DagModules.ps1`). Gerçek bir DAG'a erişildiğinde M30-M34 yeniden doğrulanmalıdır.

---

## 11. Geliştirme sırası

1. **Çekirdek iskelet** — `Core\CoreLoader.ps1` (derleme + cache), `ParallelExecutor.cs`, `Invoke-ExchangeDiag.ps1` parametre yüzeyi, config okuyucu, zaman damgalı çıktı klasörü
2. **M01** — topoloji keşfi. Diğer her şeyin girdisi; en kritik modül
3. **M02, M03** — basit modüller, iskeleti doğrular
4. **`TrackingLogParser.cs` + `PercentileEngine.cs`** — sentetik fixture'lara karşı birim testleri **önce** yazılır
5. ✅ **M10 + M11 + M12** — persentil, faz kırılımı, DB eşlemesi. **En yüksek teşhis değerine sahip modüller.** `-VerifyParser` burada devreye girer
   > Mantık sentetik fixture'lara karşı doğrulandı (`Tests\Test-LatencyModules.ps1`). Ham ayrıştırıcının `Get-MessageTrackingLog` ile **aynı** sonucu ürettiği ise ancak gerçek bir ortamda `-VerifyParser` ile gösterilebilir — o çalışana kadar gecikme türetimi doğrulanmış sayılmaz.
6. ✅ **M13, M14, M15, M16** — saat dağılımı, kuyruklar, back pressure, transport ayarları
   > M13 M10'un önbelleğini kullanır, log yeniden okunmaz. M16'nın referans tablosu `Config\reference.json`'a taşındı.
7. ✅ **`Core\PerfCounter.ps1` + M20, M21, M22** — sayaç toplama + volume haritası (P5 testi)
   > `PerfCollector.cs` planlanmıştı, yazılmadı — gerekçe Bölüm 14'te. M20 ve M21 **tek bir örnekleme turunu paylaşır**; duvar saati ikiye katlanmaz.
8. ✅ **M23, M24** — store kullanıcı analizi + büyük klasör tespiti
   > M23 Bölüm 7'deki yorum tablosunu uygular ve **teşhis** üretir, ham sayı değil. M24 kanıtı takip eder: adaylarını M23 ve M12'den alır.
9. ✅ **Faz D (M30-M34)** — DAG yoksa temiz `N/A`
   > Bu lab'da DAG olmadığı için mantık **sentetik kopya envanteriyle** doğrulandı (54 test). Gerçek ortam doğrulaması hâlâ gereklidir; ayrıntı Bölüm 10'daki uyarıda.
10. ✅ **Faz E (M40-M45)** + `known-issues.json` filtresi
    > M40 ve M41 `known-issues.json` ile bastırma uygular. M43 ve M42 **referans listesi boşken hiçbir iddiada bulunmaz** (M16 disiplini). M44'ün özellik adları (`IsExchangeTrialEdition`, `RemainingTrialPeriod`) ve M45'inkiler (`LastFullBackup`, `CircularLoggingEnabled`) canlı ortamdan **doğrulanarak** yazıldı, tahmin edilmedi. 63 test.
11. ✅ **M04, M05, M25, M26** — brief Bölüm 6'da tanımlı olup atlanmış Faz A/C modülleri
    > M04'ün enum çözümlemesi ve M25'in bayt ayrıştırması canlı ortamdan **doğrulanarak** yazıldı. M25 ve M26, kasıtlı olarak **iddia etmeyi reddettikleri** şeylerle tanımlanır: whitespace'e eşik uygulanmaz, bozuk indeks teslimle ilişkilendirilmez. M05 çalışma süresini bulgu değil **bağlam** olarak raporlar. 65 test.
12. ✅ **HTML/CSV rapor + `-CompareWith` delta motoru**
    > Delta motorunun asıl işi fark hesaplamak değil, **hangi farkın anlamsız olduğunu söylemektir**: kapsam farkı (`run-meta.json`), `N/A` sınırı, küçük sayıda büyük yüzde, saat farkı. 50 test.
13. ~~Zamanlanmış görev + yoğun saat otomasyonu~~ — *kapsam dışı bırakıldı (kullanıcı kararı)*
14. ✅ **`Tests\Assert-ReadOnly.ps1`** — 1. ilkenin otomatik güvencesi
    > AST tarar (grep değil: M32 düzeltme komutunu **metin olarak** raporlar, düz arama yanlış alarm üretir). Exchange kanalından çağrılan **15 cmdlet'in tamamı `Get-`/`Test-`**. Yerleştirilmiş sahte bir `Set-TransportService` ile yakaladığı doğrulandı — her zaman geçen bir lint işe yaramaz.
15. ✅ **`README.md`, örnek çıktı, `Config.sample\`**
    > Örnek rapor `Tests\New-SampleOutput.ps1` ile **sentetik** üretilir — gerçek bir çalıştırmanın çıktısı sunucu ve posta kutusu adları taşıdığı için dağıtılamaz. Üretilen senaryo sekiz örgünün (P1-P8) tamamını içerir.

---

## 12. Yayınlama kontrol listesi

Repo halka açılmadan önce:

- [ ] Hiçbir dosyada gerçek sunucu/domain/kullanıcı adı yok
- [ ] `output\` ve gerçek `Config\` `.gitignore`'da
- [ ] `Config.sample\` altında anonim örnek config'ler var
- [ ] `README.md`: gereksinimler (Exchange Management Shell, yetkiler), kurulum, hızlı başlangıç, örnek çıktı ekran görüntüsü
- [ ] Salt okunur olduğu README'de açıkça yazıyor
- [ ] Lisans dosyası eklendi
- [ ] Desteklenen Exchange sürümleri belirtildi
- [ ] Eşiklerin öneri olduğu, ortama göre ayarlanması gerektiği not edildi

---

## 13. Yeni oturuma açılış cümlesi

> `00-PROJE-BRIEF.md` dosyasını oku. Bu spesifikasyona göre Exchange teşhis aracını yazacağız.
> Bölüm 11'deki sırayla ilerle, önce iskeletten başla.
> Ortama özgü hiçbir bilgiyi koda yazma — keşif veya config kullan.
> Mimari ve dil kararları Bölüm 14'te; sıcak yolu PowerShell'e geri çekme.

---

## 14. Mimari ve performans

### Neden hibrit

Araç saf PowerShell 5.1 ile yazılırsa kullanılamayacak kadar yavaş kalır. Yavaşlığın kaynağı dilin kendisi değil, üç somut nokta:

| Darboğaz | Neden | Çözüm |
|---|---|---|
| `Get-MessageTrackingLog` | Her satırı zengin nesneye deserialize eder, uzaktan çalışırsa üstüne CliXml serileştirmesi biner. ~2-10k satır/sn | Ham `MSGTRK*.LOG` dosyasını okuyup parse et: 500k-2M satır/sn |
| Sıralı yürütme | 45 modül × N sunucu, teker teker. PS 5.1'de `ForEach-Object -Parallel` yok | C# `ParallelExecutor` + paylaşılan runspace havuzu |
| Persentil matematiği | Milyonlarca `TimeSpan` üzerinde PS sıralama/gruplama | `double[]` + `Array.Sort` |

**Dil seçimi C#, çünkü:** Exchange yönetim cmdlet'lerinin desteklenen bir .NET API'si yoktur. Go/Rust seçilse bile sonunda PowerShell çağrılmak zorunda kalınır. C# ise `System.Management.Automation`'ı doğrudan host edip runspace havuzunu kendi yönetebilir.

### Katman dağılımı

| Katman | Dil | Gerekçe |
|---|---|---|
| CLI, config, modül kaydı, eşik değerlendirme, rapor yazımı | PowerShell | Okunabilir, müşteri tarafında düzenlenebilir, sık değişir |
| Tracking log parser, persentil, paralel yürütücü | C# | Sıcak yol |
| Perf sayacı örnekleme, volume envanteri | PowerShell | ↓ bkz. "Neden perf tarafında C# yok" |
| Cmdlet-only modüller (M03, M04, M25, M26, M30-M33, M40, M44, M45) | PowerShell scriptblock | Ucuz çağrılar; C# yürütücüde paralel koşarlar |

**Kritik kural:** Modüller kendileri `Invoke-Command` çağırmaz. Her modül *bildirir*: hedef sunucular + scriptblock + timeout. `ParallelExecutor` bunları tek bir paylaşılan havuzda, tek bir timeout politikasıyla koşturur.

### Teslimat ve derleme

Teslimat **`.ps1` dosyalarıdır** — imzasız `.exe` güven sorunu yoktur, tüm kaynak okunabilir ve denetlenebilir. C# çekirdek çalışma anında derlenir:

- `Core\*.cs` düz kaynak dosyaları olarak durur.
- `Core\CoreLoader.ps1` kaynakların SHA256'sını alır; `%LOCALAPPDATA%\ExchangeDiag\cache\<hash>.dll` varsa doğrudan yükler, yoksa `Add-Type -OutputAssembly` ile derleyip cache'ler. İlk çalıştırma ~1-2 sn, sonrası sıfır.
- Cache dizinine yazılamıyorsa (AppLocker / kısıtlı ortam) bellek içi derlemeye düşer.
- ⚠️ **Dil sürümü C# 5 ile sınırlıdır.** `Add-Type`, PS 5.1'de .NET Framework'ün `csc.exe`'sini kullanır. String interpolation, `?.`, `nameof`, tuple, pattern matching **kullanılamaz**. Generics, LINQ, `async/await`, `Parallel.ForEach` kullanılabilir.
- **.NET SDK ve xunit test projesi KURULMADI — bilinçli karar.** Planda `Tests\ExchangeDiag.Core.Tests.csproj` (`<LangVersion>5</LangVersion>`) öngörülmüştü; gerekçesi iki maddeydi ve ikisi de başka yoldan karşılandığı için vazgeçildi:
  - *C# 5 kısıtını derleme anında zorlamak:* `Add-Type` zaten .NET Framework `csc.exe`'sini kullanıyor. Ölçülerek doğrulandı — C# 6 string interpolation içeren bir kaynak `Unexpected character '$'` ile **reddedildi**. `CoreLoader` her SHA256 değişiminde yeniden derlediği için ihlal ilk test çalıştırmasında görünür. `LangVersion 5` bu garantiyi tekrarlar, eklemez.
  - *C# birim testleri:* Parser 44 testle sınanıyor ve bunlar **Add-Type'ın ürettiği gerçek assembly** üzerinden koşuyor — yani üretimde çalışan ikilinin ta kendisi. xunit ayrı bir derleme çıktısını test ederdi; mevcut düzen bu açıdan daha yakındır.
  - Teslimat zaten SDK gerektirmez; müşteri tarafında yalnızca `.ps1` dosyaları çalışır.
  - **Ne zaman yeniden değerlendirilmeli:** C# tarafı bugün üç dosya. On dosyaya çıkarsa PowerShell üzerinden test etmek hantallaşır ve gerçek bir debugger gerekir; o noktada `dotnet test` kurulumu kendini amorti eder.

### Neden perf tarafında C# yok

Başlangıçta bir `PerfCollector.cs` planlanmıştı; **yazılmadı ve yazılmamalı.** Örnekleme maliyeti duvar saatidir: 20 örnek × 1 sn = 20 sn, dil ne olursa olsun. Kazanç yalnızca sunucular arası paralellikten gelir ve onu `ParallelExecutor` zaten sağlıyor. Toplanan birkaç bin sayıyı özetlemek için var olan `PercentileEngine` yeterli.

Sırf mimari simetri olsun diye bir C# dosyası eklemek **kod eklerdi, hız eklemezdi.** Sıcak yol kuralı (ilke 13) "her şeyi C#'a taşı" demek değildir; ölçülen darboğazı C#'a taşı demektir.

### Tracking log erişimi (`logAccess` / `-LogAccess`)

1. **`smb`** — `Get-TransportService.MessageTrackingLogPath` ile yol keşfedilir, UNC'ye çevrilir (`D:\...` → `\\<srv>\D$\...`), dosyalar doğrudan okunur. **20-50x hızlı.**
2. **`cmdlet`** — Yalnızca `Get-MessageTrackingLog`. Admin share'lerin kapalı olduğu ortamlar için.
3. **`auto` (varsayılan)** — Önce SMB dener; erişim yoksa veya parse başarısızsa sessizce cmdlet'e düşer ve rapora `via=cmdlet` etiketi yazar. Hız kaybı gizlenmez.

Parser `#Fields:` satırını **her dosyada okuyup kolon indekslerini dinamik haritalar** — sürümler arası şema kayması bu sayede hata değil, eksik kolon için `N/A` üretir.

### Ölçülen hedefler

`run.log` her modülün süresini yazar. Referans hedef: ~200k satırlık bir tracking log penceresinde M10 **< 3 sn** (cmdlet karşılığı ~60 sn). Hedef tutmazsa profil çıkarılır — "yeterince hızlı" tahminle değil ölçümle belirlenir.
