# GdUnit E2E MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build version `0.1.0` of a standalone Godot addon that lets GdUnit4 GDScript tests launch and control a separate Godot game process through the pinned GodotE2E wire/server behavior.

**Architecture:** GdUnit4 remains the only runner/assertion/lifecycle/reporting framework. The addon adapts the pinned Apache-2.0 GodotE2E GDScript server with minimal behavioral changes, adds a non-blocking in-tree GDScript TCP client and child-process Node, and exposes a small `GdUnitE2EGame` facade plus `GdUnitE2ETestSuite` convenience base.

**Tech Stack:** Godot 4.5+, GDScript, GdUnit4 6.x, localhost TCP, four-byte big-endian length-prefixed JSON, GitHub Actions, Xvfb on Linux.

**Spec:** `docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md`

## Global Constraints

- Deliver planning and implementation through this one feature PR; keep task-level commits inside it.
- Target Godot 4.5 or newer.
- Use GdUnit4 6.x; bootstrap scripts pin one known-good 6.x release.
- Product runtime code is GDScript; Python and pytest are not runtime dependencies.
- Bind the child server only to `127.0.0.1`.
- Activate only with `--gdunit-e2e`.
- Treat `RandallLiuXin/godot-e2e` commit `ae6219f6e758a0f29bd243c8f963417fe4d63c36` as the immutable server/wire baseline.
- Preserve four-byte big-endian JSON framing and upstream `_t` serializer tags; do not add `__godot_type` or a new success/error envelope.
- Keep the pinned upstream command-handler surface; only the high-level wrapper surface is intentionally small.
- Keep `protocol_version: 1` on hello for compatibility, but do not add server-side protocol-version validation in this MVP.
- Enforce a 16 MiB frame limit by rejecting/closing, not by inventing a new wire error envelope.
- Permit one in-flight command per client.
- Use `DEFAULT_COMMAND_TIMEOUT_SECONDS = 5.0` and `WAIT_MARGIN_SECONDS = 1.0`; wrappers for server waits must give the client a later deadline.
- `E2EProcess` and `E2EClient` are Nodes and must be inside the active SceneTree while they poll.
- Launch redirected pipes with `OS.execute_with_pipe(..., false)` and never live-read child stdout/stderr on the test runner main thread.
- Use only public GdUnit4 APIs: `GdUnitTestSuite`, lifecycle hooks, `fail()`, `is_failure()`, assertions, and CLI.
- `fail()` records failure but does not abort GDScript execution; examples and helpers must return when dependent work cannot continue.
- Keep GdUnit4 external and exclude it from release archives.
- Preserve Apache-2.0 attribution on adapted upstream files.
- Validate Linux and Windows in CI; macOS and Godot .NET compatibility are follow-ups.
- Do not add locators, retrying expectations, process pools, video, editor UI, or a new test runner.
- Follow RED → GREEN → REFACTOR at each task boundary.

## Planned File Structure

```text
.
├── .github/workflows/ci.yml
├── .gitignore
├── LICENSE
├── NOTICE
├── README.md
├── project.godot
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
├── scripts/
│   ├── bootstrap_gdunit4.sh
│   ├── bootstrap_gdunit4.ps1
│   └── package_release.sh
└── tests/
    ├── helpers/fake_e2e_server.gd
    ├── fixtures/minimal/
    ├── unit/
    └── integration/
```

---

## Task 1: Establish the runnable addon and GdUnit baseline

**Files:**
- Create: `.gitignore`
- Create: `project.godot`
- Modify: `README.md`
- Create: `LICENSE`
- Create: `NOTICE`
- Create: `addons/gdunit_e2e/plugin.cfg`
- Create: `addons/gdunit_e2e/plugin.gd`
- Create: `scripts/bootstrap_gdunit4.sh`
- Create: `scripts/bootstrap_gdunit4.ps1`
- Create: `tests/unit/addon_manifest_test.gd`

**Interfaces:**
- Addon path: `res://addons/gdunit_e2e`.
- Autoload: `GdUnitE2EAutomationServer` → `res://addons/gdunit_e2e/server/automation_server.gd` once Task 3 supplies it.
- GdUnit4 stays external at `res://addons/gdUnit4`.

