# C# E2E Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native `C# test -> C# game` E2E path while leaving the existing `GDScript test -> GDScript game` path unchanged.

**Architecture:** Keep the existing GDScript bootstrap, automation server, command handler, serializer, protocol v1, diagnostics, and orphan watchdog as the only child runtime. Add a BCL-only .NET 8 parent client using `TcpClient`, `System.Text.Json`, and `System.Diagnostics.Process`; gdUnit4Net/VSTest runs the C# tests as ordinary .NET tests without `[RequireGodotRuntime]` and launches the Godot .NET game as the real child process.

**Tech Stack:** Godot .NET 4.5.1, .NET 8 / C# 12, gdUnit4.api 5.0.0, gdUnit4.test.adapter 3.0.0, gdUnit4.analyzers 1.0.0, Microsoft.NET.Test.Sdk 17.14.1, localhost TCP protocol v1, GitHub Actions, Xvfb on Linux.

**Spec:** `docs/superpowers/specs/2026-08-27-csharp-e2e-integration-design.md`

## Global Constraints

- One feature PR for design, plan, implementation, tests, CI, and docs; use task-level commits inside that PR.
- Supported matrix is only `GDScript test -> GDScript game` and `C# test -> C# game`.
- Do not add tests, documentation promises, compatibility fixes, or architecture for either cross-language combination.
- Do not refactor the existing GDScript parent merely to share code with C#.
- Reuse the existing GDScript child bootstrap/server/command handler and protocol v1 unchanged unless implementation exposes a real compatibility bug.
- `GodotE2E.Client` targets `net8.0` and uses only the .NET BCL: no GodotSharp, gdUnit4Net, third-party socket, or third-party JSON package.
- Repository C# tests use gdUnit4Net/VSTest but never reference the root Godot game project.
- Pin test packages to `gdUnit4.api` 5.0.0, `gdUnit4.test.adapter` 3.0.0, `gdUnit4.analyzers` 1.0.0, and `Microsoft.NET.Test.Sdk` 17.14.1.
- Root Godot project is `GodotE2E.csproj` using `Godot.NET.Sdk/4.5.1`, targeting `net8.0`; do not set a custom `<AssemblyName>` on Godot 4.5.
- Root game compile excludes `tests/csharp/**/*.cs` and `addons/gdunit_e2e/csharp/**/*.cs`.
- Normal C# E2E tests must not use `[RequireGodotRuntime]`.
- Protocol invariants: four-byte unsigned big-endian framing, protocol version 1, 16 MiB frame cap, `127.0.0.1` only, token hello, monotonically increasing IDs, one in-flight command.
- Launch timeout default is 10 seconds; ordinary command timeout is 5 seconds; server waits/reload add a 1-second client margin.
- Continuously drain child stdout/stderr and retain only the newest 4 MiB per stream.
- One child per `E2EGame`; no pool, process reuse, parallel sessions, generic RPC layer, generated bindings, or NuGet publication.
- `DisposeAsync` is strict when no earlier test-body failure exists; `RunAsync` must preserve an earlier body/assertion exception as primary when teardown also fails.
- Unsupported Godot `_t` tags fail loudly from typed conversion; use `SendCommandAsync` for raw unsupported values.
- Linux + Windows remain the only CI platforms; no new C# matrix.
- Release remains one archive containing `addons/gdunit_e2e/**`, `README.md`, `LICENSE`, and `NOTICE`.
- RED -> GREEN -> REFACTOR for behavior tasks.

## Planned File Structure

```text
.
├── project.godot
├── GodotE2E.csproj
├── GodotE2E.sln
├── .github/workflows/ci.yml
├── README.md
├── addons/gdunit_e2e/
│   ├── client/                         # existing GDScript parent, unchanged
│   ├── protocol/                       # existing GDScript protocol
│   ├── runtime/                        # existing child bootstrap
│   ├── server/                         # existing child server
│   └── csharp/
│       ├── .gdignore
│       ├── GodotE2E.Client.csproj
│       ├── AssemblyInfo.cs
│       ├── E2EProtocol.cs
│       ├── E2EFraming.cs
│       ├── E2EJson.cs
│       ├── E2EValueTypes.cs
│       ├── E2EResult.cs
│       ├── E2EException.cs
│       ├── E2EClient.cs
│       ├── E2ELaunchOptions.cs
│       ├── E2EProcess.cs
│       └── E2EGame.cs
├── tests/fixtures/csharp/
│   ├── Main.cs
│   ├── Main.cs.uid
│   └── main.tscn
├── tests/csharp/
│   ├── GodotE2E.Tests.csproj
│   ├── TestPaths.cs
│   ├── RunnerSmokeTest.cs
│   ├── ProtocolTest.cs
│   ├── ClientTest.cs
│   ├── GameApiTest.cs
│   ├── ProcessLifecycleTest.cs
│   ├── GameplaySmokeTest.cs
│   ├── FakeProtocolServer.cs
│   └── TestProject.cs
└── tests/scripts/
    ├── bootstrap_gdunit4_import_test.sh
    ├── assert_no_e2e_children.sh
    └── package_release_test.sh
```

