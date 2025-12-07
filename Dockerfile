FROM ubuntu:26.04

ARG RUBY_VERSION=3.4.7

RUN apt-get update && apt-get install -y --no-install-recommends \
     build-essential\
     ca-certificates \
     cmake \
     curl \
     gcc \
     git \
     jq \
     libpq-dev \
     libyaml-dev \
     man-db \
     postgresql \
     sudo \
     unminimize \
     vim \
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
COPY <<-EOT /etc/bash.bashrc
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

RUN bash -c "brew install crystal"
RUN bash -c "crystal --version"

COPY profile.bashrc /etc/profile.bashrc
