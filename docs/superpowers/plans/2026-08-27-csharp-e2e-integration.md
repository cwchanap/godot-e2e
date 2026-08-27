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

The gdUnit API may bring GodotSharp transitively into the **test project's** dependency graph; that is acceptable because this project is isolated from the Godot 4.5.1 game project. Do not add a direct GodotSharp reference.

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

`BlockMainThread` is fixture-only behavior used to prove forced cleanup; do not add a production launcher seam solely for that test.

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
- Produces raw `E2EResult` with `Success`, cloned `Response`, `Message`, `Logs`, and `E2EResult.Failure(message)`.

- [ ] **Step 1: Write the RED protocol tests and exact partial-read helper**

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

Run:

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProtocolTest"
```

Expected: compile fails because the protocol classes do not exist.

- [ ] **Step 3: Add exact protocol constants and result/exception types**

Create `E2EProtocol.cs`, `E2EException.cs`, `E2EValueTypes.cs`, and `E2EResult.cs` with these public shapes:

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

Whenever a live JSON document supplies `Response` or a log element, call `.Clone()` before disposing that document.

- [ ] **Step 4: Implement framing with exact-read loops and pre-allocation size validation**

Create `E2EFraming.cs`. Its encode path must be:

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

Use one private helper for complete reads:

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

`ReadAsync` reads exactly four header bytes, validates the declared length against `MaxFrameBytes`, only then allocates the body, parses JSON, requires an object root, and returns `document.RootElement.Clone()`.

- [ ] **Step 5: Implement only the value conversion required now**

Create `E2EJson.cs`. `NormalizeForWire` recursively handles null, JSON primitives, `IReadOnlyDictionary<string, object?>`, `IDictionary<string, object?>`, `IEnumerable<object?>`, and `E2EVector2`:

```csharp
E2EVector2 v => new Dictionary<string, object?>
{
    ["_t"] = "v2",
    ["x"] = v.X,
    ["y"] = v.Y,
},
```

`Convert<T>` recognizes `_t == "v2"` when `T` is `E2EVector2`:

```csharp
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

return element.Deserialize<T>()
    ?? throw new E2EException($"Unable to convert E2E value to {typeof(T).Name}");
```

Do not implement every Godot Variant tag in this task.

- [ ] **Step 6: Run GREEN protocol tests and existing GDScript serializer tests**

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
- Produces `E2EClient.ConnectAsync(int port, string token, TimeSpan timeout, CancellationToken cancellationToken = default) -> Task<E2EResult>`.
- Produces `E2EClient.SendCommandAsync(string action, IReadOnlyDictionary<string, object?>? parameters = null, TimeSpan? timeout = null, CancellationToken cancellationToken = default) -> Task<E2EResult>`.
- Produces `IsSessionOpen`, `CollectedLogs`, and idempotent `DisposeAsync()`.
- One concurrent request attempt fails immediately with `A command is already in flight` rather than queueing.

- [ ] **Step 1: Add the exact loopback fake server used by client tests**

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
            using var tcpClient = await _listener.AcceptTcpClientAsync(_cts.Token);
            await using var stream = tcpClient.GetStream();
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

`null` from the responder intentionally means “do not respond”, which is used by timeout/concurrency tests.

- [ ] **Step 2: Write RED client tests**

Create `tests/csharp/ClientTest.cs`. First pin hello shape:

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
hello request id == 1, first normal command id == 2
{error:"bad", message:"detail"} -> Message == "bad: detail"
_logs are removed from Response and appended to CollectedLogs
response with the wrong id closes the session
no response before timeout -> failure and session closed
second SendCommandAsync while first response is held -> immediate one-in-flight failure
```

For the concurrency case, use a `TaskCompletionSource<object?>` for the first normal command response; only complete it after the second call has returned its immediate failure.

- [ ] **Step 3: Run RED client tests**

```bash
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ClientTest"
```

Expected: compile failure because `E2EClient` does not exist.

- [ ] **Step 4: Implement connection/hello and one-in-flight request ownership**

Create `E2EClient.cs`. Use `TcpClient`, `NetworkStream`, an integer `_nextId = 1`, and `SemaphoreSlim(1, 1)`. Acquire the semaphore without waiting:

```csharp
if (!await _inFlight.WaitAsync(0, cancellationToken))
    return E2EResult.Failure("A command is already in flight");
```

Always release in `finally`. `ConnectAsync` connects only to `IPAddress.Loopback`, then sends:

