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

C# tests run through gdUnit4Net/VSTest as ordinary async .NET tests. They launch the same Godot project as a separate **Godot .NET** child process and drive it over the existing authenticated localhost protocol.

The child continues to use the existing addon-owned GDScript bootstrap, automation server, command handler, protocol framing, serializer contract, diagnostics, and orphan watchdog. C# only adds a second parent-side client/process facade.

This document amends the base design only for C# support. Existing GDScript contracts remain authoritative unless explicitly changed here.

## 2. Goals

The C# integration must:

1. Let a C# gdUnit4Net test launch a separate Godot .NET child process for the same project.
2. Let that test drive a C# game scene through the existing protocol v1 command surface.
3. Keep `GDScript test -> GDScript game` unchanged.
4. Reuse the existing GDScript child bootstrap and automation server.
5. Keep the C# transport/process library independent of gdUnit4Net internals and independent of GodotSharp.
6. Use idiomatic .NET async APIs and deterministic `IAsyncDisposable` cleanup.
7. Provide a small `RunAsync` helper that captures diagnostics when a normal C# test body throws.
8. Preserve the existing localhost-only token handshake, frame cap, serializer tags, command names, response shapes, wait margins, and child orphan watchdog.
9. Validate C# child launch and cleanup on Linux and Windows CI.
10. Ship the C# client with the same addon/release artifact.
11. Deliver design, plan, implementation, tests, CI, and documentation in one feature PR.

## 3. Non-goals

This change will not:

- support or test GDScript tests against C# game scenes;
- support or test C# tests against GDScript game scenes;
- port the automation server, command handler, bootstrap, or protocol implementation to C#;
- create protocol v2 or alter protocol v1;
- replace gdUnit4Net discovery, assertions, VSTest integration, or reporting;
- add a C# suite base class or custom test runner;
- require `[RequireGodotRuntime]` for normal C# E2E tests;
- publish a NuGet package in the first C# release;
- add a generic RPC framework or generated protocol bindings;
- add parallel requests, simultaneous sessions, a process pool, or suite-level child reuse;
- add a second CI OS/version matrix;
- guarantee renamed-addon-directory auto-discovery from the C# launcher in the first release;
- inspect internal gdUnit4Net runner state or use reflection to detect failures.

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

No C# work should refactor this path merely to share parent-side code.

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

The C# parent does not need to be a Godot process. It uses standard .NET process, socket, JSON, file, and timing APIs. The separate Godot child remains the runtime under test.

## 5. Why the C# parent is separate

The existing GDScript parent is intentionally tied to GdUnit4 and the SceneTree:

- `E2EProcess` owns a `GdUnitTestSuite` and uses its temp-directory and await helpers;
- `E2EClient` is a SceneTree `Node` because it polls from `_process()`;
- `GdUnitE2EGame` maps remote failures into the suite's `fail()` state;
- `GdUnitE2ETestSuite` owns automatic teardown and failure-artifact policy.

Calling those classes dynamically from C# would preserve those dependencies while adding cross-language async/lifecycle complexity. The C# implementation therefore reuses the **wire contract and child runtime**, not the GDScript parent implementation.

The duplicated code is limited to the parent transport/process boundary where .NET and GDScript have materially different runtime primitives.

## 6. Repository layout

```text
.
├── project.godot
├── godot-e2e.csproj
├── godot-e2e.sln
├── addons/gdunit_e2e/
│   ├── client/                         # existing GDScript parent
│   ├── protocol/                       # existing wire contract
│   ├── runtime/                        # existing child bootstrap
│   ├── server/                         # existing child server
│   └── csharp/
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

## 7. Godot .NET project contract

Adding a C# fixture turns the repository itself into a Godot .NET project. The repository contract therefore includes more than a root `.csproj`.

### 7.1 `project.godot`

Keep the existing GL Compatibility renderer and add the normal Godot C# project metadata:

```ini
[application]

