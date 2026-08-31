# Output failure fixtures

These fixtures exercise four focused execution flows in each output mode:

- `hola run diagnostics`: one task containing handled command, filesystem,
  rescue, guard, and nested-resource failures.
- `hola run abort`: one unhandled nested-resource failure.
- `hola provision provision.rb`: one converge containing handled failures.
- `hola provision provision_abort.rb`: one fatal converge.

Build Hola, then run one mode at a time:

```bash
zig build
./test/output_failures/run.sh normal
./test/output_failures/run.sh compact
```

Run both modes with:

```bash
./test/output_failures/run.sh both
```

The driver verifies exit statuses silently and reports only mismatches. It uses
only `/tmp/hola-output-failures` and removes that directory between flows.
Run it as a normal user so the permission-denied case remains meaningful. Set
`HOLA_BIN=/absolute/path/to/hola` to test a different binary.

Individual cases can also be run directly:

```bash
./zig-out/bin/hola-macos-aarch64 run \
  --holafile test/output_failures/Holafile \
  --output normal diagnostics

./zig-out/bin/hola-macos-aarch64 provision \
  --output compact test/output_failures/provision.rb
```
