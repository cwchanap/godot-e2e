using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Text.Json;

namespace GodotE2E;

/// <summary>
/// Raw E2E game handle plus the lean wrapper facade (§9.3) and the
/// failure-capturing <see cref="RunAsync"/> (§9.4). Wrappers are thin: build
/// the command, send via <see cref="IE2ECommandSender"/>, map failure through
/// ONE shared mapper (<see cref="RequireSuccess"/>). Commands without a
/// wrapper stay reachable through raw <see cref="SendCommandAsync"/>.
/// </summary>
public sealed class E2EGame : IAsyncDisposable
{
    /// <summary>Depth used for failure-artifact scene-tree capture, mirroring the GDScript parent.</summary>
    private const int SceneTreeDepth = 4;

    private readonly E2EProcess? _process;
    private readonly IE2ECommandSender _sender;

    private E2EGame(E2EProcess process)
    {
        _process = process;
        _sender = process;
    }

    /// <summary>
    /// Sender-only instance for unit tests of the facade; process-backed
    /// members are never touched on these (no real child exists).
    /// </summary>
    internal E2EGame(IE2ECommandSender sender) => _sender = sender;

    public int Pid => Process().Pid;

    /// <summary>Whether the owned child has exited (owned handle, not a name scan).</summary>
    public bool HasExited => Process().HasExited;

    /// <summary>Path of the child's port file; null once cleaned up.</summary>
    public string? PortFile => Process().PortFile;

    internal string StdoutText => _process?.StdoutText ?? string.Empty;
    internal string StderrText => _process?.StderrText ?? string.Empty;
    internal IReadOnlyList<JsonElement> CollectedLogs =>
        _process?.GetCollectedLogs() ?? Array.Empty<JsonElement>();

    private E2EProcess Process() =>
        _process ?? throw new E2EException("This E2EGame has no child process (sender-only instance)");

    public static async Task<E2EGame> LaunchAsync(
        E2ELaunchOptions options,
        CancellationToken cancellationToken = default)
    {
        var process = new E2EProcess();
        // A failed launch has already reaped the child and marked the process
        // disposed, so nothing leaks and no later cleanup can mask the error.
        await process.LaunchAsync(options, cancellationToken);
        return new E2EGame(process);
    }

    public Task<E2EResult> SendCommandAsync(
        string action,
        IReadOnlyDictionary<string, JsonElement>? parameters = null,
        TimeSpan timeout = default,
        CancellationToken cancellationToken = default)
        => _sender.SendCommandAsync(action, parameters, timeout, cancellationToken);

    // ---- Inspection (§9.3) ----

    public async Task<bool> NodeExistsAsync(
        string path, CancellationToken cancellationToken = default)
    {
        var result = RequireSuccess(
            await SendCommandAsync("node_exists", Params(("path", path)), cancellationToken: cancellationToken),
            "node_exists");
        return result.Value.GetProperty("exists").GetBoolean();
    }

    public async Task<T?> GetPropertyAsync<T>(
        string path, string property, CancellationToken cancellationToken = default)
    {
        var result = RequireSuccess(
            await SendCommandAsync(
                "get_property",
                Params(("path", path), ("property", property)),
                cancellationToken: cancellationToken),
            "get_property");
        return E2EJson.Convert<T>(result.Value.GetProperty("result"));
    }

    public Task SetPropertyAsync(
        string path, string property, object? value, CancellationToken cancellationToken = default)
        => SendAndWait(
            "set_property",
            Params(("path", path), ("property", property), ("value", SerializeValue(value))),
            cancellationToken: cancellationToken);

    public async Task<T?> CallMethodAsync<T>(string path, string method, params object?[] args)
    {
        var result = RequireSuccess(
            await SendCommandAsync(
                "call_method",
                Params(
                    ("path", path),
                    ("method", method),
                    ("args", JsonSerializer.SerializeToElement(args.Select(SerializeValue))))),
            "call_method");
        return E2EJson.Convert<T>(result.Value.GetProperty("result"));
    }

    public async Task<string> GetSceneAsync(CancellationToken cancellationToken = default)
    {
        var result = RequireSuccess(
            await SendCommandAsync("get_scene", Params(), cancellationToken: cancellationToken),
            "get_scene");
        return result.Value.GetProperty("scene").GetString() ?? string.Empty;
    }

