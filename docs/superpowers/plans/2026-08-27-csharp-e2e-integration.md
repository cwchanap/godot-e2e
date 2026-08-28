# C# E2E Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native `C# test -> C# game` E2E path while leaving the existing `GDScript test -> GDScript game` path unchanged.

**Architecture:** Keep the existing GDScript bootstrap, automation server, command handler, protocol v1, diagnostics, and orphan watchdog as the only child runtime. Add a BCL-only .NET 8 parent client using `TcpClient`, `System.Text.Json`, and `System.Diagnostics.Process`; gdUnit4Net/VSTest runs C# tests as ordinary .NET tests without `[RequireGodotRuntime]`, and `E2EGame.RunAsync` captures failure diagnostics before teardown.

**Tech Stack:** Godot .NET 4.5.1, .NET 8 / C# 12, gdUnit4.api 5.0.0, gdUnit4.test.adapter 3.0.0, gdUnit4.analyzers 1.0.0, Microsoft.NET.Test.Sdk 17.14.1, existing localhost TCP protocol v1, GitHub Actions, Xvfb on Linux.

**Spec:** `docs/superpowers/specs/2026-08-27-csharp-e2e-integration-design.md`

## Global Constraints

- One feature PR for design, plan, implementation, tests, CI, and docs; use task-level commits inside that PR.
- Supported matrix is only `GDScript test -> GDScript game` and `C# test -> C# game`.
- Do not add tests, documentation promises, compatibility fixes, or architecture for either cross-language combination.
- Do not refactor the existing GDScript parent merely to share implementation with C#.
- Reuse the existing GDScript child bootstrap/server/command handler and protocol v1 unchanged unless implementation exposes a real compatibility bug.
- `GodotE2E.Client` targets `net8.0` and uses the .NET BCL only: no GodotSharp, gdUnit4Net, third-party socket, or third-party JSON dependency.
- C# repository tests use gdUnit4Net/VSTest but do not reference the root Godot game project.
- Pin test packages to `gdUnit4.api` 5.0.0, `gdUnit4.test.adapter` 3.0.0, `gdUnit4.analyzers` 1.0.0, and `Microsoft.NET.Test.Sdk` 17.14.1.
- Root `project.godot` must declare Godot 4.5, `C#`, and `GL Compatibility`, plus `[dotnet] project/assembly_name="GodotE2E"`.
- Root `godot-e2e.csproj` uses `Godot.NET.Sdk/4.5.1`, targets `net8.0`, assembly name `GodotE2E`, compiles the fixture, and excludes both `tests/csharp/**/*.cs` and `addons/gdunit_e2e/csharp/**/*.cs`.
- Commit `godot-e2e.sln` with only the root game project and commit the generated `tests/fixtures/csharp/Main.cs.uid`.
- Existing GDScript child-launching integration helpers use the product's 10-second launch default; remove non-semantic 5-second overrides.
- Normal C# E2E tests must not use `[RequireGodotRuntime]`.
- Protocol invariants: four-byte unsigned big-endian framing, protocol version `1`, 16 MiB frame cap, `127.0.0.1` only, token hello, increasing IDs, one in-flight command.
- Launch timeout default stays 10 seconds; ordinary command timeout stays 5 seconds; server-side waits and scene reload add a 1-second client margin.
- One child per `E2EGame`; no pool, reuse, parallel sessions, generic RPC layer, generated bindings, locators, retrying expectations, or NuGet publication.
- `E2EGame` uses `IAsyncDisposable`; failure to confirm owned child death is test-visible.
- `E2EGame.RunAsync` is the normal first-party/README lifecycle helper and captures diagnostics when the test body throws.
- `LaunchAsync`, `SendCommandAsync`, and explicit `CaptureFailureArtifactsAsync` remain primitives for lifecycle and negative-path tests.
- Linux + Windows remain the only CI platforms; do not add a C# matrix.
- CI builds the root C# game before any Godot process; the clean-bootstrap temp archive also builds its own root C# project before starting Godot.
- Release remains one archive containing `addons/gdunit_e2e/**`, `README.md`, `LICENSE`, and `NOTICE`.
- RED -> GREEN -> REFACTOR for behavior tasks.

## Planned File Structure

