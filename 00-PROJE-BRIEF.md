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

### Örgüler ne zaman iddia edilir

Bir örüntüyü "yakalayabilmek" yetmez; **yanlış yakalamamak** da gerekir. İlk sürümde dördü matematiksel olarak yanlış tetikleniyordu — iki sunuculu ortamda ortanca daima büyük elemanı seçtiği için P1 hiç kurulamıyor, buna karşılık tek teslimlik bir sunucu "150x yavaş" ilan edilebiliyordu. Bugünkü koşullar:

| # | Koşul | Neyi engeller |
|---|---|---|
| P1 | 3+ kıyaslanabilir sunucuda `en yavaş / ortanca ≥ 3x`; tam 2 sunucuda doğrudan kıyas. Kıyas kümesine yalnızca **20+ teslim ölçülmüş** ve hücresi `PASSIVE` olmayan sunucular girer, dışarıda kalanlar notta adlandırılır | Tek ölçümden hüküm; pasif site sunucusunu suçlamak |
| P2 | Baskın faz `Store` **ve** uçtan uca p95 ≥ `deliveryLatencyP95Sec.warn / 2` (varsayılanla 30 sn) | İç Exchange trafiğinde Store payı zaten en büyüktür; büyüklük tabanı olmadan sağlıklı sistem suçlanır |
| P3 | En az 2 DB **ve** en yüksek pay ≥ `min(max(100/N × 2, 50), 80)` — yani beklenen 1/N payının iki katı, %50-80 arasına kırpılmış. Oran **eşleştirilebilen** teslimler üzerinden hesaplanır ve örneklem cümlenin içinde yazar | İki DB'li ortamda %50 eşiğinin matematiksel garantisi; 300 alıcılık örneklemi tam tarama gibi sunmak |
| P4 | RPC p95 eşiği aşmış **ve** disk gerçekten ölçülmüş **ve** okuma/yazma hükmü `OK` **ve** kuyruk p95 < 2 | Ölçülemeyen diski "sağlıklı" sayıp operatörü depolamadan uzaklaştırmak |
| P5 | Aynı volume üzerinde 2+ DB **ve** o volume'un kendi disk hükmü `WARN`/`FAIL`. M20/M21 koşmadıysa satır `N/A` | Paylaşımı tek başına bulgu saymak |
| P6 | `p99 / ortalama ≥ 10` | — (ortalamanın yanıltıcılığını göstermek için; hüküm üretmez) |
| P7 | En az **6 farklı saatte 20+ teslim**; tepe ve sakin saat p95'e göre seçilir, `≥ 3x` fark `WARN` üretir. **Kapasite iddiası** yalnızca tepe saatin hacmi saatlik ortancanın altında değilse kurulur | Trafiğin binde birini taşıyan 03:00 saatini "yoğun saat" ilan edip `MaxConcurrentMailboxDeliveries` ayarına yönlendirmek |
| P8 | Aktif kopyalardan herhangi biri `ActivationPreference > 1`. Yük dengesizliği **ayrı** bir hükümdür: boşalmış bir düğüm, ya da `max ≥ 1.5 × ortalama` **ve** `max − min ≥ 2` | Oranın 10/10/10/0 dağılımını kaçırması; mutlak fark olmadan 3/2 dağılımına alarm vermek |

> P7'de gecikme tepesi ile yük tepesi **ayrı** raporlanır: düşük hacimli bir tepe gerçek bir sinyaldir ama sebebi kapasite değildir; araç bu durumda o saatte çalışan yedekleme, bakım işi veya toplu taşıma aramayı söyler.

---

## 4. Tasarım ilkeleri

1. **Salt okunur.** Hiçbir modül ortamı değiştirmez. Düzeltme öneren modüller komutu **metin olarak** raporlar, çalıştırmaz.
2. **Sıfır sabit kod.** Sunucu adı, DB adı, sürücü harfi, domain — hiçbiri script içinde geçmez. Hepsi keşif veya config.
3. **Modüler.** Her kontrol bağımsız bir modül; tek tek veya toplu çalışır (`-Module M10,M20`).
4. **Her modül kendi eşiğini bilir.** Çıktı ham veri değil, **yorumlanmış sonuç**: `OK` / `WARN` / `FAIL` + kanıt. Buna terk edilen iş için `TIMEOUT` ve patlayan modül için `ERROR` eklenir; `N/A` (ölçülemedi) ile `PASSIVE` (pasif site) ise **birer hüküm değildir** ve satır özetini ele geçirmezler (Bölüm 10). Sıralama: `OK` < `N/A`/`PASSIVE` < `TIMEOUT` < `WARN` < `ERROR` < `FAIL`.
5. **Tüm sunucular, aynı anda.** Kıyas olmadan tek sunucu ölçümü anlamsız. Her modül tüm sunucuları döner, **yan yana** raporlar.
6. **Ortalama yasak, persentil zorunlu.** Süre/gecikme ölçen her yerde min / p50 / p90 / p95 / p99 / max.
7. **Zaman damgalı arşiv.** Her çalıştırma `output\yyyyMMdd-HHmmss\` altına yazılır → yoğun/sakin saat karşılaştırması mümkün olur.
8. **Baseline karşılaştırma.** `-CompareWith <klasör>` ile önceki çalıştırmaya göre delta.
9. **Her modülde timeout — iki katmanlı.** Yanıt vermeyen sunucu aracı kilitlemez; hücre `TIMEOUT` yazar.
   Ama `PowerShell.Stop()` **senkrondur** ve yerel kodda (ham log ayrıştırma) çalışan bir iş durma isteğini görmez;
   yürütücü o işi **terk eder** ve devam eder. Bu yüzden uzun süren yerel işler ayrıca **kooperatif bir bütçe** alır
   (`BudgetSeconds = 840` < `TimeoutSeconds = 900`): bütçe dolunca ayrıştırıcı kendi durur ve **kısmi sonuç** döndürür.
   Kısmi sonuç sessiz kalmaz — M10/M11 satırı `WARN` olur ve notta "PENCERE KISMI" yazar. Terk edilen her iş için
   havuz tavanı bir artırılır (en çok başlangıç değerinin iki katına kadar), aksi halde sonraki modüller kendi
   bütçelerini harcamadan sıra bekleyip `TIMEOUT` olurdu. Terk sayısı da gizlenmez: çalıştırmanın sonunda
   `CORE / Terk edilen is` satırı `WARN` olarak rapora düşer ve tavan yükseltilemediyse (uzak uç nokta reddetti,
   ya da tavan doldu) **o çalıştırmadaki diğer `TIMEOUT` hücrelerine güvenilmemesi** gerektiğini söyler.
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
  "parallelism": 4,               // eşzamanlı runspace sayısı — tavanı araç kendisi kısar, ↓
  "logAccess": "auto",            // "auto" | "smb" | "cmdlet" — bkz. Bölüm 14
  "exchangeUri": "",              // boş = otomatik keşif; "http://<sunucu>/PowerShell/"
  "authentication": "Kerberos",
  "moduleTimeoutSeconds": 120,    // modül başına varsayılan yürütücü timeout'u
  "maxRecipientLookups": 300,     // M12: sorgulanacak en fazla benzersiz alıcı
  "perfSampleCount": 20,          // M20/M21: kaç örnek (persentil için)
  "perfSampleIntervalSeconds": 1, // örnekler arası hedef aralık
  "maxFolderScans": 50,           // M24: taranacak en fazla posta kutusu
  "storeDiagnosisFloorMs": 1000   // M23: teşhis kapısı - altındaki ölçüm için örüntü iddia edilmez
}
```

