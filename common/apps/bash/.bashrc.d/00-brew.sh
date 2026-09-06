# shellcheck shell=bash
# Homebrew environment: PATH, MANPATH, INFOPATH, HOMEBREW_PREFIX.
#
# Numbered 00 so brew's bin lands on PATH before any later drop-in that might
# want to probe for a brew-installed tool. Guarded on the binary existing, so
# this file is harmless on a machine where Homebrew has not been installed yet
# -- which matters because setup.sh copies it into place before the Homebrew
# stage has necessarily run.
#
# "brew shellenv" is NOT idempotent, contrary to what this comment used to
# claim. It emits an unconditional prepend:
#
#   export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin${PATH+:$PATH}"
#
# so it is a no-op only when Homebrew already sits at the front. Evaluate it
# again with anything ahead of Homebrew and that entry gets jumped, leaving a
# duplicate behind: proto:brew:... becomes brew:proto:brew:...
#
# Anything that must outrank Homebrew therefore has to assert itself in a
# later-numbered drop-in; see 90-proto.sh.

if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
elif [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv bash)"
fi
