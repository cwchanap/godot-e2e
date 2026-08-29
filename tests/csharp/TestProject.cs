namespace GodotE2E.Tests;

/// <summary>
/// Shared fixture for launching the C# fixture scene. GODOT_BIN overrides the
/// executable for local runs; the 10-second product default launch timeout is
/// kept (no short overrides).
/// </summary>
internal static class TestProject
{
    public const string ScenePath = "res://tests/fixtures/csharp/main.tscn";

    /// <summary>
    /// Headless by default for lifecycle work. Input simulation (click_node,
    /// input_action routing to Controls) and viewport screenshots need a real
    /// window, exactly like the GDScript integration suites — pass
    /// <c>headless: false</c> for gameplay and artifact tests.
    /// </summary>
    public static E2ELaunchOptions CreateOptions(bool headless = true) => new()
    {
        ScenePath = ScenePath,
        ProjectPath = TestPaths.RepositoryRoot,
        GodotPath = ResolveGodotPath(),
        // --quiet keeps the drained child output small.
        ExtraGodotArgs = headless ? ["--headless", "--quiet"] : ["--quiet"],
    };

    public static string ResolveGodotPath() =>
        Environment.GetEnvironmentVariable("GODOT_BIN") is { Length: > 0 } path ? path : "godot";
}
