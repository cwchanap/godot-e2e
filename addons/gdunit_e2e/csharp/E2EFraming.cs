using System.Buffers.Binary;
using System.Text.Json;

namespace GodotE2E;

/// <summary>
/// Byte framing on a stream: a four-byte unsigned big-endian payload length
/// followed by the UTF-8 JSON body. Mirrors e2e_framing.gd semantics.
/// </summary>
public static class E2EFraming
{
    public static async Task WriteFrameAsync(Stream stream, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
    {
        if (payload.Length > E2EProtocol.MaxFrameBytes)
            throw new E2EException($"E2E frame exceeds the {E2EProtocol.MaxFrameBytes} byte limit");

        var prefix = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(prefix, (uint)payload.Length);
        await stream.WriteAsync(prefix, cancellationToken);
        await stream.WriteAsync(payload, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    /// <summary>
    /// Reads one complete frame. The declared length is checked against the
    /// frame cap before any body allocation or body read.
    /// </summary>
    public static async Task<byte[]> ReadFrameAsync(Stream stream, CancellationToken cancellationToken)
    {
        var prefix = new byte[4];
        await ReadExactlyAsync(stream, prefix, cancellationToken);
        var declared = BinaryPrimitives.ReadUInt32BigEndian(prefix);
        if (declared > E2EProtocol.MaxFrameBytes)
            throw new E2EException($"Response frame declaration exceeds {E2EProtocol.MaxFrameBytes} bytes");

        var body = new byte[declared];
        await ReadExactlyAsync(stream, body, cancellationToken);
        return body;
    }

    private static async Task ReadExactlyAsync(Stream stream, Memory<byte> buffer, CancellationToken cancellationToken)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var count = await stream.ReadAsync(buffer[read..], cancellationToken);
            if (count <= 0)
                throw new EndOfStreamException($"Stream closed after {read} of {buffer.Length} expected bytes");
            read += count;
        }
    }
}
