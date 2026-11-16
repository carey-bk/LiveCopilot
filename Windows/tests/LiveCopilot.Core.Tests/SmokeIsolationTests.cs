using System.Net;

namespace LiveCopilot.Core.Tests;

[CollectionDefinition("Smoke environment", DisableParallelization = true)]
public sealed class SmokeEnvironmentCollection { }

[Collection("Smoke environment")]
public sealed class SmokeIsolationTests
{
    [Fact]
    public void SmokeHarnessCanChooseOnlyAnIsolatedTemporaryRunId()
    {
        var previous = Environment.GetEnvironmentVariable("LIVECOPILOT_SMOKE");
        var previousId = Environment.GetEnvironmentVariable("LIVECOPILOT_SMOKE_DATA_ID");
        try
        {
            var id = Guid.NewGuid().ToString("N");
            Environment.SetEnvironmentVariable("LIVECOPILOT_SMOKE_DATA_ID", id);
            Environment.SetEnvironmentVariable("LIVECOPILOT_SMOKE", "1");
            Assert.Equal(Path.Combine(Path.GetTempPath(), "LiveCopilot-smoke-" + id), AppPaths.DataDirectory);
            Environment.SetEnvironmentVariable("LIVECOPILOT_SMOKE_DATA_ID", "/user/data");
            Assert.StartsWith(Path.Combine(Path.GetTempPath(), "LiveCopilot-smoke-"), AppPaths.DataDirectory);
            Environment.SetEnvironmentVariable("LIVECOPILOT_SMOKE", "0");
            Assert.Equal(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LiveCopilot"), AppPaths.DataDirectory);
        }
        finally
        {
            Environment.SetEnvironmentVariable("LIVECOPILOT_SMOKE", previous);
            Environment.SetEnvironmentVariable("LIVECOPILOT_SMOKE_DATA_ID", previousId);
        }
    }

    [Fact]
    public async Task SmokeUsesTemporaryDataAndRejectsBothHttpPathsBeforeSending()
    {
        var previous = Environment.GetEnvironmentVariable("LIVECOPILOT_SMOKE");
        try
        {
            Environment.SetEnvironmentVariable("LIVECOPILOT_SMOKE", "1");
            Assert.StartsWith(Path.GetTempPath(), AppPaths.DataDirectory);
            Assert.Contains("LiveCopilot-smoke-", AppPaths.DataDirectory);
            var directory = AppPaths.DataDirectory;
            Assert.Equal(directory, AppPaths.DataDirectory);
            using var handler = new CountingHandler();
            using var client = new HttpClient(handler);
            using var transport = new HttpClientTransport(client);
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://example.invalid/");
            await Assert.ThrowsAsync<CopilotException>(() => transport.DataAsync(request, CancellationToken.None));
            await Assert.ThrowsAsync<CopilotException>(async () =>
            {
                await foreach (var _ in transport.LinesAsync(request)) { }
            });
            Assert.Equal(0, handler.Calls);
        }
        finally { Environment.SetEnvironmentVariable("LIVECOPILOT_SMOKE", previous); }
    }

    private sealed class CountingHandler : HttpMessageHandler
    {
        public int Calls { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        { Calls++; return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)); }
    }
}