    // ---- Interaction (§9.3) ----

    public Task InputActionAsync(
        string actionName, bool pressed, double strength = 1.0, CancellationToken cancellationToken = default)
        => SendAndWait(
            "input_action",
            Params(("action_name", actionName), ("pressed", pressed), ("strength", strength)),
            cancellationToken: cancellationToken);

    /// <summary>Presses then releases an input action, mirroring press_action().</summary>
    public async Task PressActionAsync(
        string actionName, double strength = 1.0, CancellationToken cancellationToken = default)
    {
        await InputActionAsync(actionName, pressed: true, strength, cancellationToken);
        await InputActionAsync(actionName, pressed: false, strength, cancellationToken);
    }

    public Task ClickNodeAsync(string path, CancellationToken cancellationToken = default)
        => SendAndWait("click_node", Params(("path", path)), cancellationToken: cancellationToken);

    // ---- Synchronization (§9.3): parameter-scaled transport timeouts ----

    /// <summary>
    /// Waits until the property equals <paramref name="value"/>. The transport
    /// deadline is the caller timeout + 1 s margin (not the transport's fixed
    /// default), so long server-side waits cannot hit the parent timeout
    /// first — mirroring wait_for_property() in the GDScript parent.
    /// </summary>
    public Task WaitForPropertyAsync(
        string path, string property, object? value, double timeoutSeconds = 5.0,
        CancellationToken cancellationToken = default)
        => SendAndWait(
            "wait_for_property",
            Params(
                ("path", path),
                ("property", property),
                ("value", SerializeValue(value)),
                ("timeout", timeoutSeconds)),
            TimeSpan.FromSeconds(timeoutSeconds) + E2EProtocol.WaitMargin,
            cancellationToken);

    /// <summary>Waits for one emission of the signal; returns its raw args.</summary>
    public async Task<IReadOnlyList<JsonElement>> WaitForSignalAsync(
        string path, string signalName, double timeoutSeconds = 5.0,
        CancellationToken cancellationToken = default)
    {
        var result = RequireSuccess(
            await SendCommandAsync(
                "wait_for_signal",
                Params(("path", path), ("signal_name", signalName), ("timeout", timeoutSeconds)),
                TimeSpan.FromSeconds(timeoutSeconds) + E2EProtocol.WaitMargin,
                cancellationToken),
            "wait_for_signal");
        // A successful signal wait answers bare {"ok":true} (no args were
        // captured), so both keys are optional — mirroring the GDScript
        // facade's result/args fallback to [].
        var args = result.Value.TryGetProperty("result", out var named)
            ? named
            : result.Value.TryGetProperty("args", out var positional)
                ? positional
                : (JsonElement?)null;
        return args is { ValueKind: JsonValueKind.Array } array
            ? array.EnumerateArray().Select(a => a.Clone()).ToArray()
            : Array.Empty<JsonElement>();
    }

    // ---- Scene / diagnostic (§9.3) ----

    public Task ReloadSceneAsync(CancellationToken cancellationToken = default)
        => SendAndWait(
            "reload_scene",
            // GDScript sends {} here; explicit margin, like the GDScript parent:
            // reload's server-side wait is the default command timeout + 1 s.
            Params(),
            E2EProtocol.DefaultCommandTimeout + E2EProtocol.WaitMargin,
            cancellationToken);

    public async Task<string> ScreenshotAsync(
        string savePath = "", CancellationToken cancellationToken = default)
    {
        var result = RequireSuccess(
            await SendCommandAsync(
                "screenshot",
                Params(("save_path", savePath)),
                cancellationToken: cancellationToken),
            "screenshot");
        return result.Value.GetProperty("path").GetString() ?? string.Empty;
    }