> ⚠️ **`storeDiagnosisFloorMs` bir eşik değil, SUSMA EŞİĞİDİR.** M23 satırının `OK`/`WARN`/`FAIL` hükmü `storeTimeInServerMs`'ten gelir; bu değer yalnızca "BEKLİYOR / CPU YAKIYOR" teşhisinin kurulabildiği en küçük büyüklüktür. 3 ms sunucu zamanının 0 ms CPU'ya oranı da sonsuzdur ama kimse beklemiyordur. Yükseltmek gerçek bulguları da susturur. Bu yüzden `warn`/`fail` ikilisine sokulmamıştır: tek yanlı bir kapıyı o şemaya koymak, yön çıkarımına uydurma bir anlam kazandırırdı (karş. `maxRecipientLookups`, `maxFolderScans`).

> ⚠️ **`parallelism` keyfi büyütülemez.** Exchange throttling policy'sindeki `PowerShellMaxConcurrency` (varsayılan 18) kullanıcı başına eşzamanlı oturum sayısını sınırlar. Araç bu değeri okuyup kendi tavanını ona göre kısar: **Global kapsamlı policy'lerin en düşüğünün yarısı** (diğer yöneticilere yer bırakmak için), değer sınırsızsa 8, policy hiç okunamazsa 4. Buraya yazılan daha büyük bir sayı bu tavanla kırpılır; aksi halde araç kendi kendini boğar ve diğer yöneticilerin oturum açmasını engeller.

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
  "memoryFreePercent":       { "warn": 5,   "fail": 1 },       // M05: düşük kötü
  "pagefileUsedPercent":     { "warn": 50,  "fail": 95 },      // M05: bellek bağlacının ikinci bacağı
  "storeTimeInServerMs":     { "warn": 30000, "fail": 60000 },
  "diskFreePercent":         { "warn": 20,  "fail": 10 },      // düşük kötü (M22/M25)
  "backupAgeDays":           { "warn": 3,   "fail": 7 },       // M45
  "eventErrorCount":         { "warn": 50,  "fail": 500 },     // M41: pencere başına HAM olay
  "updatesBehind":           { "warn": 1,   "fail": 3 }        // M43: referans SU listesine göre
}
```

> ⚠️ **M05 bellek hükmü bir BAĞLAÇTIR.** Exchange ESE önbelleğini tasarım gereği büyütür; düşük boş bellek tek başına uyarı üretmez. Uyarı ancak boş bellek `memoryFreePercent`'in altında **ve** pagefile kullanımı `pagefileUsedPercent`'in üstündeyken verilir ve satırın hükmü iki bacağın **zayıf halkasıdır** - biri yalnızca `warn` seviyesindeyken satır `FAIL` olmaz. Pagefile okunamazsa ikinci koşul bilinmiyor demektir ve hüküm verilmez (`N/A`) - okunmamış veriden "sağlıklı" sonucu çıkarılmaz.

> ⚠️ **Eksik anahtar sessiz kalmaz.** Bir eşikte `warn`/`fail` yoksa veya sayısal değilse araç açık hata verir. Eskiden eksik `fail` sessizce `0` oluyor, `warn > fail` karşılaştırması yönü **tersine** çeviriyordu: boş kuyruk `FAIL`, 5000 mesajlık kuyruk `OK`.

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

> **`ignoreFindings` bastırması görünür olmak zorundadır.** Desen satırın `Modül`, `Kontrol` ve `Not` alanlarına karşı denenir (`M45:NoRecentBackup` biçimi modülü de sınırlar) ve yalnızca `WARN`/`FAIL` satırları bastırılabilir. Bastırılan satırın hükmü `N/A`'e çekilir, notunun başına `[BASTIRILDI: profil …, desen …]` yazılır ve çalıştırmanın sonuna `CORE / Bastirilan bulgu` adıyla bir `WARN` satırı düşer. **Görünmeyen bastırma, yanlış negatifle aynıdır** — nitekim bu ayar bir süre config'de, profillerde ve bu brief'te belgeli olduğu hâlde kod tarafında hiç okunmuyordu.

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
| **M02** | Gerçek build | Kurulu CU/SU seviyesi | Setup registry `MsiInstallPath` → `Bin\ExSetup.exe` dosya sürümü, **her sunucuda** (yerel havuz + `Invoke-Command`) | ⚠️ Bkz. Bölüm 10 |
| **M03** | Servis durumu | Zorunlu servisler ayakta mı | `Test-ServiceHealth` | Hepsi `Running` |
| **M04** | Sertifikalar | Süre, atanmış servisler, zincir | `Get-ExchangeCertificate` | Eşik: `certExpiryDays` |
| **M05** | OS / kaynak | CPU, RAM, pagefile, uptime, .NET sürümü | `Get-CimInstance`, perfmon | Eşik: `cpuPercent`; bellek bağlacı: `memoryFreePercent` + `pagefileUsedPercent` |

### Faz B — Gecikme tespiti

| ID | Modül | Ne bakar | Anahtar komutlar | Örüntü |
|---|---|---|---|---|
| **M10** | Sunucu bazlı gecikme **persentili** | Hangi sunucu yavaş | `Get-MessageTrackingLog -EventId DELIVER` → `MessageLatency` | P1, P6 |
| **M11** | Faz kırılımı | Gecikme hangi aşamada | `network-message-id` üzerinden RECEIVE/DELIVER join'i — bkz. ↓ | P2 |
| **M12** | Gecikmeli teslimlerin hedef DB'leri | Gecikme belirli DB'lerde mi | Yavaş `DELIVER` → alıcılar → `Get-Recipient`.Database → grupla | P3 |
| **M13** | Saat bazlı dağılım | Yoğun saat korelasyonu | Tracking log → saat bazlı p95 | P7 |
| **M14** | Transport kuyrukları | Kuyruk derinliği (**yerel teslim / uzak hedef ayrı**), retry, poison | `Get-Queue` | Eşik: `queueMessageCount` |
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
| **M21** | Disk latency | Depolama darboğazı | `Win32_PerfRawData_PerfDisk_LogicalDisk` → `AvgDisksecPerRead/Write` (ham sayaç, ↓ Bölüm 10) | P4 |
| **M22** | DB → volume haritası | Hangi DB'ler diski paylaşıyor | `Get-MailboxDatabase` → `EdbFilePath`, `LogFolderPath` | **P5 testi** |
| **M23** | Ağır kullanıcılar | DB başına en yoğun tüketiciler | `Get-StoreUsageStatistics` | Yorum tablosu ↓; teşhis kapısı: `storeDiagnosisFloorMs` (environment.json) |
| **M24** | Büyük klasörler | Aşırı öğe sayısı | `Get-MailboxFolderStatistics` | Eşik: `folderItemCount` |
| **M25** | DB boyut / whitespace | Şişme, disk doluluğu | `Get-MailboxDatabase -Status` | — |
| **M26** | İçerik indeksi | Arama sağlığı | `Get-MailboxDatabaseCopyStatus` → `ContentIndexState` | ⚠️ Bkz. Bölüm 10 |

### Faz D — DAG ve replikasyon

> DAG yoksa bu fazın tamamı `N/A` döner — hata değil.

| ID | Modül | Ne bakar | Anahtar komutlar | Örüntü |
|---|---|---|---|---|
| **M30** | Kopya durumu | Tüm kopyaların sağlığı | `Get-MailboxDatabaseCopyStatus` | — |
| **M31** | Kuyruk uzunlukları | Replikasyon gecikmesi | `CopyQueueLength`, `ReplayQueueLength` | Eşik: config. **Lagged kopyalar replay hükmüne girmez** — orada büyük kuyruk tasarımdır; hangi kopyanın neden çıkarıldığı yazılır |
| **M32** | Aktif kopya dağılımı | Yük dengesi | Aktif DB / sunucu + `ActivationPreference` | **P8** |
| **M33** | Replikasyon sağlığı | Kapsamlı test | `Test-ReplicationHealth` | Hepsi `Passed` |
| **M34** | Siteler arası log trafiği | Uzak siteye giden log hacmi | Log üretim hızı + uzak site kuyruk uzunluğu | WAN darboğazı |

### Faz E — İzleme, güvenlik, yapılandırma

| ID | Modül | Ne bakar | Anahtar komutlar | Not |
|---|---|---|---|---|
| **M40** | Managed Availability | Sağlık setleri | `Get-ServerHealth` (sunucu başına bir iş) | `known-issues.json` ile filtrelenir |
| **M41** | Event log taraması | Son 24 saat hata/uyarı | Application + System, ilk N | Gürültü filtresi şart |
| **M42** | AV dışlamaları | Üreticinin önerdiği listeye uyum | Exclusion listesi karşılaştırması | Yol/işlem/uzantı |
| **M43** | Yama durumu | Kaç güncelleme geride | M02 build vs referans SU listesi | Referans liste config'de, güncellenebilir |
| **M44** | Lisans / aktivasyon | Sürüm, aktivasyon, süre | `Get-ExchangeServer` (deneme süresi) + `Get-CimInstance SoftwareLicensingProduct` (Windows aktivasyonu) | Eval ortamlarda süre uyarısı |
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
│   ├─ Config.ps1 · Connect.ps1 · Framework.ps1 · Report.ps1 · Compare.ps1
│   ├─ Replication.ps1         ← kopya envanteri (M30-M34 ortak girdisi)
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
├─ Sample-Output\              ← sentetik örnek rapor (repoya commit edilir)
├─ Tests\                      ← yalnızca geliştirme; teslimat için gerekmez
│   ├─ Invoke-EDTests.ps1      ← tüm paketleri KÜLTÜR BAŞINA koşturur
│   ├─ Test-*.ps1              ← paketler; fixture'lar %TEMP% altına yazılır
│   ├─ EDTestHelpers.ps1       ← paylaşılan sahte yürütücü / satır yardımcıları
│   ├─ New-*Fixture.ps1        ← sentetik MSGTRK*.LOG üreticileri
│   ├─ New-SampleOutput.ps1    ← Sample-Output\ üreticisi
│   └─ Assert-ReadOnly.ps1     ← salt okunurluk AST lint'i
└─ output\                     ← .gitignore
    └─ 20260917-143000\
        ├─ SUMMARY.html        ← renkli özet, sunucular yan yana
        ├─ SUMMARY.csv
        ├─ run-meta.json       ← çalıştırmanın kapsamı (-CompareWith bunu okur)
        ├─ M10-latency.csv     ← ham kanıt
        └─ run.log             ← modül başına süre ölçümü dahil
```

