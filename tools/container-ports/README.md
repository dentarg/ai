# container-ports

Tiny stdlib-only Ruby web app that lists running Podman containers and links to
their host-published TCP ports. The page auto-refreshes.

## Run

```sh
ruby tools/container-ports/server.rb
# open http://127.0.0.1:4567
```

## Env

- `PORT` — listen port (default `4567`)
- `BIND` — bind address (default `127.0.0.1`)
- `REFRESH` — page refresh interval in seconds (default `5`)

Requires the `podman` CLI on `PATH`. Only TCP ports with a host publish mapping
are linked.
