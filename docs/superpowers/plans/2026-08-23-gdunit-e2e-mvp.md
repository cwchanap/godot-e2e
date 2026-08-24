# GdUnit E2E MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `0.1.0` of a standalone Godot addon that lets GdUnit4 GDScript tests launch/control a separate Godot process, automatically capture diagnostics on failed tests, and avoid leaked children when the parent exits abnormally.

**Architecture:** GdUnit4 remains the only runner/assertion/lifecycle/reporting layer. The addon adapts the pinned Apache-2.0 `godot-e2e` GDScript server, preserves its wire/command behavior, adds a non-blocking in-tree GDScript client and child-process Node, and exposes a small `GdUnitE2EGame` facade. Each MVP test owns its child; `after_test()` captures artifacts when `is_failure()` and reaps all tracked children, with a child-side authenticated-peer watchdog as the abnormal-parent safety net.

**Tech Stack:** Godot 4.5+, GDScript, GdUnit4 6.x, localhost TCP, four-byte big-endian length-prefixed JSON, GitHub Actions, Xvfb on Linux.

**Spec:** `docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md`

## Global Constraints

- One feature PR with task-level commits.
- Godot 4.5+; GdUnit4 6.x pinned once in `scripts/bootstrap_gdunit4.sh`.
- GDScript runtime only; Python/pytest are not runtime dependencies.
- Bind `127.0.0.1` only; activate only with `--gdunit-e2e`.
- Pinned upstream baseline: `RandallLiuXin/godot-e2e@ae6219f6e758a0f29bd243c8f963417fe4d63c36`.
- Preserve upstream command-specific responses and `_t` serializer tags.
- Keep the full pinned handler implementation; only wrap the MVP subset.
- Four-byte BE JSON framing; reject declared frames above 16 MiB before allocation.
- Oversized server responses return `{error:"response_too_large", message:...}`.
- Exactly one in-flight command; pending fields live directly on `E2EClient`.
- `E2EClient`/`E2EProcess` must be in the SceneTree before async work.
- Client state method is `is_session_open()`, not `is_connected()`.
- `OS.execute_with_pipe(..., false)` only; never live-read child pipes.
- Use GdUnit `create_temp_dir()` for port-file location and `await_millis()` for polling/grace waits.
- Port `0` means `TCPServer.listen(0, "127.0.0.1")` then `get_local_port()`.
- Server wait wrappers add `WAIT_MARGIN_SECONDS = 1.0` to the client deadline.
- One child lifetime per test; suite-level process reuse is deferred.
- `after_test()` captures artifacts on failure, then closes/frees tracked children.
- Authenticated-peer loss starts a two-second child orphan watchdog.
- Invalid E2E flags fail closed and do not listen.
- Linux + Windows CI are MVP scope; macOS/.NET are deferred.
- GdUnit4 is external and excluded from release artifacts.
- Preserve Apache-2.0 attribution on adapted files.
- No locators, retrying expectations, pools, editor UX, video, or a second runner.
- RED → GREEN → REFACTOR for every task.

## Planned File Structure

```text
.
├── .github/workflows/ci.yml
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
│   └── gdunit/gdunit_e2e_test_suite.gd
├── tests/
│   ├── helpers/fake_e2e_server.gd
│   ├── fixtures/minimal/main.tscn
│   ├── fixtures/minimal/main.gd
│   ├── fixtures/failure_harness_test.gd
│   ├── unit/
│   └── integration/
├── scripts/bootstrap_gdunit4.sh
├── scripts/package_release.sh
├── README.md
├── LICENSE
└── NOTICE
```

There is no nested fixture `project.godot`, no copied addon, no `E2EPendingRequest`, and no second bootstrap script.

---

### Task 1: Runnable addon baseline and one GdUnit bootstrap

