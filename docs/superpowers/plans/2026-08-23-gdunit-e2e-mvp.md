# GdUnit E2E MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build version `0.1.0` of a standalone Godot addon that lets GdUnit4 GDScript tests launch and control a separate Godot child process while automatically cleaning up children and capturing diagnostics on real test failures.

**Architecture:** GdUnit4 remains the only test runner/assertion/lifecycle/reporting layer. The addon adapts the pinned Apache-2.0 `godot-e2e` GDScript server, keeps its wire behavior and command surface, adds a non-blocking in-tree GDScript client plus child-process Node, and exposes a small `GdUnitE2EGame` facade. Each MVP test owns its child; `after_test()` captures diagnostics on failure and reaps all tracked children, while the child has an authenticated-peer orphan watchdog for abnormal parent death.

**Tech Stack:** Godot 4.5+, GDScript, GdUnit4 6.x, localhost TCP, four-byte big-endian length-prefixed JSON, GitHub Actions, Xvfb on Linux.

**Spec:** `docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md`

## Global Constraints

- Deliver planning and implementation through this single feature PR with task-level commits.
- Target Godot 4.5 or newer.
- Use GdUnit4 6.x, pinned once in `scripts/bootstrap_gdunit4.sh` for development/CI.
- Product runtime code is GDScript; Python and pytest are not runtime dependencies.
- Bind only `127.0.0.1`.
- Activate the child server only with `--gdunit-e2e`.
- Treat upstream commit `ae6219f6e758a0f29bd243c8f963417fe4d63c36` as the immutable v1 wire/behavior baseline.
- Preserve upstream command-specific response shapes and `_t` serializer tags.
- Keep the full pinned upstream command-handler surface; only the convenience wrapper surface is small.
- Use four-byte big-endian JSON framing and a 16 MiB declared-frame cap.
- Oversized server responses return an upstream-shaped `response_too_large` error instead of silently dropping the connection.
- Permit exactly one in-flight client command; keep its pending fields directly on `E2EClient`.
- `E2EClient` and `E2EProcess` must be parented in the SceneTree before asynchronous work.
- Name the client state method `is_session_open()`, not `is_connected()`.
- Use `OS.execute_with_pipe(..., false)` and never live-read child stdout/stderr.
- Use GdUnit `create_temp_dir()` for port-file directories and `await_millis()` for startup/grace waits.
- Use real OS-assigned ephemeral ports via `TCPServer.listen(0, "127.0.0.1")` + `get_local_port()`.
- Client wait deadlines add `WAIT_MARGIN_SECONDS = 1.0` beyond server waits.
- Each test owns its child in the MVP; no suite-level process reuse.
- `GdUnitE2ETestSuite.after_test()` captures artifacts when `is_failure()` then closes/frees all tracked processes.
- Adapted child server self-terminates two seconds after losing an authenticated peer unless another peer authenticates.
- Invalid E2E startup flags fail closed and never listen.
- Validate Linux and Windows CI; macOS and Godot .NET compatibility are follow-ups.
- Keep GdUnit4 external and out of release archives.
- Preserve Apache-2.0 attribution for adapted upstream files.
- Do not add locators, retrying expectations, process pools, video/trace UX, editor panels, or a second test runner.
- Follow RED → GREEN → REFACTOR for each task.

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
│   │   ├── e2e_client.gd
│   │   ├── e2e_launch_options.gd
│   │   ├── e2e_process.gd
│   │   └── gdunit_e2e_game.gd
│   └── gdunit/
│       └── gdunit_e2e_test_suite.gd
├── scripts/
│   ├── bootstrap_gdunit4.sh
│   └── package_release.sh
└── tests/
    ├── helpers/fake_e2e_server.gd
    ├── fixtures/minimal/
    │   ├── main.tscn
    │   └── main.gd
    ├── unit/
    └── integration/
