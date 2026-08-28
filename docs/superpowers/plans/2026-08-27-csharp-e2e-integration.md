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

Cover:

```csharp
[TestCase]
public async Task FrameUsesBigEndianLengthAndSupportsPartialReads()
{
    var payload = JsonSerializer.SerializeToElement(new { id = 7, action = "node_exists" });
    var frame = E2EFraming.Encode(payload);
    AssertThat(BinaryPrimitives.ReadUInt32BigEndian(frame.AsSpan(0, 4)))
        .IsEqual((uint)(frame.Length - 4));

    await using var stream = new ChunkedReadStream(frame, 1);
    var decoded = await E2EFraming.ReadAsync(stream, CancellationToken.None);
    AssertThat(decoded.GetProperty("id").GetInt32()).IsEqual(7);
}

[TestCase]
public void Vector2UsesExistingTag()
{
    var wire = JsonSerializer.SerializeToElement(
        E2EJson.NormalizeForWire(new E2EVector2(1.5, -2.0)));
    AssertThat(wire.GetProperty("_t").GetString()).IsEqual("v2");
    AssertThat(E2EJson.Convert<E2EVector2>(wire))
        .IsEqual(new E2EVector2(1.5, -2.0));
}

[TestCase]
public void UnsupportedTaggedValueFailsLoudly()
{
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
}
```

Also keep oversized-declaration-before-body-allocation and JSON-null conversion coverage.

Add `ProtocolConstantsMatchGdScriptContract()` that reads `addons/gdunit_e2e/protocol/e2e_protocol.gd` and `addons/gdunit_e2e/client/e2e_process.gd` from `TestPaths.RepositoryRoot`. Regex the relevant declarations and assert evaluated values equal the C# constants. This drift test is intentional because it compares two independent implementations.

- [ ] **Step 2: Run RED tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest"
```

Expected: compile failure because protocol classes do not exist.

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

public sealed class E2EException(string message, Exception? inner = null)
    : Exception(message, inner);

public readonly record struct E2EVector2(double X, double Y);
```

`E2EResult` stores `Success`, cloned raw `Response`, `Message`, and cloned `Logs`.

- [ ] **Step 4: Implement framing with exact reads and allocation guard**

Encode UTF-8 JSON with a four-byte BE prefix. `ReadAsync` reads exactly four bytes, rejects `declaredSize > MaxFrameBytes` **before allocating the body**, then reads exactly the declared body and requires a JSON object root.

```csharp
private static async Task ReadExactlyAsync(Stream stream, Memory<byte> buffer, CancellationToken ct)
{
    var offset = 0;
    while (offset < buffer.Length)
    {
        var read = await stream.ReadAsync(buffer[offset..], ct);
        if (read == 0)
            throw new E2EException("Connection closed while reading E2E frame");
        offset += read;
    }
}
```

- [ ] **Step 5: Implement minimal value conversion with loud tagged fallback**

`NormalizeForWire` handles primitives, string-key dictionaries, object sequences, and `E2EVector2`.

`Convert<T>` handles JSON null first. Then:

```csharp
if (element.ValueKind == JsonValueKind.Object
    && element.TryGetProperty("_t", out var tagElement)
    && tagElement.ValueKind == JsonValueKind.String)
{
    var tag = tagElement.GetString()!;
    if (tag == "v2" && typeof(T) == typeof(E2EVector2))
    {
        object value = new E2EVector2(
            element.GetProperty("x").GetDouble(),
            element.GetProperty("y").GetDouble());
        return (T)value;
    }

    throw new E2EException(
        $"Unsupported Godot value tag '{tag}'; use SendCommandAsync for raw access");
}
```

Only untagged JSON falls through to `Deserialize<T>()`.

