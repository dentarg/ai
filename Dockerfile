FROM ubuntu:26.04

WORKDIR /tmp/inside_deps
COPY inside_deps/ ./

RUN apt-get update && apt-get install -y \
     build-essential\
     cmake \
     curl \
     gcc \
     git \
     postgresql \
     sudo \
     zsh
RUN sh _mise.sh
RUN sh _rv.sh
RUN $HOME/.cargo/bin/rv ruby install 3.4.7
RUN bash -c 'eval "$($HOME/.cargo/bin/rv shell env bash)" \
    && gem install bundler \
    && ruby --yjit --version \
    && bundle --version'
RUN bash -c 'eval "$($HOME/.local/bin/mise activate bash)" && mise use --global \
      bun \
      crystal \
      go \
      node \
      python \
      rust'
RUN bash -c 'eval "$($HOME/.local/bin/mise activate bash)" \
    && crystal version \
    && go version \
    && node --version \
    && python --version \
    && rustc --version'
RUN bash -c 'eval "$($HOME/.local/bin/mise activate bash)" \
  && npm install -g @anthropic-ai/claude-code \
  && npm install -g @github/copilot \
  && npm install -g @google/gemini-cli'

COPY <<-EOT ~/.bashrc
  echo 'eval "$($HOME/.local/bin/mise activate bash)"'
  echo 'eval "$(rv shell init bash)"'
  echo 'eval "$(rv shell completions bash)"'
EOT