```

---

### Task 1: Establish the runnable addon and one GdUnit bootstrap path

**Files:**
- Create: `.gitignore`
- Create: `project.godot`
- Modify: `README.md`
- Create: `LICENSE`
- Create: `NOTICE`
- Create: `addons/gdunit_e2e/plugin.cfg`
- Create: `addons/gdunit_e2e/plugin.gd`
- Create: `scripts/bootstrap_gdunit4.sh`
- Create: `tests/unit/plugin_registration_test.gd`

**Interfaces:**
- Produces addon path `res://addons/gdunit_e2e`.
- Produces autoload name `GdUnitE2EAutomationServer` -> `res://addons/gdunit_e2e/server/automation_server.gd`.
- Produces one pinned GdUnit4 bootstrap script used by Linux and Windows CI.

- [ ] **Step 1: Add root project metadata and generated-file ignores**

Use a small GL-compatibility test project. Root `project.godot` must contain the autoload entry used by this repository's own integration tests so a child launched without opening the editor still loads the server script once Task 3 creates it.

Ignore:

```gitignore
.godot/
addons/gdUnit4/
reports/
test_output/
dist/
*.tmp
```

Do not add a global `*.port` dependency; port files live under GdUnit's temp directory.

- [ ] **Step 2: Add Apache-2.0 licensing and immutable upstream attribution**

`NOTICE` contains:

```text
godot-e2e (this repository)

Contains code adapted from RandallLiuXin/godot-e2e,
Copyright 2026 LIU MINGJUN (RandallLiuXin),
licensed under the Apache License 2.0.
Reference commit: ae6219f6e758a0f29bd243c8f963417fe4d63c36
```

- [ ] **Step 3: Add the single GdUnit4 bootstrap script**

Keep one version constant:

```bash
GDUNIT_VERSION="6.2.1"
```

Behavior:

```text
if addons/gdUnit4 exists: exit 0
→ download the pinned release archive
→ on MINGW/MSYS use powershell.exe Expand-Archive
→ otherwise use unzip
→ copy only addons/gdUnit4 into the project
→ delete temporary archive/extraction directory
```

GitHub Actions must invoke the same script with `shell: bash` on Windows and Linux.

- [ ] **Step 4: Write the plugin registration RED test**

```gdscript
extends GdUnitTestSuite

func test_plugin_points_at_expected_script() -> void:
    var cfg := ConfigFile.new()
    assert_int(cfg.load("res://addons/gdunit_e2e/plugin.cfg")).is_equal(OK)
    assert_str(cfg.get_value("plugin", "script")).is_equal("plugin.gd")

func test_root_test_project_registers_runtime_autoload() -> void:
    assert_str(ProjectSettings.get_setting("autoload/GdUnitE2EAutomationServer", "")).contains(
        "res://addons/gdunit_e2e/server/automation_server.gd"
    )
```

Do not assert the release version string; that is metadata, not behavior.

- [ ] **Step 5: Run RED**

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit/plugin_registration_test.gd
```

Expected: FAIL until plugin/root project registration exists.

- [ ] **Step 6: Add minimal `plugin.cfg` / `plugin.gd` and make registration pass**

`plugin.gd` only registers/unregisters the `GdUnitE2EAutomationServer` autoload. No dock/settings UI.

- [ ] **Step 7: Run GREEN and commit**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/plugin_registration_test.gd
git add .gitignore project.godot README.md LICENSE NOTICE addons/gdunit_e2e/plugin.cfg addons/gdunit_e2e/plugin.gd scripts/bootstrap_gdunit4.sh tests/unit/plugin_registration_test.gd
git commit -m "chore: establish gdunit e2e addon baseline"
```

Expected: PASS.

---

### Task 2: Add shared framing and upstream Variant serialization

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
const ORPHAN_GRACE_SECONDS := 2.0

class_name E2EFraming
static func encode_json(message: Dictionary) -> PackedByteArray
static func try_extract(buffer: PackedByteArray) -> Dictionary
# {complete: bool, message: Dictionary, remaining: PackedByteArray, error: String}

