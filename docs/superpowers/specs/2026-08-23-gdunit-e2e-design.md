# GdUnit E2E Addon Design

**Status:** Reviewed and approved for implementation  
**Date:** 2026-08-23  
**Repository:** `cwchanap/godot-e2e`  
**License:** Apache-2.0  
**Target:** Godot 4.5+ and GdUnit4 6.x

## 1. Summary

`godot-e2e` is a standalone Godot addon for writing true out-of-process end-to-end tests in GDScript while using GdUnit4 as the only test runner, assertion library, lifecycle framework, CLI, and reporter.

A GdUnit4 test launches the same Godot project as a separate child process, optionally selecting a fixture/game scene with `--scene`. A small automation-server autoload runs inside the child only when `--gdunit-e2e` is present. The parent controls the child over a localhost-only, token-paired TCP connection using a non-blocking GDScript client.

The server implementation is adapted from `RandallLiuXin/godot-e2e` at immutable commit `ae6219f6e758a0f29bd243c8f963417fe4d63c36`. That pinned GDScript server is the v1 wire and behavior baseline. Python/pytest code is reference material only and is not a runtime dependency.

## 2. Problem

GdUnit4 already covers unit tests and in-process scene tests well. Those remain the default for most test coverage. A smaller set of flows benefits from a real second Godot process because it exercises process startup/shutdown, prevents direct access to local scene objects, and gives tests a black-box boundary around the running game.

The addon must add that process boundary without becoming another general-purpose test framework.

## 3. Goals

The MVP must:

1. Let a GdUnit4 GDScript test launch a separate Godot child process.
2. Keep GdUnit4 responsible for discovery, assertions, lifecycle, CLI, and reports.
3. Activate the automation server only with `--gdunit-e2e`.
4. Bind the server only to `127.0.0.1`.
5. Pair parent and child with the pinned upstream token handshake.
6. Preserve upstream four-byte big-endian length-prefixed UTF-8 JSON framing, command names, command-specific response shapes, and `_t` Variant tags.
7. Provide a non-blocking in-tree GDScript client with one in-flight command.
8. Provide a small high-level API for inspection, input, synchronization, scenes, screenshots, and raw commands.
9. Automatically capture diagnostics when a GdUnit test has failed.
10. Close and reap child processes on normal teardown and self-terminate orphaned children after abnormal parent loss.
11. Validate process behavior on Linux and Windows CI.
12. Deliver the MVP in one feature PR with task-level TDD commits.

## 4. Non-goals

The MVP will not:

- replace any GdUnit4 runner/assertion/reporting behavior;
- add Python or pytest runtime dependencies;
- provide C# test authoring;
- claim verified Godot .NET target support until a dedicated fixture exists;
- add Playwright-style locators or retrying `expect()` assertions;
- add multiple simultaneous sessions or a process pool;
- add suite-level child-process reuse; each test owns its launched child in the MVP;
- support remote hosts or non-loopback binding;
- add video, tracing, recording, or editor UX;
- build a generic RPC framework;
- vendor GdUnit4 in release artifacts;
- target exported/mobile builds.

## 5. Product boundary

GdUnit4 owns:

- test discovery and selection;
- assertions and failure state;
- `before_test()` / `after_test()` lifecycle;
- CLI execution;
- HTML/JUnit reporting;
- test timeout/interruption behavior;
- temporary test directories and timeout-safe `await_millis()` waits.

`godot-e2e` owns:

- child-process launch/reap;
- automation-server activation;
- localhost TCP framing and token pairing;
- remote command execution;
- deterministic server-side waits;
- screenshots, scene-tree snapshots, logs, and child stdout/stderr;
- automatic failure-artifact capture;
- orphan-child self-termination;
- the GDScript-facing remote-game facade.

## 6. Architecture

```text
GdUnit4 test process
└── GdUnitE2ETestSuite
    └── E2EProcess (Node, in SceneTree)
        ├── E2EClient (Node, in SceneTree)
        └── GdUnitE2EGame (RefCounted facade)
                    │
                    │ 127.0.0.1 TCP
                    │ [u32 BE length][UTF-8 JSON]
                    ▼
Child Godot process (same project)
├── selected game/fixture scene
└── GdUnitE2EAutomationServer autoload
    ├── token-first handshake
    ├── retained upstream command handler
    ├── deferred waits
    ├── engine-log capture
    ├── orphan watchdog
    └── screenshot/tree access
```

### 6.1 SceneTree ownership is mandatory

`E2EClient` performs network polling from `_process()`. A `Node` outside the SceneTree never receives `_process()`, so ownership is an invariant, not an implementation detail.

