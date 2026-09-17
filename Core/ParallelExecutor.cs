// ExchangeDiag - ParallelExecutor
//
// Tum modullerin paylastigi tek yurutucu. Modullerin kendisi Invoke-Command
// cagirmaz; hedef + scriptblock + timeout bildirir, bu sinif kosturur.
//
// IKI AYRI HAVUZ vardir ve bu ayrim zorunludur:
//
//   ExchangePool : Exchange uzak yonetim uc noktasi (Microsoft.Exchange).
//                  KISITLI (constrained) bir runspace'tir - sadece Exchange
//                  cmdlet'leri vardir. Invoke-Command, Get-CimInstance,
//                  Get-Content orada YOKTUR.
//
//   LocalPool    : Yerel, tam dilli runspace. Makine seviyesindeki her sey
//                  (CIM, perf sayac, ExSetup.exe surumu, SMB uzerinden log
//                  dosyasi okuma) buradan yapilir.
//
// DIL KISITI: C# 5 (Add-Type -> .NET Framework csc.exe).
// String interpolation, ?., nameof, tuple, pattern matching KULLANILAMAZ.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ExchangeDiag
{
    /// <summary>
    /// Switch parametresi isareti. AddParameter("Status", SwitchOn.Value) yazmak,
    /// bool degerinin yanlislikla bir deger parametresine baglanmasini onler.
    /// </summary>
    public sealed class SwitchOn
    {
        public static readonly SwitchOn Value = new SwitchOn();
        private SwitchOn() { }
        public override string ToString() { return "<switch>"; }
    }

    /// <summary>
    /// Bir komut hattinin tek adimi. Exchange uc noktasi NO-LANGUAGE modunda
    /// oldugu icin oraya script METNI gonderilemez; yalnizca komut + parametre
    /// gonderilebilir. Adimlar ardisik eklenerek boru hatti kurulur.
    /// </summary>
    public class ExecStep
    {
        public string Command;
        public Dictionary<string, object> Parameters;

        public ExecStep()
        {
            Parameters = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        }

        public ExecStep(string command) : this()
        {
            Command = command;
        }

        public ExecStep AddParameter(string name, object value)
        {
            Parameters[name] = value;
            return this;
        }
    }

    /// <summary>Yurutulecek tek bir is birimi.</summary>
    public class ExecTask
    {
        public string Key;                              // sonucu eslestirmek icin (genelde sunucu adi)
        public string Script;                           // YALNIZCA tam dilli (yerel) havuz icin
        public Dictionary<string, object> Parameters;   // Script'in param() blogu icin
        public List<ExecStep> Steps;                    // Exchange havuzu icin komut hatti
        public int TimeoutSeconds;

        public ExecTask()
        {
            Parameters = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            Steps = new List<ExecStep>();
            TimeoutSeconds = 120;
        }

        public ExecTask(string key, string script) : this()
        {
            Key = key;
            Script = script;
        }

        public ExecTask(string key, string script, int timeoutSeconds) : this()
        {
            Key = key;
            Script = script;
            TimeoutSeconds = timeoutSeconds;
        }

        public ExecTask AddParameter(string name, object value)
        {
            Parameters[name] = value;
            return this;
        }

        /// <summary>Komut hattina bir adim ekler ve o adimi dondurur.</summary>
        public ExecStep AddCommand(string command)
        {
            ExecStep step = new ExecStep(command);
            Steps.Add(step);
            return step;
        }

        public bool IsCommandBased
        {
            get { return Steps != null && Steps.Count > 0; }
        }
    }

    /// <summary>Tek bir isin sonucu. Hata ve timeout durumu ayri ayri tasinir.</summary>
    public class ExecResult
    {
        public string Key;
        public PSObject[] Output;
        public string Error;
        public bool TimedOut;
        public double DurationMs;

        public bool Succeeded
        {
            get { return !TimedOut && Error == null; }
        }

        /// <summary>Rapor hucresine yazilacak durum etiketi.</summary>
        public string State
        {
            get
            {
                if (TimedOut) return "TIMEOUT";
                if (Error != null) return "ERROR";
                return "OK";
            }
        }
    }

    public class ParallelExecutor : IDisposable
    {
        private RunspacePool _exchangePool;
        private RunspacePool _localPool;
        private int _parallelism;
        private bool _disposed;
        private bool _exchangeIsConstrained;
        private int _abandonedPipelines;

        /// <summary>Exchange baglantisinin nasil kuruldugu - rapor basligina yazilir.</summary>
        public string ExchangeConnection = "none";

        public ParallelExecutor(int parallelism)
        {
            if (parallelism < 1) parallelism = 1;
            _parallelism = parallelism;
        }

        /// <summary>
        /// Zaman asimi nedeniyle terk edilmis (hala arka planda calisan) boru
        /// hatti sayisi. Sifirdan buyukse sonraki TIMEOUT'lar kapasite
        /// daralmasindan kaynaklaniyor olabilir - rapor bunu soylemelidir.
        /// </summary>
        public int AbandonedPipelines
        {
            get { return _abandonedPipelines; }
        }

        public int Parallelism
        {
            get { return _parallelism; }
        }

        // ---------------------------------------------------------------
        // Baglanti kurulumu
        // ---------------------------------------------------------------

        /// <summary>
        /// Exchange uzak yonetim uc noktasina havuz acar. Yerel makinede
        /// Exchange Management Tools KURULU OLMASI GEREKMEZ.
        /// </summary>
        public void ConnectExchangeRemote(string connectionUri, string authentication,
                                          PSCredential credential, int openTimeoutMs,
                                          int operationTimeoutMs, bool skipCertificateChecks)
        {
            WSManConnectionInfo ci = new WSManConnectionInfo(
                new Uri(connectionUri),
                "http://schemas.microsoft.com/powershell/Microsoft.Exchange",
                credential);

            ci.AuthenticationMechanism = ParseAuthentication(authentication);
            ci.OpenTimeout = openTimeoutMs > 0 ? openTimeoutMs : 60000;
            ci.OperationTimeout = operationTimeoutMs > 0 ? operationTimeoutMs : 300000;
            ci.MaximumConnectionRedirectionCount = 5;
            ci.SkipCACheck = skipCertificateChecks;
            ci.SkipCNCheck = skipCertificateChecks;

            RunspacePool pool = RunspaceFactory.CreateRunspacePool(1, _parallelism, ci);
            pool.Open();

            _exchangePool = pool;
            _exchangeIsConstrained = true;   // Microsoft.Exchange uc noktasi no-language modundadir
            ExchangeConnection = "remote " + connectionUri + " (" + ci.AuthenticationMechanism + ")";
        }

        /// <summary>
        /// Uzak baglanti kurulamadiginda yedek yol: yerel makinedeki Exchange
        /// snap-in'i ile tam dilli bir havuz. Yalnizca Exchange sunucusunda veya
        /// yonetim araclari kurulu bir makinede calisir.
        /// </summary>
        public void ConnectExchangeLocalSnapIn(string snapInName)
        {
            InitialSessionState iss = InitialSessionState.CreateDefault();
            PSSnapInException snapInError;
            iss.ImportPSSnapIn(snapInName, out snapInError);
            if (snapInError != null) throw snapInError;
            iss.ThreadOptions = PSThreadOptions.ReuseThread;

            RunspacePool pool = RunspaceFactory.CreateRunspacePool(iss);
            pool.SetMinRunspaces(1);
            pool.SetMaxRunspaces(_parallelism);
            pool.Open();

            _exchangePool = pool;
            _exchangeIsConstrained = false;  // yerel snap-in tam dillidir
            ExchangeConnection = "local snap-in " + snapInName;
        }

        /// <summary>Makine seviyesindeki isler icin yerel, tam dilli havuz.</summary>
        public void OpenLocalPool()
        {
            if (_localPool != null) return;
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ThreadOptions = PSThreadOptions.ReuseThread;

            RunspacePool pool = RunspaceFactory.CreateRunspacePool(iss);
            pool.SetMinRunspaces(1);
            pool.SetMaxRunspaces(_parallelism);
            pool.Open();
            _localPool = pool;
        }

        // ---------------------------------------------------------------
        // Yurutme
        // ---------------------------------------------------------------

        /// <summary>Exchange cmdlet'leri iceren isleri kosturur.</summary>
        public ExecResult[] RunExchange(ExecTask[] tasks)
        {
            if (_exchangePool == null)
                throw new InvalidOperationException("Exchange havuzu acik degil. Once ConnectExchangeRemote/ConnectExchangeLocalSnapIn cagirin.");

            if (_exchangeIsConstrained && tasks != null)
            {
                foreach (ExecTask task in tasks)
                {
                    if (task != null && !task.IsCommandBased)
                        throw new InvalidOperationException(
                            "Exchange uzak uc noktasi no-language modundadir; script metni calistirilamaz. " +
                            "'" + task.Key + "' isini AddCommand(...) ile komut hatti olarak kurun.");
                }
            }

            return RunAll(tasks, _exchangePool);
        }

        /// <summary>
        /// Exchange havuzu kisitli (no-language) mi? Uzak uc nokta icin true,
        /// yerel snap-in icin false.
        /// </summary>
        public bool ExchangeIsConstrained
        {
            get { return _exchangeIsConstrained; }
        }

        /// <summary>Makine seviyesindeki (CIM, perf, dosya) isleri kosturur.</summary>
        public ExecResult[] RunLocal(ExecTask[] tasks)
        {
            OpenLocalPool();
            return RunAll(tasks, _localPool);
        }

        /// <summary>
        /// Esme derecesi havuz boyutuna esittir; boylece bir isin timeout saati
        /// kuyrukta beklerken degil, gercekten baslarken isler.
        /// </summary>
        private ExecResult[] RunAll(ExecTask[] tasks, RunspacePool pool)
        {
            if (tasks == null || tasks.Length == 0) return new ExecResult[0];

            ExecResult[] results = new ExecResult[tasks.Length];
            ParallelOptions options = new ParallelOptions();
            options.MaxDegreeOfParallelism = _parallelism;

            Parallel.For(0, tasks.Length, options, delegate(int i)
            {
                results[i] = RunOne(tasks[i], pool);
            });

            return results;
        }

        private ExecResult RunOne(ExecTask task, RunspacePool pool)
        {
            ExecResult result = new ExecResult();
            result.Key = task.Key;
            result.Output = new PSObject[0];

            Stopwatch watch = Stopwatch.StartNew();
            PowerShell shell = PowerShell.Create();
            try
            {
                shell.RunspacePool = pool;

                if (task.IsCommandBased)
                {
                    // Komut hatti: no-language uc noktalarinda tek gecerli yol.
                    foreach (ExecStep step in task.Steps)
                    {
                        shell.AddCommand(step.Command);
                        if (step.Parameters != null)
                        {
                            foreach (KeyValuePair<string, object> pair in step.Parameters)
                            {
                                if (pair.Value is SwitchOn) shell.AddParameter(pair.Key);
                                else shell.AddParameter(pair.Key, pair.Value);
                            }
                        }
                    }
                }
                else
                {
                    if (string.IsNullOrEmpty(task.Script))
                        throw new InvalidOperationException("ExecTask'ta ne Script ne de Steps var.");

                    shell.AddScript(task.Script);
                    if (task.Parameters != null)
                    {
                        foreach (KeyValuePair<string, object> pair in task.Parameters)
                            shell.AddParameter(pair.Key, pair.Value);
                    }
                }

                int timeout = task.TimeoutSeconds > 0 ? task.TimeoutSeconds : 120;
                IAsyncResult async = shell.BeginInvoke();
                bool finished = async.AsyncWaitHandle.WaitOne(TimeSpan.FromSeconds(timeout));

                if (!finished)
                {
                    result.TimedOut = true;
                    // PowerShell.Stop() SENKRONDUR: pipeline yonetilmeyen ya da
                    // uzun suren yerel kod icindeyse (ornegin Parallel.ForEach ile
                    // calisan parser) durma istegini gormez ve Stop() donmez.
                    // O durumda TimeoutSeconds fiilen uygulanmamis olurdu.
                    // Istek birakilir, temizlik arka plana devredilir; cagiran
                    // TIMEOUT sonucuyla hemen devam eder.
                    StopAndDisposeInBackground(shell);
                    shell = null;
                    // Terk edilen boru hatti runspace'i havuza GERI VERMEZ.
                    // Tavan yukseltilmezse havuz her zaman asiminda bir kucuur
                    // ve sonraki isler kendi butcelerini harcamadan, yalnizca
                    // sira bekleyerek TIMEOUT olur (sessiz cig).
                    CompensateAbandonedRunspace(pool);
                }
                else
                {
                    PSDataCollection<PSObject> output = shell.EndInvoke(async);
                    List<PSObject> collected = new List<PSObject>();
                    foreach (PSObject item in output)
                    {
                        if (item != null) collected.Add(item);
                    }
                    result.Output = collected.ToArray();

                    if (shell.Streams.Error.Count > 0)
                        result.Error = JoinErrors(shell.Streams.Error);
                }
            }
            catch (Exception ex)
            {
                result.Error = ex.GetType().Name + ": " + ex.Message;
            }
            finally
            {
                // shell == null: timeout yolunda sahiplik arka plana gecti.
                if (shell != null)
                {
                    try { shell.Dispose(); }
                    catch (Exception) { }
                }
                watch.Stop();
                result.DurationMs = watch.Elapsed.TotalMilliseconds;
            }

            return result;
        }

        /// <summary>
        /// Terk edilen runspace'in yerine havuzun yeni bir tane acmasina izin
        /// verir. Ust sinir baslangic degerinin iki kati: bir kacak firtinasi
        /// makineyi bogmamali, ama tek tuk terk arac genelini durdurmamali.
        /// </summary>
        private void CompensateAbandonedRunspace(RunspacePool pool)
        {
            Interlocked.Increment(ref _abandonedPipelines);
            if (pool == null) return;
            try
            {
                int max = pool.GetMaxRunspaces();
                if (max < _parallelism * 2) pool.SetMaxRunspaces(max + 1);
            }
            catch (Exception) { }
        }

        /// <summary>
        /// Zaman asan pipeline'i asenkron durdurur ve durma tamamlandiginda
        /// serbest birakir. Dispose() da calisan bir pipeline'da bloklayabilir,
        /// bu yuzden o da geri cagriya birakilir.
        /// </summary>
        private static void StopAndDisposeInBackground(PowerShell shell)
        {
            try
            {
                shell.BeginStop(delegate(IAsyncResult ar)
                {
                    try { shell.EndStop(ar); }
                    catch (Exception) { }
                    try { shell.Dispose(); }
                    catch (Exception) { }
                }, null);
            }
            catch (Exception)
            {
                // BeginStop bile basarisizsa elde kalan tek sey Dispose denemesidir.
                try { shell.Dispose(); }
                catch (Exception) { }
            }
        }

        private static string JoinErrors(PSDataCollection<ErrorRecord> errors)
        {
            StringBuilder builder = new StringBuilder();
            int shown = 0;
            foreach (ErrorRecord record in errors)
            {
                if (shown >= 3)
                {
                    builder.Append(" | (+").Append(errors.Count - shown).Append(" hata daha)");
                    break;
                }
                if (builder.Length > 0) builder.Append(" | ");
                builder.Append(record.ToString());
                shown++;
            }
            return builder.ToString();
        }

        private static AuthenticationMechanism ParseAuthentication(string name)
        {
            if (string.IsNullOrEmpty(name)) return AuthenticationMechanism.Kerberos;
            try
            {
                return (AuthenticationMechanism)Enum.Parse(typeof(AuthenticationMechanism), name, true);
            }
            catch (Exception)
            {
                return AuthenticationMechanism.Kerberos;
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            ClosePool(_exchangePool);
            ClosePool(_localPool);
            _exchangePool = null;
            _localPool = null;
        }

        private static void ClosePool(RunspacePool pool)
        {
            if (pool == null) return;
            try
            {
                // Close() terk edilmis bir boru hattinin runspace'ini bekler.
                // Rapor zaten yazilmis olur; kullaniciyi "bitti" dedikten sonra
                // dakikalarca bekletmek yerine sinirli beklenir ve birakilir.
                IAsyncResult async = pool.BeginClose(null, null);
                if (!async.AsyncWaitHandle.WaitOne(TimeSpan.FromSeconds(10))) return;
                pool.EndClose(async);
            }
            catch (Exception) { }
            try { pool.Dispose(); }
            catch (Exception) { }
        }
    }
}
