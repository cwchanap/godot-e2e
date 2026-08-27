# C# E2E Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native `C# test -> C# game` E2E path while leaving the existing `GDScript test -> GDScript game` path unchanged.

**Architecture:** Keep the existing GDScript bootstrap, automation server, command handler, protocol v1, diagnostics, and orphan watchdog as the only child runtime. Add a BCL-only .NET 8 parent client using `TcpClient`, `System.Text.Json`, and `System.Diagnostics.Process`; gdUnit4Net/VSTest runs the C# tests as ordinary .NET tests without `[RequireGodotRuntime]`, and those tests launch the Godot .NET game as the real child process.

**Tech Stack:** Godot .NET 4.5.1, .NET 8 / C# 12, gdUnit4.api 5.0.0, gdUnit4.test.adapter 3.0.0, gdUnit4.analyzers 1.0.0, Microsoft.NET.Test.Sdk 17.14.1, existing localhost TCP protocol v1, GitHub Actions, Xvfb on Linux.

**Spec:** `docs/superpowers/specs/2026-08-27-csharp-e2e-integration-design.md`

## Global Constraints

- One feature PR for design, plan, implementation, tests, CI, and docs; use task-level commits inside that PR.
- Supported matrix is only `GDScript test -> GDScript game` and `C# test -> C# game`.
- Do not add tests, documentation promises, compatibility fixes, or architecture for either cross-language combination.
- Do not refactor the existing GDScript parent implementation merely to share code with C#.
- Reuse the existing GDScript child bootstrap/server/command handler and protocol v1 unchanged unless implementation exposes a real compatibility bug.
- `GodotE2E.Client` targets `net8.0` and uses the .NET BCL only: no GodotSharp, gdUnit4Net, third-party socket, or third-party JSON dependency.
- C# repository tests use gdUnit4Net/VSTest but do not reference the root Godot game project.
- Pin repository test packages to `gdUnit4.api` 5.0.0, `gdUnit4.test.adapter` 3.0.0, `gdUnit4.analyzers` 1.0.0, and `Microsoft.NET.Test.Sdk` 17.14.1.
- Root Godot project uses `Godot.NET.Sdk/4.5.1`, targets `net8.0`, compiles the C# fixture, and excludes `tests/csharp/**/*.cs`.
- Normal C# E2E tests must not use `[RequireGodotRuntime]`.
- Protocol invariants: four-byte unsigned big-endian framing, protocol version `1`, 16 MiB frame cap, `127.0.0.1` only, token hello, monotonically increasing IDs, one in-flight command.
- Launch timeout default stays 10 seconds; ordinary command timeout stays 5 seconds; server-side waits add a 1-second client margin.
- One child per `E2EGame`; no pool, reuse, parallel sessions, generic RPC layer, generated bindings, or NuGet publication.
- `E2EGame` uses `IAsyncDisposable`; failure to confirm owned child death is test-visible.
- Explicit `CaptureFailureArtifactsAsync()` is required; automatic arbitrary gdUnit4Net assertion-failure hooks remain deferred.
- Linux + Windows remain the only CI platforms; do not add a C# matrix.
- Release remains one archive containing `addons/gdunit_e2e/**`, `README.md`, `LICENSE`, and `NOTICE`.
- RED -> GREEN -> REFACTOR for behavior tasks.

## Planned File Structure

