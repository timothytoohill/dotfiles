#!/usr/bin/env bash
#
# Detect the platform and hand off to its setup script.
#
#   ./setup.sh                 auto-detect from /etc/os-release
#   ./setup.sh --dry-run       auto-detect, options forwarded
#   ./setup.sh ubuntu26 -n     force a platform, options forwarded
#
# The platform directory is "<ID><major VERSION_ID>" from /etc/os-release, so
# Ubuntu 26.04 maps to ubuntu26. Adding a new platform is just adding a
# directory with an executable setup.sh in it; nothing here needs to change.

set -Eeuo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

available() {
    local d
    for d in "$REPO_DIR"/*/; do
        [[ -x ${d}setup.sh ]] && printf '  %s\n' "$(basename "$d")"
    done
}

# A leading non-option argument is an explicit platform request. Claim it here
# even when it does not resolve, so an unknown name reports itself as a bad
# platform rather than being forwarded and rejected as an unknown option.
target=''
if [[ ${1:-} && ${1:0:1} != - ]]; then
    target=$1
    shift
elif [[ -r /etc/os-release ]]; then
    target=$(
        . /etc/os-release
        version=${VERSION_ID:-}
        printf '%s%s' "${ID:-unknown}" "${version%%.*}"
    )
fi

if [[ -z $target || ! -x "$REPO_DIR/$target/setup.sh" ]]; then
    printf 'error: no setup script for platform '\''%s'\''\n\n' "${target:-unknown}" >&2
    printf 'available platforms:\n' >&2
    available >&2
    printf '\nusage: %s [platform] [options]\n' "${0##*/}" >&2
    exit 1
fi

exec "$REPO_DIR/$target/setup.sh" "$@"
