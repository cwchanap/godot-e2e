# godot-e2e

Native out-of-process end-to-end testing for Godot, using GDScript tests and
GdUnit4. A test starts the same Godot project as a separate child process and
drives it over an authenticated localhost connection.

The 0.1.0 MVP targets Godot 4.5 or newer and GdUnit4 6.x. It keeps GdUnit4 as
the test runner, assertion library, lifecycle, CLI, and reporter; this addon
only supplies the child-process client, automation server, and GdUnit4 suite
base class.

## Install

1. Install GdUnit4.
2. Install/copy addons/gdunit_e2e.
3. Write an E2E test.

There is no editor plugin to enable and godot-e2e does not add an autoload
to your project. The automation server exists only inside child processes
launched by GdUnitE2ETestSuite.

The addon archive does not include GdUnit4, the test fixtures, or the
CI/bootstrap files.

## Minimal test

Put a test under the project's normal GdUnit4 test tree and extend
`GdUnitE2ETestSuite`:

```gdscript
extends GdUnitE2ETestSuite

func test_main_is_ready() -> void:
    var options := E2ELaunchOptions.new()
    options.scene_path = "res://main.tscn"
    var game := await launch_game(options)
    if game == null or is_failure():
        return

    var status = await game.get_property("/root/Main/Status", "text")
    if is_failure():
        return
    assert_str(status).is_equal("ready")
```

`launch_game()` uses the current project and defaults to the fixture scene
(`res://tests/fixtures/minimal/main.tscn` in this repository). That fixture is
not included in the release archive, so installed users must set
`E2ELaunchOptions.scene_path` to a scene owned by their project, such as the
`res://main.tscn` placeholder in the example. Pass an `E2ELaunchOptions` value
when a test needs a different scene or Godot arguments. Every test-owned child
is tracked by the suite.

The `if is_failure(): return` guard matters after `launch_game()` and after a
wrapped remote call. A wrapped API call maps a transport/server error to the
GdUnit4 failure state and returns a safe fallback; continuing to make more
remote calls after that failure can obscure the original error.

## Lifecycle and cleanup

The base suite automatically captures failure artifacts (available diagnostics)
when a test is in the GdUnit4 failure state, then closes and reaps the child.
It writes artifacts under:

```text
test_output/<suite>/<test>/
  screenshot.png
  scene_tree.json
  engine_logs.json
  stdout.log
  stderr.log
```

The first three files are collected while the child is reachable; stdout and
stderr are drained after the child has exited. Capture is best effort, so a
failed diagnostic request never replaces the test's primary failure. Tests
that need diagnostics for a deliberately handled negative response may call
`await capture_failure_artifacts(game)` explicitly.

The base suite also has a final `after()` safety cleanup. If you override
`after_test()` or `after()`, you must await the corresponding super hook:

```gdscript
func after_test() -> void:
    # Test-specific cleanup may go here.
    await super.after_test()

func after() -> void:
    await super.after()
```

The child automation server starts an authenticated-peer orphan watchdog. If
the parent disappears after authentication, the child exits after its grace
period; re-authentication during that period cancels the watchdog. Normal
teardown still closes the child and confirms that its PID is no longer
running.

## Remote API

Use the wrapped `GdUnitE2EGame` methods for common operations. The MVP covers
node/property inspection, method calls, scene changes, input, screenshots,
frame/physics/seconds waits, and waits for nodes, properties, or signals:

```gdscript
assert_bool(await game.node_exists("/root/Main/Button")).is_true()
assert_bool(await game.click_node("/root/Main/Button")).is_true()
assert_bool(await game.wait_for_property(
    "/root/Main/ClickStatus", "text", "clicked", 2.0
)).is_true()
```

For a server command that does not have a wrapper, or for a negative-path
assertion, use the raw escape hatch:

```gdscript
var result: E2EResult = await game.send_command(
    "get_property",
    {"path": "/root/Missing", "property": "text"},
)
assert_bool(result.ok).is_false()
```

`send_command()` returns `E2EResult` and does not automatically fail the
GdUnit4 test. This is intentional for direct protocol checks and handled
negative paths. Wrapped methods do map failed requests to the suite failure
state, as described above.

## Same-project behavior and CI

The child is launched from the same project tree as the test runner. The
client rejects a different project path, and the child uses the repository's
addon rather than a copied fixture addon. The automation server is created
only in the child process, so normal project runs remain ordinary project
behavior.

For local development in this repository, install the pinned GdUnit4 copy and
run the normal suite by directory. Keep the intentional failure fixture out of
this command:

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit -a tests/integration -c
```

The failure harness is a separate check because it must fail intentionally and
exit with status 100:

```bash
set +e
./addons/gdUnit4/runtest.sh -a tests/fixtures/failure_harness_test.gd
status=$?
set -e
test "$status" -eq 100
```

GitHub Actions runs these two commands on both Linux and Windows. Linux uses
Xvfb for the child display; both jobs use the same Bash bootstrap and the
same GdUnit4 6.2.1 pin. Reports and `test_output` are uploaded when a job
fails. Windows hosted execution remains an external CI gate; local macOS
verification does not substitute for it.

## Packaging and attribution

Create the 0.1.1 archive with:

```bash
./scripts/package_release.sh
unzip -l dist/godot-e2e-0.1.1.zip
```

The archive contains only `addons/gdunit_e2e/**`, `README.md`, `LICENSE`, and
`NOTICE`. GdUnit4, tests, reports, `test_output`, and CI/bootstrap files are
deliberately excluded. The adapted server/protocol portions are credited in
`NOTICE` and remain under the Apache License, Version 2.0.

## Deferred after 0.1.0

The MVP intentionally does not include Playwright-style locators, retrying
`expect()` assertions, engine-error-flood detection, a dedicated Godot .NET or
C# fixture, macOS CI, suite-level process reuse/pools/parallel sessions, or
richer trace/diagnostic/editor UX.
