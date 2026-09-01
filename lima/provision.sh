#!/bin/bash

set -euxo pipefail

if [[ -f /var/lib/ai-base-provisioned ]]; then
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
export HOME=/workspace
export USER=root
export BASH_ENV=/workspace/.bash_profile
export RUBIES_DIR=/workspace/.local/share/rv/rubies
: "${AI_VM_USER:?AI_VM_USER is required}"
AI_VM_GROUP=$(id -gn "$AI_VM_USER")

run_as_vm_user() {
  sudo -u "$AI_VM_USER" env \
    HOME=/workspace \
    USER="$AI_VM_USER" \
    LOGNAME="$AI_VM_USER" \
    BASH_ENV=/workspace/.bash_profile \
    RUBIES_DIR="$RUBIES_DIR" \
    "$@"
}

apt-get update
xargs apt-get install -y --no-install-recommends < /tmp/ai-build/ubuntu-packages.txt
yes | unminimize || true

# VM-only packages. Use Ubuntu's maintained Docker stack instead of executing
# the mutable convenience installer from get.docker.com.
xargs apt-get install -y --no-install-recommends < /tmp/ai-build/vm-packages.txt
install -m 644 /tmp/ai-build/zram-generator.conf /etc/systemd/zram-generator.conf
systemctl daemon-reload
systemctl enable --now docker

if [[ -c /dev/dri/renderD128 ]]; then
  docker build \
    --build-arg LLAMA_CPP_VERSION="$(cat /tmp/ai-build/llama.cpp-version)" \
    --file /tmp/ai-build/llama.cpp.Dockerfile \
    --tag ai-llama.cpp \
    /tmp/ai-build
  docker builder prune --force
  install -D -m 755 /tmp/ai-build/llama.cpp.sh \
    /usr/local/libexec/llama.cpp
  ln -s /usr/local/libexec/llama.cpp /usr/local/bin/llama-cli
  ln -s /usr/local/libexec/llama.cpp /usr/local/bin/llama-server
  install -D -m 755 /tmp/ai-build/local-code.sh /usr/local/bin/local-code
  install -D -m 755 /tmp/ai-build/local-code-server.sh \
    /usr/local/bin/local-code-server
  install -D -m 644 /tmp/ai-build/local-code-models.ini \
    /usr/local/share/ai/local-code-models.ini
  install -D -m 644 /tmp/ai-build/pi-duration.ts \
    /usr/local/share/ai/pi-duration.ts
  install -D -m 644 /tmp/ai-build/local-code-server.service \
    /etc/systemd/system/local-code-server.service
  systemctl enable local-code-server.service
  qwen_template_version=$(cat /tmp/ai-build/qwen-chat-template-version)
  curl --fail --location --silent --show-error \
    "https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates/resolve/${qwen_template_version}/chat_template.jinja" \
    --output /tmp/qwen-chat-template.jinja
  install -D -m 644 /tmp/qwen-chat-template.jinja \
    /usr/local/share/ai/qwen-chat-template.jinja
fi

bash /tmp/ai-build/install-chromium.sh /tmp/ai-build/chromium-packages.txt

mkdir -p /workspace "$RUBIES_DIR"
chown -R "$AI_VM_USER:$AI_VM_GROUP" /workspace
cd /workspace
run_as_vm_user bash /tmp/ai-build/workspace.sh \
  /tmp/ai-build \
  /tmp/ai-build/mise-tools.txt \
  /tmp/ai-build/brew-packages.txt \
  /tmp/ai-build/npm-packages.txt \
  /tmp/ai-build/rv-ruby-versions.txt \
  /tmp/ai-build/ruby-build-versions.txt
bash /tmp/ai-build/install-system-tools.sh

# Copy the small utility from its published image now that Docker is available.
amqpcat_container=ai-build-amqpcat
docker create --name "$amqpcat_container" cloudamqp/amqpcat >/dev/null
docker cp "$amqpcat_container:/amqpcat" /usr/bin/amqpcat
docker rm "$amqpcat_container" >/dev/null

run_as_vm_user bash /tmp/ai-build/install-agents.sh \
  "$(cat /tmp/ai-build/codex-version)" \
  "$(cat /tmp/ai-build/claude-version)" \
  /tmp/ai-build/_claude.sh

install -m 755 /tmp/ai-build/start.sh /usr/local/bin/start.sh
install -m 755 /tmp/ai-build/screenshot.sh /usr/local/bin/screenshot.sh
install -m 755 /tmp/ai-build/claude.sh /usr/local/bin/c
install -m 755 /tmp/ai-build/gemini.sh /usr/local/bin/g
install -m 755 /tmp/ai-build/codex.sh /usr/local/bin/cx
install -m 755 /tmp/ai-build/exit.sh /usr/local/bin/x
install -m 755 /tmp/ai-build/loki.sh /usr/local/bin/loki
install -m 755 /tmp/ai-build/op-read.sh /usr/local/bin/op-read
install -m 755 /tmp/ai-build/claude-hook.sh /usr/local/bin/claude-hook
install -m 755 /tmp/ai-build/claude-login.sh /usr/local/bin/claude-login
install -m 755 /tmp/ai-build/codex-login /usr/local/bin/codex-login
install -m 755 /tmp/ai-build/refresh-tokens /usr/local/bin/refresh-tokens
install -m 644 /tmp/ai-build/bashrc /workspace/.bashrc
install -m 644 /tmp/ai-build/gitconfig /etc/gitconfig
install -m 644 /tmp/ai-build/gitignore /etc/gitignore
git lfs install --system

install -m 644 /tmp/ai-build/refresh-tokens.service /etc/systemd/system/refresh-tokens.service
systemctl enable refresh-tokens.service
usermod -aG docker "$AI_VM_USER"
sudo -u postgres psql --command="CREATE ROLE \"${AI_VM_USER}\" WITH LOGIN SUPERUSER;" || true
chown -R "$AI_VM_USER:$AI_VM_GROUP" /workspace /home/linuxbrew/.linuxbrew
touch /var/lib/ai-base-provisioned
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/ai-build /tmp/*.zip /tmp/*.asc
rm -f /tmp/ai-build-*.tar.gz.b64
