using System.Collections.Concurrent;
using System.Threading.Channels;
using LiveCopilot.Testing;

namespace LiveCopilot.Core.Tests;

public sealed class OpenAILiveProviderTests
{
    private static OpenAILiveOptions Options(LocalLiveServer server) => new()
    { Endpoint = server.Endpoint, StartupTimeout = TimeSpan.FromSeconds(3), CloseTimeout = TimeSpan.FromMilliseconds(300), RetryDelay = TimeSpan.FromMilliseconds(20), MaximumRetries = 0 };
    private static OpenAILiveProvider Provider(LocalLiveServer server, OpenAILiveOptions? options = null) =>
        new("fake-line13-key", "gpt-live-1", Speaker.Them, ScenarioProfile.Interview, LiveSpeechLanguage.Mixed, options ?? Options(server));

    public static IEnumerable<object[]> Configurations => from speaker in Enum.GetValues<Speaker>()
        from scenario in Enum.GetValues<ScenarioProfile>() from language in Enum.GetValues<LiveSpeechLanguage>() select new object[] { speaker, scenario, language };

    [Theory, MemberData(nameof(Configurations))]
    public async Task HandshakeAndStartMatchMac(Speaker speaker, ScenarioProfile scenario, LiveSpeechLanguage language)
    {
        await using var server = new LocalLiveServer();
        await using var provider = new OpenAILiveProvider("fake-line13-key", "gpt-live-1", speaker, scenario, language, Options(server));
        var events = new Events(provider);
        var context = "discarded" + string.Concat(Enumerable.Repeat("👩🏽‍💻", 6000));
        provider.Connect(context); provider.Connect("ignored duplicate connect");
        var peer = await server.NextAsync();
        var start = await peer.NextAsync("session.start");
        await events.Next<LiveEvent.Ready>();
        var request = Assert.Single(server.Requests);
        Assert.Equal("Bearer fake-line13-key", request.Authorization); Assert.Equal("/v1/live/sessions", request.Path);
        Assert.True(Guid.TryParse(start.GetProperty("event_id").GetString(), out _));
        var session = start.GetProperty("session");
        Assert.Equal("gpt-live-1", session.GetProperty("model").GetString());
        Assert.False(session.GetProperty("store").GetBoolean());
        Assert.Equal("client", session.GetProperty("delegation").GetProperty("type").GetString());
        var audio = session.GetProperty("audio");
        Assert.Equal("audio/pcm", audio.GetProperty("format").GetProperty("type").GetString());
        Assert.Equal(24000, audio.GetProperty("format").GetProperty("rate").GetInt32());
        Assert.Equal("marin", audio.GetProperty("output").GetProperty("voice").GetString());
        var instructions = session.GetProperty("instructions").GetString()!;
        Assert.Contains(scenario.Instructions(), instructions);
        Assert.Contains(speaker switch { Speaker.You => "do not delegate requests for assistance", Speaker.Room => "Speaker identity is uncertain", _ => "remote participants (Them)" }, instructions);
        Assert.Contains("Stay silent; the application has no voice output.", instructions);
        Assert.Contains("meaningful question or request is sufficiently complete", instructions);
        Assert.Contains("fragments, rhetorical questions, backchannels", instructions);
        if (language == LiveSpeechLanguage.Unrestricted) Assert.DoesNotContain("Do not use Korean", instructions);
        else
        {
            Assert.Contains("Do not use Korean or Japanese script", instructions);
            Assert.Contains(language switch { LiveSpeechLanguage.Chinese => "Expect primarily Mandarin Chinese", LiveSpeechLanguage.English => "Expect primarily English", _ => "possibly alternating within one sentence" }, instructions);
        }
        var input = session.GetProperty("input")[0];
        Assert.Equal("message", input.GetProperty("type").GetString()); Assert.Equal("user", input.GetProperty("role").GetString());
        Assert.Equal("input_text", input.GetProperty("content")[0].GetProperty("type").GetString());
        Assert.Equal("Prior conversation (reference only):\n" + context[9..], input.GetProperty("content")[0].GetProperty("text").GetString());
        await provider.DisconnectAsync();
        Assert.True((await events.Next<LiveEvent.Closed>()).Finalized);
    }

