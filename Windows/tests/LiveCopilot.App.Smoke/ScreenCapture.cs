#if WINDOWS
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace LiveCopilot.App.Smoke;

// GDI supplies physical pixels; WPF encodes PNGs without a WinForms/System.Drawing dependency.
internal static class ScreenCapture
{
    internal static void Desktop(string file)
    {
        var left = GetSystemMetrics(76); // SM_XVIRTUALSCREEN (may be negative)
        var top = GetSystemMetrics(77);
        var width = GetSystemMetrics(78);
        var height = GetSystemMetrics(79);
        Save(file, width, height, (target, screen) =>
            BitBlt(target, 0, 0, width, height, screen, left, top, 0x00CC0020), checkContent: false);
    }

    internal static void Region(System.Windows.Rect bounds, string file)
    {
        var desktop = new System.Windows.Rect(GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79));
        bounds.Intersect(desktop);
        var left = (int)Math.Floor(bounds.Left); var top = (int)Math.Floor(bounds.Top);
        var width = (int)Math.Ceiling(bounds.Right) - left; var height = (int)Math.Ceiling(bounds.Bottom) - top;
        Save(file, width, height, (target, screen) => BitBlt(target, 0, 0, width, height, screen, left, top, 0x00CC0020), checkContent: true);
    }

    internal static void Window(IntPtr hwnd, string file)
    {
        if (!IsWindowVisible(hwnd) || !GetWindowRect(hwnd, out var rect))
            throw new InvalidOperationException("Window is not visible.");
        if (rect.Right - rect.Left < 100 || rect.Bottom - rect.Top < 100)
            throw new InvalidOperationException("Window is too small.");
        Save(file, rect.Right - rect.Left, rect.Bottom - rect.Top,
            (target, _) => PrintWindow(hwnd, target, 2), checkContent: true);
    }

    private static void Save(string file, int width, int height, Func<IntPtr, IntPtr, bool> capture, bool checkContent)
    {
        if (width <= 0 || height <= 0) throw new InvalidOperationException("Invalid capture dimensions.");
        var screen = GetDC(IntPtr.Zero);
        if (screen == IntPtr.Zero) throw new InvalidOperationException("GetDC failed.");
        IntPtr target = IntPtr.Zero, bitmap = IntPtr.Zero, previous = IntPtr.Zero;
        try
        {
            target = CreateCompatibleDC(screen);
            // Use the screen DC, not the initially monochrome memory DC.
            bitmap = CreateCompatibleBitmap(screen, width, height);
            if (target == IntPtr.Zero || bitmap == IntPtr.Zero)
                throw new InvalidOperationException("Could not allocate capture bitmap.");
            previous = SelectObject(target, bitmap);
            if (previous == IntPtr.Zero || previous == new IntPtr(-1))
                throw new InvalidOperationException("SelectObject failed.");
            if (!capture(target, screen))
                throw new InvalidOperationException("Screen capture failed; interactive desktop required.");
            var source = Imaging.CreateBitmapSourceFromHBitmap(bitmap, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            // GDI's fourth byte is not alpha. Keep captures opaque on all desktop formats.
            var pixels = new FormatConvertedBitmap(source, PixelFormats.Bgr32, null, 0);
            if (checkContent) RequireRenderedContent(pixels);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(pixels));
            using var output = File.Create(file);
            encoder.Save(output);
        }
        finally
        {
            if (previous != IntPtr.Zero && previous != new IntPtr(-1)) _ = SelectObject(target, previous);
            if (bitmap != IntPtr.Zero) _ = DeleteObject(bitmap);
            if (target != IntPtr.Zero) _ = DeleteDC(target);
            _ = ReleaseDC(IntPtr.Zero, screen);
        }
    }

    private static void RequireRenderedContent(BitmapSource bitmap)
    {
        var stride = checked(bitmap.PixelWidth * 4);
        var pixels = new byte[checked(stride * bitmap.PixelHeight)];
        bitmap.CopyPixels(pixels, stride, 0);
        var colors = new HashSet<int>();
        for (var y = 20; y < bitmap.PixelHeight - 20; y += 7)
            for (var x = 20; x < bitmap.PixelWidth - 20; x += 7)
            {
                var offset = y * stride + x * 4;
                colors.Add(pixels[offset] | pixels[offset + 1] << 8 | pixels[offset + 2] << 16);
                if (colors.Count >= 8) return;
            }
        throw new InvalidOperationException("Screenshot is blank or not rendered.");
    }

    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int width, int height);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BitBlt(IntPtr target, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint operation);
}
#endif
