# C# E2E Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native C# test-authoring path that runs `C# test -> C# game` end-to-end while leaving the existing `GDScript test -> GDScript game` path unchanged.

**Architecture:** Keep the existing GDScript bootstrap, automation server, command handler, protocol v1, diagnostics, and orphan watchdog as the only child runtime. Add a BCL-only .NET 8 parent client using `System.Net.Sockets`, `System.Text.Json`, and `System.Diagnostics.Process`; C# tests run through gdUnit4Net/VSTest without `[RequireGodotRuntime]` and launch the Godot .NET game as the real child process.

**Tech Stack:** Godot .NET 4.5.1, .NET 8 / C# 12, gdUnit4.api 5.0.0, gdUnit4.test.adapter 3.0.0, gdUnit4.analyzers 1.0.0, Microsoft.NET.Test.Sdk 17.14.1, existing localhost TCP protocol v1, GitHub Actions, Xvfb on Linux.

**Spec:** `docs/superpowers/specs/2026-08-27-csharp-e2e-integration-design.md`

## Global Constraints

- One feature PR for design, plan, implementation, tests, CI, and docs; use task-level commits inside that PR.
- Supported matrix is only `GDScript test -> GDScript game` and `C# test -> C# game`.
- Do not add tests, docs promises, or fixes for either cross-language combination.
- Do not change the existing GDScript parent API merely to share code with C#.
- Reuse the existing GDScript bootstrap/server/command handler and protocol v1 unchanged unless a real compatibility bug is found.
- C# client targets `net8.0` and uses the .NET BCL only: no GodotSharp, gdUnit4Net, third-party socket, or third-party JSON dependency.
- C# repository tests use gdUnit4Net/VSTest but do not reference the root Godot game project.
- Pin repository test packages to `gdUnit4.api` 5.0.0, `gdUnit4.test.adapter` 3.0.0, `gdUnit4.analyzers` 1.0.0, and `Microsoft.NET.Test.Sdk` 17.14.1.
- Root Godot project uses `Godot.NET.Sdk/4.5.1`, targets `net8.0`, compiles the C# fixture, and excludes `tests/csharp/**/*.cs`.
- Normal C# E2E tests must not use `[RequireGodotRuntime]`.
- Four-byte unsigned big-endian framing, protocol version `1`, `16 * 1024 * 1024` frame cap, `127.0.0.1` only, token hello, and one in-flight command remain invariant.
- Launch timeout default stays 10 seconds; ordinary command timeout stays 5 seconds; server waits add a 1-second client margin.
- One child per `E2EGame`; no pool, reuse, parallel sessions, generic RPC layer, generated bindings, or NuGet publishing.
- `E2EGame` uses `IAsyncDisposable`; failure to confirm owned child death is test-visible.
- Explicit `CaptureFailureArtifactsAsync()` is required; automatic arbitrary gdUnit4Net assertion-failure hooks are deferred.
- Linux + Windows remain the only CI platforms; use one job per OS, not a C# matrix.
- The release remains one archive containing `addons/gdunit_e2e/**`, `README.md`, `LICENSE`, and `NOTICE`.
- RED -> GREEN -> REFACTOR for behavior tasks.

## Planned File Structure

```text
.
├── godot-e2e.csproj
├── .gitignore
├── .github/workflows/ci.yml
├── README.md
├── addons/gdunit_e2e/
│   ├── client/                         # existing GDScript path, unchanged
│   ├── protocol/                       # existing protocol/server contract
│   ├── runtime/                        # existing child bootstrap
│   ├── server/                         # existing child server
│   └── csharp/
│       ├── GodotE2E.Client.csproj      # pure .NET client project
│       ├── E2EProtocol.cs              # constants only
│       ├── E2EFraming.cs               # length-prefixed JSON framing
│       ├── E2EJson.cs                  # protocol value conversion
│       ├── E2EValueTypes.cs            # Godot-independent tagged values
│       ├── E2EResult.cs                # raw operation result
│       ├── E2EException.cs             # wrapped-operation exception
│       ├── E2EClient.cs                # TCP session + one in-flight request
│       ├── E2ELaunchOptions.cs         # public launch configuration
│       ├── E2EProcess.cs               # Godot child ownership/reap
│       └── E2EGame.cs                  # public facade + artifacts
├── tests/fixtures/csharp/
│   ├── main.tscn
│   └── Main.cs
├── tests/csharp/
│   ├── GodotE2E.Tests.csproj
│   ├── RunnerSmokeTest.cs
│   ├── ProtocolTest.cs
│   ├── ClientTest.cs
│   ├── ProcessLifecycleTest.cs
│   ├── GameplaySmokeTest.cs
│   ├── FakeProtocolServer.cs
│   └── TestProject.cs
└── tests/scripts/
    ├── bootstrap_gdunit4_import_test.sh
    ├── assert_no_e2e_children.sh
    └── package_release_test.sh
```

File responsibilities are intentionally narrow: framing never owns sockets, the TCP client never owns OS processes, process ownership never contains test-framework logic, and `E2EGame` is the only high-level convenience facade.