```text
.
├── project.godot
├── godot-e2e.csproj
├── godot-e2e.sln
├── .gitignore
├── .github/workflows/ci.yml
├── README.md
├── addons/gdunit_e2e/
│   ├── client/                         # existing GDScript parent, unchanged
│   ├── protocol/                       # existing protocol contract
│   ├── runtime/                        # existing child bootstrap
│   ├── server/                         # existing child server
│   └── csharp/
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
│   ├── main.tscn
│   ├── Main.cs
│   └── Main.cs.uid
├── tests/csharp/
│   ├── GodotE2E.Tests.csproj
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

Framing owns bytes, `E2EClient` owns one TCP session, `E2EProcess` owns one OS child, and `E2EGame` owns the convenience/lifecycle API.

---

### Task 1: Pin and prove the isolated C# test runner

**Files:**
- Create: `addons/gdunit_e2e/csharp/GodotE2E.Client.csproj`
- Create: `tests/csharp/GodotE2E.Tests.csproj`
- Create: `tests/csharp/RunnerSmokeTest.cs`
- Modify: `.gitignore`

**Interfaces:**
- Produces `GodotE2E.Client`, a pure `net8.0` library.
- Produces a gdUnit4Net test project referencing the client project but not `godot-e2e.csproj`.
- Produces repository command `dotnet test tests/csharp/GodotE2E.Tests.csproj`.

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
    <AssemblyName>GodotE2E.Tests</AssemblyName>
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

Do not add a direct GodotSharp reference and do not reference the root game project.

- [ ] **Step 3: Add a runner-only test with no Godot runtime attribute**

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

- [ ] **Step 4: Ignore managed output**

Append to `.gitignore`:

```gitignore
bin/
obj/
TestResults/
```

- [ ] **Step 5: Restore and run runner smoke**

```bash
dotnet restore tests/csharp/GodotE2E.Tests.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --no-restore --filter "FullyQualifiedName~RunnerSmokeTest"
```

Expected: one passing test and no Godot process.

- [ ] **Step 6: Prove the client project has no package dependencies**

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

### Task 2: Convert the repository to Godot .NET and add the C# fixture

**Files:**
- Modify: `project.godot`
- Create: `godot-e2e.csproj`
- Create: `godot-e2e.sln`
- Create: `tests/fixtures/csharp/Main.cs`
- Create: `tests/fixtures/csharp/Main.cs.uid` (generated by Godot import)
- Create: `tests/fixtures/csharp/main.tscn`
- Modify: `tests/unit/installation_contract_test.gd`
- Modify: `tests/integration/gameplay_smoke_test.gd`
- Modify: `tests/integration/process_lifecycle_test.gd`
- Modify: `tests/integration/server_startup_test.gd`

**Interfaces:**
- Produces a complete Godot .NET 4.5.1 repository project, not only a `.csproj`.
- Produces assembly `GodotE2E` and solution `godot-e2e.sln` containing only the game project.
- Produces C# scene `res://tests/fixtures/csharp/main.tscn` rooted at `/root/Main`.
- Produces fixture methods `Echo`, `SchedulePulse`, `BlockMainThread`, signal `Pulse`, and action/button state.
- Existing GDScript child-launch integration helpers use `E2ELaunchOptions.timeout_seconds == 10.0` by default.

- [ ] **Step 1: Write RED repository-contract assertions**

Extend `tests/unit/installation_contract_test.gd`:

```gdscript
func test_repository_is_a_complete_dotnet_project() -> void:
    var project_text := FileAccess.get_file_as_string("res://project.godot")
    assert_bool(project_text.contains('config/features=PackedStringArray("4.5", "C#", "GL Compatibility")')).is_true()
    assert_bool(project_text.contains('[dotnet]')).is_true()
    assert_bool(project_text.contains('project/assembly_name="GodotE2E"')).is_true()
    assert_bool(FileAccess.file_exists("res://godot-e2e.csproj")).is_true()
    assert_bool(FileAccess.file_exists("res://godot-e2e.sln")).is_true()

func test_csharp_fixture_script_is_uid_backed_after_import() -> void:
    assert_bool(FileAccess.file_exists("res://tests/fixtures/csharp/Main.cs.uid")).is_true()
```

After creating the `.csproj`/solution, also assert their compile/solution boundaries with shell commands in Step 9; do not build an XML parser into GDScript only for this repo contract.

Run before adding the files:

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/installation_contract_test.gd -c
```

Expected: FAIL because the repository is not yet a C# project.

- [ ] **Step 2: Add the project-level C# metadata**

Keep existing settings and add:

```ini
[application]

config/name="godot-e2e"
config/features=PackedStringArray("4.5", "C#", "GL Compatibility")

[dotnet]

