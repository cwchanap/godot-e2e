using System.Text;
using GdUnit4;
using static GdUnit4.Assertions;

namespace GodotE2E.Tests;

[TestSuite]
public class ProcessTest
{
    // ---- argv construction (mirrors e2e_process.gd build_arguments) ----

    [TestCase]
    public void BuildArguments_MatchesGdScriptOrderAndFlags()
    {
        var options = new E2ELaunchOptions
        {
            ScenePath = "res://tests/fixtures/csharp/main.tscn",
            ProjectPath = "/tmp/proj",
            ServerPort = 6008,
            LogVerbosity = "info",
            ExtraGodotArgs = ["--verbose"],
        };

        var args = E2EProcess.BuildArguments(options, "/tmp/port.txt", "tok");

        var expected = new[]
        {
            "--path", "/tmp/proj",
            "--scene", "res://addons/gdunit_e2e/runtime/bootstrap.tscn",
            "--verbose",
            "--",
            "--gdunit-e2e",
            "--gdunit-e2e-target-scene=res://tests/fixtures/csharp/main.tscn",
            "--gdunit-e2e-port=6008",
            "--gdunit-e2e-port-file=/tmp/port.txt",
            "--gdunit-e2e-token=tok",
            "--gdunit-e2e-log-verbosity=info",
        };
        AssertThat(args).HasSize(expected.Length);
        for (var i = 0; i < expected.Length; i++)
            AssertThat(args[i]).IsEqual(expected[i]);
    }

    [TestCase]
    public void BuildArguments_IncludesDefaultServerPortZero()
    {
        var options = new E2ELaunchOptions { ScenePath = "res://scene.tscn" };

        var args = E2EProcess.BuildArguments(options, "/tmp/port.txt", "tok");

        AssertThat(args).Contains("--gdunit-e2e-port=0");
    }

    // ---- launch option defaults (mirrors e2e_launch_options.gd) ----

    [TestCase]
    public void LaunchOptions_HaveGdScriptDefaults()
    {
        var options = new E2ELaunchOptions();

        AssertThat(options.Timeout).IsEqual(TimeSpan.FromSeconds(10));
        AssertThat(options.LogVerbosity).IsEqual("warning");
        AssertThat(options.ServerPort).IsEqual(0);
        AssertThat(options.BootstrapScenePath)
            .IsEqual("res://addons/gdunit_e2e/runtime/bootstrap.tscn");
        AssertThat(options.ExtraGodotArgs).HasSize(0);
    }

    // ---- executable resolution ----

    [TestCase]
    public void ResolveGodotPath_ExplicitOptionWins()
    {
        AssertThat(E2EProcess.ResolveGodotPath("/custom/godot"))
            .IsEqual("/custom/godot");
    }

    [TestCase]
    public void ResolveGodotPath_UsesGodotBinEnvironmentVariable()
    {
        var previous = Environment.GetEnvironmentVariable("GODOT_BIN");
        try
        {
            Environment.SetEnvironmentVariable("GODOT_BIN", "/env/godot");

            AssertThat(E2EProcess.ResolveGodotPath(null)).IsEqual("/env/godot");
        }
        finally
        {
            Environment.SetEnvironmentVariable("GODOT_BIN", previous);
        }
    }

    [TestCase]
    public void ResolveGodotPath_FallsBackToPath()
    {
        var previous = Environment.GetEnvironmentVariable("GODOT_BIN");
        try
        {
            Environment.SetEnvironmentVariable("GODOT_BIN", null);

            AssertThat(E2EProcess.ResolveGodotPath("")).IsEqual("godot");
        }
        finally
        {
            Environment.SetEnvironmentVariable("GODOT_BIN", previous);
        }
    }

    // ---- project resolution ----

    [TestCase]
    public void ResolveProjectPath_ExplicitOptionIsUsedVerbatim()
    {
        AssertThat(E2EProcess.ResolveProjectPath("/tmp/proj")).IsEqual("/tmp/proj");
    }

    [TestCase]
    public void ResolveProjectPath_WalksUpwardToRepositoryRoot()
    {
        AssertThat(E2EProcess.ResolveProjectPath(null)).IsEqual(TestPaths.RepositoryRoot);
    }

    // ---- bounded pipe tail (output-load regression) ----

    [TestCase]
    public void PipeTail_RetainsOnlyNewestMaxPipeBytes()
    {
        var tail = new PipeTail();

        tail.Append(new byte[E2EProtocol.MaxPipeBytes]); // 4 MiB of zeros
        var chunk = new byte[E2EProtocol.MaxPipeBytes];
        Array.Fill(chunk, (byte)'b');
        tail.Append(chunk); // 4 MiB of 'b' pushes all zeros out

        var text = tail.ToString();
        AssertThat(tail.TotalBytes).IsEqual(2L * E2EProtocol.MaxPipeBytes);
        AssertThat(text.Length).IsEqual(E2EProtocol.MaxPipeBytes);
        AssertThat(text.All(c => c == 'b')).IsTrue();
    }

    [TestCase]
    public void PipeTail_ChunkedAppendKeepsTailBoundedUnderLoad()
    {
        var tail = new PipeTail();
        var chunk = new byte[8192];
        Array.Fill(chunk, (byte)'x');

        // Simulate a continuous drain of far more than the retention limit.
        var writes = (E2EProtocol.MaxPipeBytes * 3) / chunk.Length;
        for (var i = 0; i < writes; i++)
            tail.Append(chunk);

        AssertThat(tail.TotalBytes).IsEqual((long)writes * chunk.Length);
        AssertThat(tail.ToString().Length).IsEqual(E2EProtocol.MaxPipeBytes);
    }

    [TestCase]
    public void PipeTail_PartialFillIsPreservedVerbatim()
    {
        var tail = new PipeTail();

        tail.Append(Encoding.UTF8.GetBytes("hello "));
        tail.Append(Encoding.UTF8.GetBytes("world"));

        AssertThat(tail.ToString()).IsEqual("hello world");
    }
}
