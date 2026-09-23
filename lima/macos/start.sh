#!/bin/bash
set -eu
export PATH=/opt/homebrew/bin:/opt/homebrew/opt/ruby/bin:$PATH
for service in postgresql@17 lavinmq redis; do
  # System launch daemons work over SSH without a GUI login. Run each
  # service as the guest user, especially PostgreSQL which refuses root.
  sudo -n /opt/homebrew/bin/brew services start "$service" --sudo-service-user="$(id -un)"
done
if [[ -f Gemfile ]]; then
  bundle install
fi