class_name E2ESerializer
static func serialize(value: Variant) -> Variant
static func deserialize(value: Variant) -> Variant
```

- [ ] **Step 1: Write framing RED tests**

Cover:

```text
4-byte unsigned BE header
UTF-8 round-trip
partial header
partial body without consumption
two concatenated frames
MAX_FRAME_BYTES exact boundary
declared length MAX_FRAME_BYTES + 1 -> frame_too_large before body allocation
```

- [ ] **Step 2: Run RED**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/protocol_test.gd
```

Expected: FAIL because protocol classes do not exist.

- [ ] **Step 3: Implement the smallest framing parser**

`try_extract()` reads the four-byte declared length first. If it exceeds `MAX_FRAME_BYTES`, return an error immediately; do not wait for or resize to the declared body.

- [ ] **Step 4: Write serializer RED tests against pinned upstream tags**

Cover primitives plus:

```text
Vector2 -> {_t:"v2",x,y}
Vector2i -> v2i
Vector3 -> v3
Vector3i -> v3i
Rect2 -> r2
Rect2i -> r2i
Color -> col
Transform2D -> t2d
NodePath -> np
Array / Dictionary recursive values
PackedVector2Array
PackedFloat32Array
PackedInt32Array
PackedStringArray
unknown -> _unknown diagnostic dictionary
```

- [ ] **Step 5: Adapt pinned `json_serializer.gd` behavior into `E2ESerializer`**

Do not rename tags or invent `__godot_type`.

- [ ] **Step 6: Run GREEN and commit**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/protocol_test.gd -a tests/unit/serializer_test.gd
git add addons/gdunit_e2e/protocol tests/unit/protocol_test.gd tests/unit/serializer_test.gd
git commit -m "feat: add e2e protocol primitives"
```

Expected: PASS.

---

### Task 3: Adapt the pinned child server with minimal behavioral differences

**Files:**
- Create: `addons/gdunit_e2e/server/config.gd`
- Create: `addons/gdunit_e2e/server/log_capture.gd`
- Create: `addons/gdunit_e2e/server/command_handler.gd`
- Create: `addons/gdunit_e2e/server/automation_server.gd`
- Modify: `addons/gdunit_e2e/plugin.gd`
- Create: `tests/unit/config_test.gd`
- Create: `tests/unit/command_handler_test.gd`

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

Server user flags:

```text
--gdunit-e2e
--gdunit-e2e-port=<0..65535>
--gdunit-e2e-port-file=<path>
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=<error|warning|info>
```

- [ ] **Step 1: Write strict config RED tests**

Pin valid parsing and reject without fallback:

```text
port=abc
port=70000
port=0 without port-file
verbosity=verbose
```

For invalid config, `is_enabled()` may be true but `is_valid()` is false and `get_validation_error()` is non-empty.

- [ ] **Step 2: Adapt upstream config with renamed flags and fail-closed startup contract**

`automation_server._ready()` will later stop processing/listening when config is invalid and emit `push_error()`.

- [ ] **Step 3: Write command-handler characterization only for the wrapped MVP surface**

Pin representative exact behavior for:

```text
node_exists
get_property / set_property / call_method
get_tree / get_scene
input_key / input_action / input_mouse_button / click_node
wait_process_frames / wait_physics_frames / wait_seconds
wait_for_node / wait_for_signal / wait_for_property
change_scene / reload_scene
screenshot
quit
```

Use real in-process test nodes where needed. Pin exact upstream shapes such as:

```gdscript
{"id": 1, "exists": true}
{"id": 2, "error": "Node not found: /root/Missing"}
{"id": 3, "result": {"_t": "v2", "x": 1.0, "y": 2.0}}
```

Do **not** add exhaustive new tests for retained but unwrapped commands such as `find_nodes`, `batch`, `node_actionable`, `hover_node`, or `input_mouse_motion`.

- [ ] **Step 4: Adapt the full pinned command handler and log capture**

Keep the inherited command surface intact. Change only references/names needed by this addon. Keep `_logs` / `_logs_dropped`; do not add flood detection.

- [ ] **Step 5: Adapt `automation_server.gd`**

Required deltas from upstream:

```text
GdUnitE2E names and renamed flags
strict invalid-config refusal
listen only on 127.0.0.1
port 0 -> TCPServer.listen(0, "127.0.0.1") + get_local_port()
shared E2EFraming/E2EProtocol
16 MiB receive cap
oversized outgoing command response -> upstream-shaped response_too_large error
authenticated-peer orphan watchdog using ORPHAN_GRACE_SECONDS
```

Keep token-first hello behavior. Client hello keeps `protocol_version: 1`; server does not add version validation absent from the pinned implementation.

- [ ] **Step 6: Implement orphan watchdog state**

Track:

```gdscript
var _ever_authenticated := false
var _orphan_deadline_ms := 0
```

On successful hello:

```gdscript
_ever_authenticated = true
_orphan_deadline_ms = 0
```

When an authenticated session disconnects without an intentional child quit:

```gdscript
_orphan_deadline_ms = Time.get_ticks_msec() + int(E2EProtocol.ORPHAN_GRACE_SECONDS * 1000.0)
```

While listening, if the deadline expires and no peer has re-authenticated:

```gdscript
get_tree().quit()
```

- [ ] **Step 7: Run server unit slice and commit**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/config_test.gd -a tests/unit/command_handler_test.gd
git add addons/gdunit_e2e/server addons/gdunit_e2e/plugin.gd tests/unit/config_test.gd tests/unit/command_handler_test.gd
git commit -m "feat: adapt upstream child automation server"
```

