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
- Pure `net8.0` client project.
- `InternalsVisibleTo("GodotE2E.Tests")` for narrowly scoped test seams.
- `TestPaths.RepositoryRoot` shared by source-contract/integration tests.

- [ ] **Step 1: Add the BCL-only client project and `.gdignore`**

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

`AssemblyInfo.cs`:

```csharp
using System.Runtime.CompilerServices;
[assembly: InternalsVisibleTo("GodotE2E.Tests")]
```

- [ ] **Step 2: Add isolated gdUnit4Net test project**

Reference only client project plus exact package pins; no direct GodotSharp and no game-project reference.

- [ ] **Step 3: Add `TestPaths.RepositoryRoot` locator**

Walk upward from current directory and `AppContext.BaseDirectory` until `project.godot` is found.

- [ ] **Step 4: Add runner smoke test without `[RequireGodotRuntime]`**

`[TestSuite]` + `[TestCase]`, assert `1 == 1`.

- [ ] **Step 5: Ignore `bin/`, `obj/`, `TestResults/`**

- [ ] **Step 6: Restore/run + prove client has no packages**

```bash
dotnet restore tests/csharp/GodotE2E.Tests.csproj
dotnet test tests/csharp/GodotE2E.Tests.csproj --no-restore --filter "FullyQualifiedName~RunnerSmokeTest"
dotnet list addons/gdunit_e2e/csharp/GodotE2E.Client.csproj package
```

- [ ] **Step 7: Commit**

```bash
git add .gitignore addons/gdunit_e2e/csharp tests/csharp
git commit -m "test: bootstrap csharp e2e runner"
```

---

### Task 2: Convert repository to Godot .NET and add C# fixture

**Files:** `project.godot`, new `GodotE2E.csproj`, `GodotE2E.sln`, C# fixture + UID, three GDScript integration helpers.

- [ ] **Step 1: Add Godot C# metadata + root project**

`project.godot` declares C# and `project/assembly_name="GodotE2E"`. `GodotE2E.csproj` uses `Godot.NET.Sdk/4.5.1`, targets `net8.0`, excludes `tests/csharp/**/*.cs` and `addons/gdunit_e2e/csharp/**/*.cs`, and has **no manual `<AssemblyName>`**. Create `GodotE2E.sln` with only the game project.

- [ ] **Step 2: Add fixture script**

C# root supports action state, button click, `Echo`, delayed `Pulse`, and fixture-only `BlockMainThread`.

- [ ] **Step 3: Add fixture scene**

Stable `/root/Main`, `Status`, `ClickStatus`, `Button` paths.

- [ ] **Step 4: Remove only ordinary `timeout_seconds = 5.0` launch overrides**

From gameplay smoke, process lifecycle, and server startup helpers. Keep behavior-specific short timeout values (e.g. invalid startup 0.25s).

- [ ] **Step 5: Build + Godot import once to generate `Main.cs.uid`**

```bash
dotnet build GodotE2E.csproj
"${GODOT_BIN:-godot}" --headless --editor --path . --quit
```

- [ ] **Step 6: Verify behavior, not authored file strings**

```bash
dotnet sln GodotE2E.sln list
dotnet build GodotE2E.csproj
test -f tests/fixtures/csharp/Main.cs.uid
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
```

No project.godot/csproj literal-content assertions or grep checks.

- [ ] **Step 7: Commit**

---

### Task 3: Framing, minimal typed value, and drift guards

Create protocol/framing/json/value/result/exception C# files and `ProtocolTest.cs`.

- [ ] **Step 1: RED tests** cover BE framing/partial reads, pre-allocation oversize rejection, null, v2, unsupported v3 tag loud failure, and source drift.

Drift test reads GDScript protocol + process source and asserts C# copies match protocol version, frame cap, default command timeout, wait margin, and 4 MiB pipe bound.

- [ ] **Step 2: Run RED**.

- [ ] **Step 3: Implement constants** including `MaxPipeBytes = 4 * 1024 * 1024`.

- [ ] **Step 4: Implement framing** with exact-read loops and size check before body allocation.

- [ ] **Step 5: Implement conversion**: only v2 typed support; any other `_t` throws `Unsupported Godot value tag '<tag>'; use SendCommandAsync for raw access`; only untagged JSON gets generic deserialization.

- [ ] **Step 6: Run GREEN C# protocol + existing GDScript serializer tests**.

- [ ] **Step 7: Commit**.

---

### Task 4: Raw TCP client

Create `IE2ECommandSender`, `E2EClient`, fake protocol server, client tests.

