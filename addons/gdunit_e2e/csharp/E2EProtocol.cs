namespace GodotE2E;

/// <summary>
/// Protocol constants. Must stay in sync with the GDScript sources; the drift
/// is guarded by ProtocolTest.ProtocolConstants_MatchGdScriptSources.
/// </summary>
public static class E2EProtocol
{
    public const int ProtocolVersion = 1;
    public const int MaxFrameBytes = 16 * 1024 * 1024;
    public static readonly TimeSpan DefaultCommandTimeout = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan WaitMargin = TimeSpan.FromSeconds(1);

    /// <summary>Parent diagnostic tail bound per stream, mirroring E2EProcess.MAX_PIPE_BYTES.</summary>
    public const int MaxPipeBytes = 4 * 1024 * 1024;
}
