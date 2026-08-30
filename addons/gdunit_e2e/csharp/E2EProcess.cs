using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace GodotE2E;

/// <summary>
/// Owns ONE Godot child process and ONE <see cref="E2EClient"/>. Launches the
/// child with the protocol argv, continuously drains both output pipes into
/// bounded tails, polls for the child's port file, connects, and performs the
/// protocol-v1 hello. Shutdown: best-effort quit, bounded graceful wait,
/// whole-tree kill, bounded confirmation, temp cleanup — strict on unconfirmed
/// child death. Mirrors e2e_process.gd.
/// </summary>
public sealed class E2EProcess : IE2ECommandSender, IAsyncDisposable
{
    private const int PollIntervalMillis = 25;    // e2e_process.gd POLL_INTERVAL_MILLIS
    private const int ShutdownGraceMillis = 1000; // e2e_process.gd SHUTDOWN_GRACE_MILLIS
    private const int PipeDrainMillis = 500;      // e2e_process.gd PIPE_DRAIN_MILLIS
    private const int QuitTimeoutMillis = 500;

    private Process? _child;
    private E2EClient? _client;
    private string? _portFile;
    private string? _tempDir;
    private bool _authenticated;
    private PipeTail _stdoutTail = new();
    private PipeTail _stderrTail = new();
    private Task? _stdoutDrain;
    private Task? _stderrDrain;
    private CancellationTokenSource? _drainCts;
    private int _disposed;

    public int Pid => _child?.Id ?? -1;

    /// <summary>Whether the owned child process has exited (owned handle, not a name scan).</summary>
    public bool HasExited
    {
        get
        {
            var child = _child;
            if (child is null)
                return true;
            try
            {
                return child.HasExited;
            }
            catch (InvalidOperationException)
            {
                return true;
            }
        }
    }

    public string? PortFile => _portFile;
    public string StdoutText => _stdoutTail.ToString();
    public string StderrText => _stderrTail.ToString();

    public IReadOnlyList<JsonElement> GetCollectedLogs() =>
        _client?.GetCollectedLogs() ?? Array.Empty<JsonElement>();

    public async Task LaunchAsync(E2ELaunchOptions options, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        if (string.IsNullOrEmpty(options.ScenePath))
            throw new E2EException("E2ELaunchOptions.ScenePath is required");
        // e2e_process.gd closes a live instance before relaunching; our
        // shutdown is terminal (DisposeAsync), so a relaunch of a live
        // instance fails loud instead of orphaning the first child.
        if (_child is not null || _client is not null)
            throw new E2EException(
                "E2EProcess already owns a launched child; dispose it before launching again");

        var projectPath = ResolveProjectPath(options.ProjectPath);
        var godotPath = ResolveGodotPath(options.GodotPath);
        var timeout = options.Timeout <= TimeSpan.Zero ? TimeSpan.FromSeconds(1) : options.Timeout;
        var token = NewToken();
        _tempDir = Path.Combine(Path.GetTempPath(), "gdunit_e2e_" + token);
        Directory.CreateDirectory(_tempDir);
        _portFile = Path.Combine(_tempDir, "port_" + token + ".txt");
        _stdoutTail = new PipeTail();
        _stderrTail = new PipeTail();

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = godotPath,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var argument in BuildArguments(options, projectPath, _portFile, token))
                startInfo.ArgumentList.Add(argument);

            _child = Process.Start(startInfo);
            if (_child is null)
                throw new E2EException("Failed to launch Godot child");

            // Drains start immediately: a full OS pipe buffer would block the
            // child before it can write its port file.
            _drainCts = new CancellationTokenSource();
            _stdoutDrain = DrainAsync(_child.StandardOutput.BaseStream, _stdoutTail, _drainCts.Token);
            _stderrDrain = DrainAsync(_child.StandardError.BaseStream, _stderrTail, _drainCts.Token);

