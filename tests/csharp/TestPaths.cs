namespace GodotE2E.Tests;

internal static class TestPaths
{
    public static string RepositoryRoot { get; } = FindRepositoryRoot();

    private static string FindRepositoryRoot()
    {
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            var dir = new DirectoryInfo(Path.GetFullPath(start));
            while (dir is not null)
            {
                if (File.Exists(Path.Combine(dir.FullName, "project.godot")))
                    return dir.FullName;
                dir = dir.Parent;
            }
        }

        throw new InvalidOperationException(
            "Could not locate the repository root: no 'project.godot' found while walking upward from "
            + $"'{Directory.GetCurrentDirectory()}' or '{AppContext.BaseDirectory}'.");
    }
}
