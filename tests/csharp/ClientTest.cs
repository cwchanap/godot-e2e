using System.Diagnostics;
using System.Text.Json;
using GdUnit4;
using static GdUnit4.Assertions;

namespace GodotE2E.Tests;

[TestSuite]
public class ClientTest
{
    private static readonly Func<JsonElement, Task<JsonElement?>> EchoOnly =
        command => Task.FromResult<JsonElement?>(FakeProtocolServer.Echo(command));

    // ---- Hello handshake ----

    [TestCase]
    public async Task Connect_SendsHelloFirstWithTokenAndProtocolVersion()
    {
        await using var fake = FakeProtocolServer.Start();
        await using var client = new E2EClient();

        var result = await client.ConnectAsync(fake.Port, "secret-token");

        AssertThat(result.Success).IsTrue();
        AssertThat(fake.Received).HasSize(1);
        var hello = fake.Received[0];
        AssertThat(hello.GetProperty("action").GetString()).IsEqual("hello");
        AssertThat(hello.GetProperty("token").GetString()).IsEqual("secret-token");
        AssertThat(hello.GetProperty("protocol_version").GetInt32())
            .IsEqual(E2EProtocol.ProtocolVersion);
        AssertThat(hello.GetProperty("id").GetInt32()).IsEqual(1);
    }

    [TestCase]
    public async Task Connect_HelloErrorResponseFailsAndClosesSession()
    {
        await using var fake = FakeProtocolServer.Start(_ => Task.FromResult<JsonElement?>(
            FakeProtocolServer.Json(@"{""error"":""invalid token""}")));
        await using var client = new E2EClient();

        var result = await client.ConnectAsync(fake.Port, "wrong-token");

        AssertThat(result.Success).IsFalse();
        AssertThat(result.Message).IsEqual("invalid token");
        var error = await CatchAsync(() => client.SendCommandAsync("get_property"));
        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual("E2E session is not open");
    }

    // ---- Command IDs ----

    [TestCase]
    public async Task Command_IdsIncreaseMonotonically()
    {
        await using var fake = FakeProtocolServer.Start();
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        var first = await client.SendCommandAsync("ping");
        var second = await client.SendCommandAsync("ping");
        var third = await client.SendCommandAsync("ping");

        AssertThat(first.Success).IsTrue();
        AssertThat(second.Success).IsTrue();
        AssertThat(third.Success).IsTrue();
        AssertThat(fake.Received).HasSize(4);
        AssertThat(fake.Received[1].GetProperty("id").GetInt32()).IsEqual(2);
        AssertThat(fake.Received[2].GetProperty("id").GetInt32()).IsEqual(3);
        AssertThat(fake.Received[3].GetProperty("id").GetInt32()).IsEqual(4);
    }

    [TestCase]
    public async Task Command_ParametersMergeIntoCommandObject()
    {
        await using var fake = FakeProtocolServer.Start();
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        await client.SendCommandAsync("get_property", new Dictionary<string, JsonElement>
        {
            ["path"] = FakeProtocolServer.Json("\"/root/Main\""),
            ["quiet"] = FakeProtocolServer.Json("true"),
        });

        var command = fake.Received[1];
        AssertThat(command.GetProperty("action").GetString()).IsEqual("get_property");
        AssertThat(command.GetProperty("path").GetString()).IsEqual("/root/Main");
        AssertThat(command.GetProperty("quiet").GetBoolean()).IsTrue();
    }

    // ---- Response, logs, and error parsing ----