**Files:** create `.gitignore`, `project.godot`, `LICENSE`, `NOTICE`, `addons/gdunit_e2e/plugin.cfg`, `addons/gdunit_e2e/plugin.gd`, `scripts/bootstrap_gdunit4.sh`, `tests/unit/plugin_registration_test.gd`; modify `README.md`.

**Produces:** registered `GdUnitE2EAutomationServer` autoload and one cross-OS GdUnit bootstrap path.

- [ ] **Step 1: Add project metadata and ignores**

Root `project.godot` uses GL compatibility and includes the test repository's autoload entry:

```ini
[autoload]
GdUnitE2EAutomationServer="*res://addons/gdunit_e2e/server/automation_server.gd"
```

Ignore:

```gitignore
.godot/
addons/gdUnit4/
reports/
test_output/
dist/
*.tmp
```

- [ ] **Step 2: Add Apache-2.0 + NOTICE**

`NOTICE` names the upstream repository, copyright holder, Apache-2.0, and pinned commit.

- [ ] **Step 3: Add one bootstrap script**

Pin once:

```bash
GDUNIT_VERSION="6.2.1"
```

Script behavior:

```text
already installed -> exit 0
otherwise download release zip
MINGW/MSYS -> powershell.exe Expand-Archive
other hosts -> unzip
copy addons/gdUnit4 only
clean temporary files
```

- [ ] **Step 4: Write RED registration tests**

```gdscript
extends GdUnitTestSuite

func test_plugin_script_entrypoint() -> void:
    var cfg := ConfigFile.new()
    assert_int(cfg.load("res://addons/gdunit_e2e/plugin.cfg")).is_equal(OK)
    assert_str(cfg.get_value("plugin", "script")).is_equal("plugin.gd")

func test_root_project_has_runtime_autoload() -> void:
    assert_str(ProjectSettings.get_setting("autoload/GdUnitE2EAutomationServer", "")).contains(
        "res://addons/gdunit_e2e/server/automation_server.gd"
    )
```

Do not assert plugin version metadata.

- [ ] **Step 5: Run RED, implement minimal plugin, run GREEN**

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit/plugin_registration_test.gd
```

Expected before implementation: FAIL. Expected after `plugin.cfg`/`plugin.gd`: PASS.

- [ ] **Step 6: Commit**

```bash
git add .gitignore project.godot README.md LICENSE NOTICE addons/gdunit_e2e/plugin.cfg addons/gdunit_e2e/plugin.gd scripts/bootstrap_gdunit4.sh tests/unit/plugin_registration_test.gd
git commit -m "chore: establish gdunit e2e addon baseline"
```

---

### Task 2: Shared framing and upstream Variant serialization

**Files:** create `addons/gdunit_e2e/protocol/e2e_protocol.gd`, `e2e_framing.gd`, `e2e_serializer.gd`, `tests/unit/protocol_test.gd`, `tests/unit/serializer_test.gd`.

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

class_name E2ESerializer
static func serialize(value: Variant) -> Variant
static func deserialize(value: Variant) -> Variant
```

- [ ] **Step 1: RED framing tests**

Cover BE header, UTF-8, partial header/body, two concatenated frames, exact 16 MiB boundary, and `MAX_FRAME_BYTES + 1` rejection before body allocation.

- [ ] **Step 2: Implement minimal framing parser**

`try_extract()` inspects declared length before any body-size allocation/wait.

- [ ] **Step 3: RED serializer tests against exact upstream tags**

Cover primitives plus `v2`, `v2i`, `v3`, `v3i`, `r2`, `r2i`, `col`, `t2d`, `np`, arrays/dictionaries, supported packed arrays, and `_unknown`.

- [ ] **Step 4: Adapt pinned serializer behavior**

No `__godot_type` or renamed tags.