Expected: PASS. Child-launch integration waits until Task 5, where a launcher exists.

---

### Task 4: Implement the in-tree non-blocking GDScript client

**Files:**
- Create: `addons/gdunit_e2e/client/e2e_result.gd`
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
func is_session_open() -> bool
func reset_collected_logs() -> void
func get_collected_logs() -> Array
```

Pending request state is directly on `E2EClient`:

```gdscript
var _pending_id: int = 0
var _pending_deadline_ms: int = 0
var _pending_action: String = ""
```

There is no `E2EPendingRequest` class/file.

- [ ] **Step 1: Build an in-tree deterministic fake server**

The helper extends `Node`, listens on loopback, uses `E2EFraming`, and can queue exact response dictionaries. Client tests add fake server and client under the test suite before awaiting.

- [ ] **Step 2: Write client RED tests**

Cover:

```text
hello includes token + protocol_version=1
monotonic request IDs
command-specific success dictionaries
_t deserialization
partial TCP reads
error-only response -> failed E2EResult
{error,message} -> readable failed E2EResult
client timeout
connection loss
_logs/_logs_dropped accumulation
second command rejected while one is in flight
oversized inbound declared response closes/fails
close() idempotent
is_session_open() state
client receives _process() only when parented
```

- [ ] **Step 3: Run RED**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/client_test.gd
```

Expected: FAIL until client exists.

- [ ] **Step 4: Implement `_process()` polling without busy waits**

```gdscript
func _process(_delta: float) -> void:
    if _peer == null:
        return
    _peer.poll()
    _read_available_bytes()
    _extract_complete_frames()
    _expire_pending_request_if_needed()
```

Never loop waiting for future bytes.

- [ ] **Step 5: Implement upstream-shaped result/error conversion**

```gdscript
if response.has("error"):
    var server_error := str(response["error"])
    var detail := str(response.get("message", server_error))
    var rendered := detail if detail == server_error else "%s — %s" % [server_error, detail]
    return E2EResult.failure(rendered, logs)
```

No framework error enum.