    [TestCase]
    public async Task Command_ValueIsResponseWithoutLogKeysAndLogsAreReturned()
    {
        await using var fake = FakeProtocolServer.Start(async command =>
        {
            if (command.GetProperty("action").GetString() != "logged")
                return FakeProtocolServer.Echo(command);
            await Task.Delay(1);
            return FakeProtocolServer.Json(@"{
                ""id"": 2,
                ""value"": 7,
                ""_logs"": [
                    {""level"": ""info"", ""message"": ""starting""},
                    {""level"": ""error"", ""message"": ""bad""}
                ],
                ""_logs_dropped"": 2
            }");
        });
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        var result = await client.SendCommandAsync("logged");

        AssertThat(result.Success).IsTrue();
        AssertThat(result.Value.GetProperty("value").GetInt32()).IsEqual(7);
        AssertThat(result.Value.TryGetProperty("_logs", out _)).IsFalse();
        AssertThat(result.Value.TryGetProperty("_logs_dropped", out _)).IsFalse();
        AssertThat(result.Logs).HasSize(3);
        AssertThat(result.Logs[0].GetProperty("message").GetString()).IsEqual("starting");
        AssertThat(result.Logs[1].GetProperty("level").GetString()).IsEqual("error");
        AssertThat(result.Logs[2].GetProperty("level").GetString()).IsEqual("warning");
        AssertThat(result.Logs[2].GetProperty("message").GetString())
            .IsEqual("<2> log entries dropped due to capture buffer overflow");
    }

    [TestCase]
    public async Task Command_ResponseSurvivesAfterClientInternalDocumentIsDisposed()
    {
        // The result must be a clone: still readable long after the client's
        // internal JsonDocument is unreachable (GC pressure proves it).
        await using var fake = FakeProtocolServer.Start();
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        var results = new List<E2EResult>();
        for (var i = 0; i < 64; i++)
            results.Add(await client.SendCommandAsync("ping"));

        GC.Collect();
        foreach (var result in results)
            AssertThat(result.Value.GetProperty("ok").GetBoolean()).IsTrue();
    }

    [TestCase]
    public async Task Command_ErrorKeyMeansFailureWithRenderedMessage()
    {
        await using var fake = FakeProtocolServer.Start(async command =>
        {
            var action = command.GetProperty("action").GetString();
            if (action == "hello")
                return FakeProtocolServer.Echo(command);
            await Task.Delay(1);
            return action switch
            {
                "err_full" => FakeProtocolServer.Json(
                    @"{""error"":""boom"",""message"":""details"",""note"":""kept""}"),
                "err_same" => FakeProtocolServer.Json(
                    @"{""error"":""boom"",""message"":""boom""}"),
                _ => FakeProtocolServer.Json(@"{""error"":""boom""}"),
            };
        });
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        var full = await client.SendCommandAsync("err_full");
        var same = await client.SendCommandAsync("err_same");
        var only = await client.SendCommandAsync("err_only");

        AssertThat(full.Success).IsFalse();
        AssertThat(full.Message).IsEqual("boom: details");
        AssertThat(full.Value.GetProperty("note").GetString()).IsEqual("kept");
        AssertThat(same.Success).IsFalse();
        AssertThat(same.Message).IsEqual("boom");
        AssertThat(only.Success).IsFalse();
        AssertThat(only.Message).IsEqual("boom");
    }

    // ---- Partial frame delivery ----

    [TestCase]
    public async Task Command_TrickledFrameIsReassembled()
    {
        await using var fake = FakeProtocolServer.Start();
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        fake.TrickleNextResponse();
        var result = await client.SendCommandAsync("ping");

        AssertThat(result.Success).IsTrue();
        AssertThat(result.Value.GetProperty("ok").GetBoolean()).IsTrue();
    }

    // ---- Raw failures: timeout, disconnect, id mismatch ----

    [TestCase]
    public async Task Command_TimeoutThrowsTimesOutAndDropsSession()
    {
        await using var fake = FakeProtocolServer.Start(async command =>
        {
            if (command.GetProperty("action").GetString() == "hello")
                return FakeProtocolServer.Echo(command);
            await Task.Delay(10_000);
            return FakeProtocolServer.Echo(command);
        });
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        var clock = Stopwatch.StartNew();
        var error = await CatchAsync(() => client.SendCommandAsync(
            "slow", timeout: TimeSpan.FromMilliseconds(250)));
        clock.Stop();

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual("Command 'slow' timed out after 250 ms");
        AssertThat(clock.ElapsedMilliseconds).IsLess(5_000);
        var closed = await CatchAsync(() => client.SendCommandAsync("next"));
        AssertThat(closed).IsInstanceOf<E2EException>();
        AssertThat(closed!.Message).IsEqual("E2E session is not open");
    }

