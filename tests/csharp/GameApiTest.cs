using System.Text.Json;
using GdUnit4;
using static GdUnit4.Assertions;

namespace GodotE2E.Tests;

/// <summary>
/// Unit-level facade coverage through a recording command sender: exact
/// command names, payloads, parameter-scaled transport timeouts, and the one
/// shared failure mapper. No real Godot here (§16.2); real-server behavior is
/// covered by GameplaySmokeTest.
/// </summary>
[TestSuite]
public class GameApiTest
{
    [TestCase]
    public async Task NodeExistsAsync_SendsPathAndReturnsExists()
    {
        var sender = NewSender(Result("""{"exists": true}"""));
        var game = new E2EGame(sender);

        var exists = await game.NodeExistsAsync("/root/Main");

        AssertThat(exists).IsTrue();
        AssertCommand(sender, "node_exists", p =>
        {
            AssertThat(p["path"].GetString()).IsEqual("/root/Main");
        });
    }

    [TestCase]
    public async Task GetPropertyAsync_SendsPathPropertyAndConvertsResult()
    {
        var sender = NewSender(Result("""{"result": "state1"}"""));
        var game = new E2EGame(sender);

        var value = await game.GetPropertyAsync<string>("/root/Main", "State");

        AssertThat(value).IsEqual("state1");
        AssertCommand(sender, "get_property", p =>
        {
            AssertThat(p["path"].GetString()).IsEqual("/root/Main");
            AssertThat(p["property"].GetString()).IsEqual("State");
        });
    }

    [TestCase]
    public async Task GetPropertyAsync_ConvertsTaggedVectorResult()
    {
        var sender = NewSender(Result("""{"result": {"_t": "v2", "x": 3.5, "y": -1}}"""));
        var game = new E2EGame(sender);

        var value = await game.GetPropertyAsync<E2EVector2>("/root/Main", "position");

        AssertThat(value.X).IsEqual(3.5);
        AssertThat(value.Y).IsEqual(-1);
    }

    [TestCase]
    public async Task SetPropertyAsync_SendsPathPropertyValue()
    {
        var sender = NewSender(Result("""{"ok": true}"""));
        var game = new E2EGame(sender);

        await game.SetPropertyAsync("/root/Main", "State", "hello");

        AssertCommand(sender, "set_property", p =>
        {
            AssertThat(p["path"].GetString()).IsEqual("/root/Main");
            AssertThat(p["property"].GetString()).IsEqual("State");
            AssertThat(p["value"].GetString()).IsEqual("hello");
        });
    }

    [TestCase]
    public async Task CallMethodAsync_SendsPathMethodArgs()
    {
        var sender = NewSender(Result("""{"result": "echoed"}"""));
        var game = new E2EGame(sender);

        var value = await game.CallMethodAsync<string>("/root/Main", "Echo", "echoed");

        AssertThat(value).IsEqual("echoed");
        AssertCommand(sender, "call_method", p =>
        {
            AssertThat(p["path"].GetString()).IsEqual("/root/Main");
            AssertThat(p["method"].GetString()).IsEqual("Echo");
            AssertThat(p["args"].GetArrayLength()).IsEqual(1);
            AssertThat(p["args"][0].GetString()).IsEqual("echoed");
        });
    }

    [TestCase]
    public async Task GetSceneAsync_ReturnsScenePath()
    {
        var sender = NewSender(Result("""{"scene": "res://tests/fixtures/csharp/main.tscn"}"""));
        var game = new E2EGame(sender);

        var scene = await game.GetSceneAsync();

        AssertThat(scene).IsEqual("res://tests/fixtures/csharp/main.tscn");
        AssertCommand(sender, "get_scene", _ => { });
    }

    [TestCase]
    public async Task InputActionAsync_SendsActionPressedStrength()
    {
        var sender = NewSender(Result("""{"ok": true}"""));
        var game = new E2EGame(sender);

        await game.InputActionAsync("ui_accept", pressed: true, strength: 0.5);

        AssertCommand(sender, "input_action", p =>
        {
            AssertThat(p["action_name"].GetString()).IsEqual("ui_accept");
            AssertThat(p["pressed"].GetBoolean()).IsTrue();
            AssertThat(p["strength"].GetDouble()).IsEqual(0.5);
        });
    }

    [TestCase]
    public async Task PressActionAsync_SendsPressThenRelease()
    {
        var sender = NewSender(Result("""{"ok": true}"""));
        var game = new E2EGame(sender);

        await game.PressActionAsync("ui_accept");

        AssertThat(sender.Sent).HasSize(2);
        AssertThat(sender.Sent[0].Action).IsEqual("input_action");
        AssertThat(sender.Sent[0].Parameters!["pressed"].GetBoolean()).IsTrue();
        AssertThat(sender.Sent[1].Action).IsEqual("input_action");
        AssertThat(sender.Sent[1].Parameters!["pressed"].GetBoolean()).IsFalse();
    }

    [TestCase]
    public async Task ClickNodeAsync_SendsPath()
    {
        var sender = NewSender(Result("""{"ok": true}"""));
        var game = new E2EGame(sender);

        await game.ClickNodeAsync("/root/Main/Button");

        AssertCommand(sender, "click_node", p =>
        {
            AssertThat(p["path"].GetString()).IsEqual("/root/Main/Button");
        });
    }