---

### Task 1: Pin and prove the isolated C# test runner

**Files:**
- Create: `addons/gdunit_e2e/csharp/GodotE2E.Client.csproj`
- Create: `tests/csharp/GodotE2E.Tests.csproj`
- Create: `tests/csharp/RunnerSmokeTest.cs`
- Modify: `.gitignore`

**Interfaces:**
- Produces: pure `.NET 8` project `GodotE2E.Client` for later client sources.
- Produces: gdUnit4Net test project that references `GodotE2E.Client` but not `godot-e2e.csproj`.
- Produces: working `dotnet test tests/csharp/GodotE2E.Tests.csproj` command.

- [ ] **Step 1: Add the BCL-only client project**

Create `addons/gdunit_e2e/csharp/GodotE2E.Client.csproj`:

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

Do not add a GodotSharp or gdUnit4 package here.

- [ ] **Step 2: Add the isolated gdUnit4Net test project with exact pins**

Create `tests/csharp/GodotE2E.Tests.csproj`:

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

The gdUnit package may bring GodotSharp transitively into the **test project's** dependency graph; that is acceptable because this project is isolated from the Godot 4.5.1 game project. Do not add a direct GodotSharp reference.

- [ ] **Step 3: Add a runner-only smoke test with no Godot runtime attribute**

Create `tests/csharp/RunnerSmokeTest.cs`:

```csharp
namespace GodotE2E.Tests;

using GdUnit4;
using static GdUnit4.Assertions;

[TestSuite]
public sealed class RunnerSmokeTest
{
    [TestCase]
    public void RunsWithoutGodotRuntime()
    {
        AssertThat(1).IsEqual(1);
    }
}
```

Do not add `[RequireGodotRuntime]`.

- [ ] **Step 4: Ignore managed build/test output**

Append to `.gitignore`:

```gitignore
bin/
obj/
TestResults/
```

- [ ] **Step 5: Restore and run the runner smoke test**

Run:

```bash
dotnet restore tests/csharp/GodotE2E.Tests.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --no-restore --filter "FullyQualifiedName~RunnerSmokeTest"
```

Expected: one test passes without launching or requiring Godot.

- [ ] **Step 6: Verify the client project has no accidental package dependencies**

Run:

```bash
dotnet list addons/gdunit_e2e/csharp/GodotE2E.Client.csproj package
```

Expected: no package references.

- [ ] **Step 7: Commit**

```bash
git add .gitignore addons/gdunit_e2e/csharp/GodotE2E.Client.csproj tests/csharp
 git commit -m "test: bootstrap csharp e2e runner"
```

---

### Task 2: Make the repository a Godot .NET project and add one C# game fixture

**Files:**
- Create: `godot-e2e.csproj`
- Create: `tests/fixtures/csharp/Main.cs`
- Create: `tests/fixtures/csharp/main.tscn`

**Interfaces:**
- Produces: Godot .NET 4.5.1 game assembly containing the C# fixture.
- Produces: fixture scene `res://tests/fixtures/csharp/main.tscn` with root `/root/Main`.
- Produces C# custom methods: `Echo(string)`, `SchedulePulse(double)`, `BlockMainThread(int)`.
- Produces custom signal `Pulse` and state properties `ActionCount`, `ActionPressed`.

- [ ] **Step 1: Add the minimal Godot .NET project boundary**

Create `godot-e2e.csproj`:

```xml
<Project Sdk="Godot.NET.Sdk/4.5.1">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <EnableDynamicLoading>true</EnableDynamicLoading>
    <Nullable>enable</Nullable>
  </PropertyGroup>

  <ItemGroup>
    <Compile Remove="tests/csharp/**/*.cs" />
  </ItemGroup>
</Project>
```

Do not reference the gdUnit4Net C# packages from this project.

- [ ] **Step 2: Add the C# fixture script**

Create `tests/fixtures/csharp/Main.cs`:

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

`BlockMainThread` is test fixture behavior used to prove forced cleanup; do not add a production launcher seam solely for that test.

- [ ] **Step 3: Add the C# scene with stable node paths**

Create `tests/fixtures/csharp/main.tscn`:

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

- [ ] **Step 4: Build the Godot project**

Run:

```bash
dotnet build godot-e2e.csproj
```

Expected: build passes using `Godot.NET.Sdk/4.5.1`; the gdUnit C# test sources are not compiled into the game assembly.

- [ ] **Step 5: Verify the existing GDScript suite still imports under the .NET-capable project**

Run:

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit -c
```

Expected: existing unit suite passes with no public GDScript API changes.

- [ ] **Step 6: Commit**

```bash
git add godot-e2e.csproj tests/fixtures/csharp
 git commit -m "test: add csharp godot fixture"