project/assembly_name="GodotE2E"
```

Do not change the existing GL Compatibility renderer or GdUnit4 editor-plugin entry.

- [ ] **Step 3: Add the root game project with a narrow compile boundary**

Create `godot-e2e.csproj`:

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

The exclusions are for this repository fixture project only. Do not add corresponding consumer-install requirements.

- [ ] **Step 4: Generate the solution containing only the game project**

```bash
rm -f godot-e2e.sln
dotnet new sln --name godot-e2e
dotnet sln godot-e2e.sln add godot-e2e.csproj
dotnet sln godot-e2e.sln list
```

Expected list:

```text
godot-e2e.csproj
```

Do not add `tests/csharp/GodotE2E.Tests.csproj`.

- [ ] **Step 5: Add the C# fixture**

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

Create `tests/fixtures/csharp/main.tscn` initially with a path-based script resource:

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

`BlockMainThread` is fixture-only behavior for the process-kill regression.

- [ ] **Step 6: Build before the first Godot .NET import**

```bash
dotnet build godot-e2e.csproj
```

Expected: game assembly builds without compiling `tests/csharp/**` or `addons/gdunit_e2e/csharp/**`.

- [ ] **Step 7: Import once, commit the generated C# UID, and bind it into the fixture scene**

Run with the Godot .NET 4.5.1 executable:

```bash
"$GODOT_BIN" --headless --editor --path . --quit
test -f tests/fixtures/csharp/Main.cs.uid
```

Read the generated UID and update the fixture's ext-resource line to include it:

```bash
uid="$(cat tests/fixtures/csharp/Main.cs.uid)"
python3 - "$uid" <<'PY'
from pathlib import Path
import sys
uid = sys.argv[1].strip()
path = Path("tests/fixtures/csharp/main.tscn")
text = path.read_text()
old = '[ext_resource type="Script" path="res://tests/fixtures/csharp/Main.cs" id="1_main"]'
new = f'[ext_resource type="Script" path="res://tests/fixtures/csharp/Main.cs" id="1_main" uid="{uid}"]'
path.write_text(text.replace(old, new))
PY
```

Re-open once to validate the UID-backed scene:

```bash
"$GODOT_BIN" --headless --editor --path . --quit
```

- [ ] **Step 8: Remove the obsolete 5-second ordinary-launch overrides**

Delete only these lines:

```gdscript
options.timeout_seconds = 5.0
```

from:

```text
tests/integration/gameplay_smoke_test.gd
tests/integration/process_lifecycle_test.gd
tests/integration/server_startup_test.gd
```

Keep explicit short timeouts that are themselves under test, such as `0.25` for invalid startup configuration.

This makes ordinary integration launches inherit `E2ELaunchOptions.timeout_seconds == 10.0` instead of duplicating another constant.

- [ ] **Step 9: Run GREEN repository + existing GDScript gates now**

```bash
grep -q '<AssemblyName>GodotE2E</AssemblyName>' godot-e2e.csproj
grep -Fq '<Compile Remove="tests/csharp/**/*.cs" />' godot-e2e.csproj
grep -Fq '<Compile Remove="addons/gdunit_e2e/csharp/**/*.cs" />' godot-e2e.csproj
test "$(dotnet sln godot-e2e.sln list | grep -c '\.csproj$')" -eq 1
dotnet sln godot-e2e.sln list | grep -q '^godot-e2e.csproj$'
dotnet build godot-e2e.csproj
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
```

On Linux without a display, wrap the GDScript command in the same Xvfb invocation used by CI.

Expected: project boundary checks, build, and all existing GDScript tests pass under Godot .NET before C# transport work starts.

- [ ] **Step 10: Commit**

```bash
git add project.godot godot-e2e.csproj godot-e2e.sln tests/fixtures/csharp tests/unit/installation_contract_test.gd tests/integration
git commit -m "test: add godot dotnet fixture project"
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
- Produces `E2EProtocol.ProtocolVersion = 1`, `MaxFrameBytes = 16 MiB`, `DefaultCommandTimeout = 5s`, `WaitMargin = 1s`.
- Produces `E2EFraming.Encode(JsonElement) -> byte[]` and `ReadAsync(Stream, CancellationToken) -> Task<JsonElement>`.
- Produces `E2EJson.NormalizeForWire(object?) -> object?` and `Convert<T>(JsonElement) -> T`.
- Produces `E2EVector2(double X, double Y)` as the first tagged stand-in.
- Produces raw `E2EResult` with `Success`, cloned `Response`, `Message`, and `Logs`.

- [ ] **Step 1: Write RED framing/value tests**

Create `tests/csharp/ProtocolTest.cs`:

```csharp
namespace GodotE2E.Tests;

using System.Buffers.Binary;
using System.Text.Json;
using GdUnit4;
using GodotE2E;
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
    public async Task OversizedDeclarationFailsBeforeReadingBody()
    {
        var header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, E2EProtocol.MaxFrameBytes + 1u);
        await using var stream = new MemoryStream(header);
        var threw = false;
        try
        {
            _ = await E2EFraming.ReadAsync(stream, CancellationToken.None);
        }
        catch (E2EException)
        {
            threw = true;
        }
        AssertThat(threw).IsTrue();
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

    [TestCase]
    public void RemoteNullCanMapToNullableResult()
    {
        var value = JsonSerializer.SerializeToElement<object?>(null);
        AssertThat(E2EJson.Convert<object?>(value)).IsNull();
    }

    private sealed class ChunkedReadStream(byte[] bytes, int chunkSize) : MemoryStream(bytes)
    {
        public override ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            var count = Math.Min(buffer.Length, chunkSize);
            return base.ReadAsync(buffer[..count], cancellationToken);
        }
    }
}
```

- [ ] **Step 2: Run RED**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest"
```

Expected: compile fails because protocol types do not exist.

- [ ] **Step 3: Add the exact public protocol constants/result shapes**

```csharp
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