```text
.
├── godot-e2e.csproj
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

Framing owns bytes, `E2EClient` owns one TCP session, `E2EProcess` owns one OS child, and `E2EGame` owns the public convenience API. Keep those boundaries separate.

---

### Task 1: Pin and prove the isolated C# test runner

**Files:**
- Create: `addons/gdunit_e2e/csharp/GodotE2E.Client.csproj`
- Create: `tests/csharp/GodotE2E.Tests.csproj`
- Create: `tests/csharp/RunnerSmokeTest.cs`
- Modify: `.gitignore`

**Interfaces:**
- Produces `GodotE2E.Client`, a pure `.NET 8` library for later client sources.
- Produces a gdUnit4Net test project referencing the client project but not `godot-e2e.csproj`.
- Produces the repository command `dotnet test tests/csharp/GodotE2E.Tests.csproj`.

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

`gdUnit4.api` may bring GodotSharp transitively into this test project's dependency graph. That is acceptable because this project stays isolated from the Godot 4.5.1 game project; do not add a direct GodotSharp reference.

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

Append:

```gitignore
bin/
obj/
TestResults/
```

- [ ] **Step 5: Restore and run the runner smoke test**

```bash
dotnet restore tests/csharp/GodotE2E.Tests.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --no-restore --filter "FullyQualifiedName~RunnerSmokeTest"
```

Expected: one passing test, with no Godot process involved.

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

### Task 2: Make the repository a Godot .NET project and add one C# game fixture

**Files:**
- Create: `godot-e2e.csproj`
- Create: `tests/fixtures/csharp/Main.cs`
- Create: `tests/fixtures/csharp/main.tscn`

**Interfaces:**
- Produces a Godot .NET 4.5.1 game assembly containing the C# fixture.
- Produces scene `res://tests/fixtures/csharp/main.tscn` with root `/root/Main`.
- Produces fixture methods `Echo(string)`, `SchedulePulse(double)`, `BlockMainThread(int)`, signal `Pulse`, and properties `ActionCount` / `ActionPressed`.

- [ ] **Step 1: Add the root Godot .NET project boundary**

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

Do not reference gdUnit4Net from this project. The BCL-only addon client sources may compile into the game assembly; this avoids requiring consumer `.csproj` edits merely to install the addon.

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

`BlockMainThread` is fixture-only behavior used to prove kill fallback; do not add a production launcher switch for that test.

- [ ] **Step 3: Add the fixture scene with stable paths**

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

```bash
dotnet build godot-e2e.csproj
```

Expected: `Godot.NET.Sdk/4.5.1` build passes and `tests/csharp/**/*.cs` is not part of the game assembly.

- [ ] **Step 5: Run the existing GDScript unit suite**

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit -c
```

Expected: existing unit tests pass with no GDScript public API change.

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
- Produces `E2EProtocol.ProtocolVersion`, `MaxFrameBytes`, `DefaultCommandTimeout`, `WaitMargin`.
- Produces `E2EFraming.Encode(JsonElement) -> byte[]` and `ReadAsync(Stream, CancellationToken) -> Task<JsonElement>`.
- Produces `E2EJson.NormalizeForWire(object?) -> object?` and `Convert<T>(JsonElement) -> T`.
- Produces `E2EVector2(double X, double Y)` as the first required tagged value.
- Produces `E2EResult(bool Success, JsonElement Response, string Message, IReadOnlyList<JsonElement> Logs)` plus `Failure(message)`.

- [ ] **Step 1: Write RED framing/value tests and the exact partial-read helper**

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
    public async Task OversizedDeclarationFailsBeforeReadingABody()
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
    public void NullCanBeReturnedFromVoidRemoteMethod()
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

- [ ] **Step 2: Run RED protocol tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest"
```

Expected: compile fails because the protocol classes do not exist.

- [ ] **Step 3: Add protocol constants, result, exception, and first tagged value**

Create these public shapes:

```csharp
namespace GodotE2E;

using System.Text.Json;

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

Clone any `JsonElement` that must outlive its source `JsonDocument`.

- [ ] **Step 4: Implement framing with size validation before body allocation**

`E2EFraming.Encode`:

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

Use this exact-read helper:

```csharp
private static async Task ReadExactlyAsync(
    Stream stream,
    Memory<byte> buffer,
    CancellationToken cancellationToken)
{
    var offset = 0;
    while (offset < buffer.Length)
    {
        var read = await stream.ReadAsync(buffer[offset..], cancellationToken);
        if (read == 0)
            throw new E2EException("Connection closed while reading E2E frame");
        offset += read;
    }
}
```

`ReadAsync` reads the four-byte header, rejects a declaration above `MaxFrameBytes`, allocates only after validation, parses UTF-8 JSON, requires an object root, and returns `document.RootElement.Clone()`.

- [ ] **Step 5: Implement only conversion needed by the first C# API**

`NormalizeForWire` recursively handles null, primitives, string-keyed dictionaries, object sequences, and `E2EVector2`:

```csharp
E2EVector2 v => new Dictionary<string, object?>
{
    ["_t"] = "v2",
    ["x"] = v.X,
    ["y"] = v.Y,
},
```

`Convert<T>` must accept remote `null` values before tagged conversion:

```csharp
public static T Convert<T>(JsonElement element)
{
    if (element.ValueKind == JsonValueKind.Null)
        return default!;

    if (typeof(T) == typeof(E2EVector2)
        && element.ValueKind == JsonValueKind.Object
        && element.TryGetProperty("_t", out var tag)
        && tag.GetString() == "v2")
    {
        object value = new E2EVector2(
            element.GetProperty("x").GetDouble(),
            element.GetProperty("y").GetDouble());
        return (T)value;
    }

    try
    {
        return element.Deserialize<T>()!;
    }
    catch (JsonException exception)
    {
        throw new E2EException(
            $"Unable to convert E2E value to {typeof(T).Name}",
            exception);
    }
}
```

Do not recreate the complete Godot Variant type system now.

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
- Produces `Task<E2EResult> ConnectAsync(int port, string token, TimeSpan timeout, CancellationToken cancellationToken = default)`.
- Produces `Task<E2EResult> SendCommandAsync(string action, IReadOnlyDictionary<string, object?>? parameters = null, TimeSpan? timeout = null, CancellationToken cancellationToken = default)`.
- Produces `bool IsSessionOpen`, `IReadOnlyList<JsonElement> CollectedLogs`, and idempotent `DisposeAsync()`.
- A second concurrent request fails immediately with `A command is already in flight`; requests are never queued.

- [ ] **Step 1: Add the exact loopback fake server**

Create `tests/csharp/FakeProtocolServer.cs`:

```csharp
namespace GodotE2E.Tests;

using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using GodotE2E;

internal sealed class FakeProtocolServer : IAsyncDisposable
{
    private readonly TcpListener _listener;
    private readonly Func<JsonElement, CancellationToken, Task<object?>> _responder;
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _loop;
    private Exception? _failure;

    private FakeProtocolServer(
        TcpListener listener,
        Func<JsonElement, CancellationToken, Task<object?>> responder)
    {
        _listener = listener;
        _responder = responder;
        _loop = RunAsync();
    }

    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public static FakeProtocolServer Start(
        Func<JsonElement, CancellationToken, Task<object?>> responder)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return new FakeProtocolServer(listener, responder);
    }

    public async ValueTask DisposeAsync()
    {
        _cts.Cancel();
        _listener.Stop();
        try
        {
            await _loop;
        }
        catch (OperationCanceledException) when (_cts.IsCancellationRequested)
        {
        }
        finally
        {
            _cts.Dispose();
        }

        if (_failure is not null)
            throw _failure;
    }

    private async Task RunAsync()
    {
        try
        {
            using var client = await _listener.AcceptTcpClientAsync(_cts.Token);
            await using var stream = client.GetStream();
            while (!_cts.IsCancellationRequested)
            {
                JsonElement request;
                try
                {
                    request = await E2EFraming.ReadAsync(stream, _cts.Token);
                }
                catch (E2EException)
                {
                    break;
                }

                var responseObject = await _responder(request, _cts.Token);
                if (responseObject is null)
                    continue;

                var response = JsonSerializer.SerializeToElement(responseObject);
                await stream.WriteAsync(E2EFraming.Encode(response), _cts.Token);
                await stream.FlushAsync(_cts.Token);
            }
        }
        catch (OperationCanceledException) when (_cts.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            _failure = exception;
        }
    }
}
```

Returning `null` deliberately means “do not respond”; timeout/concurrency tests use that behavior.

- [ ] **Step 2: Write RED client tests**

Pin hello first:

```csharp
[TestCase]
public async Task HelloIsFirstRequestAndUsesProtocolVersionOne()
{
    await using var server = FakeProtocolServer.Start((request, _) =>
    {
        AssertThat(request.GetProperty("id").GetInt32()).IsEqual(1);
        AssertThat(request.GetProperty("action").GetString()).IsEqual("hello");
        AssertThat(request.GetProperty("token").GetString()).IsEqual("secret");
        AssertThat(request.GetProperty("protocol_version").GetInt32()).IsEqual(1);
        return Task.FromResult<object?>(new { id = 1, ok = true });
    });

    await using var client = new E2EClient();
    var result = await client.ConnectAsync(server.Port, "secret", TimeSpan.FromSeconds(1));
    AssertThat(result.Success).IsTrue();
}
```

Add separate cases for:

```text
hello id 1 then first normal command id 2
{error:"bad", message:"detail"} -> Message == "bad: detail"
_logs removed from Response and appended to CollectedLogs
wrong response id closes session
no response before deadline -> failure and session closed
first normal request held by TaskCompletionSource, second request -> immediate one-in-flight failure
```

- [ ] **Step 3: Run RED client tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ClientTest"
```