```csharp
new Dictionary<string, object?>
{
    ["id"] = AllocateId(),
    ["action"] = "hello",
    ["token"] = token,
    ["protocol_version"] = E2EProtocol.ProtocolVersion,
}
```

Set `IsSessionOpen = true` only after a successful hello result.

- [ ] **Step 5: Implement command merging, response validation, and log collection**

Build each command as a dictionary with `id` and `action`, then add each parameter after `E2EJson.NormalizeForWire`. Serialize to `JsonElement`, encode with `E2EFraming`, write the full frame, then read exactly one response.

Validate response id. A missing id is accepted only when the response contains `error`, matching the current GDScript compatibility behavior; otherwise a mismatched/missing id closes the session.

Render failure text exactly like the GDScript client:

```text
error only                 -> error
message only               -> message
error == message           -> error
error + distinct message   -> error: message
```

Remove `_logs` and `_logs_dropped` from the logical response by copying non-log properties into a fresh JSON object. Decode each log entry, append a synthetic warning entry when `_logs_dropped > 0`, and append cloned log elements to `CollectedLogs`.

- [ ] **Step 6: Make command timeout/disconnect a terminal transport failure**

Create a linked `CancellationTokenSource` per operation and `CancelAfter(timeout)`. When the timeout fires, dispose/close the socket and return:

```text
Command '<action>' timed out after <milliseconds> ms
```

Do not leave the connection reusable after timeout, unexpected response id, framing failure, or disconnect.

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
- Create: `addons/gdunit_e2e/csharp/E2ELaunchOptions.cs`
- Create: `addons/gdunit_e2e/csharp/E2EProcess.cs`
- Create: `addons/gdunit_e2e/csharp/E2EGame.cs`
- Create: `tests/csharp/TestProject.cs`
- Create: `tests/csharp/ProcessLifecycleTest.cs`

**Interfaces:**
- Produces `E2ELaunchOptions` fields: `ScenePath`, `ProjectPath`, `GodotPath`, `Timeout`, `ExtraGodotArgs`, `LogVerbosity`, `ServerPort`, `BootstrapScenePath`.
- Produces `E2EProcess.LaunchAsync(E2ELaunchOptions, CancellationToken cancellationToken = default) -> Task<E2EProcess>`.
- Produces `E2EProcess.Client`, `ProcessId`, `Stdout`, `Stderr`, `IsRunning`, and idempotent `DisposeAsync()`.
- Produces `E2EGame.LaunchAsync(...)`, raw `SendCommandAsync(...)`, `ProcessId`, and `DisposeAsync()`.

- [ ] **Step 1: Write RED option-resolution and exact-argument tests**

Create the first cases in `tests/csharp/ProcessLifecycleTest.cs`:

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

Add an `internal static IReadOnlyList<string> E2EProcess.BuildArguments(...)` seam and assert this ordered sequence:

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

Expose internals to the test assembly by adding to `GodotE2E.Client.csproj`:

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

- [ ] **Step 3: Implement launch options and project/Godot executable resolution**

Create `E2ELaunchOptions.cs` with these defaults:

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

Resolution rules in `E2EProcess`:

```text
ProjectPath explicit -> Path.GetFullPath + require <project>/project.godot
ProjectPath empty    -> walk upward from Directory.GetCurrentDirectory(); if not found, walk from AppContext.BaseDirectory
GodotPath explicit   -> use it
GodotPath empty      -> GODOT_BIN if non-empty, otherwise command name "godot"
```

Do not reject fallback `"godot"` merely because `File.Exists("godot")` is false; `Process.Start` must be allowed to resolve `PATH`.

- [ ] **Step 4: Implement exact arguments, real launch, and continuous pipe drains**

Use `ProcessStartInfo`:

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

Do not construct one quoted shell command.

Create a unique temp directory and absolute port-file path under `Path.GetTempPath()` using `Guid.NewGuid().ToString("N")`.

Immediately after `Process.Start()`, begin both drains so Windows pipe pressure cannot block the child:

```csharp
_stdoutTask = _process.StandardOutput.ReadToEndAsync();
_stderrTask = _process.StandardError.ReadToEndAsync();
```

Poll every 25 ms until `options.Timeout` expires. On each poll, first check `process.HasExited`, then check whether the port file exists and contains an integer in `1..65535`. If the child exits or the deadline expires, kill/reap as necessary, await both drain tasks, and include captured stdout/stderr in the thrown `E2EException`.

- [ ] **Step 5: Connect/authenticate and surface the raw session**

After reading a valid port, create `E2EClient`, call `ConnectAsync(port, token, options.Timeout, cancellationToken)`, and retain it on the process. If authentication fails, reap the child before throwing `E2EException`.