config/name="godot-e2e"
config/features=PackedStringArray("4.5", "C#", "GL Compatibility")

[dotnet]

project/assembly_name="GodotE2E"
```

The `C#` feature marks the project as requiring a .NET-capable Godot build. Existing GDScript integration children therefore also run under the Godot .NET executable after this change.

### 7.2 Root game project

`godot-e2e.csproj` uses `Godot.NET.Sdk/4.5.1`, targets `net8.0`, and uses a hyphen-free assembly name:

```xml
<Project Sdk="Godot.NET.Sdk/4.5.1">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <EnableDynamicLoading>true</EnableDynamicLoading>
    <Nullable>enable</Nullable>
    <AssemblyName>GodotE2E</AssemblyName>
  </PropertyGroup>

  <ItemGroup>
    <Compile Remove="tests/csharp/**/*.cs" />
    <Compile Remove="addons/gdunit_e2e/csharp/**/*.cs" />
  </ItemGroup>
</Project>
```

The root game project compiles the C# fixture but does **not** compile either the gdUnit4Net test harness or the addon client library. This keeps the repository fixture assembly focused and avoids pulling test-runner/client implementation into the game-under-test assembly.

This exclusion is repository-specific. A consumer Godot .NET project may compile the BCL-only addon client `.cs` files normally; it does not need to copy this repository's exclusion rule.

### 7.3 Solution and UID files

Commit `godot-e2e.sln` containing only `godot-e2e.csproj`; do not add `GodotE2E.Tests.csproj` to that solution.

After the first Godot .NET import, commit the generated `tests/fixtures/csharp/Main.cs.uid`. The fixture scene must point at the C# script through its stable resource identity after import.

Everything under `.godot/` remains ignored.

## 8. C# test-runner boundary

`addons/gdunit_e2e/csharp/GodotE2E.Client.csproj` targets `net8.0` and has no dependency on:

- GodotSharp;
- gdUnit4Net;
- GdUnit4 GDScript;
- third-party networking packages;
- third-party JSON packages.

It uses only the .NET BCL.

Repository tests use these pinned packages in `tests/csharp/GodotE2E.Tests.csproj`:

```text
gdUnit4.api              5.0.0
gdUnit4.test.adapter     3.0.0
gdUnit4.analyzers        1.0.0
Microsoft.NET.Test.Sdk  17.14.1
```

The test project references `GodotE2E.Client.csproj` but does not reference `godot-e2e.csproj`. `gdUnit4.api` may bring GodotSharp transitively into the **test** project; that dependency stays isolated from the Godot 4.5.1 game project.

Normal E2E tests do not use `[RequireGodotRuntime]` because they do not instantiate Godot objects in the VSTest parent process.

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

- `ScenePath`: required for public C# launch;
- `ProjectPath`: walk upward for `project.godot` from current/base directory when omitted;
- `GodotPath`: `GODOT_BIN` when set, otherwise `godot` resolved by the OS `PATH`;
- `Timeout`: 10 seconds;
- `LogVerbosity`: `warning`;
- `ServerPort`: `0`;
- `BootstrapScenePath`: `res://addons/gdunit_e2e/runtime/bootstrap.tscn`.

The bootstrap path is overridable. Automatic renamed-addon discovery is deferred.

### 9.2 `E2EResult`

Raw commands expose the existing response rather than inventing a new error taxonomy:

```text
Success
Response (cloned JsonElement)
Message
Logs
```

Presence of the existing protocol `error` field means failure.

### 9.3 `E2EGame` convenience surface

Keep the first wrapper set to operations exercised by the C# acceptance tests:

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

Do **not** add convenience wrappers in this release for `get_tree`, key/mouse-button input, frame/seconds waits, `wait_for_node`, or `change_scene`. Those existing server commands remain available through `SendCommandAsync()` and can receive wrappers when real C# call sites need them.

### 9.4 Failure-capturing `RunAsync`

Normal first-party tests and README examples use:

