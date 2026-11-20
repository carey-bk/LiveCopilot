using LiveCopilot.Core;
using LiveCopilot.Platform.Audio;
using LiveCopilot.Platform.Hotkeys;

namespace LiveCopilot.App;

// Smoke uses the real session and windows, with hardware boundaries replaced.
internal sealed class SmokeAudioSourceFactory : IAudioSourceFactory
{
    public IAudioSource Create(AudioInput input) => throw new CopilotException("冒烟模式禁止音频采集。");
}

internal sealed class SmokeHotkeyRegistrar : IHotkeyRegistrar
{
    public event Action<int>? Pressed { add { } remove { } }
    public HotkeyRegistration Register(int id, HotkeyCombo combo, bool noRepeat) => new(true);
    public void Unregister(int id) { }
    public void Dispose() { }
}
