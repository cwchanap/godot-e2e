# C# E2E Integration Design

**Status:** Ready for review  
**Date:** 2026-08-27  
**Repository:** `cwchanap/godot-e2e`  
**Base contract:** `docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md`

## 1. Summary

Add a native C# authoring path to `godot-e2e` without changing the existing GDScript path or creating a second child automation server.

The supported language matrix becomes deliberately narrow:

| Test language | Game language | Support |
| --- | --- | --- |
| GDScript | GDScript | Existing and supported |
| C# | C# | New and supported |
| GDScript | C# | Not supported or tested |
| C# | GDScript | Not supported or tested |

C# tests run through gdUnit4Net/VSTest as ordinary async .NET tests. They launch the same Godot project as a separate **Godot .NET** child process and drive it over the existing authenticated localhost protocol.

The child continues to use the existing addon-owned GDScript bootstrap, automation server, command handler, protocol framing, serializer contract, diagnostics, and orphan watchdog. C# only adds a second parent-side client/process facade.

This document amends the base design only for C# support. All existing GDScript contracts remain authoritative unless explicitly changed here.

## 2. Goals

The C# integration must:

1. Let a C# gdUnit4Net test launch a separate Godot .NET child process for the same project.
2. Let that test drive a C# game scene through the existing protocol v1 command surface.
3. Keep the existing GDScript test-to-GDScript game path unchanged.
4. Reuse the existing GDScript child bootstrap and automation server.
5. Keep the C# transport/process library independent of gdUnit4Net internals and independent of the Godot runtime.
6. Use idiomatic .NET async APIs and deterministic `IAsyncDisposable` cleanup.
7. Preserve the existing localhost-only token handshake, frame cap, serializer tags, command names, response shapes, and child orphan watchdog.
8. Validate C# child launch and cleanup on Linux and Windows CI.
9. Ship the C# client with the same addon/release artifact.
10. Deliver design, plan, implementation, tests, and documentation in one feature PR.

## 3. Non-goals

This change will not:

- support or test GDScript tests against C# game scenes;
- support or test C# tests against GDScript game scenes;
- port the automation server, command handler, bootstrap, or protocol implementation to C#;
- create protocol v2 or alter protocol v1;
- replace gdUnit4Net discovery, assertions, VSTest integration, or reporting;
- add a custom C# test runner;
- require `[RequireGodotRuntime]` for normal C# E2E tests;
- publish a NuGet package in the first C# release;
- add a generic RPC framework or generated protocol bindings;
- add parallel requests, multiple simultaneous sessions, a process pool, or suite-level child reuse;
- add a second CI OS/version matrix;
- guarantee renamed addon-directory discovery from the C# launcher in the first release;
- automatically capture artifacts for arbitrary gdUnit4Net assertion failures in the first release.

## 4. Product boundary

### 4.1 GDScript path

The existing path remains unchanged:

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

No C# work should refactor this path merely to share parent-side implementation.

### 4.2 C# path

The new path is:

```text
C# gdUnit4Net / VSTest test process
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

The C# parent does not need to be a Godot process. It only needs standard .NET process, socket, JSON, file, and timing APIs.

This is intentional: `godot-e2e` is testing the real second Godot process, so spinning up another Godot runtime just to host the C# test harness adds cost without improving coverage.

## 5. Why the C# client is separate

The existing GDScript parent implementation is coupled to GdUnit4 lifecycle helpers:

- `E2EProcess` owns a `GdUnitTestSuite` and uses its temp-directory and await helpers;
- `GdUnitE2EGame` maps remote failures into the suite's `fail()` state;
- `GdUnitE2ETestSuite` owns automatic teardown and failure-artifact policy.

Trying to invoke those classes dynamically from C# would retain the same coupling while adding cross-language async and lifecycle complexity.

The C# implementation therefore reuses the **wire contract and child runtime**, not the GDScript parent implementation.

The duplicate code is limited to the small client/process boundary where the two languages have materially different standard libraries and test lifecycles.

## 6. Repository layout

Add:

```text
addons/gdunit_e2e/
└── csharp/
    ├── GodotE2E.Client.csproj
    ├── E2EProtocol.cs
    ├── E2EResult.cs
    ├── E2EException.cs
    ├── E2ELaunchOptions.cs
    ├── E2EClient.cs
    ├── E2EProcess.cs
    └── E2EGame.cs