> ⚠️ **Testler depo içine yazmaz.** Fixture'lar `%TEMP%` altındadır; iki paket bir zamanlar paylaşılan `Tests\fixtures` klasörünün **ebeveynini** siliyor ve birbirinin 83 MB'lık verisini yok ediyordu. Fixture kullanan paketler `-FixtureDir` alır ve koşturucu her paket/kültür çifti için ayrı bir klasör verir.

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
| Parser doğrulama | `-VerifyParser` | Ham parse sonucunu cmdlet'e karşı doğrular (%1 tolerans). **M10 içinden çalışır — `-Heavy` gerekir**, yoksa rapora `WARN` satırı düşer: "doğrulama çalıştırılamadı, gecikme türetimi DOĞRULANMIŞ SAYILMAZ" |

#### `-VerifyParser` kıyas yapamadığında

"Kıyaslanacak bir şey çıkmadı" sessizce geçilemez — doğrulayıcının varlık sebebi tam olarak buradadır. Ham yol veri üretemediyse kök neden ayrılır ve **her birinin hükmü farklıdır**:

| Durum | Hüküm | Gerekçe |
|---|---|---|
| Olaylar okundu ama hiçbirinden gecikme türetilemedi | `FAIL` | `message-info` biçimi değişmiş olabilir — **ayrıştırıcı regresyonu** şüphesi; doğrulayıcının yakalaması gereken sınıf tam olarak budur |
| Baskın neden negatif gecikme (`NegativeLatency ≥ LatencyMissing`) | `WARN` | Bu bir ayrıştırıcı hatası değil **saat kayması** bulgusudur; önce zaman senkronizasyonu düzeltilir |
| Ham okuma zaman bütçesine takıldı (`Truncated`) | `N/A` | Kısmi pencere, cmdlet'in tam penceresiyle karşılaştırılamaz; `FAIL` demek doğrulayıcıyı yalancı çıkarır |
| Ham yol hiç kullanılmadı (`-LogAccess Cmdlet`, erişim yok) | `N/A` | Karşılaştırılacak bir şey yok |
| Cmdlet veri döndürmedi ama ham yol buldu | `ERROR` | Kıyas kurulamadı; iki yoldan biri yanlış ve hangisi olduğu bilinmiyor |