`E2EGame.LaunchAsync(options)` is only a thin owner/factory:

```csharp
public static async Task<E2EGame> LaunchAsync(
    E2ELaunchOptions options,
    CancellationToken cancellationToken = default)
{
    var process = await E2EProcess.LaunchAsync(options, cancellationToken);
    return new E2EGame(process);
}
```

- [ ] **Step 6: Implement bounded normal shutdown + process-tree kill fallback**

`DisposeAsync()` order:

```text
if client session open: raw quit with 500 ms timeout, ignore command failure
DisposeAsync client
wait up to 1 second for Process.WaitForExitAsync
if alive: Process.Kill(entireProcessTree: true)
wait up to 1 second again
if dead: await stdout/stderr ReadToEnd tasks and store their strings
delete port file and temp directory best effort
if still alive: throw E2EException("Unable to confirm Godot child PID <pid> exited")
```

Use a private helper with a timeout token:

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

Repeated `DisposeAsync()` calls after successful cleanup return immediately.

- [ ] **Step 7: Add the exact repository helper for child-launching tests**

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

- [ ] **Step 8: Add the first real C# -> C# lifecycle integration test**

In `ProcessLifecycleTest.cs`:

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

- [ ] **Step 9: Build the game then run GREEN lifecycle tests**

```bash
dotnet build godot-e2e.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --filter "FullyQualifiedName~ProcessLifecycleTest"
```

Expected: C# test runner launches a real Godot .NET child using the unchanged GDScript bootstrap/server and reaps it.

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
- Produces wrapped operations required by acceptance: `NodeExistsAsync`, `GetPropertyAsync<T>`, `SetPropertyAsync`, `CallMethodAsync<T>`, `InputActionAsync`, `PressActionAsync`, `ClickNodeAsync`, `WaitForPropertyAsync`, `WaitForSignalAsync`, `GetSceneAsync`, `ReloadSceneAsync`, `ScreenshotAsync`, `CaptureFailureArtifactsAsync`.
- Wrapped failures throw `E2EException`; raw `SendCommandAsync` returns `E2EResult` for expected server errors.
- Produces `CaptureFailureArtifactsAsync(string outputDirectory)` with `screenshot.png`, `scene_tree.json`, `engine_logs.json`; stdout/stderr are added when the child has exited.

- [ ] **Step 1: Write RED gameplay tests against only the C# fixture**

Create `tests/csharp/GameplaySmokeTest.cs` and cover representative operations rather than mirroring every GDScript integration test:

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

Add a raw negative response test:

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

- [ ] **Step 2: Add RED signal + scene tests**

Schedule the signal **before** waiting because the client intentionally allows only one in-flight command:

```csharp
await game.CallMethodAsync<object?>("/root/Main", "SchedulePulse", [0.1]);
var signalArgs = await game.WaitForSignalAsync("/root/Main", "Pulse", TimeSpan.FromSeconds(2));
AssertThat(signalArgs[0]?.ToString()).IsEqual("pulse");

AssertThat(await game.GetSceneAsync())
    .IsEqual("res://tests/fixtures/csharp/main.tscn");
await game.ReloadSceneAsync();
AssertThat(await game.GetSceneAsync())
    .IsEqual("res://tests/fixtures/csharp/main.tscn");
```

Do not add a second GDScript scene or cross-language fixture to test scene changes.

- [ ] **Step 3: Add the RED explicit-artifact test**

Use a per-test temp directory and assert reachable artifacts:

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

Wrapper response mapping:

```text
node_exists         -> response["exists"] bool
get_property        -> response["result"] through E2EJson.Convert<T>
set_property        -> require success, no payload
call_method         -> response["result"] through E2EJson.Convert<T>
input_action        -> require success
press_action        -> input_action pressed=true, then pressed=false
click_node          -> require success
wait_for_property   -> server timeout in seconds; transport timeout = server timeout + 1 second
wait_for_signal     -> same margin; return response["result"] or response["args"] as object?[]
get_scene           -> response["scene"] string
reload_scene        -> transport timeout = default command timeout + 1 second
screenshot          -> response["path"] string
```

Do not add retrying `expect`, locators, batching, or parallel request support.

- [ ] **Step 6: Implement explicit artifact capture without gdUnit4Net hooks**

`CaptureFailureArtifactsAsync(outputDirectory)`:

```text
Directory.CreateDirectory(outputDirectory)
try raw screenshot -> absolute outputDirectory/screenshot.png
try raw get_tree {path:"/root", depth:4} -> write response.tree to scene_tree.json; write {} on request failure
write current client CollectedLogs -> engine_logs.json; write [] when empty
if owned child has exited -> write stdout.log and stderr.log from E2EProcess diagnostics
```

Each artifact request/write gets its own `try/catch`; one diagnostic failure must not replace the caller's primary test failure. Do not inspect gdUnit4Net internal execution/reporting state.

- [ ] **Step 7: Add the exact cleanup-on-exception regression**

Add to `ProcessLifecycleTest.cs`:

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

This proves ordinary C# scope unwinding, not a gdUnit-specific failure hook.

- [ ] **Step 8: Add forced-kill regression using the blocking C# fixture method**

Start a `call_method` for `BlockMainThread(5000)` with a 100 ms transport timeout. The timeout closes the client while the child main thread is blocked. Dispose the game; it must hit the bounded kill fallback and leave no process:

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

Do not add a production-only “disable graceful quit” or “force kill” switch.

- [ ] **Step 9: Run GREEN C# suite plus existing GDScript suite**

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
- Modify: `docs/superpowers/specs/2026-08-27-csharp-e2e-integration-design.md` (status and verified dependency wording only)

**Interfaces:**
- Produces one Linux and one Windows CI job running both language paths.
- Produces reusable survivor check for `--gdunit-e2e` processes.
- Produces package contract proving C# client ships and C# test fixtures do not.
- Produces README with independent GDScript and C# installation/examples and no cross-language promise.

- [ ] **Step 1: Extract the existing survivor scan into one Bash script**

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

Replace the duplicated inline survivor code in both existing expected-failure harness steps with a call to this script.

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

- [ ] **Step 5: Add final survivor and package gates**

Add this final step to **both** jobs so cleanup is checked even after a prior test failure:

```yaml
- name: Verify no E2E child survives
  if: always()
  shell: bash
  run: bash tests/scripts/assert_no_e2e_children.sh
```

Add package verification to the Linux job only:

```yaml
- name: Verify release package
  shell: bash
  run: bash tests/scripts/package_release_test.sh
```

One OS is enough for the deterministic ZIP contents contract; do not duplicate this packaging check on Windows.

- [ ] **Step 6: Upload managed test output on failure**

Extend each existing failure-artifact upload path with:

```text
TestResults
```

Do not add a separate C# artifact job.

- [ ] **Step 7: Rewrite README entry points as two supported paths**

The README opening must say the addon supports native out-of-process tests in either GDScript/GdUnit4 or C#/gdUnit4Net and list this exact matrix:

```text
GDScript test -> GDScript game   supported
C# test       -> C# game         supported
GDScript test -> C# game         not supported/tested
C# test       -> GDScript game   not supported/tested
```

Keep the existing GDScript install/example intact.

Add a C# section that tells a Godot .NET project to install/copy the same addon and create a separate test project with:

```xml
<PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
<PackageReference Include="gdUnit4.api" Version="5.0.0" />
<PackageReference Include="gdUnit4.test.adapter" Version="3.0.0" PrivateAssets="all" />
<PackageReference Include="gdUnit4.analyzers" Version="1.0.0" PrivateAssets="all" />
<ProjectReference Include="../../addons/gdunit_e2e/csharp/GodotE2E.Client.csproj" />
```

Explain that the `ProjectReference` path is relative to the consumer's test-project location.

Add this minimal example:

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

State that normal E2E tests do not need `[RequireGodotRuntime]`; the child is the Godot runtime. Remove the README deferred item saying dedicated Godot .NET/C# support is still deferred.

- [ ] **Step 8: Update the design status and dependency wording**

Change the C# design status from `Ready for review` to `Approved for implementation` and record these verified pins:

```text
gdUnit4.api 5.0.0
gdUnit4.test.adapter 3.0.0
gdUnit4.analyzers 1.0.0
Microsoft.NET.Test.Sdk 17.14.1
```

Clarify Risk 1: the test project has no **direct** GodotSharp or game-project reference; `gdUnit4.api`'s transitive GodotSharp dependency stays isolated in the test project and therefore does not constrain the root Godot 4.5.1 project.

- [ ] **Step 9: Run the complete local release gate**

Run:

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

Expected from the `dotnet list` command: `GodotE2E.Client` has no package references.

On Linux, wrap child-launching GDScript/C# commands with the same Xvfb invocation used by CI when no display is available.

Expected overall: all normal suites pass, the intentional failure harness exits `100`, no child survives, and packaging checks pass.

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
