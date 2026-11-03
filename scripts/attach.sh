#!/usr/bin/env bash
# Open Pi's TUI inside the running container. Extra args go to pi
# (e.g. ./scripts/attach.sh --continue, ./scripts/attach.sh -p "list files").
cd "$(dirname "$0")/.."
exec docker compose exec -it agent /docker/pi.sh "$@"