Kök neden tespiti `-LogAccess`'ten **bağımsız** yapılır: `Smb` modu tam da ham ayrıştırıcıyı zorlamak için seçilir, orada kör kalmak anlamsızdır.

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

- ⚠️ **Perf sayacı yolları işletim sistemi diline göre yerelleşir.** Türkçe bir sunucuda `\LogicalDisk(*)\Avg. Disk sec/Read` **bulunamaz**. `Win32_Perf*Data_*` sınıflarının özellik adları ise dil-nötrdür (`AvgDisksecPerRead` her yerde aynı) — ham sınıfta da böyledir. Araç "ortamdan bağımsız" olacaksa sayaçlara **CIM üzerinden** erişmelidir. Exchange'in kendi sayaçları İngilizce kalır, ama OS sayaçları kalmaz — ikisini aynı mekanizmayla okumak bu tuzağı tamamen kapatır.

- ⚠️ **Disk gecikmesi HESAPLANMIŞ sınıftan okunamaz; ham sayaçtan türetilir.** `Win32_PerfFormattedData_PerfDisk_LogicalDisk`'in `AvgDisksecPerRead/Write` alanları `UInt32`'dir — yani **tam saniye**. Eşikler 0,020/0,050 sn olduğu için bu sınıf sorulduğunda gerçek bir disk **her zaman 0** okunur; sıfırdan farklı en küçük değer 1000 ms, yani `FAIL` eşiğinin 20 katıdır. Ölçüldü: gerçek 0,0006 sn'lik yazma gecikmesinde `Get-Counter` 0,0006 dönerken CIM dört örneğin dördünde de 0 döndü.
  > Zarar "ölçüm kayboldu"dan ibaret değildi: M20'nin P4 iddiası (*"disk sağlıklı → darboğaz Store içinde → disk değiştirmek işe yaramaz"*) bu sabit sıfıra dayanıyordu. Disk boğulurken araç operatörü **depolamadan uzaklaştırıyordu** — bir teşhis aracının verebileceği en pahalı yanlış yönlendirme.
  Gecikme artık `Win32_PerfRawData_*` üzerinden `PERF_AVERAGE_TIMER` formülüyle hesaplanır: `((X1-X0) / (B1-B0)) / Frequency_PerfTime`. Kuyruk uzunluğu ve boşta yüzdesi tam sayı değerler olduğu için hesaplanmış sınıftan gelmeye devam eder.

- ⚠️ **Hesaplanmış (cooked) sayaçların ilk örneği atılmalıdır.** Bu sayaçlar iki örnek arasındaki farktan üretilir; ilk sorgu çoğu zaman `0` döner. Bu sıfırı gerçek ölçüm saymak "disk mükemmel" gibi yanlış bir sonuç üretir. **Ham sayaçta tersi geçerlidir:** orada ilk tur farkın bir ucudur ve atılmaz.

- ⚠️ **Ölçülemeyen yere `0` yazılmaz.** Sayaç sarmasında (`UInt32`), I/O olmayan aralıkta veya taban değeri değişmemişse **örnek üretilmez**; M21 o volume için `N/A` yazar ve hiçbir volume ölçülemediyse sunucu için sayı vermez. M20 de P4 örgüsünü yalnızca disk **gerçekten ölçüldüyse** kurar. "Ölçüm yok" ile "0 sn" ayrı şeylerdir; ikisini karıştırmak sağlıklı bir hüküm uydurmaktır.

- ⚠️ **Örnekleme aralığından sorgu süresini düşün.** Sorgu 0,8 sn sürüyorsa ve aralık 1 sn ise, `Start-Sleep 1` gerçek aralığı 1,8 sn yapar ve toplam süre sessizce ikiye katlanır. Ölçülen örnek: 20 örnek × 1 sn hedefi **37,3 sn** sürüyordu; sorgu süresi düşülünce **21 sn**'ye indi. Ulaşılan gerçek aralık hedefin belirgin üstündeyse bu **raporlanmalıdır** — kadans gizlenmez.

