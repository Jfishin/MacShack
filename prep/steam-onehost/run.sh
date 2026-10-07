#!/bin/bash
# Runs Steam in one process (build.sh installs it first). Quit the normal Steam before; extra arguments go to Steam.
# A clean environment, so nothing from the calling shell leaks into Steam or the games it starts.
# -ApplePersistenceIgnoreState: the host lives in Steam's bundle, so a killed run would otherwise make macOS offer to
# "reopen Steam's windows" at the next launch.
exec env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="$TMPDIR" \
  LANG=en_US.UTF-8 SHELL=/bin/zsh ${ONEHOST_HELPER_ARG:+"ONEHOST_HELPER_ARG=$ONEHOST_HELPER_ARG"} ${ONEHOST_NO_SPAWN:+ONEHOST_NO_SPAWN=1} \
  "$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/shacksteam" \
  -noverifyfiles -nobootstrapupdate -skipinitialbootstrap -norepairfiles -noarchrestart -cef-enable-debugging \
  -ApplePersistenceIgnoreState YES "$@"
