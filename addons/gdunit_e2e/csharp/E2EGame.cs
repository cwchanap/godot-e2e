using System.Text.Json;

namespace GodotE2E;

/// <summary>
/// Raw E2E game handle: owns one <see cref="E2EProcess"/> and exposes launch,
/// raw command sending, and lifecycle facts for tests. Higher-level wrappers
/// and the failure-capturing RunAsync arrive in a later task. Mirrors
/// gdunit_e2e_game.gd's ownership shape.
/// </summary>
public sealed class E2EGame : IAsyncDisposable
{
    private readonly E2EProcess _process;

    private E2EGame(E2EProcess process) => _process = process;

    public int Pid => _process.Pid;

    /// <summary>Whether the owned child has exited (owned handle, not a name scan).</summary>
    public bool HasExited => _process.HasExited;

    /// <summary>Path of the child's port file; null once cleaned up.</summary>
    public string? PortFile => _process.PortFile;

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
        => _process.SendCommandAsync(action, parameters, timeout, cancellationToken);

    public ValueTask DisposeAsync() => _process.DisposeAsync();
}
