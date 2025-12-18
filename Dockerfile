FROM ubuntu:26.04

ARG RUBY_VERSION=3.4.7

RUN apt-get update && apt-get install -y --no-install-recommends \
     bind9-host \
     build-essential \
     ca-certificates \
     cmake \
     curl \
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
     openssh-client \
     postgresql \
     strace \
     sudo \
     systemd \
     systemd-sysv \
     unminimize \
     vim \
     zlib1g-dev \
     zsh \
     && yes | unminimize \
     && rm -rf /var/lib/apt/lists /var/cache/apt/archives

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
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  eval "$($HOME/.local/bin/mise activate bash)"
  eval "$($HOME/.cargo/bin/rv shell init bash)"
  eval "$($HOME/.cargo/bin/rv shell env bash)"
  eval "$($HOME/.cargo/bin/rv shell completions bash)"

  test -f /etc/profile.bashrc && source /etc/profile.bashrc
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

RUN bash -c "rv ruby install $RUBY_VERSION"
RUN bash -c "gem install bundler"
RUN bash -c "ruby --yjit --version"
RUN bash -c "bundle --version"

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

# LavinMQ shutdown timeout override (reduces 90s default to 5s)
# https://github.com/dentarg/ai/issues/1
RUN <<-EOT
mkdir -p /etc/systemd/system/lavinmq.service.d
cat > /etc/systemd/system/lavinmq.service.d/timeout.conf <<CONF
[Service]
TimeoutStopSec=5
CONF
EOT

# we don't want to wait when starting the container
RUN systemctl disable postgresql lavinmq

# convenience script to start services
COPY ./start.sh /start.sh
RUN chmod +x /start.sh

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
ExecStopPost=/usr/bin/systemctl poweroff --force

[Install]
WantedBy=multi-user.target
EOT

RUN systemctl enable shell.service

# do this late to allow tweaking without rebuilding previous layers
COPY profile.bashrc /etc/profile.bashrc

CMD ["/sbin/init"]
