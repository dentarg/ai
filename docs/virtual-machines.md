# Virtual machines

[README](../README.md)

Build a base once with `./build_vm` or `./build_vm --macos`, then launch with `bin/ai c --vm` or `bin/ai c --macos`. See [building](building.md) for installation and update commands.

## Linux Lima VM backend

`build_vm` provisions the expensive language runtimes and development tools
once, verifies Docker and the coding agents, stops the resulting `ai-base`
instance, and protects it from accidental deletion. `bin/ai c --vm` clones that
base for each session, adds the same `/app`, `/settings`, `/history`, `/share`,
and other mounts used by the Podman backend, then deletes the clone when the
interactive shell exits. The image and VM builds share the Chromium, system
tool, language-runtime, coding-agent, and token-refresh service recipes under
`inside_deps/`; only backend-specific setup remains in their provisioners.
The initial build may take a while; `AI_VM_BUILD_TIMEOUT` controls its Lima
startup and provisioning timeout and defaults to `60m`. Long-running
provisioning runs separately from Lima's boot scripts, and `build_vm` streams
its output. This avoids Lima's fixed ten-minute boot-script and cloud-init
progress-monitor limits. The launcher checks the base's provisioning completion
marker before cloning and rejects incomplete builds. After a failed Linux build,
fix the reported error and run `./build_vm --force` (add `--gpu` for a GPU base).

Runtime instances and guest hostnames use `ai-l-XX-<project>` for standard Linux
VMs, `ai-g-XX-<project>` for GPU VMs, and `ai-m-XX-<project>` for macOS VMs.
`XX` is the first available two-digit index for that type and project, and
`project` is the sanitized current directory name, truncated to keep the VM
name within 63 characters.
Guests use UTC, matching the container backend.

VZ runtime clones use Apple's native `vzNAT` networking to avoid Lima's
user-mode TCP forwarding limits. The launcher configures this when cloning,
so existing base VMs do not need rebuilding. Other VM drivers keep their
existing network configuration.

Lima runtime clones forward the primary application port and ports explicitly
requested with `--ports` or `--udp-ports`; other guest ports are not automatically
forwarded. This applies to new clones without rebuilding the base. TCP forwards
bind to host loopback by default. Use
`--udp-ports HOST:CONTAINER` when a guest service needs an externally reachable
UDP port, such as Tailscale's default `41641`. The host-side port must also be
reachable through any outer firewall or NAT device. For Tailscale, use the same
port on both sides and configure the guest daemon to listen on that port.

Ubuntu's `docker.io`, `docker-buildx`, and `docker-compose-v2` packages provide
a rootful Docker stack inside the guest. The normal Lima user belongs to the
`docker` group and has passwordless `sudo`, so tests can exercise a realistic
Docker host without exposing the host Docker or Podman socket. Docker itself
does not require nested virtualization.

Use `--nested-virt` to expose KVM to software that starts another VM inside the
Lima guest. Lima supports this with the `vz` driver on Apple M3 or newer Macs;
the inner VM must use the native architecture. For QEMU, use `-accel kvm -cpu
host`. The option is disabled by default. `--cpus` and `--memory` override the
cloned VM's resources for workloads that need more than the base VM allocation.

