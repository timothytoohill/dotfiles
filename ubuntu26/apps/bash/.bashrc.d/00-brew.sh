# Homebrew environment: PATH, MANPATH, INFOPATH, HOMEBREW_PREFIX.
#
# Numbered 00 so brew's bin lands on PATH before any later drop-in that might
# want to probe for a brew-installed tool. Guarded on the binary existing, so
# this file is harmless on a machine where Homebrew has not been installed yet
# -- which matters because setup.sh copies it into place before the Homebrew
# stage has necessarily run.
#
# "brew shellenv" is itself idempotent: it prepends only when absent, so
# re-sourcing this file cannot grow PATH.

if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv bash)"
elif [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv bash)"
fi