- [ ] **Step 6: Run GREEN C# protocol + existing GDScript serializer tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest"
./addons/gdUnit4/runtest.sh -a tests/unit/serializer_test.gd -c
```

Expected: both pass, including drift guard.

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
- Produces internal `IE2ECommandSender.SendCommandAsync(...)` and `CollectedLogs` for the facade test seam.
- Produces `E2EClient.ConnectAsync(port, token, timeout, ct)`.
- Produces `E2EClient.SendCommandAsync(action, parameters, timeout, ct)`.
- Produces `IsSessionOpen`, `CollectedLogs`, and idempotent `DisposeAsync`.
- Second concurrent request returns failure `A command is already in flight`; it is not queued.

- [ ] **Step 1: Add the loopback fake server**

`FakeProtocolServer` uses `TcpListener(IPAddress.Loopback, 0)`, accepts one client, reads/writes with `E2EFraming`, and exposes a response handler plus recorded requests.

- [ ] **Step 2: Write RED client tests**

Cover hello ID/token/version, ID 2 for first normal command, wire normalization, partial response reads, readable protocol errors, `_logs` stripping/collection, timeout/disconnect closure, and fail-fast overlapping command behavior.

- [ ] **Step 3: Run RED client tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ClientTest"
```

Expected: compile failure for missing client.

- [ ] **Step 4: Implement connection/hello and raw command state**

Use `TcpClient` connected only to `127.0.0.1` and one `SemaphoreSlim(1, 1)` as a fail-fast guard:

```csharp
if (!await _commandGate.WaitAsync(0, cancellationToken))
    return E2EResult.Failure("A command is already in flight");
```

Allocate monotonically increasing IDs. `ConnectAsync` sends hello before marking the session open.

- [ ] **Step 5: Implement timeout/error/log handling**

Use linked cancellation with `CancelAfter(timeout)`. Catch expected transport/framing/timeout errors, close the session, and return `E2EResult.Failure(...)` for raw APIs. Verify response IDs; clone logs and raw response elements before source documents are disposed.

- [ ] **Step 6: Run GREEN tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ClientTest"
```

- [ ] **Step 7: Commit**

```bash
git add addons/gdunit_e2e/csharp tests/csharp/FakeProtocolServer.cs tests/csharp/ClientTest.cs
git commit -m "feat: add csharp e2e tcp client"
```

---

### Task 5: Launch, drain, authenticate, and reap the real Godot .NET child

**Files:**
- Create: `addons/gdunit_e2e/csharp/E2ELaunchOptions.cs`
- Create: `addons/gdunit_e2e/csharp/E2EProcess.cs`
- Create: `addons/gdunit_e2e/csharp/E2EGame.cs` (raw session/factory only in this task)
- Create: `tests/csharp/TestProject.cs`
- Create: `tests/csharp/ProcessLifecycleTest.cs`

**Interfaces:**
- `E2ELaunchOptions`: `ScenePath`, `ProjectPath`, `GodotPath`, `Timeout=10s`, `ExtraGodotArgs`, `LogVerbosity=warning`, `ServerPort=0`, `BootstrapScenePath`.
- `E2EProcess.LaunchAsync(options, ct)` owns process, async bounded pipe drains, port file, and authenticated `E2EClient`.
- `E2EGame.LaunchAsync` wraps one `E2EProcess`.
- Expose `ProcessId`, resolved `ProjectPath`, `Stdout`, `Stderr`, raw `SendCommandAsync`, and idempotent `DisposeAsync`.

- [ ] **Step 1: Write RED option/argv tests**

Pin ordering:

```text
--path <project>
--scene <BootstrapScenePath>
<ExtraGodotArgs...>
--
--gdunit-e2e
--gdunit-e2e-target-scene=<ScenePath>
--gdunit-e2e-port=<ServerPort>
--gdunit-e2e-port-file=<absolute temp path>
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=<level>
```

Pin project lookup upward from current/base directory and executable resolution `GodotPath -> GODOT_BIN -> PATH`.

- [ ] **Step 2: Run RED lifecycle tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
```

- [ ] **Step 3: Implement process start and a truly bounded continuous pipe drain**

Use `ProcessStartInfo.ArgumentList`, `UseShellExecute=false`, and redirect stdout/stderr.

Immediately start byte-stream drains from `StandardOutput.BaseStream` and `StandardError.BaseStream`. Do not use unbounded `ReadToEndAsync` storage.