Expected: compile failure because `E2EClient` does not exist.

- [ ] **Step 4: Implement loopback connect, hello, and one-in-flight ownership**

Use `TcpClient`, `_nextId = 1`, and `SemaphoreSlim(1, 1)`. Acquire without queueing:

```csharp
if (!await _inFlight.WaitAsync(0, cancellationToken))
    return E2EResult.Failure("A command is already in flight");
```

Always release in `finally`. Connect only with `IPAddress.Loopback`. Hello request is:

```csharp
new Dictionary<string, object?>
{
    ["id"] = AllocateId(),
    ["action"] = "hello",
    ["token"] = token,
    ["protocol_version"] = E2EProtocol.ProtocolVersion,
}
```

Set `IsSessionOpen` only after successful hello.

- [ ] **Step 5: Implement command merge, response validation, and log collection**

Start each request with `id` + `action`; merge normalized parameters. Validate returned id. Match current compatibility behavior: a response without `id` is tolerated only when it contains `error`; otherwise missing/mismatched IDs close the session.

Presence of `error` means failure. Render:

```text
error only               -> error
error == message         -> error
error + distinct message -> error: message
```

Copy all non-`_logs`/`_logs_dropped` properties into a fresh response object. Clone each log entry into `CollectedLogs`; append one synthetic warning entry when `_logs_dropped > 0`.

- [ ] **Step 6: Make timeout/framing/disconnect terminal for the session**

Use a linked `CancellationTokenSource` with `CancelAfter(timeout)`. On timeout close the socket and return:

```text
Command '<action>' timed out after <milliseconds> ms
```

Also close the socket after framing errors, unexpected response IDs, or disconnect. Do not attempt resynchronization.

- [ ] **Step 7: Run GREEN client + protocol tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest|FullyQualifiedName~ClientTest"
```

Expected: pass without launching Godot.

- [ ] **Step 8: Commit**

```bash
git add addons/gdunit_e2e/csharp/E2EClient.cs tests/csharp/FakeProtocolServer.cs tests/csharp/ClientTest.cs
git commit -m "feat: add csharp e2e tcp client"
```

---

### Task 5: Launch, authenticate, and deterministically reap a real Godot .NET child

**Files:**
- Modify: `addons/gdunit_e2e/csharp/GodotE2E.Client.csproj`
- Create: `addons/gdunit_e2e/csharp/E2ELaunchOptions.cs`
- Create: `addons/gdunit_e2e/csharp/E2EProcess.cs`
- Create: `addons/gdunit_e2e/csharp/E2EGame.cs`
- Create: `tests/csharp/TestProject.cs`
- Create: `tests/csharp/ProcessLifecycleTest.cs`

**Interfaces:**
- Produces `E2ELaunchOptions` with `ScenePath`, `ProjectPath`, `GodotPath`, `Timeout`, `ExtraGodotArgs`, `LogVerbosity`, `ServerPort`, `BootstrapScenePath`.
- Produces `Task<E2EProcess> E2EProcess.LaunchAsync(E2ELaunchOptions, CancellationToken = default)` and internal `BuildArguments(...)`.
- Produces `E2EProcess.Client`, `ProcessId`, `Stdout`, `Stderr`, `IsRunning`, idempotent `DisposeAsync()`.
- Produces `Task<E2EGame> E2EGame.LaunchAsync(...)`, raw `SendCommandAsync(...)`, `ProcessId`, and `DisposeAsync()`.

- [ ] **Step 1: Write RED defaults + argument-order tests**

Pin defaults:

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

Add an internal `E2EProcess.BuildArguments(options, portFile, token)` seam and assert exact order:

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

Expose internals in `GodotE2E.Client.csproj`:

```xml
<ItemGroup>
  <InternalsVisibleTo Include="GodotE2E.Tests" />
</ItemGroup>
```

- [ ] **Step 2: Run RED lifecycle tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
```

