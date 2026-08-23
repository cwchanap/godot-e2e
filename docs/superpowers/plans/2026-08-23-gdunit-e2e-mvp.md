# GdUnit E2E MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build version `0.1.0` of a standalone Godot addon that lets GdUnit4 GDScript tests launch and control a separate Godot game process through a localhost automation protocol.

**Architecture:** GdUnit4 remains the only test runner, assertion library, lifecycle framework, and reporter. The addon adapts the Apache-2.0 `godot-e2e` GDScript server, adds a non-blocking GDScript TCP client and child-process launcher, and exposes a small `GdUnitE2EGame` API plus optional `GdUnitE2ETestSuite` convenience base.

**Tech Stack:** Godot 4.5+, GDScript, GdUnit4 6.x, localhost TCP, four-byte big-endian length-prefixed JSON, GitHub Actions, Xvfb on Linux.

**Spec:** `docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md`

## Global Constraints

- Deliver planning and implementation through one feature PR after this planning branch is promoted; keep task-level commits inside that PR.
- Target Godot 4.5 or newer.
- Use GdUnit4 6.x; development scripts may pin one known-good 6.x release for deterministic CI.
- Product runtime code is GDScript; Python and pytest are not runtime dependencies.
- Bind the child automation server only to `127.0.0.1`.
- Activate the server only with `--gdunit-e2e`.
- Preserve protocol version `1`, useful upstream command names, and four-byte big-endian JSON framing.
- Enforce a 16 MiB frame limit.
- Permit one in-flight command per client in the MVP.
- Use only public GdUnit4 APIs: `GdUnitTestSuite`, lifecycle hooks, `fail()`, `is_failure()`, assertions, and the CLI.
- Keep GdUnit4 external; do not include it in release artifacts.
- Preserve Apache-2.0 attribution for adapted `godot-e2e` files.
- Use upstream commit `ae6219f6e758a0f29bd243c8f963417fe4d63c36` as the immutable adaptation baseline.
- Validate Linux and Windows in CI; macOS and Godot .NET compatibility are follow-ups.
- Do not add locators, retrying expectations, parallel sessions, video, an editor panel, or a new test runner.
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
    │   ├── project.godot
    │   ├── main.tscn
    │   └── main.gd
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
- Produces addon path `res://addons/gdunit_e2e`.
- Produces autoload name `GdUnitE2EAutomationServer` pointing at `res://addons/gdunit_e2e/server/automation_server.gd` once the server exists.
- Produces deterministic local/CI GdUnit4 bootstrap without committing `addons/gdUnit4`.

- [ ] **Step 1: Add repository metadata and ignore generated content**

Use a root `project.godot` with a small 640×360 GL compatibility window and ignore:

```gitignore
.godot/
addons/gdUnit4/
reports/
test_output/
dist/
*.tmp
*.port
```

- [ ] **Step 2: Add Apache-2.0 licensing and upstream NOTICE**

`NOTICE` must identify the adapted upstream project and immutable source commit:

```text
godot-e2e (this repository)

Contains code adapted from RandallLiuXin/godot-e2e,
Copyright 2026 LIU MINGJUN (RandallLiuXin),
licensed under the Apache License 2.0.
Reference commit: ae6219f6e758a0f29bd243c8f963417fe4d63c36
```

- [ ] **Step 3: Add GdUnit4 bootstrap scripts**

Both scripts install only upstream `addons/gdUnit4` into the local project and exit successfully when it is already present. Pin one known-good GdUnit4 6.x tag in both scripts; keep the version in one obvious constant per script.

- [ ] **Step 4: Write the failing addon manifest test**

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

Expected: FAIL because the addon manifest does not yet exist.

- [ ] **Step 5: Add the minimal plugin manifest/editor plugin and rerun**