- ⚠️ **Disk latency'de `_Total` raporlanmaz, EN KÖTÜ volume raporlanır.** Sekiz volume'un yedisi sağlıklı biri boğulmuşsa `_Total` sağlıklı görünür ve tek bozuk LUN kaybolur. Ortalamanın tail'i gizlemesiyle aynı hata, yalnızca bir boyut aşağıda. Testte ölçülen: `_Total` yazma 0,018 sn (eşiğin altında, "OK") iken gerçek bozuk volume 0,070 sn (FAIL).

- ⚠️ **Yol → volume eşlemesi en uzun önek ile yapılır.** Sürücü harfine bakmak yetmez: bağlama noktaları (mount point) yüzünden `C:\ExchangeVolumes\Vol1` ile `C:\` **farklı diskler** olabilir. Sürücü harfine göre eşleştirmek hepsini aynı volume sanmaya ve sahte bir "paylaşılan kaynak" bulgusuna yol açar.

- ⚠️ **Saat bazlı dağılım geniş pencere ister.** Varsayılan 1 saatlik pencerede "yoğun saat" diye bir şey yoktur. M13, **en az 6 farklı saatte 20+ teslim** görmeden tepe saat iddia etmez — üç saatin en yükseğiyle en düşüğünü kıyaslayıp "yoğun saat" demek gürültüyü eğri sanmaktır. Yetersiz örneklemde `N/A` döner ve `-WindowHours` önerir.

- ⚠️ **Üretici varsayılanları sürümler arasında değişir.** "Bu ayar değiştirilmiş" demek için elde doğrulanmış bir referans olmalı; yoksa araç **hiçbir iddiada bulunmamalıdır**. Geliştirme sırasında bu hatanın canlı örneği görüldü: hafızadan yazılan varsayılan tablo, hiç dokunulmamış bir SE kurulumuna "değiştirilmiş" etiketi bastı. Referans değerler `Config\reference.json`'a taşındı ve ifade "referans varsayılan X, bu ortamda Y — farklı olması tek başına hata değildir" şeklinde düzeltildi.

- ⚠️ **Kuyruk derinliği anlık bir ölçümdür.** `Get-Queue` tarama anındaki fotoğrafı verir. Sakin saatte boş görünen bir kuyruk yoğun saatte dolup boşalıyor olabilir; M14 tek başına değil M13 ile birlikte okunmalıdır. Ayrıca **gölge (shadow) kuyruklar DAG'da normalde doludur** ve toplam derinliğe katılırsa yanlış alarm üretir — derinliğin dışında tutulur, yalnızca kanıt dosyasında görünür.

- ⚠️ **Yerel teslim kuyruğu ile uzak hedef kuyruğu AYNI SATIRDA toplanmaz.** İkisi de mesaj biriktirir ama **suçlu farklıdır**: `MapiDelivery`/`SmtpDeliveryToMailbox` gibi kuyruklar bu sunucunun Store'una gider, `DnsConnectorDelivery`/`SmartHostConnectorDelivery` gibi olanlar dışarıya. Tek bir toplamda, alan tarafındaki bir MX arızası bu sunucuyu yavaş gösterir ve teşhis yanlış altsisteme kayar. Eşik ikisine de aynı uygulanır; değişen eşik değil **hükmün sahibidir**. Tanınmayan bir teslim tipi "belirsiz" kovasına düşer, yerel toplama katılır (temkinli taraf) ve notta **adıyla** yazılır.

- ⚠️ **Sayı ayrıştırması kültüre bırakılmaz.** `[double]::TryParse`'ın tek argümanlı hâli `CurrentCulture` ile ayrıştırır, ama PowerShell sayıları **her zaman invariant** biçimde string'e çevirir (`"0.07"`). tr-TR ve de-DE'de `.` binlik ayracıdır; değer sessizce **100 kat** büyür. Ölçülen sonuçlar (düzeltme öncesi, tr-TR): 12,5 ms RPC → `FAIL`; 3,5 gün kalan sertifika → `OK`. Yani hem sahte `FAIL` hem **sessizce kaçırılan** `FAIL` — ikincisi daha tehlikelidir. Kural: karşılaştırma ve aritmetik **invariant** kültürle yapılır (`ConvertTo-EDNumber`), sunum biçimi HTML'in işidir, `SUMMARY.csv` ise bir **veri sözleşmesidir** ve invariant yazılır (`-CompareWith` onu makine olarak okur).
  > Bu hata sınıfı tek kültürde koşan bir test paketiyle görülemez; nöbetçisi `Tests\Invoke-EDTests.ps1`'dir (Bölüm 11).

- ⚠️ **`RunLocal` YEREL havuzda koşar; `ExecTask`'ta hedef sunucu alanı YOKTUR** (`Key` yalnızca bir etikettir). Makine seviyesinde veri isteyen bir modül, scriptblock'un **içine** `Invoke-Command -ComputerName $Server` koymak zorundadır. Koymayan modül, aracın koştuğu makineyi N kez okuyup sonuçları MBX1/MBX2/MBX3 diye etiketler — tek sunuculu bir lab'da sonuç tesadüfen doğru çıktığı için hiçbir test kırmızı olmaz.
  > **Canlı örnek:** M05, M41, M42 ve M44 tam olarak bunu yapıyordu; bulan şey davranış testi değil, kaynağı okuyan yapısal bir sözleşme testi oldu (`Tests\Test-ModuleContracts.ps1`). Gerçekten yerel çalışması gereken kod `# ED-LOCAL-OK: <gerekçe>` ile muaf tutulur.

- ⚠️ **Back pressure sırasında kuyruklar BOŞ görünür.** Mesajlar reddedildiği için kuyruğa hiç alınmamıştır. "Kuyruk boş, demek ki transport iyi" çıkarımı bu yüzden yanlıştır — M14 ve M15 birlikte okunmalıdır.

