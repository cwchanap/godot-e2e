# godot-e2e

Native out-of-process end-to-end testing for Godot, with a GDScript path
(GdUnit4 tests) and a C# path (gdUnit4Net tests). A test starts the same
Godot project as a separate child process and drives it over an
authenticated localhost connection.

Supported pairings only: GDScript test -> GDScript game, and C# test -> C#
game. Cross-language combinations are not supported by this release (they
may work incidentally, but no fixture or promise covers them).

The 0.1.x MVP targets Godot 4.5 or newer (Godot .NET 4.5.1 with .NET 8 for
the C# path) and GdUnit4 6.x. GDScript users keep GdUnit4 as the test
runner, assertion library, lifecycle, CLI, and reporter; C# users keep
gdUnit4Net. This addon only supplies the child-process client, automation
server, and suite/facade helpers.

## Install

### GDScript users

1. Install GdUnit4.
2. Install/copy addons/gdunit_e2e.
3. Write an E2E test.

There is no editor plugin to enable and godot-e2e does not add an autoload
to your project. The automation server exists only inside child processes
launched by GdUnitE2ETestSuite.

The addon archive does not include GdUnit4, the test fixtures, or the
CI/bootstrap files.

### C# users

1. Use a Godot .NET project (this repository pins Godot .NET 4.5.1 and
   .NET 8).
2. Install/copy addons/gdunit_e2e.
3. Exclude the shipped client sources from the game project's compile — add
   this to your game `.csproj`:

```xml
<ItemGroup>
  <Compile Remove="addons/gdunit_e2e/csharp/**/*.cs" />
</ItemGroup>
```

   Without this the Godot.NET.Sdk globs the client sources into your game
   assembly.

4. Create a separate gdUnit4Net test project that references the client and
   the pinned gdUnit packages (do not reference the game project from it):

```xml
<ItemGroup>
  <PackageReference Include="gdUnit4.api" Version="5.0.0" />
  <PackageReference Include="gdUnit4.test.adapter" Version="3.0.0" />
  <PackageReference Include="gdUnit4.analyzers" Version="1.0.0" />
  <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
</ItemGroup>
<ItemGroup>
  <ProjectReference Include="path/to/addons/gdunit_e2e/csharp/GodotE2E.Client.csproj" />
</ItemGroup>
```

5. Write tests using `E2EGame.RunAsync` and run `dotnet test`. The client is
   BCL-only and the tests do **not** use `[RequireGodotRuntime]`; the child
   Godot process is found through the `GODOT_BIN` environment variable (or
   `godot` on `PATH` as fallback).

## Minimal test

Put a test under the project's normal GdUnit4 test tree and extend
`GdUnitE2ETestSuite`:

```gdscript
extends GdUnitE2ETestSuite

func test_main_is_ready() -> void:
    var options := E2ELaunchOptions.new()
    options.scene_path = "res://main.tscn"
    var game := await launch_game(options)
    if game == null or is_failure():
        return

    var status = await game.get_property("/root/Main/Status", "text")
    if is_failure():
        return
    assert_str(status).is_equal("ready")
```

`launch_game()` uses the current project and defaults to the fixture scene
(`res://tests/fixtures/minimal/main.tscn` in this repository). That fixture is
not included in the release archive, so installed users must set
`E2ELaunchOptions.scene_path` to a scene owned by their project, such as the
`res://main.tscn` placeholder in the example. Pass an `E2ELaunchOptions` value
when a test needs a different scene or Godot arguments. Every test-owned child
is tracked by the suite.

The `if is_failure(): return` guard matters after `launch_game()` and after a
wrapped remote call. A wrapped API call maps a transport/server error to the
GdUnit4 failure state and returns a safe fallback; continuing to make more
remote calls after that failure can obscure the original error.

## Lifecycle and cleanup

The base suite automatically captures failure artifacts (available diagnostics)
when a test is in the GdUnit4 failure state, then closes and reaps the child.
It writes artifacts under:

```text
test_output/<suite>/<test>/
  screenshot.png
  scene_tree.json
  engine_logs.json
  stdout.log
  stderr.log
```

The first three files are collected while the child is reachable; stdout and
stderr are drained after the child has exited. Capture is best effort, so a
failed diagnostic request never replaces the test's primary failure. Tests
that need diagnostics for a deliberately handled negative response may call
`await capture_failure_artifacts(game)` explicitly.

The base suite also has a final `after()` safety cleanup. If you override
`after_test()` or `after()`, you must await the corresponding super hook:

```gdscript
func after_test() -> void:
    # Test-specific cleanup may go here.
    await super.after_test()

func after() -> void:
    await super.after()
```

The child automation server starts an authenticated-peer orphan watchdog. If
the parent disappears after authentication, the child exits after its grace
period; re-authentication during that period cancels the watchdog. Normal
teardown still closes the child and confirms that its PID is no longer
running.

## Remote API

Use the wrapped `GdUnitE2EGame` methods for common operations. The MVP covers
node/property inspection, method calls, scene changes, input, screenshots,
frame/physics/seconds waits, and waits for nodes, properties, or signals:

```gdscript
assert_bool(await game.node_exists("/root/Main/Button")).is_true()
assert_bool(await game.click_node("/root/Main/Button")).is_true()
assert_bool(await game.wait_for_property(
    "/root/Main/ClickStatus", "text", "clicked", 2.0
)).is_true()
```

For a server command that does not have a wrapper, or for a negative-path
assertion, use the raw escape hatch:

```gdscript
var result: E2EResult = await game.send_command(
    "get_property",
    {"path": "/root/Missing", "property": "text"},
)
assert_bool(result.ok).is_false()
```

`send_command()` returns `E2EResult` and does not automatically fail the
GdUnit4 test. This is intentional for direct protocol checks and handled
negative paths. Wrapped methods do map failed requests to the suite failure
state, as described above.

## Minimal C# test

A gdUnit4Net test uses the `E2EGame.RunAsync` facade. It launches the child,
runs the body, captures failure artifacts under
`test_output/csharp/<suite>/<test>/` when the body throws, and always closes
and reaps the child (force-killing a blocked one):

```csharp
using static GdUnit4.Assertions;

[TestSuite]
public class MainReadyTest
{
    [TestCase]
    public Task MainIsReady() => E2EGame.RunAsync(
        new E2ELaunchOptions
        {
            ScenePath = "res://main.tscn",
            ProjectPath = "<path to your Godot .NET project>",
        },
        async (game, ct) =>
        {
            AssertThat(
                await game.GetPropertyAsync<string>("/root/Main/Status", "text"))
                .IsEqual("ready");
        });
}
```

For finer control (explicit artifact capture, custom teardown) use
`await E2EGame.LaunchAsync(options)` and `await using`/`DisposeAsync` the
returned game. The wrapped surface is deliberately lean (§9.3): node and
property access (`NodeExistsAsync`, `GetPropertyAsync`, `SetPropertyAsync`,
`CallMethodAsync`, `GetSceneAsync`), input (`InputActionAsync`,
`PressActionAsync`, `ClickNodeAsync`), waits (`WaitForPropertyAsync`,
`WaitForSignalAsync`), and `ReloadSceneAsync`, `ScreenshotAsync`,
`CaptureFailureArtifactsAsync`. There are no wrappers for scene changes,
frame/physics/seconds/node waits, `wait_for_node`, or tree dumps — those stay
reachable through the raw `SendCommandAsync` escape hatch.

## Same-project behavior and CI

The child is launched from the same project tree as the test runner and uses
the repository's addon rather than a copied fixture addon. The automation
server is created only in the child process, so normal project runs remain
ordinary project behavior.

For local development in this repository, install the pinned GdUnit4 copy and
run the normal suite by directory. Keep the intentional failure fixture out of
this command:

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
```

The failure harness is a separate check because it must fail intentionally and
exit with status 100:

```bash
set +e
./addons/gdUnit4/runtest.sh -a tests/fixtures/failure_harness_test.gd
status=$?
set -e
test "$status" -eq 100
```

The C# suites run with `dotnet test` (set `GODOT_BIN` so the tests can find
the Godot .NET executable):

```bash
dotnet build GodotE2E.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj
```

Build `GodotE2E.csproj` before launching any main-project Godot process, so
the editor import never has to drive the C# build.

GitHub Actions runs the full gate on both Linux and Windows with Godot .NET
4.5.1 and .NET 8: bootstrap, clean GDScript-only bootstrap contract, the
GDScript suites, the C# suites, the intentional failure harness, a survivor
scan (always), and — on Linux — the release package contract. Linux uses
Xvfb for the child display (the C# gameplay tests launch non-headless, like
the GDScript integration suites); both jobs use the same Bash bootstrap and
the same GdUnit4 6.2.1 pin. Reports, `test_output`, and the C# `TestResults`
are uploaded. Windows hosted execution remains an external CI gate; local
macOS verification does not substitute for it.

## Packaging and attribution

Create a versioned archive with:

```bash
./scripts/package_release.sh 0.1.1
unzip -l dist/godot-e2e-0.1.1.zip
```

The archive contains only `addons/gdunit_e2e/**` (including the shipped C#
client under `addons/gdunit_e2e/csharp/**`), `README.md`, `LICENSE`, and
`NOTICE`. GdUnit4, tests, reports, `test_output`, C# build output, and
CI/bootstrap files are deliberately excluded. The release contract is pinned
by `tests/scripts/package_release_test.sh`. The adapted server/protocol
portions are credited in `NOTICE` and remain under the Apache License,
Version 2.0.

To publish a release, push a stable SemVer tag such as `v0.1.1`. GitHub
Actions runs the Linux and Windows gates first; when both pass, it creates the
GitHub Release with generated notes and attaches `godot-e2e-0.1.1.zip`.
Pre-release tags are intentionally not supported by this workflow.

## Deferred after 0.1.0

The MVP intentionally does not include Playwright-style locators, retrying
`expect()` assertions, engine-error-flood detection, cross-language (C# test
to GDScript game, or the reverse) compatibility fixtures, macOS CI, NuGet
publication of the C# client, suite-level process reuse/pools/parallel
sessions, or richer trace/diagnostic/editor UX.
