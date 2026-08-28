namespace GodotE2E;

/// <summary>
/// Godot-specific typed values recognized by the C# protocol layer.
/// Only the tags explicitly supported here convert; everything else fails
/// loudly through E2EJson. Mirrors the subset of e2e_serializer.gd tags.
/// </summary>
public sealed record E2EVector2(double X, double Y);
