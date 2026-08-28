# C# E2E Integration Design

**Status:** Approved for implementation  
**Date:** 2026-08-27  
**Repository:** `cwchanap/godot-e2e`  
**Base contract:** `docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md`

## 1. Summary

Add a native C# authoring path to `godot-e2e` without changing the existing GDScript path and without creating a second child automation server.

The supported language matrix is deliberately narrow:

| Test language | Game language | Support |
| --- | --- | --- |
| GDScript | GDScript | Existing and supported |
| C# | C# | New and supported |
| GDScript | C# | Not supported or tested |
| C# | GDScript | Not supported or tested |

C# tests run through gdUnit4Net/VSTest as ordinary async .NET tests. They launch the repository Godot project as a separate **Godot .NET** child and drive it over the existing authenticated localhost protocol.

The child continues to use the addon-owned GDScript bootstrap, automation server, command handler, serializer, diagnostics, and orphan watchdog. C# adds only a second parent-side client/process facade.

Existing GDScript contracts remain authoritative unless this document explicitly amends them.

## 2. Goals

The C# integration must:

1. Let a C# gdUnit4Net test launch a separate Godot .NET child process for the same project.
2. Let that test drive a C# game scene through protocol v1.
3. Keep `GDScript test -> GDScript game` unchanged.
4. Reuse the existing GDScript child bootstrap/server.
5. Keep `GodotE2E.Client` independent of GodotSharp and gdUnit4Net.
6. Use idiomatic .NET async APIs with deterministic child cleanup.
7. Provide `RunAsync` as the normal C# test lifecycle so thrown test-body/assertion failures capture diagnostics before teardown.
8. Preserve protocol framing, token pairing, response shapes, log behavior, wait margins, frame limits, and orphan cleanup.
9. Keep child stdout/stderr continuously drained and bounded to the same 4 MiB diagnostic tail as the GDScript parent.
10. Validate both supported same-language paths on Linux and Windows.
11. Ship the C# client in the existing single addon archive.
12. Deliver design, plan, implementation, tests, CI, and docs in one feature PR.

## 3. Non-goals

This change will not:

- support or test either cross-language combination;
- port the automation server, bootstrap, command handler, or protocol to C#;
- create protocol v2;
- add a C# suite base class or custom runner;
- require `[RequireGodotRuntime]` for normal C# E2E tests;
- publish a NuGet package;
- add locators, retrying expectations, generated bindings, a generic RPC layer, pools, process reuse, parallel sessions, or a new CI matrix;
- guarantee renamed-addon-directory auto-discovery in the first C# release;
- use gdUnit4Net internals/reflection to inspect framework failure state;
- recreate the full Godot Variant type system.

## 4. Architecture

### 4.1 Existing GDScript path

```text
GDScript GdUnit4 test
└── GdUnitE2ETestSuite
    └── E2EProcess
        ├── E2EClient
        └── GdUnitE2EGame
            │
            │ protocol v1
            ▼
        Godot child
        └── existing bootstrap + automation server
            └── GDScript game scene
```

No C# work refactors this path merely to share parent implementation.

### 4.2 New C# path

```text
C# gdUnit4Net / VSTest process
└── E2EGame
    └── E2EProcess
        └── E2EClient
            │
            │ protocol v1
            ▼
        Godot .NET child
        ├── existing GDScript bootstrap
        ├── existing GDScript automation server
        └── C# game scene/scripts
```

The C# parent is a normal .NET process. It uses `System.Diagnostics.Process`, `System.Net.Sockets`, `System.Text.Json`, files, and timers. The separate Godot process is the runtime under test.

## 5. Why the C# parent is separate

The GDScript parent cannot be cleanly reused from a normal VSTest process:

- `E2EProcess` is a SceneTree `Node`, owns a `GdUnitTestSuite`, and uses GdUnit lifecycle helpers;
- `E2EClient` is a SceneTree `Node` that polls from `_process()`;
- `GdUnitE2EGame` maps failures into `suite.fail()`;
- `GdUnitE2ETestSuite` owns GdUnit-specific failure state and teardown.

