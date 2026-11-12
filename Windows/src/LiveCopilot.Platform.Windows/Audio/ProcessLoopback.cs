using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wasapi.CoreAudioApi.Interfaces;

namespace LiveCopilot.Platform.Windows.Audio;

// NAudio 2.x supplies IAudioClient/capture wrappers but not process-loopback activation.
// This is the small Windows SDK activation bridge; no private APIs or virtual driver.
internal static class ProcessLoopback
{
    [ComImport, Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAgileObject { }

    public static AudioClient Activate(CancellationToken token)
    {
        var parameters = Marshal.AllocHGlobal(12);
        var variant = Marshal.AllocHGlobal(IntPtr.Size == 8 ? 24 : 16);
        var completion = new Completion();
        IActivateAudioInterfaceAsyncOperation? operation = null;
        try
        {
            Marshal.WriteInt32(parameters, 0, 1); // AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
            Marshal.WriteInt32(parameters, 4, Environment.ProcessId);
            Marshal.WriteInt32(parameters, 8, 1); // EXCLUDE_TARGET_PROCESS_TREE
            for (var i = 0; i < (IntPtr.Size == 8 ? 24 : 16); i++) Marshal.WriteByte(variant, i, 0);
            Marshal.WriteInt16(variant, 65); // VT_BLOB
            Marshal.WriteInt32(variant, 8, 12);
            Marshal.WriteIntPtr(variant, IntPtr.Size == 8 ? 16 : 12, parameters);
            var iid = typeof(IAudioClient).GUID;
            Marshal.ThrowExceptionForHR(ActivateAudioInterfaceAsync("VAD\\Process_Loopback", ref iid, variant, completion, out operation));
            try { return completion.Result.Task.WaitAsync(TimeSpan.FromSeconds(5), token).GetAwaiter().GetResult(); }
            catch
            {
                // Activation cannot be cancelled. A late successful result still owns a COM
                // reference; release it even after the caller has selected endpoint fallback.
                _ = completion.Result.Task.ContinueWith(task =>
                {
                    if (task.IsCompletedSuccessfully) task.Result.Dispose();
                    else _ = task.Exception;
                }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
                throw;
            }
        }
        finally
        {
            if (operation is not null) Marshal.ReleaseComObject(operation);
            Marshal.FreeHGlobal(variant);
            Marshal.FreeHGlobal(parameters);
        }
    }

    [DllImport("Mmdevapi.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern int ActivateAudioInterfaceAsync(string path, ref Guid iid, nint parameters,
        IActivateAudioInterfaceCompletionHandler completion, out IActivateAudioInterfaceAsyncOperation operation);

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    private sealed class Completion : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        public TaskCompletionSource<AudioClient> Result { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation)
        {
            object? native = null;
            try
            {
                operation.GetActivateResult(out var hr, out native);
                Marshal.ThrowExceptionForHR(hr);
                var client = new AudioClient((IAudioClient)native);
                native = null; // Ownership transferred to NAudio.
                Result.TrySetResult(client);
            }
            catch (Exception e) { Result.TrySetException(e); }
            finally { if (native is not null && Marshal.IsComObject(native)) Marshal.ReleaseComObject(native); }
        }
    }
}
