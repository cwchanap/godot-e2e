using System.Text.Json;

namespace GodotE2E;

/// <summary>
/// JSON to typed-value conversion. Before generic deserialization, tagged
/// objects (`_t`) are checked — at the root AND nested anywhere — so
/// unsupported Godot values fail loudly instead of silently deserializing
/// into a plausible but wrong type. e2e_serializer.gd recurses serialize()
/// into arrays/dicts, so nested tagged payloads are real on the wire.
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
                // Build the typed value, but return it only when it is
                // compatible with the requested T. An incompatible T (e.g.
                // double, object, another record) must fail through the same
                // explicit unsupported-conversion path — never escape as a raw
                // InvalidCastException from the (T)(object) cast.
                var vector = new E2EVector2(
                    element.GetProperty("x").GetDouble(),
                    element.GetProperty("y").GetDouble());
                if (typeof(T) == typeof(E2EVector2))
                    return (T)(object)vector;
                throw UnsupportedConversion(tagValue, typeof(T));
            }

            throw Unsupported(tagValue);
        }

        // Only the ROOT v2 -> E2EVector2 path is supported; any tag nested
        // below the root (including v2 inside arrays) is rejected loudly.
        ScanForNestedTags(element);
        return element.Deserialize<T>()!;
    }

    private static void ScanForNestedTags(JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    if (property.Name == "_t" && property.Value.ValueKind == JsonValueKind.String)
                        throw Unsupported(property.Value.GetString()!);
                    ScanForNestedTags(property.Value);
                }
                break;
            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                    ScanForNestedTags(item);
                break;
        }
    }

    private static E2EException Unsupported(string tag) => new(
        $"Unsupported Godot value tag '{tag}'; use SendCommandAsync for raw access");

    private static E2EException UnsupportedConversion(string tag, Type requested) => new(
        $"Godot value tag '{tag}' is not convertible to '{requested}'; use SendCommandAsync for raw access");
}