public sealed record E2EResult(
    bool Success,
    JsonElement Response,
    string Message,
    IReadOnlyList<JsonElement> Logs)
{
    public static E2EResult Failure(string message) =>
        new(false, default, message, Array.Empty<JsonElement>());
}
```

Clone `JsonElement` values that outlive their source `JsonDocument`.

- [ ] **Step 4: Implement framing with validation before body allocation**

Encode:

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

Use an exact-read loop; if a read returns `0`, throw `E2EException("Connection closed while reading E2E frame")`. `ReadAsync` reads four bytes, rejects oversized declarations, then allocates/parses the body and requires a JSON object root.

- [ ] **Step 5: Implement only conversion needed by the first C# API**

`NormalizeForWire` handles null, primitives, string-keyed dictionaries, object sequences, and `E2EVector2`:

```csharp
E2EVector2 v => new Dictionary<string, object?>
{
    ["_t"] = "v2",
    ["x"] = v.X,
    ["y"] = v.Y,
}
```

`Convert<T>` accepts JSON null first, recognizes `v2` for `E2EVector2`, and otherwise uses `JsonElement.Deserialize<T>()`, wrapping `JsonException` in `E2EException`.

Do not implement the full Godot Variant set.

- [ ] **Step 6: Run GREEN C# protocol + existing GDScript serializer tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest"
./addons/gdUnit4/runtest.sh -a tests/unit/serializer_test.gd -c
```

Expected: both pass.

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
- Produces `ConnectAsync(int port, string token, TimeSpan timeout, CancellationToken = default)`.
- Produces `SendCommandAsync(string action, IReadOnlyDictionary<string, object?>? parameters = null, TimeSpan? timeout = null, CancellationToken = default)`.
- Produces `IsSessionOpen`, `CollectedLogs`, and idempotent `DisposeAsync`.
- One concurrent request attempt fails immediately with `A command is already in flight`.

- [ ] **Step 1: Add a loopback fake protocol server**

Create `FakeProtocolServer` with a `TcpListener(IPAddress.Loopback, 0)`, expose its chosen `Port`, accept one client, read requests with `E2EFraming.ReadAsync`, record cloned request JSON, and reply with `E2EFraming.Encode`.

Provide helpers:

```csharp
Task<JsonElement> ReadRequestAsync(CancellationToken cancellationToken = default)
Task ReplyAsync(object response, CancellationToken cancellationToken = default)
```

The fake is pure .NET; do not reuse the GDScript `Node` fake.

- [ ] **Step 2: Write RED client tests**

Pin:

```text
hello request:
{id:1, action:"hello", token:"secret", protocol_version:1}

first ordinary request id: 2
host: 127.0.0.1 only
error rendering: error + message when both differ
_logs removed from Response but appended to CollectedLogs
one-in-flight request rejected locally
timeout/disconnect returns failed E2EResult and closes the session
```

Use the fake server to return partial frames by writing response bytes in small chunks for at least one test.

- [ ] **Step 3: Run RED**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ClientTest"
```

Expected: compile failure for missing `E2EClient`.

- [ ] **Step 4: Implement the client with one request gate**

Use `TcpClient`, `NetworkStream`, and a `SemaphoreSlim(1, 1)` only as a fail-fast in-flight guard; do not queue a second request.

For each request:

```text
allocate id
normalize parameters
encode frame
write all bytes
read one complete frame
validate response id
extract _logs / _logs_dropped
strip log transport fields from public response
render existing error/message semantics
release in-flight state
```

Cancellation/timeout uses a linked `CancellationTokenSource`. Ordinary default timeout is `E2EProtocol.DefaultCommandTimeout`.

- [ ] **Step 5: Run GREEN raw-client tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ClientTest"
```

Expected: all pass without Godot.

- [ ] **Step 6: Commit**

```bash
git add addons/gdunit_e2e/csharp/E2EClient.cs tests/csharp/FakeProtocolServer.cs tests/csharp/ClientTest.cs
git commit -m "feat: add csharp e2e tcp client"
```

---

### Task 5: Add Godot child launch, authentication, stdout/stderr draining, and reap

**Files:**
- Create: `addons/gdunit_e2e/csharp/E2ELaunchOptions.cs`
- Create: `addons/gdunit_e2e/csharp/E2EProcess.cs`
- Create: `addons/gdunit_e2e/csharp/E2EGame.cs` (launch/raw/dispose shell only)
- Create: `tests/csharp/TestProject.cs`
- Create: `tests/csharp/ProcessLifecycleTest.cs`

**Interfaces:**
- Produces `E2ELaunchOptions` defaults matching the design.
- Produces `E2EProcess.LaunchAsync` and idempotent `DisposeAsync`.
- Produces process diagnostics: `ProcessId`, `ProjectPath`, `Stdout`, `Stderr`, `HasExited`.
- Produces `E2EGame.LaunchAsync`, raw `SendCommandAsync`, `ProcessId`, and `DisposeAsync`.

- [ ] **Step 1: Write RED launch-argument and resolution tests**

Pin argument order against the existing GDScript contract:

```text
--path <project>
--scene <bootstrap>
<extra Godot args>
--
--gdunit-e2e
--gdunit-e2e-target-scene=<scene>
--gdunit-e2e-port=0
--gdunit-e2e-port-file=<path>
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=<level>
```

Also pin:

