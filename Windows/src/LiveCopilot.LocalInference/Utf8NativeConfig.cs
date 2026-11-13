using System.Reflection;
using System.Runtime.InteropServices;

namespace LiveCopilot.LocalInference;

// sherpa's C# config fields use LPStr (the Windows ANSI code page), whereas the
// native API expects UTF-8. Keep upstream layouts but encode paths explicitly so
// Chinese Windows usernames/model directories do not depend on the host manifest.
internal sealed class Utf8NativeConfig<T> : IDisposable where T : struct
{
    private readonly List<IntPtr> strings = [];
    public IntPtr Pointer { get; private set; }
    public Utf8NativeConfig(T value)
    {
        Pointer = Marshal.AllocHGlobal(Marshal.SizeOf<T>());
        try { Write(value, typeof(T), Pointer); }
        catch { Dispose(); throw; }
    }
    private void Write(object value, Type type, IntPtr address)
    {
        foreach (var field in type.GetFields(BindingFlags.Public | BindingFlags.Instance))
        {
            var target = address + checked((int)Marshal.OffsetOf(type, field.Name));
            var item = field.GetValue(value);
            if (field.FieldType == typeof(string))
            {
                var text = item is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8((string)item);
                if (text != IntPtr.Zero) strings.Add(text);
                Marshal.WriteIntPtr(target, text);
            }
            else if (field.FieldType == typeof(int)) Marshal.WriteInt32(target, (int)item!);
            else if (field.FieldType == typeof(float)) Marshal.WriteInt32(target, BitConverter.SingleToInt32Bits((float)item!));
            else if (field.FieldType.IsValueType && !field.FieldType.IsPrimitive && !field.FieldType.IsEnum)
                Write(item!, field.FieldType, target);
            else throw new NotSupportedException("Unsupported sherpa config field: " + field.Name);
        }
    }
    public void Dispose()
    {
        foreach (var text in strings) Marshal.FreeCoTaskMem(text);
        strings.Clear();
        if (Pointer != IntPtr.Zero) Marshal.FreeHGlobal(Pointer);
        Pointer = IntPtr.Zero;
    }
}