```

---

### Task 3: Implement protocol framing and the minimal Godot-independent value codec

**Files:**
- Create: `addons/gdunit_e2e/csharp/E2EProtocol.cs`
- Create: `addons/gdunit_e2e/csharp/E2EFraming.cs`
- Create: `addons/gdunit_e2e/csharp/E2EJson.cs`
- Create: `addons/gdunit_e2e/csharp/E2EValueTypes.cs`
- Create: `addons/gdunit_e2e/csharp/E2EResult.cs`
- Create: `addons/gdunit_e2e/csharp/E2EException.cs`
- Create: `tests/csharp/ProtocolTest.cs`

**Interfaces:**
- Produces `E2EProtocol.ProtocolVersion = 1`, `MaxFrameBytes = 16 * 1024 * 1024`, `DefaultCommandTimeout = 5s`, `WaitMargin = 1s`.
- Produces `E2EFraming.Encode(JsonElement) -> byte[]` and `ReadAsync(Stream, CancellationToken) -> Task<JsonElement>`.
- Produces `E2EJson.NormalizeForWire(object?) -> object?` and `Convert<T>(JsonElement) -> T`.
- Produces `E2EVector2(double X, double Y)` as the first required tagged value.
- Produces raw `E2EResult` with `Success`, cloned `Response`, `Message`, and per-response `Logs`.

- [ ] **Step 1: Write RED protocol tests**

Create `tests/csharp/ProtocolTest.cs` with focused cases:

```csharp
namespace GodotE2E.Tests;

using System.Buffers.Binary;
using System.Text.Json;
using GdUnit4;
using static GdUnit4.Assertions;

[TestSuite]
public sealed class ProtocolTest
{
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
    public async Task OversizedDeclarationFailsBeforeReadingABody()
    {
        var header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, E2EProtocol.MaxFrameBytes + 1u);
        await using var stream = new MemoryStream(header);

        await AssertThrownAsync<E2EException>(
            () => E2EFraming.ReadAsync(stream, CancellationToken.None));
    }

    [TestCase]
    public void Vector2UsesExistingV2Tag()
    {
        var wire = JsonSerializer.SerializeToElement(
            E2EJson.NormalizeForWire(new E2EVector2(1.5, -2.0)));

        AssertThat(wire.GetProperty("_t").GetString()).IsEqual("v2");
        AssertThat(E2EJson.Convert<E2EVector2>(wire))
            .IsEqual(new E2EVector2(1.5, -2.0));
    }
}
```

If gdUnit4Net lacks a convenient async-exception assertion, use explicit `try/catch` and assert the exception type; do not add another assertion framework.

Add a tiny private `ChunkedReadStream` in the same test file or a focused helper file; it must cap each `ReadAsync` call to the configured chunk size.

- [ ] **Step 2: Run RED tests**

Run:

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest"
```

Expected: compile fails because the protocol classes do not exist.

- [ ] **Step 3: Add exact protocol constants and result/exception types**

Implement:

```csharp
namespace GodotE2E;

public static class E2EProtocol
{
    public const int ProtocolVersion = 1;
    public const uint MaxFrameBytes = 16u * 1024u * 1024u;
    public static readonly TimeSpan DefaultCommandTimeout = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan WaitMargin = TimeSpan.FromSeconds(1);
}

public sealed class E2EException(string message, Exception? inner = null)
    : Exception(message, inner);

public readonly record struct E2EVector2(double X, double Y);
```

`E2EResult` stores cloned `JsonElement` values so it never depends on a disposed `JsonDocument`.

- [ ] **Step 4: Implement framing with exact-read loops and pre-allocation size validation**

The core shape must be:

```csharp
public static byte[] Encode(JsonElement message)
{
    var payload = JsonSerializer.SerializeToUtf8Bytes(message);
    if ((uint)payload.Length > E2EProtocol.MaxFrameBytes)
        throw new E2EException("E2E frame exceeds the 16 MiB limit");

    var frame = new byte[4 + payload.Length];
    BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(0, 4), (uint)payload.Length);
    payload.CopyTo(frame.AsSpan(4));
    return frame;
}
```

`ReadAsync` first reads exactly four bytes, validates the declared size against `MaxFrameBytes`, then allocates/reads the body. EOF before a complete frame throws `E2EException`.

- [ ] **Step 5: Implement only the value conversion required now**

`NormalizeForWire` must recursively handle primitives, dictionaries/lists, and `E2EVector2`:

```csharp
E2EVector2 v => new Dictionary<string, object?>
{
    ["_t"] = "v2",
    ["x"] = v.X,
    ["y"] = v.Y,
}
```

`Convert<T>` recognizes `_t == "v2"` when `T` is `E2EVector2`; otherwise use `JsonElement.Deserialize<T>()`. Do not implement every Godot Variant tag in this task.

- [ ] **Step 6: Run GREEN tests and the existing GDScript serializer tests**

Run:

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest"
./addons/gdUnit4/runtest.sh -a tests/unit/serializer_test.gd -c
```

Expected: both suites pass; existing protocol behavior remains unchanged.

- [ ] **Step 7: Commit**

```bash
git add addons/gdunit_e2e/csharp tests/csharp/ProtocolTest.cs
 git commit -m "feat: add csharp e2e protocol primitives"