The editor plugin should only register/unregister the autoload. Do not add docks, settings pages, or other editor UX.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add .gitignore project.godot README.md LICENSE NOTICE addons scripts tests/unit/addon_manifest_test.gd
git commit -m "chore: establish gdunit e2e addon baseline"
```

---

## Task 2: Implement protocol framing and Variant serialization

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

class_name E2EFraming
static func encode_json(message: Dictionary) -> PackedByteArray
static func try_extract(buffer: PackedByteArray) -> Dictionary
# returns {"complete": bool, "message": Dictionary, "remaining": PackedByteArray, "error": String}

class_name E2ESerializer
static func serialize(value: Variant) -> Variant
static func deserialize(value: Variant) -> Variant
```

- [ ] **Step 1: Write framing tests first**

Cover:

1. header is four-byte big-endian length;
2. UTF-8 payload round-trip;
3. incomplete header returns `complete=false`;
4. incomplete body returns `complete=false` without consuming bytes;
5. two concatenated frames leave the second in `remaining`;
6. a declared payload over 16 MiB returns `frame_too_large`.

Run:

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/protocol_test.gd
```

Expected: FAIL because `E2EFraming` does not exist.

- [ ] **Step 2: Implement the smallest framing parser and make the tests pass**

Do not add compression, streaming JSON, checksums, or alternate framing.

- [ ] **Step 3: Write serializer tests using the upstream wire tags**

Cover primitives plus the upstream supported Godot value shapes:

```text
Vector2 / Vector2i
Vector3 / Vector3i
Rect2 / Rect2i
Color
Transform2D
NodePath
Array / Dictionary
PackedVector2Array
PackedFloat32Array
PackedInt32Array
PackedStringArray
```

Unknown values remain tagged diagnostic dictionaries rather than causing the serializer to crash.

- [ ] **Step 4: Implement the serializer by adapting the pinned upstream `json_serializer.gd` behavior**

Preserve its `_t` tags (`v2`, `v2i`, `v3`, `v3i`, `r2`, `r2i`, `col`, `t2d`, `np`, `_unknown`) for protocol compatibility.

- [ ] **Step 5: Run protocol + serializer tests**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/protocol_test.gd -a tests/unit/serializer_test.gd
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add addons/gdunit_e2e/protocol tests/unit/protocol_test.gd tests/unit/serializer_test.gd
git commit -m "feat: add e2e protocol primitives"
```

---

## Task 3: Adapt the child automation server

**Files:**
- Create: `addons/gdunit_e2e/server/config.gd`
- Create: `addons/gdunit_e2e/server/log_capture.gd`
- Create: `addons/gdunit_e2e/server/command_handler.gd`
- Create: `addons/gdunit_e2e/server/automation_server.gd`
- Create: `tests/unit/config_test.gd`
- Create: `tests/unit/command_handler_test.gd`
- Create: `tests/integration/automation_server_test.gd`

**Interfaces:**

```gdscript
class_name GdUnitE2EConfig
static func is_enabled() -> bool
static func get_port() -> int
static func get_port_file() -> String
static func get_token() -> String
static func get_log_verbosity() -> String
```

Server launch flags:

```text
--gdunit-e2e
--gdunit-e2e-port=<N>
--gdunit-e2e-port-file=<absolute path>
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=<error|warning|info>
```

- [ ] **Step 1: Write config parsing tests**

Test disabled-by-default behavior, each flag, invalid port fallback, and invalid verbosity fallback.

Expected first run: FAIL.

- [ ] **Step 2: Adapt upstream config with renamed flags**

Keep parsing small and based on `OS.get_cmdline_user_args()`.

- [ ] **Step 3: Write command-handler tests before copying behavior**

Cover the MVP commands:

```text
node_exists
get_property
set_property
call_method
get_tree
input_key
input_action
input_mouse_button
click_node
wait_process_frames
wait_physics_frames
wait_seconds
wait_for_node
wait_for_signal
wait_for_property
get_scene
change_scene
reload_scene
screenshot
quit
```

Use a tiny test scene and assert command result dictionaries/deferred wait descriptors.

- [ ] **Step 4: Adapt the pinned upstream command handler and serializer references**

Remove commands that are not part of the MVP unless they are required internally. Preserve upstream command names/parameter shapes for included commands.

- [ ] **Step 5: Adapt log capture**

