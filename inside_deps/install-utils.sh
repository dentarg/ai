#!/bin/bash

download() {
  curl \
    --fail \
    --show-error \
    --silent \
    --location \
    --retry 3 \
    --retry-all-errors \
    "$@"
}
