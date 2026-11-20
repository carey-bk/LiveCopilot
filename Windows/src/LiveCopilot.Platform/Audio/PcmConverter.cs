using System.Buffers.Binary;

namespace LiveCopilot.Platform.Audio;

/// Streaming, causal Blackman-windowed sinc resampler with equal-weight channel downmix.
/// Fixed history, no audio queue. The 128-tap filter introduces 63.5 input frames of delay.
/// Separate instances are required for independent inputs. Reset/convert are serialized.
public sealed class PcmConverter
{
    private const int Taps = 128;
    private readonly object sync = new();
    private readonly double[] history = new double[Taps];
    private readonly Dictionary<int, double[]> kernels = [];
    private PcmFormat? format;
    private byte[] fragment = [];
    private int fragmentCount, head, phase;
    public int SampleRate { get; }

    public PcmConverter(int sampleRate = 16000)
    {
        if (sampleRate is < 8000 or > 96000) throw new ArgumentOutOfRangeException(nameof(sampleRate));
        SampleRate = sampleRate;
    }

    public byte[] Convert(ReadOnlySpan<byte> input, PcmFormat inputFormat)
    {
        inputFormat.Validate();
        lock (sync)
        {
            if (format != inputFormat)
            {
                ResetState();
                format = inputFormat;
                fragment = new byte[inputFormat.FrameBytes];
            }
            var output = new List<byte>();
            foreach (var value in input)
            {
                fragment[fragmentCount++] = value;
                if (fragmentCount != fragment.Length) continue;
                fragmentCount = 0;
                double mono = 0;
                for (var channel = 0; channel < inputFormat.Channels; channel++)
                    mono += ReadSample(fragment.AsSpan(channel * inputFormat.BytesPerSample), inputFormat.Encoding);
                mono /= inputFormat.Channels;
                history[head] = mono;
                phase += SampleRate;
                while (phase >= inputFormat.SampleRate)
                {
                    phase -= inputFormat.SampleRate;
                    double sample = mono;
                    if (SampleRate != inputFormat.SampleRate)
                    {
                        var kernel = Kernel(phase, inputFormat.SampleRate);
                        sample = 0;
                        for (var tap = 0; tap < Taps; tap++) sample += history[(head - tap + Taps) % Taps] * kernel[tap];
                    }
                    var pcm = (short)Math.Clamp(Math.Round(sample * 32768), short.MinValue, short.MaxValue);
                    output.Add((byte)(pcm & 255));
                    output.Add((byte)((pcm >> 8) & 255));
                }
                head = (head + 1) % Taps;
            }
            return output.ToArray();
        }
    }

    private double[] Kernel(int remainder, int inputRate)
    {
        if (kernels.TryGetValue(remainder, out var existing)) return existing;
        var kernel = new double[Taps];
        var cutoff = Math.Min(1d, (double)SampleRate / inputRate) * 0.90;
        double sum = 0;
        for (var i = 0; i < Taps; i++)
        {
            var offset = i - (Taps - 1) / 2d - (double)remainder / SampleRate;
            var x = Math.PI * cutoff * offset;
            var window = 0.42 - 0.5 * Math.Cos(2 * Math.PI * i / (Taps - 1)) + 0.08 * Math.Cos(4 * Math.PI * i / (Taps - 1));
            kernel[i] = cutoff * (Math.Abs(x) < 1e-12 ? 1 : Math.Sin(x) / x) * window;
            sum += kernel[i];
        }
        for (var i = 0; i < Taps; i++) kernel[i] /= sum;
        kernels.Add(remainder, kernel);
        return kernel;
    }

    private static double ReadSample(ReadOnlySpan<byte> data, PcmEncoding encoding)
    {
        var value = encoding switch
        {
            PcmEncoding.Int16 => BinaryPrimitives.ReadInt16LittleEndian(data) / 32768d,
            PcmEncoding.Int24 => ((data[0] | data[1] << 8 | data[2] << 16) << 8 >> 8) / 8388608d,
            PcmEncoding.Int32 => BinaryPrimitives.ReadInt32LittleEndian(data) / 2147483648d,
            _ => BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(data))
        };
        return double.IsFinite(value) ? value : 0;
    }

    public void Reset() { lock (sync) { ResetState(); format = null; } }
    private void ResetState()
    {
        Array.Clear(history);
        kernels.Clear();
        fragmentCount = head = phase = 0;
    }
}
