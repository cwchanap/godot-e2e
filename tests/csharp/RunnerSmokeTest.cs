using GdUnit4;
using static GdUnit4.Assertions;

namespace GodotE2E.Tests;

[TestSuite]
public class RunnerSmokeTest
{
    [TestCase]
    public void RunnerIsWiredUp()
    {
        AssertThat(1).IsEqual(1);
    }

    [TestCase]
    public void RepositoryRootPointsAtProjectGodot()
    {
        AssertThat(File.Exists(Path.Combine(TestPaths.RepositoryRoot, "project.godot"))).IsTrue();
    }
}