- [ ] **Step 6: Run GREEN and commit**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/client_test.gd
git add addons/gdunit_e2e/client/e2e_result.gd addons/gdunit_e2e/client/e2e_client.gd tests/helpers/fake_e2e_server.gd tests/unit/client_test.gd
git commit -m "feat: add async gdscript e2e client"
```

Expected: PASS.

---

### Task 5: Add child launch, real server integration, and bounded cleanup

**Files:**
- Create: `addons/gdunit_e2e/client/e2e_launch_options.gd`
- Create: `addons/gdunit_e2e/client/e2e_process.gd`
- Create: `tests/fixtures/minimal/main.tscn`
- Create: `tests/fixtures/minimal/main.gd`
- Create: `tests/unit/launch_options_test.gd`
- Create: `tests/integration/process_lifecycle_test.gd`
- Create: `tests/integration/server_startup_test.gd`

**Interfaces:**

```gdscript
class_name E2ELaunchOptions
extends RefCounted
var project_path: String
var scene_path := "res://tests/fixtures/minimal/main.tscn"
var godot_path: String
var timeout_seconds := 10.0
var extra_godot_args: PackedStringArray
var log_verbosity := "warning"

class_name E2EProcess
extends Node

func _init(suite: GdUnitTestSuite) -> void
func launch(options: E2ELaunchOptions) -> E2EResult
func close() -> void
func is_running() -> bool
func get_client() -> E2EClient
func get_stdout() -> String
func get_stderr() -> String
func get_exit_code() -> int
```

`E2EProcess` stores the owning suite only to reuse public `create_temp_dir()` and `await_millis()` helpers.

- [ ] **Step 1: Write launch-option RED tests**

Pin command construction:

```text
<godot>
--path <repo/project>
--scene res://tests/fixtures/minimal/main.tscn
<explicit extra Godot args>
--
--gdunit-e2e
--gdunit-e2e-port=0
--gdunit-e2e-port-file=<gdunit temp dir>/port_<token>.txt
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=warning
```

Assert GdUnit runner arguments are never forwarded.

- [ ] **Step 2: Create the fixture scene inside the root project**

No nested `project.godot` and no addon copy.

`main.gd`:

```gdscript
extends Node2D

@onready var status: Label = $Status
@onready var click_status: Label = $ClickStatus
var action_count := 0

func _ready() -> void:
    $Button.pressed.connect(func(): click_status.text = "clicked")

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("ui_accept"):
        action_count += 1
        status.text = "accepted:%d" % action_count
```

- [ ] **Step 3: Write process lifecycle RED tests**

Verify:

```text
E2EProcess must be in SceneTree before launch
execute_with_pipe uses blocking=false
port path is under suite.create_temp_dir(...)
client is child of E2EProcess before connect
no live stdout/stderr reads while PID is running
graceful close reaps PID
forced close kills unhealthy PID
OS.is_process_running(pid) is false after close
post-death pipe drain terminates at EOF/error/byte-time bound
close() twice is safe
```

- [ ] **Step 4: Implement launch with GdUnit waits**

Use:

```gdscript
var process_info := OS.execute_with_pipe(executable, args, false)
```

Startup polling uses:

```gdscript
await _suite.await_millis(25)
```

between process-status/port-file checks. Do not use `create_timer()` and do not read process pipes while alive.

- [ ] **Step 5: Implement bounded shutdown**

Attempt remote `quit`, close TCP, then loop with a short total grace using `_suite.await_millis(25)`. If still alive, `OS.kill(pid)`. Only after `OS.is_process_running(pid)` is false, drain each non-blocking pipe until EOF/error or a documented small bound.

- [ ] **Step 6: Add real server-startup integration tests now that the launcher exists**

Using the root project + fixture scene, verify:

1. `port=0` yields a nonzero actual port;
2. listener is loopback-only;
3. correct-token hello succeeds;
4. wrong token disconnects;
5. non-hello first command disconnects;
6. invalid E2E config creates no listener/port file, launch times out, and parent kills the child;
7. dropping an authenticated client without `quit` makes the child self-exit after `ORPHAN_GRACE_SECONDS`;
8. a replacement authenticated peer during the grace cancels orphan exit.

Use raw `StreamPeerTCP` where handshake behavior itself is under test; do not hand-roll a second child launcher.

- [ ] **Step 7: Run process/server integration on the development OS**

```bash
./addons/gdUnit4/runtest.sh \
  -a tests/unit/launch_options_test.gd \
  -a tests/integration/process_lifecycle_test.gd \
  -a tests/integration/server_startup_test.gd
