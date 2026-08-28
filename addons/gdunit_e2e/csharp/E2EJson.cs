using System.Text.Json;

namespace GodotE2E;

/// <summary>
/// JSON to typed-value conversion. Before generic deserialization, tagged
/// objects (`_t`) are checked so unsupported Godot values fail loudly instead
/// of silently deserializing into a plausible but wrong type.
/// </summary>
public static class E2EJson
{
    public static T Convert<T>(JsonElement element)
    {
        if (element.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)
            return default!;

        if (element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty("_t", out var tag)
            && tag.ValueKind == JsonValueKind.String)
        {
            var tagValue = tag.GetString()!;
            if (tagValue == "v2")
            {
                return (T)(object)new E2EVector2(
                    element.GetProperty("x").GetDouble(),
                    element.GetProperty("y").GetDouble());
            }

            throw new E2EException(
                $"Unsupported Godot value tag '{tagValue}'; use SendCommandAsync for raw access");
        }

        return element.Deserialize<T>()!;
    }
}
