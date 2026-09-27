# Browser recorder

Run this from the repository while the authenticated host browser is available:

```sh
./tools/browser-recorder/browser-recorder
```

The recorder writes one JSONL file to the current directory. Pass
`--output-dir DIR` or set `RECORDING_OUTPUT_DIR` to choose another directory.
Press Ctrl-C to flush and stop it.
The logs include sensitive browser data such as cookies, headers, request and
response bodies, typed form values, clipboard contents, and selected file
contents. Files are created with owner-only permissions. Use `--output-dir` to
keep recordings outside the current directory.

Request and response bodies, form values, clipboard data, and selected file
contents are captured by default. Set the corresponding `CAPTURE_*` variable
to `false` to omit that data. DOM snapshots and high-frequency pointer or
mouse events are off by default to keep logs manageable:

- `DOM_SNAPSHOTS=none` (default) records element metadata only.
- `DOM_SNAPSHOTS=actions` adds full snapshots for interactive actions.
- `DOM_SNAPSHOTS=all` snapshots every recorded interaction and its event path.
- `CAPTURE_HIGH_FREQUENCY_EVENTS=true` adds pointer and mouse move, enter,
  leave, over, and out events.

Set `RECORDING_ID` to choose the filename suffix. The executable accepts
`--id`, `--output-dir`, and `--dom-snapshots none|actions|all`. Use
`--capture-high-frequency-events` to include pointer and mouse movement events,
or the `--no-request-bodies`, `--no-response-bodies`, `--no-form-values`,
`--no-clipboard`, and `--no-file-contents` options to reduce captured data.
Run `./tools/browser-recorder/browser-recorder --help` for the full option list.