- ⚠️ **Eşzamanlılık Exchange tarafında sınırlıdır.** Throttling policy'deki `PowerShellMaxConcurrency` (varsayılan 18) aşılırsa yeni oturumlar reddedilir ve araç hem kendini hem diğer yöneticileri kilitler. `parallelism` tavanı bu değerden türetilmeli, sabit büyük bir sayı verilmemeli.

- ⚠️ **OKUMA HATASI ile NORMAL DURUM ayrı raporlanır.** Bu, tek tek modüllerde defalarca aynı biçimde yapılan hatadır ve hepsinin sonucu aynı cümledir: *ölçülemeyen şey sağlıklı sayılır.* Birkaç canlı örnek — DB listesi okunamadığında aktif DB sayısına `0` yazmak (M01; bu sayı P8'i besler), sayfa dosyası okunamadığında bellek hükmünü yine de vermek (M05), olay günlüğü okunamayan sunucuya `0 hata / OK` demek (M41), hiçbir posta kutusu taranamamışken "büyük klasör yok" demek (M24), hiçbir DB birime eşlenememişken "hiçbiri boş alandan büyük değil" demek (M25), `Unknown` indeks durumunu bozuk saymak (M26). Kural üç maddedir: **(1)** okunamayan değer `N/A` yazılır, **(2)** okuma hatası varsa satır en az `WARN` olur ve `N/A`'lerin "sıfır" anlamına gelmediği notta yazar, **(3)** ölçüm yokken olumlu cümle **kurulmaz**.

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
   > Bu lab'da DAG olmadığı için mantık **sentetik kopya envanteriyle** doğrulandı. Gerçek ortam doğrulaması hâlâ gereklidir; ayrıntı Bölüm 10'daki uyarıda.
10. ✅ **Faz E (M40-M45)** + `known-issues.json` filtresi
    > M40 ve M45 `known-issues.json` ile bastırma uygular ve **ikisi de bastırmayı satırın notunda görünür kılar** (kaç bulgu, hangi nesne) — görünmeyen bastırma yanlış negatifle aynıdır. **M41 bastırma UYGULAMAZ:** eşleşen olayı yalnızca kanıt CSV'sinde `Bastirildi=True` diye etiketler, hata sayısından düşmez ve hükmü değiştirmez. `known-issues.json`'a M41 girdisi yazan operatör gürültünün susacağını sanır; susmaz. M43 ve M42 **referans listesi boşken hiçbir iddiada bulunmaz** (M16 disiplini). M44'ün özellik adları (`IsExchangeTrialEdition`, `RemainingTrialPeriod`) ve M45'inkiler (`LastFullBackup`, `CircularLoggingEnabled`) canlı ortamdan **doğrulanarak** yazıldı, tahmin edilmedi.
11. ✅ **M04, M05, M25, M26** — brief Bölüm 6'da tanımlı olup atlanmış Faz A/C modülleri
    > M04'ün enum çözümlemesi ve M25'in bayt ayrıştırması canlı ortamdan **doğrulanarak** yazıldı. M25 ve M26, kasıtlı olarak **iddia etmeyi reddettikleri** şeylerle tanımlanır: whitespace'e eşik uygulanmaz, bozuk indeks teslimle ilişkilendirilmez. M05 çalışma süresini bulgu değil **bağlam** olarak raporlar.
12. ✅ **HTML/CSV rapor + `-CompareWith` delta motoru**
    > Delta motorunun asıl işi fark hesaplamak değil, **hangi farkın anlamsız olduğunu söylemektir**: kapsam farkı (`run-meta.json`), `N/A` sınırı, küçük sayıda büyük yüzde, saat farkı.

    > ⚠️ **Satır adı (`Kontrol`) bir EŞLEŞTİRME ANAHTARIDIR.** Delta motoru satırları `Modül|Kontrol` ikilisiyle eşler. Bir satırı yeniden adlandırmak, eski bir taban ile karşılaştırıldığında bir **KAYBOLDU + YENİ çifti** üretir; modül atlanmamış ve kapsam değişmemişken **uydurma bir kapsam değişikliği iddiası**dır. Ayrıca `ignoreFindings` desenleri `Kontrol` alanına karşı denenir: eski adı yazan bir bastırma **sessizce çalışmayı bırakır**. Bu yüzden ad değişikliği **bir kereye mahsus bir bedeldir** ve yalnızca eski ad yanıltıcıysa yapılır; yapıldığında commit mesajında açıkça yazılır.
13. ~~Zamanlanmış görev + yoğun saat otomasyonu~~ — *kapsam dışı bırakıldı (kullanıcı kararı)*
14. ✅ **`Tests\Assert-ReadOnly.ps1`** — 1. ilkenin otomatik güvencesi
    > AST tarar (grep değil: M32 düzeltme komutunu **metin olarak** raporlar, düz arama yanlış alarm üretir). Exchange kanalından çağrılan **15 cmdlet'in tamamı `Get-`/`Test-`**. Denetimin kendisi de sınanır (`Tests\Test-ReadOnlyLint.ps1`): düşmanca bir sahte depoya karşı koşturulduğunda yirmi kadar yazma yolundan yalnızca ikisini yakaladığı görüldü ve sertleştirildi — **bir denetim betiğinin sessizliği, temizlikten ayırt edilemediği için en kötü başarısızlık biçimidir.**
15. ✅ **`README.md`, örnek çıktı, `Config.sample\`**
    > Örnek rapor `Tests\New-SampleOutput.ps1` ile **sentetik** üretilir — gerçek bir çalıştırmanın çıktısı sunucu ve posta kutusu adları taşıdığı için dağıtılamaz. Üretilen senaryo sekiz örgünün (P1-P8) tamamını içerir. `Sample-Output\` depoya commit edilmiş bir **demo**dur: kod düzeldiğinde o da tazelenmezse rapor katmanının doğru davranışını yalanlar.

### Test paketi neden kültür başına koşar

Paketler geliştiricinin makinesinde (çoğunlukla en-US) koşuyordu ve **tek bir test bile kırmızı değilken** her eşik hükmü Türkçe bir sunucuda yanlış çıkıyordu (Bölüm 10, kültür uyarısı). Bu yüzden `Tests\Invoke-EDTests.ps1` her paketi **her kültür için ayrı bir alt süreçte** koşturur — varsayılan `en-US` + `tr-TR`; kültür aynı oturumda değiştirilirse önceden yüklenmiş tipler ve biçimlendiriciler yarım kalır.

**Geçmek yetmez, iki kültürde de geçmek gerekir.** Bir iddia yalnızca tek kültürde geçiyorsa ya ürün kültüre bağımlıdır (hata) ya da iddianın kendisi geliştiricinin ondalık ayracını varsayıyordur (test hatası); ikisi de düzeltilir. Sonuç satırı üretmeyen bir paket "0 hata" sayılmaz, `COKTU` olarak raporlanır.

Bugünkü durum — **15 paket × 2 kültür = 2486 doğrulama, 0 hata** (paket başına en-US/tr-TR aynı):

| Paket | Doğrulama | Kapsam |
|---|---|---|
| `Test-TrackingLogParser` | 137 | C# ayrıştırıcı: `#Fields:` eşlemesi, tırnaklı CSV, UTC, gecikme türetimi, zaman bütçesi, performans |
| `Test-CoreUnits` | 130 | C# çekirdek birim testleri: `PercentileEngine`, `StatsAccumulator`, `CsvLineSplitter` |
| `Test-LatencyModules` | 48 | M10-M13 uçtan uca (**canlı Exchange uç noktası ister**) |
| `Test-LatencyPatterns` | 119 | P1/P2/P3/P7 hüküm mantığı, sahte yürütücüyle |
| `Test-TransportModules` | 71 | M14-M16 |
| `Test-PerfModules` | 52 | M20-M22, örgü P4 ve P5 |
| `Test-StoreModules` | 50 | M23-M24, yorum tablosu |
| `Test-BaselineModules` | 103 | M04, M05, M25, M26 |
| `Test-DagModules` | 100 | M30-M34 (sentetik DAG) |
| `Test-HealthModules` | 79 | M40-M45 |
| `Test-CompareEngine` | 145 | Delta motoru ve kapsam koruması |
| `Test-ReportLayer` | 110 | Rapor katmanı + giriş noktası: CSV kaçırma, `N/A` sınıfı, çıkış kodları |
| `Test-ReadOnlyLint` | 38 | Salt okunurluk denetiminin **kendi** testi |
| `Test-ModuleContracts` | 33 | Yapısal sözleşme: `RunLocal` kullanan modül ve Core toplayıcısı hedefe gidiyor mu |
| `Test-TimeoutVerdict` | 28 | `TIMEOUT` sıralaması: `N/A` < `TIMEOUT` < `WARN` < `ERROR` < `FAIL` |

> `Test-LatencyModules` dışındaki paketler gerçek sunucuya sorgu göndermez: sahte yürütücü gerçek `ExchangeDiag.ExecResult` nesneleri üretir, sentetik tracking log'lar `%TEMP%` altına yazılır. `Test-LatencyModules` ise bağlanır ve M01'i koşturur; bu yüzden örgülerin **karar** mantığı orada değil `Test-LatencyPatterns`'ta sınanır — iki sunuculu, pasif siteli, tek örneklemli senaryolar canlı ortamda üretilemez.

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
| Sıralı yürütme | 30 modül × N sunucu, teker teker. PS 5.1'de `ForEach-Object -Parallel` yok | C# `ParallelExecutor` + paylaşılan runspace havuzları (Exchange & yerel) |
| Persentil matematiği | Milyonlarca `TimeSpan` üzerinde PS sıralama/gruplama | `double[]` + `Array.Sort` |

**Dil seçimi C#, çünkü:** Exchange yönetim cmdlet'lerinin desteklenen bir .NET API'si yoktur. Go/Rust seçilse bile sonunda PowerShell çağrılmak zorunda kalınır. C# ise `System.Management.Automation`'ı doğrudan host edip runspace havuzunu kendi yönetebilir.

### Katman dağılımı

| Katman | Dil | Gerekçe |
|---|---|---|
| CLI, config, modül kaydı, eşik değerlendirme, rapor yazımı | PowerShell | Okunabilir, müşteri tarafında düzenlenebilir, sık değişir |
| Tracking log parser, persentil/istatistik, paralel yürütücü | C# | Sıcak yol — `Core\TrackingLogParser.cs`, `Core\PercentileEngine.cs`, `Core\ParallelExecutor.cs` (bugün C# tarafının tamamı bu üç dosyadır) |
| Perf sayacı örnekleme, volume envanteri, kopya durumu toplama | PowerShell | ↓ bkz. "Neden perf tarafında C# yok"; ortak yardımcılar `Core\PerfCounter.ps1` ve `Core\Replication.ps1` |
| Modüllerin **tamamı** (30 dosya) | PowerShell | Modül bir *bildirimdir*, yürütücü değildir; işleri C# havuzlarında paralel koşar |

**Yürütme kanalları.** Ayrı bir "cmdlet-only modül" sınıfı **yoktur** — `ParallelExecutor` iki ayrı runspace havuzu işletir ve bir modül ikisini birden kullanabilir:

| Kanal | Modülün verdiği | Kullanan modüller |
|---|---|---|
| **Exchange havuzu** (`RunExchange`) — kısıtlı (NO-LANGUAGE) uzak yönetim runspace'i | Komut adı + parametre + `-Select`. **Scriptblock değil**: orada script metni çalışmaz, `Invoke-Command`/`Get-CimInstance` yoktur | Kendi işini açan: M01, M03, M04, M12, M14, M16, M23, M24, M33, M40, M44, M45 — ortak `Get-EDCopyStatus` önbelleği üzerinden (tek sorgu paylaşılır): M26, M30, M31, M32, M34 |
| **Yerel havuz** (`RunLocal`) — tam dilli runspace, hedefe `Invoke-Command -ComputerName` ile gider | Scriptblock + parametre + timeout | Kendi işini açan: M02, M05, M15, M41, M42, M44 — ortak `Core\PerfCounter.ps1` yardımcıları üzerinden (`Invoke-Command` yardımcının içindedir): M20, M21, M22, M25 |
| **Yerel havuz, hedefe gitmeden** — aracın kendi makinesinden SMB/UNC okuma (`# ED-LOCAL-OK` muafiyeti) | Scriptblock + UNC yolu + `BudgetSeconds` | M10, M11, M13 (ham `MSGTRK*.LOG` ayrıştırma) |

Tek bir kanala düşmeyen üç durum vardır ve üçü de kasıtlıdır: **M44** iki havuzu birden kullanır (Exchange tarafı `Get-ExchangeServer`, Windows tarafı `SoftwareLicensingProduct`); **M10/M11/M13** log yolunu Exchange kanalından keşfeder (`Get-TransportService`), M10 ve M13 `logAccess=cmdlet`'e düşerse `Get-MessageTrackingLog`'a da o kanaldan gider — **M11 düşmez**, ham log erişimi yoksa `N/A` döner (MSGTRK + MSGTRKMD birleştirmesi cmdlet yolunda bütün olayları çekmeyi gerektirir); **M43** hiç iş açmaz, build numarasını M02'nin önbelleğinden okur.

**Kritik kural:** Modüller kendi runspace'ini/havuzunu açmaz, kendi paralelliğini yönetmez. Her modül *bildirir*: hedefler + iş tanımı (Exchange kanalında komut/parametre, yerel kanalda scriptblock) + timeout. `ParallelExecutor` bunları paylaşılan havuzlarında koşturur. (Makine seviyesindeki veriyi isteyen modül, `Invoke-Command -ComputerName`'i **scriptblock'un içinde** kendisi yazar — Bölüm 10'daki `RunLocal` uyarısı; `Tests\Test-ModuleContracts.ps1` bunu kaynak üzerinden zorlar.)

