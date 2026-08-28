namespace GodotE2E.Tests;

/// <summary>
/// Shared fixture for launching the C# fixture scene. GODOT_BIN overrides the
/// executable for local runs; the 10-second product default launch timeout is
/// kept (no short overrides).
/// </summary>
internal static class TestProject
{
    public const string ScenePath = "res://tests/fixtures/csharp/main.tscn";

    public static E2ELaunchOptions CreateOptions() => new()
    {
        ScenePath = ScenePath,
        ProjectPath = TestPaths.RepositoryRoot,
        GodotPath = ResolveGodotPath(),
        // Headless keeps CI (no display) and local runs identical; --quiet
        // keeps the drained child output small.
        ExtraGodotArgs = ["--headless", "--quiet"],
    };

    public static string ResolveGodotPath() =>
        Environment.GetEnvironmentVariable("GODOT_BIN") is { Length: > 0 } path ? path : "godot";
}
