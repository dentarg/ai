FROM ubuntu:26.04

RUN apt-get update && apt-get install -y --no-install-recommends \
     build-essential\
     cmake \
     curl \
     gcc \
     git \
     jq \
     man-db \
     postgresql \
     sudo \
     unminimize \
     ca-certificates \
     zsh \
     && yes | unminimize \
     && rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV HOME=/workspace
RUN mkdir $HOME
WORKDIR $HOME

COPY inside_deps/ ./
RUN sh _mise.sh
RUN sh _rv.sh
RUN rm _mise.sh \
       _rv.sh

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

COPY <<-EOT /etc/bash.bashrc
  export HISTFILE=/commandhistory/.bash_history
  eval "$($HOME/.local/bin/mise activate bash)"
  eval "$(rv shell init bash)"
  eval "$(rv shell completions bash)"
EOT
