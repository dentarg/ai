# Shared terminal sessions

[README](../README.md)

`bin/ai session` runs multiplayer sessions with a shared native terminal. Start sessions
**inside a Linux sandbox VM**, with Docker available. Sessions use
`ghcr.io/dentarg/ai:latest` by default and pull it if missing from the VM's
Docker daemon. Pull explicitly to update a cached image. Use `--image ai:latest`
to use a local development build, or `--image ghcr.io/dentarg/ai:sha-<commit>`
to select a published revision. An image on the host's Podman daemon is not
automatically available in the VM.
Use `--keep-vm` when launching the VM: terminal detachment does not override
the outer launcher's VM cleanup policy.

Each session runs its agent in a separate Docker container. Local and invited
remote participants attach to the same native agent UI and type freely.

```shell
# Run from this repository inside the VM; choose the agent's working directory.
bin/ai session start demo --workspace /repos/demo -- c myprofile

# Start without attaching, and publish a web app on an unused VM loopback port.
bin/ai session start web --workspace /repos/web --detach --port 3000 -- cx myprofile

# From another terminal in the same VM:
bin/ai session list
bin/ai session attach demo
bin/ai session attach demo --read-only
bin/ai session ports web
```

Detach with **Ctrl+b, then d**. Ctrl+C still reaches the agent. Everyone
shares one input buffer; coordinate typing out of band. Writable clients
can also use tmux commands inside the agent container. Read-only attachment
is a local convenience, not a remote authentication boundary. Viewer
terminals do not resize the shared screen; the latest active writable
client determines its size.
Use **Ctrl+b, then i** to redisplay the session information without leaving
the terminal. The owner can list invitations or retrieve the same invitation
from another VM terminal.

The image must contain Bash, tmux, util-linux (`script`), and the requested
agent command. `--image` selects another image. The normal agent wrappers
and shell configuration are loaded, but the container runs without systemd
or automatic database startup. Supporting services belong in the VM.
Neither the Docker socket nor the VM's home directory is mounted into it.

`--settings` selects the settings directory (default `/settings`), mounted
read-only. Everyone with write access to the terminal can use the credentials
in that directory. Agent history, bundle cache, and shell history are isolated
per session. Token changes stay in the session; syncing refreshed credentials
back to the read-only settings directory is not supported in this first slice.

Repeat `--port` (also accepted as `--ports`) for additional TCP services.
`--port 3000` selects an unused
VM port; `--port 18080:3000` selects VM port 18080 explicitly. Both bind only
to `127.0.0.1` in the VM. Apps must listen on `0.0.0.0` inside the container.
`session ports` prints HTTP preview URLs; the forwarding itself also carries
WebSockets and other TCP protocols.
These are **session** ports: use `session start --port 3000`. The VM launcher's
`--ports` option is not required for Tailcat previews and does not publish a
port from an agent container. Ports must be selected when creating the session.

## Invite remote participants

The VM needs Tailcat (bundled version: v0.7.0), OpenSSH server, and a running systemd
user manager. Enable persistent user services once if needed:
`sudo loginctl enable-linger "$USER"`. The invitation commands run as your
normal VM user and do not change the VM's existing SSH server.

```shell
# On the VM: create one invitation per participant. Repeating this command
# displays the same invitation, including after attaching to the terminal.
bin/ai session invite web alice

# List invitations without displaying credentials.
bin/ai session invitations web

# On the participant's Mac or Linux machine, from a checkout of this repo:
bin/ai session join 'ai-session-v1.REPLACE_WITH_INVITATION' --port 3000

# Or receive the invitation as a file, keeping the credential out of shell
# history and process arguments:
bin/ai session join @alice.invite --port 3000

# Home-relative invitation paths also work:
bin/ai session join @~/Downloads/alice.invite --port 3000

# On the VM: disconnect this invitation's terminal and preview tunnels.
bin/ai session revoke web alice
```