Framing owns bytes, `E2EClient` owns one TCP session, `E2EProcess` owns one OS child, and `E2EGame` owns the public convenience/lifecycle API.

---

### Task 1: Pin and prove the isolated C# runner and client project

**Files:**
- Create: `addons/gdunit_e2e/csharp/.gdignore`
- Create: `addons/gdunit_e2e/csharp/GodotE2E.Client.csproj`
- Create: `addons/gdunit_e2e/csharp/AssemblyInfo.cs`
- Create: `tests/csharp/GodotE2E.Tests.csproj`
- Create: `tests/csharp/TestPaths.cs`
- Create: `tests/csharp/RunnerSmokeTest.cs`
- Modify: `.gitignore`

**Interfaces:**
- Produces a pure `net8.0` `GodotE2E.Client` project.
- Produces an internal-test visibility seam through `InternalsVisibleTo("GodotE2E.Tests")`.
- Produces `TestPaths.RepositoryRoot` for source-contract tests and integration helpers.
- Produces `dotnet test tests/csharp/GodotE2E.Tests.csproj` without starting Godot.

- [ ] **Step 1: Add the BCL-only client project and keep it out of Godot resource scanning**

Create an empty `addons/gdunit_e2e/csharp/.gdignore` and:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <LangVersion>12.0</LangVersion>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>GodotE2E</RootNamespace>
  </PropertyGroup>
</Project>
```

Create `AssemblyInfo.cs`:

```csharp
using System.Runtime.CompilerServices;
[assembly: InternalsVisibleTo("GodotE2E.Tests")]
```

- [ ] **Step 2: Add the isolated gdUnit4Net test project with exact pins**

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <LangVersion>12.0</LangVersion>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <IsTestProject>true</IsTestProject>
    <RootNamespace>GodotE2E.Tests</RootNamespace>
  </PropertyGroup>

  <ItemGroup>
    <ProjectReference Include="../../addons/gdunit_e2e/csharp/GodotE2E.Client.csproj" />
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
    <PackageReference Include="gdUnit4.api" Version="5.0.0" />
    <PackageReference Include="gdUnit4.test.adapter" Version="3.0.0" PrivateAssets="all" />
    <PackageReference Include="gdUnit4.analyzers" Version="1.0.0">
      <PrivateAssets>all</PrivateAssets>
      <IncludeAssets>runtime; build; native; contentfiles; analyzers; buildtransitive</IncludeAssets>
    </PackageReference>
  </ItemGroup>
</Project>
```

Do not add a direct GodotSharp reference and do not reference `GodotE2E.csproj`.

- [ ] **Step 3: Add the reusable repository-root locator**

```csharp
namespace GodotE2E.Tests;

internal static class TestPaths
{
    public static string RepositoryRoot { get; } = FindRepositoryRoot();

    private static string FindRepositoryRoot()
    {
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            var current = new DirectoryInfo(Path.GetFullPath(start));
            while (current is not null)
            {
                if (File.Exists(Path.Combine(current.FullName, "project.godot")))
                    return current.FullName;
                current = current.Parent;
            }
        }
        throw new InvalidOperationException("Unable to locate godot-e2e repository root");
    }
}
```

- [ ] **Step 4: Add a runner-only test with no Godot runtime attribute**

```csharp
namespace GodotE2E.Tests;

using GdUnit4;
using static GdUnit4.Assertions;

[TestSuite]
public sealed class RunnerSmokeTest
{
    [TestCase]
    public void RunsWithoutGodotRuntime() => AssertThat(1).IsEqual(1);
}
```

- [ ] **Step 5: Ignore managed build/test output**

Append:

```gitignore
bin/
obj/
TestResults/
```

