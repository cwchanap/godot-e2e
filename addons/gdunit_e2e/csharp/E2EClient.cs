using System.Diagnostics;
using System.Net.Sockets;
using System.Text.Json;

namespace GodotE2E;

/// <summary>
/// Transport seam so game wrappers depend on command sending, not on
/// <see cref="E2EClient"/> concretely; a recording sender implements this to
/// pin wait/reload margins without a real connection.
/// </summary>
internal interface IE2ECommandSender
{
    Task<E2EResult> SendCommandAsync(
        string action,
        IReadOnlyDictionary<string, JsonElement>? parameters = null,
        TimeSpan timeout = default,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Raw client owning ONE TCP session to the fixed loopback host. Sends the
/// protocol-v1 hello first, then commands with monotonically increasing ids.
/// Exactly one command may be in flight; overlapping sends fail fast. Timeouts
/// use a linked cancellation source; transport failures, disconnects, and
/// response-id mismatches throw <see cref="E2EException"/>. Responses are
/// cloned — the caller never sees this client's internal JsonDocument.
/// Mirrors e2e_client.gd semantics.
/// </summary>
public sealed class E2EClient : IE2ECommandSender, IAsyncDisposable
{
    private TcpClient? _connection;
    private int _nextId = 1;
    private readonly SemaphoreSlim _inFlight = new(1, 1);
    private readonly List<JsonElement> _collectedLogs = new();
    private int _disposed;

    /// <summary>
    /// Effective transport timeout for a command: the six commands the
    /// GDScript parent (<c>gdunit_e2e_game.gd</c>) margins get the extra
    /// <see cref="E2EProtocol.WaitMargin"/> on top of the default.
    /// </summary>
    public static TimeSpan CommandTimeoutFor(string action) =>
        action is "wait_seconds" or "wait_for_node" or "wait_for_property"
            or "wait_for_signal" or "change_scene" or "reload_scene"
            ? E2EProtocol.DefaultCommandTimeout + E2EProtocol.WaitMargin
            : E2EProtocol.DefaultCommandTimeout;

    public async Task<E2EResult> ConnectAsync(
        int port,
        string token,
        TimeSpan timeout = default,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        using var gate = AcquireInFlightOrThrow();
        // Like E2EProcess.LaunchAsync: fail loud on a live session instead
        // of orphaning the first socket; reconnect only after DropConnection.
        if (_connection is not null)
            throw new E2EException(
                "E2EClient already owns an open session; dispose it before connecting again");

        var effective = timeout == default ? E2EProtocol.DefaultCommandTimeout : timeout;
        // One monotonic start timestamp bounds both the TCP connect and the
        // hello, so a slow connect cannot restart the clock for the handshake.
        // Mirrors the single-deadline contract E2EProcess.LaunchAsync enforces
        // for the whole launch (port-file wait + connect + hello): never a
        // fresh full timeout. Stopwatch is monotonic (like e2e_client.gd's
        // Time.get_ticks_msec); DateTime.UtcNow is a wall clock that NTP or a
        // manual adjustment can shift mid-handshake.
        var startTimestamp = Stopwatch.GetTimestamp();
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(effective);

        var connection = new TcpClient();
        try
        {
            await connection.ConnectAsync(E2EProtocol.Host, port, timeoutCts.Token);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            connection.Dispose();
            throw new E2EException(
                $"Connect to {E2EProtocol.Host}:{port} timed out after {(int)effective.TotalMilliseconds} ms");
        }
        catch (OperationCanceledException)
        {
            // Caller cancellation during TcpClient.ConnectAsync: preserve it
            // (mirrors SendCoreAsync) instead of relabeling as a connection
            // failure, so a cancelled launch/session stays distinguishable.
            connection.Dispose();
            throw;
        }
        catch (Exception e)
        {
            connection.Dispose();
            throw new E2EException($"Failed to connect to {E2EProtocol.Host}:{port}", e);
        }

        Volatile.Write(ref _connection, connection);
        // DisposeAsync may have won the race while we awaited
        // TcpClient.ConnectAsync: it set _disposed and DropConnection found
        // _connection still null, so the socket we just published would leak
        // (a later DisposeAsync returns early because _disposed is already set).
        // Tear it down if disposal already ran. A disposal that runs after this
        // point is already safe: DropConnection finds the published socket.
        if (Volatile.Read(ref _disposed) != 0)
        {
            DropConnection();
            throw new ObjectDisposedException(nameof(E2EClient));
        }
        // The connect consumed part of the shared budget; the hello gets only
        // what remains. A non-positive remainder fails loud rather than being
        // treated as "use default" by SendCoreAsync, which would restart the
        // clock a third time and let the configured timeout be exceeded.
        var helloRemaining = effective - Stopwatch.GetElapsedTime(startTimestamp);
        if (helloRemaining <= TimeSpan.Zero)
        {
            DropConnection();
            throw new E2EException(
                $"Connect to {E2EProtocol.Host}:{port} timed out before the hello handshake after {(int)effective.TotalMilliseconds} ms");
        }
        var result = await SendCoreAsync(
            "hello",
            new Dictionary<string, JsonElement>
            {
                ["token"] = JsonSerializer.SerializeToElement(token),
                ["protocol_version"] = JsonSerializer.SerializeToElement(E2EProtocol.ProtocolVersion),
            },
            helloRemaining,
            cancellationToken,
            gate);
        // e2e_client.gd drops the peer when the hello handshake fails.
        if (!result.Success)
            DropConnection();
        return result;
    }

    /// <summary>Snapshot of every response log entry seen this session,
    /// mirroring e2e_client.gd's collected logs used for failure artifacts.</summary>
    public IReadOnlyList<JsonElement> GetCollectedLogs() => _collectedLogs.ToList();

    public async Task<E2EResult> SendCommandAsync(
        string action,
        IReadOnlyDictionary<string, JsonElement>? parameters = null,
        TimeSpan timeout = default,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var effective = timeout == default ? CommandTimeoutFor(action) : timeout;
        // using, like ConnectAsync: SendCoreAsync can throw before its own try
        // (e.g. CreateLinkedTokenSource on a disposed caller token); release is
        // idempotent with the gate's own Interlocked.
        using var gate = AcquireInFlightOrThrow();
        return await SendCoreAsync(action, parameters, effective, cancellationToken, gate);
    }

    private async Task<E2EResult> SendCoreAsync(
        string action,
        IReadOnlyDictionary<string, JsonElement>? parameters,
        TimeSpan timeout,
        CancellationToken cancellationToken,
        InFlightGate gate)
    {
        var connection = _connection;
        if (connection is null)
        {
            gate.Dispose();
            throw new E2EException("E2E session is not open");
        }

        var commandId = _nextId++;
        var command = new Dictionary<string, JsonElement>
        {
            ["id"] = JsonSerializer.SerializeToElement(commandId),
            ["action"] = JsonSerializer.SerializeToElement(action),
        };
        if (parameters is not null)
            foreach (var (key, value) in parameters)
                command[key] = value;

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(timeout);
        try
        {
            var stream = connection.GetStream();
            await E2EFraming.WriteFrameAsync(
                stream, JsonSerializer.SerializeToUtf8Bytes(command), timeoutCts.Token);
            var body = await E2EFraming.ReadFrameAsync(stream, timeoutCts.Token);
            using var document = JsonDocument.Parse(body);
            return BuildResultAndCollect(document.RootElement, action, commandId);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // A timed-out session may hold a late response; it is unusable.
            DropConnection();
            throw new E2EException(
                $"Command '{action}' timed out after {(int)timeout.TotalMilliseconds} ms");
        }
        catch (OperationCanceledException)
        {
            // Caller cancellation: the command may already be on the wire (or
            // partly written), so a late server response would land on the
            // socket and corrupt the next command's frame/id. Drop the session
            // before rethrowing so the cancellation semantics are preserved but
            // the stale socket can never be reused.
            DropConnection();
            throw;
        }
        catch (Exception e) when (e is EndOfStreamException or IOException or SocketException or ObjectDisposedException)
        {
            DropConnection();
            throw new E2EException($"Connection lost while waiting for '{action}'", e);
        }
        catch (E2EException)
        {
            DropConnection();
            throw;
        }
        finally
        {
            gate.Dispose();
        }
    }

    private InFlightGate AcquireInFlightOrThrow()
    {
        // Timeout 0 always completes synchronously: fail fast, never queue.
        if (!_inFlight.WaitAsync(0).GetAwaiter().GetResult())
            throw new E2EException("A command is already in flight");
        return new InFlightGate(_inFlight);
    }

    private E2EResult BuildResult(string action, int commandId, JsonElement response)
    {
        if (response.ValueKind != JsonValueKind.Object)
            throw new E2EException("Invalid response message");

        bool hasId = response.TryGetProperty("id", out var idElement);
        bool hasError = response.TryGetProperty("error", out _);
        // e2e_client.gd: a response without "id" is accepted only when it
        // carries an "error" (the real server answers invalid_json without an
        // id); anything else is an id mismatch.
        // Godot's JSON round-trips integer ids as floats ("id":1.0), and the
        // GDScript parent's == compares numerically; GetDouble matches that.
        var matches = (hasId
            && idElement.ValueKind == JsonValueKind.Number
            && idElement.GetDouble() == commandId)
            || (!hasId && hasError);
        if (!matches)
            throw new E2EException(
                $"Unexpected response id {(hasId ? idElement.ToString() : "<null>")} for '{action}'");

        return new E2EResult
        {
            Success = !hasError,
            Value = CloneWithoutLogKeys(response),
            Message = hasError ? RenderError(response) : string.Empty,
            Logs = ExtractLogs(response),
        };
    }

    private E2EResult BuildResultAndCollect(JsonElement response, string action, int commandId)
    {
        var result = BuildResult(action, commandId, response);
        _collectedLogs.AddRange(result.Logs);
        return result;
    }

    private static string RenderError(JsonElement response)
    {
        var errorText = StringifyProperty(response, "error");
        var detail = StringifyProperty(response, "message");
        if (errorText.Length == 0)
            return detail;
        if (detail.Length == 0 || detail == errorText)
            return errorText;
        return $"{errorText}: {detail}";
    }

    private static string StringifyProperty(JsonElement response, string name) =>
        response.TryGetProperty(name, out var value)
            ? value.ValueKind == JsonValueKind.String ? value.GetString()! : value.ToString()
            : string.Empty;

    private static List<JsonElement> ExtractLogs(JsonElement response)
    {
        var entries = new List<JsonElement>();
        if (response.TryGetProperty("_logs", out var rawLogs)
            && rawLogs.ValueKind == JsonValueKind.Array)
        {
            foreach (var entry in rawLogs.EnumerateArray())
                entries.Add(entry.Clone());
        }

        if (response.TryGetProperty("_logs_dropped", out var dropped)
            && dropped.ValueKind == JsonValueKind.Number
            && dropped.GetDouble() > 0)
        {
            var droppedCount = (int)dropped.GetDouble();
            entries.Add(JsonDocument.Parse(
                $"{{\"level\":\"warning\",\"message\":\"<{droppedCount}> log entries dropped due to capture buffer overflow\"}}").RootElement.Clone());
        }

        return entries;
    }

    private static JsonElement CloneWithoutLogKeys(JsonElement response)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            foreach (var property in response.EnumerateObject())
            {
                if (property.Name is "_logs" or "_logs_dropped")
                    continue;
                property.WriteTo(writer);
            }
            writer.WriteEndObject();
        }

        using var document = JsonDocument.Parse(buffer.ToArray());
        return document.RootElement.Clone();
    }

    /// <summary>Drops the session. Idempotent.</summary>
    private void DropConnection()
    {
        var connection = Interlocked.Exchange(ref _connection, null);
        if (connection is not null)
            connection.Dispose();
    }

    public ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
            return ValueTask.CompletedTask;
        // _inFlight is deliberately not disposed: an in-flight command's
        // gate releases it from SendCoreAsync's finally, and disposing here
        // would make that Release throw ObjectDisposedException.
        DropConnection();
        return ValueTask.CompletedTask;
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
    }

    /// <summary>Releases the one-in-flight slot exactly once, even if both the
    /// owning scope and SendCoreAsync's finally try.</summary>
    private sealed class InFlightGate : IDisposable
    {
        private readonly SemaphoreSlim _semaphore;
        private int _released;

        public InFlightGate(SemaphoreSlim semaphore) => _semaphore = semaphore;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _released, 1) == 0)
                _semaphore.Release();
        }
    }
}
