namespace GodotE2E;

/// <summary>
/// Options for launching the Godot child process. Mirrors
/// e2e_launch_options.gd; defaults are guarded by ProcessTest.
/// </summary>
public sealed class E2ELaunchOptions
{
    /// <summary>Required: scene the child loads as the automation target.</summary>
    public string ScenePath { get; set; } = "";

    /// <summary>
    /// Godot project directory. When empty, resolved by locating
    /// <c>project.godot</c> walking upward from the current directory.
    /// </summary>
    public string? ProjectPath { get; set; }

    /// <summary>
    /// Godot executable. When empty, <c>GODOT_BIN</c> is used, otherwise
    /// <c>godot</c> resolved from <c>PATH</c>.
    /// </summary>
    public string? GodotPath { get; set; }

    /// <summary>Bounded launch deadline (port-file wait + hello). Default 10 seconds.</summary>
    public TimeSpan Timeout { get; set; } = TimeSpan.FromSeconds(10);

    /// <summary>Additional flags passed to Godot itself, before the `--` separator.</summary>
    public IReadOnlyList<string> ExtraGodotArgs { get; set; } = [];

    /// <summary>Child log verbosity: error, warning, or info.</summary>
    public string LogVerbosity { get; set; } = "warning";

    /// <summary>Fixed server port; 0 lets the child pick one via the port file.</summary>
    public int ServerPort { get; set; }

    /// <summary>Bootstrap scene the child starts from.</summary>
    public string BootstrapScenePath { get; set; } = "res://addons/gdunit_e2e/runtime/bootstrap.tscn";
}
