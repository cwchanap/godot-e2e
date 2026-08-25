# Zero-Config Godot E2E Addon Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `godot-e2e` usable immediately after its files are installed by removing the EditorPlugin/autoload setup requirement and bootstrapping the automation server only inside E2E child processes.

**Architecture:** `E2EProcess` launches a private addon-owned bootstrap scene instead of launching the consumer target scene directly. The bootstrap defers a runner into `SceneTree.root`; that runner registers log capture before the consumer scene initializes, switches to the requested scene, then attaches the existing automation server directly under `SceneTree.root` and removes itself. This preserves startup diagnostics, normal consumer paths such as `/root/Main`, and server survival across later scene changes without permanent `project.godot` mutation.

**Tech Stack:** Godot 4.5+, GDScript, GdUnit4 6.x, existing localhost TCP E2E protocol.

**Spec:** `docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md` (Task 1 amends the installation/runtime sections to this bootstrap model.)

## Global Constraints

- One feature PR for planning and implementation.
- Preserve the public `E2ELaunchOptions.scene_path` API.
- Preserve the existing TCP framing, token authentication, command handler, diagnostics, orphan watchdog, and process lifecycle behavior.
- Preserve consumer-scene startup logs emitted from `_ready()` and earlier engine initialization after removing the autoload.
- Do not add an installer CLI, npm wrapper, editor dock, package manager, or second runtime.
- Do not modify consumer `project.godot`.
- Do not require enabling an editor plugin.
- Bootstrap infrastructure exists only in the E2E child process.
- The consumer target scene must become `SceneTree.current_scene` and retain paths such as `/root/Main`.
- Resolve the private bootstrap scene relative to the installed addon code; do not hardcode `res://addons/gdunit_e2e` in the launcher.
- GdUnit4 remains separately installed and is not bundled.
- Linux and Windows remain the required CI platforms.
- Target release: `0.1.1`.
- RED → GREEN → REFACTOR for implementation tasks.

## Planned File Structure

```text
addons/gdunit_e2e/
├── client/
│   └── e2e_process.gd
├── runtime/
│   ├── bootstrap.tscn
│   ├── bootstrap.gd
│   └── bootstrap_runner.gd
├── server/
│   ├── automation_server.gd
│   ├── config.gd
│   └── log_capture.gd
└── ...
```

Remove:

```text
addons/gdunit_e2e/plugin.cfg
addons/gdunit_e2e/plugin.gd
```

Responsibilities:

- `bootstrap.tscn`: private child-process entry scene.
- `bootstrap.gd`: defers runner attachment to `SceneTree.root` after the bootstrap scene finishes entering the tree.
- `bootstrap_runner.gd`: registers startup log capture, survives replacement of the bootstrap scene, activates the requested consumer scene, hands the existing capture to the automation server, then removes itself.
- `automation_server.gd`: retains standalone log-capture creation when no capture is injected, and accepts the bootstrap-owned capture before entering the tree.

The runner must live directly below `/root`, not below the bootstrap scene, so replacing `SceneTree.current_scene` cannot destroy startup logic. The root attachment must be deferred because the SceneTree root is still busy inserting the bootstrap scene while its `_ready()` callback runs.

---

### Task 1: Amend the installation and runtime design contract

**Files:**
- Modify: `docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md`

**Interfaces:**
- Consumes: current 0.1.0 design contract.
- Produces: authoritative zero-config bootstrap contract used by Tasks 2–4.

- [ ] **Step 1: Replace the autoload architecture in the design**

Change the child architecture from a pre-registered project autoload to:

```text
Child Godot process
├── consumer target scene
└── GdUnitE2EAutomationServer
    └── directly attached under SceneTree.root by private bootstrap
```

The server stays outside `SceneTree.current_scene`, so normal remote scene changes do not remove it.

- [ ] **Step 2: Replace installation requirements**

The supported installation contract becomes:

```text
install GdUnit4
copy/install addons/gdunit_e2e
write tests
run tests
```

State explicitly:

```text
No editor plugin enable step.
No godot-e2e autoload entry.
No consumer project.godot modification.
```

- [ ] **Step 3: Update launch and diagnostic semantics**

Document that `E2EProcess` launches the private bootstrap PackedScene resolved from its installed resource path, rather than relying on a fixed addon directory. The child still receives the consumer scene through:

```text
--gdunit-e2e-target-scene=<E2ELaunchOptions.scene_path>
```

Document this startup order:

```text
bootstrap scene enters tree
→ defer runner under SceneTree.root
→ runner validates E2E configuration
→ runner registers LogCapture
→ change to consumer target scene
→ consumer scene initializes, including _ready()
→ scene_changed fires
→ runner creates automation server with the existing LogCapture
→ automation server listens/writes port file
→ runner frees itself
→ parent authenticates
```

The automation server must not accept authentication until the target consumer scene has become current, while log capture must begin before that scene initializes.

- [ ] **Step 4: Update acceptance criteria**

Add these required behaviors:

```text
- a clean consumer project with no gdunit-e2e autoload can launch E2E tests;
- the requested consumer scene becomes SceneTree.current_scene;
- its root remains directly below /root;
- startup push_error/push_warning output from the consumer scene reaches the parent log collection;
- the bootstrap scene and runner are gone after startup;
- the automation server survives change_scene/reload_scene exactly as the old autoload did;
- a renamed addon install directory still resolves the private bootstrap through its preloaded resource path.
```

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md
git commit -m "docs: define zero-config e2e bootstrap"
```

---

### Task 2: Add target-scene configuration and safe private bootstrap

**Files:**
- Modify: `addons/gdunit_e2e/server/config.gd`
- Modify: `addons/gdunit_e2e/server/automation_server.gd`
- Modify: `tests/unit/config_test.gd`
- Create: `addons/gdunit_e2e/runtime/bootstrap.tscn`
- Create: `addons/gdunit_e2e/runtime/bootstrap.gd`
- Create: `addons/gdunit_e2e/runtime/bootstrap_runner.gd`

**Interfaces:**
- Produces: `GdUnitE2EConfig.get_target_scene() -> String`.
- Produces: a private bootstrap PackedScene loaded by `E2EProcess` through a relative preload.
- Produces: `GdUnitE2EAutomationServer.set_log_capture(log_capture) -> void`, called before the server enters the SceneTree.
- The runner starts from its own `_ready()`; there is no `start()` method or second deferred-start layer.

- [ ] **Step 1: Write RED target-scene config tests**

Add:

```gdscript
func test_parses_target_scene() -> void:
    GdUnitE2EConfig._reset_for_testing([
        "--gdunit-e2e",
        "--gdunit-e2e-target-scene=res://main.tscn",
    ])

    assert_str(GdUnitE2EConfig.get_target_scene()).is_equal("res://main.tscn")
    assert_bool(GdUnitE2EConfig.is_valid()).is_true()


func test_rejects_empty_explicit_target_scene() -> void:
    GdUnitE2EConfig._reset_for_testing([
        "--gdunit-e2e",
        "--gdunit-e2e-target-scene=",
    ])

    assert_bool(GdUnitE2EConfig.is_valid()).is_false()
```

Absence of this flag remains valid for direct automation-server unit tests. The bootstrap itself requires a target scene.

- [ ] **Step 2: Run RED config tests**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/config_test.gd
```

Expected: FAIL because `get_target_scene()` does not exist.

- [ ] **Step 3: Add minimal config parsing**

Add state:

```gdscript
static var _target_scene := ""
```

Parse:

```gdscript
elif arg.begins_with("--gdunit-e2e-target-scene="):
    _target_scene = arg.substr("--gdunit-e2e-target-scene=".length())
    if _target_scene.is_empty():
        _mark_invalid("target scene must not be empty")
```

Expose:

```gdscript
static func get_target_scene() -> String:
    _ensure_parsed()
    return _target_scene
```

Reset `_target_scene` in `_reset_for_testing()`.

- [ ] **Step 4: Run config GREEN**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/config_test.gd
```

Expected: PASS.

- [ ] **Step 5: Let the automation server accept an already-registered log capture**

Add the narrow injection seam:

```gdscript
func set_log_capture(log_capture) -> void:
    _log_capture = log_capture
```

Keep direct/legacy construction working by changing `_ready()` from unconditional logger creation to:

```gdscript
if _log_capture == null:
    _log_capture = LogCaptureScript.new()
    _log_capture.set_verbosity_str(Config.get_log_verbosity())
    OS.add_logger(_log_capture)
