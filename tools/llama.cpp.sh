#!/bin/sh

set -eu

runtime_args="--rm --interactive"
if [ -t 0 ] && [ -t 1 ]; then
  runtime_args="$runtime_args --tty"
fi

# The word splitting is intentional; runtime_args only contains fixed flags.
# shellcheck disable=SC2086
case "$PWD" in
  /share|/share/*)
    exec docker run $runtime_args \
      --device /dev/dri \
      --env HOME=/tmp \
      --env GGML_VK_DISABLE_F16 \
      --env XDG_RUNTIME_DIR=/tmp \
      --network host \
      --user "$(id -u):$(id -g)" \
      --volume /share:/share \
      --workdir "$PWD" \
      ai-llama.cpp \
      "$(basename "$0")" \
      "$@"
    ;;
  *)
    exec docker run $runtime_args \
      --device /dev/dri \
      --env HOME=/tmp \
      --env GGML_VK_DISABLE_F16 \
      --env XDG_RUNTIME_DIR=/tmp \
      --network host \
      --user "$(id -u):$(id -g)" \
      --volume /share:/share \
      --volume "$PWD:$PWD" \
      --workdir "$PWD" \
      ai-llama.cpp \
      "$(basename "$0")" \
      "$@"
    ;;
esac