- [ ] **Step 5: Run + commit**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/protocol_test.gd -a tests/unit/serializer_test.gd
git add addons/gdunit_e2e/protocol tests/unit/protocol_test.gd tests/unit/serializer_test.gd
git commit -m "feat: add e2e protocol primitives"
```

Expected: PASS.

---

### Task 3: Adapt the child server without shrinking inherited functionality

**Files:** create `addons/gdunit_e2e/server/config.gd`, `log_capture.gd`, `command_handler.gd`, `automation_server.gd`, `tests/unit/config_test.gd`, `tests/unit/command_handler_test.gd`; modify `plugin.gd`.

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

- [ ] **Step 1: RED strict-config tests**

Reject without fallback:

```text
--gdunit-e2e-port=abc
--gdunit-e2e-port=70000
--gdunit-e2e-port=0 without port-file
--gdunit-e2e-log-verbosity=verbose
```

- [ ] **Step 2: Adapt config with renamed flags and fail-closed state**

Invalid enabled config produces a readable validation error; server startup checks it before listen.

- [ ] **Step 3: RED command-handler characterization for the wrapped surface only**

Cover representative exact responses for node/property/method/tree, input/click, waits, scene change/reload, screenshot, and quit. Pin examples like:

```gdscript
{"id": 1, "exists": true}
{"id": 2, "error": "Node not found: /root/Missing"}
{"id": 3, "result": {"_t": "v2", "x": 1.0, "y": 2.0}}
```

Do not create new exhaustive tests for unwrapped inherited commands (`find_nodes`, `batch`, `node_actionable`, `hover_node`, etc.).

- [ ] **Step 4: Adapt full pinned handler/log capture**

Keep inherited commands and `_logs`/`_logs_dropped`. No flood detector.

- [ ] **Step 5: Adapt automation server deltas**

Implement only:

```text
GdUnitE2E naming/flags
invalid config refuses to listen
loopback bind
port 0 -> listen(0,"127.0.0.1") + get_local_port()
shared framing/constants
16 MiB inbound declaration guard
oversized response -> compact response_too_large error
orphan watchdog
```

Keep upstream token-first hello and do not add protocol-version validation.

- [ ] **Step 6: Add watchdog state**

```gdscript
var _ever_authenticated := false
var _orphan_deadline_ms := 0
```

Successful hello clears deadline. Authenticated disconnect sets deadline to `now + 2000ms`. Re-authentication clears it. Listening past deadline calls `get_tree().quit()`.

- [ ] **Step 7: Run + commit**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/config_test.gd -a tests/unit/command_handler_test.gd
git add addons/gdunit_e2e/server addons/gdunit_e2e/plugin.gd tests/unit/config_test.gd tests/unit/command_handler_test.gd
git commit -m "feat: adapt upstream child automation server"
```

Expected: PASS. No child-launch integration yet; Task 5 owns it.

---

### Task 4: Non-blocking in-tree GDScript client

**Files:** create `addons/gdunit_e2e/client/e2e_result.gd`, `e2e_client.gd`, `tests/helpers/fake_e2e_server.gd`, `tests/unit/client_test.gd`.

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

Direct pending state:

```gdscript
var _pending_id: int = 0
var _pending_deadline_ms: int = 0
var _pending_action: String = ""
```

- [ ] **Step 1: Build fake in-tree server**

It uses `E2EFraming`, listens on loopback, and can queue exact dictionaries/partial writes.

- [ ] **Step 2: RED client tests**

Cover hello token+protocol field, monotonic IDs, command-specific success, `_t` deserialization, partial reads, error-only and `{error,message}`, timeout, disconnect, log deltas, one-in-flight rejection, oversized response declaration, idempotent close, `is_session_open()`, and SceneTree parenting.

- [ ] **Step 3: Implement `_process()` polling**

```gdscript
func _process(_delta: float) -> void:
    if _peer == null:
        return
    _peer.poll()
    _read_available_bytes()
    _extract_complete_frames()
    _expire_pending_request_if_needed()
```

Never busy-wait.

- [ ] **Step 4: Implement exact error rendering**

Presence of `error` means failed `E2EResult`; combine `error`+`message` readably without adding an enum.

