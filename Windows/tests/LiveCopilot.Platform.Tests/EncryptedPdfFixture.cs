using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace LiveCopilot.Platform.Tests;

// Minimal runtime-only PDF fixture using PDF Standard Security revision 2.
// RC4/MD5 here exercise legacy encrypted input; they are not used by application code.
internal static class EncryptedPdfFixture
{
    public static byte[] Create()
    {
        byte[] padding = Convert.FromHexString("28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A");
        byte[] Pad(string value) => Encoding.ASCII.GetBytes(value).Concat(padding).Take(32).ToArray();
        var id = Enumerable.Range(0, 16).Select(i => (byte)i).ToArray();
        var owner = Rc4(MD5.HashData(Pad("fixture-owner"))[..5], Pad("fixture-password"));
        var key = MD5.HashData(Pad("fixture-password").Concat(owner).Concat(new byte[] { 0xfc, 0xff, 0xff, 0xff }).Concat(id).ToArray())[..5];
        var user = Rc4(key, padding);
        var objectKey = MD5.HashData(key.Concat(new byte[] { 4, 0, 0, 0, 0 }).ToArray())[..10];
        var content = Rc4(objectKey, Encoding.ASCII.GetBytes("BT /F1 12 Tf 20 350 Td (secret evidence) Tj ET"));
        using var output = new MemoryStream();
        void Write(string value) => output.Write(Encoding.ASCII.GetBytes(value));
        var offsets = new List<long> { 0 };
        void Object(int number, string body)
        { offsets.Add(output.Position); Write($"{number} 0 obj\n{body}\nendobj\n"); }
        Write("%PDF-1.4\n");
        Object(1, "<< /Type /Catalog /Pages 2 0 R >>");
        Object(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
        Object(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 400] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>");
        offsets.Add(output.Position); Write($"4 0 obj\n<< /Length {content.Length} >>\nstream\n");
        output.Write(content); Write("\nendstream\nendobj\n");
        Object(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
        Object(6, $"<< /Filter /Standard /V 1 /R 2 /Length 40 /O <{Convert.ToHexString(owner)}> /U <{Convert.ToHexString(user)}> /P -4 >>");
        var xref = output.Position;
        Write("xref\n0 7\n0000000000 65535 f \n");
        foreach (var offset in offsets.Skip(1)) Write(offset.ToString("D10", CultureInfo.InvariantCulture) + " 00000 n \n");
        Write($"trailer\n<< /Size 7 /Root 1 0 R /Encrypt 6 0 R /ID [<{Convert.ToHexString(id)}> <{Convert.ToHexString(id)}>] >>\nstartxref\n{xref}\n%%EOF\n");
        return output.ToArray();
    }

    private static byte[] Rc4(byte[] key, byte[] input)
    {
        var state = Enumerable.Range(0, 256).Select(i => (byte)i).ToArray(); var j = 0;
        for (var i = 0; i < 256; i++) { j = (j + state[i] + key[i % key.Length]) & 255; (state[i], state[j]) = (state[j], state[i]); }
        var result = new byte[input.Length]; var x = 0; j = 0;
        for (var i = 0; i < input.Length; i++)
        {
            x = (x + 1) & 255; j = (j + state[x]) & 255; (state[x], state[j]) = (state[j], state[x]);
            result[i] = (byte)(input[i] ^ state[(state[x] + state[j]) & 255]);
        }
        return result;
    }
}