```text
ProjectPath omitted -> walk upward for project.godot
GodotPath -> GODOT_BIN first, otherwise executable name "godot" for PATH lookup
ScenePath empty -> fail before Process.Start
BootstrapScenePath default -> res://addons/gdunit_e2e/runtime/bootstrap.tscn
Timeout default -> 10 seconds
```

- [ ] **Step 2: Run RED lifecycle tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
```

Expected: compile failure for missing process/session types.

- [ ] **Step 3: Implement process launch with immediate pipe drains**

`ProcessStartInfo`:

```csharp
UseShellExecute = false
RedirectStandardOutput = true
RedirectStandardError = true
WorkingDirectory = resolved project path
```

Immediately after `Process.Start()`:

```csharp
var stdoutTask = process.StandardOutput.ReadToEndAsync();
var stderrTask = process.StandardError.ReadToEndAsync();
```

Do not wait until teardown to start reading either pipe.

Use a random token and temp directory/port file. Poll every ~25 ms until:

```text
process exits -> fail with exit + collected diagnostics
valid port file appears -> continue
launch timeout expires -> reap then throw E2EException
```

- [ ] **Step 4: Authenticate before returning the session**

After port discovery:

```csharp
var client = new E2EClient();
var hello = await client.ConnectAsync(port, token, options.Timeout, cancellationToken);
if (!hello.Success)
{
    await process.DisposeAsync();
    throw new E2EException($"Child E2E handshake failed: {hello.Message}");
}
```

`E2EGame.LaunchAsync` returns an `E2EGame` owning the successful process/client.

- [ ] **Step 5: Implement bounded normal shutdown + kill fallback**

Order:

```text
if session open -> raw quit, 500 ms timeout, failure ignored
Dispose client
wait at most 1 second for process exit
if alive -> Process.Kill(entireProcessTree: true)
wait at most 1 second again
if dead -> await stdout/stderr drain tasks and store strings
delete port file/temp directory best effort
if still alive -> throw E2EException with PID
```

Use `Process.WaitForExitAsync` with a timeout CTS. Later `DisposeAsync` calls return immediately after successful cleanup.

- [ ] **Step 6: Add the shared repository integration helper using the 10-second default**

Create `tests/csharp/TestProject.cs`:

```csharp
namespace GodotE2E.Tests;

using System.Diagnostics;
using GodotE2E;

internal static class TestProject
{
    public static string RepositoryRoot { get; } = FindRepositoryRoot();

    public static E2ELaunchOptions LaunchOptions() => new()
    {
        ProjectPath = RepositoryRoot,
        GodotPath = Environment.GetEnvironmentVariable("GODOT_BIN"),
        ScenePath = "res://tests/fixtures/csharp/main.tscn",
        ExtraGodotArgs = ["--quiet"],
        // Do not override Timeout: use the product default of 10 seconds.
    };

    public static bool IsProcessRunning(int pid)
    {
        if (pid <= 0)
            return false;
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    private static string FindRepositoryRoot()
    {
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            for (var current = new DirectoryInfo(Path.GetFullPath(start)); current is not null; current = current.Parent)
            {
                if (File.Exists(Path.Combine(current.FullName, "project.godot")))
                    return current.FullName;
            }
        }
        throw new InvalidOperationException("Unable to locate godot-e2e repository root");
    }
}
```

- [ ] **Step 7: Add the first real `C# -> C#` lifecycle test**

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

- [ ] **Step 8: Build first, then run GREEN lifecycle tests**

```bash
dotnet build godot-e2e.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
```

Expected: real Godot .NET child launches through the unchanged GDScript bootstrap/server and is reaped.

- [ ] **Step 9: Commit**

```bash
git add addons/gdunit_e2e/csharp tests/csharp/TestProject.cs tests/csharp/ProcessLifecycleTest.cs
git commit -m "feat: launch csharp godot e2e child"
```

---

### Task 6: Add the lean C# facade, wait-margin unit seam, RunAsync artifacts, and cleanup regressions

**Files:**
- Create: `addons/gdunit_e2e/csharp/AssemblyInfo.cs`
- Modify: `addons/gdunit_e2e/csharp/E2EClient.cs`
- Modify: `addons/gdunit_e2e/csharp/E2EGame.cs`
- Modify: `addons/gdunit_e2e/csharp/E2EJson.cs`
- Modify: `addons/gdunit_e2e/csharp/E2EProcess.cs`
- Create: `tests/csharp/GameApiTest.cs`
- Modify: `tests/csharp/ProcessLifecycleTest.cs`
- Create: `tests/csharp/GameplaySmokeTest.cs`

**Interfaces:**
- Public wrappers are limited to:
  - `NodeExistsAsync`
  - `GetPropertyAsync<T>`
  - `SetPropertyAsync`
  - `CallMethodAsync<T>`
  - `GetSceneAsync`
  - `InputActionAsync`
  - `PressActionAsync`
  - `ClickNodeAsync`
  - `WaitForPropertyAsync`
  - `WaitForSignalAsync`
  - `ReloadSceneAsync`
  - `ScreenshotAsync`
  - `CaptureFailureArtifactsAsync`
  - `RunAsync`
  - raw `SendCommandAsync`
