using System.Text.Json;
using GdUnit4;
using static GdUnit4.Assertions;

namespace GodotE2E.Tests;

/// <summary>
/// Real-Godot gameplay coverage through the facade against the C# fixture
/// (§16.3): scene/property/method/input/waits, raw expected negative, explicit
/// artifact capture, RunAsync failure capture with deterministic named
/// artifacts, graceful disposal, and body-failure cleanup including the
/// blocked-child force-kill path. Input and screenshot tests launch with a
/// real window, like the GDScript integration suites.
/// </summary>
[TestSuite]
public class GameplaySmokeTest
{
    [TestCase]
    public async Task FacadeDrivesRealFixtureGameplay()
    {
        var game = await E2EGame.LaunchAsync(TestProject.CreateOptions(headless: false));
        try
        {
            // Scene current.
            AssertThat(await game.GetSceneAsync())
                .IsEqual("res://tests/fixtures/csharp/main.tscn");

            // Node existence.
            AssertThat(await game.NodeExistsAsync("/root/Main")).IsTrue();
            AssertThat(await game.NodeExistsAsync("/root/Missing")).IsFalse();

            // Property read/write round-trip.
            AssertThat(await game.GetPropertyAsync<string>("/root/Main", "State")).IsEqual("ready");
            await game.SetPropertyAsync("/root/Main", "State", "written");
            AssertThat(await game.GetPropertyAsync<string>("/root/Main", "State")).IsEqual("written");

            // Method call with return value.
            AssertThat(await game.CallMethodAsync<string>("/root/Main", "Echo", "hello"))
                .IsEqual("hello");

            // Input action: press + release is observable on the fixture.
            await game.PressActionAsync("ui_accept");
            AssertThat(await game.GetPropertyAsync<int>("/root/Main", "ActionCount")).IsEqual(1);
            AssertThat(await game.GetPropertyAsync<bool>("/root/Main", "ActionPressed")).IsFalse();

            // Button click through the facade.
            await game.ClickNodeAsync("/root/Main/Button");
            AssertThat(await game.GetPropertyAsync<string>("/root/Main/ClickStatus", "text"))
                .IsEqual("clicked");

            // Scene reload resets script state.
            await game.ReloadSceneAsync();
            AssertThat(await game.GetPropertyAsync<string>("/root/Main", "State")).IsEqual("ready");

            // Property wait succeeds once the value matches.
            await game.SetPropertyAsync("/root/Main", "State", "final");
            await game.WaitForPropertyAsync("/root/Main", "State", "final", 2);

            // Signal wait: emit is deferred by the fixture, the wait bridges it.
            await game.CallMethodAsync<object>("/root/Main", "TriggerPulse");
            await game.WaitForSignalAsync("/root/Main", "Pulse", 3);

            // Raw expected negative: SendCommandAsync returns E2EResult.
            var negative = await game.SendCommandAsync(
                "get_property",
                new Dictionary<string, JsonElement>
                {
                    ["path"] = JsonSerializer.SerializeToElement("/root/Missing"),
                    ["property"] = JsonSerializer.SerializeToElement("text"),
                });
            AssertThat(negative.Success).IsFalse();
            AssertThat(negative.Message).Contains("Node not found: /root/Missing");
        }
        finally
        {
            await game.DisposeAsync();
        }
        AssertNoSurvivor(game);
    }

    [TestCase]
    public async Task WrappedWaitTimeout_ThrowsE2EException()
    {
        var game = await E2EGame.LaunchAsync(TestProject.CreateOptions(headless: false));
        try
        {
            var error = await CatchAsync(
                () => game.WaitForPropertyAsync("/root/Main", "State", "never-matches", 0.5));

            AssertThat(error).IsInstanceOf<E2EException>();
            AssertThat(error!.Message).Contains("timeout");
        }
        finally
        {
            await game.DisposeAsync();
        }
        AssertNoSurvivor(game);
    }