- [ ] **Step 1:** loopback fake server using shared C# framing.
- [ ] **Step 2:** RED tests for hello/IDs, partial reads, errors, logs, timeout/disconnect, fail-fast overlap.
- [ ] **Step 3:** run RED.
- [ ] **Step 4:** implement fixed-host client, hello, monotonic IDs, `SemaphoreSlim.WaitAsync(0)` fail-fast.
- [ ] **Step 5:** implement linked-cancellation timeouts, response-id check, cloned response/logs, raw failures.
- [ ] **Step 6:** GREEN.
- [ ] **Step 7:** commit.

---

### Task 5: Real Godot child process

Create launch options/process/raw game factory + TestProject/process lifecycle tests.

- [ ] **Step 1:** RED argv/default/path tests, including `--gdunit-e2e-port=<ServerPort>`.
- [ ] **Step 2:** run RED.
- [ ] **Step 3:** Process.Start with ArgumentList and continuous bounded byte-stream drains. Consume all stdout/stderr but retain newest 4 MiB only; no unbounded `ReadToEndAsync` storage.
- [ ] **Step 4:** port-file polling + hello, 10s launch deadline, reap on failure.
- [ ] **Step 5:** quit, <=1s graceful wait, whole-tree kill, <=1s confirmation, drains/temp cleanup, strict failure if still alive.
- [ ] **Step 6:** TestProject uses C# fixture, GODOT_BIN, 10s default.
- [ ] **Step 7:** real launch/raw node_exists/dispose/PID-dead test; add output-load boundedness regression if needed.
- [ ] **Step 8:** build + GREEN.
- [ ] **Step 9:** commit.

---

### Task 6: Lean facade, wait margin, RunAsync, artifacts

- [ ] **Step 1:** RED C#-fixture facade tests using RunAsync.
- [ ] **Step 2:** recording `IE2ECommandSender` pins WaitForProperty +1s, WaitForSignal +1s, Reload +1s; no duplicate real timing-race test.
- [ ] **Step 3:** run RED.
- [ ] **Step 4:** implement only accepted wrapper subset through one failure mapper.
- [ ] **Step 5:** explicit independent best-effort screenshot/tree/log/process-tail artifacts.
- [ ] **Step 6:** implement RunAsync with caller file/member path `test_output/csharp/<suite>/<test>`, safe path components, ExceptionDispatchInfo. If body + cleanup fail, preserve/rethrow original body failure and attach cleanup detail as secondary diagnostic; cleanup-only failure still throws.
- [ ] **Step 7:** deterministic named artifact regression; no timestamp/GUID scan.
- [ ] **Step 8:** body-failure cleanup + fixture-only blocked-child force-kill regressions.
- [ ] **Step 9:** full C# + existing GDScript GREEN.
- [ ] **Step 10:** commit.

---

### Task 7: GDScript-only clean bootstrap, CI, package, README

- [ ] **Step 1:** after clean archive extraction remove `GodotE2E.csproj/.sln`, C# repository tests/fixture; keep shipped addon C# client. Strip `C#` feature + `[dotnet]` from temp `project.godot`; do **not** C# build temp project; run existing import/class-cache check.
- [ ] **Step 2:** extract Linux/Windows survivor scan script.
- [ ] **Step 3:** package contract includes client `.gdignore`/csproj/facade; excludes root project/tests/GdUnit4.
- [ ] **Step 4:** existing two jobs switch to Godot .NET 4.5.1 + .NET 8.
- [ ] **Step 5:** `dotnet build GodotE2E.csproj` before main-project bootstrap script/any Godot launch.
- [ ] **Step 6:** both same-language suites per existing OS job; no new matrix.
- [ ] **Step 7:** survivor `always()`, Linux package gate, upload TestResults.
- [ ] **Step 8:** README C# game csproj includes `<Compile Remove="addons/gdunit_e2e/csharp/**/*.cs" />`; separate test project references client + pinned gdUnit packages; examples use RunAsync; no RequireGodotRuntime or cross-language claim.
- [ ] **Step 9:** complete local release gate.
- [ ] **Step 10:** commit.

---

## Final PR Gate

- [ ] `git diff main...HEAD --check`.
- [ ] Existing GDScript API unchanged for code-sharing purposes.
- [ ] Client has no package dependencies; C# tests do not reference game project.
- [ ] No C# E2E `[RequireGodotRuntime]`.
- [ ] No manual game `<AssemblyName>`; solution identity matches project.godot; UID committed.
- [ ] Game compile excludes C# tests/client.
- [ ] Same-language fixtures only.
- [ ] Clean-bootstrap strips C# game metadata/fixture but keeps shipped client directory.
- [ ] Unsupported typed `_t` values fail loudly; duplicated constants have drift guard.
- [ ] Pipe retention <=4 MiB per stream.
- [ ] RunAsync preserves primary body failure and uses suite/test artifact paths.
- [ ] README includes C# game compile exclusion.
- [ ] Linux/Windows CI green on Godot .NET 4.5.1.
- [ ] Release package shape correct.
- [ ] No surviving E2E child.
