# GdUnit E2E Addon Design

**Status:** Approved for implementation planning  
**Date:** 2026-08-23  
**Repository:** `cwchanap/godot-e2e`  
**License:** Apache-2.0  
**Target:** Godot 4.5+ and GdUnit4 6.x

## 1. Summary

`godot-e2e` will be a standalone Godot addon for writing true out-of-process end-to-end tests in GDScript while using GdUnit4 for test discovery, assertions, lifecycle hooks, CLI execution, HTML reports, and JUnit output.

A GdUnit4 test process launches a second Godot process containing the game under test. A small automation server runs inside that child process and exposes a localhost-only, token-authenticated TCP protocol. The GdUnit4 process controls the child through a non-blocking GDScript client.

The implementation uses `RandallLiuXin/godot-e2e` as the architectural and protocol reference, pinned to commit `ae6219f6e758a0f29bd243c8f963417fe4d63c36`. The Godot-side server may be adapted under Apache-2.0; Python/pytest code is reference material only and is not a runtime dependency.

## 2. Problem

GdUnit4 already covers unit tests and in-process scene/integration tests well. Its scene runner is fast and should remain the default for most tests, but it does not provide process isolation:

- a game crash can terminate the test runner;
- startup and shutdown behavior are not exercised as a separate application process;
- tests can accidentally reach directly into local scene objects;
- child-process stdout/stderr and startup failure are not naturally part of the test boundary.

The desired framework keeps GdUnit4 as the test framework while adding a small out-of-process layer for the few flows that benefit from real E2E isolation.

## 3. Goals

The MVP must:

1. Let a GdUnit4 GDScript test launch a Godot project as a separate child process.
2. Enable the automation server only when the child is explicitly launched in E2E mode.
3. Bind the automation server only to `127.0.0.1`.
4. Authenticate the first client command with a random per-launch token.
5. Preserve the useful `godot-e2e` wire contract: four-byte big-endian length-prefixed UTF-8 JSON and compatible command names for the MVP surface.
6. Provide a non-blocking GDScript client so the GdUnit4 runner main loop remains responsive.
7. Expose a small high-level API for inspection, interaction, synchronization, scenes, screenshots, and raw commands.
8. Convert transport and command failures into readable GdUnit4 failures.
9. Capture useful diagnostics on failed tests.
10. Cleanly terminate the child process and hard-kill it when graceful shutdown fails.
11. Run the same core integration suite on Linux and Windows CI.
12. Deliver the implementation through one PR with reviewable task-level commits.

## 4. Non-goals

The MVP will not:

- replace GdUnit4 discovery, assertions, reports, retries, or CLI;
- provide a Python client or pytest integration;
- provide C# test authoring;
- claim verified C# game-target support until a dedicated .NET fixture is added;
- add Playwright-style locators or retrying `expect()` assertions;
- add process pools or parallel game sessions;
- support remote hosts or non-loopback binding;
- add video recording, trace viewers, record/replay, or an editor panel;
- build a generic RPC framework;
- vendor GdUnit4 in release artifacts;
- target exported/mobile builds in the MVP.

## 5. Product boundary

GdUnit4 owns:

- test discovery;
- assertions;
- suite/test lifecycle hooks;
- command-line execution;
- HTML/JUnit reporting;
- test selection/filtering.

`godot-e2e` owns:

- child Godot process lifecycle;
- automation-server activation;
- TCP framing/authentication;
- remote command execution;
- frame/property/node synchronization;
- screenshots and child diagnostics;
- the GDScript-facing remote game API.

This keeps the addon small and prevents it from becoming another general-purpose test framework.

## 6. Architecture

```text
GdUnit4 test process
├── GDScript test suite
├── GdUnitE2ETestSuite
├── GdUnitE2EGame
├── GdUnitE2EProcess
└── GdUnitE2EClient
          │
          │ 127.0.0.1 TCP
          │ [u32 big-endian length][UTF-8 JSON]
          ▼
Child Godot process
├── normal game main scene
└── GdUnitE2EAutomationServer autoload
    ├── token handshake
    ├── command handler
    ├── deferred waits
    ├── engine-log capture
    └── screenshot/tree access
```

### 6.1 Why the game remains the TCP server

The child-side server already fits the upstream architecture and lets the child bind an ephemeral port and report it through a port file. The GdUnit process still owns lifecycle because it launches and terminates the child.

Reversing the connection direction adds new protocol work without improving the MVP.

### 6.2 Why the client is asynchronous

The Python implementation can block a Python thread while waiting for a response. A GDScript client lives inside a Godot test runner and must not block its main loop.