Each drain continuously consumes every byte from the OS pipe while a fixed-size ring/tail retains only the newest `E2EProtocol.MaxPipeBytes` bytes. Decode the retained tail as UTF-8 after EOF. Retained data must never exceed 4 MiB per stream.

- [ ] **Step 4: Implement launch polling and authentication**

Create a unique temp directory/port file. Poll until the 10-second deadline: child exit -> finish drains/cleanup and throw with bounded diagnostics; valid nonzero port -> connect/authenticate; otherwise delay 25 ms. Reap before throwing on handshake failure.

- [ ] **Step 5: Implement bounded shutdown + kill fallback**

```text
if authenticated -> raw quit with ~500ms timeout, ignore command failure
Dispose client
wait <=1s for exit
if alive -> Process.Kill(entireProcessTree: true)
wait <=1s again
if dead -> await drain tasks and store bounded strings
remove temp path best effort
if still alive -> throw E2EException containing PID
```

Repeated successful disposal returns immediately.

- [ ] **Step 6: Add the repository integration helper**

```csharp
internal static class TestProject
{
    public static E2ELaunchOptions LaunchOptions() => new()
    {
        ProjectPath = TestPaths.RepositoryRoot,
        GodotPath = Environment.GetEnvironmentVariable("GODOT_BIN"),
        ScenePath = "res://tests/fixtures/csharp/main.tscn",
        Timeout = TimeSpan.FromSeconds(10),
        ExtraGodotArgs = ["--quiet"],
    };
}
```

Keep a small `IsProcessRunning(pid)` helper using `Process.GetProcessById` for cleanup assertions.

- [ ] **Step 7: Add the first real C# -> C# lifecycle test**

Launch, assert raw `node_exists("/root/Main")`, dispose, and assert the PID is no longer running. Add pipe-noise coverage only if needed to prove responsiveness under output load; assert retained diagnostic tails stay bounded.

- [ ] **Step 8: Build + run GREEN lifecycle tests**

```bash
dotnet build GodotE2E.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
```

- [ ] **Step 9: Commit**

```bash
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
- Public wrappers: `NodeExistsAsync`, `GetPropertyAsync<T>`, `SetPropertyAsync`, `CallMethodAsync<T>`, `InputActionAsync`, `PressActionAsync`, `ClickNodeAsync`, `WaitForPropertyAsync`, `WaitForSignalAsync`, `GetSceneAsync`, `ReloadSceneAsync`, `ScreenshotAsync`, `CaptureFailureArtifactsAsync`, raw `SendCommandAsync`.
- `RunAsync(options, body, ct, caller metadata)` is the normal first-party lifecycle.
- Deliberately no convenience wrappers yet for `get_tree`, key/mouse-button input, frame/seconds waits, `wait_for_node`, or `change_scene`.

- [ ] **Step 1: Write RED facade tests against only the C# fixture**

Use `RunAsync` for normal tests and cover node/property/method/vector2/action/click/property-wait plus raw negative response. Add signal/reload coverage, scheduling the signal before the wait because the session permits one in-flight command.

- [ ] **Step 2: Add a recording command-sender unit seam for the wait margin**

Implement `RecordingCommandSender : IE2ECommandSender`; construct `E2EGame` through its internal non-owning sender constructor. Assert:

```text
WaitForPropertyAsync(server=2.5s) -> transport=3.5s
WaitForSignalAsync(server=1.0s)   -> transport=2.0s
ReloadSceneAsync                  -> transport=6.0s
```

Do not duplicate the server timing-race integration test.

- [ ] **Step 3: Run RED facade tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~GameApiTest|FullyQualifiedName~GameplaySmokeTest"
```

- [ ] **Step 4: Implement wrappers through one failure mapper**

```csharp
private async Task<JsonElement> RequireAsync(
    string action,
    IReadOnlyDictionary<string, object?>? parameters = null,
    TimeSpan? timeout = null,
    CancellationToken cancellationToken = default)
{
    var result = await SendCommandAsync(action, parameters, timeout, cancellationToken);
    if (!result.Success)
        throw new E2EException(result.Message);
    return result.Response;
}
```

Typed results pass through `E2EJson.Convert<T>`; wait/reload transport deadlines apply `E2EProtocol.WaitMargin`.