```csharp
public static Task RunAsync(
    E2ELaunchOptions options,
    Func<E2EGame, CancellationToken, Task> body,
    CancellationToken cancellationToken = default)
```

Behavior:

```text
LaunchAsync
→ execute body
→ if body throws:
     best-effort CaptureFailureArtifactsAsync while child is reachable
→ DisposeAsync in finally
→ after child exit, append stdout/stderr to the same artifact directory when failure capture started
→ rethrow the test/body exception (normal finally/disposal exception semantics apply if cleanup itself fails)
```

Default automatic C# failure artifacts go under:

```text
test_output/csharp/<timestamp>-<short-guid>/
```

`LaunchAsync()` and explicit `CaptureFailureArtifactsAsync(outputDirectory)` remain public primitives for lifecycle tests and deliberately handled negative paths.

This helper provides failure diagnostics without a C# suite base class and without coupling the client to gdUnit4Net internals.

## 10. Failure model

Wrapped remote-operation failures throw `E2EException`. gdUnit4Net/VSTest reports that exception as a failed test.

`SendCommandAsync()` returns `E2EResult` without throwing for expected server/protocol negative paths.

`RunAsync()` catches ordinary test-body exceptions only to collect diagnostics before teardown, then rethrows. It does not inspect assertion-framework state.

## 11. Process ownership and cleanup

`E2EGame` implements `IAsyncDisposable` and owns one `E2EProcess`.

Launch:

```text
resolve project + Godot executable
→ create token and temp port-file path
→ Process.Start with redirected stdout/stderr
→ immediately start ReadToEndAsync for both pipes
→ poll child exit + port file until bounded deadline
→ connect TcpClient to 127.0.0.1:<port>
→ send protocol-v1 hello token
→ return E2EGame
```

Pass the same E2E user arguments as the GDScript launcher:

```text
--gdunit-e2e
--gdunit-e2e-target-scene=<scene>
--gdunit-e2e-port=0
--gdunit-e2e-port-file=<path>
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=<level>
```

Shutdown:

```text
best-effort quit when authenticated
→ close TCP client
→ wait up to 1 second for process exit
→ Process.Kill(entireProcessTree: true) if still alive
→ wait up to 1 second for confirmed exit
→ finish stdout/stderr drains
→ delete temp port file/directory best effort
→ throw E2EException if owned child death still cannot be confirmed
```

`DisposeAsync()` is idempotent. No production-only kill/test switch is added.

## 12. Protocol compatibility

The C# client implements protocol v1 to interoperate with the unchanged GDScript server.

Required invariants:

- four-byte unsigned big-endian frame length;
- UTF-8 JSON body;
- `16 * 1024 * 1024` frame cap;
- first command is `hello` with token and `protocol_version = 1`;
- monotonically increasing request IDs;
- one in-flight request;
- existing command names/keys and response shapes;
- existing `error` rendering semantics;
- server-side waits use a client deadline of server timeout + `1 second`;
- scene reload uses default command timeout + `1 second`;
- host is fixed to `127.0.0.1`.

No server change is required solely for C# support.

## 13. Variant/JSON conversion

The existing `_t` tags remain the wire contract.

The first C# implementation decodes only types exercised by the supported wrapper surface/tests. Primitive values and containers use ordinary `System.Text.Json` conversion.

The first required Godot-specific stand-in is:

```text
v2 -> E2EVector2(double X, double Y)
```

Do not recreate the full Godot Variant type system. Raw `SendCommandAsync()` preserves access to unsupported/custom JSON shapes.

## 14. C# fixture

Add one dedicated C# fixture scene with a C# root script. It exposes only behavior needed to validate the client:

- readable/writable state;
- callable method with return value;
- action/button-driven state changes;
- one signal;
- deterministic scene-tree paths;
- a fixture-only blocking method used to force the process-kill fallback.

The C# suite launches only this C# fixture. GDScript tests continue using GDScript fixtures.

## 15. Failure artifacts

### 15.1 Existing GDScript behavior