# Godot .NET project used by the repository fixture
godot-e2e.csproj

tests/
├── fixtures/
│   └── csharp/
│       ├── main.tscn
│       └── Main.cs
└── csharp/
    ├── GodotE2E.Tests.csproj
    ├── ProtocolTest.cs
    ├── ClientTest.cs
    ├── ProcessLifecycleTest.cs
    └── GameplaySmokeTest.cs
```

The exact test file split may stay smaller if multiple cases fit cleanly in one suite. Do not create one class/file per protocol command.

### 6.1 Pure .NET client project

`addons/gdunit_e2e/csharp/GodotE2E.Client.csproj` targets .NET 8 and has no dependency on:

- GodotSharp;
- gdUnit4Net;
- GdUnit4 GDScript;
- any third-party networking or JSON package.

It uses the .NET BCL only.

The C# test project references this client project and the gdUnit4Net packages used for discovery/assertions. It does not reference the Godot game project because E2E tests intentionally treat the game as a black box.

This separation also avoids coupling the C# test harness to whichever GodotSharp version gdUnit4Net itself currently targets.

### 6.2 Root Godot project compile boundary

The new root `godot-e2e.csproj` is the Godot .NET game/fixture project. Its normal recursive C# compile must include `tests/fixtures/csharp/Main.cs`, but explicitly exclude:

```text
tests/csharp/**/*.cs
```

Those test sources depend on gdUnit4Net and belong only to `GodotE2E.Tests.csproj`; letting the root Godot project compile them would incorrectly force test-runner packages into the game assembly.

The pure client sources under `addons/gdunit_e2e/csharp/**` may also compile into the Godot project assembly because they are BCL-only. This is harmless and avoids requiring consumer projects to edit their root `.csproj` simply to install the addon.

## 7. C# test runner integration

C# E2E tests use gdUnit4Net/VSTest conventions such as:

```csharp
[TestSuite]
public class MainE2ETest
{
    [TestCase]
    public async Task MainIsReady()
    {
        await using var game = await E2EGame.LaunchAsync(new E2ELaunchOptions
        {
            ScenePath = "res://tests/fixtures/csharp/main.tscn",
        });

        var status = await game.GetPropertyAsync<string>(
            "/root/Main/Status",
            "text"
        );

        AssertThat(status).IsEqual("ready");
    }
}
```

Normal E2E tests must not require `[RequireGodotRuntime]` because the test process does not instantiate Godot objects. The child game process is the runtime under test.

gdUnit4Net is the supported/recommended C# test runner for this repository, but `GodotE2E.Client` does not reference gdUnit4Net. That keeps the addon client usable from the VSTest process without binding its lifecycle to framework internals.

## 8. Public C# API

Keep the first API intentionally small and aligned with the existing GDScript concepts.

### 8.1 `E2ELaunchOptions`

Required/primary fields:

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
- `ProjectPath`: auto-detect by walking upward for `project.godot` from the test working/base directory, with explicit override available;
- `GodotPath`: `GODOT_BIN` if set, otherwise `godot` and let the OS resolve `PATH`;
- `Timeout`: preserve the existing launch-timeout default;
- `LogVerbosity`: preserve the existing server default;
- `ServerPort`: `0`;
- `BootstrapScenePath`: `res://addons/gdunit_e2e/runtime/bootstrap.tscn`.

The bootstrap path is overridable, but automatic renamed-addon discovery is not required in the first C# version. The release/install path remains the documented default.

### 8.2 `E2EResult`

Raw command operations return a result with the same conceptual fields as GDScript:

```text
Success
Value / raw JSON response
Message
Logs where available
```

Do not invent a new error taxonomy. Presence of the existing protocol `error` field means failure.

### 8.3 `E2EGame`

Initial wrapped surface:

Inspection:

- `NodeExistsAsync`
- `GetPropertyAsync<T>`
- `SetPropertyAsync`
- `CallMethodAsync<T>`
- `GetTreeAsync`
- `GetSceneAsync`

Interaction:

- `InputActionAsync`
- `PressActionAsync`
- `InputKeyAsync`
- `InputMouseButtonAsync`
- `ClickNodeAsync`

Synchronization:

- `WaitProcessFramesAsync`
- `WaitPhysicsFramesAsync`
- `WaitSecondsAsync`
- `WaitForNodeAsync`
- `WaitForPropertyAsync`
- `WaitForSignalAsync`

Scene/diagnostic:

- `ChangeSceneAsync`
- `ReloadSceneAsync`
- `ScreenshotAsync`
- `CaptureFailureArtifactsAsync`
- `SendCommandAsync` as the raw escape hatch

If implementation shows some convenience wrappers add significant conversion complexity and are not needed by acceptance tests, keep `SendCommandAsync` and defer those wrappers. Protocol access is more important than nominal API parity. `CaptureFailureArtifactsAsync` is not optional because it is the supported explicit diagnostic path for C# tests.

## 9. Failure model

C# uses exceptions for wrapped remote-operation failures.

```text
wrapped method
→ protocol/remote failure
→ throw E2EException
→ gdUnit4Net/VSTest reports the exception as a failed test
```

`SendCommandAsync()` is the exception to this rule: it returns `E2EResult` so negative-path/protocol tests can inspect expected failures without failing the test automatically.

This replaces the GDScript-specific pattern where wrapped failures call `suite.fail()` and execution must explicitly check `is_failure()`.

Do not create a C# `GdUnitE2ETestSuite` merely to emulate that behavior.

## 10. Process ownership and cleanup

`E2EGame` implements `IAsyncDisposable` and owns one `E2EProcess`.

The supported test usage is:

```csharp
await using var game = await E2EGame.LaunchAsync(...);
```

This guarantees that cleanup is attempted when:

- the test succeeds;
- a gdUnit assertion throws;
- an E2E wrapper throws;
- unrelated test code throws.

The first version does not attempt to recover from a test process that is externally killed; the existing authenticated-peer child orphan watchdog remains the abnormal-parent-loss safety net.

### 10.1 Launch

Use standard .NET APIs:

```text
resolve project + Godot executable
→ create token and temp port-file path
→ Process.Start with redirected stdout/stderr
→ launch existing bootstrap scene
→ asynchronously drain stdout and stderr
→ poll child exit + port file until bounded deadline
→ connect TcpClient to 127.0.0.1:<port>
→ send protocol-v1 hello token
→ return E2EGame
```

Pass the same E2E user arguments used by the GDScript launcher:

```text
--gdunit-e2e
--gdunit-e2e-target-scene=<scene>
--gdunit-e2e-port=0
--gdunit-e2e-port-file=<path>
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=<level>
```

### 10.2 Shutdown

```text
best-effort quit command when authenticated
→ close TCP client
→ bounded wait for Process exit
→ Process.Kill(entireProcessTree: true) if still alive
→ bounded wait for confirmed exit
→ finish stdout/stderr drains
→ delete temp port file best effort
```

`DisposeAsync()` is idempotent. If it cannot confirm that an owned child exited, it throws `E2EException`; standard C# `await using` exception semantics apply if disposal itself fails while another exception is unwinding.

Do not silently leave an owned child alive.

## 11. Protocol compatibility

The C# client implements the existing protocol v1 exactly enough to interoperate with the unchanged GDScript automation server.

Required invariants:

- four-byte unsigned big-endian frame length;
- UTF-8 JSON body;
- `16 * 1024 * 1024` frame cap;
- first command is `hello` with token and `protocol_version = 1`;
- monotonically increasing request IDs for the session;
- one in-flight request in the first version;
- existing command names and request keys;
- existing command-specific response shapes;
- existing `error` semantics;
- existing timeout margin for server-side waits;
- no host parameter: client connects to `127.0.0.1` only.

No server changes should be necessary solely to make the C# client work.

## 12. Variant/JSON conversion

The server's existing `_t` serializer tags remain the protocol contract.

The C# client must decode the values required by the supported wrapper surface and C# fixture tests. Primitive JSON values and containers use ordinary .NET types/`JsonElement` conversion.

For Godot-specific tagged values, use small client-side value records/structs rather than referencing GodotSharp. For example:

```text
v2  -> E2EVector2
v2i -> E2EVector2I
v3  -> E2EVector3
v3i -> E2EVector3I
r2  -> E2ERect2
r2i -> E2ERect2I
col -> E2EColor
```

Only add tags exercised by the public API/tests or needed for compatibility with existing serializer behavior. Do not recreate the full Godot Variant type system preemptively.

Raw `SendCommandAsync()` must preserve access to the underlying JSON for unsupported/custom shapes.

## 13. C# fixture

The repository becomes a Godot .NET-capable project by adding the minimal root C# project file required by Godot 4.5.1 .NET.

Add one dedicated C# fixture scene with a C# root script. It should expose enough behavior to verify the E2E client rather than attempting to mirror every GDScript fixture feature.

Minimum fixture behavior:

- readable/writable property;
- callable method with a return value;
- button or action-driven state change;
- one signal;
- deterministic scene-tree paths;
- optional second scene only if needed to validate scene changes.

The C# test suite launches only C# fixture/game scenes. Cross-language fixture reuse is explicitly outside the acceptance matrix.

## 14. Failure artifacts

The GDScript path keeps its current automatic `after_test()` artifact behavior unchanged.

The C# first release provides an explicit diagnostic path:

```text
await game.CaptureFailureArtifactsAsync(...)
```

It uses the existing screenshot, scene-tree, and collected-log command paths and writes independent best-effort artifacts. Child stdout/stderr remain available from process diagnostics and are included when the process has exited.

Automatic artifact capture after an arbitrary gdUnit4Net assertion failure is not part of this release. Wrapped E2E methods do not add hidden runner hooks or reflection to detect framework failure state before throwing.

## 15. Testing strategy

### 15.1 Existing GDScript tests

Keep all existing GDScript unit/integration/failure-harness tests running. C# support must not require rewriting them.

### 15.2 C# unit tests

Use the C# test project for focused tests of:

- big-endian framing;
- partial frame assembly;
- oversized frame rejection;
- request ID sequencing;
- hello/token request shape;
- timeout/disconnect behavior;
- one-in-flight enforcement;
- representative response/error parsing;
- serializer conversion for the tags actually used;
- launch argument construction;
- executable/project resolution;
- explicit artifact-path behavior;
- idempotent disposal with fakes where useful.

Do not duplicate exhaustive command-handler tests already owned by the GDScript/server suite.

### 15.3 C# integration tests

All child-launching C# tests use the C# fixture and Godot .NET executable.

Verify at least:

1. launch + port-file discovery + authenticated hello;
2. real C# scene becomes current;
3. node/property read and write;
4. C# method call and return value;
5. input/button behavior;
6. one deterministic server wait;
7. one signal wait;
8. raw expected negative response;
9. explicit failure-artifact capture produces the reachable artifacts;
10. graceful `DisposeAsync()` reaps the child;
11. an exception/assertion escaping an `await using` body still attempts cleanup and leaves no child;
12. forced cleanup of a child that does not exit gracefully;
13. no surviving `--gdunit-e2e` process after the C# suite/harness.

Do not add mirrored C# integration tests for every existing GDScript integration case.

## 16. CI

Keep the existing two jobs:

```text
Linux
Windows
```

Do not add a separate `csharp × OS` matrix.

Switch the installed Godot executable in both jobs from the standard build to the Godot .NET 4.5.1 build. That executable runs both GDScript and C# projects, so the same job can validate both paths.

Per job:

```text
checkout
→ install Godot .NET 4.5.1
→ setup required .NET SDK
→ bootstrap pinned GdUnit4 GDScript addon
→ existing bootstrap/import contract check
→ dotnet build the Godot project / C# fixture
→ existing GDScript unit + integration suites
→ C# unit + C#→C# integration suite with dotnet test
→ existing intentional-failure artifact harness
→ surviving --gdunit-e2e process check
```

Linux keeps Xvfb for child game processes where required.

The implementation plan must pin the exact gdUnit4Net package versions after verifying they restore and run in the separate pure-.NET test project. The C# client itself must not inherit that compatibility constraint.

## 17. Installation and packaging

The existing release artifact remains one package containing:

```text
addons/gdunit_e2e/**
README.md
LICENSE
NOTICE
```

The C# client project/sources live under `addons/gdunit_e2e/csharp/**` and are therefore included automatically.

No NuGet publication is required for this change.

### 17.1 GDScript user path

Unchanged:

```text
install GdUnit4
install/copy addons/gdunit_e2e
write GDScript E2E tests
run through GdUnit4
```

### 17.2 C# user path

Document a separate path:

```text
use a Godot .NET project
install/copy addons/gdunit_e2e
create/use a C# gdUnit4Net test project
reference addons/gdunit_e2e/csharp/GodotE2E.Client.csproj
write C# E2E tests with await using
run dotnet test
```

The exact gdUnit4Net package references belong to the consumer test project, not the addon client project.

## 18. Compatibility policy

For this first C# release, support means:

```text
GDScript test -> GDScript game
C# test       -> C# game
```

The implementation may technically work across languages because the server acts on generic Godot nodes, but that behavior is incidental. Do not add tests, documentation promises, compatibility fixes, or architecture solely for:

```text
GDScript test -> C# game
C# test       -> GDScript game
```

If a future real use case needs cross-language support, it can be enabled by adding explicit compatibility fixtures/tests rather than by changing protocol architecture now.

## 19. Risks

### Risk 1: gdUnit4Net version versus Godot 4.5.1

The latest gdUnit4Net release/documentation may target a different GodotSharp version than the game project.

Mitigation: the E2E client and C# test project do not reference the Godot game project or GodotSharp. They run in lightweight .NET mode and only launch the Godot .NET child externally. Pin the exact working gdUnit4Net package version in repository tests after verification.

### Risk 2: Windows process/stdout behavior

The existing GDScript path already found platform-specific pipe pressure and termination issues. Native .NET `Process` APIs have different behavior but still require asynchronous stdout/stderr drains and bounded cleanup.

Mitigation: keep Linux + Windows process integration coverage and explicitly test graceful and forced exit.

### Risk 3: C# client grows into a duplicate framework

Mirroring every GDScript helper or exposing every server command could double maintenance.

Mitigation: keep `SendCommandAsync()` as the compatibility escape hatch and add convenience wrappers only for commonly used/tested operations.

## 20. Acceptance criteria

The C# integration is accepted when:

- all existing GDScript tests continue to pass without public API changes;
- the repository builds as a Godot 4.5.1 .NET project with the dedicated C# fixture;
- the root Godot project excludes `tests/csharp/**/*.cs` while compiling the C# fixture;
- a gdUnit4Net C# test can launch that C# fixture as a real second Godot .NET process;
- normal C# E2E tests run without requiring a Godot runtime in the VSTest parent process;
- the C# client connects only to `127.0.0.1` and performs the existing token hello;
- framing, frame cap, request IDs, response/error interpretation, wait timeout margin, and required serializer tags match protocol v1;
- representative property, method, input, wait, signal, scene, raw-command, and explicit-artifact operations work against the C# fixture;
- `await using` cleanup reaps the child when the test succeeds or throws;
- forced cleanup does not leave a surviving child;
- existing child orphan-watchdog behavior remains unchanged;
- Linux and Windows CI run both the existing GDScript suite and new C# suite using Godot .NET;
- the release archive still contains one addon plus README/LICENSE/NOTICE;
- README documents separate GDScript and C# usage paths;
- no acceptance test or documentation claim is added for either cross-language combination.

## 21. Deferred follow-ups

Only consider these after the same-language C# path is useful:

1. Cross-language compatibility fixtures/support.
2. NuGet publication for `GodotE2E.Client`.
3. Automatic gdUnit4Net assertion-failure artifact hooks if a stable public lifecycle seam is available.
4. More Variant tag wrappers driven by real usage.
5. Process reuse, pooling, or parallel sessions.
6. Richer trace/diagnostic UX.