```

Do not create a second logging abstraction or ownership object. The bootstrap runner and server share the same `LogCapture` instance for the lifetime of the child.

- [ ] **Step 6: Implement the bootstrap entry scene with deferred root attachment**

`bootstrap.gd`:

```gdscript
extends Node

const BootstrapRunner = preload("bootstrap_runner.gd")


func _ready() -> void:
    var runner = BootstrapRunner.new()
    runner.name = "GdUnitE2EBootstrapRunner"
    # The SceneTree root is still inserting this bootstrap scene while _ready()
    # runs, so root-level startup infrastructure must be attached deferred.
    get_tree().root.add_child.call_deferred(runner)
```

`bootstrap.tscn` contains only the Node using this script.

Do not call `root.add_child(runner)` synchronously from the bootstrap scene's `_ready()`; that can fail while the root is busy setting up the current scene.

- [ ] **Step 7: Implement the persistent runner and register logs before scene initialization**

`bootstrap_runner.gd`:

```gdscript
extends Node
class_name GdUnitE2EBootstrapRunner

const Config = preload("../server/config.gd")
const AutomationServer = preload("../server/automation_server.gd")
const LogCapture = preload("../server/log_capture.gd")

var _log_capture = null


func _ready() -> void:
    if not Config.is_enabled():
        push_error("godot-e2e: missing --gdunit-e2e")
        get_tree().quit(2)
        return
    if not Config.is_valid():
        push_error("godot-e2e: %s" % Config.get_validation_error())
        get_tree().quit(2)
        return

    var target_scene := Config.get_target_scene()
    if target_scene.is_empty():
        push_error("godot-e2e: missing --gdunit-e2e-target-scene")
        get_tree().quit(2)
        return

    _log_capture = LogCapture.new()
    _log_capture.set_verbosity_str(Config.get_log_verbosity())
    OS.add_logger(_log_capture)

    var error := get_tree().change_scene_to_file(target_scene)
    if error != OK:
        push_error("godot-e2e: failed to load target scene '%s' (error %d)" % [target_scene, error])
        get_tree().quit(2)
        return

    await get_tree().scene_changed

    var server := AutomationServer.new()
    server.name = "GdUnitE2EAutomationServer"
    server.set_log_capture(_log_capture)
    get_tree().root.add_child(server)

    queue_free()
```

`scene_changed` occurs only after the target scene has entered the tree and initialized, so registering `LogCapture` before `change_scene_to_file()` is required to retain consumer `_ready()` errors. The server is still attached only after the scene change succeeds, so invalid targets never expose a listener.

- [ ] **Step 8: Run existing server/config unit coverage**

```bash
./addons/gdUnit4/runtest.sh \
  -a tests/unit/config_test.gd \
  -a tests/unit/automation_server_framing_test.gd \
  -a tests/unit/command_handler_test.gd
```

Expected: PASS. Positive bootstrap behavior is intentionally proven by the real child integration in Task 3 rather than by duplicate file-existence tests.

- [ ] **Step 9: Commit**

```bash
git add addons/gdunit_e2e/runtime \
        addons/gdunit_e2e/server/config.gd \
        addons/gdunit_e2e/server/automation_server.gd \
        tests/unit/config_test.gd
git commit -m "feat: add safe e2e child bootstrap"
```

---

### Task 3: Remove the old injection point and route real launches through bootstrap

**Files:**
- Delete: `addons/gdunit_e2e/plugin.cfg`
- Delete: `addons/gdunit_e2e/plugin.gd`
- Delete: `tests/unit/plugin_registration_test.gd`
- Modify: `project.godot`
- Modify: `addons/gdunit_e2e/client/e2e_process.gd`
- Modify: `tests/unit/launch_options_test.gd`
- Modify: `tests/integration/server_startup_test.gd`
- Create: `tests/unit/installation_contract_test.gd`
- Create: `tests/fixtures/startup_error/main.gd`
- Create: `tests/fixtures/startup_error/main.tscn`

**Interfaces:**
- Consumes: `E2ELaunchOptions.scene_path` as the consumer target scene.
- Consumes: private bootstrap PackedScene from Task 2.
- Produces: zero-config child launch without changing the public launch API.
- Produces: the only real E2E server in a child process; the old autoload is removed before bootstrap integration is judged GREEN.

- [ ] **Step 1: Write the RED installation-contract test against the current plugin/autoload state**

Create `tests/unit/installation_contract_test.gd`:

```gdscript
extends GdUnitTestSuite