    [Fact]
    public void DefaultsUseMacEndpointAndDeadlines()
    {
        var options = new OpenAILiveOptions();
        Assert.Equal("wss://api.openai.com/v1/live/sessions", options.Endpoint.AbsoluteUri);
        Assert.Equal(TimeSpan.FromSeconds(20), options.StartupTimeout); Assert.Equal(TimeSpan.FromSeconds(8), options.CloseTimeout);
        Assert.Equal(3, options.MaximumRetries); Assert.Equal(TimeSpan.FromSeconds(1), options.RetryDelay);
        using var start = JsonDocument.Parse(OpenAILiveProtocol.Start("custom", Speaker.Room, ScenarioProfile.Meeting, LiveSpeechLanguage.Unrestricted, ""));
        Assert.False(start.RootElement.GetProperty("session").TryGetProperty("input", out _));
    }

    [Fact]
    public async Task AudioIsCopiedAsBase64PcmOnlyAfterReadyAndContextIsByteBounded()
    {
        await using var server = new LocalLiveServer { AutoReady = false };
        await using var provider = Provider(server);
        var events = new Events(provider);
        provider.SendAudio(new byte[6]); provider.Connect("");
        var peer = await server.NextAsync(); await peer.NextAsync("session.start");
        provider.SendAudio(new byte[6]);
        await peer.SendAsync(new { type = "session.started" }); await events.Next<LiveEvent.Ready>();
        var pcm = new byte[] { 0, 0, 255, 127, 0, 128 };
        provider.SendAudio(pcm); Array.Fill(pcm, (byte)7);
        provider.SendAudio(new byte[3]);
        var audio = await peer.NextAsync("session.input_audio.append");
        Assert.Equal(new byte[] { 0, 0, 255, 127, 0, 128 }, Convert.FromBase64String(audio.GetProperty("audio").GetString()!));
        var text = string.Concat(Enumerable.Repeat("👩🏽‍💻中文", 100));
        provider.AppendContext(text, "delegation-1"); provider.AppendContext("You said: understood", null);
        var thinking = await peer.NextAsync("session.thinking.append");
        Assert.Equal("delegation-1", thinking.GetProperty("delegation_id").GetString());
        var excerpt = thinking.GetProperty("content").GetString()!;
        Assert.InRange(Encoding.UTF8.GetByteCount(excerpt), 430, 450); Assert.StartsWith(excerpt, text);
        Assert.Equal(JsonValueKind.Null, (await peer.NextAsync("session.thinking.append")).GetProperty("delegation_id").ValueKind);
        await provider.DisconnectAsync(); provider.SendAudio(pcm);
        Assert.Single(peer.Messages, m => m.GetProperty("type").GetString() == "session.input_audio.append");
        Assert.True(Guid.TryParse((await peer.NextAsync("session.close")).GetProperty("event_id").GetString(), out _));
    }