```

---

### Task 4: Add the raw TCP client and prove protocol-v1 interoperability without Godot

**Files:**
- Create: `addons/gdunit_e2e/csharp/E2EClient.cs`
- Create: `tests/csharp/FakeProtocolServer.cs`
- Create: `tests/csharp/ClientTest.cs`

**Interfaces:**
- Produces `E2EClient.ConnectAsync(int port, string token, TimeSpan timeout, CancellationToken) -> Task<E2EResult>`.
- Produces `E2EClient.SendCommandAsync(string action, IReadOnlyDictionary<string, object?>? parameters, TimeSpan? timeout, CancellationToken) -> Task<E2EResult>`.
- Produces `IsSessionOpen`, `CollectedLogs`, `CloseAsync/DisposeAsync`.
- One concurrent request attempt fails immediately with `A command is already in flight` rather than queueing.

- [ ] **Step 1: Write RED client tests around a real loopback `TcpListener`**

`FakeProtocolServer` should listen on `IPAddress.Loopback`, expose its assigned port, read frames with `E2EFraming`, and let each test provide a response function.

Add tests that assert:

```csharp
[TestCase]
public async Task HelloIsFirstRequestAndUsesProtocolVersionOne()
{
    await using var server = await FakeProtocolServer.StartAsync(request =>
    {
        AssertThat(request.GetProperty("id").GetInt32()).IsEqual(1);
        AssertThat(request.GetProperty("action").GetString()).IsEqual("hello");
        AssertThat(request.GetProperty("token").GetString()).IsEqual("secret");
        AssertThat(request.GetProperty("protocol_version").GetInt32()).IsEqual(1);
        return new { id = 1, ok = true };
    });

    await using var client = new E2EClient();
    var result = await client.ConnectAsync(server.Port, "secret", TimeSpan.FromSeconds(1));
    AssertThat(result.Success).IsTrue();
}
```

Also cover request ID `2` after hello, server `{error,message}` rendering as `"error: message"`, `_logs` collection, timeout closing the session, unexpected response ID closing the session, and a second request while one is blocked returning the one-in-flight failure.

- [ ] **Step 2: Run RED client tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ClientTest"
```

Expected: compile failure because `E2EClient` and `FakeProtocolServer` are not implemented.

- [ ] **Step 3: Implement connection/hello and one-in-flight request ownership**

Use `TcpClient.ConnectAsync(IPAddress.Loopback, port, cancellationToken)` and a `SemaphoreSlim(1, 1)`. Acquire with a zero-time wait:

```csharp
if (!await _inFlight.WaitAsync(0, cancellationToken))
    return E2EResult.Failure("A command is already in flight");
```

Always release in `finally`. Do not add a request queue.

- [ ] **Step 4: Implement request IDs, raw command merging, response validation, and log collection**

Build requests as a dictionary with `id` and `action`; add each parameter after `E2EJson.NormalizeForWire`. Clone the response element before disposing the parse document.

Treat `error` presence as failure. Render messages exactly like the GDScript client:

```text
error only                 -> error
message only               -> message
error == message           -> error
error + distinct message   -> error: message
```

Strip `_logs` and `_logs_dropped` from the logical response value and append decoded logs to `CollectedLogs`.

- [ ] **Step 5: Make command timeout a transport failure**

Use a linked `CancellationTokenSource.CancelAfter(timeout)`. If timeout occurs, close the socket and return:

```text
Command '<action>' timed out after <milliseconds> ms
```

Do not leave the connection reusable after a partial/timed-out response.

- [ ] **Step 6: Run GREEN client + protocol tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest|FullyQualifiedName~ClientTest"
```

Expected: pass without launching Godot.

- [ ] **Step 7: Commit**

```bash
git add addons/gdunit_e2e/csharp/E2EClient.cs tests/csharp/FakeProtocolServer.cs tests/csharp/ClientTest.cs
 git commit -m "feat: add csharp e2e tcp client"
```

---

### Task 5: Launch, authenticate, and deterministically reap a real Godot .NET child

**Files:**
- Create: `addons/gdunit_e2e/csharp/E2ELaunchOptions.cs`
- Create: `addons/gdunit_e2e/csharp/E2EProcess.cs`
- Create: `addons/gdunit_e2e/csharp/E2EGame.cs`
- Create: `tests/csharp/TestProject.cs`
- Create: `tests/csharp/ProcessLifecycleTest.cs`

**Interfaces:**
- Produces `E2ELaunchOptions` fields: `ScenePath`, `ProjectPath`, `GodotPath`, `Timeout`, `ExtraGodotArgs`, `LogVerbosity`, `ServerPort`, `BootstrapScenePath`.
- Produces `E2EProcess.LaunchAsync(E2ELaunchOptions, CancellationToken) -> Task<E2EProcess>`.
- Produces `E2EProcess.Client`, `ProcessId`, `Stdout`, `Stderr`, `IsRunning`, and idempotent `DisposeAsync()`.
- Produces `E2EGame.LaunchAsync(...)`, raw `SendCommandAsync(...)`, `ProcessId`, and `DisposeAsync()`.

- [ ] **Step 1: Write RED unit tests for option resolution and exact launch arguments**

Cover these defaults:

```csharp
var options = new E2ELaunchOptions
{
    ScenePath = "res://tests/fixtures/csharp/main.tscn",
};

