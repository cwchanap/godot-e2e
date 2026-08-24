# GdUnit E2E Addon Design

**Status:** Approved for implementation planning  
**Date:** 2026-08-23  
**Repository:** `cwchanap/godot-e2e`  
**License:** Apache-2.0  
**Target:** Godot 4.5+ and GdUnit4 6.x

## 1. Summary

`godot-e2e` is a standalone Godot addon for writing true out-of-process end-to-end tests in GDScript while keeping GdUnit4 as the only test runner, assertion library, lifecycle framework, CLI, and reporter.

A GdUnit4 test process launches a second Godot process containing the game under test. A small automation-server autoload runs in that child only when explicitly activated. The GdUnit process controls the child through a non-blocking GDScript client over localhost TCP.

The child-side implementation is adapted from `RandallLiuXin/godot-e2e` at immutable commit `ae6219f6e758a0f29bd243c8f963417fe4d63c36`. That pinned GDScript server is the protocol and behavior baseline. We rename activation flags/autoload names, bind explicitly to loopback, share framing helpers, and add a 16 MiB parser limit, but we do not invent a second wire format.

## 2. Problem

GdUnit4 already covers unit tests and in-process scene/integration tests well. Its scene runner should remain the default for most tests, but it does not create an independent application process boundary:

- a game crash can terminate the test runner;
- application startup/shutdown is not exercised as a separate process;
- tests can accidentally reach directly into local scene objects;
- child stdout/stderr and startup failures are not naturally part of the test boundary.

This addon adds only the out-of-process layer needed for a small number of critical flows.

## 3. Goals

The MVP must:

1. Let a GdUnit4 GDScript test launch a Godot project as a separate child process.
2. Enable the automation server only with `--gdunit-e2e`.
3. Bind only to `127.0.0.1`.
4. Pair launcher and child with a random per-launch token.
5. Preserve the pinned upstream server's four-byte big-endian length-prefixed UTF-8 JSON wire behavior and serializer tags.
6. Preserve the pinned upstream command-handler surface in the adapted server so the fork stays small.
7. Provide a non-blocking GDScript client with one in-flight command.
8. Provide a small high-level GdUnit-facing API for the commands needed by the MVP.
9. Use explicit `E2EResult` values at the transport boundary instead of pretending GDScript has Python-style exceptions.
10. Make server waits and client deadlines deterministic by applying a client-side margin.
11. Capture useful failure diagnostics without replacing the primary GdUnit failure.
12. Cleanly terminate the child and hard-kill it when graceful shutdown fails.
13. Run the core integration suite on Linux and Windows CI.
14. Deliver the MVP through one PR with reviewable task-level commits.

## 4. Non-goals

The MVP will not:

- replace GdUnit4 discovery, assertions, reports, retries, or CLI;
- provide a Python runtime dependency or pytest integration;
- provide C# test authoring;
- claim verified C# game-target support before a dedicated .NET fixture exists;
- add Playwright-style locators or retrying `expect()` assertions;
- add process pools or parallel game sessions;
- support remote hosts or non-loopback binding;
- add video recording, trace viewers, record/replay, or editor UI;
- build a generic RPC framework;
- vendor GdUnit4 in release artifacts;
- target exported/mobile builds in the MVP;
- redesign the pinned upstream wire response envelopes;
- translate Python exception classes into a parallel GDScript error taxonomy.

## 5. Product boundary

GdUnit4 owns:

- test discovery;
- assertions and failure state;
- suite/test lifecycle hooks;
- command-line execution;
- HTML/JUnit reporting;
- test selection/filtering.

`godot-e2e` owns:

- child Godot process lifecycle;
- child automation-server activation;
- localhost transport/framing/token pairing;
- remote command execution;
- synchronization commands;
- screenshots, scene-tree capture, engine-log deltas, and child stdout/stderr;
- the GDScript-facing remote-game API.

## 6. Architecture