- [ ] **Step 5: Run + commit**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/client_test.gd
git add addons/gdunit_e2e/client/e2e_result.gd addons/gdunit_e2e/client/e2e_client.gd tests/helpers/fake_e2e_server.gd tests/unit/client_test.gd
git commit -m "feat: add async gdscript e2e client"
```

Expected: PASS.

---

### Task 5: Child launch, real server integration, and bounded teardown

**Files:** create `addons/gdunit_e2e/client/e2e_launch_options.gd`, `e2e_process.gd`, `tests/fixtures/minimal/main.tscn`, `main.gd`, `tests/unit/launch_options_test.gd`, `tests/integration/process_lifecycle_test.gd`, `server_startup_test.gd`.

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

- [ ] **Step 1: RED argv tests**

Pin:

```text
<godot> --path <repo> --scene res://tests/fixtures/minimal/main.tscn <extra engine args> --
--gdunit-e2e --gdunit-e2e-port=0 --gdunit-e2e-port-file=<GdUnit temp>/port_<token>.txt
--gdunit-e2e-token=<token> --gdunit-e2e-log-verbosity=warning
```

No GdUnit CLI args after `--`.

- [ ] **Step 2: Add fixture scene in the root project**

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

- [ ] **Step 3: RED process tests**

Verify in-tree requirement, `execute_with_pipe(..., false)`, temp path under `create_temp_dir()`, child client parenting, no live pipe reads, graceful reap, forced kill, `OS.is_process_running(pid)==false`, bounded post-death drain, and idempotent close.

- [ ] **Step 4: Implement launch using GdUnit waits**

```gdscript
var process_info := OS.execute_with_pipe(executable, args, false)
```

Poll PID/port file with `await _suite.await_millis(25)`. Do not use live pipe reads.

- [ ] **Step 5: Implement bounded close**

Remote quit → close TCP → bounded `await_millis(25)` loop → `OS.kill(pid)` if needed → confirm dead → bounded non-blocking stdout/stderr drain.

- [ ] **Step 6: Add all child-startup integration now**

Verify real nonzero port from port 0, correct token, wrong token, non-hello first command, invalid-config no-listener + parent kill, authenticated-disconnect watchdog self-exit, and re-authentication within grace cancelling watchdog.

- [ ] **Step 7: Run + commit**

```bash
./addons/gdUnit4/runtest.sh \
  -a tests/unit/launch_options_test.gd \
  -a tests/integration/process_lifecycle_test.gd \
  -a tests/integration/server_startup_test.gd

git add addons/gdunit_e2e/client/e2e_launch_options.gd addons/gdunit_e2e/client/e2e_process.gd tests/fixtures/minimal tests/unit/launch_options_test.gd tests/integration/process_lifecycle_test.gd tests/integration/server_startup_test.gd
git commit -m "feat: manage e2e child process lifecycle"
```

Expected: PASS with no surviving child.

---

### Task 6: High-level remote-game API and deterministic wait deadlines

**Files:** create `addons/gdunit_e2e/client/gdunit_e2e_game.gd`, `tests/unit/game_api_test.gd`, `tests/integration/gameplay_smoke_test.gd`.

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

- [ ] **Step 1: RED wrapper-shape tests**

Verify upstream action/parameter names and deserialized return values only for this wrapper surface.

- [ ] **Step 2: RED timeout-margin tests**

Pin:

```text
wait_for_node(...,5.0)      -> client 6.0
wait_for_property(...,2.5)  -> client 3.5
wait_for_signal(...,1.0)    -> client 2.0
wait_seconds(3.0)           -> client 4.0
change_scene/reload         -> default + 1.0
```

- [ ] **Step 3: Implement failure mapping**

Convenience methods call public `suite.fail(...)` and return a safe fallback; raw `send_command()` does not auto-fail.

Tests/docs use:

```gdscript
var game := await launch_game()
if is_failure():
    return