    /// <summary>
    /// Captures the reachable remote artifacts while the child is still up:
    /// screenshot.png, scene_tree.json, engine_logs.json. Each artifact is
    /// independent best effort; an unreachable child still writes the JSON
    /// defaults so the directory stays deterministic. Process output is
    /// appended by <see cref="RunAsync"/> after teardown.
    /// </summary>
    public async Task CaptureFailureArtifactsAsync(string outputDirectory)
    {
        TryCreateDirectory(outputDirectory);

        // Raw command seam, deliberately: while handling a failure, a failed
        // diagnostic RPC must not be mapped into a thrown wrapper failure.
        // The screenshot file existing on disk is the source of truth, so a
        // stale artifact from an earlier run must not survive a failed capture.
        var screenshotPath = Path.Combine(outputDirectory, "screenshot.png");
        TryDeleteFile(screenshotPath);
        _ = await TrySendAsync(
            "screenshot",
            Params(("save_path", screenshotPath)));

        var tree = JsonDocument.Parse("{}").RootElement.Clone();
        var treeResult = await TrySendAsync(
            "get_tree", Params(("path", "/root"), ("depth", SceneTreeDepth)));
        if (treeResult?.Success == true
            && treeResult.Value.ValueKind == JsonValueKind.Object
            && treeResult.Value.TryGetProperty("tree", out var capturedTree)
            && capturedTree.ValueKind == JsonValueKind.Object)
            tree = capturedTree.Clone();
        WriteJsonBestEffort(Path.Combine(outputDirectory, "scene_tree.json"), tree);

        var logs = JsonSerializer.SerializeToElement(CollectedLogs);
        WriteJsonBestEffort(Path.Combine(outputDirectory, "engine_logs.json"), logs);
    }

    // ---- Failure-capturing runner (§9.4) ----

    public static Task RunAsync(
        E2ELaunchOptions options,
        Func<E2EGame, CancellationToken, Task> body,
        CancellationToken cancellationToken = default,
        [CallerMemberName] string testName = "",
        [CallerFilePath] string callerFilePath = "")
        => RunAsync(options, body, cancellationToken, testName, callerFilePath, BuildFailureDirectory);

    /// <summary>
    /// Internal overload lets tests force the failure-directory construction
    /// to throw, proving capture-side failures never replace the body failure
    /// or skip teardown (§9.4).
    /// </summary>
    internal static async Task RunAsync(
        E2ELaunchOptions options,
        Func<E2EGame, CancellationToken, Task> body,
        CancellationToken cancellationToken,
        string testName,
        string callerFilePath,
        Func<E2ELaunchOptions, string, string, string> buildFailureDirectory)
    {
        // A failed launch has already reaped its child; nothing to clean up.
        var game = await LaunchAsync(options, cancellationToken);

        Exception? bodyFailure = null;
        string? failureDirectory = null;
        try
        {
            await body(game, cancellationToken);
        }
        catch (Exception e)
        {
            bodyFailure = e;
            // Best-effort capture while the child is still reachable: a
            // capture-side throw must never replace the body failure or
            // skip teardown (§9.4).
            try
            {
                failureDirectory = buildFailureDirectory(options, testName, callerFilePath);
                await TryCaptureArtifactsAsync(game, failureDirectory);
            }
            catch (Exception)
            {
                // Best effort only.
            }
        }
        finally
        {
            Exception? cleanupFailure = null;
            try
            {
                await game.DisposeAsync();
            }
            catch (Exception e)
            {
                cleanupFailure = e;
            }

            // Process tails are final only after the child exited.
            if (failureDirectory is not null)
                WriteProcessTails(game, failureDirectory, cleanupFailure);

            if (cleanupFailure is not null)
            {
                // Cleanup failure is secondary diagnostics: parent stderr + the
                // failure artifacts. It must never replace the body failure.
                Console.Error.WriteLine(
                    $"E2E cleanup failed{(bodyFailure is null ? "" : " after an earlier body failure")}: "
                    + $"{cleanupFailure.Message}");
                if (bodyFailure is null)
                    ExceptionDispatchInfo.Capture(cleanupFailure).Throw();
            }
        }

        if (bodyFailure is not null)
            ExceptionDispatchInfo.Capture(bodyFailure).Throw();
    }