Calling these objects dynamically from C# would keep those dependencies and add cross-language lifecycle complexity. The C# implementation therefore reuses the wire contract and child runtime, not the GDScript parent implementation.

## 6. Repository layout

```text
.
├── project.godot
├── GodotE2E.csproj
├── GodotE2E.sln
├── addons/gdunit_e2e/
│   ├── client/                         # existing GDScript parent
│   ├── protocol/                       # existing wire contract
│   ├── runtime/                        # existing child bootstrap
│   ├── server/                         # existing child server
│   └── csharp/
│       ├── .gdignore
│       ├── GodotE2E.Client.csproj
│       ├── E2EProtocol.cs
│       ├── E2EFraming.cs
│       ├── E2EJson.cs
│       ├── E2EValueTypes.cs
│       ├── E2EResult.cs
│       ├── E2EException.cs
│       ├── E2EClient.cs
│       ├── E2ELaunchOptions.cs
│       ├── E2EProcess.cs
│       ├── E2EGame.cs
│       └── AssemblyInfo.cs
├── tests/fixtures/csharp/
│   ├── Main.cs
│   ├── Main.cs.uid
│   └── main.tscn
└── tests/csharp/
    ├── GodotE2E.Tests.csproj
    ├── TestPaths.cs
    ├── RunnerSmokeTest.cs
    ├── ProtocolTest.cs
    ├── ClientTest.cs
    ├── GameApiTest.cs
    ├── ProcessLifecycleTest.cs
    ├── GameplaySmokeTest.cs
    ├── FakeProtocolServer.cs
    └── TestProject.cs
```

The exact C# test-file split may stay smaller if responsibilities remain clear. Do not create one class/file per protocol command.

`.gdignore` keeps the pure managed test client out of Godot's resource scan. MSBuild ignores `.gdignore`, so C# Godot projects still need the compile exclusion described below.

## 7. Godot .NET project contract

Adding a C# fixture turns this repository into a Godot .NET project.

### 7.1 Godot project metadata

`project.godot` keeps GL Compatibility and declares the normal C# project metadata:

```ini
[application]

config/name="godot-e2e"
config/features=PackedStringArray("4.5", "C#", "GL Compatibility")

[dotnet]

project/assembly_name="GodotE2E"
```

Use `GodotE2E.csproj` and `GodotE2E.sln` so the file/project identity matches `dotnet/project/assembly_name`.

Do **not** set `<AssemblyName>` manually in the `.csproj`. Godot 4.5 has a known engine bug where overriding `<AssemblyName>` can break C# script type resolution. The project filename/default assembly identity and `project/assembly_name` stay aligned instead.

### 7.2 Root game project

`GodotE2E.csproj` uses `Godot.NET.Sdk/4.5.1`, targets `net8.0`, compiles the repository C# fixture, and excludes both the test harness and pure E2E client:

```xml
<Project Sdk="Godot.NET.Sdk/4.5.1">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <EnableDynamicLoading>true</EnableDynamicLoading>
    <Nullable>enable</Nullable>
  </PropertyGroup>

  <ItemGroup>
    <Compile Remove="tests/csharp/**/*.cs" />
    <Compile Remove="addons/gdunit_e2e/csharp/**/*.cs" />
  </ItemGroup>
</Project>
```

The root game project compiles the C# fixture but does **not** compile either the gdUnit4Net test harness or the addon client library.

The solution contains only this game project. The gdUnit4Net test project remains outside it.

After the first Godot .NET import, commit `tests/fixtures/csharp/Main.cs.uid`. `.godot/**` remains ignored.

### 7.3 Consumer C# compile boundary

A Godot .NET consumer that installs `addons/gdunit_e2e` must keep the BCL client out of the game assembly while its test project references `GodotE2E.Client.csproj`.

Document this consumer rule in the C# installation steps:

```xml
<ItemGroup>
  <Compile Remove="addons/gdunit_e2e/csharp/**/*.cs" />
</ItemGroup>
```

This avoids compiling the test transport into the shipped game assembly. The separate test project compiles/references the client library through `GodotE2E.Client.csproj`.

GDScript consumers do not modify a `.csproj`.

## 8. C# test-runner boundary

`GodotE2E.Client.csproj` targets `net8.0` and has no dependency on GodotSharp, gdUnit4Net, or third-party networking/JSON packages.

Repository tests pin:

```text
gdUnit4.api              5.0.0
gdUnit4.test.adapter     3.0.0
gdUnit4.analyzers        1.0.0
Microsoft.NET.Test.Sdk  17.14.1
```

The test project references `GodotE2E.Client.csproj` but never references `GodotE2E.csproj`. Any GodotSharp dependency pulled transitively by gdUnit4Net stays isolated in the test project.

Normal E2E tests do not use `[RequireGodotRuntime]`.

## 9. Public C# API

### 9.1 `E2ELaunchOptions`

Primary fields:

```text
ScenePath
ProjectPath
GodotPath
Timeout
ExtraGodotArgs
LogVerbosity
ServerPort
BootstrapScenePath
```

Defaults:

- `ScenePath`: required;
- `ProjectPath`: locate `project.godot` upward from current/base directory when omitted;
- `GodotPath`: `GODOT_BIN`, otherwise `godot` resolved from `PATH`;
- `Timeout`: 10 seconds;
- `LogVerbosity`: `warning`;
- `ServerPort`: `0`;
- `BootstrapScenePath`: `res://addons/gdunit_e2e/runtime/bootstrap.tscn`.

Automatic renamed-addon discovery is deferred.

### 9.2 `E2EResult`

Raw commands return the existing response as a cloned `JsonElement` plus `Success`, `Message`, and response logs. Presence of protocol `error` means failure; no parallel C# error taxonomy is introduced.

### 9.3 Lean `E2EGame` convenience surface

The first wrapper set is limited to operations exercised by acceptance tests:

Inspection:

- `NodeExistsAsync`
- `GetPropertyAsync<T>`
- `SetPropertyAsync`
- `CallMethodAsync<T>`
- `GetSceneAsync`

Interaction:

- `InputActionAsync`
- `PressActionAsync`
- `ClickNodeAsync`

Synchronization:

- `WaitForPropertyAsync`
- `WaitForSignalAsync`

Scene/diagnostic:

- `ReloadSceneAsync`
- `ScreenshotAsync`
- `CaptureFailureArtifactsAsync`
- raw `SendCommandAsync`

Do not add wrappers in this release for `get_tree`, key/mouse-button input, frame/seconds waits, `wait_for_node`, or `change_scene`. Those commands remain reachable through `SendCommandAsync()`.

### 9.4 Failure-capturing `RunAsync`

Normal first-party tests and README examples use `RunAsync`, while `LaunchAsync` remains public for low-level/lifecycle tests:

```csharp
public static Task RunAsync(
    E2ELaunchOptions options,
    Func<E2EGame, CancellationToken, Task> body,
    CancellationToken cancellationToken = default,
    [CallerMemberName] string testName = "",
    [CallerFilePath] string callerFilePath = "")
```

The default failure directory is derived without call-site boilerplate:

```text
<resolved project>/test_output/csharp/<caller-file-name>/<testName>/
```

For first-party tests, caller file names match suite/class names, yielding the same useful `<suite>/<test>` shape as the GDScript path.

Behavior:

```text
LaunchAsync
→ run body
→ on body exception:
     best-effort capture screenshot/tree/logs while child is reachable
→ attempt DisposeAsync
→ append bounded stdout/stderr after exit when available
→ if only cleanup failed: throw cleanup error
→ if body failed: preserve/rethrow the original body exception
     and attach/report cleanup failure as secondary diagnostic if cleanup also failed
```