```

Expected: PASS with no surviving child PID.

- [ ] **Step 8: Commit**

```bash
git add addons/gdunit_e2e/client/e2e_launch_options.gd addons/gdunit_e2e/client/e2e_process.gd tests/fixtures/minimal tests/unit/launch_options_test.gd tests/integration/process_lifecycle_test.gd tests/integration/server_startup_test.gd
git commit -m "feat: manage e2e child process lifecycle"
```

---

### Task 6: Expose the high-level remote-game API and timeout margins

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
func get_scene() -> String

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

func change_scene(scene_path: String) -> bool
func reload_scene() -> bool
func screenshot(save_path := "") -> String
func send_command(action: String, parameters := {}, timeout := E2EProtocol.DEFAULT_COMMAND_TIMEOUT_SECONDS) -> E2EResult
```

The facade receives a live `E2EProcess`/`E2EClient` and owning `GdUnitTestSuite` for public `fail()` / `is_failure()` behavior.

- [ ] **Step 1: Write fake-client RED tests for exact wrapper commands**

Verify each wrapper uses pinned upstream command names/parameters and returns deserialized business values. Do not wrap the whole retained server surface.

- [ ] **Step 2: Pin timeout-margin behavior**

Unit tests assert:

```gdscript
await game.wait_for_node(path, 5.0)      # client timeout 6.0
await game.wait_for_property(..., 2.5)  # client timeout 3.5
await game.wait_for_signal(..., 1.0)    # client timeout 2.0
await game.wait_seconds(3.0)             # client timeout 4.0
```

`change_scene()` / `reload_scene()` use `DEFAULT_COMMAND_TIMEOUT_SECONDS + WAIT_MARGIN_SECONDS`.

- [ ] **Step 3: Implement wrapper failure mapping**

```gdscript
func _fail_remote(action: String, context: String, result: E2EResult) -> void:
    _suite.fail("E2E command %s failed%s: %s" % [
        action,
        " for " + context if not context.is_empty() else "",
        result.message,
    ])
```

Return safe fallbacks after calling `fail()`. Do not assume `fail()` ends the test.

Raw `send_command()` returns `E2EResult` without calling `fail()`.

- [ ] **Step 4: Add real gameplay smoke tests**

```gdscript
func test_action_reaches_separate_game_process() -> void:
    var game := await launch_game()
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

Add a second smoke test for `click_node()` changing `$ClickStatus.text` to `"clicked"`.

- [ ] **Step 5: Add the timeout-race regression**

Use a server wait close to its configured timeout and assert the result is the server's timeout/failure result, not a client transport timeout. The test must fail if the client deadline equals the server duration instead of adding one second.

- [ ] **Step 6: Run GREEN and commit**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/game_api_test.gd -a tests/integration/gameplay_smoke_test.gd
git add addons/gdunit_e2e/client/gdunit_e2e_game.gd tests/unit/game_api_test.gd tests/integration/gameplay_smoke_test.gd
git commit -m "feat: expose gdunit remote game api"
```

Expected: PASS.

---