    /// <summary>
    /// <c>&lt;resolved project&gt;/test_output/csharp/&lt;caller-file-name&gt;/&lt;testName&gt;/</c>
    /// with safe path components (§9.4, §15).
    /// </summary>
    internal static string BuildFailureDirectory(
        E2ELaunchOptions options, string testName, string callerFilePath)
    {
        var suite = SafePathComponent(Path.GetFileNameWithoutExtension(callerFilePath), "suite");
        var test = SafePathComponent(testName, "test");
        return Path.Combine(
            E2EProcess.ResolveProjectPath(options.ProjectPath),
            "test_output", "csharp", suite, test);
    }

    private static string SafePathComponent(string value, string fallback)
    {
        var normalized = value.Trim();
        if (normalized.Length == 0)
            normalized = fallback;
        foreach (var c in Path.GetInvalidFileNameChars())
            normalized = normalized.Replace(c, '_');
        return normalized.Replace("..", "_");
    }

    private static async Task TryCaptureArtifactsAsync(E2EGame game, string outputDirectory)
    {
        try
        {
            await game.CaptureFailureArtifactsAsync(outputDirectory);
        }
        catch (Exception)
        {
            // Artifact capture is best effort and never replaces the failure.
        }
    }

    private static void WriteProcessTails(E2EGame game, string outputDirectory, Exception? cleanupFailure)
    {
        try
        {
            Directory.CreateDirectory(outputDirectory);
            File.WriteAllText(Path.Combine(outputDirectory, "stdout.log"), game.StdoutText);
            var stderr = game.StderrText;
            if (cleanupFailure is not null)
                // Secondary diagnostic appended where the failure artifacts live.
                stderr += (stderr.Length > 0 ? "\n" : "")
                    + $"E2E cleanup failed after an earlier body failure: {cleanupFailure.Message}";
            File.WriteAllText(Path.Combine(outputDirectory, "stderr.log"), stderr);
        }
        catch (Exception)
        {
            // Best effort only.
        }
    }

    private static void TryCreateDirectory(string path)
    {
        try
        {
            Directory.CreateDirectory(path);
        }
        catch (Exception)
        {
            // Best effort only.
        }
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception)
        {
            // Best effort only.
        }
    }

    private static void WriteJsonBestEffort(string path, JsonElement value)
    {
        try
        {
            File.WriteAllText(path, value.GetRawText());
        }
        catch (Exception)
        {
            // Best effort only.
        }
    }

    private async Task<E2EResult?> TrySendAsync(
        string action,
        IReadOnlyDictionary<string, JsonElement>? parameters = null,
        TimeSpan timeout = default,
        CancellationToken cancellationToken = default)
    {
        try
        {
            return await SendCommandAsync(action, parameters, timeout, cancellationToken);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>The ONE failure mapper for the whole wrapper set (§10).</summary>
    private static E2EResult RequireSuccess(E2EResult result, string action) =>
        result.Success ? result
            : throw new E2EException($"Command '{action}' failed: {result.Message}");

    private async Task SendAndWait(
        string action,
        IReadOnlyDictionary<string, JsonElement>? parameters,
        TimeSpan timeout = default,
        CancellationToken cancellationToken = default)
        => RequireSuccess(
            await SendCommandAsync(action, parameters, timeout, cancellationToken), action);

    private static Dictionary<string, JsonElement> Params(params (string Key, object? Value)[] entries)
    {
        var parameters = new Dictionary<string, JsonElement>();
        foreach (var (key, value) in entries)
            parameters[key] = SerializeValue(value);
        return parameters;
    }

    private static JsonElement SerializeValue(object? value) => value switch
    {
        null => JsonDocument.Parse("null").RootElement.Clone(),
        JsonElement element => element,
        E2EVector2 vector => SerializeVector2(vector),
        _ => JsonSerializer.SerializeToElement(value),
    };

    /// <summary>v2 tagged form, the dual of E2EJson's root conversion.</summary>
    private static JsonElement SerializeVector2(E2EVector2 vector)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("_t", "v2");
            writer.WriteNumber("x", vector.X);
            writer.WriteNumber("y", vector.Y);
            writer.WriteEndObject();
        }
        return JsonDocument.Parse(buffer.ToArray()).RootElement.Clone();
    }

    public ValueTask DisposeAsync()
        => _process?.DisposeAsync() ?? ValueTask.CompletedTask;
}