Keep the bounded ring buffer and response-delta model. Do not add flood detection in this PR.

- [ ] **Step 6: Adapt the automation server**

Required differences from upstream:

- class/autoload naming uses `GdUnitE2E`;
- only `--gdunit-e2e` activates it;
- listen explicitly on `127.0.0.1`;
- handshake also validates `protocol_version == 1`;
- framing uses the shared `E2EFraming`/protocol constants;
- payload limit is 16 MiB;
- only one client and one in-flight command are supported.

- [ ] **Step 7: Add the real server integration test**

Launch a test server-enabled project, connect a raw `StreamPeerTCP`, send `hello`, assert successful handshake, then verify an invalid token is rejected.

- [ ] **Step 8: Run the server slice**

```bash
./addons/gdUnit4/runtest.sh \
  -a tests/unit/config_test.gd \
  -a tests/unit/command_handler_test.gd \
  -a tests/integration/automation_server_test.gd
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add addons/gdunit_e2e/server tests/unit/config_test.gd tests/unit/command_handler_test.gd tests/integration/automation_server_test.gd
git commit -m "feat: add child automation server"
```

---

## Task 4: Implement the non-blocking GDScript client

**Files:**
- Create: `addons/gdunit_e2e/client/e2e_result.gd`
- Create: `addons/gdunit_e2e/client/e2e_pending_request.gd`
- Create: `addons/gdunit_e2e/client/e2e_client.gd`
- Create: `tests/helpers/fake_e2e_server.gd`
- Create: `tests/unit/client_test.gd`

**Interfaces:**

```gdscript
class_name E2EResult
var ok: bool
var value: Variant
var error_code: String
var message: String
var logs: Array

class_name E2EClient
extends Node

func connect_to_server(host: String, port: int, token: String, timeout_seconds := 5.0) -> E2EResult
func send_command(action: String, parameters := {}, timeout_seconds := 5.0) -> E2EResult
func close() -> void
func is_connected() -> bool
func reset_collected_logs() -> void
func get_collected_logs() -> Array
```

- [ ] **Step 1: Build a deterministic fake server helper**

The fake server should accept one connection, decode the same framing, and let tests queue specific responses. It must not know GdUnit internals.

- [ ] **Step 2: Write client RED tests**

Cover:

- connection and hello handshake;
- monotonically increasing request IDs;
- one complete response;
- response arriving over partial TCP reads;
- command error converted to `E2EResult(ok=false)`;
- timeout converted to `E2EResult(error_code="timeout")`;
- disconnect converted to `connection_lost`;
- log deltas appended to collected logs;
- second command rejected while one is in flight;
- `close()` is idempotent.

- [ ] **Step 3: Implement polling without blocking the Godot main loop**

`E2EClient` should call `StreamPeerTCP.poll()` from `_process()`, append available bytes to a receive buffer, repeatedly extract complete frames, and resolve the one pending request.

Do not use a busy loop waiting for network data.

- [ ] **Step 4: Implement request timeout using `Time.get_ticks_msec()`**

Timeout completion must happen from the client's normal processing path so GdUnit remains responsive.

- [ ] **Step 5: Run the client tests**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/client_test.gd
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add addons/gdunit_e2e/client/e2e_result.gd addons/gdunit_e2e/client/e2e_pending_request.gd addons/gdunit_e2e/client/e2e_client.gd tests/helpers/fake_e2e_server.gd tests/unit/client_test.gd
git commit -m "feat: add async gdscript e2e client"
```

---

## Task 5: Add child-process launch and cleanup

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

- [ ] **Step 1: Write launch-option validation tests**

Validate project path, optional explicit Godot executable, accepted log verbosity, and command construction.

Default executable is `OS.get_executable_path()`.

- [ ] **Step 2: Create the minimal fixture project**

The fixture scene must expose enough observable state for later tests:

```gdscript
extends Node2D

@onready var status: Label = $Status
var action_count := 0

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("ui_accept"):
        action_count += 1
        status.text = "accepted:%d" % action_count
