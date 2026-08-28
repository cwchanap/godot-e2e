using System.Text.Json;

namespace GodotE2E;

/// <summary>
/// Result of one raw command exchange, mirroring e2e_result.gd. Presence of
/// the protocol `error` key means failure; Message carries the rendered error,
/// Value the response with `_logs`/`_logs_dropped` removed, and Logs the
/// extracted response log entries.
/// </summary>
public sealed class E2EResult
{
    public bool Success { get; init; }

    /// <summary>Response payload with `_logs`/`_logs_dropped` removed.</summary>
    public JsonElement Value { get; init; }

    public string Message { get; init; } = string.Empty;

    public IReadOnlyList<JsonElement> Logs { get; init; } = Array.Empty<JsonElement>();
}