Unchanged. `GdUnitE2ETestSuite.after_test()` automatically captures reachable diagnostics on failure, then reaps the child and writes stdout/stderr.

### 15.2 C# behavior

`CaptureFailureArtifactsAsync(outputDirectory)` writes independent best-effort artifacts:

```text
screenshot.png
scene_tree.json
engine_logs.json
stdout.log        # when child has exited
stderr.log        # when child has exited
```

A failed diagnostic request never replaces the caller's primary failure.

`RunAsync()` is the normal C# lifecycle helper. When its body throws, it starts failure capture while the child is reachable, performs teardown, appends process output after exit, and rethrows. This gives ordinary C# assertion failures useful diagnostics without gdUnit4Net lifecycle hooks.

## 16. Testing strategy

### 16.1 Existing GDScript tests

Keep all existing unit/integration/failure-harness tests. Do not rewrite them for C#.

Because every child becomes a Godot .NET child after the project conversion, existing integration helpers must use the product's **10-second** launch default. Remove their current explicit 5-second launch overrides unless a test is intentionally exercising timeout behavior.

### 16.2 C# unit tests

Cover:

- big-endian framing and partial reads;
- oversized declaration rejection before body allocation;
- hello/token and request IDs;
- partial TCP reads, timeout/disconnect, one-in-flight enforcement;
- response/error/log parsing;
- minimal `_t` conversion;
- launch argument construction and project/executable resolution;
- wait-margin forwarding with a recording fake command sender;
- runner smoke without `[RequireGodotRuntime]`.

The wrapper-margin test pins `WaitForPropertyAsync`, `WaitForSignalAsync`, and `ReloadSceneAsync` to use the expected +1 second client deadline. Do not duplicate the GDScript server-side timeout race as another C# integration race.

### 16.3 C# integration tests

All child-launching C# tests use the C# fixture and Godot .NET executable.

Verify:

1. launch + port-file discovery + authenticated hello;
2. C# scene becomes current;
3. property read/write;
4. C# method call and return;
5. input/button behavior;
6. deterministic property wait;
7. signal wait;
8. raw expected negative response;
9. explicit artifact capture;
10. `RunAsync` captures artifacts when a test body throws;
11. graceful disposal reaps the child;
12. cleanup still runs when a test body throws;
13. blocked child uses forced-kill fallback;
14. no surviving `--gdunit-e2e` process.

Do not mirror every existing GDScript integration case.

## 17. CI and build ordering

Keep exactly two jobs:

```text
Linux
Windows
```

Both use Godot .NET 4.5.1 and .NET 8.

Required order per job:

```text
checkout
→ install Godot .NET 4.5.1
→ setup .NET 8
→ resolve GODOT_BIN
→ dotnet build godot-e2e.csproj
→ bootstrap pinned GdUnit4
→ run clean bootstrap/import contract
→ run existing GDScript unit + integration suites
→ run C# unit + C#->C# integration suite
→ run existing intentional-failure harness
→ verify no --gdunit-e2e child survives
→ Linux only: verify release ZIP contents
```

No Godot process should run in CI before the root game assembly has been built.

The clean bootstrap test copies committed source to a fresh temp directory with `git archive HEAD`. Because root build outputs are not part of that archive, `tests/scripts/bootstrap_gdunit4_import_test.sh` must also run:

```bash
dotnet build "$TEST_ROOT/godot-e2e.csproj"
```

inside the temporary copy **before** invoking the Godot .NET editor there.

Linux uses Xvfb for child-launching suites.

## 18. Installation and packaging

One release artifact remains:

```text
addons/gdunit_e2e/**
README.md
LICENSE
NOTICE
```

No NuGet publication is required.

### GDScript users

```text
install GdUnit4
install/copy addons/gdunit_e2e
write GDScript E2E tests
run through GdUnit4
```

### C# users