```text
GdUnit4 test process
├── GDScript test suite
├── GdUnitE2ETestSuite        <- owns child-process Nodes in the SceneTree
├── GdUnitE2EGame             <- RefCounted facade, never the tree owner
└── E2EProcess (Node)
    └── E2EClient (Node)       <- _process() polls non-blocking TCP
          │
          │ 127.0.0.1 TCP
          │ [u32 big-endian length][UTF-8 JSON]
          ▼
Child Godot process
├── normal game main scene
└── GdUnitE2EAutomationServer autoload
    ├── token hello handshake
    ├── pinned upstream command surface
    ├── deferred waits
    ├── engine-log capture
    └── screenshot/tree access
```

### 6.1 Game remains the TCP server

The upstream child-side server already binds an ephemeral port and reports it through a port file. Keeping that direction minimizes divergence. The GdUnit process still owns lifecycle because it launches, parents, monitors, and terminates the child.

### 6.2 Client is asynchronous and must be in-tree

The Python reference client can block a Python thread. A GDScript client running inside the GdUnit Godot process must not block the main loop.

`E2EClient` therefore extends `Node`, polls `StreamPeerTCP` from `_process()`, accumulates framed responses, and resolves one pending request through `await`-friendly signals/state.

A `Node` that is not inside the active SceneTree will not receive `_process()`. Therefore:

- `GdUnitE2ETestSuite.launch_game()` creates `E2EProcess`, adds it as a child of the suite, then launches/connects;
- `E2EProcess` adds `E2EClient` as its child before connecting;
- `close_game()` closes the process, removes it from the tree, and frees it;
- a caller using `E2EProcess` directly from a normal `GdUnitTestSuite` must `add_child(process)` before awaiting launch.

`GdUnitE2EGame` is `RefCounted`; it references the live process/client but never owns the SceneTree lifetime.

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

GdUnit4 is installed separately at `res://addons/gdUnit4` for development/consumer projects and is excluded from release archives.

## 8. Activation and child argv

Enabling the addon registers an autoload named:

```text
GdUnitE2EAutomationServer
```

pointing to:

```text
res://addons/gdunit_e2e/server/automation_server.gd
```

The autoload is inert unless `OS.get_cmdline_user_args()` contains `--gdunit-e2e`.

The launcher uses the current executable by default:

```text
<godot executable>
  --path <absolute project path>
  <extra Godot engine args>
  --
  --gdunit-e2e
  --gdunit-e2e-port=0
  --gdunit-e2e-port-file=<absolute temp file>
  --gdunit-e2e-token=<random token>
  --gdunit-e2e-log-verbosity=warning
```

Only E2E user arguments are passed after `--`. GdUnit CLI arguments are not forwarded to the child, so launching the game does not recursively invoke the GdUnit CLI.

The child is still the same Godot project. Normal project autoloads therefore load in the child exactly as they do on F5, including any GdUnit-related autoloads configured by the consumer. Those autoloads must already be safe/inert during a normal game run. The MVP does not create a shadow project to suppress them.

The E2E flag names intentionally differ from upstream `--e2e` names so both addons cannot activate accidentally.

### 8.1 Invalid configuration

When `--gdunit-e2e` is present, invalid E2E startup values are fatal to automation startup:

- non-integer or out-of-range `--gdunit-e2e-port`;
- `--gdunit-e2e-port=0` without a writable port-file path;
- unsupported log verbosity.

The config parser exposes the validation error, the autoload emits `push_error()`, disables processing, and does not listen. It must not silently fall back to a shared default port.

## 9. Wire contract

The pinned GDScript server at commit `ae6219f6e758a0f29bd243c8f963417fe4d63c36` is the v1 behavioral contract. The addon may extract common framing/serializer helpers, but emitted/accepted payload shapes remain compatible with that server.

### 9.1 Framing

Each message is:

```text
[4-byte unsigned big-endian JSON byte length]
[UTF-8 JSON payload]
```

`E2EFraming` is shared by the client and adapted server so the frame implementation cannot drift.

The parser enforces `MAX_FRAME_BYTES = 16 * 1024 * 1024`:

