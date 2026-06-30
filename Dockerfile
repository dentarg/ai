FROM ubuntu:26.04

RUN apt-get update && apt-get install -y --no-install-recommends \
     bat \
     bind9-host \
     build-essential \
     ca-certificates \
     cmake \
     curl \
     ffmpeg \
     file \
     gcc \
     git \
     gpg \
     gpg-agent \
     htop \
     inetutils-traceroute \
     iputils-ping \
     iputils-tracepath \
     jq \
     less \
     libbpf1 \
     libcurl4-openssl-dev \
     liblz4-dev \
     libpq-dev \
     libyaml-dev \
     libzstd-dev \
     lsof \
     man-db \
     netcat-openbsd \
     openjdk-21-jdk-headless \
     openssh-client \
     pandoc \
     postgresql \
     ragel \
     rdap \
     redis-server \
     ripgrep \
     rsync \
     shellcheck \
     silversearcher-ag \
     strace \
     sudo \
     systemd \
     systemd-sysv \
     tmux \
     tree \
     unminimize \
     unzip \
     vim \
     wget \
     whois \
     zip \
     zlib1g-dev \
     zsh \
     && yes | unminimize \
     && rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Ubuntu ships bat's binary as "batcat"; expose it under the expected name
RUN ln -s /usr/bin/batcat /usr/local/bin/bat

# Install Chromium dependencies and browser from Debian sid
# (Ubuntu's chromium-browser is a snap wrapper that won't work in containers)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    ca-certificates \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libasound2t64 \
    libpango-1.0-0 \
    libcairo2 \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# Add Debian sid repository for Chromium (Ubuntu snaps don't work in containers)
RUN curl -fsSL "https://ftp-master.debian.org/keys/archive-key-12.asc" -o /tmp/debian.asc \
    && gpg --batch --yes --dearmor -o /usr/share/keyrings/debian-archive.gpg /tmp/debian.asc \
    && echo "deb [signed-by=/usr/share/keyrings/debian-archive.gpg] http://deb.debian.org/debian sid main" > /etc/apt/sources.list.d/debian-sid.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends chromium \
    && rm -rf /var/lib/apt/lists/* /tmp/debian.asc

ENV HOME=/workspace
ENV RUBIES_DIR="${HOME}/.local/share/rv/rubies"
RUN mkdir $HOME
WORKDIR $HOME

COPY inside_deps/_brew.sh \
     inside_deps/_mise.sh \
     inside_deps/_nvm.sh \
     inside_deps/_rv.sh \
     ./

RUN bash _brew.sh
RUN bash _nvm.sh
RUN sh _mise.sh
RUN sh _rv.sh
RUN rm _brew.sh \
       _mise.sh \
       _nvm.sh \
       _rv.sh

# Homebrew does not let you pick HOMEBREW_PREFIX on Linux, always /home/linuxbrew/.linuxbrew
# $HOME must be set to run brew
COPY <<-EOT /workspace/.bash_profile
export HOME=/workspace
export PATH=$PATH:/workspace/.cargo/bin

eval "$($HOME/.cargo/bin/rv shell init bash)"
eval "$($HOME/.cargo/bin/rv shell completions bash)"

eval "$($HOME/.local/bin/mise activate bash)"
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

source /workspace/.nvm/nvm.sh
EOT

# BASH_ENV makes non-interactively shells source this file
ENV BASH_ENV="/workspace/.bash_profile"

RUN bash -c "brew --version"
RUN bash -c "mise --version"
RUN bash -c "rv --version"

RUN bash -c "mise use --global bun"
RUN bash -c "mise use --global go"
RUN bash -c "mise use --global python"
RUN bash -c "mise use --global rust"

RUN bash -c "go version"
RUN bash -c "python --version"
RUN bash -c "rustc --version"

RUN bash -c "nvm install 22"
RUN bash -c "npm install -g npm@11"
RUN bash -c "node -v"
RUN bash -c "npm -v"

RUN bash -c "brew install ast-grep"
RUN bash -c "ast-grep --version"

RUN bash -c "npm install -g @github/copilot"
RUN bash -c "npm install -g @google/gemini-cli"

RUN bash -c "rv ruby install 3.4.7"
RUN bash -c "rv ruby install 3.4.8"
RUN bash -c "rv ruby install 3.4.9"
RUN bash -c "rv ruby install 4.0.2"
RUN bash -c "rv ruby install 4.0.3"
RUN bash -c "rv ruby install 4.0.5"
RUN bash -c "rv run ruby --yjit --version"
RUN bash -c "rv run bundle --version"

# Install chruby per https://gist.github.com/dentarg/79aae28811c290b7a6a96ab4fafd4197
RUN bash -c "git clone --branch do-no-set-gem-home https://github.com/eregon/chruby.git"

# JRuby via ruby-build
RUN bash -c "git clone https://github.com/rbenv/ruby-build.git"
RUN bash -c "ruby-build/bin/ruby-build jruby-10.0.4.0 $RUBIES_DIR/jruby-10.0.4.0"

# TruffleRuby via ruby-build
RUN bash -c "ruby-build/bin/ruby-build truffleruby-34.0.1 $RUBIES_DIR/truffleruby-34.0.1"

# Install puppeteer-core (uses system Chromium instead of bundling its own)
RUN bash -c "npm install -g puppeteer-core"

# Crystal
RUN curl --location https://packagecloud.io/84codes/crystal/gpgkey | gpg --dearmor > /etc/apt/trusted.gpg.d/84codes_crystal.gpg
COPY <<-EOT /etc/apt/sources.list.d/84codes_crystal.list
deb https://packagecloud.io/84codes/crystal/ubuntu noble main
EOT
RUN apt-get update && apt-get install -y --no-install-recommends crystal
RUN bash -c "crystal --version"

# PostgreSQL
RUN sed -i 's/scram-sha-256/trust/' /etc/postgresql/*/main/pg_hba.conf
RUN service postgresql start && sudo -u postgres psql --command='CREATE ROLE root WITH LOGIN SUPERUSER;'