`GdUnitE2ETestSuite.launch_game()` must:

```text
create E2EProcess
→ add_child(process)
→ process creates/adds E2EClient
→ launch/connect/handshake
→ return GdUnitE2EGame
```

`GdUnitE2EGame` is only a facade. It must not own the polling Nodes.

### 6.2 One child per test in the MVP

Every process launched through the base suite is tracked for the current test and is closed from `after_test()`. This makes cleanup deterministic and gives failure-artifact capture one authoritative lifecycle hook.

Process reuse across multiple test cases is deferred until there is a demonstrated performance need.

## 7. Repository layout

```text
.
├── addons/gdunit_e2e/
│   ├── plugin.cfg
│   ├── plugin.gd
│   ├── protocol/
│   │   ├── e2e_protocol.gd
│   │   ├── e2e_framing.gd
│   │   └── e2e_serializer.gd
│   ├── server/
│   │   ├── automation_server.gd
│   │   ├── command_handler.gd
│   │   ├── config.gd
│   │   └── log_capture.gd
│   ├── client/
│   │   ├── e2e_result.gd
│   │   ├── e2e_client.gd
│   │   ├── e2e_launch_options.gd
│   │   ├── e2e_process.gd
│   │   └── gdunit_e2e_game.gd
│   └── gdunit/
│       └── gdunit_e2e_test_suite.gd
├── tests/
│   ├── helpers/fake_e2e_server.gd
│   ├── fixtures/minimal/
│   │   ├── main.tscn
│   │   └── main.gd
│   ├── unit/
│   └── integration/
├── scripts/bootstrap_gdunit4.sh
├── scripts/package_release.sh
├── .github/workflows/ci.yml
├── project.godot
├── README.md
├── LICENSE
└── NOTICE
```

There is no nested fixture `project.godot`. Integration tests launch the repository's own project and select `res://tests/fixtures/minimal/main.tscn`. This guarantees the child uses the exact addon/autoload under test instead of a copied fixture addon.

GdUnit4 is installed separately at `res://addons/gdUnit4` for development/CI and is excluded from release artifacts.

## 8. Activation and launch arguments

The addon registers an autoload named:

```text
GdUnitE2EAutomationServer
```

pointing to:

```text
res://addons/gdunit_e2e/server/automation_server.gd
```

The autoload is inert unless `OS.get_cmdline_user_args()` includes `--gdunit-e2e`.

Typical child argv:

```text
<godot>
  --path <absolute project path>
  --scene res://tests/fixtures/minimal/main.tscn
  <other explicit Godot args>
  --
  --gdunit-e2e
  --gdunit-e2e-port=0
  --gdunit-e2e-port-file=<GdUnit temp dir>/port_<token>.txt
  --gdunit-e2e-token=<random token>
  --gdunit-e2e-log-verbosity=warning
```

No GdUnit CLI arguments are forwarded to the child. The child is still the same project, so normal project autoloads—including any GdUnit4 autoloads configured by the project—load normally and must be inert during ordinary game execution.

### 8.1 Fail-closed configuration

Invalid E2E-only startup flags must prevent the automation server from listening and emit `push_error()`; they must not silently fall back to a shared port or verbosity.

Examples:

```text
--gdunit-e2e-port=abc
--gdunit-e2e-port=70000
--gdunit-e2e-port=0 without --gdunit-e2e-port-file
--gdunit-e2e-log-verbosity=verbose
```

### 8.2 Real ephemeral port allocation

For `--gdunit-e2e-port=0`, the adapted server uses:

```gdscript
var error := _server.listen(0, "127.0.0.1")
var actual_port := _server.get_local_port()
```

Godot 4.5 passes port `0` through to the OS socket bind and `get_local_port()` reads back the assigned port. The upstream random 10000-60000 retry loop is removed.

For an explicitly configured nonzero port, the server still binds only `127.0.0.1`.

## 9. Upstream wire contract

The pinned GDScript server is the v1 contract. The addon changes activation names, loopback binding, size safety, and orphan teardown; it does not invent a second wire model.

### 9.1 Framing and size limit

Each message is:

```text
[4-byte unsigned big-endian JSON byte length]
[UTF-8 JSON payload]
```

`E2EProtocol.MAX_FRAME_BYTES` is `16 * 1024 * 1024`.

The rule exists primarily to prevent allocation based on an untrusted length prefix:

- `E2EFraming.try_extract()` rejects an inbound declared size above the cap before allocating/awaiting the body;
- the client rejects an oversized request locally before writing;
- the server closes a peer that sends an oversized request declaration;
- the client closes a peer that declares an oversized response;
- when a server command produces a response above the cap, the server sends the compact upstream-shaped error below instead of silently dropping the connection:

```json
{
  "id": 7,
  "error": "response_too_large",
  "message": "Response exceeded the 16 MiB frame limit"
}
```

If even the compact error cannot be written, disconnect is the last-resort fallback.

### 9.2 Request example

```json
{
  "id": 7,
  "action": "get_property",
  "path": "/root/Main/Player",
  "property": "position"
}
```

### 9.3 Command-specific success examples

A `Vector2` property uses the pinned upstream serializer tag:

```json
{
  "id": 7,
  "result": {
    "_t": "v2",
    "x": 32.0,
    "y": 64.0
  }
}
```

`node_exists` returns:

```json
{
  "id": 8,
  "exists": true
}
```

Mutations commonly return:

```json
{
  "id": 9,
  "ok": true
}
```

The serializer preserves upstream tags `v2`, `v2i`, `v3`, `v3i`, `r2`, `r2i`, `col`, `t2d`, `np`, and `_unknown`. There is no `__godot_type` envelope.

### 9.4 Error handling

A missing node may be returned exactly as:

```json
{
  "id": 7,
  "error": "Node not found: /root/Main/Player"
}
```

Some retained upstream commands already use both `error` and `message`. Those responses are preserved. The client treats presence of `error` as failure and renders a readable `E2EResult.message`; it does not define a parallel framework error-code taxonomy.

### 9.5 Handshake

The first command remains compatible with the upstream Python client:

```json
{
  "id": 1,
  "action": "hello",
  "token": "<per-launch random token>",
  "protocol_version": 1
}
```

The pinned GDScript server validates first-command ordering and token equality but does not validate `protocol_version`. The field stays on the client hello for compatibility; the MVP does not add a new validation branch.

## 10. Server surface and wrapped API

### 10.1 Retained server surface

Keep the pinned command-handler surface rather than deleting unwrapped commands:

```text
node_exists get_property set_property call_method
find_by_group query_nodes find_nodes node_actionable get_tree batch
input_key input_action input_mouse_button input_mouse_motion click_node hover_node
wait_process_frames wait_physics_frames wait_seconds
wait_for_node wait_for_signal wait_for_property
get_scene change_scene reload_scene
screenshot set_log_verbosity set_log_buffer_size quit
```

This minimizes fork maintenance. The MVP does not write exhaustive new characterization tests for every inherited command.

### 10.2 Wrapped MVP surface

`GdUnitE2EGame` wraps only the paths used by the MVP:

Inspection:

- `node_exists`
- `get_property`
- `set_property`
- `call_method`
- `get_tree`
- `get_scene`

Interaction:

- `input_action`
- `press_action`
- `input_key`
- `input_mouse_button`
- `click_node`

Synchronization:

- `wait_process_frames`
- `wait_physics_frames`
- `wait_seconds`
- `wait_for_node`
- `wait_for_property`
- `wait_for_signal`

Scene/diagnostics:

- `change_scene`
- `reload_scene`
- `screenshot`
- raw `send_command`

Unwrapped inherited commands remain reachable through raw `send_command()`.

## 11. Client model

`E2EClient` extends `Node` and is always inside the SceneTree before connect/await work begins.

One in-flight command is allowed, so request state stays directly on the client rather than adding a separate pending-request class:

```gdscript
var _pending_id: int = 0
var _pending_deadline_ms: int = 0
var _pending_action: String = ""
```

The public state method is:

```gdscript
func is_session_open() -> bool
```

It must not be named `is_connected()`, which conflicts with `Object.is_connected(signal, callable)`.

The client hardcodes `127.0.0.1`; the MVP has no host parameter.

## 12. Result and failure model

```gdscript
class_name E2EResult
extends RefCounted

var ok: bool
var value: Variant
var message: String
var logs: Array
```

Raw client operations return `E2EResult`.

`GdUnitE2EGame` convenience methods convert a failed result into the public GdUnit `fail(message)` API and return a safe fallback value. `fail()` records failure but does not stop GDScript execution, so dependent test flow must explicitly stop:

```gdscript
func test_start_game_spawns_player() -> void:
    var game := await launch_game()
    if is_failure():
        return

    await game.click_node("/root/MainMenu/StartButton")
    if is_failure():
        return

    await game.wait_for_node("/root/Game/Player")
    if is_failure():
        return

    assert_bool(await game.node_exists("/root/Game/Player")).is_true()
```

Raw `game.send_command()` returns `E2EResult` without automatically failing the suite, which supports negative-path tests and direct diagnostic characterization.

