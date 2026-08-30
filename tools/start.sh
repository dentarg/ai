#!/bin/bash

set -eu

SUDO=""
[[ $EUID -eq 0 ]] || SUDO=sudo

start_service() {
  local service=$1
  local label=$2
  echo "+ Starting ${label}..."
  $SUDO systemctl enable --now --no-block "$service"
}

start_service postgresql PostgreSQL
start_service lavinmq LavinMQ
start_service redis-server Redis

# Serialize bundle install across containers sharing /bundle (BUNDLE_PATH),
# so concurrent installs of the same gem can't corrupt the shared path.
if test -f Gemfile; then
  echo '+ Installing bundle dependencies...'
  flock /bundle/.install.lock bundle install || true
else
  echo '+ Skipping bundle install (Gemfile not found).'
fi