    [TestCase]
    public async Task Command_AbruptDisconnectThrowsE2EException()
    {
        await using var fake = FakeProtocolServer.Start(EchoOnly);
        fake.Responder = async command =>
        {
            if (command.GetProperty("action").GetString() == "hello")
                return FakeProtocolServer.Echo(command);
            fake.CloseClient();
            await Task.Delay(1);
            return null;
        };
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        var error = await CatchAsync(() => client.SendCommandAsync("die"));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual("Connection lost while waiting for 'die'");
    }

    [TestCase]
    public async Task Command_ResponseIdMismatchThrowsAndDropsSession()
    {
        await using var fake = FakeProtocolServer.Start(async command =>
        {
            await Task.Delay(1);
            return command.GetProperty("action").GetString() == "hello"
                ? FakeProtocolServer.Echo(command)
                : FakeProtocolServer.Json(@"{""id"":99,""ok"":true}");
        });
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        var error = await CatchAsync(() => client.SendCommandAsync("mismatch"));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual("Unexpected response id 99 for 'mismatch'");
        var closed = await CatchAsync(() => client.SendCommandAsync("next"));
        AssertThat(closed!.Message).IsEqual("E2E session is not open");
    }

    // ---- One in-flight command, fail fast ----

    [TestCase]
    public async Task Command_SecondCommandWhileInFlightFailsImmediately()
    {
        await using var fake = FakeProtocolServer.Start(async command =>
        {
            if (command.GetProperty("action").GetString() == "hello")
                return FakeProtocolServer.Echo(command);
            await Task.Delay(10_000);
            return FakeProtocolServer.Echo(command);
        });
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        var inFlight = client.SendCommandAsync("hang");
        var clock = Stopwatch.StartNew();
        var error = await CatchAsync(() => client.SendCommandAsync("second"));
        clock.Stop();

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual("A command is already in flight");
        AssertThat(clock.ElapsedMilliseconds).IsLess(2_000);
        await client.DisposeAsync();
        await CatchAsync(() => inFlight);
    }

    [TestCase]
    public async Task Command_ConnectWhileCommandInFlightFailsFast()
    {
        await using var fake = FakeProtocolServer.Start(async command =>
        {
            if (command.GetProperty("action").GetString() == "hello")
                return FakeProtocolServer.Echo(command);
            await Task.Delay(10_000);
            return FakeProtocolServer.Echo(command);
        });
        await using var client = new E2EClient();
        await client.ConnectAsync(fake.Port, "t");

        var inFlight = client.SendCommandAsync("hang");
        var error = await CatchAsync(() => client.ConnectAsync(fake.Port, "t"));

        AssertThat(error).IsInstanceOf<E2EException>();
        AssertThat(error!.Message).IsEqual("A command is already in flight");
        await client.DisposeAsync();
        await CatchAsync(() => inFlight);
    }

    // ---- Wait/reload transport margin ----

    [TestCase]
    public void CommandTimeoutFor_WaitAndReloadCommandsAddMargin()
    {
        AssertThat(E2EClient.CommandTimeoutFor("wait_for_property"))
            .IsEqual(E2EProtocol.DefaultCommandTimeout + E2EProtocol.WaitMargin);
        AssertThat(E2EClient.CommandTimeoutFor("wait_for_signal"))
            .IsEqual(E2EProtocol.DefaultCommandTimeout + E2EProtocol.WaitMargin);
        AssertThat(E2EClient.CommandTimeoutFor("reload_scene"))
            .IsEqual(E2EProtocol.DefaultCommandTimeout + E2EProtocol.WaitMargin);
        AssertThat(E2EClient.CommandTimeoutFor("get_property"))
            .IsEqual(E2EProtocol.DefaultCommandTimeout);
        AssertThat(E2EClient.CommandTimeoutFor("screenshot"))
            .IsEqual(E2EProtocol.DefaultCommandTimeout);
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
}
