#!/bin/bash

set -eux

systemctl enable --now --no-block postgresql
systemctl enable --now --no-block lavinmq
# Serialize bundle install across containers sharing /bundle (BUNDLE_PATH),
# so concurrent installs of the same gem can't corrupt the shared path.
test -f Gemfile && flock /bundle/.install.lock bundle install || true
