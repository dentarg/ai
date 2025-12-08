#!/bin/bash

set -eux

service postgresql start
exec "$@"