AssertThat(options.Timeout).IsEqual(TimeSpan.FromSeconds(10));
AssertThat(options.LogVerbosity).IsEqual("warning");
AssertThat(options.ServerPort).IsEqual(0);
AssertThat(options.BootstrapScenePath)
    .IsEqual("res://addons/gdunit_e2e/runtime/bootstrap.tscn");
```

Add a test-only internal `E2EProcess.BuildArguments(options, portFile, token)` seam and assert the ordered argument sequence is:

```text
--path <project>
--scene res://addons/gdunit_e2e/runtime/bootstrap.tscn
<ExtraGodotArgs...>
--
--gdunit-e2e
--gdunit-e2e-target-scene=<scene>
--gdunit-e2e-port=<port>
--gdunit-e2e-port-file=<file>
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=<verbosity>
```

- [ ] **Step 2: Run RED lifecycle tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
```

Expected: compile failure because the process/session types do not exist.

- [ ] **Step 3: Implement project/Godot executable resolution**

Rules:

```text
ProjectPath explicit -> normalize and require project.godot beneath it
ProjectPath empty    -> walk upward from Directory.GetCurrentDirectory(), then AppContext.BaseDirectory
GodotPath explicit   -> use it
GodotPath empty      -> GODOT_BIN if set, otherwise command name "godot"
```

Do not reject the fallback `"godot"` merely because `File.Exists("godot")` is false; `Process.Start` must be allowed to resolve `PATH`.

- [ ] **Step 4: Implement real launch and continuous stdout/stderr draining**

Use `ProcessStartInfo` with:

```csharp
UseShellExecute = false,
RedirectStandardOutput = true,
RedirectStandardError = true,
CreateNoWindow = true,
WorkingDirectory = projectPath,
```

Populate `ArgumentList` one token at a time; do not construct a quoted shell command.

Create a unique temp directory/port file under `Path.GetTempPath()`. Start asynchronous output/error reads immediately after `Process.Start()` so Windows pipe pressure cannot block the child before it writes the port file.

Poll every 25 ms until the bounded launch deadline. Fail with captured stdout/stderr if the child exits before port publication or the port file never appears.

- [ ] **Step 5: Connect/authenticate and surface a raw `E2EGame` session**

After reading a valid port `1..65535`, create `E2EClient`, authenticate with the launch token, and return `E2EGame` owning the process. If handshake fails, reap the child before throwing `E2EException`.

- [ ] **Step 6: Implement bounded normal shutdown + kill fallback**

`DisposeAsync()` order:

```text
if authenticated: send quit with 500 ms timeout, best effort
close/dispose client
wait up to 1 second for child exit
if alive: Process.Kill(entireProcessTree: true)
wait up to 1 second again
finish output/error drains
delete temp port file/directory best effort
throw E2EException if death still cannot be confirmed
```

Repeated `DisposeAsync()` calls after successful cleanup return immediately.

- [ ] **Step 7: Add the first real C# -> C# lifecycle integration test**

`tests/csharp/TestProject.cs` resolves the repository root and returns:

```csharp
internal static E2ELaunchOptions LaunchOptions() => new()
{
    ProjectPath = RepositoryRoot,
    GodotPath = Environment.GetEnvironmentVariable("GODOT_BIN"),
    ScenePath = "res://tests/fixtures/csharp/main.tscn",
    Timeout = TimeSpan.FromSeconds(5),
    ExtraGodotArgs = ["--quiet"],
};
```

Use it in:

```csharp
[TestCase]
public async Task LaunchesAndGracefullyReapsCSharpFixture()
{
    var game = await E2EGame.LaunchAsync(TestProject.LaunchOptions());
    var pid = game.ProcessId;

    var result = await game.SendCommandAsync(
        "node_exists",
        new Dictionary<string, object?> { ["path"] = "/root/Main" });
    AssertThat(result.Success).IsTrue();
    AssertThat(result.Response.GetProperty("exists").GetBoolean()).IsTrue();

    await game.DisposeAsync();
    AssertThat(TestProject.IsProcessRunning(pid)).IsFalse();
}
```

- [ ] **Step 8: Build the game then run GREEN lifecycle tests**

```bash
dotnet build godot-e2e.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
```

Expected: C# test runner launches a real Godot .NET child using the unchanged GDScript bootstrap/server and reaps it.

- [ ] **Step 9: Commit**

```bash
git add addons/gdunit_e2e/csharp tests/csharp/TestProject.cs tests/csharp/ProcessLifecycleTest.cs
 git commit -m "feat: launch csharp godot e2e child"
```