### Task 7: Make GdUnit lifecycle cleanup and failure artifacts automatic

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
func after_test() -> void
func after() -> void
```

The base suite tracks process/game pairs created during the current test.

**Consumer rule:** if a test suite overrides `after_test()` or `after()`, it must `await super.after_test()` / `await super.after()` so E2E cleanup remains active. Put this prominently in README examples that customize hooks.

- [ ] **Step 1: Write launch-parenting RED tests**

Verify `launch_game()`:

```text
creates E2EProcess.new(self)
add_child(process) before await process.launch()
returns game only after successful launch
on launch failure calls fail(message), closes/frees process, returns null
tracks the process for current-test cleanup
```

- [ ] **Step 2: Implement test-owned launch tracking**

MVP does not retain a child across test cases. `before_test()` starts with an empty tracking collection.

Consumer pattern:

```gdscript
var game := await launch_game()
if is_failure():
    return
```

- [ ] **Step 3: Write automatic failure-artifact RED tests**

With a fake reachable game/process, set GdUnit failure state through a failing assertion in a characterization harness, invoke the base `after_test()`, and verify ordering:

```text
is_failure checked
screenshot/tree/log capture attempted
process close/reap
stdout/stderr finalized
Node removed/freed
```

Do not require consumers to call `capture_failure_artifacts()` manually.

- [ ] **Step 4: Implement `after_test()` cleanup**

For each tracked game/process:

```gdscript
if is_failure():
    await capture_failure_artifacts(game)
await _close_and_finalize(game)
```

Artifact capture is independent per file; errors never replace the primary test failure.

- [ ] **Step 5: Implement `after()` as final safety cleanup**

Close any process still tracked because test-hook cleanup itself failed. Do not add another process-lifetime mode.

- [ ] **Step 6: Implement artifact files**

Before child death, when reachable:

```text
test_output/<suite>/<test>/screenshot.png
test_output/<suite>/<test>/scene_tree.json
test_output/<suite>/<test>/engine_logs.json
```

After `E2EProcess.close()` has reaped and drained pipes:

```text
test_output/<suite>/<test>/stdout.log
test_output/<suite>/<test>/stderr.log
```

- [ ] **Step 7: Add a green negative-path artifact integration test**

```gdscript
func test_raw_failure_can_be_captured_without_failing_outer_test() -> void:
    var game := await launch_game()
    if is_failure():
        return

    var result := await game.send_command("get_property", {
        "path": "/root/Main/Missing",
        "property": "health",
    })
    assert_bool(result.ok).is_false()

    await capture_failure_artifacts(game)
    assert_file("test_output/.../scene_tree.json").exists()
```

This tests the manual escape hatch without nesting an intentionally failing GdUnit run.

- [ ] **Step 8: Add a real automatic-failure characterization**

Use a small harness suite launched by the GdUnit CLI whose test assertion fails after a child is running. The harness result is expected to fail, but the outer integration check asserts that the corresponding `test_output` artifacts exist and no child remains. This specifically proves the production `after_test()` path rather than only the manual helper.

- [ ] **Step 9: Run lifecycle/artifact tests**

```bash
./addons/gdUnit4/runtest.sh \
  -a tests/unit/gdunit_suite_test.gd \
  -a tests/integration/failure_artifact_test.gd