`RunAsync` must not let a cleanup exception replace an already-propagating assertion/test-body exception. If both fail, attach cleanup details to the body exception diagnostics and write them to stderr/artifacts, then rethrow the original exception with its original stack.

## 10. Failure model

Wrapped remote failures throw `E2EException`. Raw `SendCommandAsync()` returns `E2EResult` for expected negative paths.

Artifact capture is best effort and cannot replace the primary failure.

`DisposeAsync()` remains strict when called on a success path: failure to confirm owned child death throws `E2EException`. `RunAsync` preserves an earlier body failure as primary when teardown also reports a failure.

## 11. Process ownership, pipes, and cleanup

`E2EGame` owns one `E2EProcess`; `E2EProcess` owns one `System.Diagnostics.Process` and one `E2EClient`.

Launch:

```text
resolve project + Godot executable
→ create token and temp port file
→ Process.Start with redirected stdout/stderr
→ immediately start continuous async drains for both pipes
→ poll child exit + port file until bounded deadline
→ connect TcpClient to 127.0.0.1:<port>
→ send protocol-v1 hello
→ return E2EGame
```

Pass:

```text
--gdunit-e2e
--gdunit-e2e-target-scene=<ScenePath>
--gdunit-e2e-port=<ServerPort>
--gdunit-e2e-port-file=<path>
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=<level>
```

Pipe drains retain only the most recent **4 MiB per stream**, matching the GDScript parent's `MAX_PIPE_BYTES`. Do not use unbounded `ReadToEndAsync` storage. A small fixed-size byte-tail/ring buffer continuously consumes the OS pipe while bounding retained managed memory.

Shutdown:

```text
best-effort quit when authenticated
→ close TCP client
→ wait up to 1 second
→ Process.Kill(entireProcessTree: true) if alive
→ wait up to 1 second again
→ finish pipe drains
→ delete temp port file/directory best effort
→ throw if owned child death still cannot be confirmed
```

`DisposeAsync()` is idempotent. No production-only kill/test switch is added.

## 12. Protocol compatibility and drift guard

C# implements protocol v1 independently because the GDScript protocol classes cannot run in a pure VSTest parent.

Required invariants:

- four-byte unsigned big-endian frame length;
- UTF-8 JSON body;
- 16 MiB frame cap;
- hello first with token + protocol version 1;
- monotonically increasing IDs;
- one in-flight request;
- existing request keys, response shapes, error rendering, and `_logs` handling;
- wait transport deadline = server timeout + 1 second;
- reload transport deadline = default command timeout + 1 second;
- fixed host `127.0.0.1`.

Because C# duplicates protocol constants, a C# unit test reads `addons/gdunit_e2e/protocol/e2e_protocol.gd` and asserts these copies stay equal:

```text
PROTOCOL_VERSION              1
MAX_FRAME_BYTES               16 * 1024 * 1024
DEFAULT_COMMAND_TIMEOUT       5 seconds
WAIT_MARGIN                   1 second
```

The same test also pins the parent diagnostic tail to the existing GDScript `E2EProcess.MAX_PIPE_BYTES = 4 * 1024 * 1024`.

A drift guard is cheaper and clearer than inventing a cross-language shared constants generator.

## 13. Variant/JSON conversion

The first C# implementation recognizes only the Godot-specific tagged value needed by acceptance tests:

```text
v2 -> E2EVector2(double X, double Y)
```

Deferring other tags must be **loud**, not lossy. Before generic `System.Text.Json` deserialization, `E2EJson.Convert<T>` checks for an object `_t` tag. If the tag is not explicitly supported for the requested conversion, throw:

```text
Unsupported Godot value tag '<tag>'; use SendCommandAsync for raw access
```

This prevents a `v3`, `col`, `r2`, `np`, or other tagged payload from being silently deserialized into a plausible but incorrect type. Raw `SendCommandAsync()` remains the escape hatch for unsupported tags.

## 14. C# fixture