- [ ] **Step 1: Add repository metadata and generated-file ignores**

Use:

```gitignore
.godot/
addons/gdUnit4/
reports/
test_output/
dist/
*.tmp
*.port
```

Use a minimal root `project.godot` with a 640×360 GL Compatibility window.

- [ ] **Step 2: Add Apache-2.0 licensing and immutable upstream attribution**

`NOTICE` contains:

```text
godot-e2e (this repository)

Contains code adapted from RandallLiuXin/godot-e2e,
Copyright 2026 LIU MINGJUN (RandallLiuXin),
licensed under the Apache License 2.0.
Reference commit: ae6219f6e758a0f29bd243c8f963417fe4d63c36
```

- [ ] **Step 3: Add deterministic GdUnit4 bootstrap scripts**

Both scripts install only `addons/gdUnit4`, use the same pinned 6.x release, and exit successfully when that addon already exists.

- [ ] **Step 4: Write the manifest RED test**

```gdscript
extends GdUnitTestSuite

func test_plugin_manifest_declares_expected_entrypoint() -> void:
    var cfg := ConfigFile.new()
    assert_int(cfg.load("res://addons/gdunit_e2e/plugin.cfg")).is_equal(OK)
    assert_str(cfg.get_value("plugin", "script")).is_equal("plugin.gd")
    assert_str(cfg.get_value("plugin", "version")).is_equal("0.1.0")
```

Run:

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit/addon_manifest_test.gd
```

Expected: FAIL because the manifest is absent.

- [ ] **Step 5: Add the minimal plugin and rerun GREEN**

The editor plugin only registers/unregisters the autoload. No docks/settings/editor UX.

- [ ] **Step 6: Commit**

```bash
git add .gitignore project.godot README.md LICENSE NOTICE addons scripts tests/unit/addon_manifest_test.gd
git commit -m "chore: establish gdunit e2e addon baseline"
```

---

## Task 2: Extract upstream-compatible framing and Variant serialization

**Files:**
- Create: `addons/gdunit_e2e/protocol/e2e_protocol.gd`
- Create: `addons/gdunit_e2e/protocol/e2e_framing.gd`
- Create: `addons/gdunit_e2e/protocol/e2e_serializer.gd`
- Create: `tests/unit/protocol_test.gd`
- Create: `tests/unit/serializer_test.gd`

**Interfaces:**

```gdscript
class_name E2EProtocol
const PROTOCOL_VERSION := 1
const MAX_FRAME_BYTES := 16 * 1024 * 1024
const DEFAULT_COMMAND_TIMEOUT_SECONDS := 5.0
const WAIT_MARGIN_SECONDS := 1.0

class_name E2EFraming
static func encode_json(message: Dictionary) -> PackedByteArray
static func try_extract(buffer: PackedByteArray) -> Dictionary
# {"complete": bool, "message": Dictionary, "remaining": PackedByteArray, "error": String}

class_name E2ESerializer
static func serialize(value: Variant) -> Variant
static func deserialize(value: Variant) -> Variant
```

- [ ] **Step 1: Write framing RED tests from the pinned server behavior**

Cover four-byte big-endian length, UTF-8 JSON, partial header/body, two concatenated frames, and declared payload over 16 MiB.

```gdscript
func test_frame_prefix_is_big_endian_payload_size() -> void:
    var frame := E2EFraming.encode_json({"id": 1, "action": "node_exists"})
    var declared := (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3]
    assert_int(declared).is_equal(frame.size() - 4)