```

Include a `Button` whose press changes another label so click automation can be tested later.

- [ ] **Step 3: Write process lifecycle RED tests**

Test:

1. child launches using `OS.execute_with_pipe()`;
2. child writes its ephemeral port file;
3. client connects and authenticates;
4. process is alive after launch;
5. `close()` requests quit and reaps the child;
6. `close()` twice is safe;
7. a child that cannot complete handshake returns a launch error and is killed;
8. temporary port file is removed.

- [ ] **Step 4: Implement launch flow**

```text
create temp port file path
→ generate random token
→ OS.execute_with_pipe()
→ poll file until it contains a port or timeout/child exit
→ add E2EClient as a child Node
→ connect + hello
→ return success
```

Use `Crypto.generate_random_bytes()` (or equivalent Godot crypto API) to create the per-launch token; do not use a fixed test token in production code.

- [ ] **Step 5: Implement shutdown flow**

Attempt graceful `quit`, close the client, and then hard-kill a still-running PID with `OS.kill()` after a short bounded grace period.

- [ ] **Step 6: Run process lifecycle integration tests**

```bash
./addons/gdUnit4/runtest.sh -a tests/integration/process_lifecycle_test.gd
```

Expected: PASS with no surviving child process.

- [ ] **Step 7: Commit**

```bash
git add addons/gdunit_e2e/client/e2e_launch_options.gd addons/gdunit_e2e/client/e2e_process.gd tests/fixtures/minimal tests/unit/launch_options_test.gd tests/integration/process_lifecycle_test.gd
git commit -m "feat: manage e2e child process lifecycle"
```

---

## Task 6: Expose the high-level remote game API

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
func send_command(action: String, parameters := {}, timeout := 5.0) -> E2EResult
```

All remote methods that wait for TCP results are invoked with `await` by callers, even where the returned business value is not itself a signal.

- [ ] **Step 1: Write unit tests around a fake client**

Verify each wrapper sends the expected upstream command and serializes/deserializes values correctly.

- [ ] **Step 2: Implement the smallest wrapper**

Do not add locators or assertion classes.

- [ ] **Step 3: Add the real gameplay smoke test**

The test must prove the product's core value:

```gdscript
func test_action_reaches_separate_game_process() -> void:
    var game := await launch_fixture_game()

    assert_int(await game.get_property("/root/Main", "action_count")).is_equal(0)
    await game.press_action("ui_accept")
    await game.wait_process_frames(2)
    assert_int(await game.get_property("/root/Main", "action_count")).is_equal(1)
```

Add a second test that clicks the fixture button and verifies its label changed remotely.

- [ ] **Step 4: Run the smoke tests**

```bash
./addons/gdUnit4/runtest.sh -a tests/integration/gameplay_smoke_test.gd
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add addons/gdunit_e2e/client/gdunit_e2e_game.gd tests/unit/game_api_test.gd tests/integration/gameplay_smoke_test.gd
git commit -m "feat: expose remote game test api"
```

---

## Task 7: Integrate GdUnit lifecycle and failure artifacts

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

The base suite may internally track launched sessions for guaranteed cleanup, but it must not override or replace GdUnit's test runner.

- [ ] **Step 1: Write failure-format tests**

A failed remote command should become one readable GdUnit failure containing action, target context, error code, and message.

Example desired text:

```text
E2E command get_property failed for /root/Main/Missing.health: node_not_found — Node '/root/Main/Missing' was not found
```

- [ ] **Step 2: Implement GdUnit failure mapping**

Use the public `fail(message)` API. Do not reach into GdUnit internals.

- [ ] **Step 3: Add automatic launched-session cleanup**

Any game launched through the base suite is registered and closed from suite cleanup even if a test fails.

- [ ] **Step 4: Add best-effort artifacts on failure**

Create:

```text
test_output/<suite>/<test>/
├── screenshot.png
├── scene_tree.json
├── engine_logs.json
├── stdout.log
└── stderr.log
```

Capture each artifact independently. A screenshot failure must not prevent log capture, and artifact errors must not replace the primary test failure.

