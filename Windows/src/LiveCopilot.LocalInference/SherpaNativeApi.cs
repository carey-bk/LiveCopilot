using System.Runtime.InteropServices;
using System.Collections.Concurrent;
using SherpaOnnx;

namespace LiveCopilot.LocalInference;

// The official 1.13.8 binding has no CreateStreamWithHotwords and does not check
// null recognizer/VAD handles. Use its ABI configuration/result types with this
// small checked adapter. No worker process or alternate ASR implementation.
internal sealed class SherpaNativeApi
{
    private static readonly object Gate = new();
    private static SherpaNativeApi? resident;
    private readonly IntPtr library;
    private readonly ConcurrentDictionary<string, Delegate> functions = new();
    public InferenceBackend Backend { get; }
    public IReadOnlyList<BackendAttempt> Attempts { get; }

    private SherpaNativeApi(IntPtr library, InferenceBackend backend, IReadOnlyList<BackendAttempt> attempts)
    { this.library = library; Backend = backend; Attempts = attempts; }

    public static SherpaNativeApi Load(InferenceOptions options)
    {
        lock (Gate)
        {
            // Native runtimes are process-wide. CPU model sessions may still use a GPU-capable runtime.
            if (resident is not null) return resident;
            List<BackendAttempt> attempts = [];
            foreach (var backend in BackendSelection.Speech(options.HardwareProbe.Detect(), options.ForceCpu))
            {
                IntPtr handle = IntPtr.Zero, ort = IntPtr.Zero;
                try
                {
                    if (backend == InferenceBackend.Cpu)
                        handle = NativeLibrary.Load("sherpa-onnx-c-api", typeof(OnlineRecognizerConfig).Assembly, null);
                    else
                    {
                        var directory = Path.GetFullPath(Path.Combine(options.SherpaRuntimeRoot, SpeechConfiguration.Provider(backend)));
                        var file = Path.Combine(directory, "sherpa-onnx-c-api.dll");
                        if (!OperatingSystem.IsWindows() || !File.Exists(file)) throw new DllNotFoundException();
                        ort = LoadLibraryEx(Path.Combine(directory, "onnxruntime.dll"), IntPtr.Zero, 0x100 | 0x1000);
                        if (ort == IntPtr.Zero) throw new DllNotFoundException();
                        new OrtProviderProbe(ort).Require(backend);
                        handle = LoadLibraryEx(file, IntPtr.Zero, 0x100 | 0x1000); // DLL directory + safe default directories
                        if (handle == IntPtr.Zero) throw new DllNotFoundException();
                    }
                    var version = Marshal.GetDelegateForFunctionPointer<Version>(NativeLibrary.GetExport(handle, "SherpaOnnxGetVersionStr"))();
                    if (Marshal.PtrToStringUTF8(version) is not ("1.13.8" or "v1.13.8"))
                        throw new NotSupportedException("The sherpa native runtime must match binding version 1.13.8.");
                    attempts.Add(new(backend, "loaded"));
                    resident = new(handle, backend, attempts.AsReadOnly());
                    return resident;
                }
                catch (Exception e) when (e is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException or InvalidOperationException or NotSupportedException)
                {
                    if (handle != IntPtr.Zero) NativeLibrary.Free(handle);
                    if (ort != IntPtr.Zero) NativeLibrary.Free(ort);
                    attempts.Add(new(backend, "runtime_unavailable: " + e.Message));
                }
            }
            throw new DllNotFoundException("No usable local sherpa-onnx runtime. Check native runtime installation.");
        }
    }

    public T Function<T>(string name) where T : Delegate => (T)functions.GetOrAdd(name,
        _ => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(library, "SherpaOnnx" + name)));
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "LoadLibraryExW", SetLastError = true)]
    private static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr Version();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr CreateRecognizer(IntPtr config);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr CreateVad(IntPtr config, float seconds);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr CreateStream(IntPtr recognizer);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr CreateHotwordStream(IntPtr recognizer, [MarshalAs(UnmanagedType.LPUTF8Str)] string words);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void One(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int Check(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int Ready(IntPtr recognizer, IntPtr stream);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void Decode(IntPtr recognizer, IntPtr stream);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr Result(IntPtr recognizer, IntPtr stream);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void Wave(IntPtr stream, int sampleRate, float[] samples, int count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void VadWave(IntPtr vad, float[] samples, int count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void Option(IntPtr stream, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string value);
}