func test_project_has_no_e2e_autoload() -> void:
    assert_bool(
        ProjectSettings.has_setting("autoload/GdUnitE2EAutomationServer")
    ).is_false()


func test_addon_requires_no_editor_plugin() -> void:
    assert_bool(FileAccess.file_exists(
        "res://addons/gdunit_e2e/plugin.cfg"
    )).is_false()
    assert_bool(FileAccess.file_exists(
        "res://addons/gdunit_e2e/plugin.gd"
    )).is_false()


func test_bootstrap_scene_points_to_bootstrap_script() -> void:
    var packed := load("res://addons/gdunit_e2e/runtime/bootstrap.tscn") as PackedScene
    assert_object(packed).is_not_null()
    var root := packed.instantiate()
    assert_str(root.get_script().resource_path).is_equal(
        "res://addons/gdunit_e2e/runtime/bootstrap.gd"
    )
    root.free()
```

This is the single structural installation suite. Do not add a second `bootstrap_test.gd` that repeats file-existence assertions.

- [ ] **Step 2: Run installation RED**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/installation_contract_test.gd
```

Expected: FAIL because the old E2E autoload and editor-plugin files still exist.

- [ ] **Step 3: Remove the competing plugin/autoload injection point before testing bootstrap launches**

Delete:

```text
addons/gdunit_e2e/plugin.cfg
addons/gdunit_e2e/plugin.gd
tests/unit/plugin_registration_test.gd
```

Delete from `project.godot`:

```ini
[autoload]

GdUnitE2EAutomationServer="*res://addons/gdunit_e2e/server/automation_server.gd"
```

Keep GdUnit4's development editor-plugin configuration unchanged. Do not commit yet; the task's GREEN state requires the new launch path too.

- [ ] **Step 4: Run installation GREEN before changing the launcher**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/installation_contract_test.gd
```

Expected: PASS. At this point real E2E child launches are intentionally broken because no runtime injection point exists; that makes the following integration GREEN meaningful rather than accidentally exercising the old autoload.

- [ ] **Step 5: Write RED argv expectations**

Change `tests/unit/launch_options_test.gd` to expect the installed bootstrap resource path as the child scene and the consumer scene as an E2E-only user argument:

```text
--path <project>
--scene res://addons/gdunit_e2e/runtime/bootstrap.tscn
<extra Godot args>
--
--gdunit-e2e
--gdunit-e2e-target-scene=<consumer scene>
--gdunit-e2e-port=0
--gdunit-e2e-port-file=<temp path>
--gdunit-e2e-token=<token>
--gdunit-e2e-log-verbosity=warning
```

The concrete path above is correct for this repository checkout, but production code must derive it from the preloaded PackedScene rather than embedding that string.

- [ ] **Step 6: Run argv RED**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/launch_options_test.gd
```

Expected: FAIL with argv mismatch because `E2EProcess` still launches `options.scene_path` directly.

- [ ] **Step 7: Resolve the bootstrap relative to `e2e_process.gd` and update `build_arguments()`**

Add:

```gdscript
const BootstrapScene = preload("../runtime/bootstrap.tscn")
```

Build the engine scene argument with:

```gdscript
"--scene",
BootstrapScene.resource_path,
```

and after the `--` separator add:

```gdscript
"--gdunit-e2e-target-scene=" + options.scene_path
```

Do not add a new launch-option property. Do not introduce `const BOOTSTRAP_SCENE := "res://addons/gdunit_e2e/..."`; the relative preload keeps renamed/vendored addon directories working and makes a missing bootstrap an import-time failure.

- [ ] **Step 8: Run argv GREEN**

```bash
./addons/gdUnit4/runtest.sh -a tests/unit/launch_options_test.gd
```

Expected: PASS.

- [ ] **Step 9: Pin current-scene, NodePath, runner-removal, and server-survival behavior in the real child integration**

Extend the successful launch case in `tests/integration/server_startup_test.gd`:

```gdscript
var client = _process.get_client()
var scene_result = await client.send_command("get_scene")
assert_bool(scene_result.ok).is_true()
assert_str(scene_result.value["scene"]).is_equal(
    "res://tests/fixtures/minimal/main.tscn"
)

var root_result = await client.send_command("node_exists", {"path": "/root/Main"})
assert_bool(root_result.ok).is_true()
assert_bool(root_result.value["exists"]).is_true()

var bootstrap_result = await client.send_command(
    "node_exists",
    {"path": "/root/GdUnitE2EBootstrapRunner"},
)
assert_bool(bootstrap_result.ok).is_true()
assert_bool(bootstrap_result.value["exists"]).is_false()
```

Then force a real scene replacement through the existing server command and prove the same connection/server survives:

```gdscript
var changed = await client.send_command(
    "change_scene",
    {"scene_path": "res://tests/fixtures/minimal/main.tscn"},
    6.0,
)
assert_bool(changed.ok).is_true()

var after_change = await client.send_command("node_exists", {"path": "/root/Main"})
assert_bool(after_change.ok).is_true()
assert_bool(after_change.value["exists"]).is_true()
```

Keep the existing `/root/Main/Status` property assertion as well. This is the structural regression that proves the root-owned server replaces the survival guarantee previously supplied by an autoload.

- [ ] **Step 10: Add a startup-error fixture and prove early logs cross the bootstrap boundary**

Create `tests/fixtures/startup_error/main.gd`:

```gdscript
extends Node


func _ready() -> void:
    push_error("gdunit-e2e startup error fixture")
```

Create `tests/fixtures/startup_error/main.tscn`:

```text
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/fixtures/startup_error/main.gd" id="1"]

[node name="StartupError" type="Node"]
script = ExtResource("1")
```

Add an integration test that launches this scene and checks the client's accumulated logs after the hello handshake:

```gdscript
var result = await _launch("res://tests/fixtures/startup_error/main.tscn")
assert_bool(result.ok).is_true()

var found_startup_error := false
for entry in _process.get_client().get_collected_logs():
    if String(entry.get("message", "")).contains("gdunit-e2e startup error fixture"):
        found_startup_error = true
        break
assert_bool(found_startup_error).is_true()
```

Adjust the local `_launch()` helper to accept an optional scene path and assign it to `E2ELaunchOptions.scene_path`; do not add fixture-specific production behavior.

This test must fail if log registration is moved back to server creation after `scene_changed`.

- [ ] **Step 11: Add invalid-target integration regression**

Launch with:

```gdscript
options.scene_path = "res://does_not_exist.tscn"
```

Assert:

```text
launch fails
child exits
PID is not running
_process.get_port() remains -1
no E2E port file is successfully consumed
```

The existing `E2EProcess.launch()` child-exited/timeout handling remains the failure mapper; do not create a second bootstrap error transport.

- [ ] **Step 12: Run the genuine zero-config integration gate**

```bash
./addons/gdUnit4/runtest.sh \
  -a tests/unit/installation_contract_test.gd \
  -a tests/unit/launch_options_test.gd \
  -a tests/integration/server_startup_test.gd \
  -a tests/integration/process_lifecycle_test.gd \
  -a tests/integration/gameplay_smoke_test.gd
```

Expected: PASS with no surviving children. Because the repository autoload was removed before this run, a passing `server_startup_test.gd` is evidence for the bootstrap path itself rather than the old server accidentally winning the port-file race.

- [ ] **Step 13: Commit**

```bash
git add -A addons/gdunit_e2e \
           project.godot \
           tests/unit \
           tests/integration/server_startup_test.gd \
           tests/fixtures/startup_error
git commit -m "feat: launch e2e games without project setup"
```

---

### Task 4: Simplify install docs and package 0.1.1

**Files:**
- Modify: `README.md`
- Modify: `scripts/package_release.sh`
- Modify: `.github/workflows/ci.yml` only if the renamed/deleted tests are explicitly enumerated

**Interfaces:**
- Consumes: final zero-config addon layout.
- Produces: documented install flow and `0.1.1` release archive.

- [ ] **Step 1: Replace installation instructions**

Replace:

```text
copy addon
→ open Project Settings
→ Plugins
→ enable GdUnit E2E
```

with:

```text
1. Install GdUnit4.
2. Install/copy addons/gdunit_e2e.
3. Write an E2E test.
```

State explicitly:

```text
There is no editor plugin to enable and godot-e2e does not add an autoload
to your project. The automation server exists only inside child processes
launched by GdUnitE2ETestSuite.
```

- [ ] **Step 2: Keep consumer test syntax unchanged**

The README example remains:

```gdscript
var options := E2ELaunchOptions.new()
options.scene_path = "res://main.tscn"
var game := await launch_game(options)
```

No source migration is required for existing E2E tests.

- [ ] **Step 3: Bump package-release version**

Change:

```bash
VERSION="0.1.1"
```

Expected archive:

```text
dist/godot-e2e-0.1.1.zip
```

- [ ] **Step 4: Verify release contents**

```bash
./scripts/package_release.sh
unzip -l dist/godot-e2e-0.1.1.zip
```

Require:

```text
addons/gdunit_e2e/runtime/bootstrap.tscn
addons/gdunit_e2e/runtime/bootstrap.gd
addons/gdunit_e2e/runtime/bootstrap_runner.gd
```

Reject:

```text
addons/gdunit_e2e/plugin.cfg
addons/gdunit_e2e/plugin.gd
addons/gdUnit4/**
tests/**
project.godot
```

- [ ] **Step 5: Run the full normal suite**

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
```

Expected: PASS, including the startup-log and scene-survival regressions from Task 3.

- [ ] **Step 6: Run the expected-failure artifact harness**

```bash
set +e
./addons/gdUnit4/runtest.sh -a tests/fixtures/failure_harness_test.gd
status=$?
set -e
test "$status" -eq 100
```

Require failure artifacts and no surviving child. In particular, `engine_logs.json` must remain populated when the failing path emitted captured engine logs.

- [ ] **Step 7: Verify Linux and Windows CI**

Both jobs must continue covering:

```text
bootstrap launch
consumer startup log capture
real target scene
scene-change server survival
TCP authentication
graceful child exit
forced child exit
orphan watchdog
failure artifacts
bounded stdout/stderr drain
```

CI remains pinned to the existing Godot 4.5.1 family. Do not add a version or OS matrix.

- [ ] **Step 8: Commit**

```bash
git add README.md scripts/package_release.sh .github/workflows/ci.yml
git commit -m "docs: ship zero-config addon installation"
```

---

## Final PR Verification

- [ ] `E2ELaunchOptions.scene_path` remains source-compatible.
- [ ] `E2EProcess` resolves the private bootstrap via a relative `preload("../runtime/bootstrap.tscn")` and passes `BootstrapScene.resource_path` to `--scene`; no hardcoded addon root is used.
- [ ] The bootstrap runner is deferred under `SceneTree.root`; no synchronous root `add_child()` happens from bootstrap `_ready()`.
- [ ] The requested consumer scene becomes `SceneTree.current_scene`.
- [ ] Existing `/root/Main/...` paths remain unchanged.
- [ ] Consumer startup errors emitted during `_ready()` reach the parent's collected engine logs.
- [ ] The automation server is directly below `SceneTree.root`, outside the current scene.
- [ ] `GdUnitE2EBootstrapRunner` disappears after startup.
- [ ] A real `change_scene` round-trip succeeds and subsequent commands still reach the server.
- [ ] Missing/invalid target scenes fail before exposing an E2E listener.
- [ ] `project.godot` contains no `GdUnitE2EAutomationServer` autoload before bootstrap integration is considered GREEN.
- [ ] `plugin.cfg`, `plugin.gd`, and `plugin_registration_test.gd` no longer exist.
- [ ] One installation-contract suite owns structural no-plugin/no-autoload assertions; there is no redundant bootstrap file-existence suite.
- [ ] No manual plugin-enable step remains in README.
- [ ] Full Linux and Windows suites pass on the existing Godot 4.5.1 CI pin.
- [ ] Failure artifacts and orphan cleanup remain intact.
- [ ] `0.1.1` archive contains the addon plus README/LICENSE/NOTICE and excludes GdUnit4/tests/project configuration.
- [ ] No installer CLI, npm wrapper, editor dock, or package-management layer was introduced.

## Release Follow-Up

After `0.1.1` is released, submit that release archive to the Godot Asset Library.

The intended consumer path is:

```text
Asset Library
→ Install Godot E2E
→ use it
```

Asset Library is distribution only. Do not add AssetLib-specific runtime code to the addon.