Joining directly from a checkout requires Ruby 3.1 or newer, OpenSSH client, and
`tailcat` on PATH.
On macOS, install Tailcat with `brew install tailcat`
([upstream installation instructions](https://github.com/tailscale/tailcat/blob/main/INSTALL.md)).
`join` checks for missing client tools before attempting a connection.

To keep SSH and Tailcat inside a container, select Podman or Docker:

```shell
bin/ai session join --podman @~/Downloads/alice.invite --port 3000
bin/ai session join --docker @~/Downloads/alice.invite --port 3000

# Use a different local browser port:
bin/ai session join --podman @~/Downloads/alice.invite --port 13000:3000
```

The helper requires Ruby and the selected container engine on the participant's
machine. Start the engine first; for Podman on macOS, run `podman machine start`
after the usual initial setup. The helper runs `ghcr.io/dentarg/ai:latest`,
mounts the invitation read-only, sets the preview bind address, and publishes
ports only on host loopback. Repeat `--port` for more apps, or omit it for
terminal-only access. `--image IMAGE`
selects a different participant image. A missing image is pulled automatically;
use `podman pull ghcr.io/dentarg/ai:latest` or `docker pull ghcr.io/dentarg/ai:latest`
to refresh an already cached image.

Participants can also join using Docker without cloning this repository or
installing Ruby or Tailcat locally. Save the invitation as a file, then run:

```shell
docker pull ghcr.io/dentarg/ai:latest
docker run --rm --init -it \
  --mount "type=bind,src=$HOME/Downloads/alice.invite,dst=/invitation,readonly" \
  --entrypoint ai-join \
  ghcr.io/dentarg/ai:latest @/invitation
```

To browse an app published by the owner with `session start --port 3000`:

```shell
docker run --rm --init -it \
  --mount "type=bind,src=$HOME/Downloads/alice.invite,dst=/invitation,readonly" \
  --publish 127.0.0.1:3000:3000 \
  --entrypoint ai-join \
  ghcr.io/dentarg/ai:latest @/invitation --port 3000 --bind 0.0.0.0
```

Open `http://127.0.0.1:3000` on the participant's machine. `--bind 0.0.0.0`
lets Docker reach the SSH preview listener inside the client container;
`--publish 127.0.0.1:3000:3000` keeps access on the host limited to localhost.
To use host port 13000, change only the publish mapping to
`127.0.0.1:13000:3000`. Use `--bind 0.0.0.0` only with the container setup;
normal `session join` previews bind to localhost by default.
Detach with **Ctrl+b, then d**. Docker removes the client container and its
temporary credentials; the shared agent keeps running. Run the same command
again to reconnect with the invitation.

An invitation grants access immediately; send it privately through your usual
chat. It contains an SSH private key and a pinned server host key. Anyone with
the invitation can use it, so use a separate participant name for each person.
Invitations remain valid until revoked, the session stops, or the VM shuts down.
The same invitation supports repeated and simultaneous connections while valid.
Revoked participant names cannot be reused until the session is stopped and
started again. Restarting requires fresh invitations; old ones stay revoked.

Tailcat carries an encrypted connection to a dedicated SSH endpoint on VM
loopback. SSH forces terminal attachment inside the agent container and permits
forwarding only to this session's published preview ports. Arbitrary VM commands,
agent forwarding, remote forwarding, and Unix socket forwarding are disabled.
Each invitation has its own systemd service, so revocation also closes existing
connections without interrupting other participants. Share only with trusted
collaborators: terminal writers have the agent container's full capabilities
and can read its mounted credentials and project files.
After revocation, the participant's terminal may take a few seconds to detect
the lost transport and close; access is already stopped on the VM.

`join --port 3000` makes the app available at `http://127.0.0.1:3000` on the
participant's machine while attached. Use `--port 13000:3000` if local port 3000
is occupied, and repeat the option for other published ports. Browser requests
and WebSockets travel through the same authenticated connection. Detaching
closes these tunnels; joining again restores them. The participant's SSH
credentials are saved with private permissions in
`${XDG_CONFIG_HOME:-~/.config}/ai/session-joins/`.

Remote terminal events identify the invitation name, not individual keystrokes.
Detailed bridge diagnostics are available through `journalctl --user -u UNIT`;
the service name is in the invitation's `invitation.json` under session data.

## Session history

```shell
bin/ai session logs demo
bin/ai session logs demo --follow
bin/ai session replay demo
bin/ai session stop demo
```

Use `logs --follow` (or `logs -f`) to print existing lifecycle events and keep
watching for new ones. Press Ctrl+C to stop following.

Session data lives in `/history/multiplayer/<name>` when `/history` exists,
otherwise `$AI_DIR/history/multiplayer/<name>` (`AI_DIR` defaults to `~/ai`).
`AI_SESSION_DIR` overrides this location. It contains the agent's own history,
a terminal output/timing recording, and a logfmt lifecycle log. Raw keystrokes
are not recorded, but text echoed on screen is. Terminal recordings do not
attribute prompts to participants. Replay uses util-linux `scriptreplay` in
the VM. Stopping removes the container while retaining these files. Start a
stopped session again with the same name and an agent command:

```shell
bin/ai session start demo --detach --port 3333 -- cx
```

The saved workspace, image, settings, and port mappings are reused unless
overridden. Supplying `--port` replaces the previous port mappings. Each start
creates a new container and agent process; use the agent's resume option to
continue an earlier conversation. Agent history, shell history, and bundle
cache are retained, but packages installed only in the removed container are
lost. The previous recording, session metadata, and invitation records move
to `runs/<previous-run-id>/` within the session directory. `session replay`
plays the current run's recording. Create new invitations after restarting.
Disconnects preserve running sessions, but VM reboot recovery is not implemented.

## Tests

Run the integration tests without agent credentials or model requests.
The remote tests need the VM services listed above and reach Tailcat's relay
network; the local tests need only Docker and Ruby with Minitest:

```shell
docker build -f tools/session/Dockerfile.test -t ai-session-test:latest tools/session
ruby tools/session/test_session.rb

# Local tests only (also run against each candidate image in CI):
ruby tools/session/test_session.rb --exclude '/remote|tailcat/'

# Include joining through both Docker and Podman helpers with browser preview forwarding:
docker build -t ai-session-client-test:latest .
docker save ai-session-client-test:latest | podman load
AI_SESSION_CLIENT_IMAGE=ai-session-client-test:latest ruby tools/session/test_session.rb
```