```

Run the test and confirm RED because helpers do not exist.

- [ ] **Step 2: Implement framing with no new wire envelopes**

An oversized local outbound frame returns a local parser/client failure. An oversized received declaration causes the peer to close. Do not emit a new `frame_too_large` JSON response.

- [ ] **Step 3: Write serializer RED tests using exact upstream `_t` tags**

Cover primitives and:

```text
Vector2 / Vector2i -> v2 / v2i
Vector3 / Vector3i -> v3 / v3i
Rect2 / Rect2i     -> r2 / r2i
Color              -> col
Transform2D        -> t2d
NodePath           -> np
unknown            -> _unknown
```

Also cover arrays/dictionaries and upstream supported packed arrays.

- [ ] **Step 4: Adapt `json_serializer.gd` behavior and rerun GREEN**

Do not add `__godot_type`; serialized `Vector2(32, 64)` must be exactly shaped as:

```json
{"_t":"v2","x":32.0,"y":64.0}
```

- [ ] **Step 5: Run protocol + serializer tests**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/protocol_test.gd -a tests/unit/serializer_test.gd
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add addons/gdunit_e2e/protocol tests/unit/protocol_test.gd tests/unit/serializer_test.gd
git commit -m "feat: add upstream-compatible e2e protocol primitives"
```

---

## Task 3: Adapt the pinned child automation server without shrinking its command surface

**Files:**
- Create: `addons/gdunit_e2e/server/config.gd`
- Create: `addons/gdunit_e2e/server/log_capture.gd`
- Create: `addons/gdunit_e2e/server/command_handler.gd`
- Create: `addons/gdunit_e2e/server/automation_server.gd`
- Modify: `addons/gdunit_e2e/plugin.gd`
- Create: `tests/unit/config_test.gd`
- Create: `tests/unit/command_handler_test.gd`
- Create: `tests/integration/automation_server_test.gd`

**Interfaces:**

```gdscript
class_name GdUnitE2EConfig
static func is_enabled() -> bool
static func is_valid() -> bool
static func get_validation_error() -> String
static func get_port() -> int
static func get_port_file() -> String
static func get_token() -> String
static func get_log_verbosity() -> String
```

Flags:

```text
--gdunit-e2e
--gdunit-e2e-port=<N>
--gdunit-e2e-port-file=<absolute path>
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=<error|warning|info>
```

- [ ] **Step 1: Write strict config RED tests**

Assert disabled-by-default and valid flags. Then assert these are invalid and do not fall back:

```text
--gdunit-e2e-port=abc
--gdunit-e2e-port=70000
--gdunit-e2e-port=0 without a port file
--gdunit-e2e-log-verbosity=verbose
```

`is_enabled()` may remain true because the flag was present, but `is_valid()` must be false and `get_validation_error()` non-empty.

- [ ] **Step 2: Adapt upstream config with renamed flags and fail-closed automation startup**

`automation_server._ready()` uses:

```gdscript
if not GdUnitE2EConfig.is_enabled():
    set_process(false)
    set_physics_process(false)
    return
if not GdUnitE2EConfig.is_valid():
    push_error("godot-e2e: %s" % GdUnitE2EConfig.get_validation_error())
    set_process(false)
    set_physics_process(false)
    return
```

- [ ] **Step 3: Write command-handler characterization RED tests for the retained upstream surface**

Characterize, without rewriting semantics:

```text
node_exists get_property set_property call_method
find_by_group query_nodes find_nodes node_actionable get_tree batch
input_key input_action input_mouse_button input_mouse_motion click_node hover_node
wait_process_frames wait_physics_frames wait_seconds
wait_for_node wait_for_signal wait_for_property
get_scene change_scene reload_scene
screenshot set_log_verbosity set_log_buffer_size quit
```

Pin representative exact payloads, including plain missing-node error text and `_t` serialized property values.

- [ ] **Step 4: Adapt the pinned command handler intact**

Keep commands that are not wrapped by `GdUnitE2EGame`. `send_command()` is the raw escape hatch, so deleting those commands only increases fork maintenance.

- [ ] **Step 5: Adapt log capture**

Keep the upstream bounded ring buffer and `_logs` / `_logs_dropped` response deltas. Do not add engine-error-flood detection.

- [ ] **Step 6: Adapt the automation server with only documented differences**

Differences from upstream:

```text
GdUnitE2E names
renamed --gdunit-e2e flags
listen only on 127.0.0.1
shared E2EFraming / E2EProtocol constants
16 MiB receive/send cap via disconnect/reject
```