> **Timeout'un sınırı.** Yürütücünün `TimeoutSeconds`'ı tek katman değildir ve tek başına bir sınır da sayılmaz.
> Bir iş yerel koda girdikten sonra dışarıdan durdurulamaz (bkz. Bölüm 4, madde 9): `PowerShell.Stop()` senkrondur,
> yerel kodda dönen bir iş durma isteğini görmez. Yürütücü o işi **terk eder**, temizliği arka plana devreder ve
> çağırana hemen döner. Bu yüzden `TIMEOUT` hücresi "iş durduruldu" değil, **"iş terk edildi, arka planda sürüyor
> olabilir"** demektir; kuyrukta beklerken zaman aşan işler de aynı sayaca düşer ve ikisi ayırt edilemez.
> Gerçek sınır, ayrıştırıcıya verilen kooperatif bütçedir (`BudgetSeconds`); o da bloke bir SMB okumasını kesemez.
> Bütçe, iş **başladıktan** sonra hesaplanır — kuyrukta bekleme bütçeyi yemez — ve eksik/0 verilirse **sınırsız**
> kabul edilir: aksi halde geçmişte bir son teslim anı üretilir, bütün dosyalar atlanır ve sonuç "boş pencere" gibi
> görünürdü. Bu, aracın üretebileceği en tehlikeli çıktı biçimidir.