            var port = 0;
            // Monotonic start timestamp (mirrors e2e_process.gd's
            // Time.get_ticks_msec); DateTime.UtcNow is a wall clock that NTP or
            // a manual adjustment can shift during the port-file wait.
            var startTimestamp = Stopwatch.GetTimestamp();
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (_child.HasExited)
                    throw new E2EException(
                        $"Godot child exited before writing its port file (exit {_child.ExitCode})");
                if (TryReadPortFile(_portFile, out port))
                    break;
                if (Stopwatch.GetElapsedTime(startTimestamp) >= timeout)
                    throw new E2EException(
                        $"Timed out waiting for the child E2E server port file after {(int)timeout.TotalMilliseconds} ms");
                await Task.Delay(PollIntervalMillis, cancellationToken);
            }

            // The configured launch timeout bounds the WHOLE launch (port-file
            // wait + hello). The polling loop above already consumed up to it,
            // so pass the remaining budget into ConnectAsync — never a fresh
            // full timeout, which could run ~2x configured before failing.
            // ConnectAsync treats TimeSpan.Zero as "use default", so a non-positive
            // remainder must fail here rather than restart the clock.
            var remaining = timeout - Stopwatch.GetElapsedTime(startTimestamp);
            if (remaining <= TimeSpan.Zero)
                throw new E2EException(
                    $"Child E2E launch timed out after {(int)timeout.TotalMilliseconds} ms (no budget left for handshake)");
            _client = new E2EClient();
            var hello = await _client.ConnectAsync(port, token, remaining, cancellationToken);
            if (!hello.Success)
                throw new E2EException($"Child E2E handshake failed: {hello.Message}");
            _authenticated = true;
        }
        catch (Exception e)
        {
            // Reap the child and include the drained output in the failure.
            // Already disposed so a later DisposeAsync cannot mask this failure.
            Interlocked.Exchange(ref _disposed, 1);
            await ShutdownAsync(throwOnUnconfirmedDeath: false);
            // Caller cancellation during launch (port-file polling, connect,
            // or hello) is preserved as OperationCanceledException, mirroring
            // the in-flight command/body path: E2EClient.ConnectAsync and
            // SendCoreAsync rethrow caller cancellation while converting
            // timeout cancellation to E2EException, and the port-file loop
            // above uses a manual Stopwatch check (no linked timeout CTS), so
            // an OperationCanceledException reaching here is genuinely caller
            // cancellation — not a timeout. Rethrow it so E2EGame.LaunchAsync
            // /RunAsync can distinguish cancellation from a launch failure;
            // the child is already reaped above.
            if (e is OperationCanceledException)
                throw;
            var message = e switch
            {
                E2EException failure => failure.Message,
                _ => $"Failed to launch Godot child: {e.GetType().Name}: {e.Message}",
            };
            throw new E2EException(message + TailDiagnostics(), e);
        }
    }

    public async Task<E2EResult> SendCommandAsync(
        string action,
        IReadOnlyDictionary<string, JsonElement>? parameters = null,
        TimeSpan timeout = default,
        CancellationToken cancellationToken = default)
    {
        var client = _client;
        if (client is null)
            throw new E2EException("E2E session is not open");
        return await client.SendCommandAsync(action, parameters, timeout, cancellationToken);
    }

    internal static List<string> BuildArguments(
        E2ELaunchOptions options, string projectPath, string portFile, string token)
    {
        var args = new List<string>
        {
            "--path",
            projectPath,
            "--scene",
            options.BootstrapScenePath,
        };
        foreach (var extra in options.ExtraGodotArgs)
            args.Add(extra);
        args.Add("--");
        args.Add("--gdunit-e2e");
        args.Add("--gdunit-e2e-target-scene=" + options.ScenePath);
        args.Add($"--gdunit-e2e-port={options.ServerPort}");
        args.Add("--gdunit-e2e-port-file=" + portFile);
        args.Add("--gdunit-e2e-token=" + token);
        args.Add("--gdunit-e2e-log-verbosity=" + options.LogVerbosity);
        return args;
    }

    internal static string ResolveProjectPath(string? projectPath)
    {
        if (!string.IsNullOrEmpty(projectPath))
            return projectPath;
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            for (var dir = new DirectoryInfo(start); dir is not null; dir = dir.Parent)
            {
                if (File.Exists(Path.Combine(dir.FullName, "project.godot")))
                    return dir.FullName;
            }
        }
        throw new E2EException(
            "Could not locate a Godot project: no 'project.godot' found walking upward from the current directory. "
            + "Set E2ELaunchOptions.ProjectPath explicitly.");
    }

    internal static string ResolveGodotPath(string? godotPath)
    {
        if (!string.IsNullOrEmpty(godotPath))
            return godotPath;
        var fromEnvironment = Environment.GetEnvironmentVariable("GODOT_BIN");
        return string.IsNullOrEmpty(fromEnvironment) ? "godot" : fromEnvironment;
    }

    private static string NewToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(16));

    private static bool TryReadPortFile(string path, out int port)
    {
        port = 0;
        try
        {
            if (!File.Exists(path))
                return false;
            if (!int.TryParse(File.ReadAllText(path).Trim(), out var parsed))
                return false;
            if (parsed <= 0 || parsed > 65535)
                return false;
            port = parsed;
            return true;
        }
        catch (IOException)
        {
            // Torn or concurrently-flushed read: the next poll retries.
            return false;
        }
    }

    private static async Task DrainAsync(Stream stream, PipeTail tail, CancellationToken cancellationToken)
    {
        var buffer = new byte[8192];
        try
        {
            while (true)
            {
                var read = await stream.ReadAsync(buffer, cancellationToken);
                if (read <= 0)
                    break;
                tail.Append(buffer.AsSpan(0, read));
            }
        }
        catch (Exception e) when (e is OperationCanceledException or IOException or ObjectDisposedException)
        {
            // Pipe torn down by shutdown or child death; diagnostics only.
        }
    }

    private string TailDiagnostics()
    {
        var stdout = StdoutText;
        var stderr = StderrText;
        var diagnostics = string.Empty;
        if (stdout.Length > 0)
            diagnostics += $"\n--- child stdout ---\n{stdout}";
        if (stderr.Length > 0)
            diagnostics += $"\n--- child stderr ---\n{stderr}";
        return diagnostics;
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
            return;
        await ShutdownAsync(throwOnUnconfirmedDeath: true);
    }

    /// <summary>
    /// The full shutdown path: best-effort quit when authenticated, close the
    /// client, bounded graceful wait, whole-tree kill, bounded confirmation,
    /// finish drains, delete temp files. Strict mode throws when child death
    /// cannot be confirmed; launch-failure mode never throws.
    /// </summary>
    private async Task ShutdownAsync(bool throwOnUnconfirmedDeath)
    {
        var client = Interlocked.Exchange(ref _client, null);
        if (client is not null)
        {
            if (_authenticated)
            {
                // Quit is best effort: the child may die before its response
                // is observed; the bounded reap below is the source of truth.
                try
                {
                    await client.SendCommandAsync(
                        "quit",
                        timeout: TimeSpan.FromMilliseconds(QuitTimeoutMillis));
                }
                catch (Exception)
                {
                    // Ignored: quit is advisory.
                }
            }
            await client.DisposeAsync();
        }
        _authenticated = false;

        var child = _child;
        if (child is not null)
        {
            if (!await WaitForDeathAsync(child, ShutdownGraceMillis))
            {
                TryKillTree(child);
                if (!await WaitForDeathAsync(child, ShutdownGraceMillis))
                {
                    if (throwOnUnconfirmedDeath)
                        throw new E2EException($"Unable to confirm Godot child PID {child.Id} exited.{TailDiagnostics()}");
                    return; // Launch-failure mode: skip cleanup of still-running state.
                }
            }
        }

        await FinishDrainsAsync();
        CleanupTempFiles();
    }

    private static async Task<bool> WaitForDeathAsync(Process child, int millis)
    {
        try
        {
            if (child.HasExited)
                return true;
            using var cts = new CancellationTokenSource(millis);
            await child.WaitForExitAsync(cts.Token);
            return true;
        }
        catch (OperationCanceledException)
        {
            return child.HasExited;
        }
        catch (InvalidOperationException)
        {
            return true;
        }
    }

    private static void TryKillTree(Process child)
    {
        try
        {
            child.Kill(entireProcessTree: true);
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // Raced an exit; death confirmation below is the source of truth.
        }
    }

    private async Task FinishDrainsAsync()
    {
        var drains = new[] { _stdoutDrain, _stderrDrain };
        _stdoutDrain = null;
        _stderrDrain = null;
        try
        {
            var pending = drains.Where(t => t is not null).Select(t => t!).ToArray();
            if (pending.Length > 0)
                await Task.WhenAny(Task.WhenAll(pending), Task.Delay(PipeDrainMillis));
        }
        finally
        {
            _drainCts?.Cancel();
            _drainCts?.Dispose();
            _drainCts = null;
            _child?.Dispose();
            _child = null;
        }
    }

    private void CleanupTempFiles()
    {
        try
        {
            if (_portFile is not null && File.Exists(_portFile))
                File.Delete(_portFile);
            if (_tempDir is not null && Directory.Exists(_tempDir))
                Directory.Delete(_tempDir, recursive: true);
        }
        catch (IOException)
        {
            // Best effort only.
        }
        _portFile = null;
        _tempDir = null;
    }
}