Keep token-first hello behavior. The client sends `protocol_version: 1`, but the server does not add a new protocol-version validation branch.

- [ ] **Step 7: Add real server integration tests**

Connect raw `StreamPeerTCP` to the child and verify:

1. hello with the correct token succeeds;
2. hello response contains upstream-style `ok`, `godot_version`, and `server_version` fields;
3. wrong token disconnects;
4. non-hello first command disconnects;
5. invalid startup config never creates a listening server.

- [ ] **Step 8: Run server slice**

```bash
./addons/gdUnit4/runtest.sh \
  -a tests/unit/config_test.gd \
  -a tests/unit/command_handler_test.gd \
  -a tests/integration/automation_server_test.gd
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add addons/gdunit_e2e/server addons/gdunit_e2e/plugin.gd tests/unit/config_test.gd tests/unit/command_handler_test.gd tests/integration/automation_server_test.gd
git commit -m "feat: adapt upstream child automation server"
```

---

## Task 4: Implement the in-tree non-blocking GDScript client

**Files:**
- Create: `addons/gdunit_e2e/client/e2e_result.gd`
- Create: `addons/gdunit_e2e/client/e2e_pending_request.gd`
- Create: `addons/gdunit_e2e/client/e2e_client.gd`
- Create: `tests/helpers/fake_e2e_server.gd`
- Create: `tests/unit/client_test.gd`

**Interfaces:**

```gdscript
class_name E2EResult
extends RefCounted
var ok: bool
var value: Variant
var message: String
var logs: Array

class_name E2EClient
extends Node

func connect_to_server(port: int, token: String, timeout_seconds := E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS) -> E2EResult
func send_command(action: String, parameters := {}, timeout_seconds := E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS) -> E2EResult
func close() -> void
func is_connected() -> bool
func reset_collected_logs() -> void
func get_collected_logs() -> Array
```

`connect_to_server()` hardcodes `127.0.0.1`; there is no `host` parameter in the MVP.

- [ ] **Step 1: Build an in-tree deterministic fake server helper**

The fake server extends `Node`, listens on loopback, uses `E2EFraming`, and queues exact response dictionaries. Client tests add both fake server and client under the test suite before awaiting network work.

- [ ] **Step 2: Write client RED tests**

Cover:

- correct-token hello with `protocol_version: 1`;
- monotonically increasing request IDs;
- upstream command-specific success dictionaries;
- `_t` result deserialization;
- response over partial TCP reads;
- any response containing `error` becomes `E2EResult(ok=false)` with readable message;
- an upstream `{error, message}` pair is rendered without a new framework error-code field;
- client timeout;
- connection loss;
- `_logs`/`_logs_dropped` collection;
- second command rejected while one is in flight;
- oversized frame closes/rejects;
- `close()` idempotency;
- client receives `_process()` because it is parented in the suite tree.

- [ ] **Step 3: Implement `_process()` polling without busy waits**

Core shape:

```gdscript
func _process(_delta: float) -> void:
    if _peer == null:
        return
    _peer.poll()
    _read_available_bytes()
    _extract_complete_frames()
    _expire_pending_request_if_needed()
```

Never loop waiting for future network bytes.

- [ ] **Step 4: Implement exact upstream error/result handling**

Use:

```gdscript
if response.has("error"):
    var server_error := str(response["error"])
    var detail := str(response.get("message", server_error))
    var rendered := detail if detail == server_error else "%s — %s" % [server_error, detail]
    return E2EResult.failure(rendered, logs)
```

Do not infer `node_not_found` or other framework error enums.

- [ ] **Step 5: Implement monotonic deadline tracking**

Pending requests store an absolute `Time.get_ticks_msec()` deadline. Expiry happens only from normal `_process()` polling.

