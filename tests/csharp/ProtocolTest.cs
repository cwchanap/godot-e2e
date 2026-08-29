using System.Text;
using System.Text.Json;
using GdUnit4;
using GodotE2E;
using static GdUnit4.Assertions;

namespace GodotE2E.Tests;

[TestSuite]
public class ProtocolTest
{
    // ---- Framing: big-endian length prefix, partial reads, oversize rejection ----

    [TestCase]
    public async Task WriteFrame_PrependsUnsignedBigEndianLength()
    {
        using var stream = new MemoryStream();
        var payload = Encoding.UTF8.GetBytes("{\"id\":1}");

        await E2EFraming.WriteFrameAsync(stream, payload, CancellationToken.None);

        var bytes = stream.ToArray();
        AssertThat(bytes.Length).IsEqual(4 + payload.Length);
        AssertThat(bytes[0]).IsEqual(0);
        AssertThat(bytes[1]).IsEqual(0);
        AssertThat(bytes[2]).IsEqual(0);
        AssertThat(bytes[3]).IsEqual((byte)payload.Length);
        AssertThat(bytes.AsSpan(4).ToArray()).IsEqual(payload);
    }

    [TestCase]
    public async Task ReadFrame_ReassemblesFrameDeliveredByteByByte()
    {
        var payload = Encoding.UTF8.GetBytes("{\"action\":\"get_property\",\"path\":\"/root/Main\"}");
        using var framed = new MemoryStream();
        await E2EFraming.WriteFrameAsync(framed, payload, CancellationToken.None);
        using var stream = new TrickleReader(framed.ToArray());

        var read = await E2EFraming.ReadFrameAsync(stream, CancellationToken.None);

        AssertThat(read).IsEqual(payload);
    }

    [TestCase]
    public async Task ReadFrame_RejectsOversizeDeclarationBeforeReadingBody()
    {
        // Declaration says 16 MiB + 1 bytes; no body bytes follow. The frame cap
        // must be enforced before any body allocation or body read.
        using var stream = new MemoryStream();
        var prefix = new byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(
            prefix, (uint)E2EProtocol.MaxFrameBytes + 1);
        stream.Write(prefix);
        stream.Seek(0, SeekOrigin.Begin);

        var error = await CatchAsync(() => E2EFraming.ReadFrameAsync(stream, CancellationToken.None));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual(
            $"Response frame declaration exceeds {E2EProtocol.MaxFrameBytes} bytes");
    }

    [TestCase]
    public async Task WriteFrame_RejectsOversizePayload()
    {
        using var stream = new MemoryStream();
        var payload = new byte[E2EProtocol.MaxFrameBytes + 1];

        var error = await CatchAsync(
            () => E2EFraming.WriteFrameAsync(stream, payload, CancellationToken.None));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(stream.Length).IsEqual(0);
    }

    // ---- E2EJson conversion ----

    [TestCase]
    public void Convert_NullReturnsNull()
    {
        var element = JsonDocument.Parse("null").RootElement;

        var value = E2EJson.Convert<object>(element);

        AssertThat(value).IsNull();
    }

    [TestCase]
    public void Convert_V2TagBuildsVector()
    {
        var element = JsonDocument.Parse("{\"_t\":\"v2\",\"x\":1.5,\"y\":-2}").RootElement;

        var value = E2EJson.Convert<E2EVector2>(element);

        AssertThat(value.X).IsEqual(1.5);
        AssertThat(value.Y).IsEqual(-2.0);
    }

    [TestCase]
    public void Convert_V3TagFailsLoudlyWithExactMessage()
    {
        var element = JsonDocument.Parse("{\"_t\":\"v3\",\"x\":1,\"y\":2,\"z\":3}").RootElement;

        var error = Catch(() => E2EJson.Convert<object>(element));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual(
            "Unsupported Godot value tag 'v3'; use SendCommandAsync for raw access");
    }

    [TestCase]
    public void Convert_ColorTagFailsLoudlyWithExactMessage()
    {
        var element = JsonDocument.Parse("{\"_t\":\"col\",\"r\":1,\"g\":0,\"b\":0,\"a\":1}").RootElement;

        var error = Catch(() => E2EJson.Convert<object>(element));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual(
            "Unsupported Godot value tag 'col'; use SendCommandAsync for raw access");
    }

    [TestCase]
    public void Convert_UntaggedJsonUsesGenericDeserialization()
    {
        var element = JsonDocument.Parse("[3,1,4]").RootElement;

        var value = E2EJson.Convert<int[]>(element);

        AssertThat(value).IsEqual(new[] { 3, 1, 4 });
    }