---

### Task 6: Add the useful C# facade, explicit artifacts, and cleanup regressions

**Files:**
- Modify: `addons/gdunit_e2e/csharp/E2EGame.cs`
- Modify: `addons/gdunit_e2e/csharp/E2EJson.cs`
- Modify: `tests/fixtures/csharp/Main.cs`
- Modify: `tests/csharp/ProcessLifecycleTest.cs`
- Create: `tests/csharp/GameplaySmokeTest.cs`

**Interfaces:**
- Produces wrapped operations required by acceptance: `NodeExistsAsync`, `GetPropertyAsync<T>`, `SetPropertyAsync`, `CallMethodAsync<T>`, `InputActionAsync`, `PressActionAsync`, `ClickNodeAsync`, `WaitForPropertyAsync`, `WaitForSignalAsync`, `GetSceneAsync`, `ReloadSceneAsync`, `ScreenshotAsync`, `CaptureFailureArtifactsAsync`.
- Wrapped failures throw `E2EException`; raw `SendCommandAsync` never converts expected server errors into framework failure state.
- Produces `CaptureFailureArtifactsAsync(string outputDirectory)` with `screenshot.png`, `scene_tree.json`, `engine_logs.json`; stdout/stderr are added when available after exit.

- [ ] **Step 1: Write RED gameplay tests against only the C# fixture**

Cover representative operations rather than mirroring every GDScript integration test:

```csharp
[TestCase]
public async Task DrivesCSharpGameThroughWrappedApi()
{
    await using var game = await E2EGame.LaunchAsync(TestProject.LaunchOptions());

    AssertThat(await game.NodeExistsAsync("/root/Main/Button")).IsTrue();
    AssertThat(await game.GetPropertyAsync<string>("/root/Main/Status", "text"))
        .IsEqual("ready");
    AssertThat(await game.CallMethodAsync<string>("/root/Main", "Echo", ["hello"]))
        .IsEqual("csharp:hello");

    await game.SetPropertyAsync("/root/Main", "position", new E2EVector2(12, 34));
    AssertThat(await game.GetPropertyAsync<E2EVector2>("/root/Main", "position"))
        .IsEqual(new E2EVector2(12, 34));

    await game.PressActionAsync("ui_accept");
    AssertThat(await game.GetPropertyAsync<int>("/root/Main", "ActionCount"))
        .IsEqual(1);

    await game.ClickNodeAsync("/root/Main/Button");
    AssertThat(await game.WaitForPropertyAsync(
        "/root/Main/ClickStatus", "text", "clicked", TimeSpan.FromSeconds(2)))
        .IsTrue();
}
```

Add a raw negative response test using `get_property` on `/root/Missing`, and assert `Success == false` without a thrown wrapper exception.

- [ ] **Step 2: Add RED signal + scene tests**

Schedule the signal **before** waiting because the client intentionally allows only one in-flight command:

```csharp
await game.CallMethodAsync<object?>("/root/Main", "SchedulePulse", [0.1]);
var signalArgs = await game.WaitForSignalAsync("/root/Main", "Pulse", TimeSpan.FromSeconds(2));
AssertThat((string)signalArgs[0]!).IsEqual("pulse");

AssertThat(await game.GetSceneAsync())
    .IsEqual("res://tests/fixtures/csharp/main.tscn");
await game.ReloadSceneAsync();
AssertThat(await game.GetSceneAsync())
    .IsEqual("res://tests/fixtures/csharp/main.tscn");
```

Do not add a second GDScript scene or cross-language fixture to test scene changes.

- [ ] **Step 3: Add RED explicit artifact test**

Use a per-test temp directory and assert the reachable artifacts:

```csharp
var output = Path.Combine(Path.GetTempPath(), "godot-e2e-csharp-artifacts", Guid.NewGuid().ToString("N"));
await game.CaptureFailureArtifactsAsync(output);

AssertThat(File.Exists(Path.Combine(output, "screenshot.png"))).IsTrue();
AssertThat(File.Exists(Path.Combine(output, "scene_tree.json"))).IsTrue();
AssertThat(File.Exists(Path.Combine(output, "engine_logs.json"))).IsTrue();
```

Artifact capture is best effort per artifact: a failed screenshot request must not prevent tree/log JSON writes.