### Teslimat ve derleme

Teslimat **`.ps1` dosyalarıdır** — imzasız `.exe` güven sorunu yoktur, tüm kaynak okunabilir ve denetlenebilir. C# çekirdek çalışma anında derlenir:

- `Core\*.cs` düz kaynak dosyaları olarak durur.
- `Core\CoreLoader.ps1` kaynakların SHA256'sını alır; `%LOCALAPPDATA%\ExchangeDiag\cache\<hash>.dll` varsa doğrudan yükler, yoksa `Add-Type -OutputAssembly` ile derleyip cache'ler. İlk çalıştırma ~1-2 sn, sonrası sıfır.
- Cache dizinine yazılamıyorsa (AppLocker / kısıtlı ortam) bellek içi derlemeye düşer.
- ⚠️ **Dil sürümü C# 5 ile sınırlıdır.** `Add-Type`, PS 5.1'de .NET Framework'ün `csc.exe`'sini kullanır. String interpolation, `?.`, `nameof`, tuple, pattern matching **kullanılamaz**. Generics, LINQ, `async/await`, `Parallel.ForEach` kullanılabilir.
- **.NET SDK ve xunit test projesi KURULMADI — bilinçli karar.** Planda `Tests\ExchangeDiag.Core.Tests.csproj` (`<LangVersion>5</LangVersion>`) öngörülmüştü; gerekçesi iki maddeydi ve ikisi de başka yoldan karşılandığı için vazgeçildi:
  - *C# 5 kısıtını derleme anında zorlamak:* `Add-Type` zaten .NET Framework `csc.exe`'sini kullanıyor. Ölçülerek doğrulandı — C# 6 string interpolation içeren bir kaynak `Unexpected character '$'` ile **reddedildi**. `CoreLoader` her SHA256 değişiminde yeniden derlediği için ihlal ilk test çalıştırmasında görünür. `LangVersion 5` bu garantiyi tekrarlar, eklemez.
  - *C# birim testleri:* Çekirdek iki paketle sınanıyor — `Test-TrackingLogParser` (95) ayrıştırıcıyı, `Test-CoreUnits` (130) `PercentileEngine` / `StatsAccumulator` / `CsvLineSplitter`'ı doğrudan — ve bunlar **Add-Type'ın ürettiği gerçek assembly** üzerinden koşuyor, yani üretimde çalışan ikilinin ta kendisi. xunit ayrı bir derleme çıktısını test ederdi; mevcut düzen bu açıdan daha yakındır.
    > Bu argüman "dolaylı test yeterlidir" demek değildir. Çekirdek sınıfların **doğrudan** testi bir süre yoktu ve hepsi yalnızca sentetik log üzerinden, beklenen değerler de aynı motorun varsayımlarından türetilerek ölçülüyordu: `PercentileEngine.Percentile` doğrusal interpolasyondan nearest-rank'e çevrildiğinde **tüm paket yeşil kaldı.** `Test-CoreUnits`'teki değerler bu yüzden elle hesaplanmış ve sabit yazılmıştır.
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
