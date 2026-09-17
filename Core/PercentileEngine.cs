// ExchangeDiag - PercentileEngine
//
// Brief ilke 6: "Ortalama yasak, persentil zorunlu."
// Ortalama, tail olaylarini gizleyerek sorunun varligini inkar ettirir.
// Bu sinif her sure metrigi icin min/p50/p90/p95/p99/max uretir.
// Ortalama yalnizca referans olarak tasinir, tek basina RAPORLANMAZ.
//
// DIL KISITI: C# 5. Bkz. ParallelExecutor.cs basligi.

using System;
using System.Collections.Generic;
using System.Globalization;

namespace ExchangeDiag
{
    /// <summary>Tek bir olcum kumesinin persentil ozeti.</summary>
    public class Stats
    {
        public long Count;
        public double Min;
        public double P50;
        public double P90;
        public double P95;
        public double P99;
        public double Max;
        public double Mean;   // yalnizca referans; tek basina raporlanmaz
        public double Sum;

        public bool IsEmpty
        {
            get { return Count == 0; }
        }

        /// <summary>Rapor hucresi icin kisa gosterim.</summary>
        public string Format(int decimals)
        {
            if (Count == 0) return "N/A";
            return P95.ToString("F" + decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
        }

        public override string ToString()
        {
            if (Count == 0) return "n=0";
            return string.Concat(
                "n=", Count.ToString(CultureInfo.InvariantCulture),
                " min=", Round(Min), " p50=", Round(P50), " p90=", Round(P90),
                " p95=", Round(P95), " p99=", Round(P99), " max=", Round(Max));
        }

        private static string Round(double value)
        {
            return Math.Round(value, 3).ToString(CultureInfo.InvariantCulture);
        }
    }

    public static class PercentileEngine
    {
        /// <summary>
        /// Persentil yontemi: siralanmis dizi uzerinde dogrusal interpolasyon
        /// (NumPy varsayilani ile ayni). Yontem raporda belirtilmeli ki farkli
        /// araclarin sonuclari karsilastirilabilsin.
        /// </summary>
        public static double Percentile(double[] sorted, double percentile)
        {
            if (sorted == null || sorted.Length == 0) return 0d;
            if (sorted.Length == 1) return sorted[0];
            if (percentile <= 0d) return sorted[0];
            if (percentile >= 100d) return sorted[sorted.Length - 1];

            double rank = (percentile / 100d) * (sorted.Length - 1);
            int lower = (int)Math.Floor(rank);
            int upper = (int)Math.Ceiling(rank);
            if (lower == upper) return sorted[lower];

            double weight = rank - lower;
            return sorted[lower] * (1d - weight) + sorted[upper] * weight;
        }

        /// <summary>Diziyi YERINDE siralar ve ozetini cikarir.</summary>
        public static Stats Compute(double[] values)
        {
            Stats stats = new Stats();
            if (values == null || values.Length == 0) return stats;

            Array.Sort(values);

            double sum = 0d;
            for (int i = 0; i < values.Length; i++) sum += values[i];

            stats.Count = values.Length;
            stats.Sum = sum;
            stats.Mean = sum / values.Length;
            stats.Min = values[0];
            stats.Max = values[values.Length - 1];
            stats.P50 = Percentile(values, 50d);
            stats.P90 = Percentile(values, 90d);
            stats.P95 = Percentile(values, 95d);
            stats.P99 = Percentile(values, 99d);
            return stats;
        }

        public static Stats Compute(List<double> values)
        {
            if (values == null || values.Count == 0) return new Stats();
            return Compute(values.ToArray());
        }
    }

    /// <summary>
    /// Akan veri icin biriktirici. Milyonlarca satir islenirken her satirda
    /// yeniden siralama yapmamak icin degerler toplanir, ozet sonda cikarilir.
    /// Gruplama (sunucu / saat / veritabani) icin anahtarli kullanilir.
    /// </summary>
    public class StatsAccumulator
    {
        private readonly Dictionary<string, List<double>> _groups;

        public StatsAccumulator()
        {
            _groups = new Dictionary<string, List<double>>(StringComparer.OrdinalIgnoreCase);
        }

        public void Add(string group, double value)
        {
            if (group == null) group = "";
            List<double> bucket;
            if (!_groups.TryGetValue(group, out bucket))
            {
                bucket = new List<double>();
                _groups[group] = bucket;
            }
            bucket.Add(value);
        }

        public string[] Groups
        {
            get
            {
                string[] keys = new string[_groups.Count];
                _groups.Keys.CopyTo(keys, 0);
                Array.Sort(keys, StringComparer.OrdinalIgnoreCase);
                return keys;
            }
        }

        public Stats Summarize(string group)
        {
            List<double> bucket;
            if (!_groups.TryGetValue(group, out bucket)) return new Stats();
            return PercentileEngine.Compute(bucket);
        }

        /// <summary>Tum gruplarin ozeti. Rapor tablosunu bu besler.</summary>
        public Dictionary<string, Stats> SummarizeAll()
        {
            Dictionary<string, Stats> output = new Dictionary<string, Stats>(StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, List<double>> pair in _groups)
                output[pair.Key] = PercentileEngine.Compute(pair.Value);
            return output;
        }

        public long TotalCount
        {
            get
            {
                long total = 0;
                foreach (KeyValuePair<string, List<double>> pair in _groups) total += pair.Value.Count;
                return total;
            }
        }
    }
}
