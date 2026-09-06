#!/usr/bin/env bash
#
# Ubuntu 26.04.
#
# Everything here lives beside this file: apt.txt, apt-remove.txt, brew.txt,
# and an optional apps/ directory for configs specific to this platform.
# Configs shared with every other platform live in ../common/apps.

set -Eeuo pipefail

PLATFORM_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# These three are read by lib/setup-lib.sh, sourced at the end of this file.
# shellcheck disable=SC2034
EXPECTED_ID=ubuntu
# shellcheck disable=SC2034
EXPECTED_NAME="Ubuntu"

# shellcheck source=/dev/null
. "$(dirname "$PLATFORM_DIR")/lib/setup-lib.sh"