    [TestCase]
    public void Convert_NestedUnsupportedTagFailsLoudlyWithExactMessage()
    {
        // e2e_serializer.gd recurses, so nested tagged payloads are real on
        // the wire; only the ROOT tag was checked before.
        var element = JsonDocument.Parse(
            "[{\"position\":{\"_t\":\"col\",\"r\":1,\"g\":0,\"b\":0,\"a\":1}}]").RootElement;

        var error = Catch(() => E2EJson.Convert<object>(element));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual(
            "Unsupported Godot value tag 'col'; use SendCommandAsync for raw access");
    }

    [TestCase]
    public void Convert_DeeplyNestedUnsupportedTagFailsLoudly()
    {
        var element = JsonDocument.Parse(
            "{\"a\":{\"b\":[{\"_t\":\"np\",\"data\":\"x\"}]}}").RootElement;

        var error = Catch(() => E2EJson.Convert<Dictionary<string, object>>(element));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual(
            "Unsupported Godot value tag 'np'; use SendCommandAsync for raw access");
    }

    [TestCase]
    public void Convert_NestedV2InsideArrayFailsLoudlyNotSilentlyWrong()
    {
        // Array[Vector2] arrives as [{"_t":"v2",...}] on the wire. Nested v2
        // conversion is out of scope, so it must fail LOUD — never silently
        // deserialize into a plausible but wrong shape.
        var element = JsonDocument.Parse(
            "[{\"_t\":\"v2\",\"x\":1,\"y\":2},{\"_t\":\"v2\",\"x\":3,\"y\":4}]").RootElement;

        var error = Catch(() => E2EJson.Convert<IReadOnlyList<E2EVector2>>(element));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual(
            "Unsupported Godot value tag 'v2'; use SendCommandAsync for raw access");
    }

    [TestCase]
    public void Convert_NestedV2InUntypedPayloadFailsLoudly()
    {
        var element = JsonDocument.Parse(
            "{\"items\":[{\"_t\":\"v2\",\"x\":1,\"y\":2}]}").RootElement;

        var error = Catch(() => E2EJson.Convert<Dictionary<string, object>>(element));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual(
            "Unsupported Godot value tag 'v2'; use SendCommandAsync for raw access");
    }

    // ---- Drift guard: C# protocol constants vs GDScript sources ----

    [TestCase]
    public void ProtocolConstants_MatchGdScriptSources()
    {
        var protocol = ReadGdSource("addons/gdunit_e2e/protocol/e2e_protocol.gd");
        var process = ReadGdSource("addons/gdunit_e2e/client/e2e_process.gd");

        AssertThat(GdNumberConst(protocol, "PROTOCOL_VERSION"))
            .IsEqual(E2EProtocol.ProtocolVersion);
        AssertThat(GdNumberConst(protocol, "MAX_FRAME_BYTES"))
            .IsEqual(E2EProtocol.MaxFrameBytes);
        AssertThat(GdNumberConst(protocol, "DEFAULT_COMMAND_TIMEOUT_SECONDS"))
            .IsEqual(E2EProtocol.DefaultCommandTimeout.TotalSeconds);
        AssertThat(GdNumberConst(protocol, "WAIT_MARGIN_SECONDS"))
            .IsEqual(E2EProtocol.WaitMargin.TotalSeconds);
        AssertThat(GdNumberConst(process, "MAX_PIPE_BYTES"))
            .IsEqual(E2EProtocol.MaxPipeBytes);
    }

    private static string ReadGdSource(string relativePath)
    {
        return File.ReadAllText(Path.Combine(TestPaths.RepositoryRoot, relativePath));
    }

    /// Extracts a numeric `const NAME := expr` value from GDScript source text.
    /// Supports decimal literals joined by `*`, e.g. `16 * 1024 * 1024` or `5.0`.
    private static double GdNumberConst(string source, string name)
    {
        var match = System.Text.RegularExpressions.Regex.Match(
            source, $@"const\s+{name}\s*:=\s*([^\r\n]+)");
        AssertThat(match.Success).IsTrue();
        var product = 1.0;
        foreach (var part in match.Groups[1].Value.Split('*'))
            product *= double.Parse(part.Trim(), System.Globalization.CultureInfo.InvariantCulture);
        return product;
    }

    private static Exception? Catch(Action action)
    {
        try
        {
            action();
            return null;
        }
        catch (Exception e)
        {
            return e;
        }
    }

    private static async Task<Exception?> CatchAsync(Func<Task> action)
    {
        try
        {
            await action();
            return null;
        }
        catch (Exception e)
        {
            return e;
        }
    }

    /// A stream whose every Read returns at most one byte, forcing partial reads.
    private sealed class TrickleReader : Stream
    {
        private readonly byte[] _bytes;
        private int _position;

        public TrickleReader(byte[] bytes) => _bytes = bytes;

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => _bytes.Length;

        public override long Position
        {
            get => _position;
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            if (count == 0 || _position >= _bytes.Length)
                return 0;
            buffer[offset] = _bytes[_position++];
            return 1;
        }

        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
