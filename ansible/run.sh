#!/usr/bin/env bash
# Run ansible-playbook with a safe locale to avoid
# "could not initialize the preferred locale" errors on minimal Arch.
set -euo pipefail

cd "$(dirname "$0")"
exec env LANG=C LC_ALL=C ansible-playbook "$@"
