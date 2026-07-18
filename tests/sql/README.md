# SQL Tests

These fixtures exercise the installed validation, compiler, and materialization
surfaces against the bundled sales model. They are executed by
`tools/run_nano_smoke.sh` after the corresponding catalog state is installed.

- `validation_smoke.sql` checks live validation and matrix output.
- `compile_request_smoke.sql` checks the structured compiler SQL script.
- `materialization_smoke.sql` checks registration and both compiler entry points.
