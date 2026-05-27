# container-ports

Tiny stdlib-only Ruby web app that lists running Podman containers and links to
their host-published TCP ports. Auto-refresh is off by default (set `REFRESH`
to a positive number of seconds to enable it).

## Run

```sh
ruby tools/container-ports/server.rb
# open http://127.0.0.1:4567
```

## Env

- `PORT` — listen port (default `4567`)
- `BIND` — bind address (default `127.0.0.1`)
- `REFRESH` — page refresh interval in seconds (default `0`, disabled; set a positive value to enable)

Requires the `podman` CLI on `PATH`. Only TCP ports with a host publish mapping
are linked.