Expected: compile failure because the process/session types do not exist.

- [ ] **Step 3: Implement launch options and project/executable resolution**

Create:

```csharp
public sealed class E2ELaunchOptions
{
    public required string ScenePath { get; init; }
    public string? ProjectPath { get; init; }
    public string? GodotPath { get; init; }
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(10);
    public IReadOnlyList<string> ExtraGodotArgs { get; init; } = Array.Empty<string>();
    public string LogVerbosity { get; init; } = "warning";
    public int ServerPort { get; init; }
    public string BootstrapScenePath { get; init; } =
        "res://addons/gdunit_e2e/runtime/bootstrap.tscn";
}
```

Resolution rules:

```text
ProjectPath explicit -> full path + require <project>/project.godot
ProjectPath empty    -> walk parents from current directory, then AppContext.BaseDirectory
GodotPath explicit   -> use it
GodotPath empty      -> non-empty GODOT_BIN, otherwise command name "godot"
```

Do not require `File.Exists("godot")`; allow `Process.Start` to resolve `PATH`.

- [ ] **Step 4: Implement real launch with immediate stdout/stderr drains**

Use:

```csharp
var startInfo = new ProcessStartInfo
{
    FileName = godotPath,
    UseShellExecute = false,
    RedirectStandardOutput = true,
    RedirectStandardError = true,
    CreateNoWindow = true,
    WorkingDirectory = projectPath,
};
foreach (var argument in BuildArguments(options, portFile, token))
    startInfo.ArgumentList.Add(argument);
```

Create a unique absolute temp port file beneath `Path.GetTempPath()`. Immediately after `Process.Start()` begin:

```csharp
_stdoutTask = _process.StandardOutput.ReadToEndAsync();
_stderrTask = _process.StandardError.ReadToEndAsync();
```

Poll every 25 ms until `options.Timeout`. Check `HasExited` before reading the port file. Accept only port `1..65535`. On exit/timeout, reap the child, await both drain tasks, and include stdout/stderr in the launch exception.

- [ ] **Step 5: Authenticate and expose the raw game session**

After port discovery create `E2EClient` and call `ConnectAsync(port, token, options.Timeout, cancellationToken)`. Reap before throwing when handshake fails.

`E2EGame.LaunchAsync` remains a thin factory:

```csharp
public static async Task<E2EGame> LaunchAsync(
    E2ELaunchOptions options,
    CancellationToken cancellationToken = default)
{
    var process = await E2EProcess.LaunchAsync(options, cancellationToken);
    return new E2EGame(process);
}
```

- [ ] **Step 6: Implement bounded normal shutdown + kill fallback**

Order:

```text
if session open -> raw quit, 500 ms timeout, command failure ignored
Dispose client
wait at most 1 second for process exit
if alive -> Process.Kill(entireProcessTree: true)
wait at most 1 second again
if dead -> await stdout/stderr drain tasks and store strings
delete port file/temp directory best effort
if still alive -> throw E2EException with PID
```

Use:

```csharp
private static async Task<bool> WaitForExitAsync(Process process, TimeSpan timeout)
{
    using var cts = new CancellationTokenSource(timeout);
    try
    {
        await process.WaitForExitAsync(cts.Token);
        return true;
    }
    catch (OperationCanceledException)
    {
        return process.HasExited;
    }
}
```

After successful disposal, later `DisposeAsync()` calls return immediately.

- [ ] **Step 7: Add the exact repository helper for integration tests**

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
        Timeout = TimeSpan.FromSeconds(5),
        ExtraGodotArgs = ["--quiet"],
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

- [ ] **Step 8: Add the first real C# -> C# lifecycle test**

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

- [ ] **Step 9: Build the game and run GREEN lifecycle tests**

```bash
dotnet build godot-e2e.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
```

Expected: real Godot .NET child launches through the unchanged GDScript bootstrap/server and is reaped.

