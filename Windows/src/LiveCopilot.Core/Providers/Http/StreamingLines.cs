namespace LiveCopilot.Core;

/// Frames original UTF-8 bytes, including empty LF, CRLF and CR lines.
public sealed class StreamingLines
{
    public const int MaximumEventBytes = 1_048_576;
    internal const string OversizedMessage = "Reasoning stream contained an oversized event. Retry this question.";
    private static readonly Encoding Utf8 = new UTF8Encoding(false, true);
    private readonly List<byte> bytes = [];
    private bool afterCR;
    private int eventBytes;

    public string? Consume(byte value)
    {
        if (afterCR)
        {
            afterCR = false;
            if (value == 10)
            {
                if (eventBytes > 0) CountEventByte();
                return null;
            }
        }
        if (value is 10 or 13)
        {
            afterCR = value == 13;
            if (bytes.Count == 0) eventBytes = 0;
            else CountEventByte();
            return Flush();
        }
        CountEventByte();
        bytes.Add(value);
        return null;
    }

    public string? Finish() => bytes.Count == 0 ? null : Flush();
    private void CountEventByte()
    {
        // Include line terminators and comments, so many short lines cannot bypass the cap.
        if (eventBytes >= MaximumEventBytes) throw new CopilotException(OversizedMessage);
        eventBytes++;
    }
    private string Flush()
    {
        try { return Utf8.GetString(bytes.ToArray()); }
        catch (DecoderFallbackException)
        { throw new CopilotException("Reasoning stream contained invalid text encoding. Retry this question."); }
        finally { bytes.Clear(); }
    }
}

public sealed class ServerSentEvents
{
    private readonly List<string> data = [];
    private int eventBytes;
    public string? Consume(string line)
    {
        if (line.Length == 0)
        {
            var result = data.Count == 0 ? null : string.Join('\n', data);
            data.Clear(); eventBytes = 0;
            return result;
        }
        // Bound the whole event as well as individual lines, including comments.
        var size = Encoding.UTF8.GetByteCount(line) + 1;
        if (size > StreamingLines.MaximumEventBytes - eventBytes)
            throw new CopilotException(StreamingLines.OversizedMessage);
        eventBytes += size;
        if (line.StartsWith("data:", StringComparison.Ordinal))
        {
            var payload = line[5..];
            data.Add(payload.StartsWith(' ') ? payload[1..] : payload);
        }
        return null;
    }
    public string? Finish() => Consume("");
}
