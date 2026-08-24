# godot-e2e

Native out-of-process end-to-end testing for Godot, with GDScript tests and GdUnit4.

## Planning

The MVP is planning-first. Implementation will stay on the same feature branch and draft PR.

- [Design specification](docs/superpowers/specs/2026-08-23-gdunit-e2e-design.md)
- [Implementation plan](docs/superpowers/plans/2026-08-23-gdunit-e2e-mvp.md)

The design uses [`RandallLiuXin/godot-e2e`](https://github.com/RandallLiuXin/godot-e2e) as the protocol/server reference while replacing the Python/pytest client side with native GDScript and GdUnit4 integration.

## Development

Install the pinned GdUnit4 test dependency and run the addon unit tests with:

```bash
./scripts/bootstrap_gdunit4.sh
./addons/gdUnit4/runtest.sh -a tests/unit/plugin_registration_test.gd
```

The bootstrap script downloads GdUnit4 6.2.1 only for local development and CI; it is ignored from release artifacts.