- [ ] **Step 10: Commit**

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
- Produces:
  - `Task<bool> NodeExistsAsync(string path, CancellationToken = default)`
  - `Task<T> GetPropertyAsync<T>(string path, string property, CancellationToken = default)`
  - `Task SetPropertyAsync(string path, string property, object? value, CancellationToken = default)`
  - `Task<T> CallMethodAsync<T>(string path, string method, IReadOnlyList<object?>? args = null, CancellationToken = default)`
  - `Task InputActionAsync(string actionName, bool pressed, double strength = 1.0, CancellationToken = default)`
  - `Task PressActionAsync(string actionName, double strength = 1.0, CancellationToken = default)`
  - `Task ClickNodeAsync(string path, CancellationToken = default)`
  - `Task<bool> WaitForPropertyAsync(string path, string property, object? value, TimeSpan timeout, CancellationToken = default)`
  - `Task<IReadOnlyList<object?>> WaitForSignalAsync(string path, string signalName, TimeSpan timeout, CancellationToken = default)`
  - `Task<string> GetSceneAsync(CancellationToken = default)`
  - `Task ReloadSceneAsync(CancellationToken = default)`
  - `Task<string> ScreenshotAsync(string savePath = "", CancellationToken = default)`
  - `Task CaptureFailureArtifactsAsync(string outputDirectory, CancellationToken = default)`
- Wrapped failures throw `E2EException`; raw `SendCommandAsync` returns `E2EResult` for expected server errors.
- Deliberately defer convenience wrappers not exercised by acceptance (`GetTreeAsync`, `InputKeyAsync`, `InputMouseButtonAsync`, frame/seconds waits, `ChangeSceneAsync`); raw `SendCommandAsync` already exposes those protocol commands. Add wrappers later only when real usage needs them.

- [ ] **Step 1: Write RED gameplay tests against only the C# fixture**

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

Add a raw negative response case:

```csharp
var result = await game.SendCommandAsync(
    "get_property",
    new Dictionary<string, object?>
    {
        ["path"] = "/root/Missing",
        ["property"] = "text",
    });
AssertThat(result.Success).IsFalse();
AssertThat(result.Message).Contains("Node not found");
```

- [ ] **Step 2: Add RED signal + scene cases**

Schedule the signal before waiting because the session permits one in-flight command:

```csharp
_ = await game.CallMethodAsync<object?>("/root/Main", "SchedulePulse", [0.1]);
var signalArgs = await game.WaitForSignalAsync("/root/Main", "Pulse", TimeSpan.FromSeconds(2));
AssertThat(signalArgs[0]?.ToString()).IsEqual("pulse");

AssertThat(await game.GetSceneAsync())
    .IsEqual("res://tests/fixtures/csharp/main.tscn");
await game.ReloadSceneAsync();
AssertThat(await game.GetSceneAsync())
    .IsEqual("res://tests/fixtures/csharp/main.tscn");
```

Do not add a GDScript scene or cross-language fixture to satisfy scene coverage.

- [ ] **Step 3: Add RED explicit-artifact coverage**

```csharp
var output = Path.Combine(
    Path.GetTempPath(),
    "godot-e2e-csharp-artifacts",
    Guid.NewGuid().ToString("N"));
await game.CaptureFailureArtifactsAsync(output);

AssertThat(File.Exists(Path.Combine(output, "screenshot.png"))).IsTrue();
AssertThat(File.Exists(Path.Combine(output, "scene_tree.json"))).IsTrue();
AssertThat(File.Exists(Path.Combine(output, "engine_logs.json"))).IsTrue();
```

- [ ] **Step 4: Run RED gameplay tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~GameplaySmokeTest"
```

Expected: compile failure for missing facade methods.

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

Map responses exactly:

```text
node_exists       -> response.exists
get_property      -> E2EJson.Convert<T>(response.result)
set_property      -> success only
call_method       -> E2EJson.Convert<T>(response.result), including JSON null
input_action      -> success only
press_action      -> pressed=true then pressed=false
click_node        -> success only
wait_for_property -> server timeout in seconds; transport timeout = server timeout + 1s
wait_for_signal   -> same margin; response.result or response.args converted to object?[]
get_scene         -> response.scene
reload_scene      -> default command timeout + 1s
screenshot        -> response.path
```

Do not add locators, retries, batching, or parallel requests.

- [ ] **Step 6: Implement explicit artifacts without gdUnit4Net hooks**

`CaptureFailureArtifactsAsync(outputDirectory)`:

```text
Directory.CreateDirectory(outputDirectory)
try raw screenshot -> <output>/screenshot.png
try raw get_tree {path:"/root", depth:4} -> scene_tree.json; write {} on request failure
write current E2EClient.CollectedLogs -> engine_logs.json; write [] when empty
if the child is already exited -> write stdout.log + stderr.log from E2EProcess diagnostics
```

Each request/write has its own `try/catch`; one failed diagnostic must not replace the caller's primary failure. Never inspect internal gdUnit4Net test state.

- [ ] **Step 7: Add cleanup-on-exception regression**

```csharp
private sealed class ExpectedTestException : Exception
{
}

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

