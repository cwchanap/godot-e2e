using System.Text.Json;

namespace GodotE2E;

/// <summary>Thrown for protocol violations and remote wrapper failures.</summary>
public class E2EException : Exception
{
    public E2EException(string message) : base(message) { }

    public E2EException(string message, Exception innerException) : base(message, innerException) { }
}