- client rejects an oversized request locally before writing;
- server closes the peer on an oversized inbound declaration;
- client closes the peer if an oversized response declaration is received;
- server disconnects rather than inventing a new wire response envelope when a response itself cannot be encoded within the cap.

### 9.2 Request example

```json
{
  "id": 7,
  "action": "get_property",
  "path": "/root/Main/Player",
  "property": "position"
}
```

### 9.3 Success examples are command-specific

The server does not wrap every success in a new `{ok, result}` envelope.

`get_property` with a `Vector2` uses the upstream `_t` serializer tag:

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

`node_exists` returns its own field:

```json
{
  "id": 8,
  "exists": true
}
```

Mutating commands commonly return:

```json
{
  "id": 9,
  "ok": true
}
```

The client deserializes values using the pinned upstream tags (`v2`, `v2i`, `v3`, `v3i`, `r2`, `r2i`, `col`, `t2d`, `np`, `_unknown`). It does not introduce `__godot_type`.

### 9.4 Error examples remain upstream-shaped

A missing node from `get_property` is:

```json
{
  "id": 7,
  "error": "Node not found: /root/Main/Player"
}
```

Some existing upstream commands already return a short error string plus a `message`; those shapes are preserved as-is. The new client treats the presence of `error` as failure and produces one readable `E2EResult.message`; it does not define a parallel `node_not_found`/`invalid_argument` enum for the framework.

### 9.5 Handshake

The first command is compatible with the upstream Python client:

```json
{
  "id": 1,
  "action": "hello",
  "token": "<per-launch random token>",
  "protocol_version": 1
}
```

The pinned GDScript server validates the token and first-command ordering. It does not validate `protocol_version`; this addon keeps that behavior in the MVP. The field remains on the client hello for wire compatibility and future evolution.

A successful hello remains command-specific:

```json
{
  "id": 1,
  "ok": true,
  "godot_version": "4.5.0",
  "server_version": "0.1.0"
}
```

Token pairing is not expanded into a new security model. The server is loopback-only and the token exists to pair the launcher with its child process.

## 10. Server surface versus wrapped MVP surface

### 10.1 Adapted server surface

Keep the pinned upstream command-handler surface instead of deleting commands merely because the first high-level wrapper does not expose them. This minimizes fork diff and keeps raw `send_command()` useful.

Retained server commands include the pinned upstream commands such as:

- `node_exists`, `get_property`, `set_property`, `call_method`;
- `find_by_group`, `query_nodes`, `find_nodes`, `node_actionable`, `get_tree`, `batch`;
- `input_key`, `input_action`, `input_mouse_button`, `input_mouse_motion`, `click_node`, `hover_node`;
- `wait_process_frames`, `wait_physics_frames`, `wait_seconds`, `wait_for_node`, `wait_for_signal`, `wait_for_property`;
- `get_scene`, `change_scene`, `reload_scene`;
- `screenshot`, `set_log_verbosity`, `set_log_buffer_size`, `quit`.

The MVP does not add convenience wrappers for every retained command.

### 10.2 High-level `GdUnitE2EGame` wrappers

Inspection:

- `node_exists(path)`
- `get_property(path, property)`
- `set_property(path, property, value)`
- `call_method(path, method, args)`
- `get_tree(path = "/root", depth = 4)`
- `get_scene()`

Interaction:

- `input_action(action_name, pressed, strength)`
- `press_action(action_name, strength)`
- `input_key(keycode, pressed, physical)`
- `input_mouse_button(x, y, button, pressed)`
- `click_node(path)`

Synchronization:

- `wait_process_frames(count)`
- `wait_physics_frames(count)`
- `wait_seconds(seconds)`
- `wait_for_node(path, timeout)`
- `wait_for_property(path, property, value, timeout)`
- `wait_for_signal(path, signal_name, timeout)`

Scene lifecycle:

- `change_scene(scene_path)`
- `reload_scene()`

Diagnostics/lifecycle:

- `screenshot(save_path)`
- `quit(exit_code)`
- collected response-log deltas
- raw `send_command(action, parameters, timeout)` escape hatch.