Add one C# fixture scene with only behavior needed by the C# acceptance tests:

- readable/writable state;
- callable method with return value;
- action/button state changes;
- one signal;
- deterministic paths;
- one fixture-only blocking method used to prove kill fallback.

The C# suite launches only this fixture. Existing GDScript tests keep using GDScript fixtures.

## 15. Failure artifacts

C# failure artifacts use the same useful suite/test grouping as GDScript:

```text
test_output/csharp/<suite>/<test>/
  screenshot.png
  scene_tree.json
  engine_logs.json
  stdout.log
  stderr.log
```

`CaptureFailureArtifactsAsync(outputDirectory)` stays public for handled negative paths. `RunAsync` selects the default suite/test directory from caller metadata and captures reachable artifacts automatically when the body throws.

Each artifact is independent and best effort. Process output is appended after teardown when available and is already bounded to the retained 4 MiB tail.

## 16. Testing strategy

### 16.1 Existing GDScript path

Keep all existing GDScript unit/integration/failure-harness tests. Once the repository becomes a Godot .NET project, remove ordinary explicit 5-second child-launch overrides so normal launches use the product's existing 10-second default. Keep short values that intentionally test timeout behavior.

### 16.2 C# unit tests

Cover:

- framing and partial reads;
- oversized declaration rejection before allocation;
- hello/token, IDs, timeout/disconnect, one-in-flight fail-fast behavior;
- response/error/log parsing;
- supported `v2` conversion and rejection of unsupported `_t` tags;
- protocol-constant + pipe-limit drift against GDScript sources;
- launch argv and project/executable resolution;
- wait/reload +1 second transport margin with a recording command sender;
- runner smoke without `[RequireGodotRuntime]`.

Do not duplicate the GDScript server timing-race integration test.

### 16.3 C# integration tests

Verify only the C# fixture path:

1. launch + port discovery + hello;
2. C# scene current;
3. property read/write;
4. method call;
5. input/button behavior;
6. property wait;
7. signal wait;
8. raw expected negative response;
9. explicit artifact capture;
10. `RunAsync` capture under `test_output/csharp/<suite>/<test>`;
11. graceful disposal;
12. body exception still cleans up;
13. blocked child force-kill;
14. no surviving child.

## 17. CI and clean-bootstrap coverage

Keep exactly two CI jobs: Linux and Windows. Both use Godot .NET 4.5.1 and .NET 8.

Main repository order:

```text
checkout
→ install Godot .NET 4.5.1
→ setup .NET 8
→ resolve GODOT_BIN
→ dotnet build GodotE2E.csproj
→ bootstrap pinned GdUnit4
→ clean GDScript-only bootstrap/import contract
→ existing GDScript suites
→ C# suites
→ intentional GDScript failure harness
→ verify no child survives
→ Linux only: package contract
```

No main-project Godot process runs before `GodotE2E.csproj` has built.

The clean bootstrap test continues to prove the **GDScript-only consumer shape**, not another C# project build. After `git archive HEAD` into the temp tree it removes repository-only C# project/test fixture material:

```text
GodotE2E.csproj
GodotE2E.sln
tests/csharp/**
tests/fixtures/csharp/**
```

It strips `C#` from `config/features` and removes the `[dotnet]` section from the temporary `project.godot`, then runs the existing GdUnit bootstrap/import check. It intentionally keeps `addons/gdunit_e2e/csharp/**` because that directory ships in the single addon archive; `.gdignore` keeps it out of Godot's resource scan.

This restores coverage for a C#-free GDScript consumer without adding another Godot install or a C# build inside the temp archive.

## 18. Installation and packaging

One release artifact remains:

```text
addons/gdunit_e2e/**
README.md
LICENSE
NOTICE
```

### GDScript users

```text
install GdUnit4
install/copy addons/gdunit_e2e
write GDScript E2E tests
run through GdUnit4
```

No C# project changes are required.

### C# users

