# shellcheck shell=bash
# proto toolchain shims, forced to the front of PATH.
#
# Numbered 90 so it runs after 00-brew.sh, and it moves the shims rather than
# merely adding them, because the failure mode is proto being present but
# behind Homebrew.
#
# Why this is needed: "brew shellenv" does not leave PATH alone. It emits an
# unconditional prepend --
#
#   export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin${PATH+:$PATH}"
#
# -- so it is only a no-op when Homebrew already happens to sit at the front.
# Evaluate it a second time with anything ahead of Homebrew and that thing gets
# jumped: proto:brew:... becomes brew:proto:brew:... Since Homebrew supplies
# node and pnpm on some machines, that silently swapped proto's pinned
# toolchain for Homebrew's, which is how a project pinned to pnpm 10 ended up
# running pnpm 11.
#
# The invariant this file exists to enforce: version-manager shims win. They
# are asserted last precisely so nothing earlier in ~/.bashrc can outrank them.
#
# Inert when proto is not installed, so it is safe on every machine.

if [ -d "$HOME/.proto/shims" ]; then
    # Strip every existing occurrence, then prepend once. Doing it in that
    # order makes this idempotent and correct whether proto was absent,
    # somewhere in the middle, or already first. The loop covers adjacent
    # duplicates, which a single pass would leave behind: removing ":x:" from
    # ":x:x:" consumes the separator the second entry needs to match on.
    __proto_path=":$PATH:"
    while [ "${__proto_path#*":$HOME/.proto/shims:"}" != "$__proto_path" ]; do
        __proto_path="${__proto_path%%":$HOME/.proto/shims:"*}:${__proto_path#*":$HOME/.proto/shims:"}"
    done
    __proto_path="${__proto_path#:}"
    __proto_path="${__proto_path%:}"

    # The :+ guard avoids a trailing colon when proto was the only entry; an
    # empty PATH element means the current directory.
    # shellcheck disable=SC2123  # setting PATH is the entire point of this file
    PATH="$HOME/.proto/shims${__proto_path:+:$__proto_path}"
    export PATH
    unset __proto_path
fi