- [ ] **Step 6: Restore, run, and prove the client has no packages**

```bash
dotnet restore tests/csharp/GodotE2E.Tests.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --no-restore --filter "FullyQualifiedName~RunnerSmokeTest"
dotnet list addons/gdunit_e2e/csharp/GodotE2E.Client.csproj package
```

Expected: one passing test; client reports no package references.

- [ ] **Step 7: Commit**

```bash
git add .gitignore addons/gdunit_e2e/csharp tests/csharp
git commit -m "test: bootstrap csharp e2e runner"
```

---

### Task 2: Convert the repository to a real Godot .NET project and add the C# fixture

**Files:**
- Modify: `project.godot`
- Create: `GodotE2E.csproj`
- Create: `GodotE2E.sln`
- Create: `tests/fixtures/csharp/Main.cs`
- Create: `tests/fixtures/csharp/main.tscn`
- Create after Godot import: `tests/fixtures/csharp/Main.cs.uid`
- Modify: `tests/integration/gameplay_smoke_test.gd`
- Modify: `tests/integration/process_lifecycle_test.gd`
- Modify: `tests/integration/server_startup_test.gd`

**Interfaces:**
- Produces Godot project assembly identity `GodotE2E` through `project.godot` + matching project/solution filenames, not a custom `<AssemblyName>`.
- Produces C# scene `res://tests/fixtures/csharp/main.tscn` rooted at `/root/Main`.
- Produces `Echo(string)`, `SchedulePulse(double)`, `BlockMainThread(int)`, signal `Pulse`, and properties `ActionCount`/`ActionPressed`.
- Ordinary GDScript integration launches use the existing 10-second product default.

- [ ] **Step 1: Add Godot C# project metadata and root project**

Add the C# feature and:

```ini
[dotnet]

project/assembly_name="GodotE2E"
```

Keep GL Compatibility.

Create `GodotE2E.csproj`:

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

Do **not** add `<AssemblyName>`; Godot 4.5 can misresolve C# scripts when it is overridden.

Create the solution with only the game project:

```bash
dotnet new sln -n GodotE2E
dotnet sln GodotE2E.sln add GodotE2E.csproj
```

- [ ] **Step 2: Add the C# fixture script**

```csharp
using Godot;
using System.Threading;

public partial class Main : Node2D
{
    [Signal]
    public delegate void PulseEventHandler(string value);

    [Export]
    public int ActionCount { get; set; }

    [Export]
    public bool ActionPressed { get; set; }

    public override void _Ready()
    {
        GetNode<Button>("Button").Pressed += () =>
            GetNode<Label>("ClickStatus").Text = "clicked";
    }

    public override void _UnhandledInput(InputEvent @event)
    {
        if (@event.IsActionPressed("ui_accept"))
        {
            ActionCount += 1;
            ActionPressed = true;
            GetNode<Label>("Status").Text = $"accepted:{ActionCount}";
        }
        else if (@event.IsActionReleased("ui_accept"))
        {
            ActionPressed = false;
        }
    }

    public string Echo(string value) => $"csharp:{value}";

    public void SchedulePulse(double delaySeconds)
    {
        GetTree().CreateTimer(delaySeconds).Timeout += () =>
            EmitSignal(SignalName.Pulse, "pulse");
    }

    public int BlockMainThread(int milliseconds)
    {
        Thread.Sleep(milliseconds);
        return milliseconds;
    }
}
```

- [ ] **Step 3: Add the fixture scene with stable paths**

```text
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/fixtures/csharp/Main.cs" id="1_main"]

[node name="Main" type="Node2D"]
script = ExtResource("1_main")

[node name="Status" type="Label" parent="."]
offset_left = 24.0
offset_top = 24.0
offset_right = 300.0
offset_bottom = 60.0
text = "ready"

[node name="ClickStatus" type="Label" parent="."]
offset_left = 24.0
offset_top = 72.0
offset_right = 300.0
offset_bottom = 108.0
text = "not clicked"

[node name="Button" type="Button" parent="."]
offset_left = 24.0
offset_top = 128.0
offset_right = 184.0
offset_bottom = 176.0
text = "Click"
```

- [ ] **Step 4: Remove only non-semantic 5-second GDScript launch overrides**

Delete ordinary `options.timeout_seconds = 5.0` assignments from:

```text
tests/integration/gameplay_smoke_test.gd
tests/integration/process_lifecycle_test.gd
tests/integration/server_startup_test.gd
```

