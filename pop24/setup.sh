#!/usr/bin/env bash
#
# Pop!_OS 24.04.
#
# The directory name is not cosmetic: the dispatcher derives it from
# /etc/os-release as "${ID}${VERSION_ID%%.*}", and Pop!_OS reports ID=pop, so
# this must be pop24 rather than popos24 to be found.
#
# Pop!_OS is Ubuntu-derived (ID_LIKE="ubuntu debian"), so apt package names
# largely match, but it tracks 24.04 rather than 26.04 and ships its own
# desktop, kernel and driver packages. That is why it gets its own lists
# instead of reusing Ubuntu's.

set -Eeuo pipefail

PLATFORM_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# These three are read by lib/setup-lib.sh, sourced at the end of this file.
# shellcheck disable=SC2034
EXPECTED_ID=pop
# shellcheck disable=SC2034
EXPECTED_NAME="Pop!_OS"

# shellcheck source=/dev/null
. "$(dirname "$PLATFORM_DIR")/lib/setup-lib.sh"
