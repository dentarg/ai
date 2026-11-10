# Local models

[README](../README.md)

Use Pi with llama.cpp in a [GPU VM](virtual-machines.md) or on the macOS host.

## GPU VM setup

GPU acceleration uses a separate `ai-base-gpu` instance because Lima selects
the VM driver when an instance is created. `build_vm --gpu` uses Lima's
experimental `krunkit` driver and verifies that `/dev/dri/renderD128` exists;
`bin/ai c --vm --gpu` clones that base. This requires Apple Silicon, macOS 14 or
newer, and krunkit installed on the host.

The guest receives a paravirtualized Vulkan device rather than direct hardware
passthrough. Vulkan commands travel through Mesa Venus and MoltenVK to the
Apple GPU. Container images therefore need compatible Vulkan userspace drivers
and must receive the device explicitly. Verify the path with the patched Fedora
Mesa image recommended for krunkit:

```shell
docker run --rm --device /dev/dri --env XDG_RUNTIME_DIR=/tmp --entrypoint vulkaninfo quay.io/slopezpa/fedora-vgpu --summary
```

GPU workloads do not use the guest's Ubuntu Mesa because its Venus protocol is
incompatible with krunkit's host-side virglrenderer. They carry compatible Mesa
libraries in their container image, using the patched Fedora image above as a
base when appropriate.

Debian sid supplies Chromium without Ubuntu's snap wrapper. Its repository is
pinned below Ubuntu so installing Chromium cannot upgrade the guest's Mesa and
other base libraries to Debian versions.

## Models and downloads

The GPU base includes a pinned llama.cpp build with Vulkan support. The
`llama-cli` and `llama-server` commands run it in the compatible Fedora image,
pass through `/dev/dri`, and mount both the current directory and `/share`.
Models are deliberately not baked into the ephemeral VM; keep GGUF files under
`/share` so they survive VM rebuilds. `model-download` maps the models used by
this project to pinned downloads, resumes partial files, and verifies their
sizes. Available aliases are:

| Alias | Model |
| --- | --- |
| `qwen3coder` | Qwen3-Coder-Next 80B-A3B Q4_K_M (default) |
| `qwen3coder-q4` | Qwen3-Coder-Next 80B-A3B Q4_K_M |
| `qwen3coder-q5` | Qwen3-Coder-Next 80B-A3B Q5_K_M |
| `gemma4` | Gemma 4 26B-A4B Q4_0 |
| `qwen36` | Qwen3.6 27B Q5_K_M |
| `qwen25tiny` | Qwen2.5 0.5B Instruct Q4_K_M |

For example:

```shell
model-download qwen25tiny /share/models
llama-cli \
  --model /share/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  --gpu-layers 99
```

The wrapper passes `GGML_VK_DISABLE_F16` through when it is set. Hybrid
DeltaNet models such as Qwen3.6 need this Vulkan workaround on the
paravirtualized Apple GPU. Qwen3.6-27B Q5_K_M runs reliably with 36 layers
offloaded, CPU-side KV cache, and reduced batch sizes:

```shell
model-download qwen36 /share/models
GGML_VK_DISABLE_F16=1 llama-cli \
  --model /share/models/Qwen3.6-27B-Q5_K_M.gguf \
  --gpu-layers 36 \
  --no-kv-offload \
  --ctx-size 8192 \
  --batch-size 64 \
  --ubatch-size 32
```

`llama-server` uses host networking, so its default port is directly available
through the VM's configured forwards.

## Shared inference

The GPU base runs a shared, authenticated llama.cpp router as
`local-code-server.service`. Model instances load on demand and unload when a
different model is selected, so multiple Pi sessions share one model allocation.
Qwen3-Coder-Next has one 40K slot and Gemma has one 64K slot. Qwen3-Coder-Next
is the default for repository work; use Gemma for bounded generation, review,
and diagnosis.

The `local-code` client is available in both the VM and the OCI image. It uses
Qwen3-Coder-Next 80B-A3B Q4_K_M by default. The Q4 preset runs on the CPU so it
fits a 48 GiB VM without exhausting virtual GPU memory. Explicit
`qwen3coder-q4` and `qwen3coder-q5` aliases make both quantizations available
without changing the default. Download a model before first use:

```shell
model-download qwen3coder /share/models
local-code
model-download gemma4 /share/models
local-code --model gemma4
```

## Native macOS inference

For productive Qwen3-Coder inference, run llama.cpp natively on the macOS host.
This gives llama.cpp direct Metal access and leaves the VM memory available for
development tools. Install the one build dependency once:

```shell
brew install cmake
```

From this repository on the host, start the recommended Q5 model:

```shell
bin/local-code-host --model qwen3coder-q5
```

The command builds the pinned llama.cpp revision with Metal, downloads and
validates all model shards under `~/ai/share/models`, creates an API key under
`~/ai/share/local-code-host`, and runs the server in the foreground. Subsequent
runs reuse both the build and model. Use `--list-models` to show every available
alias or `--download-only` to prepare a model without starting the server.

In the VM, connect Pi to the host server:

```shell
export LOCAL_CODE_BASE_URL=http://host.lima.internal:8080/v1
export LOCAL_CODE_API_KEY=$(cat /share/local-code-host/api-key)
local-code --model qwen3coder-q5
```

The native server supports every `model-download` alias. Qwen3-Coder Q5 uses
52.8 GiB for weights and is the recommended coding model on a 96 GiB host. Q4
uses 45.1 GiB, Gemma 4 uses 13.4 GiB, Qwen3.6 uses 18.2 GiB, and the tiny Qwen
model uses 0.5 GiB. The Qwen3-Coder and Gemma aliases have tested Pi profiles;
the other aliases are available through the server API.

## Client behavior and tuning

Pi gives the model `read`, `write`, `edit`, and `bash` tools. After each task it
prints a `Cooked for` duration and completion time. Host-networked Docker
containers in the GPU VM can reach the VM-local server at `127.0.0.1:8080`;
set `LOCAL_CODE_BASE_URL` when using a different address. The VM-local API key
defaults to `local` and can be changed with `LOCAL_CODE_API_KEY` on the service
and clients. The native host launcher instead generates a shared random key.
The client reserves 4K tokens for each response. When compacting, it retains the
newest 2K tokens for Qwen and 4K for Gemma. A Pi extension limits reads to 200
lines, blocks unbounded recursive listings, and stops after three consecutive
tool errors. Read limits are clamped to 200 lines, and both models stop at 24
total calls. Qwen compaction creates a small local
checkpoint instead of spending model tokens generating a summary. Gemma uses
Google's pinned canonical chat template and preserves thinking across tool-call
turns. Pi sessions persist under `/history/pi` and appear in the history viewer.

Run the end-to-end smoke test inside a GPU VM to verify that the default model
can inspect a broken JavaScript function, edit it, and pass its test:

```shell
tools/test_local_code_model.sh
```

The Q4 preset is CPU-only for 48 GiB VMs. The Q5 preset fully offloads the
model, and `gemma4` uses 20 GPU layers. To override the selected profile, stop
the service and run the server directly:

```shell
sudo systemctl stop local-code-server
LOCAL_CODE_GPU_LAYERS=18 local-code-server
```