Keep short values such as invalid-startup `0.25` seconds because they are the behavior under test.

- [ ] **Step 5: Build and import once to generate the C# UID**

```bash
dotnet build GodotE2E.csproj
"${GODOT_BIN:-godot}" --headless --editor --path . --quit
```

Commit generated `tests/fixtures/csharp/Main.cs.uid`; do not commit `.godot/**`.

- [ ] **Step 6: Verify behavior, not file literals**

```bash
dotnet sln GodotE2E.sln list
dotnet build GodotE2E.csproj
test -f tests/fixtures/csharp/Main.cs.uid
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
```

Expected: solution lists only `GodotE2E.csproj`; build and existing GDScript suites pass. Do not add greps or GDScript assertions that merely restate the `project.godot`/`.csproj` strings written in this task.

- [ ] **Step 7: Commit**

```bash
git add project.godot GodotE2E.csproj GodotE2E.sln tests/fixtures/csharp tests/integration
git commit -m "test: add csharp godot fixture"
```

---

### Task 3: Implement framing, minimal typed values, and drift guards

**Files:**
- Create: `addons/gdunit_e2e/csharp/E2EProtocol.cs`
- Create: `addons/gdunit_e2e/csharp/E2EFraming.cs`
- Create: `addons/gdunit_e2e/csharp/E2EJson.cs`
- Create: `addons/gdunit_e2e/csharp/E2EValueTypes.cs`
- Create: `addons/gdunit_e2e/csharp/E2EResult.cs`
- Create: `addons/gdunit_e2e/csharp/E2EException.cs`
- Create: `tests/csharp/ProtocolTest.cs`

**Interfaces:**
- Produces `E2EProtocol.ProtocolVersion = 1`, `MaxFrameBytes = 16 MiB`, `DefaultCommandTimeout = 5s`, `WaitMargin = 1s`, `MaxPipeBytes = 4 MiB`.
- Produces `E2EFraming.Encode(JsonElement)` and `ReadAsync(Stream, CancellationToken)`.
- Produces `E2EJson.NormalizeForWire(object?)` and `Convert<T>(JsonElement)`.
- Produces only `E2EVector2(double X, double Y)` as the first Godot-specific stand-in.
- Unsupported `_t` typed conversion throws and points callers to raw `SendCommandAsync`.

- [ ] **Step 1: Write RED framing/value/drift tests**

Cover framing, partial reads, oversized declaration before body allocation, JSON null, `v2`, unsupported tagged fallback, and protocol drift.

The unsupported-tag test must verify a `v3` payload does not silently deserialize into `E2EVector2`:

```csharp
var wire = JsonSerializer.SerializeToElement(new { _t = "v3", x = 1, y = 2, z = 3 });
var message = "";
try
{
    _ = E2EJson.Convert<E2EVector2>(wire);
}
catch (E2EException exception)
{
    message = exception.Message;
}
AssertThat(message).Contains("Unsupported Godot value tag 'v3'");
```

`ProtocolConstantsMatchGdScriptContract()` reads `addons/gdunit_e2e/protocol/e2e_protocol.gd` and `addons/gdunit_e2e/client/e2e_process.gd` from `TestPaths.RepositoryRoot`. Regex the relevant declarations and assert evaluated values equal the C# constants. This is a deliberate two-implementation drift guard.

- [ ] **Step 2: Run RED tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest"
```

- [ ] **Step 3: Add exact constants and result/exception/value types**

```csharp
public static class E2EProtocol
{
    public const int ProtocolVersion = 1;
    public const uint MaxFrameBytes = 16u * 1024u * 1024u;
    public const int MaxPipeBytes = 4 * 1024 * 1024;
    public static readonly TimeSpan DefaultCommandTimeout = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan WaitMargin = TimeSpan.FromSeconds(1);
}
```

Add `E2EException`, `E2EVector2`, and `E2EResult` with cloned response/log `JsonElement` values.

- [ ] **Step 4: Implement framing with exact reads and allocation guard**

Encode UTF-8 JSON with a four-byte BE prefix. Read exactly four header bytes, reject a declared length above `MaxFrameBytes` before allocating the body, then read/parse the exact body and require an object root.

- [ ] **Step 5: Implement minimal value conversion with loud tagged fallback**

Handle JSON null first; support only `v2 -> E2EVector2`. If an object has `_t` and that tagged conversion is not explicitly supported, throw:

```text
Unsupported Godot value tag '<tag>'; use SendCommandAsync for raw access
```

Only untagged JSON falls through to generic `Deserialize<T>()`.

- [ ] **Step 6: Run GREEN C# protocol + existing GDScript serializer tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest"
./addons/gdUnit4/runtest.sh -a tests/unit/serializer_test.gd -c
```