# LavinMQ
RUN curl --location https://packagecloud.io/cloudamqp/lavinmq/gpgkey | gpg --dearmor > /usr/share/keyrings/lavinmq.gpg
# no resolute packages yet
COPY <<-EOT /etc/apt/sources.list.d/lavinmq.list
deb [signed-by=/usr/share/keyrings/lavinmq.gpg] https://packagecloud.io/cloudamqp/lavinmq/ubuntu noble main
EOT
RUN apt-get update && apt-get install -y --no-install-recommends lavinmq

# amqpcat - AMQP CLI tool
COPY --from=cloudamqp/amqpcat /amqpcat /usr/bin/amqpcat

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# glow - terminal markdown renderer (Charm apt repo)
RUN curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/charm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
        > /etc/apt/sources.list.d/charm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends glow \
    && rm -rf /var/lib/apt/lists/* \
    && glow --version

# Loki logcli
# https://github.com/grafana/loki/releases
# sha256 from the SHA256SUMS file published with the release
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
         amd64) sha256="7850d566d2af10d7adf255ed9452de632ab20c0f269dc61fac7f70bed4d99e48" ;; \
         arm64) sha256="2fec7cbf4c0929f2fbd1e339753b14bc6432aadb41abf4b4155b00d3f6509e4e" ;; \
         *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://github.com/grafana/loki/releases/download/v3.7.2/logcli-linux-${arch}.zip" -o /tmp/logcli.zip \
    && echo "${sha256}  /tmp/logcli.zip" | sha256sum -c - \
    && unzip -p /tmp/logcli.zip "logcli-linux-${arch}" > /usr/local/bin/logcli \
    && chmod +x /usr/local/bin/logcli \
    && rm /tmp/logcli.zip \
    && logcli --version

# mitmproxy
RUN bash -c "pip install mitmproxy"

# we don't want to wait when starting the container
RUN systemctl disable postgresql lavinmq redis-server

#
# systemd
#

# Default is SIGTERM (15), but systemd ignores that. Systemd expects SIGRTMIN+3 (37) to initiate a clean shutdown
# Without it, podman would send SIGTERM, systemd ignores it, then after a timeout podman sends SIGKILL
STOPSIGNAL SIGRTMIN+3

# disables login prompt
RUN systemctl mask getty.target console-getty.service

# this gets us the behaviour we had without systemd: a shell is started, container stops when we exit the shell
COPY <<-EOT /etc/systemd/system/shell.service
[Unit]
Description=Interactive Shell
After=multi-user.target

[Service]
Type=simple
Environment=HOME=$HOME
PassEnvironment=HOST_DIR PORT CLAUDE_PROFILE CLAUDE_RESUME CODEX_AUTO_START
ExecStart=/bin/bash
WorkingDirectory=/app
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/console
TTYReset=yes
TTYVHangup=yes
# Quiet the harmless "Failed to make mounts private" warning systemd-shutdown
# emits in the unprivileged container; it inherits the manager log level.
ExecStopPost=/usr/bin/systemctl log-level err
ExecStopPost=/bin/kill -37 1

[Install]
WantedBy=multi-user.target
EOT

RUN systemctl enable shell.service

# Token refresh service
COPY <<-EOT /etc/systemd/system/refresh-tokens.service
[Unit]
Description=Claude OAuth Token Refresh
After=network.target

[Service]
Type=simple
Environment=HOME=$HOME
ExecStart=/usr/local/bin/refresh-tokens --daemon
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOT

RUN systemctl enable refresh-tokens.service

#
# Coding agents (Claude Code, Codex)
#
# Agent versions are pinned in versions/ and refreshed by build_image flags.

# Codex — npm global, pinned version
COPY versions/codex /tmp/codex-version
RUN bash -c 'npm install -g "@openai/codex@$(cat /tmp/codex-version)"' \
    && rm /tmp/codex-version

# Claude Code — official installer, asked to install the pinned version
COPY inside_deps/_claude.sh ./
COPY versions/claude-code /tmp/claude-version
RUN bash _claude.sh "$(cat /tmp/claude-version)" \
    && rm _claude.sh /tmp/claude-version
# created by claude native installer
RUN rm -rf $HOME/.claude

# Claude Code plugins
# RUN bash -c "claude plugin marketplace add https://github.com/anthropics/claude-code"
# RUN bash -c "claude plugin install ralph-wiggum@claude-code-plugins"

ENV LANG C.UTF-8
ENV LC_ALL C.UTF-8

# do this late to allow tweaking without rebuilding previous layers
COPY ./tools/start.sh /usr/local/bin/start.sh
COPY ./tools/screenshot.sh /usr/local/bin/screenshot.sh
COPY ./tools/claude.sh /usr/local/bin/c
COPY ./tools/gemini.sh /usr/local/bin/g
COPY ./tools/codex.sh /usr/local/bin/cx
COPY ./tools/exit.sh /usr/local/bin/x
COPY ./tools/loki.sh /usr/local/bin/loki
COPY ./tools/claude-hook.sh /usr/local/bin/claude-hook
COPY ./tools/claude-login.sh /usr/local/bin/claude-login
COPY dot.bashrc $HOME/.bashrc
COPY .gitconfig /etc/gitconfig
COPY gitignore-global /etc/gitignore
COPY bin/codex-login /usr/local/bin/codex-login
COPY bin/refresh-tokens /usr/local/bin/refresh-tokens
RUN chmod +x /usr/local/bin/start.sh \
             /usr/local/bin/screenshot.sh \
             /usr/local/bin/c \
             /usr/local/bin/g \
             /usr/local/bin/cx \
             /usr/local/bin/x \
             /usr/local/bin/loki \
             /usr/local/bin/claude-hook \
             /usr/local/bin/claude-login \
             /usr/local/bin/codex-login \
             /usr/local/bin/refresh-tokens

# Quiet systemd: hide status messages and the INFO-level boot banner
# (systemd version, detected virtualization/architecture, "Queued start job…").
RUN mkdir -p /etc/systemd/system.conf.d && \
    printf '[Manager]\nShowStatus=no\nLogLevel=warning\n' > /etc/systemd/system.conf.d/hide-status.conf

CMD ["/sbin/init"]