- [ ] **Step 6: Run client tests**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/client_test.gd
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add addons/gdunit_e2e/client/e2e_result.gd addons/gdunit_e2e/client/e2e_pending_request.gd addons/gdunit_e2e/client/e2e_client.gd tests/helpers/fake_e2e_server.gd tests/unit/client_test.gd
git commit -m "feat: add async in-tree gdscript e2e client"
```

---

## Task 5: Add non-blocking child-process launch, tree ownership, and bounded cleanup

**Files:**
- Create: `addons/gdunit_e2e/client/e2e_launch_options.gd`
- Create: `addons/gdunit_e2e/client/e2e_process.gd`
- Create: `tests/fixtures/minimal/project.godot`
- Create: `tests/fixtures/minimal/main.tscn`
- Create: `tests/fixtures/minimal/main.gd`
- Create: `tests/unit/launch_options_test.gd`
- Create: `tests/integration/process_lifecycle_test.gd`

**Interfaces:**

```gdscript
class_name E2ELaunchOptions
extends RefCounted
var project_path: String
var godot_path: String
var timeout_seconds := 10.0
var extra_godot_args: PackedStringArray
var log_verbosity := "warning"

class_name E2EProcess
extends Node

func launch(options: E2ELaunchOptions) -> E2EResult
func close() -> void
func is_running() -> bool
func get_client() -> E2EClient
func get_stdout() -> String
func get_stderr() -> String
func get_exit_code() -> int
```

- [ ] **Step 1: Write launch-option RED tests**

Validate project path, optional executable, log verbosity, and exact argv. After `--`, argv contains only:

```text
--gdunit-e2e
--gdunit-e2e-port=0
--gdunit-e2e-port-file=...
--gdunit-e2e-token=...
--gdunit-e2e-log-verbosity=...
```

Assert GdUnit CLI arguments are never forwarded.

- [ ] **Step 2: Create the minimal fixture project**

```gdscript
extends Node2D

@onready var status: Label = $Status
var action_count := 0

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("ui_accept"):
        action_count += 1
        status.text = "accepted:%d" % action_count
```

Include a `Button` whose `pressed` signal changes another label.

- [ ] **Step 3: Write process lifecycle RED tests**

Test:

1. the `E2EProcess` must be in the SceneTree before launch;
2. child launches with `OS.execute_with_pipe(..., false)` behavior;
3. child writes an ephemeral port file;
4. `E2EClient` is added as child of `E2EProcess` before connect;
5. client connects/authenticates;
6. process is alive after launch;
7. no stdout/stderr read is attempted while child is alive;
8. graceful close reaps child;
9. forced close kills an unhealthy child;
10. after close `OS.is_process_running(pid)` is false;
11. non-blocking pipe drain terminates at EOF/error/bound after death;
12. `close()` twice is safe;
13. port file is removed.

- [ ] **Step 4: Implement launch with explicitly non-blocking pipes**

Use the exact call shape:

```gdscript
var process_info := OS.execute_with_pipe(executable, args, false)
```

Do not omit the third argument.

Poll only process status and the port file during startup. Do not read stdout/stderr while the child is running.

- [ ] **Step 5: Implement client parenting and launch handshake**

```gdscript
_client = E2EClient.new()
add_child(_client)
var result := await _client.connect_to_server(_port, _token, options.timeout_seconds)
```

`E2EProcess` itself is parented by the GdUnit suite in Task 7; direct integration tests must `add_child(process)` before calling `launch()`.

- [ ] **Step 6: Implement bounded shutdown and post-death pipe drain**

Attempt remote `quit`, close TCP, wait a short grace period, then call `OS.kill(pid)` if needed. Only after `OS.is_process_running(pid)` is false, drain each non-blocking pipe until EOF/error or a documented small bound.

- [ ] **Step 7: Run lifecycle integration tests**

```bash
./addons/gdUnit4/runtest.sh -a tests/integration/process_lifecycle_test.gd
```

Expected: PASS with no surviving child process.

- [ ] **Step 8: Commit**

```bash
git add addons/gdunit_e2e/client/e2e_launch_options.gd addons/gdunit_e2e/client/e2e_process.gd tests/fixtures/minimal tests/unit/launch_options_test.gd tests/integration/process_lifecycle_test.gd
git commit -m "feat: manage non-blocking e2e child lifecycle"
```

---

## Task 6: Expose the high-level remote game API with deterministic wait deadlines

**Files:**
- Create: `addons/gdunit_e2e/client/gdunit_e2e_game.gd`
- Create: `tests/unit/game_api_test.gd`
- Create: `tests/integration/gameplay_smoke_test.gd`

**Interfaces:**

```gdscript
class_name GdUnitE2EGame
extends RefCounted