```

Expected: outer characterization suite PASS; its deliberately failing child/harness run is asserted as data, not treated as the outer test result.

- [ ] **Step 10: Commit**

```bash
git add addons/gdunit_e2e/gdunit tests/unit/gdunit_suite_test.gd tests/integration/failure_artifact_test.gd
git commit -m "feat: automate gdunit e2e cleanup diagnostics"
```

---

### Task 8: Add Linux/Windows CI, packaging, docs, and risk verification

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `scripts/package_release.sh`
- Modify: `README.md`
- Modify: `NOTICE` if adapted-file attribution changes
- Verify: complete suite and release archive

**Interfaces:**
- Linux and Windows CI exercise real child processes.
- Release archive: `dist/godot-e2e-0.1.0.zip`.

- [ ] **Step 1: Add Linux CI**

```text
checkout
→ install one pinned Godot 4.5+ build
→ shell:bash ./scripts/bootstrap_gdunit4.sh
→ start Xvfb / set DISPLAY
→ run full GdUnit suite
→ upload reports/test_output on failure
```

- [ ] **Step 2: Add Windows CI using the same bootstrap script**

```text
checkout
→ install the same Godot version family
→ shell:bash ./scripts/bootstrap_gdunit4.sh
→ run full GdUnit suite
→ upload reports/test_output on failure
```

Do not add a second PowerShell bootstrap script. No macOS/version matrix in this PR.

- [ ] **Step 3: Pin the process-risk assertions in CI-visible integration tests**

Both OS jobs must execute assertions that prove:

```text
graceful quit reaches OS.is_process_running(pid) == false
forced kill reaches OS.is_process_running(pid) == false
post-death stdout drain terminates
post-death stderr drain terminates
authenticated-peer disconnect watchdog exits the child
```

These are required test cases, not manual checks.

- [ ] **Step 4: Add release packaging script**

Package only:

```text
addons/gdunit_e2e/**
README.md
LICENSE
NOTICE
```

Explicitly reject archive entries under:

```text
addons/gdUnit4/
tests/
reports/
test_output/
```

- [ ] **Step 5: Replace planning README with user-facing documentation**

README includes:

1. what process isolation adds beyond GdUnit scene tests;
2. Godot/GdUnit prerequisites;
3. addon installation and plugin enablement;
4. minimal test with `if is_failure(): return` after dependent remote calls;
5. note that overriding `after_test()` / `after()` requires calling `super`;
6. wrapped API table and raw `send_command()` escape hatch;
7. automatic failure artifacts;
8. orphan-child watchdog behavior;
9. same-project child/autoload behavior;
10. CI notes;
11. Apache-2.0 upstream attribution;
12. deferred features.

Minimal example:

```gdscript
extends GdUnitE2ETestSuite

func test_game_accepts_input() -> void:
    var game := await launch_game()
    if is_failure():
        return

    await game.press_action("ui_accept")
    if is_failure():
        return

    assert_int(await game.get_property("/root/Main", "action_count")).is_equal(1)
```

- [ ] **Step 6: Run complete local verification**

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests -c
./scripts/package_release.sh
unzip -l dist/godot-e2e-0.1.0.zip
```

Verify:

```text
zero unexpected outer-suite failures
no surviving child processes from completed integration tests
automatic failure-artifact characterization produced artifacts
no test-created port path escapes GdUnit temp storage
release contains no GdUnit4 or tests
```

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/ci.yml README.md NOTICE scripts/package_release.sh
git commit -m "ci: validate and package gdunit e2e addon"
```

---

## Final PR Verification

Before marking the single MVP PR ready for review:

- [ ] Re-read `docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md`; map every acceptance criterion to a test or explicit package inspection.
- [ ] Run the complete GdUnit suite from a clean checkout after bootstrapping GdUnit4.
- [ ] Confirm Linux CI passes.
- [ ] Confirm Windows CI passes.
- [ ] Confirm the abnormal-disconnect watchdog integration test leaves no child.
- [ ] Confirm an actual GdUnit assertion failure automatically creates available failure artifacts before process teardown.
- [ ] Confirm graceful and forced process cleanup both end with `OS.is_process_running(pid) == false` on Linux and Windows.
- [ ] Confirm non-blocking stdout/stderr drains terminate on both CI operating systems.
- [ ] Inspect release ZIP and confirm it contains only addon + README/LICENSE/NOTICE.
- [ ] Search production addon code for Python imports, pytest, locators, process pools, editor panels, and other deferred features; none should exist.
- [ ] Search adapted upstream files for Apache-2.0 attribution and modification notices.
- [ ] Confirm the implementation remains one feature PR with task-level commits.

## Follow-ups after 0.1.0

Do not pull these into the MVP unless a failing core test proves they are required:

1. Playwright-like locators.
2. Retrying `expect()` assertions.
3. Engine-error-flood detection.
4. Dedicated Godot .NET/C# target fixture.
5. macOS CI.
6. Suite-level process reuse, pools, or parallel sessions.
7. richer trace/diagnostic/editor UX.