- [ ] **Step 4: Run RED gameplay tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~GameplaySmokeTest"
```

Expected: compile failure for missing facade methods.

- [ ] **Step 5: Implement only the wrappers exercised by acceptance**

Use one internal helper:

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

`WaitForPropertyAsync` and `WaitForSignalAsync` send the server timeout in seconds and set the transport timeout to `serverTimeout + E2EProtocol.WaitMargin`.

`PressActionAsync` is exactly two sequential `input_action` calls (`pressed=true`, then `pressed=false`); do not add retry/expect semantics.

- [ ] **Step 6: Implement explicit artifact capture without gdUnit4Net hooks**

`CaptureFailureArtifactsAsync(outputDirectory)`:

```text
Directory.CreateDirectory(outputDirectory)
try screenshot -> absolute outputDirectory/screenshot.png
try get_tree /root depth 4 -> scene_tree.json, write {} on failure
write client CollectedLogs -> engine_logs.json, write [] when empty
if owned child has exited: write stdout.log and stderr.log
```

Each artifact request/write gets its own `try/catch`; do not throw merely because one diagnostic failed. Do not inspect gdUnit4Net internal test state.

- [ ] **Step 7: Add cleanup-on-exception regression**

In `ProcessLifecycleTest.cs`:

```csharp
[TestCase]
public async Task AwaitUsingReapsChildWhenTestBodyThrows()
{
    var pid = -1;
    try
    {
        await using var game = await E2EGame.LaunchAsync(TestProject.LaunchOptions());
        pid = game.ProcessId;
        throw new ExpectedTestException();
    }
    catch (ExpectedTestException)
    {
    }

    AssertThat(TestProject.IsProcessRunning(pid)).IsFalse();
}
```

Use a private test exception type; do not rely on a gdUnit-specific failure hook.

- [ ] **Step 8: Add forced-kill regression using the blocking C# fixture method**

Start a `call_method` for `BlockMainThread(5000)` with a 100 ms transport timeout. The timeout closes the client while the child main thread is still blocked. Dispose the game; it must hit the bounded kill fallback and leave no process:

```csharp
var result = await game.SendCommandAsync(
    "call_method",
    new Dictionary<string, object?>
    {
        ["path"] = "/root/Main",
        ["method"] = "BlockMainThread",
        ["args"] = new object?[] { 5000 },
    },
    TimeSpan.FromMilliseconds(100));
AssertThat(result.Success).IsFalse();

await game.DisposeAsync();
AssertThat(TestProject.IsProcessRunning(pid)).IsFalse();
```

This must finish well before the fixture's five-second sleep completes naturally.

- [ ] **Step 9: Run GREEN C# suite plus existing GDScript integration suite**

```bash
dotnet build godot-e2e.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
```

Expected: C# -> C# and existing GDScript -> GDScript paths are green; no cross-language test exists.

- [ ] **Step 10: Commit**

```bash
git add addons/gdunit_e2e/csharp tests/csharp tests/fixtures/csharp/Main.cs
 git commit -m "feat: add csharp e2e game facade"
```

---

### Task 7: Put both language paths through the same CI/release gate and document them separately

**Files:**
- Modify: `.github/workflows/ci.yml`
- Create: `tests/scripts/assert_no_e2e_children.sh`
- Create: `tests/scripts/package_release_test.sh`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-27-csharp-e2e-integration-design.md` (status/verified pins wording only)

**Interfaces:**
- Produces one Linux and one Windows CI job running both language paths.
- Produces reusable survivor check for `--gdunit-e2e` processes.
- Produces package contract proving C# client ships and C# test fixtures do not.
- Produces README with independent GDScript and C# installation/examples and no cross-language promise.

- [ ] **Step 1: Extract the existing survivor scan into one Bash script**

Create `tests/scripts/assert_no_e2e_children.sh` from the current workflow logic:

```bash
#!/usr/bin/env bash
set -euo pipefail

process_snapshot() {
  if [ "${RUNNER_OS:-}" = "Windows" ]; then
    powershell.exe -NoLogo -NoProfile -NonInteractive -Command \
      '$self = $PID; Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $self -and $_.CommandLine } | ForEach-Object { "{0} {1}" -f $_.ProcessId, $_.CommandLine }'
  else
    ps -eo pid=,args=
  fi
}

survivors="$(process_snapshot | while read -r pid command; do
  if [ "$pid" = "$$" ] || [ "$pid" = "$BASHPID" ]; then
    continue
  fi
  case "$command" in
    *--gdunit-e2e*) printf '%s %s\n' "$pid" "$command" ;;
  esac
done)"

if [ -n "$survivors" ]; then
  echo "Found surviving --gdunit-e2e child process(es):" >&2
  echo "$survivors" >&2
  exit 1
fi
```

Replace the duplicated inline survivor code in both existing failure-harness steps with `bash tests/scripts/assert_no_e2e_children.sh`.

- [ ] **Step 2: Add a release-package contract test**

Create `tests/scripts/package_release_test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

./scripts/package_release.sh
archive="dist/godot-e2e-0.1.1.zip"
listing="$(unzip -Z1 "$archive")"

grep -qx 'addons/gdunit_e2e/csharp/GodotE2E.Client.csproj' <<<"$listing"
grep -qx 'addons/gdunit_e2e/csharp/E2EGame.cs' <<<"$listing"
! grep -q '^tests/' <<<"$listing"
! grep -qx 'godot-e2e.csproj' <<<"$listing"
! grep -q '^addons/gdUnit4/' <<<"$listing"
```

This proves the single archive ships the client source/project but not repository C# tests or the fixture project.

- [ ] **Step 3: Update both CI jobs to Godot .NET + .NET 8**

