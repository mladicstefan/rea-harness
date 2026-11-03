#!/usr/bin/env bash
# Launch Pi with the harness defaults. Extra arguments are passed through.
exec pi --thinking "${PI_THINKING:-off}" "$@"
