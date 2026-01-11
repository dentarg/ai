FROM ubuntu:26.04

ARG RUBY_VERSION=3.4.8

RUN apt-get update && apt-get install -y --no-install-recommends \
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
     inetutils-traceroute \
     iputils-ping \
     iputils-tracepath \
     jq \
     liblz4-dev \
     libpq-dev \
     libyaml-dev \
     libzstd-dev \
     man-db \
     netcat-openbsd \
     openjdk-21-jre-headless \
     openssh-client \
     pandoc \
     postgresql \
     ripgrep \
     rsync \
     silversearcher-ag \
     strace \
     sudo \
     systemd \
     systemd-sysv \
     tree \
     unminimize \
     vim \
     zlib1g-dev \
     zsh \
     && yes | unminimize \
     && rm -rf /var/lib/apt/lists /var/cache/apt/archives

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
RUN mkdir $HOME
WORKDIR $HOME

COPY inside_deps/ ./
RUN bash _brew.sh
RUN sh _mise.sh
RUN sh _rv.sh
RUN rm _brew.sh \
       _mise.sh \
       _rv.sh

# Homebrew does not let you pick HOMEBREW_PREFIX on Linux, always /home/linuxbrew/.linuxbrew
# $HOME must be set to run brew
COPY <<-EOT /etc/bash.bashrc
  export HOME=/workspace
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  eval "$($HOME/.local/bin/mise activate bash)"
  eval "$($HOME/.cargo/bin/rv shell init bash)"
  eval "$($HOME/.cargo/bin/rv shell env bash)"
  eval "$($HOME/.cargo/bin/rv shell completions bash)"

  test -f /etc/profile.bashrc && source /etc/profile.bashrc
EOT

COPY <<-EOT /etc/zsh/zshrc
  export HOME=/workspace
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  eval "$($HOME/.local/bin/mise activate zsh)"
  eval "$($HOME/.cargo/bin/rv shell init zsh)"
  eval "$($HOME/.cargo/bin/rv shell env zsh)"
  eval "$($HOME/.cargo/bin/rv shell completions zsh)"

  test -f /etc/profile.zshrc && source /etc/profile.zshrc
EOT

# --login needed for rv to be found (?)
# BASH_ENV makes non-interactively shells source this file
ENV BASH_ENV="/etc/bash.bashrc"

RUN bash -c "brew --version"
RUN bash -c "mise --version"
RUN bash --login -c "rv --version"

RUN bash -c "mise use --global bun"
RUN bash -c "mise use --global go"
RUN bash -c "mise use --global node"
RUN bash -c "mise use --global python"
RUN bash -c "mise use --global rust"

RUN bash -c "go version"
RUN bash -c "node --version"
RUN bash -c "python --version"
RUN bash -c "rustc --version"

RUN bash -c "npm install -g @anthropic-ai/claude-code"
RUN bash -c "npm install -g @github/copilot"
RUN bash -c "npm install -g @google/gemini-cli"
RUN bash -c "npm install -g @openai/codex"

RUN bash -c "rv ruby install $RUBY_VERSION"
RUN bash -c "rv ruby install 4.0.0"
RUN bash -c "ruby --yjit --version"
RUN bash -c "bundle --version"

# JRuby via mise (rv doesn't support JRuby)
RUN bash -c "mise use --global ruby@jruby-10.0.2.0"

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
RUN sed -i 's/scram-sha-256/trust/' /etc/postgresql/17/main/pg_hba.conf
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

# we don't want to wait when starting the container
RUN systemctl disable postgresql lavinmq

# convenience script to start services
COPY ./tools/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# convenience script to take browser screenshots
COPY ./tools/screenshot.sh /usr/local/bin/screenshot.sh
RUN chmod +x /usr/local/bin/start.sh

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
ExecStart=/bin/bash
WorkingDirectory=/app
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/console
TTYReset=yes
TTYVHangup=yes
ExecStopPost=/bin/sh -c 'kill -9 -1; systemctl poweroff --force'

[Install]
WantedBy=multi-user.target
EOT

RUN systemctl enable shell.service

# do this late to allow tweaking without rebuilding previous layers
COPY .bashrc /etc/profile.bashrc
COPY .gitconfig /etc/gitconfig

CMD ["/sbin/init"]