- [ ] **Step 7: Commit**

```bash
git add addons/gdunit_e2e/csharp tests/csharp/ProtocolTest.cs
git commit -m "feat: add csharp e2e protocol primitives"
```

---

### Task 4: Implement the raw TCP client with one fail-fast in-flight request

**Files:**
- Create: `addons/gdunit_e2e/csharp/E2EClient.cs`
- Create: `addons/gdunit_e2e/csharp/IE2ECommandSender.cs`
- Create: `tests/csharp/FakeProtocolServer.cs`
- Create: `tests/csharp/ClientTest.cs`

**Interfaces:**
- Internal `IE2ECommandSender` exposes raw send + collected logs for facade unit tests.
- `E2EClient.ConnectAsync`, `SendCommandAsync`, `IsSessionOpen`, `CollectedLogs`, idempotent disposal.
- Overlap returns `A command is already in flight` immediately; no queue.

- [ ] **Step 1: Add the loopback fake server**

Use `TcpListener(IPAddress.Loopback, 0)`, `E2EFraming`, scripted response handler, and recorded requests.

- [ ] **Step 2: Write RED client tests**

Cover hello shape/ID, next request ID, normalized parameters, partial reads, error rendering, log stripping/collection, timeout/disconnect, and fail-fast overlap.

- [ ] **Step 3: Run RED client tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ClientTest"
```

- [ ] **Step 4: Implement hello + raw command state**

Use fixed host `127.0.0.1`, monotonic IDs, and `SemaphoreSlim.WaitAsync(0)` as the fail-fast gate.

- [ ] **Step 5: Implement timeout/error/log handling**

Use linked cancellation with `CancelAfter(timeout)`. Raw transport/protocol failures return `E2EResult.Failure`; verify response IDs and clone response/log elements before document disposal.

- [ ] **Step 6: Run GREEN tests and commit**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ClientTest"
git add addons/gdunit_e2e/csharp tests/csharp/FakeProtocolServer.cs tests/csharp/ClientTest.cs
git commit -m "feat: add csharp e2e tcp client"
```

---

### Task 5: Launch, drain, authenticate, and reap the real Godot .NET child

**Files:**
- Create: `addons/gdunit_e2e/csharp/E2ELaunchOptions.cs`
- Create: `addons/gdunit_e2e/csharp/E2EProcess.cs`
- Create: `addons/gdunit_e2e/csharp/E2EGame.cs` (raw session/factory only)
- Create: `tests/csharp/TestProject.cs`
- Create: `tests/csharp/ProcessLifecycleTest.cs`

**Interfaces:**
- `E2ELaunchOptions`: scene/project/Godot path, 10s launch timeout, args, warning verbosity, server port 0, bootstrap path.
- `E2EProcess` owns process, bounded drain tasks, temp port file, authenticated client.
- `E2EGame.LaunchAsync` owns one process and exposes process ID/project path/bounded stdout+stderr/raw send/dispose.

- [ ] **Step 1: Write RED option/argv tests**

Pin `--path`, `--scene`, extra Godot args, `--`, then E2E user flags including `--gdunit-e2e-port=<ServerPort>`. Pin project lookup and `GodotPath -> GODOT_BIN -> PATH` resolution.

