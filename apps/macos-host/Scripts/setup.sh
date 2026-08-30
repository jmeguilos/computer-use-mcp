#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_dir/../../.." && pwd -P)"
canonical_setup="$repository_root/scripts/setup-local.sh"

[[ -x "$canonical_setup" && ! -L "$canonical_setup" ]] || {
  echo "canonical setup script is missing, non-executable, or symlinked: $canonical_setup" >&2
  exit 1
}

exec "$canonical_setup" --adhoc-sign "$@"