func node_exists(path: String) -> bool
func get_property(path: String, property: String) -> Variant
func set_property(path: String, property: String, value: Variant) -> bool
func call_method(path: String, method: String, args := []) -> Variant
func get_tree(path := "/root", depth := 4) -> Dictionary

func input_action(action_name: String, pressed: bool, strength := 1.0) -> bool
func press_action(action_name: String, strength := 1.0) -> bool
func input_key(keycode: int, pressed: bool, physical := false) -> bool
func input_mouse_button(x: float, y: float, button := 1, pressed := true) -> bool
func click_node(path: String) -> bool

func wait_process_frames(count := 1) -> bool
func wait_physics_frames(count := 1) -> bool
func wait_seconds(seconds: float) -> bool
func wait_for_node(path: String, timeout := 5.0) -> bool
func wait_for_property(path: String, property: String, value: Variant, timeout := 5.0) -> bool
func wait_for_signal(path: String, signal_name: String, timeout := 5.0) -> Array

func get_scene() -> String
func change_scene(scene_path: String) -> bool
func reload_scene() -> bool
func screenshot(save_path := "") -> String
func send_command(action: String, parameters := {}, timeout := E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS) -> E2EResult
```

`GdUnitE2EGame` receives a live `E2EProcess`/`E2EClient` plus the owning `GdUnitTestSuite` used only for public `fail()`/`is_failure()` behavior.

- [ ] **Step 1: Write fake-client RED tests for exact command shapes**

Verify wrappers send pinned upstream command names/parameters and deserialize business values. Do not require every upstream server command to gain a wrapper.

- [ ] **Step 2: Write timeout-margin RED tests**

Pin these client deadlines:

```gdscript
await game.wait_for_node(path, 5.0)      # send_command timeout 6.0
await game.wait_for_property(..., 2.5)  # send_command timeout 3.5
await game.wait_for_signal(..., 1.0)    # send_command timeout 2.0
await game.wait_seconds(3.0)             # send_command timeout 4.0
```

Scene change/reload use `DEFAULT_COMMAND_TIMEOUT_SECONDS + WAIT_MARGIN_SECONDS`.

- [ ] **Step 3: Implement wrapper failure mapping with safe fallbacks**

A helper formats context plus the `E2EResult.message` and calls only public `GdUnitTestSuite.fail()`.

```gdscript
func _fail_remote(action: String, context: String, result: E2EResult) -> void:
    _suite.fail("E2E command %s failed%s: %s" % [
        action,
        " for " + context if not context.is_empty() else "",
        result.message,
    ])
```

Do not add a framework error-code enum.

- [ ] **Step 4: Keep raw `send_command()` non-failing**

Raw `send_command()` returns `E2EResult` directly and does not call GdUnit `fail()`. This is the deliberate escape hatch for retained upstream commands and negative-path tests.

- [ ] **Step 5: Add real gameplay smoke tests**

```gdscript
func test_action_reaches_separate_game_process() -> void:
    var game := await launch_fixture_game()
    if is_failure():
        return

    assert_int(await game.get_property("/root/Main", "action_count")).is_equal(0)
    if is_failure():
        return

    await game.press_action("ui_accept")
    if is_failure():
        return

    await game.wait_process_frames(2)
    if is_failure():
        return

    assert_int(await game.get_property("/root/Main", "action_count")).is_equal(1)
```

Add a second integration test for `click_node()` changing the fixture label.

- [ ] **Step 6: Add real server/client timeout-race regression**

Use a server wait close to its configured timeout and assert the result arrives as the server's timeout/failure result rather than a client timeout. The test must fail if the client deadline equals the server timeout instead of adding the 1 second margin.

- [ ] **Step 7: Run API + smoke tests**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/game_api_test.gd -a tests/integration/gameplay_smoke_test.gd
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add addons/gdunit_e2e/client/gdunit_e2e_game.gd tests/unit/game_api_test.gd tests/integration/gameplay_smoke_test.gd
git commit -m "feat: expose gdunit remote game api"
```