```

and return again after any remote operation on which later steps depend.

- [ ] **Step 4: Real smoke tests**

Prove `ui_accept` changes remote `action_count` and `click_node()` changes `$ClickStatus.text`.

- [ ] **Step 5: Real timeout-race regression**

Server wait near its own timeout must produce the server timeout result, not a client timeout. The test fails if the +1 second margin is removed.

- [ ] **Step 6: Run + commit**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/game_api_test.gd -a tests/integration/gameplay_smoke_test.gd
git add addons/gdunit_e2e/client/gdunit_e2e_game.gd tests/unit/game_api_test.gd tests/integration/gameplay_smoke_test.gd
git commit -m "feat: expose gdunit remote game api"
```

Expected: PASS.

---

### Task 7: Automatic GdUnit cleanup and failure artifacts

**Files:** create `addons/gdunit_e2e/gdunit/gdunit_e2e_test_suite.gd`, `tests/unit/gdunit_suite_test.gd`, `tests/integration/failure_artifact_test.gd`, `tests/fixtures/failure_harness_test.gd`.

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

Consumer rule: overriding `after_test()` or `after()` requires `await super.after_test()` / `await super.after()`.

- [ ] **Step 1: RED launch-parenting tests**

Verify `E2EProcess.new(self)`, `add_child(process)` before launch, failure -> `fail()` + cleanup + null return, and per-test tracking.

- [ ] **Step 2: Implement per-test ownership**

`before_test()` begins with no tracked children. No process survives intentionally into the next test.

- [ ] **Step 3: RED automatic-after-test ordering with fakes**

Characterize:

```text
is_failure()
-> screenshot/tree/log attempt while reachable
-> close/reap
-> stdout/stderr finalization
-> remove/free process
```

- [ ] **Step 4: Implement `after_test()` and final `after()` safety cleanup**

```gdscript
if is_failure():
    await capture_failure_artifacts(game)
await _close_and_finalize(game)
```

`after()` closes anything unexpectedly left tracked.

- [ ] **Step 5: Implement artifact layout**

Before child death:

```text
test_output/<suite>/<test>/screenshot.png
test_output/<suite>/<test>/scene_tree.json
test_output/<suite>/<test>/engine_logs.json
```

After death/drain:

```text
test_output/<suite>/<test>/stdout.log
test_output/<suite>/<test>/stderr.log
```

Each file is independent/best-effort.

- [ ] **Step 6: Green manual negative-path integration**

Use raw `send_command()` against a missing node, assert `result.ok == false`, call `capture_failure_artifacts()` explicitly, and assert reachable artifacts. This test itself stays green.

- [ ] **Step 7: Add dedicated expected-failure CLI characterization for the real production hook**

`tests/fixtures/failure_harness_test.gd`:

```gdscript
extends GdUnitE2ETestSuite

func test_real_failure_captures_artifacts() -> void:
    var game := await launch_game()
    if is_failure():
        return
    fail("intentional characterization failure")
    return
```

Run it as a separate verification command, **not nested inside another GdUnit test**:

```bash
set +e
./addons/gdUnit4/runtest.sh -a tests/fixtures/failure_harness_test.gd
status=$?
set -e
test "$status" -eq 100
# inspect test_output for expected artifacts and confirm no child remains
```

This proves the real `after_test()` path while keeping the normal test suite green.