## 13. Timeout policy

`E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS = 5.0` and `WAIT_MARGIN_SECONDS = 1.0`.

Server-side wait duration and client transport deadline are distinct:

- `wait_for_node/property/signal(timeout)` uses client deadline `timeout + WAIT_MARGIN_SECONDS`;
- `wait_seconds(seconds)` uses `seconds + WAIT_MARGIN_SECONDS`;
- scene change/reload use `DEFAULT_COMMAND_TIMEOUT_SECONDS + WAIT_MARGIN_SECONDS`;
- ordinary commands use `DEFAULT_COMMAND_TIMEOUT_SECONDS`;
- raw `send_command()` accepts an explicit client timeout.

The margin prevents a client timeout racing the server's own timeout result.

## 14. Child-process lifecycle

`E2EProcess` extends `Node`, is created with its owning `GdUnitE2ETestSuite`, and uses that suite's public `create_temp_dir()` and `await_millis()` helpers.

### 14.1 Temp port file

The suite creates a per-test temp directory through GdUnit4. `E2EProcess` builds a unique port-file path inside that directory using the launch token. It does not use `create_temp_file()` because the child must be able to create/write the file without an open parent file handle, especially on Windows.

GdUnit's temp-directory cleanup is the stale-file safety net; `close()` may still remove its own port file best-effort.

### 14.2 Launch

`OS.execute_with_pipe(path, args, false)` is mandatory. The default is blocking; this addon always requests non-blocking pipes.

Launch flow:

```text
suite add_child(E2EProcess)
→ create GdUnit temp directory and token-based port path
→ execute_with_pipe(..., blocking=false)
→ await suite.await_millis(...) while polling PID + port file
→ read actual port
→ E2EProcess add_child(E2EClient)
→ connect 127.0.0.1:<port>
→ token hello
→ return GdUnitE2EGame
```

The parent does not live-read child stdout/stderr while the child is running.

### 14.3 Normal shutdown

```text
send quit when connected
→ close TCP peer
→ await bounded grace period with suite.await_millis()
→ OS.kill(pid) if still running
→ verify OS.is_process_running(pid) == false
→ drain stdout/stderr only after death
→ close pipes
→ best-effort remove port file
→ remove/free E2EProcess Node
```

Pipe drains are non-blocking and bounded by bytes/time/error/EOF. Diagnostics must never hang test cleanup.

### 14.4 Orphan watchdog

Normal parent teardown is not sufficient because the GdUnit runner itself can be interrupted, killed, or crash.

The adapted child server tracks whether a peer has ever authenticated. If an authenticated peer disconnects without the child already quitting, the server starts:

```gdscript
const ORPHAN_GRACE_SECONDS := 2.0
```

During that grace period it may accept a replacement authenticated peer. If no authenticated peer is present when the grace expires, the child calls `get_tree().quit()`.

A child that never authenticated does not self-quit through this watchdog; launch timeout/kill remains the parent's responsibility.

## 15. Automatic failure artifacts

Failure artifacts are a lifecycle feature, not a manual convention.

`GdUnitE2ETestSuite.after_test()` performs this order for every tracked process from the just-finished test:

```text
if is_failure() and child is reachable:
    capture_failure_artifacts(game)
close/reap child
write stdout/stderr artifacts after child death
remove/free process
```

Reachable-child artifacts:

```text
test_output/<suite>/<test>/
├── screenshot.png
├── scene_tree.json
└── engine_logs.json
```

Post-death artifacts when available:

```text
├── stdout.log
└── stderr.log
```

Each artifact is independent and best-effort. Artifact failure never replaces the primary test failure.

`capture_failure_artifacts(game)` remains public as an explicit escape hatch for negative-path tests, but ordinary failed tests do not need to call it.

`after()` performs a final best-effort cleanup of any process still tracked because a test hook failed unexpectedly. The child watchdog covers cases where the entire parent process disappears.

## 16. Upstream adaptation and licensing

Adapt, rather than redesign, these pinned upstream files where useful:

- `addons/godot_e2e/automation_server.gd`
- `addons/godot_e2e/command_handler.gd`
- `addons/godot_e2e/config.gd`
- `addons/godot_e2e/json_serializer.gd`
- `addons/godot_e2e/log_capture.gd`
- `addons/godot_e2e/plugin.gd`

Substantially adapted files retain Apache-2.0 notices and clearly state they were modified.

The repo keeps:

- Apache-2.0 `LICENSE`;
- `NOTICE` crediting `godot-e2e` and the pinned source commit;
- README attribution.

