#!/bin/bash

set -eux

systemctl enable --now --no-block postgresql
systemctl enable --now --no-block lavinmq
test -f Gemfile && bundle install || true