    [TestCase]
    public async Task ExplicitArtifactCapture_WritesDeterministicRemoteArtifacts()
    {
        var game = await E2EGame.LaunchAsync(TestProject.CreateOptions(headless: false));
        try
        {
            var directory = Path.Combine(
                TestPaths.RepositoryRoot, "test_output", "csharp", "manual", "explicit_capture");
            DeleteDirectory(directory);

            // Handled negative path: the public escape hatch while reachable.
            await game.CaptureFailureArtifactsAsync(directory);

            AssertThat(File.Exists(Path.Combine(directory, "screenshot.png"))).IsTrue();
            var tree = JsonDocument.Parse(
                await File.ReadAllTextAsync(Path.Combine(directory, "scene_tree.json")));
            AssertThat(tree.RootElement.GetProperty("name").GetString()).IsEqual("root");
            JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(directory, "engine_logs.json")));
            // Deterministic names only — nothing timestamped beside them.
            AssertThat(ArtifactFileNames(directory))
                .IsEqual("engine_logs.json,scene_tree.json,screenshot.png");
        }
        finally
        {
            await game.DisposeAsync();
        }
        AssertNoSurvivor(game);
    }

    [TestCase]
    public async Task RunAsync_OnBodyFailure_CapturesAllArtifactsAndRethrowsOriginal()
    {
        var directory = FailureDirectory(nameof(RunAsync_OnBodyFailure_CapturesAllArtifactsAndRethrowsOriginal));
        DeleteDirectory(directory);
        E2EGame? game = null;
        var marker = new InvalidOperationException("body-marker");

        var error = await CatchAsync(() => E2EGame.RunAsync(
            TestProject.CreateOptions(headless: false),
            async (g, _) =>
            {
                game = g;
                await g.SetPropertyAsync("/root/Main", "State", "pre-failure");
                throw marker;
            }));

        // The ORIGINAL body exception (same instance, original stack via EDI).
        AssertThat(error).IsSame(marker);
        AssertNoSurvivor(game!);

        // Deterministic named artifacts: exactly the five §15 files.
        AssertThat(Directory.Exists(directory)).IsTrue();
        AssertThat(ArtifactFileNames(directory))
            .IsEqual("engine_logs.json,scene_tree.json,screenshot.png,stderr.log,stdout.log");
        var tree = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(directory, "scene_tree.json")));
        AssertThat(tree.RootElement.GetProperty("name").GetString()).IsEqual("root");
        // Process tails were appended after teardown.
        AssertThat(File.Exists(Path.Combine(directory, "stdout.log"))).IsTrue();
    }

    [TestCase]
    public async Task RunAsync_OnSuccess_DisposesAndWritesNoArtifacts()
    {
        var directory = FailureDirectory(nameof(RunAsync_OnSuccess_DisposesAndWritesNoArtifacts));
        DeleteDirectory(directory);
        E2EGame? game = null;

        await E2EGame.RunAsync(
            TestProject.CreateOptions(headless: false),
            async (g, _) =>
            {
                game = g;
                await g.SetPropertyAsync("/root/Main", "State", "clean");
            });

        AssertNoSurvivor(game!);
        AssertThat(Directory.Exists(directory)).IsFalse();
    }

    [TestCase]
    public async Task RunAsync_BlockedChild_IsForceKilledAndBodyFailureStaysPrimary()
    {
        var directory = FailureDirectory(nameof(RunAsync_BlockedChild_IsForceKilledAndBodyFailureStaysPrimary));
        DeleteDirectory(directory);
        E2EGame? game = null;
        var marker = new InvalidOperationException("blocked-marker");

        var error = await CatchAsync(() => E2EGame.RunAsync(
            TestProject.CreateOptions(headless: false),
            async (g, _) =>
            {
                game = g;
                // Blocks the child's main thread forever: the graceful quit
                // cannot be processed, so teardown must escalate to Kill(tree).
                var blocked = await CatchAsync(() => g.SendCommandAsync(
                    "call_method",
                    new Dictionary<string, JsonElement>
                    {
                        ["path"] = JsonSerializer.SerializeToElement("/root/Main"),
                        ["method"] = JsonSerializer.SerializeToElement("BlockMainThread"),
                        ["args"] = JsonSerializer.SerializeToElement(Array.Empty<object>()),
                    },
                    TimeSpan.FromSeconds(2)));
                AssertThat(blocked).IsInstanceOf<E2EException>();
                throw marker;
            }));

        AssertThat(error).IsSame(marker);
        // The blocked child was force-killed and its death confirmed.
        AssertNoSurvivor(game!);
        // Best-effort artifacts were still written even though the blocked
        // child could not answer the diagnostic RPCs.
        AssertThat(File.Exists(Path.Combine(directory, "scene_tree.json"))).IsTrue();
        AssertThat(File.Exists(Path.Combine(directory, "stderr.log"))).IsTrue();
    }

    // ---- helpers ----

    /// <summary>The §9.4 default failure directory RunAsync derives from
    /// caller metadata: test_output/csharp/&lt;suite&gt;/&lt;test&gt;.</summary>
    private static string FailureDirectory(string testName) => Path.Combine(
        TestPaths.RepositoryRoot, "test_output", "csharp", nameof(GameplaySmokeTest), testName);

    private static string ArtifactFileNames(string directory) =>
        string.Join(",", Directory.GetFiles(directory).Select(Path.GetFileName).OrderBy(n => n));

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

    private static void DeleteDirectory(string path)
    {
        if (Directory.Exists(path))
            Directory.Delete(path, recursive: true);
    }

    private static void AssertNoSurvivor(E2EGame game) =>
        AssertThat(game.HasExited).IsTrue();
}
