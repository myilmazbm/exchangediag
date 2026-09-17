// ExchangeDiag - TrackingLogParser
//
// Aracin en yuksek degerli bileseni. Get-MessageTrackingLog her satiri zengin
// bir .NET nesnesine deserialize eder (~2-10k satir/sn) ve uzaktan calisirken
// ustune CliXml serilestirmesi biner. Bu sinif ayni veriyi diskteki ham CSV
// dosyasindan okur.
//
// KRITIK: PowerShell tarafina MILYONLARCA SATIR DONDURULMEZ. Ozetleme burada,
// C# icinde yapilir; PS yalnizca hazir persentilleri ve en yavas N kaydi alir.
//
// DIKKAT EDILEN NOKTALAR (brief Bolum 10):
//  - DELIVER olaylari MSGTRKMD*.LOG (Mailbox Transport Delivery) dosyasindadir,
//    duz MSGTRK*.LOG Transport service'e aittir. Yanlis dosya kumesi "veri yok"
//    sonucu verir.
//  - #Fields: satiri HER DOSYADA okunup kolon indeksleri dinamik haritalanir;
//    surumler arasi sema kaymasi hata degil, eksik kolon icin N/A uretir.
//    Ama bir SATIRIN alan sayisi basliktaki kolon sayisiyla uyusmuyorsa o
//    satirdaki hicbir kolon guvenilir degildir: satir atilir ve MalformedLines
//    sayacina yazilir. Sessiz kayip yok - kismen bozuk bir log ile temiz bir
//    log operatore ayni gorunmemeli.
//  - date-time UTC'dir. Saat bazli dagilim yerel saate cevrilmeden uretilirse
//    yogun saat korelasyonu kayar.
//  - MessageLatency log'da BIR KOLON DEGILDIR; cmdlet onu hesaplar. Burada
//    message-info alanindaki gonderim zaman damgasindan yeniden turetilir.
//    Bu turetim -VerifyParser ile cmdlet'e karsi dogrulanmadan guvenilmez.
//  - Log dosyalari o anda YAZILIYOR olabilir: FileShare.ReadWrite|Delete sart.
//
// DIL KISITI: C# 5. Bkz. ParallelExecutor.cs basligi.

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace ExchangeDiag
{
    /// <summary>Bir satirin alanlarini kopyalamadan isaretleyen ayirici.</summary>
    public class CsvLineSplitter
    {
        private int[] _start = new int[64];
        private int[] _length = new int[64];
        private int _count;
        private string _line;
        private bool _unterminatedQuote;
        private bool _quoteResidue;

        public int Count { get { return _count; } }

        /// <summary>
        /// Tirnak acildi ama satir icinde KAPANMADI. Pratikteki sebebi
        /// genellikle masum: Exchange dosyaya o anda yaziyor ve okuyucu
        /// (FileShare.ReadWrite ile acildigi icin) son satiri yarim yakaladi.
        /// Sonucu masum degildir: virgul alan ayiraci olmaktan cikar ve
        /// satirin geri kalani TEK alana yutulur.
        /// </summary>
        public bool HasUnterminatedQuote { get { return _unterminatedQuote; } }

        /// <summary>
        /// Kapanis tirnagindan sonra ayirac yerine metin geldi (orn. a,"b"x,c).
        /// Artik metin KENDI alanini acar ve sagindaki her kolon bir saga kayar.
        /// </summary>
        public bool HasQuoteResidue { get { return _quoteResidue; } }

        /// <summary>
        /// Satir kendi icinde tutarsiz. Alanlar yine de uretilir - hangi
        /// kolonun kaydigi burada bilinemez, karari cagiran taraf verir -
        /// ama satirin GUVENILMEZ oldugu artik soylenebilir.
        /// </summary>
        public bool IsMalformed { get { return _unterminatedQuote || _quoteResidue; } }

        /// <summary>
        /// Satiri alanlara boler. Alan METINLERI kopyalanmaz; yalnizca konum ve
        /// uzunluk tutulur, boylece 30 kolonluk bir satirda sadece ihtiyac
        /// duyulan 5 alan icin string ayrilir.
        /// </summary>
        public void Split(string line)
        {
            _line = line;
            _count = 0;
            // Literal tablosu da sifirlanmali: kacisli tirnak iceren her satir
            // buraya bir string ekler ve temizlenmezse dosya boyunca birikir.
            if (_literals != null) _literals.Clear();
            // Bozukluk bayraklari da SATIR BASINA sifirlanir; aksi halde bir
            // dosyadaki tek bozuk satir, ayni ayirici nesnesi yeniden
            // kullanildigi icin kalan tum satirlari bozuk gosterirdi.
            _unterminatedQuote = false;
            _quoteResidue = false;

            int i = 0;
            int n = line.Length;
            while (i <= n)
            {
                if (i == n)
                {
                    Add(i, 0);
                    break;
                }

                if (line[i] == '"')
                {
                    // Tirnakli alan: icinde virgul olabilir (orn. cok alicili
                    // recipient-address). Naif Split(',') bunu bozar.
                    int start = ++i;
                    StringBuilder unescaped = null;
                    while (i < n)
                    {
                        if (line[i] == '"')
                        {
                            if (i + 1 < n && line[i + 1] == '"')
                            {
                                // Kacisli tirnak: "" -> "
                                if (unescaped == null)
                                {
                                    unescaped = new StringBuilder();
                                    unescaped.Append(line, start, i - start);
                                }
                                unescaped.Append('"');
                                i += 2;
                                continue;
                            }
                            break;
                        }
                        if (unescaped != null) unescaped.Append(line[i]);
                        i++;
                    }

                    if (unescaped != null)
                    {
                        AddLiteral(unescaped.ToString());
                    }
                    else
                    {
                        Add(start, i - start);
                    }

                    // Kapanis tirnagini ve ayiraci atla.
                    // Buradaki iki "else" dali eskiden yoktu: ayirici satirin
                    // bozuk oldugunu GORUYOR ama kimseye soylemiyordu.
                    if (i < n && line[i] == '"') i++;
                    else _unterminatedQuote = true;   // i >= n: tirnak hic kapanmadi

                    if (i < n && line[i] == ',') i++;
                    else if (i >= n) break;
                    else _quoteResidue = true;        // tirnaktan sonra ayirac degil metin var
                }
                else
                {
                    int start = i;
                    while (i < n && line[i] != ',') i++;
                    Add(start, i - start);
                    if (i < n) i++;
                    else break;
                }
            }
        }

        private List<string> _literals;

        private void Add(int start, int length)
        {
            EnsureCapacity();
            _start[_count] = start;
            _length[_count] = length;
            _count++;
        }

        private void AddLiteral(string value)
        {
            if (_literals == null) _literals = new List<string>();
            _literals.Add(value);
            EnsureCapacity();
            _start[_count] = -_literals.Count;   // negatif = literal tablosunda
            _length[_count] = 0;
            _count++;
        }

        private void EnsureCapacity()
        {
            if (_count < _start.Length) return;
            Array.Resize(ref _start, _start.Length * 2);
            Array.Resize(ref _length, _length.Length * 2);
        }

        public string GetField(int index)
        {
            if (index < 0 || index >= _count) return null;
            int start = _start[index];
            if (start < 0) return _literals[-start - 1];
            if (_length[index] == 0) return string.Empty;
            return _line.Substring(start, _length[index]);
        }

        /// <summary>
        /// Bu satirda boyle bir kolon VAR MI? "Kolon yok" ile "kolon bos"
        /// AYRI iddialardir ve ayri sorulmalidir.
        /// </summary>
        public bool HasField(int index)
        {
            return index >= 0 && index < _count;
        }

        /// <summary>
        /// Kolon var ve BOS mu?
        ///
        /// Eskiden kapsam disi indekste de true donuyordu. O davranis, sema
        /// kaymis bir dosyada HIC OLMAYAN bir kolonu, var olup bos birakilmis
        /// bir kolondan ayirt edilemez kiliyordu: cagiran taraf "bu alan bos"
        /// diye dogru bir cevap aldigini saniyordu, oysa aldigi cevap
        /// "boyle bir alan yok" idi.
        ///
        /// Uc durum (yok / bos / dolu) icin yeni bir enum eklemek yerine iki
        /// yuklem tutuldu: HasField(i) ve IsFieldEmpty(i). Birlikte okununca
        /// ucunu de verirler ve hicbir cagriyi imza degisikligine zorlamazlar.
        /// </summary>
        public bool IsFieldEmpty(int index)
        {
            if (index < 0 || index >= _count) return false;
            if (_start[index] < 0) return _literals[-_start[index] - 1].Length == 0;
            return _length[index] == 0;
        }

        /// <summary>Alani string ayirmadan karsilastirir (sicak yol).</summary>
        public bool FieldEquals(int index, string value)
        {
            if (index < 0 || index >= _count) return false;
            if (_start[index] < 0) return string.Equals(_literals[-_start[index] - 1], value, StringComparison.OrdinalIgnoreCase);
            if (_length[index] != value.Length) return false;
            return string.Compare(_line, _start[index], value, 0, value.Length, StringComparison.OrdinalIgnoreCase) == 0;
        }

        /// <summary>UTC zaman damgasini string ayirmadan cozer.</summary>
        public bool TryGetUtc(int index, out DateTime value)
        {
            value = DateTime.MinValue;
            if (index < 0 || index >= _count) return false;
            if (_start[index] < 0) return TrackingLogParser.TryParseUtc(_literals[-_start[index] - 1], 0, _literals[-_start[index] - 1].Length, out value);
            return TrackingLogParser.TryParseUtc(_line, _start[index], _length[index], out value);
        }
    }

    /// <summary>Kanit CSV'sine yazilacak tek bir yavas teslim kaydi.</summary>
    public class SlowDelivery
    {
        public DateTime TimestampUtc;
        public double LatencySeconds;
        public string Recipient;
        public string Sender;
        public string Subject;
        public string NetworkMessageId;     // Exchange ic kimligi (network-message-id)
        public string MessageId;            // RFC 5322 SMTP basligi (message-id) - ayri kimliktir
        public string Source;
        public string ServerHostname;
    }

    /// <summary>
    /// Esigi asan teslimlerin alici bazinda toplami. M12 bu listeyi posta
    /// kutusu -> veritabani eslemesine besler; ham satirlar PowerShell'e
    /// tasinmaz.
    /// </summary>
    public class RecipientLatency
    {
        public string Recipient;
        public long Count;
        public double MaxSeconds;
        public double SumSeconds;

        public double MeanSeconds
        {
            get { return Count > 0 ? SumSeconds / Count : 0d; }
        }
    }

    /// <summary>Bir sunucunun teslim gecikmesi analizi.</summary>
    public class DeliveryLatencyAnalysis
    {
        public string Server;
        public string Via;                  // "smb" | "cmdlet"
        public long FilesScanned;          // pencereyle kesisen dosya sayisi
        public long FilesProcessed;        // gercekten islenen dosya sayisi
        public bool Truncated;             // zaman siniri kesti: SONUC KISMI
        public bool ReadFailed;            // okuma basarisiz: "veri yok" ile ayni sey DEGIL
        public long LinesScanned;
        public long MalformedLines;         // semaya uymayan satirlar: ATILDI ama SAYILDI
        public long DeliverEvents;
        public long LatencyComputed;
        public long LatencyMissing;         // message-info'dan gonderim zamani cikarilamayan kayitlar
        public long NegativeLatency;        // saat kaymasi kaynakli; kirpilmaz, atilir

        /// <summary>
        /// Bozuk satirlarin taranan satirlara orani. Ham sayi tek basina
        /// yetmez ("4 satir" 11 satirda mi 1.2 milyonda mi?), oran da tek
        /// basina yetmez (bkz. TrackingLogParser.ShouldWarnMalformed).
        /// </summary>
        public double MalformedLineRatio
        {
            get { return LinesScanned > 0 ? (double)MalformedLines / LinesScanned : 0d; }
        }
        public double SlowThresholdSeconds;
        public long SlowDeliveryCount;
        public Stats Overall;
        public Dictionary<int, Stats> ByHourLocal;   // yerel saat 0-23
        public List<SlowDelivery> Slowest;
        public List<RecipientLatency> SlowRecipients;
        public List<string> Warnings;
        public double ElapsedMs;

        public DeliveryLatencyAnalysis()
        {
            Overall = new Stats();
            ByHourLocal = new Dictionary<int, Stats>();
            Slowest = new List<SlowDelivery>();
            SlowRecipients = new List<RecipientLatency>();
            Warnings = new List<string>();
            Via = "smb";
        }
    }

    /// <summary>Log dosyasinin hangi servise ait oldugu - faz kirilimi buna dayanir.</summary>
    public enum TrackingLogKind
    {
        Transport = 0,          // MSGTRK*      - Transport service
        MailboxDelivery = 1,    // MSGTRKMD*    - Mailbox Transport Delivery (DELIVER burada)
        MailboxSubmission = 2,  // MSGTRKMS*    - Mailbox Transport Submission
        Approval = 3            // MSGTRKMA*    - moderasyon
    }

    /// <summary>Tek bir mesajin fazlar arasi izi.</summary>
    public class MessageTrace
    {
        public DateTime SubmitUtc;
        public DateTime TransportReceiveUtc;
        public DateTime MailboxReceiveUtc;
        public DateTime DeliverUtc;
        public bool HasSubmit;
        public bool HasTransportReceive;
        public bool HasMailboxReceive;
        public bool HasDeliver;
    }

    /// <summary>
    /// Gecikmenin hangi asamada olustugunun kirilimi (brief orgusu P2).
    /// Toplam gecikme tek basina "nerede yavasladi" sorusunu cevaplamaz.
    /// </summary>
    public class PhaseBreakdown
    {
        public string Server;
        public long FilesScanned;
        public long LinesScanned;
        public long MalformedLines;         // semaya uymayan satirlar: ATILDI ama SAYILDI
        public long MessagesSeen;
        public long MessagesComplete;       // faz zinciri TAM olan mesajlar = PhaseSamples
        public long SkewedSamples;          // sunucular arasi saat kaymasi -> negatif faz
        public bool TruncatedByLimit;      // maxMessages siniri
        public bool Truncated;             // zaman siniri kesti: KIRILIM KISMI
        public long FilesProcessed;

        public Stats Total;                 // DELIVER - gonderim (uctan uca), GENIS nufus
        public Stats Ingress;               // Transport RECEIVE - gonderim
        public Stats Transport;             // Mailbox RECEIVE - Transport RECEIVE
        public Stats Store;                 // DELIVER - Mailbox RECEIVE  (DeliveryToMailbox)

        // --- Nufus muhasebesi -------------------------------------------
        // Uc faz ayni mesaj kumesinden hesaplanir (bkz. AnalyzePhaseBreakdown).
        // Uctan uca (Total) ise BILEREK daha genis tutulur: ara olaylari
        // pencere disinda kalmis yavas mesajlari raporun disina atmak,
        // "her sey yolunda" diyen daha beter bir yalan olurdu. Bu yuzden iki
        // nufusun da sayisi ACIKCA tasinir.
        public long PhaseSamples;           // uc fazin da dayandigi mesaj sayisi
        public long MessagesWithTotal;      // uctan uca olculebilen mesaj sayisi (= Total.Count)
        public long UnreconciledSamples;    // uctan uca var ama faz zinciri eksik
        public Stats TotalReconciled;       // faz karsilastirmasinin uctan uca karsiligi
        public Stats UnreconciledTotal;     // zinciri eksik mesajlarin uctan uca dagilimi

        /// <summary>
        /// Zinciri eksik kalan mesajlar, zinciri tam olanlardan BELIRGIN
        /// SEKILDE yavas. Yani baskin faz hukmu, tam da aciklanmasi gereken
        /// mesajlari disarida birakarak verildi.
        /// </summary>
        public bool PhaseVerdictIncomplete;

        public string DominantPhase;        // p95'i en buyuk olan faz
        public List<string> Warnings;
        public double ElapsedMs;

        public double MalformedLineRatio
        {
            get { return LinesScanned > 0 ? (double)MalformedLines / LinesScanned : 0d; }
        }

        public PhaseBreakdown()
        {
            Total = new Stats();
            Ingress = new Stats();
            Transport = new Stats();
            Store = new Stats();
            TotalReconciled = new Stats();
            UnreconciledTotal = new Stats();
            Warnings = new List<string>();
            DominantPhase = "N/A";
        }
    }

    public static class TrackingLogParser
    {
        // Saat anahtarlari StatsAccumulator string bekledigi icin onceden
        // uretilir; aksi halde her satir icin bir ToString() ayrilir.
        private static readonly string[] HourKeys = BuildHourKeys();

        private static string[] BuildHourKeys()
        {
            string[] keys = new string[24];
            for (int h = 0; h < 24; h++) keys[h] = h.ToString(CultureInfo.InvariantCulture);
            return keys;
        }

        // ---------------------------------------------------------------
        // Bozuk satir politikasi
        //
        // NEDEN HEM SAYI HEM ORAN
        // Ham sayi tek basina okunamaz: "4 bozuk satir" 11 satirlik bir
        // dosyada felaket, 1.2 milyon satirlik bir dosyada ise yazilmakta
        // olan son satirdir. Oran tek basina da yetmez: cok buyuk bir
        // dosyada sistematik bir bozulma (orn. tirnaklanmamis bir kolon
        // uretiliyor) binlerce satiri yutsa bile oran esigin altinda kalir.
        // Bu yuzden SAYAC her zaman analiz nesnesine ulasir (sessiz kayip
        // olmaz), UYARI ise iki esikten biri asilinca uretilir (gurultu
        // olmaz - her calistirmada uyari veren bir arac okunmaz hale gelir).
        private const double MalformedRatioWarn = 0.001;    // binde 1
        private const long MalformedAbsoluteWarn = 1000;    // oran kucuk olsa da sistematik

        private static bool ShouldWarnMalformed(long malformed, long scanned)
        {
            if (malformed <= 0) return false;
            if (malformed >= MalformedAbsoluteWarn) return true;
            if (scanned <= 0) return true;
            return ((double)malformed / scanned) >= MalformedRatioWarn;
        }

        private static string MalformedWarning(long malformed, long scanned)
        {
            double ratio = scanned > 0 ? (double)malformed / scanned : 1d;
            return malformed.ToString(CultureInfo.InvariantCulture) + " satir (%" +
                   (ratio * 100d).ToString("F2", CultureInfo.InvariantCulture) +
                   ") semaya uymadi (alan sayisi #Fields kolon sayisiyla ayni degil ya da tirnak " +
                   "kapanmamis); bu satirlar ATILDI. Sonuc log'un TAMAMINI temsil etmiyor.";
        }

        /// <summary>
        /// Satir semaya uyuyor mu?
        ///
        /// Alan sayisi basliktaki kolon sayisindan farkliysa o satirdaki
        /// HICBIR kolona guvenilemez: kaymanin nerede basladigi bilinemez.
        /// "date-time ve event-id yerinde duruyor gibi" gorunmesi yanilticidir -
        /// a,"b"x,c orneginde suclu alanin SAGINDAKI her kolon bir saga kayar,
        /// yani satir dogru event-id ile yanlis message-info tasiyabilir.
        /// Bu yuzden satir kismen kurtarilmaya calisilmaz, atilir ve sayilir.
        ///
        /// expectedFields &lt;= 1 ise karsilastirma yapilmaz: tek kolonluk bir
        /// #Fields satiri semanin kendisi supheli demektir ve o durumda
        /// virgul iceren HER satiri bozuk saymak butun dosyayi yok ederdi.
        /// </summary>
        private static bool IsRowMalformed(CsvLineSplitter splitter, int expectedFields)
        {
            if (splitter.IsMalformed) return true;
            return expectedFields > 1 && splitter.Count != expectedFields;
        }

        // Tracking log kolon adlari. #Fields: satirindan dinamik haritalanir.
        private const string ColDateTime = "date-time";
        private const string ColEventId = "event-id";
        private const string ColMessageInfo = "message-info";
        private const string ColRecipient = "recipient-address";
        private const string ColSender = "sender-address";
        private const string ColSubject = "message-subject";
        private const string ColNetworkId = "network-message-id";
        private const string ColMessageId = "message-id";
        private const string ColSource = "source";
        private const string ColServer = "server-hostname";

        // ---------------------------------------------------------------
        // Dosya kesfi
        // ---------------------------------------------------------------

        /// <summary>
        /// Pencereyle kesisebilecek log dosyalarini bulur.
        /// Dosya adi eleme KABADIR (dosya adi sunucunun yerel tarihini tasir,
        /// satirlar ise UTC'dir); kesin eleme satir seviyesinde yapilir. Bu
        /// yuzden bir gun pay birakilir.
        /// </summary>
        public static string[] FindLogFiles(string directory, string filePrefix, DateTime startUtc, DateTime endUtc)
        {
            if (string.IsNullOrEmpty(directory) || !Directory.Exists(directory))
                return new string[0];

            string pattern = (string.IsNullOrEmpty(filePrefix) ? "MSGTRK" : filePrefix) + "*.LOG";
            string[] all = Directory.GetFiles(directory, pattern);

            DateTime lowerBound = startUtc.AddDays(-1);
            DateTime upperBound = endUtc.AddDays(1);

            List<string> selected = new List<string>();
            foreach (string path in all)
            {
                DateTime fileDate;
                if (TryParseDateFromFileName(Path.GetFileName(path), out fileDate))
                {
                    if (fileDate < lowerBound.Date || fileDate > upperBound.Date) continue;
                }
                else
                {
                    // Ad cozulemezse son yazma zamanina bakilir.
                    try
                    {
                        if (File.GetLastWriteTimeUtc(path) < lowerBound) continue;
                    }
                    catch (Exception) { }
                }
                selected.Add(path);
            }

            selected.Sort(StringComparer.OrdinalIgnoreCase);
            return selected.ToArray();
        }

        /// <summary>MSGTRKMD20260917-1.LOG -> 2026-09-17</summary>
        public static bool TryParseDateFromFileName(string fileName, out DateTime date)
        {
            date = DateTime.MinValue;
            if (string.IsNullOrEmpty(fileName)) return false;

            for (int i = 0; i + 8 <= fileName.Length; i++)
            {
                if (!IsDigits(fileName, i, 8)) continue;
                int year = ParseInt(fileName, i, 4);
                int month = ParseInt(fileName, i + 4, 2);
                int day = ParseInt(fileName, i + 6, 2);
                if (year < 2000 || year > 2100 || month < 1 || month > 12 || day < 1 || day > 31) continue;
                try
                {
                    date = new DateTime(year, month, day);
                    return true;
                }
                catch (Exception) { return false; }
            }
            return false;
        }

        private static bool IsDigits(string text, int start, int count)
        {
            for (int i = start; i < start + count; i++)
            {
                if (i >= text.Length) return false;
                if (text[i] < '0' || text[i] > '9') return false;
            }
            return true;
        }

        private static int ParseInt(string text, int start, int count)
        {
            int value = 0;
            for (int i = start; i < start + count; i++) value = value * 10 + (text[i] - '0');
            return value;
        }

        // ---------------------------------------------------------------
        // Zaman ayristirma
        // ---------------------------------------------------------------

        /// <summary>
        /// "2026-09-17T08:00:00.123Z" bicimini elle cozer. DateTime.TryParseExact
        /// satir basina cagrildiginda olcuulebilir bir maliyet olusturur; bu
        /// hizli yol sicak dongude kullanilir, cozulemezse genel ayristiriciya
        /// dusulur.
        /// </summary>
        public static bool TryParseUtc(string text, int start, int length, out DateTime value)
        {
            value = DateTime.MinValue;
            if (text == null || length < 19) return false;

            if (text[start + 4] == '-' && text[start + 7] == '-' &&
                (text[start + 10] == 'T' || text[start + 10] == ' ') &&
                text[start + 13] == ':' && text[start + 16] == ':' &&
                IsDigits(text, start, 4) && IsDigits(text, start + 5, 2) && IsDigits(text, start + 8, 2) &&
                IsDigits(text, start + 11, 2) && IsDigits(text, start + 14, 2) && IsDigits(text, start + 17, 2))
            {
                int year = ParseInt(text, start, 4);
                int month = ParseInt(text, start + 5, 2);
                int day = ParseInt(text, start + 8, 2);
                int hour = ParseInt(text, start + 11, 2);
                int minute = ParseInt(text, start + 14, 2);
                int second = ParseInt(text, start + 17, 2);

                int millisecond = 0;
                if (length > 20 && text[start + 19] == '.')
                {
                    int digits = 0;
                    int index = start + 20;
                    while (digits < 3 && index < start + length && text[index] >= '0' && text[index] <= '9')
                    {
                        millisecond = millisecond * 10 + (text[index] - '0');
                        digits++;
                        index++;
                    }
                    while (digits < 3) { millisecond *= 10; digits++; }
                }

                try
                {
                    value = new DateTime(year, month, day, hour, minute, second, millisecond, DateTimeKind.Utc);
                    return true;
                }
                catch (Exception) { return false; }
            }

            // Yedek yol: bicim beklenenden farkliysa genel ayristirici.
            string slice = text.Substring(start, length);
            DateTime parsed;
            if (DateTime.TryParse(slice, CultureInfo.InvariantCulture,
                                  DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out parsed))
            {
                value = DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
                return true;
            }
            return false;
        }

        /// <summary>
        /// message-info alanindan gonderim zamanini cikarir.
        /// Bicim: "2026-09-17T07:59:55.000Z;SRV=EXC01" - ilk ';' oncesi zaman
        /// damgasidir. MessageLatency = date-time - bu deger.
        /// </summary>
        public static bool TryParseSubmitTime(string messageInfo, out DateTime value)
        {
            value = DateTime.MinValue;
            if (string.IsNullOrEmpty(messageInfo)) return false;

            int end = messageInfo.IndexOf(';');
            if (end < 0) end = messageInfo.Length;
            if (end < 19) return false;

            return TryParseUtc(messageInfo, 0, end, out value);
        }

        // ---------------------------------------------------------------
        // Analiz
        // ---------------------------------------------------------------

        /// <summary>
        /// Bir sunucunun teslim gecikmesi persentillerini cikarir.
        /// Dosyalar paralel islenir; PowerShell tarafina yalnizca ozet doner.
        /// </summary>
        public static DeliveryLatencyAnalysis AnalyzeDeliveryLatency(
            string server, string directory, string filePrefix,
            DateTime startUtc, DateTime endUtc, int topSlowCount, int maxDegreeOfParallelism,
            double slowThresholdSeconds)
        {
            return AnalyzeDeliveryLatency(server, directory, filePrefix, startUtc, endUtc,
                                          topSlowCount, maxDegreeOfParallelism, slowThresholdSeconds,
                                          DateTime.MaxValue);
        }

        /// <summary>
        /// deadlineUtc: bu an gecildiginde taranmamis dosyalar atlanir ve sonuc
        /// KISMI doner (uyari eklenir). Yurutucunun TimeoutSeconds'i bu cagri
        /// basladiktan sonra fiilen uygulanamaz - PowerShell.Stop() senkrondur
        /// ve buradaki Parallel.ForEach durma istegini gormez. Gercek sinir budur.
        /// </summary>
        public static DeliveryLatencyAnalysis AnalyzeDeliveryLatency(
            string server, string directory, string filePrefix,
            DateTime startUtc, DateTime endUtc, int topSlowCount, int maxDegreeOfParallelism,
            double slowThresholdSeconds, DateTime deadlineUtc)
        {
            DeliveryLatencyAnalysis analysis = new DeliveryLatencyAnalysis();
            analysis.Server = server;
            analysis.SlowThresholdSeconds = slowThresholdSeconds;
            Stopwatch watch = Stopwatch.StartNew();

            string[] files;
            try
            {
                files = FindLogFiles(directory, filePrefix, startUtc, endUtc);
            }
            catch (Exception ex)
            {
                analysis.Warnings.Add("Log klasoru okunamadi (" + directory + "): " + ex.Message);
                watch.Stop();
                analysis.ElapsedMs = watch.Elapsed.TotalMilliseconds;
                return analysis;
            }

            analysis.FilesScanned = files.Length;
            if (files.Length == 0)
            {
                analysis.Warnings.Add("Pencereyle kesisen log dosyasi yok: " + directory + "\\" + filePrefix + "*.LOG");
                watch.Stop();
                analysis.ElapsedMs = watch.Elapsed.TotalMilliseconds;
                return analysis;
            }

            // FindLogFiles yavas bir SMB payinda dakikalar surebilir; bu noktada
            // butce bitmis olabilir ve o zaman tek dogru sey hemen donmektir.
            if (DateTime.UtcNow > deadlineUtc)
            {
                analysis.Truncated = true;
                analysis.Warnings.Add("Zaman siniri dosya listesi cikarilirken doldu; hicbir dosya okunmadi. SONUC YOK.");
                watch.Stop();
                analysis.ElapsedMs = watch.Elapsed.TotalMilliseconds;
                return analysis;
            }

            if (topSlowCount < 1) topSlowCount = 50;
            if (maxDegreeOfParallelism < 1) maxDegreeOfParallelism = Environment.ProcessorCount;

            object sync = new object();
            List<double> allLatencies = new List<double>();
            StatsAccumulator byHour = new StatsAccumulator();
            List<SlowDelivery> slowest = new List<SlowDelivery>();
            Dictionary<string, RecipientLatency> slowRecipients =
                new Dictionary<string, RecipientLatency>(StringComparer.OrdinalIgnoreCase);
            TimeZoneInfo localZone = TimeZoneInfo.Local;

            ParallelOptions options = new ParallelOptions();
            options.MaxDegreeOfParallelism = maxDegreeOfParallelism;

            long filesProcessed = 0;
            bool deadlineHit = false;
            Parallel.ForEach(files, options, delegate(string path, ParallelLoopState state)
            {
                // Butce dolduysa kalan dosyalara hic baslanmaz: elde olan kismi
                // sonucla donmek, hic donmemekten iyidir.
                if (DateTime.UtcNow > deadlineUtc) { state.Stop(); return; }

                FileAnalysis partial = AnalyzeFile(path, startUtc, endUtc, topSlowCount, localZone, slowThresholdSeconds, deadlineUtc);

                // Saat kovalari kilit DISINDA hazirlanir; kritik bolgede satir
                // basina degil kova basina tek cagri kalir.
                List<double>[] hourBuckets = new List<double>[24];
                for (int i = 0; i < partial.Latencies.Count; i++)
                {
                    int hour = partial.Hours[i];
                    if (hour < 0 || hour > 23) continue;
                    if (hourBuckets[hour] == null) hourBuckets[hour] = new List<double>();
                    hourBuckets[hour].Add(partial.Latencies[i]);
                }

                lock (sync)
                {
                    filesProcessed++;
                    // Dosya SAYISI yetmez: son dosyanin ortasinda kesilmek de
                    // kismi sonuctur ve o durumda sayilar esitlenir.
                    if (partial.DeadlineHit) deadlineHit = true;
                    analysis.LinesScanned += partial.LinesScanned;
                    analysis.MalformedLines += partial.MalformedLines;
                    analysis.DeliverEvents += partial.DeliverEvents;
                    analysis.LatencyComputed += partial.Latencies.Count;
                    analysis.LatencyMissing += partial.LatencyMissing;
                    analysis.NegativeLatency += partial.NegativeLatency;
                    analysis.SlowDeliveryCount += partial.SlowDeliveryCount;
                    allLatencies.AddRange(partial.Latencies);
                    for (int hour = 0; hour < 24; hour++)
                        byHour.AddRange(HourKeys[hour], hourBuckets[hour]);
                    slowest.AddRange(partial.Slowest);

                    foreach (KeyValuePair<string, RecipientLatency> pair in partial.SlowRecipients)
                    {
                        RecipientLatency existing;
                        if (slowRecipients.TryGetValue(pair.Key, out existing))
                        {
                            existing.Count += pair.Value.Count;
                            existing.SumSeconds += pair.Value.SumSeconds;
                            if (pair.Value.MaxSeconds > existing.MaxSeconds) existing.MaxSeconds = pair.Value.MaxSeconds;
                        }
                        else
                        {
                            slowRecipients[pair.Key] = pair.Value;
                        }
                    }

                    analysis.Warnings.AddRange(partial.Warnings);
                }
            });

            analysis.FilesProcessed = filesProcessed;
            if (deadlineHit || filesProcessed < files.Length)
            {
                analysis.Truncated = true;
                analysis.Warnings.Add("Zaman siniri asildi: " + files.Length + " dosyanin " +
                    filesProcessed + " tanesi islendi. SONUC KISMI - persentiller tam pencereyi temsil etmez.");
            }

            if (ShouldWarnMalformed(analysis.MalformedLines, analysis.LinesScanned))
                analysis.Warnings.Add(MalformedWarning(analysis.MalformedLines, analysis.LinesScanned));

            analysis.Overall = PercentileEngine.Compute(allLatencies);

            List<RecipientLatency> recipientList = new List<RecipientLatency>(slowRecipients.Values);
            recipientList.Sort(delegate(RecipientLatency a, RecipientLatency b)
            {
                int byCount = b.Count.CompareTo(a.Count);
                if (byCount != 0) return byCount;
                return b.MaxSeconds.CompareTo(a.MaxSeconds);
            });
            analysis.SlowRecipients = recipientList;

            foreach (string hourKey in byHour.Groups)
            {
                int hour;
                if (int.TryParse(hourKey, NumberStyles.Integer, CultureInfo.InvariantCulture, out hour))
                    analysis.ByHourLocal[hour] = byHour.Summarize(hourKey);
            }

            slowest.Sort(delegate(SlowDelivery a, SlowDelivery b) { return b.LatencySeconds.CompareTo(a.LatencySeconds); });
            if (slowest.Count > topSlowCount) slowest.RemoveRange(topSlowCount, slowest.Count - topSlowCount);
            analysis.Slowest = slowest;

            watch.Stop();
            analysis.ElapsedMs = watch.Elapsed.TotalMilliseconds;
            return analysis;
        }

        private class FileAnalysis
        {
            public long LinesScanned;
            public long MalformedLines;
            public long DeliverEvents;
            public long LatencyMissing;
            public long NegativeLatency;
            public long SlowDeliveryCount;
            public List<double> Latencies = new List<double>();
            public List<int> Hours = new List<int>();
            public List<SlowDelivery> Slowest = new List<SlowDelivery>();
            public Dictionary<string, RecipientLatency> SlowRecipients =
                new Dictionary<string, RecipientLatency>(StringComparer.OrdinalIgnoreCase);
            public bool DeadlineHit;
            // Tek string DEGIL: bir dosyada once sema hatasi, sonra bir istisna
            // olusabilir; ikincisi birincisini ezerse kok neden kaybolur.
            public List<string> Warnings = new List<string>();
        }

        private static FileAnalysis AnalyzeFile(string path, DateTime startUtc, DateTime endUtc,
                                                int topSlowCount, TimeZoneInfo localZone,
                                                double slowThresholdSeconds, DateTime deadlineUtc)
        {
            FileAnalysis result = new FileAnalysis();
            double slowestThreshold = 0d;

            try
            {
                // Log dosyalari o anda yaziliyor olabilir; paylasimli acilmali.
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                                                          FileShare.ReadWrite | FileShare.Delete, 65536))
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true, 65536))
                {
                    CsvLineSplitter splitter = new CsvLineSplitter();
                    int idxDateTime = -1, idxEvent = -1, idxInfo = -1, idxRecipient = -1;
                    int idxSender = -1, idxSubject = -1, idxNetworkId = -1, idxSource = -1, idxServer = -1;
                    int idxMessageId = -1;
                    int expectedFields = 0;
                    bool haveFields = false;

                    string line;
                    long rawLines = 0;
                    while ((line = reader.ReadLine()) != null)
                    {
                        // Granularite 64K ham satir: yavas bir SMB payinda bu
                        // birkac saniyelik asim demektir - 840 sn butce icinde kabul
                        // edilebilir, ama kesin bir kesme noktasi DEGILDIR.
                        // Kontrol HER satir icin gecerli olmali. Asagi tarafa
                        // konursa semasi uymayan (haveFields == false) bir dosya
                        // butceye hic bakilmadan sonuna kadar okunur.
                        if ((rawLines++ & 0xFFFF) == 0 && DateTime.UtcNow > deadlineUtc)
                        {
                            result.DeadlineHit = true;
                            result.Warnings.Add(Path.GetFileName(path) + ": zaman siniri asildi, dosya kismen okundu.");
                            break;
                        }

                        if (line.Length == 0) continue;

                        if (line[0] == '#')
                        {
                            // Sema HER dosyada yeniden okunur; surum kaymasi
                            // boylece hata degil, dinamik haritalama olur.
                            if (line.StartsWith("#Fields:", StringComparison.OrdinalIgnoreCase))
                            {
                                string[] names = line.Substring("#Fields:".Length).Split(',');
                                // Kolon SAYISI da sema kadar onemli: satirin
                                // alan sayisi bununla karsilastirilmazsa
                                // kaymis satirlar sessizce yanlis kolon okur.
                                expectedFields = names.Length;
                                idxDateTime = IndexOf(names, ColDateTime);
                                idxEvent = IndexOf(names, ColEventId);
                                idxInfo = IndexOf(names, ColMessageInfo);
                                idxRecipient = IndexOf(names, ColRecipient);
                                idxSender = IndexOf(names, ColSender);
                                idxSubject = IndexOf(names, ColSubject);
                                idxNetworkId = IndexOf(names, ColNetworkId);
                                idxMessageId = IndexOf(names, ColMessageId);
                                idxSource = IndexOf(names, ColSource);
                                idxServer = IndexOf(names, ColServer);
                                haveFields = idxDateTime >= 0 && idxEvent >= 0;
                                if (!haveFields)
                                    result.Warnings.Add(Path.GetFileName(path) + ": #Fields satirinda date-time/event-id yok.");
                            }
                            continue;
                        }

                        if (!haveFields) continue;

                        result.LinesScanned++;
                        splitter.Split(line);

                        // Semaya uymayan satir: atilir AMA sayilir. Eskiden
                        // yalnizca atiliyordu ve kismen bozuk bir log,
                        // tertemiz bir logdan ayirt edilemiyordu.
                        if (IsRowMalformed(splitter, expectedFields))
                        {
                            result.MalformedLines++;
                            continue;
                        }

                        // Once en ucuz eleme: olay tipi.
                        if (!splitter.FieldEquals(idxEvent, "DELIVER")) continue;

                        DateTime timestampUtc;
                        if (!splitter.TryGetUtc(idxDateTime, out timestampUtc)) continue;
                        if (timestampUtc < startUtc || timestampUtc > endUtc) continue;

                        result.DeliverEvents++;

                        // MessageLatency log'da kolon degildir: message-info
                        // alanindaki gonderim zamanindan turetilir.
                        // HasField iki soruyu birden cevaplar: kolon semada
                        // var mi (idx >= 0) ve BU SATIRDA var mi.
                        string messageInfo = splitter.HasField(idxInfo) ? splitter.GetField(idxInfo) : null;
                        DateTime submitUtc;
                        if (!TryParseSubmitTime(messageInfo, out submitUtc))
                        {
                            result.LatencyMissing++;
                            continue;
                        }

                        double seconds = (timestampUtc - submitUtc).TotalSeconds;
                        // Saat kaymasi negatif gecikme uretebilir; kirpilmaz,
                        // atilir - aksi halde persentiller sessizce bozulur.
                        // Yalnizca NegativeLatency artar: LatencyMissing "message-info
                        // ayristirilamadi" demektir; saat kaymasini oraya da yazmak
                        // iki sayaci bagimsiz okunamaz hale getirir.
                        if (seconds < 0) { result.NegativeLatency++; continue; }

                        result.Latencies.Add(seconds);
                        DateTime local = TimeZoneInfo.ConvertTimeFromUtc(timestampUtc, localZone);
                        result.Hours.Add(local.Hour);

                        // Esigi asan teslimlerin alicilari: M12'nin girdisi.
                        if (slowThresholdSeconds > 0 && seconds >= slowThresholdSeconds)
                        {
                            result.SlowDeliveryCount++;
                            string recipients = splitter.HasField(idxRecipient) ? splitter.GetField(idxRecipient) : null;
                            AddSlowRecipients(result.SlowRecipients, recipients, seconds);
                        }

                        if (result.Slowest.Count < topSlowCount || seconds > slowestThreshold)
                        {
                            SlowDelivery record = new SlowDelivery();
                            record.TimestampUtc = timestampUtc;
                            record.LatencySeconds = seconds;
                            // Eksik kolon icin N/A (null) uretilir; "kolon yok"
                            // ile "kolon bos" burada da ayni sey degildir.
                            record.Recipient = splitter.HasField(idxRecipient) ? splitter.GetField(idxRecipient) : null;
                            record.Sender = splitter.HasField(idxSender) ? splitter.GetField(idxSender) : null;
                            record.Subject = splitter.HasField(idxSubject) ? splitter.GetField(idxSubject) : null;
                            record.NetworkMessageId = splitter.HasField(idxNetworkId) ? splitter.GetField(idxNetworkId) : null;
                            record.MessageId = splitter.HasField(idxMessageId) ? splitter.GetField(idxMessageId) : null;
                            record.Source = splitter.HasField(idxSource) ? splitter.GetField(idxSource) : null;
                            record.ServerHostname = splitter.HasField(idxServer) ? splitter.GetField(idxServer) : null;
                            result.Slowest.Add(record);

                            if (result.Slowest.Count > topSlowCount * 2)
                            {
                                result.Slowest.Sort(delegate(SlowDelivery a, SlowDelivery b) { return b.LatencySeconds.CompareTo(a.LatencySeconds); });
                                result.Slowest.RemoveRange(topSlowCount, result.Slowest.Count - topSlowCount);
                                slowestThreshold = result.Slowest[result.Slowest.Count - 1].LatencySeconds;
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                result.Warnings.Add(Path.GetFileName(path) + ": " + ex.GetType().Name + " - " + ex.Message);
            }

            return result;
        }

        private static int IndexOf(string[] names, string target)
        {
            for (int i = 0; i < names.Length; i++)
            {
                if (string.Equals(names[i].Trim(), target, StringComparison.OrdinalIgnoreCase)) return i;
            }
            return -1;
        }

        /// <summary>
        /// recipient-address alani birden cok aliciyi ';' ile ayirir (ve o yuzden
        /// tirnak icinde gelir). Her alici ayri sayilir.
        /// </summary>
        private static void AddSlowRecipients(Dictionary<string, RecipientLatency> target,
                                              string recipientField, double seconds)
        {
            if (string.IsNullOrEmpty(recipientField)) return;

            int start = 0;
            while (start <= recipientField.Length)
            {
                int end = recipientField.IndexOf(';', start);
                if (end < 0) end = recipientField.Length;

                int length = end - start;
                if (length > 0)
                {
                    string recipient = recipientField.Substring(start, length).Trim();
                    if (recipient.Length > 0)
                    {
                        RecipientLatency entry;
                        if (!target.TryGetValue(recipient, out entry))
                        {
                            entry = new RecipientLatency();
                            entry.Recipient = recipient;
                            target[recipient] = entry;
                        }
                        entry.Count++;
                        entry.SumSeconds += seconds;
                        if (seconds > entry.MaxSeconds) entry.MaxSeconds = seconds;
                    }
                }

                if (end >= recipientField.Length) break;
                start = end + 1;
            }
        }

        // ---------------------------------------------------------------
        // Faz kirilimi (M11 / orgu P2)
        // ---------------------------------------------------------------

        /// <summary>Dosya adindan hangi servise ait oldugunu cikarir.</summary>
        public static TrackingLogKind ClassifyLogFile(string fileName)
        {
            string name = Path.GetFileName(fileName);
            if (name == null) return TrackingLogKind.Transport;
            if (name.StartsWith("MSGTRKMD", StringComparison.OrdinalIgnoreCase)) return TrackingLogKind.MailboxDelivery;
            if (name.StartsWith("MSGTRKMS", StringComparison.OrdinalIgnoreCase)) return TrackingLogKind.MailboxSubmission;
            if (name.StartsWith("MSGTRKMA", StringComparison.OrdinalIgnoreCase)) return TrackingLogKind.Approval;
            return TrackingLogKind.Transport;
        }

        /// <summary>
        /// Gecikmeyi asamalara ayirir. Mesajlar network-message-id uzerinden
        /// birlestirilir:
        ///
        ///   gonderim (message-info)
        ///        |  Ingress   : Transport RECEIVE - gonderim
        ///   Transport RECEIVE
        ///        |  Transport : Mailbox RECEIVE - Transport RECEIVE
        ///   Mailbox  RECEIVE  (MSGTRKMD)
        ///        |  Store     : DELIVER - Mailbox RECEIVE   <- DeliveryToMailbox
        ///   DELIVER
        ///
        /// Store fazi baskinsa darbogaz transport'ta degil Store tarafindadir
        /// (orgu P2) ve arastirma M20/M21/M22'ye kayar.
        ///
        /// NUFUS: uc faz da YALNIZCA zinciri tam olan mesajlardan hesaplanir
        /// (PhaseSamples). Boylece uc sutun ayni mesaj kumesini anlatir ve
        /// Ingress + Transport + Store = TotalReconciled olur. Uctan uca
        /// (Total) daha genis bir kumeden gelir - zinciri eksik ama teslim
        /// edilmis mesajlar da sayilir - ve kac mesajdan geldigi
        /// MessagesWithTotal ile ayrica bildirilir. Iki kume arasindaki fark
        /// hukmu degistirecek kadar buyukse PhaseVerdictIncomplete isaretlenir.
        ///
        /// Cok alicili mesajlar ayni network-message-id ile birden cok DELIVER
        /// satiri uretir; mesajin tamamlanma suresi icin EN GEC DELIVER, giris
        /// icin EN ERKEN RECEIVE alinir.
        /// </summary>
        public static PhaseBreakdown AnalyzePhaseBreakdown(
            string server, string directory, DateTime startUtc, DateTime endUtc,
            int maxMessages, int maxDegreeOfParallelism)
        {
            return AnalyzePhaseBreakdown(server, directory, startUtc, endUtc,
                                         maxMessages, maxDegreeOfParallelism, DateTime.MaxValue);
        }

        /// <summary>
        /// deadlineUtc: AnalyzeDeliveryLatency ile ayni kooperatif sinir.
        /// Butce dolunca kalan dosyalar atlanir ve kirilim KISMI doner.
        /// </summary>
        public static PhaseBreakdown AnalyzePhaseBreakdown(
            string server, string directory, DateTime startUtc, DateTime endUtc,
            int maxMessages, int maxDegreeOfParallelism, DateTime deadlineUtc)
        {
            PhaseBreakdown breakdown = new PhaseBreakdown();
            breakdown.Server = server;
            Stopwatch watch = Stopwatch.StartNew();

            string[] files;
            try
            {
                // Faz kirilimi hem Transport hem Mailbox Delivery log'larini ister.
                files = FindLogFiles(directory, "MSGTRK", startUtc, endUtc);
            }
            catch (Exception ex)
            {
                breakdown.Warnings.Add("Log klasoru okunamadi (" + directory + "): " + ex.Message);
                watch.Stop();
                breakdown.ElapsedMs = watch.Elapsed.TotalMilliseconds;
                return breakdown;
            }

            breakdown.FilesScanned = files.Length;
            if (files.Length == 0)
            {
                breakdown.Warnings.Add("Pencereyle kesisen log dosyasi yok: " + directory);
                watch.Stop();
                breakdown.ElapsedMs = watch.Elapsed.TotalMilliseconds;
                return breakdown;
            }

            if (maxMessages < 1) maxMessages = 1000000;
            if (maxDegreeOfParallelism < 1) maxDegreeOfParallelism = Environment.ProcessorCount;

            ConcurrentDictionary<string, MessageTrace> traces =
                new ConcurrentDictionary<string, MessageTrace>(StringComparer.OrdinalIgnoreCase);
            long linesScanned = 0;
            long malformedLines = 0;
            bool truncated = false;
            long filesProcessed = 0;
            object sync = new object();

            ParallelOptions options = new ParallelOptions();
            options.MaxDegreeOfParallelism = maxDegreeOfParallelism;

            bool deadlineHit = false;
            Parallel.ForEach(files, options, delegate(string path, ParallelLoopState state)
            {
                if (DateTime.UtcNow > deadlineUtc)
                {
                    lock (sync) { deadlineHit = true; }
                    state.Stop();
                    return;
                }

                long localLines = 0;
                long localMalformed = 0;
                bool localTruncated = false;
                bool localDeadline = false;
                // Tek uyari alani yerine liste: sema hatasi sonrasi gelen bir
                // istisna ilk mesaji ezmemeli.
                List<string> localWarnings = new List<string>();
                TrackingLogKind kind = ClassifyLogFile(path);

                // Submission ve moderasyon log'lari bu kirilimda kullanilmaz.
                // Islenmis sayilir: aksi halde "kismi sonuc" sayimi yanilir.
                if (kind == TrackingLogKind.MailboxSubmission || kind == TrackingLogKind.Approval)
                {
                    lock (sync) { filesProcessed++; }
                    return;
                }

                try
                {
                    using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                                                              FileShare.ReadWrite | FileShare.Delete, 65536))
                    using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true, 65536))
                    {
                        CsvLineSplitter splitter = new CsvLineSplitter();
                        int idxDateTime = -1, idxEvent = -1, idxInfo = -1, idxNetworkId = -1;
                        int expectedFields = 0;
                        bool haveFields = false;

                        string line;
                        long rawLines = 0;
                        while ((line = reader.ReadLine()) != null)
                        {
                            // Semadan bagimsiz kontrol; gerekce icin AnalyzeFile'a bakin.
                            if ((rawLines++ & 0xFFFF) == 0 && DateTime.UtcNow > deadlineUtc)
                            {
                                localDeadline = true;
                                localWarnings.Add(Path.GetFileName(path) + ": zaman siniri asildi, dosya kismen okundu.");
                                break;
                            }

                            if (line.Length == 0) continue;

                            if (line[0] == '#')
                            {
                                if (line.StartsWith("#Fields:", StringComparison.OrdinalIgnoreCase))
                                {
                                    string[] names = line.Substring("#Fields:".Length).Split(',');
                                    expectedFields = names.Length;
                                    idxDateTime = IndexOf(names, ColDateTime);
                                    idxEvent = IndexOf(names, ColEventId);
                                    idxInfo = IndexOf(names, ColMessageInfo);
                                    idxNetworkId = IndexOf(names, ColNetworkId);
                                    haveFields = idxDateTime >= 0 && idxEvent >= 0 && idxNetworkId >= 0;
                                    if (!haveFields)
                                        localWarnings.Add(Path.GetFileName(path) + ": faz kirilimi icin network-message-id/date-time/event-id gerekli, bulunamadi.");
                                }
                                continue;
                            }

                            if (!haveFields) continue;
                            localLines++;
                            splitter.Split(line);

                            // Kaymis bir satir yanlis network-message-id ile
                            // yanlis bir zincire yapisabilir; faz kirilimi bu
                            // yuzden bozuk satira HIC dokunmaz.
                            if (IsRowMalformed(splitter, expectedFields)) { localMalformed++; continue; }

                            bool isDeliver = splitter.FieldEquals(idxEvent, "DELIVER");
                            bool isReceive = !isDeliver && splitter.FieldEquals(idxEvent, "RECEIVE");
                            if (!isDeliver && !isReceive) continue;

                            // DELIVER yalnizca Mailbox Delivery log'undan sayilir.
                            if (isDeliver && kind != TrackingLogKind.MailboxDelivery) continue;

                            DateTime timestampUtc;
                            if (!splitter.TryGetUtc(idxDateTime, out timestampUtc)) continue;
                            if (timestampUtc < startUtc || timestampUtc > endUtc) continue;

                            string messageId = splitter.GetField(idxNetworkId);
                            if (string.IsNullOrEmpty(messageId)) continue;

                            MessageTrace trace;
                            if (!traces.TryGetValue(messageId, out trace))
                            {
                                if (traces.Count >= maxMessages) { localTruncated = true; continue; }
                                trace = new MessageTrace();
                                trace = traces.GetOrAdd(messageId, trace);
                            }

                            lock (trace)
                            {
                                if (isDeliver)
                                {
                                    // Cok alicili mesajda en gec DELIVER alinir.
                                    if (!trace.HasDeliver || timestampUtc > trace.DeliverUtc)
                                    {
                                        trace.DeliverUtc = timestampUtc;
                                        trace.HasDeliver = true;
                                    }
                                    if (!trace.HasSubmit && splitter.HasField(idxInfo))
                                    {
                                        DateTime submitUtc;
                                        if (TryParseSubmitTime(splitter.GetField(idxInfo), out submitUtc))
                                        {
                                            trace.SubmitUtc = submitUtc;
                                            trace.HasSubmit = true;
                                        }
                                    }
                                }
                                else if (kind == TrackingLogKind.MailboxDelivery)
                                {
                                    if (!trace.HasMailboxReceive || timestampUtc < trace.MailboxReceiveUtc)
                                    {
                                        trace.MailboxReceiveUtc = timestampUtc;
                                        trace.HasMailboxReceive = true;
                                    }
                                }
                                else
                                {
                                    if (!trace.HasTransportReceive || timestampUtc < trace.TransportReceiveUtc)
                                    {
                                        trace.TransportReceiveUtc = timestampUtc;
                                        trace.HasTransportReceive = true;
                                    }
                                }
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    localWarnings.Add(Path.GetFileName(path) + ": " + ex.GetType().Name + " - " + ex.Message);
                }

                lock (sync)
                {
                    filesProcessed++;
                    linesScanned += localLines;
                    malformedLines += localMalformed;
                    if (localTruncated) truncated = true;
                    if (localDeadline) deadlineHit = true;
                    breakdown.Warnings.AddRange(localWarnings);
                }
            });

            breakdown.FilesProcessed = filesProcessed;
            if (deadlineHit || filesProcessed < files.Length)
            {
                breakdown.Truncated = true;
                breakdown.Warnings.Add("Zaman siniri asildi: " + files.Length + " dosyanin " + filesProcessed +
                    " tanesi islendi. FAZ KIRILIMI KISMI - tum dosyalar okunmadi.");
            }

            breakdown.LinesScanned = linesScanned;
            breakdown.MalformedLines = malformedLines;
            if (ShouldWarnMalformed(malformedLines, linesScanned))
                breakdown.Warnings.Add(MalformedWarning(malformedLines, linesScanned));

            breakdown.MessagesSeen = traces.Count;
            breakdown.TruncatedByLimit = truncated;
            if (truncated)
                breakdown.Warnings.Add("Mesaj sayisi " + maxMessages.ToString(CultureInfo.InvariantCulture) +
                                       " sinirini asti; kirilim orneklemdir. Pencereyi daraltin.");

            // FAZLAR TEK BIR NUFUSTAN HESAPLANIR.
            //
            // Eskiden her fazin kendi kabul kosulu vardi: Store yalnizca
            // Mailbox RECEIVE istiyordu, Transport iki RECEIVE birden,
            // Ingress gonderim + Transport RECEIVE. Sonuc, yan yana basilan
            // ama FARKLI mesaj kumelerini anlatan dort sutundu ve kirilim
            // toplanmiyordu. Daha kotusu, sistematik olarak Store'a yanliydi:
            // ara olaylari pencere disinda kalan mesajlar - yani tam da EN
            // YAVAS olanlar - yalnizca Store ve Total'a giriyordu. 7195
            // saniyenin 7180'i mailbox receive'den ONCE gecmisken hukum
            // "darbogaz Store" cikiyordu ve arastirma yanlis yere (disk/RPC)
            // yonlendiriliyordu.
            //
            // Artik uc faz da YALNIZCA zinciri tam olan mesajlardan hesaplanir;
            // boylece Ingress + Transport + Store, ayni mesajin uctan uca
            // suresini verir ve karsilastirma anlamli olur.
            List<double> totals = new List<double>();
            List<double> reconciledTotals = new List<double>();
            List<double> unreconciledTotals = new List<double>();
            List<double> ingress = new List<double>();
            List<double> transport = new List<double>();
            List<double> store = new List<double>();
            long complete = 0;
            long skewed = 0;

            foreach (KeyValuePair<string, MessageTrace> pair in traces)
            {
                MessageTrace trace = pair.Value;
                if (!trace.HasDeliver) continue;

                double totalValue = 0d;
                bool hasTotal = false;
                if (trace.HasSubmit)
                {
                    totalValue = (trace.DeliverUtc - trace.SubmitUtc).TotalSeconds;
                    if (totalValue >= 0) hasTotal = true; else skewed++;
                }

                double ingressValue = 0d;
                bool hasIngress = false;
                if (trace.HasSubmit && trace.HasTransportReceive)
                {
                    ingressValue = (trace.TransportReceiveUtc - trace.SubmitUtc).TotalSeconds;
                    if (ingressValue >= 0) hasIngress = true; else skewed++;
                }

                double transportValue = 0d;
                bool hasTransport = false;
                if (trace.HasTransportReceive && trace.HasMailboxReceive)
                {
                    // Bu iki olay FARKLI SUNUCULARDA olabilir; saatleri kaymissa
                    // negatif cikar. Kirpilmaz, sayilir ve raporlanir.
                    transportValue = (trace.MailboxReceiveUtc - trace.TransportReceiveUtc).TotalSeconds;
                    if (transportValue >= 0) hasTransport = true; else skewed++;
                }

                double storeValue = 0d;
                bool hasStore = false;
                if (trace.HasMailboxReceive)
                {
                    storeValue = (trace.DeliverUtc - trace.MailboxReceiveUtc).TotalSeconds;
                    if (storeValue >= 0) hasStore = true; else skewed++;
                }

                // Uctan uca olcum BILEREK genis nufustan toplanir: zinciri
                // eksik diye en yavas mesajlari rapordan silmek, faz yanliligi
                // yerine "her sey yolunda" yalanini koyardi.
                if (hasTotal) totals.Add(totalValue);

                bool reconciled = hasTotal && hasIngress && hasTransport && hasStore;
                if (reconciled)
                {
                    ingress.Add(ingressValue);
                    transport.Add(transportValue);
                    store.Add(storeValue);
                    reconciledTotals.Add(totalValue);
                    complete++;
                }
                else if (hasTotal)
                {
                    unreconciledTotals.Add(totalValue);
                }
            }

            breakdown.MessagesComplete = complete;
            breakdown.PhaseSamples = complete;
            breakdown.SkewedSamples = skewed;
            breakdown.Total = PercentileEngine.Compute(totals);
            breakdown.MessagesWithTotal = breakdown.Total.Count;
            breakdown.TotalReconciled = PercentileEngine.Compute(reconciledTotals);
            breakdown.UnreconciledTotal = PercentileEngine.Compute(unreconciledTotals);
            breakdown.UnreconciledSamples = breakdown.UnreconciledTotal.Count;
            breakdown.Ingress = PercentileEngine.Compute(ingress);
            breakdown.Transport = PercentileEngine.Compute(transport);
            breakdown.Store = PercentileEngine.Compute(store);
            breakdown.DominantPhase = DetermineDominantPhase(breakdown);

            EvaluatePhaseCoverage(breakdown);

            if (skewed > 0)
                breakdown.Warnings.Add(skewed.ToString(CultureInfo.InvariantCulture) +
                    " ornek negatif faz suresi verdi (sunucular arasi saat kaymasi olabilir); bu ornekler atildi.");

            watch.Stop();
            breakdown.ElapsedMs = watch.Elapsed.TotalMilliseconds;
            return breakdown;
        }

        // Faz hukmunun kor noktasi icin esikler. Zinciri eksik kalan mesajlar
        // nadiren rastgeledir: bir mesajin RECEIVE olayi pencerenin onunde
        // kaldiysa o mesaj zaten uzun suredir yoldadir. Bu yuzden TEK BASINA
        // "eksik mesaj var" demek her kosuda uyari uretirdi. Uyari, eksik
        // kumenin hem KAYDA DEGER buyuklukte hem de BELIRGIN yavas oldugu
        // durumda cikar - yani hukmun yonunu degistirebilecegi durumda.
        private const double PhaseGapShareWarn = 0.01;      // uctan uca nufusun %1'i
        private const double PhaseGapSlownessWarn = 2.0;    // p95 orani

        /// <summary>
        /// Baskin faz hukmu, aciklanmasi gereken mesajlari disarida birakarak
        /// mi verildi? Birakildiysa bu SESSIZ kalmamalidir: operator aksi
        /// halde "darbogaz su fazda" cumlesini, en yavas mesajlarin hic
        /// bakilmadigini bilmeden okur.
        /// </summary>
        private static void EvaluatePhaseCoverage(PhaseBreakdown breakdown)
        {
            if (breakdown.UnreconciledSamples <= 0 || breakdown.Total.Count <= 0) return;

            double share = (double)breakdown.UnreconciledSamples / breakdown.Total.Count;

            // Zinciri tam hic mesaj yoksa karsilastirilacak taban da yoktur:
            // bu, gorunurlugun tamamen kayip oldugu en kotu durumdur.
            double slowness = double.MaxValue;
            if (breakdown.TotalReconciled.Count > 0 && breakdown.TotalReconciled.P95 > 0)
                slowness = breakdown.UnreconciledTotal.P95 / breakdown.TotalReconciled.P95;

            if (share < PhaseGapShareWarn || slowness < PhaseGapSlownessWarn) return;

            breakdown.PhaseVerdictIncomplete = true;
            breakdown.Warnings.Add(
                "Faz zinciri " + breakdown.Total.Count.ToString(CultureInfo.InvariantCulture) + " mesajin " +
                breakdown.UnreconciledSamples.ToString(CultureInfo.InvariantCulture) +
                " tanesinde tamamlanamadi (ara olaylar pencerenin disinda kalmis olabilir). Bu mesajlarin " +
                "uctan uca p95'i " + breakdown.UnreconciledTotal.P95.ToString("F2", CultureInfo.InvariantCulture) +
                " sn, zinciri tam olanlarinki " + breakdown.TotalReconciled.P95.ToString("F2", CultureInfo.InvariantCulture) +
                " sn: BASKIN FAZ HUKMU EN YAVAS MESAJLARI ICERMIYOR. Pencereyi -WindowHours ile GENISLETIN.");
        }

        private static string DetermineDominantPhase(PhaseBreakdown breakdown)
        {
            double ingress = breakdown.Ingress.Count > 0 ? breakdown.Ingress.P95 : -1d;
            double transport = breakdown.Transport.Count > 0 ? breakdown.Transport.P95 : -1d;
            double store = breakdown.Store.Count > 0 ? breakdown.Store.P95 : -1d;

            if (ingress < 0 && transport < 0 && store < 0) return "N/A";

            string dominant = "Ingress";
            double best = ingress;
            if (transport > best) { best = transport; dominant = "Transport"; }
            if (store > best) { best = store; dominant = "Store"; }
            return dominant;
        }
    }
}
