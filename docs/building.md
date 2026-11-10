# Building and updating images

[README](../README.md)

## Published images

The image publishing workflow builds `ghcr.io/dentarg/ai` for Linux AMD64 and
ARM64 on pushes to `main` and manual runs from `main`. After both native
builds pass the agent smoke checks and local session integration tests, it publishes
`latest` and `sha-<full-commit-sha>` multi-platform tags. Docker and Podman
select the matching architecture automatically.

The package is public and supports anonymous downloads. The workflow uses
`GITHUB_TOKEN` with `packages: write`; no registry secret is needed.

```shell
# Download instead of building, keeping the local tag used by the host tools.
podman pull ghcr.io/dentarg/ai:latest
podman tag ghcr.io/dentarg/ai:latest ai:latest

# Inside a Linux VM, download directly into its Docker daemon.
docker pull ghcr.io/dentarg/ai:latest
```

Repeat the pull to update, or use a `sha-<full-commit-sha>` tag to select a
particular source revision. Registry digests can be used for an exact image.
`./build_image` still builds the local `ai:latest` image for development.

## Build prerequisites and commands

Podman is required for the default backend. Ruby or Python 3 is needed on the
host to choose a free primary host port. Lima and `jq` are required for
`--vm`. The optional 1Password bridge also requires 1Password 8 and 1Password
CLI on the host.

```shell
brew install podman
brew install lima jq           # for --vm
brew tap libkrun/krun          # for --vm --gpu
brew trust libkrun/krun
brew install krunkit
brew install 1password-cli # optional

# init the Podman machine, enable zram swap, set kernel.keys quotas
bin/setup-vm

# normal builds use the pinned agent versions in "versions/" and do not
# check upstream "latest" endpoints.
./build_image

# update pinned agents and plugin marketplaces, then rebuild
./build_image --update-agents

# update only one pinned version file
./build_image --update-claude
./build_image --update-codex
./build_image --update-antigravity
./build_image --update-plugins

# rebuild all layers and pull latest base image
./build_image --force

# build the stopped ai-base Lima instance used by bin/ai c --vm
./build_vm

# replace an existing base VM; accepts the same agent update flags
./build_vm --force
./build_vm --force --update-agents
./build_vm --force --update-plugins

# build the separate ai-base-gpu instance with Lima's krunkit driver
./build_vm --gpu
./build_vm --gpu --force
```

See [virtual machines](virtual-machines.md) for backend requirements and
lifecycle, and [local models](local-models.md) for GPU setup.

Provisioning changes must cover the container, both VM backends, and
[Claude cloud setup](cloud-setup.md). See [AGENTS.md](../AGENTS.md) for the
provisioning checks and cache revision rule.
