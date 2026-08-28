using System.Text;

namespace GodotE2E;

/// <summary>
/// Fixed-size UTF-8 byte tail: continuously consumes stream chunks while
/// retaining only the most recent <see cref="E2EProtocol.MaxPipeBytes"/> bytes.
/// Ring buffer, so a steady producer never allocates and never grows. Mirrors
/// E2EProcess.MAX_PIPE_BYTES from e2e_process.gd.
/// </summary>
internal sealed class PipeTail
{
    private readonly byte[] _buffer = new byte[E2EProtocol.MaxPipeBytes];
    private int _start;
    private int _count;
    private long _total;

    public long TotalBytes => _total;

    public void Append(ReadOnlySpan<byte> chunk)
    {
        _total += chunk.Length;
        if (chunk.Length >= _buffer.Length)
        {
            chunk[^_buffer.Length..].CopyTo(_buffer);
            _start = 0;
            _count = _buffer.Length;
            return;
        }

        var end = (_start + _count) % _buffer.Length;
        var first = Math.Min(chunk.Length, _buffer.Length - end);
        chunk[..first].CopyTo(_buffer.AsSpan(end));
        chunk[first..].CopyTo(_buffer.AsSpan(0));

        var count = _count + chunk.Length;
        if (count > _buffer.Length)
        {
            _start = (_start + count - _buffer.Length) % _buffer.Length;
            count = _buffer.Length;
        }
        _count = count;
    }

    /// <summary>
    /// Decodes retained bytes as UTF-8. A multi-byte character split at the
    /// ring seam decodes as U+FFFD; acceptable for diagnostics.
    /// </summary>
    public override string ToString()
    {
        if (_count == 0)
            return string.Empty;
        if (_count < _buffer.Length)
            return Encoding.UTF8.GetString(_buffer, 0, _count);
        return Encoding.UTF8.GetString(_buffer, _start, _buffer.Length - _start)
            + Encoding.UTF8.GetString(_buffer, 0, _start);
    }
}
