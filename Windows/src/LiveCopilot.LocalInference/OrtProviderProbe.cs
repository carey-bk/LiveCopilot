using System.Runtime.InteropServices;

namespace LiveCopilot.LocalInference;

// Query the SAME ORT DLL that sherpa will load, without installing a second ORT
// NuGet runtime. OrtApi v8 is an append-only C ABI supported by newer runtimes.
// Slots: microsoft/onnxruntime v1.8.0, include/onnxruntime/core/session/onnxruntime_c_api.h.
internal sealed class OrtProviderProbe
{
    private readonly IntPtr library, api;
    internal OrtProviderProbe(IntPtr library)
    {
        this.library = library;
        var root = Marshal.GetDelegateForFunctionPointer<GetApiBase>(NativeLibrary.GetExport(library, "OrtGetApiBase"))();
        api = Marshal.GetDelegateForFunctionPointer<GetApi>(Marshal.ReadIntPtr(root))(8);
        if (api == IntPtr.Zero) throw new NotSupportedException("ONNX Runtime must support OrtApi v8.");
    }
    private T Function<T>(int slot) where T : Delegate =>
        Marshal.GetDelegateForFunctionPointer<T>(Marshal.ReadIntPtr(api, slot * IntPtr.Size));
    private void Check(IntPtr status)
    {
        if (status == IntPtr.Zero) return;
        try { throw new InvalidOperationException("ONNX Runtime provider probe: " + Marshal.PtrToStringUTF8(Function<Message>(2)(status))); }
        finally { Function<Release>(93)(status); }
    }
    internal IReadOnlyList<string> AvailableProviders()
    {
        Check(Function<Providers>(125)(out var names, out var count));
        try
        {
            return Enumerable.Range(0, count).Select(i =>
                Marshal.PtrToStringUTF8(Marshal.ReadIntPtr(names, i * IntPtr.Size)) ?? "").ToArray();
        }
        finally { Check(Function<FreeProviders>(126)(names, count)); }
    }
    internal void Require(InferenceBackend backend)
    {
        var name = backend switch
        {
            InferenceBackend.Cuda => "CUDAExecutionProvider",
            InferenceBackend.DirectML => "DmlExecutionProvider",
            InferenceBackend.Cpu => "CPUExecutionProvider",
            _ => throw new ArgumentOutOfRangeException(nameof(backend))
        };
        if (!AvailableProviders().Contains(name)) throw new InvalidOperationException("ONNX Runtime provider unavailable: " + name);
        if (backend == InferenceBackend.Cpu) return;
        Check(Function<CreateOptions>(10)(out var options));
        try
        {
            if (backend == InferenceBackend.Cuda)
            {
                var cuda = new CudaOptions { AlgorithmSearch = 1, MemoryLimit = nuint.MaxValue, CopyInDefaultStream = 1 };
                Check(Function<AppendCuda>(152)(options, ref cuda));
            }
            else
            {
                Check(Function<SetMode>(13)(options, 0)); // sequential
                Check(Function<Option>(17)(options)); // disable memory patterns
                var append = Marshal.GetDelegateForFunctionPointer<AppendDml>(
                    NativeLibrary.GetExport(library, "OrtSessionOptionsAppendExecutionProvider_DML"));
                Check(append(options, 0));
            }
        }
        finally { Function<Release>(100)(options); }
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct CudaOptions
    {
        public int Device, AlgorithmSearch;
        public nuint MemoryLimit;
        public int ArenaStrategy, CopyInDefaultStream, HasUserStream;
        public IntPtr UserStream, ArenaConfig;
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr GetApiBase();
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr GetApi(uint version);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr Message(IntPtr status);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void Release(IntPtr value);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr Providers(out IntPtr names, out int count);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr FreeProviders(IntPtr names, int count);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr CreateOptions(out IntPtr options);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr Option(IntPtr options);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr SetMode(IntPtr options, int mode);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr AppendCuda(IntPtr options, ref CudaOptions cuda);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr AppendDml(IntPtr options, int device);
}