- `GetTreeAsync`, key/mouse wrappers, frame/seconds waits, `WaitForNodeAsync`, and `ChangeSceneAsync` remain raw-command only in this release.
- Wrapped failures throw `E2EException`; raw server failures stay in `E2EResult`.

- [ ] **Step 1: Add the smallest internal command-sender seam for wrapper unit tests**

Add an internal interface next to `E2EGame` or `E2EClient`:

```csharp
internal interface IE2ECommandSender
{
    Task<E2EResult> SendCommandAsync(
        string action,
        IReadOnlyDictionary<string, object?>? parameters = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default);
}
```

`E2EClient` implements it. `E2EGame` gets an internal non-owning test constructor accepting `IE2ECommandSender`; production construction still owns an `E2EProcess`.

Create `addons/gdunit_e2e/csharp/AssemblyInfo.cs`:

```csharp
using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("GodotE2E.Tests")]
```

Do not expose the test seam as public API. The non-owning test instance has no process to dispose; `DisposeAsync()` is a no-op for it.

- [ ] **Step 2: Write the RED wait-margin unit test**

Create `tests/csharp/GameApiTest.cs` with a recording sender. Return the response shape each wrapper actually consumes so the test fails only on timeout forwarding:

```csharp
private sealed class RecordingSender : IE2ECommandSender
{
    public List<(string Action, TimeSpan? Timeout)> Calls { get; } = [];

    public Task<E2EResult> SendCommandAsync(
        string action,
        IReadOnlyDictionary<string, object?>? parameters = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        Calls.Add((action, timeout));
        var response = action switch
        {
            "wait_for_property" => JsonSerializer.SerializeToElement(new { id = 1, ok = true }),
            "wait_for_signal" => JsonSerializer.SerializeToElement(new { id = 1, result = Array.Empty<object>() }),
            "reload_scene" => JsonSerializer.SerializeToElement(new { id = 1, ok = true }),
            _ => throw new InvalidOperationException($"Unexpected action: {action}"),
        };
        return Task.FromResult(new E2EResult(true, response, "", Array.Empty<JsonElement>()));
    }
}
```

Pin the client deadlines:

```csharp
[TestCase]
public async Task WaitWrappersAddTransportMargin()
{
    var sender = new RecordingSender();
    await using var game = new E2EGame(sender);

    _ = await game.WaitForPropertyAsync("/root/Main", "value", 1, TimeSpan.FromSeconds(2));
    _ = await game.WaitForSignalAsync("/root/Main", "Pulse", TimeSpan.FromSeconds(3));
    await game.ReloadSceneAsync();

    AssertThat(sender.Calls[0].Timeout).IsEqual(TimeSpan.FromSeconds(3));
    AssertThat(sender.Calls[1].Timeout).IsEqual(TimeSpan.FromSeconds(4));
    AssertThat(sender.Calls[2].Timeout).IsEqual(
        E2EProtocol.DefaultCommandTimeout + E2EProtocol.WaitMargin);
}
```

This is the C# equivalent of the existing GDScript fake-client contract; do not add another server timing-race integration test.

- [ ] **Step 3: Write RED gameplay tests against only the C# fixture**

```csharp
[TestCase]
public async Task DrivesCSharpGameThroughWrappedApi()
{
    await E2EGame.RunAsync(TestProject.LaunchOptions(), async (game, _) =>
    {
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
    });
}
```

Add signal/reload and raw-negative cases using the same C# fixture. Schedule the signal before waiting because the client permits one in-flight command.

- [ ] **Step 4: Run RED wrapper tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~GameApiTest|FullyQualifiedName~GameplaySmokeTest"
```

Expected: compile failures for missing wrapper/test-seam methods.

- [ ] **Step 5: Implement wrappers through one failure-mapping helper**

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

Response mapping:

```text
node_exists       -> response.exists
get_property      -> E2EJson.Convert<T>(response.result)
set_property      -> success only
call_method       -> E2EJson.Convert<T>(response.result), including JSON null
get_scene         -> response.scene
input_action      -> success only
press_action      -> input_action pressed=true then pressed=false
click_node        -> success only
wait_for_property -> server timeout in seconds; transport timeout = timeout + 1s; return true on success
wait_for_signal   -> same margin; response.result or response.args
reload_scene      -> default command timeout + 1s
screenshot        -> response.path
```

Do not implement the deferred wrappers.

- [ ] **Step 6: Implement explicit best-effort artifacts**

`CaptureFailureArtifactsAsync(outputDirectory)`:

```text
Directory.CreateDirectory(outputDirectory)
try raw screenshot -> screenshot.png
try raw get_tree {path:"/root", depth:4} -> scene_tree.json; {} on unavailable tree
write current client CollectedLogs -> engine_logs.json; [] when empty
if child already exited -> stdout.log and stderr.log from E2EProcess
```

Each diagnostic is independent and catches its own exception. A diagnostic failure must not replace the caller's primary failure.

- [ ] **Step 7: Implement `RunAsync` as the normal failure-capturing lifecycle**

Public signature:

```csharp
public static async Task RunAsync(
    E2ELaunchOptions options,
    Func<E2EGame, CancellationToken, Task> body,
    CancellationToken cancellationToken = default)