For GPU setup and inference, see [local models](local-models.md). For application ports, see [port forwarding](usage.md#port-forwarding).

### Resources and troubleshooting

GPU builds default to 24 CPUs and 48 GiB of memory;
other builds default to 4 CPUs and 8 GiB. These defaults can be changed with
`AI_VM_CPUS`, `AI_VM_MEMORY` (GiB), and `AI_VM_DISK` (GiB); `AI_VM_BASE`
changes the base instance name for both building and launching.

Lima bases enable zram swap sized to half of guest RAM, using zstd compression.
This absorbs temporary memory spikes from compilers and container builds before
the guest has to invoke the OOM killer.

Use `--keep-vm` when diagnosing a guest problem. The launcher prints the
instance name, which can then be opened or removed manually. The launcher also
keeps the VM automatically when its console exits nonzero, preserving guest
logs and Docker build cache for diagnosis.

```shell
# attach to a running VM for the current directory with the sandbox shell
bin/vm

# list instances, select one explicitly, or run a command in one
bin/vm list
bin/vm <instance>
bin/vm <instance> docker ps

limactl stop <instance>
limactl delete <instance>
```

## macOS Lima VM backend

On an Apple-silicon Mac with Lima 2.1 or later and `jq`, build a separate
macOS base and launch an ephemeral session:

```shell
./build_vm --macos
bin/ai c --macos
bin/ai --macos cx work
bin/ai c --macos work --ports 9999,8888:7777
```

The default base is `ai-base-macos`. If tool installation fails, run
`./build_vm --macos --resume` to resend the current build assets and rerun
provisioning in the existing VM, preserving its installed OS and packages.
`--force` deletes and rebuilds it instead; these options cannot be combined.
The existing
`--update-agents`, `--update-claude`, `--update-codex`, `--update-antigravity`,
and `--update-plugins` options also work. `AI_VM_BASE`, `AI_VM_CPUS`,
`AI_VM_MEMORY`, and `AI_VM_DISK`
override the build defaults. `AI_VM_BUILD_TIMEOUT` controls each Lima startup
(default `60m`); subsequent tool installation streams directly over SSH.
The host must support the macOS 26 restore image supplied by the installed
Lima template and run the same or a newer macOS version.

Install full Xcode on the host before building. The build copies
`/Applications/Xcode.app` into the guest; set `AI_VM_XCODE_APP` to use another
Xcode application path. It accepts the Xcode license, installs first-launch
components, and downloads the iOS simulator runtime. The guest includes
`xcodebuild`, Swift, the macOS and iOS SDKs, and `simctl`. Allow space for Xcode
and the simulator on both machines, plus a temporary Xcode archive during the
build. Signing identities and provisioning profiles must be configured
separately for signed device builds and distribution.

Provisioning installs Homebrew, native language tools, the pinned Claude and
Codex versions, Codex plugins, and the shared agent wrappers. The guest user
gets passwordless sudo inside this disposable VM. The build reboots to activate
macOS synthetic links for `/workspace`, `/app`, and the other shared paths,
then verifies the installed tools after another restart before protecting the
base. No desktop login or Lima 2.3 `suppressFirstLoginSetup` setting is required
by this SSH workflow. After startup, the launcher attempts to hide Lima's
macOS display using the host's application API. The window may briefly appear
and take focus before it is hidden; Lima still requires the display to exist.
If that API fails, it tries System Events, which may request Automation or
Accessibility permission for the host terminal. Hiding failures are nonfatal.
The hide attempt times out after five seconds so it cannot block the build.
Set `AI_VM_SHOW_DISPLAY=1` when building or launching to leave it visible.

Profiles, resume, `--keep-vm`, CPU/memory overrides, and the opt-in host bridges
use the existing launcher. TCP ports are forwarded over an SSH tunnel bound to
host loopback; the tunnel closes when the launcher exits, even with `--keep-vm`.
UDP forwarding, `--gpu`, and `--nested-virt` are rejected for this backend.
Native gem caches live in `$AI_DIR/bundle-macos`, separate from Linux gems.
Codex transcripts remain in shared history, while its SQLite runtime databases
live under `~/.codex-state` on the macOS guest disk to avoid shared-filesystem
I/O errors. These local databases are discarded with an ephemeral VM.
`s` starts native PostgreSQL, Redis, and LavinMQ as system launch daemons running
as the guest user, then runs Bundler. The Linux Docker stack and Chromium setup
are not installed in macOS guests; use `--host-browser` for the host browser.

The macOS backend is experimental. Its build/launch command flow is covered by
`bash tools/test_macos_vm.sh`; full installation and agent login still require
verification on an Apple-silicon Mac. See [Lima's macOS guest documentation](https://lima-vm.io/docs/usage/guests/macos/).