    [Fact]
    public async Task FragmentedDeltaCompletedDelegationAndTrailingFinalAreDeliveredInOrder()
    {
        await using var server = new LocalLiveServer();
        await using var provider = Provider(server);
        var events = new Events(provider); provider.Connect(""); var peer = await server.NextAsync(); await events.Next<LiveEvent.Ready>();
        await peer.SendRawAsync(Encoding.UTF8.GetBytes("malformed json"));
        await peer.SendAsync(new { type = "session.output_audio.delta", delta = "ignored" });
        await peer.SendAsync(new { type = "session.input_transcript.delta", event_id = "t1", delta = "为什么", start_ms = 0, end_ms = 500 }, fragmented: true);
        var delta = (await events.Next<LiveEvent.Transcript>()).Fragment;
        Assert.Equal("为什么", delta.Text); Assert.Equal(Speaker.Them, delta.Speaker); Assert.Equal(500, delta.EndMs);
        await peer.SendAsync(new { type = "session.input_transcript.completed", event_id = "t1", transcript = "为什么选择这个方案？", start_ms = 0, end_ms = 1500 });
        var final = (await events.Next<LiveEvent.Transcript>()).Fragment;
        Assert.Equal(delta.Id, final.Id); Assert.Equal("为什么选择这个方案？", final.Text);
        await peer.SendAsync(new { type = "session.delegation.created", delegation = new { id = "d1", target = "client" }, offset_ms = 1500 });
        Assert.Equal(new LiveEvent.Delegation("d1", 1500), await events.Next<LiveEvent.Delegation>());
        peer.FinalTranscript = "再补充一句。";
        await provider.DisconnectAsync(); await provider.DisconnectAsync();
        Assert.Equal("再补充一句。", (await events.Next<LiveEvent.Transcript>()).Fragment.Text);
        Assert.True((await events.Next<LiveEvent.Closed>()).Finalized);
        Assert.Single(events.All.OfType<LiveEvent.Closed>());
        Assert.Empty(events.All.OfType<LiveEvent.Failed>());
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("[]")]
    [InlineData("{\"type\":\"session.input_transcript.delta\",\"delta\":\"missing timestamps\"}")]
    [InlineData("{\"type\":\"session.input_transcript.delta\",\"delta\":\"bad\",\"event_id\":\"x\",\"start_ms\":1.5,\"end_ms\":2}")]
    [InlineData("{\"type\":\"session.delegation.created\",\"delegation\":{\"target\":\"server\",\"id\":\"ignored\"}}")]
    public void UnknownAndMalformedEventsAreIgnored(string json) => Assert.Null(OpenAILiveProtocol.Parse(Encoding.UTF8.GetBytes(json), Speaker.Room));

    [Theory]
    [InlineData("invalid_api_key", ServiceHTTPFailureKind.Authentication)]
    [InlineData("insufficient_quota", ServiceHTTPFailureKind.Billing)]
    [InlineData("permission_denied", ServiceHTTPFailureKind.Permission)]
    [InlineData("model_not_found", ServiceHTTPFailureKind.Model)]
    [InlineData("rate_limit_exceeded", ServiceHTTPFailureKind.RateLimit)]
    [InlineData("unknown", ServiceHTTPFailureKind.Service)]
    public async Task ServerErrorsAreSanitizedAndNotRetried(string code, ServiceHTTPFailureKind kind)
    {
        await using var server = new LocalLiveServer();
        await using var provider = Provider(server, Options(server) with { MaximumRetries = 3 });
        var events = new Events(provider); provider.Connect(""); var peer = await server.NextAsync(); await events.Next<LiveEvent.Ready>();
        await peer.SendAsync(new { type = "error", error = new { code, message = "DO-NOT-LEAK fake-key-and-private-context" } });
        var failure = await events.Next<LiveEvent.Failed>();
        Assert.Equal(kind.Message(), failure.Message); Assert.False(failure.WillRetry);
        await events.Next<LiveEvent.Closed>(); await provider.DisconnectAsync(); Assert.Single(server.Requests);
    }

    [Theory]
    [InlineData(400)] [InlineData(401)] [InlineData(402)] [InlineData(403)] [InlineData(404)] [InlineData(429)]
    public async Task HandshakeHttpFailuresDoNotRetry(int status)
    {
        await using var server = new LocalLiveServer { RejectionStatus = status };
        await using var provider = Provider(server, Options(server) with { MaximumRetries = 3 });
        var events = new Events(provider); provider.Connect("");
        var failure = await events.Next<LiveEvent.Failed>();
        Assert.Equal(new ServiceHTTPFailure(status).Message, failure.Message); Assert.False(failure.WillRetry);
        await events.Next<LiveEvent.Closed>(); Assert.Single(server.Requests);
    }

