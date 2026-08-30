FROM ubuntu:26.04

COPY inside_deps/ubuntu-packages.txt /tmp/ubuntu-packages.txt
RUN apt-get update \
     && xargs apt-get install -y --no-install-recommends < /tmp/ubuntu-packages.txt \
     && yes | unminimize \
     && rm -rf /var/lib/apt/lists /var/cache/apt/archives /tmp/ubuntu-packages.txt

COPY inside_deps/chromium-packages.txt /tmp/chromium-packages.txt
COPY inside_deps/install-utils.sh \
     inside_deps/install-chromium.sh \
     /tmp/ai-build/
RUN bash /tmp/ai-build/install-chromium.sh /tmp/chromium-packages.txt \
    && rm -rf /tmp/ai-build /tmp/chromium-packages.txt

ENV HOME=/workspace
ENV RUBIES_DIR="${HOME}/.local/share/rv/rubies"
RUN mkdir $HOME
WORKDIR $HOME

COPY inside_deps/workspace.sh \
     inside_deps/mise-tools.txt \
     inside_deps/brew-packages.txt \
     inside_deps/npm-packages.txt \
     inside_deps/rv-ruby-versions.txt \
     inside_deps/ruby-build-versions.txt \
     inside_deps/_brew.sh \
     inside_deps/_mise.sh \
     inside_deps/_nvm.sh \
     inside_deps/_rv.sh \
     /tmp/ai-build/

# Homebrew always installs under /home/linuxbrew/.linuxbrew. Keep the expensive
# user-space toolchain recipe shared with the Lima VM.
ENV BASH_ENV="/workspace/.bash_profile"
RUN bash /tmp/ai-build/workspace.sh \
      /tmp/ai-build \
      /tmp/ai-build/mise-tools.txt \
      /tmp/ai-build/brew-packages.txt \
      /tmp/ai-build/npm-packages.txt \
      /tmp/ai-build/rv-ruby-versions.txt \
      /tmp/ai-build/ruby-build-versions.txt \
    && rm -rf /tmp/ai-build

COPY inside_deps/install-utils.sh \
     inside_deps/install-system-tools.sh \
     /tmp/ai-build/
RUN bash /tmp/ai-build/install-system-tools.sh && rm -rf /tmp/ai-build

# amqpcat - AMQP CLI tool
COPY --from=cloudamqp/amqpcat /amqpcat /usr/bin/amqpcat

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
PassEnvironment=HOST_DIR PORT CLAUDE_PROFILE CLAUDE_RESUME CODEX_AUTO_START CODEX_RESUME AI_REMOTE AI_FAST OP_BRIDGE_URL OP_BRIDGE_TOKEN OP_BRIDGE_CA
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

COPY inside_deps/refresh-tokens.service /etc/systemd/system/refresh-tokens.service
RUN systemctl enable refresh-tokens.service

#
# Coding agents (Claude Code, Codex)
#
# Agent versions are pinned in versions/ and refreshed by build_image flags.

# Codex — npm global, pinned version
COPY versions/codex /tmp/codex-version
COPY versions/claude-code /tmp/claude-version
COPY inside_deps/_claude.sh /tmp/claude-installer.sh
COPY inside_deps/install-agents.sh /tmp/install-agents.sh
RUN bash /tmp/install-agents.sh \
      "$(cat /tmp/codex-version)" \
      "$(cat /tmp/claude-version)" \
      /tmp/claude-installer.sh \
    && rm /tmp/codex-version /tmp/claude-version \
          /tmp/claude-installer.sh /tmp/install-agents.sh

# Claude Code plugins — every marketplace pinned in versions/claude-plugins is
# cloned in and its plugins exposed under /opt/claude-plugins/enabled, which
# tools/claude.sh links into each session's ~/.claude/skills/. They then load in
# every project with no marketplace registration and no per-project config.
#
# Deliberately not "claude plugin install": ~/.claude is a fresh per-session
# directory (see tools/claude.sh), and an install writes marketplace and install
# records full of absolute paths into it — all discarded on the next launch.
COPY inside_deps/_claude_plugins.sh ./
COPY versions/claude-plugins /tmp/claude-plugins
RUN bash _claude_plugins.sh /tmp/claude-plugins /opt/claude-plugins \
    && rm _claude_plugins.sh /tmp/claude-plugins

# created by claude native installer and by the plugin validation above
RUN rm -rf $HOME/.claude $HOME/.claude.json

# last, so editing the blocklist doesn't re-clone the marketplaces above
COPY claude/plugins.blocklist /opt/claude-plugins/blocklist

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
COPY ./tools/op-read.sh /usr/local/bin/op-read
COPY ./tools/claude-hook.sh /usr/local/bin/claude-hook
COPY ./tools/claude-login.sh /usr/local/bin/claude-login
COPY dot.bashrc $HOME/.bashrc
COPY .gitconfig /etc/gitconfig
RUN git lfs install --system \
    && test "$(git config --system --get filter.lfs.process)" = "git-lfs filter-process"
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
             /usr/local/bin/op-read \
             /usr/local/bin/claude-hook \
             /usr/local/bin/claude-login \
             /usr/local/bin/codex-login \
             /usr/local/bin/refresh-tokens

# Quiet systemd: hide status messages and the INFO-level boot banner
# (systemd version, detected virtualization/architecture, "Queued start job…").
RUN mkdir -p /etc/systemd/system.conf.d && \
    printf '[Manager]\nShowStatus=no\nLogLevel=warning\n' > /etc/systemd/system.conf.d/hide-status.conf

CMD ["/sbin/init"]