- [ ] **Step 5: Implement explicit artifact capture**

`CaptureFailureArtifactsAsync(outputDirectory)` independently attempts screenshot, raw `get_tree {path:"/root", depth:4}`, and current collected logs. Write `{}`/`[]` fallbacks when unavailable. If child already exited, write bounded stdout/stderr. One diagnostic failure never blocks the others.

- [ ] **Step 6: Implement `RunAsync` with stable suite/test paths and failure precedence**

```csharp
public static Task RunAsync(
    E2ELaunchOptions options,
    Func<E2EGame, CancellationToken, Task> body,
    CancellationToken cancellationToken = default,
    [CallerMemberName] string testName = "",
    [CallerFilePath] string callerFilePath = "")
```

Output path:

```text
<resolved game project>/test_output/csharp/<safe caller-file-name>/<safe testName>/
```

Use GDScript-like safe path normalization for `..`, `/`, `\`, and `:`.

Control precedence explicitly rather than awaiting disposal in a `finally` that can replace the body failure:

```text
capture body exception with ExceptionDispatchInfo
on body failure -> best-effort reachable artifacts
attempt DisposeAsync and retain cleanup exception separately
best-effort append bounded stdout/stderr
if body failed:
    if cleanup also failed:
        add cleanup text to bodyException.Data["GodotE2E.CleanupFailure"]
        write it to stderr/artifact diagnostic
    rethrow original body exception through ExceptionDispatchInfo
else if cleanup failed:
    throw cleanup exception
```

- [ ] **Step 7: Add deterministic RunAsync artifact regression**

Use `RunAsyncCapturesBodyFailureArtifacts` and only delete/check:

```text
test_output/csharp/GameplaySmokeTest/RunAsyncCapturesBodyFailureArtifacts/
```

Deliberately throw a local exception after launch, catch outside, and assert screenshot/tree/log files exist at that exact path. No GUID scan or global `test_output/csharp` deletion.

- [ ] **Step 8: Add cleanup + forced-kill regressions**

Keep body-exception cleanup coverage and fixture-only `BlockMainThread(5000)` forced-kill coverage. The blocking raw call uses ~100ms command timeout; disposal must kill/reap within its bounded window. No production kill toggle.

- [ ] **Step 9: Run GREEN same-language suites**

```bash
dotnet build GodotE2E.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
```

- [ ] **Step 10: Commit**

```bash
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
- Clean-bootstrap script proves the shipped addon imports in a temporary project with no C# project metadata/fixture.
- README gives separate GDScript/C# setup and requires C# game compile exclusion for the client sources.

- [ ] **Step 1: Change clean bootstrap back to the GDScript-only consumer shape**

After `git archive HEAD | tar -x -C "$TEST_ROOT"`:

```bash
rm -f "$TEST_ROOT/GodotE2E.csproj" "$TEST_ROOT/GodotE2E.sln"
rm -rf "$TEST_ROOT/tests/csharp" "$TEST_ROOT/tests/fixtures/csharp"
```

Keep `addons/gdunit_e2e/csharp/**` because it ships in the addon archive.

Strip C# metadata from temporary `project.godot` with Git-for-Windows-compatible `sed`/`awk`:

```bash
project_file="$TEST_ROOT/project.godot"
sed -E 's/"C#",[[:space:]]*//g; s/,[[:space:]]*"C#"//g' "$project_file" > "$project_file.features"
awk '
  /^\[dotnet\]$/ { skip=1; next }
  skip && /^\[/ { skip=0 }
  !skip { print }
' "$project_file.features" > "$project_file.clean"
mv "$project_file.clean" "$project_file"
rm -f "$project_file.features"
```

Do **not** run a C# build in the temp project. Continue existing GdUnit bootstrap/import and class-cache assertion with `GODOT_BIN`.

- [ ] **Step 2: Extract the duplicated survivor scan**

Create `assert_no_e2e_children.sh` from the two existing workflow process-scan blocks. It must support Linux `ps` and Windows PowerShell and fail if a command line contains `--gdunit-e2e`.

- [ ] **Step 3: Add the release-package contract**