- [ ] **Step 2: Run RED lifecycle tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
```

- [ ] **Step 3: Implement process start and truly bounded continuous pipe drains**

Use `ProcessStartInfo.ArgumentList`, `UseShellExecute=false`, redirected stdout/stderr. Immediately drain both `BaseStream`s into fixed-size byte-tail/ring buffers. Consume all OS pipe bytes but retain no more than `E2EProtocol.MaxPipeBytes` per stream. Do not store an unbounded `ReadToEndAsync` string.

- [ ] **Step 4: Implement launch polling and authentication**

Create unique temp dir/port file; poll child exit/valid port until 10s deadline. Reap on early exit or handshake failure; include bounded pipe tails in launch diagnostics.

- [ ] **Step 5: Implement bounded shutdown + kill fallback**

Best-effort quit, client close, <=1s wait, whole-tree kill if needed, <=1s wait again, finish drains, clean temp, throw if death still unconfirmed. Repeated successful disposal is a no-op.

- [ ] **Step 6: Add TestProject helper**

Use `TestPaths.RepositoryRoot`, C# fixture scene, `GODOT_BIN`, 10s timeout, `--quiet`, plus `IsProcessRunning(pid)`.

- [ ] **Step 7: Add first real C# -> C# lifecycle test**

Launch, raw `node_exists("/root/Main")`, dispose, assert PID dead. Add output-load coverage if needed and assert retained diagnostics remain bounded.

- [ ] **Step 8: Build + run GREEN lifecycle tests and commit**

```bash
dotnet build GodotE2E.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
git add addons/gdunit_e2e/csharp tests/csharp/TestProject.cs tests/csharp/ProcessLifecycleTest.cs
git commit -m "feat: launch csharp godot e2e child"
```

---

### Task 6: Add the lean facade, wait-margin seam, failure lifecycle, and artifacts

**Files:**
- Modify: `addons/gdunit_e2e/csharp/E2EGame.cs`
- Modify: `addons/gdunit_e2e/csharp/E2EJson.cs`
- Modify: `tests/fixtures/csharp/Main.cs`
- Create: `tests/csharp/GameApiTest.cs`
- Create: `tests/csharp/GameplaySmokeTest.cs`
- Modify: `tests/csharp/ProcessLifecycleTest.cs`

**Interfaces:**
- Public wrappers: node/property/method/scene, action/press/click, property/signal waits, reload, screenshot, explicit artifacts, raw send.
- No wrappers yet for get_tree, key/mouse-button input, frame/seconds waits, wait_for_node, change_scene.
- `RunAsync` is the normal first-party lifecycle.

- [ ] **Step 1: Write RED facade tests against only the C# fixture**

Use `RunAsync` for normal tests and cover property/method/vector2/action/click/wait/signal/reload/raw-negative flows.

- [ ] **Step 2: Add recording command-sender margin test**

Through internal non-owning `E2EGame`, assert property wait 2.5s -> 3.5s transport, signal wait 1.0s -> 2.0s, reload -> 6.0s. Do not add another real server timing-race test.

- [ ] **Step 3: Run RED facade tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~GameApiTest|FullyQualifiedName~GameplaySmokeTest"
```

- [ ] **Step 4: Implement wrappers through one failure mapper**

Wrapped failures throw `E2EException`; typed results use `E2EJson.Convert<T>`; wait/reload deadlines add `WaitMargin`.

- [ ] **Step 5: Implement explicit artifact capture**

Independently attempt screenshot, raw get_tree, logs, and exited-process pipe tails. Diagnostic failures are best effort and cannot replace caller failures.

- [ ] **Step 6: Implement RunAsync with stable suite/test path and primary-failure precedence**

Signature uses `[CallerMemberName]` + `[CallerFilePath]`. Default directory:

```text
<resolved project>/test_output/csharp/<safe caller-file-name>/<safe testName>/
```

Capture body exception with `ExceptionDispatchInfo`; capture reachable artifacts; retain cleanup exception separately; append bounded pipe diagnostics. If only cleanup fails, throw it. If body already failed, attach cleanup text in `bodyException.Data["GodotE2E.CleanupFailure"]` and diagnostics, then rethrow the original body exception through `ExceptionDispatchInfo`.

- [ ] **Step 7: Add deterministic RunAsync artifact regression**

Test exact path `test_output/csharp/GameplaySmokeTest/RunAsyncCapturesBodyFailureArtifacts/`; no GUID scan/global directory cleanup.

- [ ] **Step 8: Add body-failure cleanup and fixture-only blocked-child kill regressions**

Use `BlockMainThread(5000)` with ~100ms raw command timeout. No production kill toggle.

- [ ] **Step 9: Run GREEN same-language suites and commit**

```bash
dotnet build GodotE2E.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
git add addons/gdunit_e2e/csharp tests/csharp tests/fixtures/csharp/Main.cs
git commit -m "feat: add csharp e2e game facade"
```

---

### Task 7: Restore GDScript-only bootstrap coverage, wire CI, package, and docs

**Files:**
- Modify: `tests/scripts/bootstrap_gdunit4_import_test.sh`
- Create: `tests/scripts/assert_no_e2e_children.sh`
- Create: `tests/scripts/package_release_test.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`