- [ ] **Step 8: Run normal lifecycle tests + commit**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/gdunit_suite_test.gd -a tests/integration/failure_artifact_test.gd
git add addons/gdunit_e2e/gdunit tests/unit/gdunit_suite_test.gd tests/integration/failure_artifact_test.gd tests/fixtures/failure_harness_test.gd
git commit -m "feat: automate gdunit e2e cleanup diagnostics"
```

Expected: normal suite PASS; expected-failure harness is verified separately with exit code 100.

---

### Task 8: Linux/Windows CI, packaging, and user docs

**Files:** create `.github/workflows/ci.yml`, `scripts/package_release.sh`; modify `README.md`, `NOTICE` if needed.

- [ ] **Step 1: Linux CI**

```text
checkout -> pinned Godot -> shell:bash bootstrap -> Xvfb -> normal tests
-> expected-failure artifact harness (expect exit 100)
-> upload reports/test_output on failure
```

- [ ] **Step 2: Windows CI with same bootstrap**

```text
checkout -> same Godot family -> shell:bash bootstrap -> normal tests
-> expected-failure artifact harness (expect exit 100)
-> upload reports/test_output on failure
```

No `.ps1` bootstrap, macOS, or version matrix.

- [ ] **Step 3: Make risk assertions mandatory on both OS jobs**

CI executes tests proving graceful kill, forced kill, `OS.is_process_running(pid)==false`, bounded stdout drain, bounded stderr drain, and orphan-watchdog child exit.

- [ ] **Step 4: Package only distributable files**

```text
addons/gdunit_e2e/**
README.md
LICENSE
NOTICE
```

Reject GdUnit4, tests, reports, and `test_output` from the zip.

- [ ] **Step 5: User README**

Document install/enable, minimal test, `if is_failure(): return`, `super.after_test()`/`super.after()` rule, wrapped API, raw command escape hatch, automatic artifacts, orphan watchdog, same-project autoload behavior, CI, attribution, and deferred features.

- [ ] **Step 6: Complete verification**

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests -c
# run expected-failure harness separately and require exit 100
./scripts/package_release.sh
unzip -l dist/godot-e2e-0.1.0.zip
```

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/ci.yml README.md NOTICE scripts/package_release.sh
git commit -m "ci: validate and package gdunit e2e addon"
```

---

## Risks Carried Into Execution

### Risk 1: Windows process termination and non-blocking pipe drain

`OS.kill()`, process-exit visibility, and post-death pipe EOF/error behavior can diverge from Linux. This can produce hangs or zombie children even if the Linux implementation looks correct.

**Required mitigation/test:** Task 5 + Task 8 must run graceful exit, forced kill, `OS.is_process_running(pid)==false`, and bounded stdout/stderr drain assertions on `windows-latest` and Linux.

### Risk 2: Parent interruption before normal cleanup

GdUnit can interrupt a timed-out test body, and the entire parent runner can also be killed before `close_game()` executes.

**Required mitigation/test:** automatic `after_test()` cleanup for normal test failures/timeouts, final `after()` safety cleanup, plus a child-side authenticated-peer orphan watchdog proven with a real disconnect integration test.

---

## Final PR Verification

- [ ] Map every design acceptance criterion to a passing test or explicit package check.
- [ ] Clean checkout → bootstrap → full normal GdUnit suite.
- [ ] Separate failure harness exits `100`, creates available artifacts, and leaves no child.
- [ ] Linux CI passes.
- [ ] Windows CI passes.
- [ ] Graceful and forced child teardown both end with no running PID on both OSes.
- [ ] Post-death pipe drains terminate on both OSes.
- [ ] Authenticated disconnect watchdog leaves no child.
- [ ] No fixture `project.godot`, copied addon, `E2EPendingRequest`, or duplicate bootstrap script exists.
- [ ] Release zip contains only addon + README/LICENSE/NOTICE.
- [ ] Production addon contains no Python/pytest, locator framework, process pool, or editor UX.
- [ ] Adapted upstream files contain Apache-2.0 attribution/modification notices.
- [ ] Implementation remains one PR with task-level commits.

## Follow-ups after 0.1.0

1. Playwright-like locators.
2. Retrying `expect()` assertions.
3. Engine-error-flood detection.
4. Dedicated Godot .NET/C# target fixture.
5. macOS CI.
6. Suite-level process reuse, pools, or parallel sessions.
7. Richer trace/diagnostic/editor UX.