- [ ] **Step 8: Add forced-kill regression using only fixture behavior**

```csharp
[TestCase]
public async Task DisposeForceKillsBlockedChild()
{
    var game = await E2EGame.LaunchAsync(TestProject.LaunchOptions());
    var pid = game.ProcessId;
    var started = Stopwatch.StartNew();

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
    AssertThat(started.Elapsed < TimeSpan.FromSeconds(4)).IsTrue();
}
```

Do not add a production-only force-kill toggle.

- [ ] **Step 9: Run GREEN same-language suites**

```bash
dotnet build godot-e2e.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
```

Expected: `C# -> C#` and existing `GDScript -> GDScript` are green; no cross-language test exists.

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
- Modify: `docs/superpowers/specs/2026-08-27-csharp-e2e-integration-design.md` (status + verified dependency wording only)

**Interfaces:**
- Produces one Linux and one Windows CI job running both same-language paths.
- Produces reusable survivor check for `--gdunit-e2e` processes.
- Produces package contract proving C# client ships and C# repository fixtures/tests do not.
- Produces independent GDScript/C# README paths with no cross-language claim.

- [ ] **Step 1: Extract the existing survivor scan**

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

- [ ] **Step 2: Add the package contract**

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

- [ ] **Step 3: Switch both CI jobs to Godot .NET + .NET 8**

Use in both jobs:

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

Keep existing `GODOT_BIN` resolution, including Windows `cygpath` handling.

- [ ] **Step 4: Add build + C# tests to the existing OS jobs**

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

Keep existing GDScript normal suite and intentional-failure harness.

- [ ] **Step 5: Add final survivor + package gates**

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

One OS is enough for deterministic ZIP contents.

- [ ] **Step 6: Upload managed test output on failure**

Add `TestResults` to both existing artifact upload paths. Do not add a third job.

- [ ] **Step 7: Document the two supported paths**

README support matrix:

```text
GDScript test -> GDScript game   supported
C# test       -> C# game         supported
GDScript test -> C# game         not supported/tested
C# test       -> GDScript game   not supported/tested
```

Keep existing GDScript instructions/example. Add a separate C# test-project example with:

```xml
<PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
<PackageReference Include="gdUnit4.api" Version="5.0.0" />
<PackageReference Include="gdUnit4.test.adapter" Version="3.0.0" PrivateAssets="all" />
<PackageReference Include="gdUnit4.analyzers" Version="1.0.0" PrivateAssets="all" />
<ProjectReference Include="../../addons/gdunit_e2e/csharp/GodotE2E.Client.csproj" />
```

State that the project-reference path is relative to the consumer's test project.

Minimal C# usage:

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

State that normal C# E2E tests do not need `[RequireGodotRuntime]`; the child is the Godot runtime. Remove the old README deferred item for dedicated C#/.NET support.

- [ ] **Step 8: Mark the approved design and record verified dependency isolation**

Change design status from `Ready for review` to `Approved for implementation` and record:

```text
gdUnit4.api 5.0.0
gdUnit4.test.adapter 3.0.0
gdUnit4.analyzers 1.0.0
Microsoft.NET.Test.Sdk 17.14.1
```

Clarify Risk 1: the test project has no **direct** GodotSharp or game-project reference; `gdUnit4.api`'s transitive GodotSharp dependency stays isolated in the test project and therefore does not constrain the root Godot 4.5.1 project.

- [ ] **Step 9: Run the complete local release gate**

```bash
./scripts/bootstrap_gdunit4.sh
dotnet list addons/gdunit_e2e/csharp/GodotE2E.Client.csproj package
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

`dotnet list` must report no package references for `GodotE2E.Client`. On Linux without a display, wrap child-launching commands in the same Xvfb invocation used by CI.

- [ ] **Step 10: Commit**

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
