using System.Runtime.InteropServices;

namespace LiveCopilot.LocalInference;

public enum InferenceBackend { Cpu, Cuda, DirectML, Vulkan }
public sealed record HardwareCapabilities(bool Windows, bool Nvidia, bool DirectML, bool Vulkan);
public interface IHardwareProbe { HardwareCapabilities Detect(); }
public sealed record BackendAttempt(InferenceBackend Backend, string Outcome);

public sealed record InferenceOptions
{
    public bool ForceCpu { get; init; } = Environment.GetEnvironmentVariable("LIVECOPILOT_INFERENCE_CPU") == "1";
    public string SherpaRuntimeRoot { get; init; } = Path.Combine(AppContext.BaseDirectory, "native", "sherpa");
    public IHardwareProbe HardwareProbe { get; init; } = new SystemHardwareProbe();
}

public static class BackendSelection
{
    public static IReadOnlyList<InferenceBackend> Speech(HardwareCapabilities hardware, bool forceCpu = false)
    {
        if (forceCpu) return [InferenceBackend.Cpu];
        List<InferenceBackend> choices = [];
        if (hardware.Nvidia) choices.Add(InferenceBackend.Cuda);
        if (hardware.Windows && hardware.DirectML) choices.Add(InferenceBackend.DirectML);
        choices.Add(InferenceBackend.Cpu);
        return choices;
    }
    public static IReadOnlyList<InferenceBackend> Embedding(HardwareCapabilities hardware, bool forceCpu = false)
    {
        if (forceCpu) return [InferenceBackend.Cpu];
        List<InferenceBackend> choices = [];
        if (hardware.Nvidia) choices.Add(InferenceBackend.Cuda);
        if (hardware.Vulkan) choices.Add(InferenceBackend.Vulkan);
        choices.Add(InferenceBackend.Cpu);
        return choices;
    }
}

public sealed class SystemHardwareProbe : IHardwareProbe
{
    public HardwareCapabilities Detect() => new(OperatingSystem.IsWindows(), HasCudaDevice(), HasDirectMLDevice(),
        HasLibrary(OperatingSystem.IsWindows() ? "vulkan-1.dll" : "libvulkan.so.1"));

    private static bool HasLibrary(string name)
    {
        if (!NativeLibrary.TryLoad(name, out var handle)) return false;
        NativeLibrary.Free(handle);
        return true;
    }
    private static bool HasCudaDevice()
    {
        if (!NativeLibrary.TryLoad(OperatingSystem.IsWindows() ? "nvcuda.dll" : "libcuda.so.1", out var handle)) return false;
        try
        {
            var init = Marshal.GetDelegateForFunctionPointer<CuInit>(NativeLibrary.GetExport(handle, "cuInit"));
            var count = Marshal.GetDelegateForFunctionPointer<CuCount>(NativeLibrary.GetExport(handle, "cuDeviceGetCount"));
            return init(0) == 0 && count(out var devices) == 0 && devices > 0;
        }
        catch (EntryPointNotFoundException) { return false; }
        finally { NativeLibrary.Free(handle); }
    }
    private static bool HasDirectMLDevice()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            var iid = new Guid("189819f1-1db6-4b57-be54-1821339b85f7");
            var result = D3D12CreateDevice(IntPtr.Zero, 0xb000, ref iid, out var device);
            if (device != IntPtr.Zero) Marshal.Release(device);
            return result >= 0;
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException) { return false; }
    }
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate int CuInit(uint flags);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate int CuCount(out int count);
    [DllImport("d3d12.dll", ExactSpelling = true)]
    private static extern int D3D12CreateDevice(IntPtr adapter, int featureLevel, ref Guid iid, out IntPtr device);
}