```text
use a Godot .NET project
install/copy addons/gdunit_e2e
create/use a C# gdUnit4Net test project
reference addons/gdunit_e2e/csharp/GodotE2E.Client.csproj
write tests using E2EGame.RunAsync
run dotnet test
```

The consumer test project owns gdUnit4Net package references; the client library does not.

## 19. Compatibility policy

Support means only:

```text
GDScript test -> GDScript game
C# test       -> C# game
```

Cross-language behavior may work incidentally because the server acts on generic Godot nodes, but do not add compatibility tests, documentation promises, or architecture for it in this release.

## 20. Risks

### Risk 1: gdUnit4Net versus Godot 4.5.1 dependency graph

`gdUnit4.api` may target a different GodotSharp package than the root game project.

Mitigation: `GodotE2E.Client` and `GodotE2E.Tests` do not reference the game project; the test project's transitive GodotSharp dependency remains isolated.

### Risk 2: Windows process/stdout behavior

Native .NET `Process` semantics differ from GDScript but can still deadlock if redirected pipes are not drained.

Mitigation: start `ReadToEndAsync` immediately for stdout and stderr and verify graceful + forced exit on Linux and Windows.

### Risk 3: Godot .NET cold-start cost versus old 5-second integration deadlines

The repository currently launches the standard editor and several integration helpers override the 10-second product default with 5 seconds. Switching every child to Godot .NET adds restore/JIT/assembly-load cost, especially on hosted Windows runners.

Mitigation: build before any Godot process, build again inside the clean archived fixture, and remove the non-semantic 5-second integration overrides so ordinary launches use the 10-second product default.

### Risk 4: C# facade grows into a duplicate framework

Mirroring every GDScript convenience method would double maintenance without demonstrated call sites.

Mitigation: keep the wrapper subset in §9.3 and use `SendCommandAsync()` for the rest.

## 21. Acceptance criteria

The change is accepted when:

- all existing GDScript public APIs remain unchanged;
- `project.godot` declares Godot 4.5 C# + GL Compatibility and `project/assembly_name="GodotE2E"`;
- `godot-e2e.csproj` uses Godot.NET.Sdk 4.5.1, assembly `GodotE2E`, and excludes both `tests/csharp/**/*.cs` and `addons/gdunit_e2e/csharp/**/*.cs`;
- `godot-e2e.sln` contains only the root game project;
- the imported C# fixture has a committed `Main.cs.uid`;
- existing GDScript child-launching integration tests use the 10-second product launch default unless testing timeout behavior;
- a gdUnit4Net C# test launches the C# fixture as a real separate Godot .NET process;
- normal C# E2E tests run without `[RequireGodotRuntime]`;
- the BCL client has no package dependency on GodotSharp or gdUnit4Net;
- protocol framing, hello/token, IDs, error/log handling, and required serializer behavior match v1;
- C# wait wrappers have unit coverage proving the +1 second transport margin;
- representative property, method, input, wait, signal, scene-reload, raw-command, and artifact flows work against the C# fixture;
- normal first-party C# tests/README use `RunAsync`, and a thrown test body produces reachable diagnostics before teardown;
- `DisposeAsync` reaps normal children and force-kills a blocked child when necessary;
- no C# or GDScript E2E child survives its test path;
- CI builds the root C# game before the first Godot process and the clean-bootstrap temp copy builds its own assembly before import;
- Linux and Windows CI run both supported same-language paths using Godot .NET 4.5.1;
- the release ZIP contains `addons/gdunit_e2e/csharp/**` and excludes repository tests, root `.csproj`/`.sln`, GdUnit4, reports, and test output;
- README makes no cross-language support claim.

## 22. Deferred follow-ups

Only consider these after the same-language C# path is useful:

1. Cross-language compatibility fixtures/support.
2. NuGet publication for `GodotE2E.Client`.
3. More Godot Variant stand-ins driven by real usage.
4. Automatic renamed-addon discovery for the C# bootstrap path.
5. Process reuse, pooling, or parallel sessions.
6. Richer trace/diagnostic/editor UX.