Change both `setup-godot` calls to:

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

Keep the existing `GODOT_BIN` resolution, including Windows `cygpath` conversion.

- [ ] **Step 4: Add build + C# test steps without creating another matrix**

Linux:

```yaml
- name: Build C# fixture
  shell: bash
  run: dotnet build godot-e2e.csproj

- name: Run C# unit and E2E suites
  shell: bash
  run: >-
    xvfb-run --auto-servernum --server-args="-screen 0 1280x720x24"
    dotnet test tests/csharp/GodotE2E.Tests.csproj
```

Windows:

```yaml
- name: Build C# fixture
  shell: bash
  run: dotnet build godot-e2e.csproj

- name: Run C# unit and E2E suites
  shell: bash
  run: dotnet test tests/csharp/GodotE2E.Tests.csproj
```

Keep the existing GDScript unit/integration and expected-failure artifact harness steps.

Add a final survivor check with `if: always()` in each job so it still runs when an earlier test step fails:

```yaml
- name: Verify no E2E child survives
  if: always()
  shell: bash
  run: bash tests/scripts/assert_no_e2e_children.sh
```

- [ ] **Step 5: Upload managed test output on failure**

Extend each artifact upload path with:

```text
TestResults
```

Do not add a separate C# artifact job.

- [ ] **Step 6: Rewrite README entry points as two supported paths**

The README opening should say the addon supports native out-of-process tests in either GDScript/GdUnit4 or C#/gdUnit4Net, while explicitly listing the supported matrix.

Add a C# installation section with exact repository package pins:

```xml
<PackageReference Include="gdUnit4.api" Version="5.0.0" />
<PackageReference Include="gdUnit4.test.adapter" Version="3.0.0" PrivateAssets="all" />
<PackageReference Include="gdUnit4.analyzers" Version="1.0.0" PrivateAssets="all" />
<ProjectReference Include="addons/gdunit_e2e/csharp/GodotE2E.Client.csproj" />
```

Add the minimal C# example:

```csharp
using GdUnit4;
using GodotE2E;
using static GdUnit4.Assertions;

[TestSuite]
public sealed class MainE2ETest
{
    [TestCase]
    public async Task MainIsReady()
    {
        await using var game = await E2EGame.LaunchAsync(new E2ELaunchOptions
        {
            ScenePath = "res://main.tscn",
        });

        AssertThat(await game.GetPropertyAsync<string>("/root/Main/Status", "text"))
            .IsEqual("ready");
    }
}
```

State that normal E2E tests do not need `[RequireGodotRuntime]`; the child is the Godot runtime. Keep the existing GDScript example intact.

Remove the README deferred item saying dedicated Godot .NET/C# support is still deferred. Do not claim `GDScript -> C#` or `C# -> GDScript` support.

- [ ] **Step 7: Update the design status and dependency wording**

Change the C# design status from `Ready for review` to `Approved for implementation` and record the verified pins:

```text
gdUnit4.api 5.0.0
gdUnit4.test.adapter 3.0.0
gdUnit4.analyzers 1.0.0
Microsoft.NET.Test.Sdk 17.14.1
```

Clarify Risk 1 wording: the test project has no **direct** GodotSharp/game-project reference; gdUnit4.api's own transitive GodotSharp dependency stays isolated in the test project and therefore does not constrain the root Godot 4.5.1 project.

- [ ] **Step 8: Run the complete local release gate**

Run:

```bash
./scripts/bootstrap_gdunit4.sh
dotnet build godot-e2e.csproj
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

On Linux, wrap child-launching GDScript/C# commands with the same Xvfb invocation used by CI when no display is available.

Expected: all normal suites pass, the intentional failure harness exits `100`, no child survives, and packaging checks pass.

- [ ] **Step 9: Commit**

```bash
git add .github/workflows/ci.yml README.md docs/superpowers/specs/2026-08-27-csharp-e2e-integration-design.md tests/scripts
 git commit -m "docs: ship csharp e2e integration path"
```

---

## Final PR Gate

Before marking the single feature PR ready:

- [ ] Run `git diff main...HEAD --check`.
- [ ] Confirm no existing GDScript public file was refactored solely for C# reuse.
- [ ] Confirm `GodotE2E.Client.csproj` has no package dependencies.
- [ ] Confirm `GodotE2E.Tests.csproj` does not reference `godot-e2e.csproj`.
- [ ] Confirm no C# test has `[RequireGodotRuntime]`.
- [ ] Confirm every C# child-launching test targets `res://tests/fixtures/csharp/main.tscn`.
- [ ] Confirm no GDScript test targets the C# fixture and no C# test targets a GDScript fixture.
- [ ] Confirm Linux and Windows CI are green using Godot .NET 4.5.1.
- [ ] Confirm the release ZIP contains `addons/gdunit_e2e/csharp/**` and excludes `tests/**`, `godot-e2e.csproj`, `addons/gdUnit4/**`, reports, and test output.
- [ ] Confirm no `--gdunit-e2e` process survives either test path.
