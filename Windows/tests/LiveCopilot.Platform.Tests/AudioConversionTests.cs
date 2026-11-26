using LiveCopilot.Platform.Audio;

namespace LiveCopilot.Platform.Tests;

public sealed class AudioConversionTests
{
    [Theory]
    [InlineData(ListeningService.Zipformer, 16000)] [InlineData(ListeningService.Paraformer, 16000)]
    [InlineData(ListeningService.Apple, 24000)] [InlineData(ListeningService.OpenAI, 24000)]
    public void ServiceRateMatchesWindowsContract(ListeningService service, int rate) => Assert.Equal(rate, service.SampleRate());

    [Theory] [InlineData(16000, 32)] [InlineData(24000, 48)]
    public async Task Stereo48kHasExactDurationAndCorrectDownmix(int rate, int bytesPerMs)
    {
        var output = await Signals.Capture(Signals.Float(48000, 2, (_, c) => c == 0 ? .75f : .25f), new(48000, 2, PcmEncoding.Float32), rate);
        Assert.Equal(bytesPerMs * 1000, output.Length);
        Assert.All(Signals.Samples(output).Skip(200), sample => Assert.InRange(sample, 16383, 16385));
    }

    [Theory] [InlineData(16000)] [InlineData(24000)]
    public async Task ArbitraryPacketAndPartialFrameBoundariesDoNotChangeOutput(int rate)
    {
        var input = Signals.Float(4817, 2, (i, c) => (float)(Math.Sin(i * .12 + c) * .6));
        var format = new PcmFormat(48000, 2, PcmEncoding.Float32);
        Assert.Equal(await Signals.Capture(input, format, rate), await Signals.Capture(input, format, rate, 37));
    }

    [Theory] [InlineData(16000, 12000)] [InlineData(24000, 18000)]
    public async Task ResamplerPreservesSpeechAndRejectsAliasing(int rate, int stopFrequency)
    {
        async Task<double> Rms(int frequency)
        {
            var pcm = await Signals.Capture(Signals.Float(24000, 2, (i, _) => (float)(.5 * Math.Sin(2 * Math.PI * frequency * i / 48000))), new(48000, 2, PcmEncoding.Float32), rate, 1279);
            return Math.Sqrt(Signals.Samples(pcm).Skip(200).Select(s => Math.Pow(s / 32768d, 2)).Average());
        }
        Assert.InRange(await Rms(1000), .34, .36);
        Assert.InRange(await Rms(stopFrequency), 0, .005);
    }

    [Theory] [InlineData(44100, 16000)] [InlineData(44100, 24000)] [InlineData(16000, 24000)]
    public async Task FractionalRateAndUpsamplingKeepDurationAndSignal(int inputRate, int outputRate)
    {
        var pcm = await Signals.Capture(Signals.Float(inputRate, 1, (_, _) => .25f), new(inputRate, 1, PcmEncoding.Float32), outputRate, 211);
        Assert.Equal(outputRate * 2, pcm.Length);
        Assert.All(Signals.Samples(pcm).Skip(300), s => Assert.InRange(s, 8191, 8193));
    }

    [Fact] public async Task FloatClippingAndNonfiniteValuesAreSafeLittleEndian()
    {
        float[] values = [-2, -1, -.5f, 0, .5f, 1, 2, float.NaN, float.PositiveInfinity];
        var output = await Signals.Capture(Signals.Float(values.Length, 1, (i, _) => values[i]), new(16000, 1, PcmEncoding.Float32), 16000);
        Assert.Equal(new byte[] { 0,128, 0,128, 0,192, 0,0, 0,64, 255,127, 255,127, 0,0, 0,0 }, output);
    }

    [Theory] [InlineData(PcmEncoding.Int16)] [InlineData(PcmEncoding.Int24)] [InlineData(PcmEncoding.Int32)]
    public async Task IntegerFormatsPreserveSignAndEndianness(PcmEncoding encoding)
    {
        byte[] input = encoding switch
        {
            PcmEncoding.Int16 => [0,128, 0,192, 0,0, 0,64, 255,127],
            PcmEncoding.Int24 => [0,0,128, 0,0,192, 0,0,0, 0,0,64, 255,255,127],
            _ => [0,0,0,128, 0,0,0,192, 0,0,0,0, 0,0,0,64, 255,255,255,127]
        };
        var output = await Signals.Capture(input, new(16000, 1, encoding), 16000, 1);
        Assert.Equal(new short[] { -32768, -16384, 0, 16384, 32767 }, Signals.Samples(output));
    }

    [Fact] public async Task OppositeChannelsCancelWithoutEarlyClipping()
    {
        var pcm = await Signals.Capture(Signals.Float(1000, 2, (_, c) => c == 0 ? 2f : -1.5f), new(16000, 2, PcmEncoding.Float32), 16000);
        Assert.All(Signals.Samples(pcm), s => Assert.Equal(8192, s));
    }

    [Fact] public async Task IndependentSourcesNeverShareFilterOrFragmentState()
    {
        var mic = new FakeAudioSource(); var system = new FakeAudioSource();
        await using var a = new AudioCaptureManager(new FakeAudioFactory(mic), AudioInput.Microphone);
        await using var b = new AudioCaptureManager(new FakeAudioFactory(system), AudioInput.System);
        a.Configure(16000); b.Configure(24000);
        var left = new List<byte>(); var right = new List<byte>();
        a.Pcm16Available += d => left.AddRange(d.ToArray()); b.Pcm16Available += d => right.AddRange(d.ToArray());
        await a.StartAsync(); await b.StartAsync();
        for (var i = 0; i < 20; i++) { mic.Push(Signals.Float(480, 2, (_, _) => .5f)); system.Push(new byte[480 * 8]); }
        Assert.Equal(6400, left.Count); Assert.Equal(9600, right.Count);
        Assert.All(Signals.Samples(right), s => Assert.Equal(0, s));
        Assert.All(Signals.Samples(left).Skip(100), s => Assert.InRange(s, 16383, 16385));
    }
}