The client therefore polls `StreamPeerTCP`, accumulates framed responses, correlates request IDs, and resolves requests through signals/`await`.

The MVP permits one in-flight command per client. Supporting command pipelining adds complexity without a demonstrated need.

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
│   │   ├── e2e_pending_request.gd
│   │   ├── e2e_client.gd
│   │   ├── e2e_launch_options.gd
│   │   ├── e2e_process.gd
│   │   └── gdunit_e2e_game.gd
│   └── gdunit/
│       └── gdunit_e2e_test_suite.gd
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── helpers/
│   └── fixtures/minimal/
├── scripts/
├── docs/
├── project.godot
├── README.md
├── LICENSE
└── NOTICE
```

GdUnit4 is installed separately at `res://addons/gdUnit4` for development/consumer projects and is excluded from the release archive.

## 8. Activation

Enabling the addon registers an autoload named:

```text
GdUnitE2EAutomationServer
```

pointing to:

```text
res://addons/gdunit_e2e/server/automation_server.gd
```

The autoload is inert unless `OS.get_cmdline_user_args()` contains:

```text
--gdunit-e2e
```

A normal editor/game/test-runner launch therefore pays no active networking cost.

The launcher starts a child using the current executable by default:

```text
<godot executable>
  --path <absolute project path>
  <extra Godot args>
  --
  --gdunit-e2e
  --gdunit-e2e-port=0
  --gdunit-e2e-port-file=<absolute temp file>
  --gdunit-e2e-token=<random token>
  --gdunit-e2e-log-verbosity=warning
```

The names intentionally differ from upstream `--e2e` flags so both addons cannot activate accidentally.

## 9. Protocol

### 9.1 Framing

Each message is:

```text
[4-byte unsigned big-endian JSON byte length]
[UTF-8 JSON payload]
```

The maximum frame size is 16 MiB.

- Client rejects an oversized outbound request before writing.
- Server rejects an oversized inbound frame and closes the peer.
- A response that cannot fit is replaced with a compact `frame_too_large` error.

### 9.2 Request

```json
{
  "id": 7,
  "action": "get_property",
  "path": "/root/Main/Player",
  "property": "position"
}
```

### 9.3 Success

```json
{
  "id": 7,
  "ok": true,
  "result": {
    "__godot_type": "Vector2",
    "x": 32.0,
    "y": 64.0
  }
}
```

### 9.4 Error

```json
{
  "id": 7,
  "error": "node_not_found",
  "message": "Node '/root/Main/Player' was not found"
}
```

### 9.5 Handshake

The first command must be:

```json
{
  "id": 1,
  "action": "hello",
  "token": "<per-launch random token>",
  "protocol_version": 1
}
```

The server validates the token and protocol version before accepting any other command.

## 10. MVP command surface

### Inspection

- `node_exists(path)`
- `get_property(path, property)`
- `set_property(path, property, value)`
- `call_method(path, method, args)`
- `get_tree(path = "/root", depth = 4)`
- `get_scene()`

### Interaction

- `input_action(action_name, pressed, strength)`
- `input_key(keycode, pressed, physical)`
- `input_mouse_button(x, y, button, pressed)`
- `click_node(path)`

### Synchronization

- `wait_process_frames(count)`
- `wait_physics_frames(count)`
- `wait_seconds(seconds)`
- `wait_for_node(path, timeout)`
- `wait_for_property(path, property, value, timeout)`
- `wait_for_signal(path, signal_name, timeout)`

### Scene lifecycle

- `change_scene(scene_path)`
- `reload_scene()`
- `quit(exit_code)`

### Diagnostics

- `screenshot(save_path)`
- response log deltas

### Escape hatch

`send_command(action, parameters)` remains available to test new server commands without immediately adding a convenience method.

## 11. Test-facing API

Typical usage should stay close to normal GdUnit4:

```gdscript
extends GdUnitE2ETestSuite

func test_start_game_spawns_player() -> void:
    var game := await launch_game()

    await game.click_node("/root/MainMenu/StartButton")
    await game.wait_for_node("/root/Game/Player")

    assert_bool(await game.node_exists("/root/Game/Player")).is_true()
```

For suite-level reuse:

```gdscript
extends GdUnitE2ETestSuite

var game: GdUnitE2EGame

func before() -> void:
    game = await launch_game()

func before_test() -> void:
    await game.reload_scene()

func after() -> void:
    await close_game(game)
```

The base suite is convenience, not a new runner. A normal `GdUnitTestSuite` can instantiate the lower-level API directly.

## 12. Result and failure model

GDScript does not provide Python-style exceptions, so transport APIs use an explicit result:

```gdscript
class_name E2EResult
extends RefCounted

var ok: bool
var value: Variant
var error_code: String
var message: String
```

The low-level client returns `E2EResult`.

The GdUnit-facing game wrapper turns an unsuccessful result into `GdUnitTestSuite.fail()` with a message containing:

- command/action;
- relevant node/property/scene path;
- transport or server error code;
- server message;
- recent engine logs when available.

The API must not force every user test to inspect raw dictionaries.

## 13. Process lifecycle

`GdUnitE2EProcess` uses `OS.get_executable_path()` by default and `OS.execute_with_pipe()` for the child.

Launch flow:

```text
create token + empty port file
→ launch child Godot
→ poll port file
→ connect 127.0.0.1:<port>
→ hello/token handshake
→ return GdUnitE2EGame
```

Shutdown flow:

```text
send quit when connected
→ close TCP peer
→ wait briefly for child exit
→ OS.kill(pid) if still alive
→ close pipes
→ remove port file
```

Cleanup must be idempotent. Calling `close()` twice must not fail.

The MVP does not add a process pool. Reusing one process for a suite is an explicit suite-level choice.

## 14. Failure artifacts

When an E2E test fails and a child is still reachable, the GdUnit adapter attempts best-effort capture of:

```text
test_output/<suite>/<test>/
├── screenshot.png
├── scene_tree.json
├── engine_logs.json
├── stdout.log
└── stderr.log
```

Artifact capture must never replace the original test failure. Each capture operation is independent and best effort.

If the child has already crashed, stdout/stderr and process exit information remain available even when screenshot/tree capture cannot run.

## 15. Upstream adaptation and licensing

The server-side implementation may adapt these upstream files from the pinned `godot-e2e` commit:

- `automation_server.gd`
- `command_handler.gd`
- `config.gd`
- `json_serializer.gd`
- `log_capture.gd`

Substantially adapted files must retain the required Apache-2.0 copyright/license notice and clearly state that they were modified.

The repository keeps:

- an Apache-2.0 `LICENSE`;
- a `NOTICE` that credits `godot-e2e` and its original copyright holder;
- README attribution with the pinned source commit.

The client/process/GdUnit integration is written natively in GDScript for this project rather than mechanically translating Python files.

## 16. Testing strategy

### Unit tests

Use GdUnit4 for deterministic tests of:

- frame encoding/decoding and partial reads;
- serializer round-trips;
- configuration parsing;
- command validation;
- client request correlation/timeouts using a fake local server;
- launch option construction;
- failure-message formatting;
- cleanup idempotency where OS calls can be isolated.

### Integration tests

Use a minimal real child project to verify:

1. launch + handshake;
2. node discovery/property read;
3. action input + physics-frame waiting;
4. button click;
5. scene reload/change;
6. screenshot capture;
7. graceful quit;
8. forced cleanup after an unhealthy child;
9. diagnostics on a deliberately failing E2E flow.

Tests should assert observable behavior, not reproduce upstream internals.

## 17. CI

MVP CI runs:

```text
Linux
├── bootstrap GdUnit4
├── unit tests
└── integration E2E tests under Xvfb

Windows
├── bootstrap GdUnit4
├── unit tests
└── integration E2E tests
```

Do not multiply the matrix across many Godot/GdUnit versions in the first PR. One pinned development combination per OS is enough to establish the contract.

## 18. Release packaging

Release packaging includes only:

```text
addons/gdunit_e2e/**
LICENSE
NOTICE
README.md
```

It excludes:

- `addons/gdUnit4`;
- tests;
- reports/test output;
- development scripts unless a release needs them.

## 19. Deferred follow-ups

Only add these after the MVP is useful:

1. Locator API (`get_by_text`, `get_by_group`, etc.).
2. Auto-retrying expectations.
3. Engine-error-flood detection.
4. Dedicated Godot .NET/C# fixture.
5. macOS CI.
6. Parallel child sessions.
7. richer diagnostics/trace output.
8. editor UX.

Each is independently optional; none is required to validate the core architecture.

## 20. Acceptance criteria

The MVP is accepted when:

- a GdUnit4 GDScript test can launch a real separate Godot process;
- the client authenticates and performs commands without blocking the test runner;
- a gameplay test can inject an action, wait physics frames, and verify remote state;
- a UI test can click a remote `Control` and verify the resulting remote scene state;
- a failed remote command becomes a readable GdUnit failure;
- a failed test produces available diagnostic artifacts without masking the primary failure;
- cleanup leaves no child Godot process running;
- Linux and Windows CI exercise a real child process successfully;
- no Python/pytest dependency is needed to author or run the tests;
- GdUnit4 remains the only test runner/assertion/reporting framework.