**Interfaces:**
- Keeps one Linux and one Windows job running both supported same-language paths.
- Clean-bootstrap proves shipped addon import in a temporary project with no C# game metadata/fixture.
- README gives separate GDScript/C# setup and requires C# game compile exclusion for client sources.

- [ ] **Step 1: Restore clean bootstrap to GDScript-only consumer shape**

After archive extraction remove `GodotE2E.csproj`, `GodotE2E.sln`, `tests/csharp`, `tests/fixtures/csharp`; keep shipped `addons/gdunit_e2e/csharp/**`. Strip `C#` from temp `config/features` and remove `[dotnet]` section with Git-for-Windows-compatible `sed`/`awk`. Do not build C# in the temp project; continue the existing GdUnit import/class-cache check.

- [ ] **Step 2: Extract duplicated survivor scan**

Create `assert_no_e2e_children.sh` supporting Linux `ps` + Windows PowerShell; fail on surviving `--gdunit-e2e` processes.

- [ ] **Step 3: Add release-package contract**

Verify archive includes C# `.gdignore`, client csproj, facade sources; excludes tests, `GodotE2E.csproj`/`.sln`, and GdUnit4.

- [ ] **Step 4: Switch existing jobs to Godot .NET 4.5.1 + .NET 8**

Keep current `GODOT_BIN` resolution.

- [ ] **Step 5: Build root game before the first main-project Godot process**

Run `dotnet build GodotE2E.csproj` before `scripts/bootstrap_gdunit4.sh`; then run GdUnit bootstrap and clean-bootstrap test.

- [ ] **Step 6: Run both same-language paths in each job**

Keep GDScript suite + intentional failure harness; add C# suite via Xvfb on Linux and plain `dotnet test` on Windows. No new matrix/job.

- [ ] **Step 7: Add survivor/package gates and managed failure artifacts**

Run survivor script with `if: always()` both jobs; Linux package gate; upload `TestResults` on failure.

- [ ] **Step 8: Document C# game compile exclusion and RunAsync**

Game `.csproj`:

```xml
<ItemGroup>
  <Compile Remove="addons/gdunit_e2e/csharp/**/*.cs" />
</ItemGroup>
```

Separate test project references `GodotE2E.Client.csproj` and pinned gdUnit4Net/Test SDK packages. README examples use `RunAsync`; no `[RequireGodotRuntime]`. Same-language support matrix only.

- [ ] **Step 9: Run complete local release gate**

```bash
./scripts/bootstrap_gdunit4.sh
dotnet list addons/gdunit_e2e/csharp/GodotE2E.Client.csproj package
dotnet sln GodotE2E.sln list
dotnet build GodotE2E.csproj
bash tests/scripts/bootstrap_gdunit4_import_test.sh
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
dotnet test tests/csharp/GodotE2E.Tests.csproj

set +e
./addons/gdUnit4/runtest.sh -a tests/fixtures/failure_harness_test.gd
status=$?
set -e
test "$status" -eq 100

bash tests/scripts/assert_no_e2e_children.sh
bash tests/scripts/package_release_test.sh
```

Use Xvfb locally on Linux where needed.

- [ ] **Step 10: Commit**

```bash
git add .github/workflows/ci.yml README.md tests/scripts
git commit -m "docs: ship csharp e2e integration path"
```

---

## Final PR Gate

- [ ] `git diff main...HEAD --check` passes.
- [ ] Existing GDScript public API was not refactored solely for C# reuse.
- [ ] Client project has no package dependencies; test project does not reference game project.
- [ ] No C# E2E test has `[RequireGodotRuntime]`.
- [ ] Game csproj has no manual `<AssemblyName>` and excludes C# test/client source trees.
- [ ] Solution contains only game project; C# UID committed.
- [ ] Same-language fixtures only.
- [ ] Clean-bootstrap temp project strips C# game/test metadata but keeps shipped client directory.
- [ ] Unsupported `_t` typed conversion throws; protocol/pipe constants have drift coverage.
- [ ] C# stdout/stderr retention is bounded to 4 MiB per stream.
- [ ] `RunAsync` preserves body failure when cleanup also fails and uses suite/test artifact path.
- [ ] README includes C# game compile exclusion.
- [ ] Linux + Windows CI green on Godot .NET 4.5.1.
- [ ] Release ZIP contains client and excludes root project/test files, GdUnit4, reports, test output.
- [ ] No E2E child survives either supported path.