    [TestCase]
    public async Task WaitForPropertyAsync_ScalesTransportTimeoutByOneSecond()
    {
        var sender = NewSender(Result("""{"ok": true}"""));
        var game = new E2EGame(sender);

        await game.WaitForPropertyAsync("/root/Main", "State", "done", 2.5);

        var command = AssertCommand(sender, "wait_for_property", p =>
        {
            AssertThat(p["path"].GetString()).IsEqual("/root/Main");
            AssertThat(p["property"].GetString()).IsEqual("State");
            AssertThat(p["value"].GetString()).IsEqual("done");
            // The server keeps polling for the caller timeout, not the margin.
            AssertThat(p["timeout"].GetDouble()).IsEqual(2.5);
        });
        AssertThat(command.Timeout).IsEqual(TimeSpan.FromSeconds(3.5));
    }

    [TestCase]
    public async Task WaitForPropertyAsync_LargeCallerTimeoutExceedsTheFixedTransportDefault()
    {
        var sender = NewSender(Result("""{"ok": true}"""));
        var game = new E2EGame(sender);

        // A long caller wait must NOT be capped at the transport's fixed
        // default+margin (6 s): the margin scales with the caller timeout.
        await game.WaitForPropertyAsync("/root/Main", "State", "done", 20);

        AssertThat(sender.Sent[0].Timeout).IsEqual(TimeSpan.FromSeconds(21));
    }

    [TestCase]
    public async Task WaitForSignalAsync_ScalesTransportTimeoutByOneSecond()
    {
        var sender = NewSender(Result("""{"result": [1, 2]}"""));
        var game = new E2EGame(sender);

        var args = await game.WaitForSignalAsync("/root/Main", "Pulse", 3);

        AssertThat(args).HasSize(2);
        AssertThat(args[0].GetInt32()).IsEqual(1);
        var command = AssertCommand(sender, "wait_for_signal", p =>
        {
            AssertThat(p["path"].GetString()).IsEqual("/root/Main");
            AssertThat(p["signal_name"].GetString()).IsEqual("Pulse");
            AssertThat(p["timeout"].GetDouble()).IsEqual(3);
        });
        AssertThat(command.Timeout).IsEqual(TimeSpan.FromSeconds(4));
    }

    [TestCase]
    public async Task ReloadSceneAsync_UsesDefaultCommandTimeoutPlusMargin()
    {
        var sender = NewSender(Result("""{"ok": true}"""));
        var game = new E2EGame(sender);

        await game.ReloadSceneAsync();

        var command = AssertCommand(sender, "reload_scene", _ => { });
        AssertThat(command.Timeout)
            .IsEqual(E2EProtocol.DefaultCommandTimeout + E2EProtocol.WaitMargin);
    }

    [TestCase]
    public async Task ScreenshotAsync_SendsSavePathAndReturnsServerPath()
    {
        var sender = NewSender(Result("""{"path": "/tmp/artifacts/screenshot.png"}"""));
        var game = new E2EGame(sender);

        var path = await game.ScreenshotAsync("/tmp/artifacts/screenshot.png");

        AssertThat(path).IsEqual("/tmp/artifacts/screenshot.png");
        AssertCommand(sender, "screenshot", p =>
        {
            AssertThat(p["save_path"].GetString()).IsEqual("/tmp/artifacts/screenshot.png");
        });
    }

    [TestCase]
    public async Task WrappedRemoteFailure_ThrowsE2EExceptionWithRenderedError()
    {
        // One shared failure mapper backs the whole wrapper set (§10).
        var sender = NewSender(Failure("node_not_found", "Node not found: /root/Missing"));
        var game = new E2EGame(sender);

        var error = await CatchAsync(() => game.NodeExistsAsync("/root/Missing"));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).Contains("node_not_found: Node not found: /root/Missing");
    }

    [TestCase]
    public async Task WrappedRemoteFailureOnWait_ThrowsE2EException()
    {
        var sender = NewSender(Failure("timeout", "Timed out waiting for property"));
        var game = new E2EGame(sender);

        var error = await CatchAsync(() => game.WaitForPropertyAsync("/root/Main", "State", "x", 1));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).Contains("Timed out waiting for property");
    }

    // ---- helpers ----

    private static RecordingSender NewSender(E2EResult response) => new(response);

    private static SentCommand AssertCommand(
        RecordingSender sender, string action, Action<IReadOnlyDictionary<string, JsonElement>> assertParameters)
    {
        AssertThat(sender.Sent).HasSize(1);
        var command = sender.Sent[0];
        AssertThat(command.Action).IsEqual(action);
        // gdUnit4 cannot render JsonElement dictionaries; a plain throw keeps
        // the failure message about the actual problem (null parameters).
        ArgumentNullException.ThrowIfNull(command.Parameters);
        assertParameters(command.Parameters);
        return command;
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

    private static E2EResult Result(string json) => new()
    {
        Success = true,
        Value = JsonDocument.Parse(json).RootElement.Clone(),
    };

    private static E2EResult Failure(string error, string message) => new()
    {
        Success = false,
        Message = $"{error}: {message}",
    };

    internal sealed record SentCommand(
        string Action,
        IReadOnlyDictionary<string, JsonElement>? Parameters,
        TimeSpan Timeout);

    internal sealed class RecordingSender(E2EResult response) : IE2ECommandSender
    {
        public List<SentCommand> Sent { get; } = [];

        public Task<E2EResult> SendCommandAsync(
            string action,
            IReadOnlyDictionary<string, JsonElement>? parameters = null,
            TimeSpan timeout = default,
            CancellationToken cancellationToken = default)
        {
            Sent.Add(new SentCommand(action, parameters, timeout));
            return Task.FromResult(response);
        }
    }
}