Verify archive includes `.gdignore`, `GodotE2E.Client.csproj`, and `E2EGame.cs`; excludes `tests/**`, `GodotE2E.csproj`, `GodotE2E.sln`, and `addons/gdUnit4/**`.

- [ ] **Step 4: Switch both existing jobs to Godot .NET + .NET 8**

```yaml
- name: Install Godot
  uses: chickensoft-games/setup-godot@v2.4.1
  with:
    version: 4.5.1
    use-dotnet: true

- name: Setup .NET
  uses: actions/setup-dotnet@v6
  with:
    dotnet-version: 8.0.x
```

Keep current `GODOT_BIN` resolution, including Windows `cygpath` handling.

- [ ] **Step 5: Build root game before the first main-project Godot process**

Place before `./scripts/bootstrap_gdunit4.sh` because that script launches the editor:

```yaml
- name: Build Godot .NET project
  shell: bash
  run: dotnet build GodotE2E.csproj
```

Then run GdUnit bootstrap and modified clean-bootstrap test. The clean temp project does not build C# because it strips C# metadata first.

- [ ] **Step 6: Run both same-language paths in each job**

Keep existing GDScript suite + intentional failure harness. Add C# suite via Xvfb on Linux and plain `dotnet test` on Windows. Do not add another matrix/job.

- [ ] **Step 7: Add survivor/package gates and managed failure artifacts**

Run `assert_no_e2e_children.sh` with `if: always()` in both jobs. Linux runs package contract. Add `TestResults` to existing failure uploads.

- [ ] **Step 8: Document C# compile exclusion and RunAsync usage**

C# game project installation includes:

```xml
<ItemGroup>
  <Compile Remove="addons/gdunit_e2e/csharp/**/*.cs" />
</ItemGroup>
```

Separate test project includes the pinned gdUnit4Net/Test SDK packages and a `ProjectReference` to `GodotE2E.Client.csproj`. State that the reference path is relative to the consumer test project.

README C# examples use `E2EGame.RunAsync`, not bare `await using`, so thrown assertions get best-effort diagnostics. State normal C# E2E tests do not need `[RequireGodotRuntime]`.

Support matrix remains same-language only.

- [ ] **Step 9: Run the complete local release gate**

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

On Linux without display, wrap child-launching commands with CI's Xvfb invocation.

- [ ] **Step 10: Commit**

```bash
git add .github/workflows/ci.yml README.md tests/scripts
git commit -m "docs: ship csharp e2e integration path"
```

---

## Final PR Gate

- [ ] `git diff main...HEAD --check` passes.
- [ ] No existing GDScript public API was refactored solely for C# reuse.
- [ ] `GodotE2E.Client.csproj` has no package dependencies.
- [ ] `GodotE2E.Tests.csproj` does not reference `GodotE2E.csproj`.
- [ ] No C# E2E test has `[RequireGodotRuntime]`.
- [ ] `GodotE2E.csproj` has no manual `<AssemblyName>` and excludes both C# test/client source trees.
- [ ] `GodotE2E.sln` contains only `GodotE2E.csproj`.
- [ ] `tests/fixtures/csharp/Main.cs.uid` is committed.
- [ ] Every C# child-launching test targets `res://tests/fixtures/csharp/main.tscn`.
- [ ] No GDScript test targets the C# fixture and no C# test targets a GDScript fixture.
- [ ] Clean-bootstrap temp project strips C# game/test metadata but keeps shipped `addons/gdunit_e2e/csharp/**`.
- [ ] Unsupported `_t` typed conversion throws and protocol/pipe constants have drift coverage.
- [ ] C# stdout/stderr retention is bounded to 4 MiB per stream.
- [ ] `RunAsync` preserves body failure when cleanup also fails and uses `test_output/csharp/<suite>/<test>`.
- [ ] README includes C# game `<Compile Remove="addons/gdunit_e2e/csharp/**/*.cs" />`.
- [ ] Linux and Windows CI are green using Godot .NET 4.5.1.
- [ ] Release ZIP includes C# client and excludes root project/test files, GdUnit4, reports, and test output.
- [ ] No `--gdunit-e2e` process survives either supported path.