The GDScript client/process/GdUnit adapter is new native code rather than a mechanical Python translation.

## 17. Testing strategy

### 17.1 Unit tests

Use GdUnit4 for:

- four-byte BE framing and partial reads;
- 16 MiB rejection before allocation;
- upstream serializer round-trips;
- strict E2E config parsing;
- representative wrapped command-handler behavior and exact upstream response shapes;
- client request IDs, partial TCP reads, timeout, disconnect, log deltas, one-in-flight enforcement, and `is_session_open()`;
- launch argv construction;
- failure-message formatting;
- artifact helper behavior with fakes.

Do not write exhaustive characterization tests for inherited server commands the MVP does not wrap.

### 17.2 Integration tests

All child-launching tests live after `E2EProcess` exists. They launch the repository's own `project.godot` with the fixture scene.

Verify:

1. `listen(0, "127.0.0.1")` produces a nonzero actual port and writes it to the temp port path;
2. valid token hello succeeds;
3. wrong-token and non-hello-first connections are rejected;
4. invalid startup config never listens and the parent kills the timed-out child;
5. an authenticated peer disconnect causes child self-exit after the orphan grace;
6. real node/property access;
7. action input and button click;
8. server-wait timeout arrives before the client margin expires;
9. graceful quit/reap;
10. forced cleanup of an unhealthy child;
11. no child remains after `after_test()`;
12. automatic artifacts are created when the GdUnit failure flag is set;
13. post-death stdout/stderr drain terminates on both Linux and Windows.

## 18. CI and bootstrap

Use one pinned bootstrap script:

```text
scripts/bootstrap_gdunit4.sh
```

GitHub Actions invokes it with `shell: bash` on Linux and Windows; GitHub's Windows hosted runners provide Git for Windows Bash. Keep the GdUnit version pin in one place.

The script may branch only for archive extraction (`unzip` on Unix, PowerShell `Expand-Archive` under Git-for-Windows Bash) while sharing download/version logic.

CI:

```text
Linux
├── install pinned Godot
├── bootstrap GdUnit4
├── Xvfb
└── full unit + child-process integration suite

Windows
├── install same Godot version family
├── bootstrap GdUnit4 using the same shell script
└── full unit + child-process integration suite
```

No macOS or version matrix in the MVP.

## 19. Release packaging

Package only:

```text
addons/gdunit_e2e/**
README.md
LICENSE
NOTICE
```

Exclude:

- `addons/gdUnit4`;
- tests/fixtures;
- reports and `test_output`;
- CI-only/bootstrap files from the user addon archive.

## 20. Risks

### Risk 1: Windows process termination and pipe behavior

`OS.kill()`, child exit visibility, and non-blocking pipe EOF/error behavior can differ from Linux. This is why Windows CI is MVP scope, not a later matrix expansion.

Mitigation: Task 5 integration tests must exercise graceful exit, forced kill, `OS.is_process_running(pid) == false`, and bounded post-death drain on both operating systems.

### Risk 2: Parent interruption before cleanup

GdUnit can interrupt a timed-out test function, and the whole runner can also be killed. Normal `close_game()` cannot be the only cleanup line.

Mitigation: automatic `after_test()` cleanup, final `after()` safety cleanup, plus child-side authenticated-peer orphan watchdog.

## 21. Deferred follow-ups

Only add these after the MVP is useful:

1. Playwright-style locators.
2. Retrying `expect()` assertions.
3. Engine-error-flood detection.
4. Dedicated Godot .NET/C# fixture.
5. macOS CI.
6. Process reuse/pools/parallel sessions.
7. Richer traces and editor UX.

## 22. Acceptance criteria

The MVP is accepted when:

- a GdUnit4 GDScript test launches a real separate Godot process from the same project;
- the selected fixture/game scene runs with the addon autoload active only under `--gdunit-e2e`;
- port 0 is OS-assigned and the actual loopback port is communicated through the GdUnit temp path;
- the client authenticates and performs wrapped remote operations without blocking the runner;
- `_t` values and upstream command/error shapes are preserved;
- a server-side wait result cannot lose a same-duration client timeout race;
- ordinary failed tests automatically capture available diagnostics;
- every test-owned child is closed from `after_test()`;
- an authenticated orphaned child self-terminates after the grace period if the parent disappears;
- invalid E2E flags fail closed;
- oversized inbound lengths cannot cause large untrusted allocation and oversized responses produce a readable upstream-shaped error;
- Linux and Windows integration tests both verify child termination and bounded pipe drain;
- release packaging contains the addon plus README/LICENSE/NOTICE and no GdUnit4 copy.