## 11. Result and failure model

### 11.1 Transport result

```gdscript
class_name E2EResult
extends RefCounted

var ok: bool
var value: Variant
var message: String
var logs: Array
```

`E2EClient` returns `E2EResult` for connection, handshake, and raw commands.

For a server response containing `error`, `ok` is false and `message` is the server's readable message. When an upstream response has both `error` and `message`, the client preserves both pieces in the rendered message without creating a framework-level error-code enum.

Transport failures use readable messages such as connection loss, timeout, invalid frame, or oversize frame.

### 11.2 GdUnit-facing wrappers

Convenience wrappers translate a failed `E2EResult` into the public GdUnit `fail(message)` API and return a safe fallback (`false`, `null`, empty array/dictionary/string as appropriate).

`fail()` records failure but does not terminate the current GDScript function. Therefore tests must stop explicitly when later steps depend on a failed launch/remote call.

Minimal example:

```gdscript
extends GdUnitE2ETestSuite

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

The raw `game.send_command()` escape hatch returns `E2EResult` without automatically failing the suite. This supports deliberate negative-path tests and direct artifact tests.

## 12. Timeout policy

The low-level client has `DEFAULT_COMMAND_TIMEOUT_SECONDS = 5.0` for ordinary commands and `WAIT_MARGIN_SECONDS = 1.0`.

Server-side wait duration and client-side transport deadline are separate concepts. A client deadline must always be later than the server's expected completion:

- `wait_for_node/property/signal(timeout)` uses client deadline `timeout + WAIT_MARGIN_SECONDS`;
- `wait_seconds(seconds)` uses `seconds + WAIT_MARGIN_SECONDS`;
- scene-change/reload wrappers use the command timeout plus the same margin because the server resolves them asynchronously;
- raw callers can pass an explicit client timeout when exercising retained server commands;
- frame waits use the normal command timeout for ordinary counts and expose a raw explicit timeout if a caller intentionally waits an unusually large number of frames.

This prevents the client timer from winning a race against a server wait with the same nominal timeout.

## 13. Process lifecycle

`E2EProcess` extends `Node` and uses `OS.get_executable_path()` by default.

### 13.1 Launch

`OS.execute_with_pipe(path, args, false)` is mandatory. Godot's default is blocking pipes; this framework always requests non-blocking pipes.

Launch flow:

```text
parent E2EProcess under the GdUnit suite
→ create token + empty port-file path
→ execute_with_pipe(..., blocking=false)
→ poll port file without reading stdout/stderr
→ add E2EClient child Node
→ connect 127.0.0.1:<port>
→ hello/token handshake
→ return GdUnitE2EGame
```

The framework does not live-read stdout/stderr on the main thread during tests.

### 13.2 Shutdown

```text
send quit when connected
→ close TCP peer
→ wait a short bounded grace period for PID exit
→ OS.kill(pid) if still running
→ assert/verify PID is no longer running
→ drain stdout/stderr from non-blocking pipes with a bounded read loop
→ close pipes
→ remove port file
→ remove/free E2EProcess Node
```

Pipe draining occurs only after the child is dead. Reads stop when `FileAccess.get_error() != OK`, EOF is reached, or a small byte/time bound is reached. Diagnostics are best effort and must never hang suite cleanup.

`close()` is idempotent.

## 14. Failure artifacts

Failure diagnostics use two phases so the runner never blocks on live process pipes.

While the child is reachable, `capture_failure_artifacts(game)` attempts independently:

```text
test_output/<suite>/<test>/
├── screenshot.png
├── scene_tree.json
└── engine_logs.json
```

During/after `close_game()`, once the PID is dead and pipes are drained, the same directory receives when available:

```text
├── stdout.log
└── stderr.log
```

Artifact errors are secondary diagnostics and never replace the primary GdUnit failure.

The artifact helper itself is tested without intentionally failing the outer GdUnit run: an integration test sends a known-bad command through raw `send_command()`, asserts `E2EResult.ok == false`, invokes artifact capture directly, closes the game, and asserts the files that are available.

## 15. Upstream adaptation and licensing

Adapt these files from the pinned upstream commit where useful:

- `addons/godot_e2e/automation_server.gd`;
- `addons/godot_e2e/command_handler.gd`;
- `addons/godot_e2e/config.gd`;
- `addons/godot_e2e/json_serializer.gd`;
- `addons/godot_e2e/log_capture.gd`;
- `addons/godot_e2e/plugin.gd`.

The adapted files live under `addons/gdunit_e2e/` and may be reorganized, but their wire behavior remains pinned unless this design explicitly documents a difference.

Substantially adapted files retain Apache-2.0 notices and state that they were modified. The repository contains `LICENSE`, `NOTICE`, README attribution, and the immutable source commit.

The new GDScript client/process/GdUnit integration is native code for this repository rather than a mechanical translation of Python modules.

## 16. Testing strategy

### 16.1 Unit tests

Use GdUnit4 for:

- framing and partial reads, including 16 MiB limits;
- upstream serializer-tag round trips;
- strict E2E config parsing;
- retained command-handler behavior;
- client request IDs, one-in-flight rejection, partial responses, log collection, timeouts, and disconnects with an in-tree fake server;
- wait timeout + 1 second client-margin behavior;
- launch option/argv construction including `blocking=false` launch intent;
- failure formatting without invented error codes;
- suite parenting/cleanup behavior;
- artifact helper behavior with fakes.

### 16.2 Integration tests

Use a minimal real child project to verify:

1. launch + token handshake;
2. process/client Nodes receive processing because they are parented under the suite;
3. node discovery/property read;
4. action input + physics-frame waiting;
5. button click;
6. scene reload/change;
7. wait timeout returns the server result before the client margin expires;
8. screenshot capture;
9. graceful quit and `OS.is_process_running(pid) == false`;
10. forced cleanup after an unhealthy child;
11. artifact capture after a raw known-bad command;
12. no surviving child PID or stale port file.

Tests assert observable behavior rather than reimplementing upstream internals.

## 17. CI

MVP CI runs one pinned Godot/GdUnit4 combination per OS:

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

No macOS or version matrix in the MVP.

## 18. Release packaging

Release archive:

```text
addons/gdunit_e2e/**
README.md
LICENSE
NOTICE
```

Exclude GdUnit4, tests, reports, `test_output`, and development-only scripts.

## 19. Deferred follow-ups

Only add these after the MVP proves useful:

1. Locator API.
2. Auto-retrying expectations.
3. Engine-error-flood detection.
4. Dedicated Godot .NET/C# fixture.
5. macOS CI.
6. Parallel child sessions.
7. Richer trace/diagnostic UX.
8. Editor UX.

## 20. Acceptance criteria

The MVP is accepted when:

- a GdUnit4 GDScript suite launches a separate real Godot process;
- `E2EProcess` and `E2EClient` are demonstrably in the test runner SceneTree while active;
- the child server stays inert without `--gdunit-e2e` and refuses invalid E2E startup configuration;
- the server listens only on loopback and authenticates the first command with the launch token;
- actual wire payloads use the pinned upstream response shapes and `_t` serializer tags;
- the adapted server retains the pinned upstream command-handler surface;
- the client is non-blocking and permits one in-flight request;
- server wait commands receive a client deadline later than their server timeout;
- high-level failures use GdUnit `fail()` and examples explicitly return after a recorded failure when subsequent work depends on success;
- a real input action changes observable state in the child;
- a real UI click changes observable state in the child;
- screenshot/tree/log artifacts can be captured without a nested intentionally failing GdUnit suite;
- `execute_with_pipe(..., false)` is used and live stdout/stderr are not read on the main thread;
- shutdown leaves `OS.is_process_running(pid) == false` and no stale port file;
- Linux and Windows CI pass the same core E2E suite;
- the release archive contains no Python/pytest runtime and no vendored GdUnit4;
- Apache-2.0 attribution is preserved for adapted upstream files;
- the MVP remains one implementation PR.