- [ ] **Step 5: Add the deliberately failing integration test**

Run a nested/fixture test that intentionally requests a missing node, then assert the output directory contains the available artifacts and the child process was cleaned up.

- [ ] **Step 6: Run lifecycle/artifact tests**

```bash
./addons/gdUnit4/runtest.sh \
  -a tests/unit/gdunit_suite_test.gd \
  -a tests/integration/failure_artifact_test.gd
```

Expected: PASS (the outer characterization test validates the intentionally failing inner flow).

- [ ] **Step 7: Commit**

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
- Modify: `NOTICE` if adapted file list changed
- Verify: all tests

**Interfaces:**
- Produces Linux and Windows CI exercising real child processes.
- Produces `dist/godot-e2e-0.1.0.zip` containing only distributable files.

- [ ] **Step 1: Add Linux CI**

Linux job:

```text
checkout
→ install pinned Godot 4.5+ build
→ ./scripts/bootstrap_gdunit4.sh
→ start Xvfb / set DISPLAY
→ run full GdUnit suite
→ upload reports/test_output on failure
```

- [ ] **Step 2: Add Windows CI**

Windows job:

```text
checkout
→ install same Godot version family
→ powershell ./scripts/bootstrap_gdunit4.ps1
→ run full GdUnit suite
→ upload reports/test_output on failure
```

Do not add macOS or a version matrix in this PR.

- [ ] **Step 3: Add release packaging test/script**

`package_release.sh` must package only:

```text
addons/gdunit_e2e/**
README.md
LICENSE
NOTICE
```

and explicitly exclude `addons/gdUnit4`, tests, reports, and `test_output`.

- [ ] **Step 4: Replace planning README with user-facing setup**

README should contain:

1. what E2E isolation adds beyond GdUnit scene tests;
2. prerequisites;
3. addon installation;
4. enabling the plugin/autoload;
5. a minimal GDScript test;
6. command/API table for the MVP;
7. CI notes;
8. attribution to the pinned upstream commit;
9. explicit non-goals/deferred features.

Minimal example:

```gdscript
extends GdUnitE2ETestSuite

func test_game_accepts_input() -> void:
    var game := await launch_game()
    await game.press_action("ui_accept")
    await game.wait_process_frames(2)
    assert_int(await game.get_property("/root/Main", "action_count")).is_equal(1)
```

- [ ] **Step 5: Run the complete local verification**

Linux/macOS development machine:

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests -c
./scripts/package_release.sh
unzip -l dist/godot-e2e-0.1.0.zip
```

Verify:

- zero GdUnit failures;
- all integration children exit;
- no leftover `.port` files;
- package contains no GdUnit4 dependency or test files.

- [ ] **Step 6: Commit**

```bash
git add .github README.md NOTICE scripts/package_release.sh
git commit -m "ci: validate and package gdunit e2e addon"
```

---

## Final PR Verification

Before marking the single implementation PR ready for review:

- [ ] Re-read `docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md` and map every acceptance criterion to a passing test or documented manual check.
- [ ] Run the complete GdUnit suite from a clean checkout after bootstrapping GdUnit4.
- [ ] Confirm Linux CI passes.
- [ ] Confirm Windows CI passes.
- [ ] Confirm failure artifacts are uploaded when a CI characterization run fails.
- [ ] Inspect the release ZIP and confirm it contains only addon + README/LICENSE/NOTICE.
- [ ] Search production addon code for `pytest`, Python imports, locators, process pools, editor panels, and other explicitly deferred features; none should exist.
- [ ] Search adapted upstream files for Apache-2.0 attribution and modification notices.
- [ ] Confirm the PR contains task-level commits but remains one PR for the MVP.

## Follow-ups after 0.1.0

Do not pull these into the MVP unless a test proves the core design cannot work without them:

1. Playwright-like locators.
2. Retrying `expect()` assertions.
3. Engine-error-flood detection.
4. Dedicated Godot .NET/C# target fixture.
5. macOS CI.
6. Multiple parallel child sessions.
7. richer trace/diagnostic UX.