```

Behavior skeleton:

```csharp
var game = await LaunchAsync(options, cancellationToken);
string? failureDirectory = null;
try
{
    await body(game, cancellationToken);
}
catch
{
    failureDirectory = game.CreateDefaultFailureArtifactDirectory();
    await game.CaptureFailureArtifactsAsync(failureDirectory, CancellationToken.None);
    throw;
}
finally
{
    try
    {
        await game.DisposeAsync();
    }
    finally
    {
        if (failureDirectory is not null)
            game.WriteExitedProcessArtifactsBestEffort(failureDirectory);
    }
}
```

`CreateDefaultFailureArtifactDirectory()` uses the resolved project path and creates:

```text
test_output/csharp/<UTC timestamp>-<8-char guid>/
```

Keep this helper internal/private; callers that need a known path still call `CaptureFailureArtifactsAsync(path)` explicitly.

- [ ] **Step 8: Add a RED/GREEN regression proving RunAsync captures a thrown test body**

Before the test, remove `test_output/csharp` if present. Run:

```csharp
try
{
    await E2EGame.RunAsync(TestProject.LaunchOptions(), (_, _) =>
        throw new ExpectedTestException());
}
catch (ExpectedTestException)
{
}
```

Then assert exactly one new failure directory exists and contains:

```text
screenshot.png
scene_tree.json
engine_logs.json
stdout.log
stderr.log
```

Also assert no child PID remains alive. This verifies the README path, not only explicit artifact capture.

- [ ] **Step 9: Add forced-kill regression using fixture behavior only**

Launch with the primitive `LaunchAsync`, call `BlockMainThread(5000)` with a 100 ms transport timeout, then dispose. Assert the process is dead within 4 seconds. Do not add a production-only force-kill toggle.

- [ ] **Step 10: Run GREEN same-language suites**

```bash
dotnet build godot-e2e.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
```

Expected: `C# -> C#` and existing `GDScript -> GDScript` are green; no cross-language test exists.

- [ ] **Step 11: Commit**

```bash
git add addons/gdunit_e2e/csharp tests/csharp
git commit -m "feat: add csharp e2e game lifecycle"
```

---

### Task 7: Put both supported paths through the same CI/release gate and document RunAsync

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `tests/scripts/bootstrap_gdunit4_import_test.sh`
- Create: `tests/scripts/assert_no_e2e_children.sh`
- Create: `tests/scripts/package_release_test.sh`
- Modify: `README.md`

**Interfaces:**
- Produces one Linux and one Windows job running both same-language paths.
- Ensures the root game assembly is built before any Godot process in CI.
- Ensures the clean archived project builds its own C# assembly before Godot import.
- Produces reusable survivor and release-package gates.
- README uses `RunAsync` as the normal C# example.

- [ ] **Step 1: Make the clean-bootstrap test build the archived C# project before Godot**

In `tests/scripts/bootstrap_gdunit4_import_test.sh`, after extracting `HEAD` and copying `addons/gdUnit4`, add:

```bash
if [ -f "$TEST_ROOT/godot-e2e.csproj" ]; then
    dotnet build "$TEST_ROOT/godot-e2e.csproj"
fi
```

This is required because `git archive HEAD` does not contain the root workspace's `bin/obj` outputs.

Keep the existing class-cache assertions after bootstrap/import.

- [ ] **Step 2: Extract the duplicated survivor scan**

Create `tests/scripts/assert_no_e2e_children.sh`:

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

Replace both duplicated workflow survivor blocks with this script.

- [ ] **Step 3: Add the package contract**

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
! grep -qx 'godot-e2e.sln' <<<"$listing"
! grep -q '^addons/gdUnit4/' <<<"$listing"
```

- [ ] **Step 4: Switch each existing CI job to Godot .NET + .NET 8**

Use:

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

- [ ] **Step 5: Make CI ordering explicit: build before every Godot process**

Immediately after setup + `GODOT_BIN` resolution, before `Bootstrap GdUnit4`, add:

```yaml
- name: Build Godot .NET project
  shell: bash
  run: dotnet build godot-e2e.csproj
```

Then preserve this order:

```text
Build Godot .NET project
Bootstrap GdUnit4
Verify clean bootstrap import
Run GDScript unit/integration suites
Run C# unit/E2E suites
Run expected-failure harness
Verify no child survives
```

`bootstrap_gdunit4.sh` itself launches Godot for import when `GODOT_BIN` is set, so the build must precede that step.

- [ ] **Step 6: Add the C# suite to the same OS jobs**

Linux:

```yaml
- name: Run C# unit and E2E suites
  shell: bash
  run: >-
    xvfb-run --auto-servernum --server-args="-screen 0 1280x720x24"
    dotnet test tests/csharp/GodotE2E.Tests.csproj
