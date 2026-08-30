using System.Text.Json;
using GdUnit4;
using static GdUnit4.Assertions;

namespace GodotE2E.Tests;

/// <summary>
/// Real-launch lifecycle coverage: launch + port discovery + hello, raw
/// commands against the C# fixture, graceful disposal, and force-kill of a
/// blocked child. Every test ends by confirming its own child is dead via the
/// owned process handle (no name scans).
/// </summary>
[TestSuite]
public class ProcessLifecycleTest
{
    [TestCase]
    public async Task Launch_ConnectsViaPortFileAndHello()
    {
        var game = await E2EGame.LaunchAsync(TestProject.CreateOptions());
        try
        {
            AssertThat(game.Pid).IsGreater(0);
            // The port file is the discovery mechanism and lives in a
            // per-launch temp directory that cleanup must remove.
            AssertThat(game.PortFile).IsNotNull();
            AssertThat(File.Exists(game.PortFile!)).IsTrue();
            AssertThat(Directory.Exists(Path.GetDirectoryName(game.PortFile!)!)).IsTrue();
        }
        finally
        {
            await game.DisposeAsync();
        }
        AssertNoSurvivor(game);
    }

    [TestCase]
    public async Task RawNodeExists_OnCsharpFixtureScene()
    {
        var game = await E2EGame.LaunchAsync(TestProject.CreateOptions());
        try
        {
            var present = await game.SendCommandAsync("node_exists", NodePath("Main"));
            AssertThat(present.Success).IsTrue();
            AssertThat(present.Value.GetProperty("exists").GetBoolean()).IsTrue();

            var absent = await game.SendCommandAsync("node_exists", NodePath("Missing"));
            AssertThat(absent.Success).IsTrue();
            AssertThat(absent.Value.GetProperty("exists").GetBoolean()).IsFalse();
        }
        finally
        {
            await game.DisposeAsync();
        }
        AssertNoSurvivor(game);
    }

    [TestCase]
    public async Task GracefulDispose_ChildExitsAndTempFilesCleaned()
    {
        var game = await E2EGame.LaunchAsync(TestProject.CreateOptions());
        var portFile = game.PortFile!;
        var tempDir = Path.GetDirectoryName(portFile)!;

        await game.DisposeAsync();

        AssertNoSurvivor(game);
        AssertThat(File.Exists(portFile)).IsFalse();
        AssertThat(Directory.Exists(tempDir)).IsFalse();
    }

    [TestCase]
    public async Task PidIsDeadAfterDispose()
    {
        var game = await E2EGame.LaunchAsync(TestProject.CreateOptions());
        var pid = game.Pid;
        AssertThat(pid).IsGreater(0);

        await game.DisposeAsync();

        // Confirmed through the owned process handle, not a name scan.
        AssertNoSurvivor(game);
    }

    [TestCase]
    public async Task BlockedChild_IsForceKilledWhenGracefulQuitTimesOut()
    {
        var game = await E2EGame.LaunchAsync(TestProject.CreateOptions());
        try
        {
            // Blocks the child's main thread forever, so the graceful quit can
            // never be processed and dispose must escalate to Kill(tree).
            var error = await CatchAsync(() => game.SendCommandAsync(
                "call_method",
                Call("Main", "BlockMainThread"),
                TimeSpan.FromSeconds(2)));
            AssertThat(error).IsInstanceOf<E2EException>();
        }
        finally
        {
            await game.DisposeAsync();
        }
        AssertNoSurvivor(game);
    }

    [TestCase]
    public async Task Launch_CallerCancellationIsPreservedAndChildIsReaped()
    {
        // Caller cancellation during launch (port-file polling, connect, or
        // hello) must be preserved as OperationCanceledException — mirroring
        // the in-flight command/body path (E2EClient.ConnectAsync/SendCoreAsync
        // rethrow caller cancellation) — so E2EGame.LaunchAsync/RunAsync can
        // distinguish cancellation from a launch failure instead of seeing an
        // E2EException("Godot child launch was cancelled"). A pre-canceled
        // token throws from the port-file polling loop right after the child
        // starts, exercising the launch catch's reap-then-rethrow path.
        var process = new E2EProcess();
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var error = await CatchAsync(() => process.LaunchAsync(TestProject.CreateOptions(), cts.Token));

        // Cancellation is preserved, not wrapped as an E2EException launch failure.
        AssertThat(error).IsInstanceOf<OperationCanceledException>();
        // The child was reaped before the rethrow; the owned handle confirms death.
        AssertThat(process.HasExited).IsTrue();
    }

    [TestCase]
    public async Task RelaunchOfLiveInstance_ThrowsAndKeepsFirstChild()
    {
        var process = new E2EProcess();
        await process.LaunchAsync(TestProject.CreateOptions());
        try
        {
            var firstPid = process.Pid;

            var error = await CatchAsync(() => process.LaunchAsync(TestProject.CreateOptions()));

            // The guard fires before any second child is started and the
            // first child is neither orphaned nor replaced.
            AssertThat(error).IsInstanceOf<E2EException>();
            AssertThat(process.Pid).IsEqual(firstPid);
            AssertThat(process.HasExited).IsFalse();
        }
        finally
        {
            await process.DisposeAsync();
        }
        AssertThat(process.HasExited).IsTrue();
    }

    // ---- helpers ----

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

    private static Dictionary<string, JsonElement> NodePath(string nodePath) => new()
    {
        ["path"] = JsonSerializer.SerializeToElement(nodePath),
    };

    private static Dictionary<string, JsonElement> Call(string nodePath, string method) => new()
    {
        ["path"] = JsonSerializer.SerializeToElement(nodePath),
        ["method"] = JsonSerializer.SerializeToElement(method),
        ["args"] = JsonSerializer.SerializeToElement(Array.Empty<object>()),
    };

    private static void AssertNoSurvivor(E2EGame game) =>
        AssertThat(game.HasExited).IsTrue();
}