```text
use a Godot .NET project
install/copy addons/gdunit_e2e
exclude addons/gdunit_e2e/csharp/**/*.cs from the game .csproj Compile items
create/use a C# gdUnit4Net test project
reference addons/gdunit_e2e/csharp/GodotE2E.Client.csproj
write tests using E2EGame.RunAsync
run dotnet test
```

No NuGet publication is part of this change.

## 19. Compatibility policy

Support means only:

```text
GDScript test -> GDScript game
C# test       -> C# game
```

Cross-language behavior may work incidentally because the child server acts on generic Godot nodes, but this release adds no compatibility promise or fixture for it.

## 20. Risks

### Risk 1: gdUnit4Net versus Godot 4.5.1 dependency graph

The test project may receive a different GodotSharp version transitively through gdUnit4Net. It stays isolated because the test project references only `GodotE2E.Client`, not the game project.

### Risk 2: process/pipe behavior on Windows

Redirected pipes can deadlock if not drained and can consume unbounded managed memory if fully retained. The C# parent continuously drains both streams and retains only the most recent 4 MiB per stream; Linux and Windows integration coverage pins graceful/forced exit.

### Risk 3: Godot .NET cold start

The old standard-Godot integration helpers used several non-semantic 5-second launch overrides. Build before launch and use the existing 10-second product default for normal child starts.

### Risk 4: C# source globbing

Godot.NET.Sdk compiles C# sources under the project tree unless excluded. The repository and documented consumer C# setup explicitly remove `addons/gdunit_e2e/csharp/**/*.cs` from the game compile; the test project references the client project separately.

### Risk 5: duplicated protocol constants

C# necessarily duplicates a few GDScript wire constants. A focused drift test fails locally/CI when either side changes without the other.

### Risk 6: cleanup during an existing test failure

A wedged child can make teardown fail at the same time an assertion/body exception is already propagating. `RunAsync` preserves the body exception as primary and records cleanup failure as secondary diagnostic; `DisposeAsync` remains strict when no earlier body failure exists.

## 21. Acceptance criteria

The change is accepted when:

- existing GDScript public APIs remain unchanged;
- `project.godot` declares the C# project identity and `GodotE2E.csproj`/`GodotE2E.sln` match it without a manual `<AssemblyName>` override;
- the solution contains only the game project and `Main.cs.uid` is committed;
- root game compile excludes `tests/csharp/**` and `addons/gdunit_e2e/csharp/**`;
- the clean-bootstrap test strips repository C# project metadata/fixtures and still imports the shipped addon as a GDScript-only project;
- GDScript child-launch tests use the 10-second default except intentional timeout cases;
- gdUnit4Net C# tests run without `[RequireGodotRuntime]` and launch only the C# fixture;
- `GodotE2E.Client` has no GodotSharp/gdUnit package dependency;
- C# protocol constants and 4 MiB pipe-tail limit are guarded against GDScript drift;
- unsupported `_t` tags fail loudly instead of silently converting;
- C# wait/reload wrappers have +1 second margin unit coverage;
- `RunAsync` writes failure artifacts to `test_output/csharp/<suite>/<test>` and preserves the body failure if cleanup also fails;
- `DisposeAsync` reaps normal children and force-kills a blocked child;
- no child survives either supported test path;
- Linux/Windows CI build the root C# project before main-project Godot runs and execute both same-language paths;
- the release ZIP contains `addons/gdunit_e2e/csharp/**` and excludes root project/test files, GdUnit4, reports, and test output;
- README documents the C# game-project `<Compile Remove>` requirement and makes no cross-language support claim.

## 22. Deferred follow-ups

Only consider after the same-language C# path is useful:

1. Cross-language compatibility fixtures/support.
2. NuGet publication.
3. Additional Godot Variant stand-ins driven by real usage.
4. Automatic renamed-addon discovery for the C# bootstrap path.
5. Process reuse/pooling/parallel sessions.
6. Richer trace/diagnostic/editor UX.