    [Fact]
    public async Task StartupTimeoutRetriesExactlyThreeTimesAndStops()
    {
        await using var server = new LocalLiveServer { AutoReady = false };
        await using var provider = Provider(server, Options(server) with { MaximumRetries = 3, StartupTimeout = TimeSpan.FromMilliseconds(150) });
        var events = new Events(provider); provider.Connect("");
        for (var i = 0; i < 4; i++)
        {
            var failure = await events.Next<LiveEvent.Failed>();
            Assert.Equal(OpenAILiveProtocol.StartupTimeoutMessage, failure.Message); Assert.Equal(i < 3, failure.WillRetry);
        }
        await events.Next<LiveEvent.Closed>(); Assert.Equal(4, server.Requests.Count);
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task TransportLossReconnectsWithContextWithoutReplayingAudio(bool graceful)
    {
        await using var server = new LocalLiveServer();
        await using var provider = Provider(server, Options(server) with { MaximumRetries = 1 });
        var events = new Events(provider); provider.Connect("prior context"); var peer = await server.NextAsync(); await events.Next<LiveEvent.Ready>();
        await peer.SendAsync(new { type = "session.input_transcript.delta", event_id = "t1", delta = "new transcript", start_ms = 0, end_ms = 50 });
        await events.Next<LiveEvent.Transcript>(); provider.AppendContext("assistant result", null); await peer.NextAsync("session.thinking.append");
        if (graceful) await peer.CloseTransportAsync(); else peer.Abort();
        var failure = await events.Next<LiveEvent.Failed>(); Assert.True(failure.WillRetry); Assert.Equal(OpenAILiveProtocol.ConnectionFailureMessage, failure.Message);
        var reconnected = await server.NextAsync(); await events.Next<LiveEvent.Ready>();
        var start = await reconnected.NextAsync("session.start");
        var text = start.GetProperty("session").GetProperty("input")[0].GetProperty("content")[0].GetProperty("text").GetString()!;
        Assert.Contains("prior contextnew transcript\nassistant result", text);
        await provider.DisconnectAsync(); Assert.DoesNotContain(reconnected.Messages, m => m.GetProperty("type").GetString() == "session.input_audio.append");
    }

    [Fact]
    public async Task OversizedAudioFailsWithBoundedBacklogMessage()
    {
        await using var server = new LocalLiveServer(); await using var provider = Provider(server);
        var events = new Events(provider); provider.Connect(""); await server.NextAsync(); await events.Next<LiveEvent.Ready>();
        provider.SendAudio(new byte[192_002]);
        Assert.Equal(OpenAILiveProtocol.UploadTooSlowMessage, (await events.Next<LiveEvent.Failed>()).Message);
        await events.Next<LiveEvent.Closed>();
    }

    [Theory] [InlineData(false)] [InlineData(true)]
    public async Task StopCancelsStartupOrPendingRetryPromptly(bool retry)
    {
        await using var server = new LocalLiveServer { AutoReady = false };
        await using var provider = Provider(server, Options(server) with { MaximumRetries = 3, StartupTimeout = TimeSpan.FromMilliseconds(150), RetryDelay = TimeSpan.FromSeconds(2) });
        var events = new Events(provider); provider.Connect(""); var peer = await server.NextAsync(); await peer.NextAsync("session.start");
        if (retry) Assert.True((await events.Next<LiveEvent.Failed>()).WillRetry);
        await provider.DisconnectAsync().WaitAsync(TimeSpan.FromSeconds(1));
        Assert.False((await events.Next<LiveEvent.Closed>()).Finalized); Assert.Single(server.Requests);
        Assert.Equal(retry ? 1 : 0, events.All.OfType<LiveEvent.Failed>().Count());
        Assert.DoesNotContain(peer.Messages, m => m.GetProperty("type").GetString() == "session.close");
    }

    [Fact]
    public async Task UnacknowledgedStopIsBoundedAndNotFinalized()
    {
        await using var server = new LocalLiveServer { AutoClose = false }; await using var provider = Provider(server);
        var events = new Events(provider); provider.Connect(""); var peer = await server.NextAsync(); await events.Next<LiveEvent.Ready>();
        await provider.DisconnectAsync().WaitAsync(TimeSpan.FromSeconds(2));
        await peer.NextAsync("session.close");
        Assert.False((await events.Next<LiveEvent.Closed>()).Finalized); Assert.Empty(events.All.OfType<LiveEvent.Failed>());
    }

    [Theory] [InlineData("")] [InlineData("   ")] [InlineData("bad\nkey")]
    public async Task InvalidKeyNeverOpensSocket(string key)
    {
        await using var server = new LocalLiveServer();
        await using var provider = new OpenAILiveProvider(key, "gpt-live-1", Speaker.Room, ScenarioProfile.Meeting, LiveSpeechLanguage.Mixed, Options(server));
        var events = new Events(provider); provider.Connect("");
        var failure = await events.Next<LiveEvent.Failed>(); Assert.Contains("密钥", failure.Message);
        await provider.DisconnectAsync(); Assert.Empty(server.Requests);
    }

    [Fact]
    public async Task FactoryUsesOnlySharedCredentialAndRejectsMissingKey()
    {
        await using var server = new LocalLiveServer(); var credentials = new MemoryCredentialStore();
        credentials.Save(CredentialReference.SeparateOpenAI, "fake-wrong-key");
        Assert.Equal(OpenAILiveProvider.MissingKeyMessage, Assert.Throws<CopilotException>(() =>
            OpenAILiveProvider.FromCredentials(new(), credentials, Speaker.Them, Options(server))).Message);
        Assert.Empty(server.Requests);
        credentials.Save(CredentialReference.Live, "fake-shared-key");
        await using var provider = OpenAILiveProvider.FromCredentials(new(), credentials, Speaker.Them, Options(server));
        var events = new Events(provider); provider.Connect(""); await server.NextAsync(); await events.Next<LiveEvent.Ready>();
        Assert.Equal("Bearer fake-shared-key", Assert.Single(server.Requests).Authorization);
    }

    [Fact]
    public void AssistanceFeedbackMatchesMacNineHundredGraphemePrefix()
    {
        var prefix = string.Concat(Enumerable.Repeat("👩🏽‍💻", 900));
        Assert.Equal("Assistance completed in the text overlay for the question. Brief result: " + prefix,
            OpenAILiveProtocol.AssistanceSummary(prefix + "discarded"));
    }

    [Theory]
    [InlineData(System.Net.Sockets.SocketError.NetworkDown)]
    [InlineData(System.Net.Sockets.SocketError.NetworkUnreachable)]
    [InlineData(System.Net.Sockets.SocketError.HostUnreachable)]
    [InlineData(System.Net.Sockets.SocketError.TimedOut)]
    [InlineData(System.Net.Sockets.SocketError.ConnectionReset)]
    public void NestedNetworkFailuresUseSafeMacMessages(System.Net.Sockets.SocketError code)
    {
        var error = new System.Net.WebSockets.WebSocketException("private request", new HttpRequestException("private URL",
            new System.Net.Sockets.SocketException((int)code)));
        var expected = code == System.Net.Sockets.SocketError.TimedOut ? OpenAILiveProtocol.StartupTimeoutMessage :
            code == System.Net.Sockets.SocketError.ConnectionReset ? OpenAILiveProtocol.ConnectionFailureMessage :
            "No internet connection. Reconnect and try the speech service again.";
        Assert.Equal(expected, OpenAILiveProtocol.TransportFailure(error));
    }

    private sealed class Events
    {
        private readonly Channel<LiveEvent> queue = Channel.CreateUnbounded<LiveEvent>();
        public ConcurrentQueue<LiveEvent> All { get; } = new();
        public Events(ILiveProvider provider) => provider.OnEvent = value => { All.Enqueue(value); queue.Writer.TryWrite(value); };
        public async Task<T> Next<T>() where T : LiveEvent
        {
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(6));
            while (true) if (await queue.Reader.ReadAsync(deadline.Token) is T value) return value;
        }
    }
}