```

Windows:

```yaml
- name: Run C# unit and E2E suites
  shell: bash
  run: dotnet test tests/csharp/GodotE2E.Tests.csproj
```

Keep existing GDScript suite and intentional-failure harness.

- [ ] **Step 7: Add survivor/package gates and managed artifacts**

Both jobs:

```yaml
- name: Verify no E2E child survives
  if: always()
  shell: bash
  run: bash tests/scripts/assert_no_e2e_children.sh
```

Linux only:

```yaml
- name: Verify release package
  shell: bash
  run: bash tests/scripts/package_release_test.sh
```

Add `TestResults` to both failure artifact uploads. `test_output` is already uploaded and now also contains automatic C# `RunAsync` diagnostics.

- [ ] **Step 8: Rewrite README introduction/install into two separate supported paths**

Document matrix:

```text
GDScript test -> GDScript game   supported
C# test       -> C# game         supported
GDScript test -> C# game         not supported/tested
C# test       -> GDScript game   not supported/tested
```

Keep current GDScript example/lifecycle guidance.

Add C# test-project references:

```xml
<PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
<PackageReference Include="gdUnit4.api" Version="5.0.0" />
<PackageReference Include="gdUnit4.test.adapter" Version="3.0.0" PrivateAssets="all" />
<PackageReference Include="gdUnit4.analyzers" Version="1.0.0" PrivateAssets="all" />
<ProjectReference Include="../../addons/gdunit_e2e/csharp/GodotE2E.Client.csproj" />
```

Normal C# example must use `RunAsync`, not bare `await using`:

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
        await E2EGame.RunAsync(new E2ELaunchOptions
        {
            ScenePath = "res://main.tscn",
        }, async (game, _) =>
        {
            AssertThat(await game.GetPropertyAsync<string>("/root/Main/Status", "text"))
                .IsEqual("ready");
        });
    }
}
```

State:

```text
- normal C# E2E tests do not need [RequireGodotRuntime]
- RunAsync captures screenshot/tree/logs before teardown when the body throws and appends stdout/stderr after exit
- LaunchAsync + await using remains available for custom lifecycle/negative-path tests
- automatic artifacts live under test_output/csharp/<timestamp>-<id>/
```

Remove the old deferred item that says dedicated C#/.NET support is not included.

- [ ] **Step 9: Run the complete local release gate in the same safe order**

```bash
dotnet build godot-e2e.csproj
./scripts/bootstrap_gdunit4.sh
dotnet list addons/gdunit_e2e/csharp/GodotE2E.Client.csproj package
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

If `GODOT_BIN` is set, keep `dotnet build godot-e2e.csproj` before `bootstrap_gdunit4.sh` because bootstrap itself launches Godot. On Linux without a display, wrap child-launching commands in the same Xvfb invocation used by CI.

Expected:

```text
GodotE2E.Client has no package references
GDScript -> GDScript passes
C# -> C# passes
intentional failure harness exits 100 and keeps artifacts
no child survives
release ZIP contract passes
```

- [ ] **Step 10: Commit**

```bash
git add .github/workflows/ci.yml README.md tests/scripts
git commit -m "docs: ship csharp e2e integration path"
```

---

## Final PR Gate

Before marking the single feature PR ready:

- [ ] Run `git diff main...HEAD --check`.
- [ ] Confirm only the two same-language combinations are tested/documented.
- [ ] Confirm no existing GDScript public implementation was refactored solely for C# sharing.
- [ ] Confirm `project.godot` requires `4.5`, `C#`, and `GL Compatibility` and names assembly `GodotE2E`.
- [ ] Confirm `godot-e2e.sln` contains only `godot-e2e.csproj`.
- [ ] Confirm `Main.cs.uid` is committed.
- [ ] Confirm root game project excludes both `tests/csharp/**` and `addons/gdunit_e2e/csharp/**`.
- [ ] Confirm ordinary GDScript integration launches no longer override the default with 5 seconds.
- [ ] Confirm `GodotE2E.Client.csproj` has no package dependencies.
- [ ] Confirm `GodotE2E.Tests.csproj` does not reference `godot-e2e.csproj`.
- [ ] Confirm no normal C# test has `[RequireGodotRuntime]`.
- [ ] Confirm first-party normal C# E2E tests and README use `RunAsync`.
- [ ] Confirm `GameApiTest` pins the +1 second transport margin without a duplicate integration race.
- [ ] Confirm every C# child-launching test targets `res://tests/fixtures/csharp/main.tscn`.
- [ ] Confirm no GDScript test targets the C# fixture and no C# test targets a GDScript fixture.
- [ ] Confirm CI builds `godot-e2e.csproj` before `bootstrap_gdunit4.sh` and that the clean temp archive builds its own project before Godot import.
- [ ] Confirm Linux and Windows CI are green using Godot .NET 4.5.1.
- [ ] Confirm the release ZIP contains `addons/gdunit_e2e/csharp/**` and excludes `tests/**`, root `.csproj`/`.sln`, `addons/gdUnit4/**`, reports, and test output.
- [ ] Confirm no `--gdunit-e2e` process survives either test path.
