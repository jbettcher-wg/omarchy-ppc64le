#!/bin/bash
# Repoint absolute /usr paths inside staged pkg-config files at the sysroot.
#
# Most .pc files define prefix=/usr and derive the rest, so rewriting prefix is
# enough. Some (uchardet's, for one) skip prefix entirely and hardcode
# libdir=/usr/lib and includedir=/usr/include, and those silently resolve to the
# *system* paths -- the dependency is "found", and then the compiler cannot find
# the header. So rewrite every absolute directory variable, not just prefix.
set -uo pipefail
SYSROOT=${1:-/home/jbettcher/omarchy-work/sysroot}

for d in "$SYSROOT/usr/lib/pkgconfig" "$SYSROOT/usr/share/pkgconfig" "$SYSROOT/usr/lib/cmake"; do
  [ -d "$d" ] || continue
  find "$d" -name '*.pc' | while read -r pc; do
    sed -i -E "s#^(prefix|exec_prefix|libdir|includedir|datarootdir|datadir|sharedstatedir|sysconfdir)=/usr(/|\$)#\1=$SYSROOT/usr\2#" "$pc"
  done
done
