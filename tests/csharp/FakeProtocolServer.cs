using System.Net;
using System.Net.Sockets;
using System.Text.Json;

namespace GodotE2E.Tests;

/// <summary>
/// Loopback stand-in for the Godot E2E server. Speaks the real wire framing
/// and defers every response to a scriptable async delegate; returning null
/// from the responder sends nothing (silence). Covers hello checking, command
/// handling, error injection, slow responses, and abrupt disconnects.
/// </summary>
internal sealed class FakeProtocolServer : IAsyncDisposable
{
    private readonly TcpListener _listener;
    private readonly CancellationTokenSource _shutdown = new();
    private readonly Task _acceptLoop;
    private TcpClient? _client;
    private bool _trickleNext;

    private FakeProtocolServer(TcpListener listener, int port)
    {
        _listener = listener;
        Port = port;
        _acceptLoop = AcceptLoopAsync();
    }

    public int Port { get; }

    /// <summary>Frames received so far (hello first), in arrival order, cloned.</summary>
    public List<JsonElement> Received { get; } = new();

    /// <summary>
    /// Returns the response for a received frame, or null to stay silent.
    /// A response object without an "id" gets the command's id inserted.
    /// Defaults to echoing {"id": n, "ok": true}.
    /// </summary>
    public Func<JsonElement, Task<JsonElement?>>? Responder { get; set; }

    public static FakeProtocolServer Start(
        Func<JsonElement, Task<JsonElement?>>? responder = null)
    {
        var listener = new TcpListener(IPAddress.Parse(E2EProtocol.Host), 0);
        listener.Start();
        return new FakeProtocolServer(listener, ((IPEndPoint)listener.LocalEndpoint).Port)
        {
            Responder = responder,
        };
    }

    /// <summary>Sends the next scripted response byte-by-byte with delays.</summary>
    public void TrickleNextResponse() => _trickleNext = true;

    /// <summary>Abruptly closes the current connection (no response frame).</summary>
    public void CloseClient()
    {
        _client?.Close();
        _client = null;
    }

    public static JsonElement Json(string json) => JsonDocument.Parse(json).RootElement.Clone();

    public async ValueTask DisposeAsync()
    {
        _shutdown.Cancel();
        _listener.Stop();
        _client?.Close();
        try { await _acceptLoop; }
        catch { /* connection teardown races are expected in a fake */ }
        _shutdown.Dispose();
    }

    private async Task AcceptLoopAsync()
    {
        while (!_shutdown.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_shutdown.Token); }
            catch (OperationCanceledException) { return; }
            _client = client;
            try { await ServeAsync(client, _shutdown.Token); }
            catch { /* abrupt closes and shutdown races are expected */ }
            finally
            {
                _client = null;
                client.Dispose();
            }
        }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken ct)
    {
        await using var stream = client.GetStream();
        while (!ct.IsCancellationRequested)
        {
            byte[] body;
            try { body = await E2EFraming.ReadFrameAsync(stream, ct); }
            catch (EndOfStreamException) { return; }
            catch (IOException) { return; }

            var command = JsonDocument.Parse(body).RootElement;
            Received.Add(command.Clone());

            var trickle = _trickleNext;
            _trickleNext = false;
            var response = Responder is null ? Echo(command) : await Responder(command);
            if (response is null)
                continue;

            var payload = SerializeWithId(response.Value, command);
            if (trickle)
                await WriteTrickledAsync(stream, payload, ct);
            else
                await E2EFraming.WriteFrameAsync(stream, payload, ct);
        }
    }

    public static JsonElement Echo(JsonElement command)
    {
        var id = command.TryGetProperty("id", out var value) ? value.GetInt32() : 0;
        return Json(@"{""id"":" + id + @",""ok"":true}");
    }

    private static byte[] SerializeWithId(JsonElement response, JsonElement command)
    {
        if (response.ValueKind != JsonValueKind.Object || response.TryGetProperty("id", out _))
            return JsonSerializer.SerializeToUtf8Bytes(response);

        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            if (command.TryGetProperty("id", out var id))
            {
                writer.WritePropertyName("id");
                id.WriteTo(writer);
            }
            foreach (var property in response.EnumerateObject())
                property.WriteTo(writer);
            writer.WriteEndObject();
        }
        return stream.ToArray();
    }

    private static async Task WriteTrickledAsync(Stream stream, byte[] payload, CancellationToken ct)
    {
        var prefix = new byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(prefix, (uint)payload.Length);
        foreach (var b in prefix.Concat(payload))
        {
            await stream.WriteAsync(new[] { b }, ct);
            await stream.FlushAsync(ct);
            await Task.Delay(2, ct);
        }
    }
}