---

## Task 7: Integrate GdUnit tree ownership, failure state, cleanup, and artifacts

**Files:**
- Create: `addons/gdunit_e2e/gdunit/gdunit_e2e_test_suite.gd`
- Create: `tests/unit/gdunit_suite_test.gd`
- Create: `tests/integration/failure_artifact_test.gd`

**Interfaces:**

```gdscript
class_name GdUnitE2ETestSuite
extends GdUnitTestSuite

func launch_game(options := E2ELaunchOptions.new()) -> GdUnitE2EGame
func close_game(game: GdUnitE2EGame) -> void
func capture_failure_artifacts(game: GdUnitE2EGame) -> void
```

The base suite tracks launched `E2EProcess` Nodes for guaranteed cleanup but does not replace GdUnit's runner.

- [ ] **Step 1: Write suite-parenting RED tests**

Verify `launch_game()`:

1. creates `E2EProcess`;
2. calls `add_child(process)` before `await process.launch()`;
3. returns a `GdUnitE2EGame` only after launch succeeds;
4. on launch failure calls `fail(message)` and returns `null`;
5. cleanup closes, removes, and frees tracked process Nodes.

- [ ] **Step 2: Implement suite launch/cleanup with explicit failure return behavior**

Consumer pattern is pinned in tests/docs:

```gdscript
var game := await launch_game()
if is_failure():
    return
```

Do not rely on `fail()` to stop execution.

- [ ] **Step 3: Write failure-format unit tests**

For an upstream missing-node response, desired failure text contains the action, target context, and exact upstream message, for example:

```text
E2E command get_property failed for /root/Main/Missing.health: Node not found: /root/Main/Missing
```

Do not expect `node_not_found`.

- [ ] **Step 4: Implement reachable-child artifact capture**

`capture_failure_artifacts(game)` independently attempts screenshot, scene tree, and engine logs. One failure cannot suppress the others.

- [ ] **Step 5: Implement post-death stdout/stderr artifact finalization**

`close_game()` lets `E2EProcess.close()` kill/reap then drain pipes. If the current test has an artifact directory, write `stdout.log`/`stderr.log` afterward. No live pipe reads.

- [ ] **Step 6: Unit-test artifact helper with fakes**

Use a fake/reachable `GdUnitE2EGame` and fake process outputs. Assert filenames/content without creating a failing GdUnit test.

- [ ] **Step 7: Add non-failing artifact integration test using raw command failure**

```gdscript
func test_known_bad_command_can_capture_failure_artifacts() -> void:
    var game := await launch_game()
    if is_failure():
        return

    var result := await game.send_command("get_property", {
        "path": "/root/Main/Missing",
        "property": "health",
    })
    assert_bool(result.ok).is_false()

    await capture_failure_artifacts(game)
    await close_game(game)

    assert_file("test_output/.../scene_tree.json").exists()
```

The outer suite stays green; it characterizes diagnostics after a known-bad raw command instead of nesting an intentionally failing GdUnit run.

- [ ] **Step 8: Run suite/artifact tests**

```bash
./addons/gdUnit4/runtest.sh \
  -a tests/unit/gdunit_suite_test.gd \
  -a tests/integration/failure_artifact_test.gd
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add addons/gdunit_e2e/gdunit tests/unit/gdunit_suite_test.gd tests/integration/failure_artifact_test.gd
git commit -m "feat: integrate gdunit lifecycle and diagnostics"
```

---

## Task 8: Add CI, packaging, and user documentation

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `scripts/package_release.sh`
- Modify: `README.md`
- Modify: `NOTICE` if the adapted-file attribution list changes
- Verify: all tests

**Interfaces:**
- Linux and Windows CI exercise real child processes.
- Release: `dist/godot-e2e-0.1.0.zip` contains only distributable files.

- [ ] **Step 1: Add Linux CI**

```text
checkout
→ install pinned Godot 4.5+ build
→ ./scripts/bootstrap_gdunit4.sh
→ start Xvfb / set DISPLAY
→ run full GdUnit suite
→ upload reports/test_output on failure
```

