#!/bin/zsh
set -euo pipefail
script_directory=${0:A:h}
exec "$script_directory/build_unified_app.sh"