- [ ] **Step 2: Add Windows CI**

```text
checkout
→ install same Godot version family
→ powershell ./scripts/bootstrap_gdunit4.ps1
→ run full GdUnit suite
→ upload reports/test_output on failure
```

No macOS or version matrix in this PR.

- [ ] **Step 3: Add release packaging test/script**

Package exactly:

```text
addons/gdunit_e2e/**
README.md
LICENSE
NOTICE
```

Exclude `addons/gdUnit4`, tests, reports, `test_output`, and development-only files.

- [ ] **Step 4: Replace planning README with user-facing setup**

README includes prerequisites, install/enable steps, architecture distinction from GdUnit scene tests, wrapped MVP API, raw `send_command()` escape hatch, child-autoload behavior, CI notes, and pinned upstream attribution.

The minimal example must show explicit abort after recorded failure:

```gdscript
extends GdUnitE2ETestSuite

func test_game_accepts_input() -> void:
    var game := await launch_game()
    if is_failure():
        return

    await game.press_action("ui_accept")
    if is_failure():
        return

    await game.wait_process_frames(2)
    if is_failure():
        return

    assert_int(await game.get_property("/root/Main", "action_count")).is_equal(1)
```

Document that the child uses the same project and therefore loads normal project autoloads; the launcher forwards no GdUnit CLI arguments to the child.

- [ ] **Step 5: Run complete local verification**

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests -c
./scripts/package_release.sh
unzip -l dist/godot-e2e-0.1.0.zip
```

Verify zero failures, no live child PIDs, no stale `.port` files, and no vendored GdUnit4/test files in the ZIP.

- [ ] **Step 6: Commit**

```bash
git add .github README.md NOTICE scripts/package_release.sh
git commit -m "ci: validate and package gdunit e2e addon"
```

---

## Final PR Verification

Before marking the single implementation PR ready for review:

- [ ] Re-read the design spec and map every acceptance criterion to a passing test or explicit packaging/CI check.
- [ ] Search the spec, plan, and production protocol code for `__godot_type`, `node_not_found`, and a universal `{ok,result}` response assumption; none may define the wire contract.
- [ ] Compare adapted server/serializer/config behavior with pinned commit `ae6219f6e758a0f29bd243c8f963417fe4d63c36`; intentional differences are limited to names/flags, loopback binding, strict startup config, shared framing, and the 16 MiB cap.
- [ ] Confirm retained upstream commands still exist even when `GdUnitE2EGame` has no convenience wrapper.
- [ ] Confirm `connect_to_server()` has no host parameter and uses `127.0.0.1`.
- [ ] Confirm wait wrappers add `WAIT_MARGIN_SECONDS` to their client deadline.
- [ ] Confirm every polling `E2EClient` in tests/production is parented in the active SceneTree.
- [ ] Search for `execute_with_pipe(` and confirm every child launch passes `false` for `blocking`.
- [ ] Search process code for stdout/stderr reads while `OS.is_process_running(pid)` is true; none should exist.
- [ ] Run the complete GdUnit suite from a clean checkout after bootstrapping GdUnit4.
- [ ] Confirm Linux CI passes.
- [ ] Confirm Windows CI passes.
- [ ] Confirm artifact integration stays green while exercising a raw known-bad command.
- [ ] Inspect the release ZIP and confirm it contains only addon + README/LICENSE/NOTICE.
- [ ] Search production addon code for Python/pytest imports, locators, process pools, editor panels, and other deferred features; none should exist.
- [ ] Search adapted upstream files for Apache-2.0 attribution/modification notices.
- [ ] Confirm the work remains one PR with task-level commits.

## Follow-ups after 0.1.0

Do not pull these into the MVP unless a failing core test proves they are required:

1. Playwright-like locators.
2. Retrying `expect()` assertions.
3. Engine-error-flood detection.
4. Dedicated Godot .NET/C# target fixture.
5. macOS CI.
6. Multiple parallel child sessions.
7. Richer trace/diagnostic UX.
