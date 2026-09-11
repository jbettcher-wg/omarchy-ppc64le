#!/bin/bash
# Repoint absolute /usr paths inside staged pkg-config files at the sysroot.
#
# Most .pc files define prefix=/usr and derive the rest, so rewriting prefix is
# enough. Some (uchardet's, for one) skip prefix entirely and hardcode
# libdir=/usr/lib and includedir=/usr/include, and those silently resolve to the
# *system* paths -- the dependency is "found", and then the compiler cannot find
# the header. So rewrite every absolute directory variable, not just prefix.
#
# ...except when bq builds under the bwrap overlay, where the sysroot IS /usr.
# There a .pc saying prefix=/usr already resolves to the staged files, and
# pkg-config drops the resulting -I/usr/include by itself. Rewriting to the raw
# sysroot path there does active harm: every pkg-config query answers with
# -I<sysroot>/usr/include, which lands in generated Makefiles, gets baked into
# the .pc and *-config scripts the package installs, and -- because a plain -I
# is not a system directory -- promotes warnings inside glibc's own headers to
# errors for anything built -pedantic -Werror. xmlsec died exactly there.
#
# PC_PREFIX=sysroot forces the rewrite, PC_PREFIX=usr undoes it; the default
# follows whether bwrap actually works, which is the same test bq makes. Both
# directions are idempotent, so flipping an already-staged sysroot is fine.
set -uo pipefail
SYSROOT=${1:-/home/jbettcher/omarchy-work/sysroot}

if [ -z "${PC_PREFIX:-}" ]; then
  if bwrap --dev-bind / / true >/dev/null 2>&1; then PC_PREFIX=usr
  else PC_PREFIX=sysroot; fi
fi

_vars='prefix|exec_prefix|libdir|includedir|datarootdir|datadir|sharedstatedir|sysconfdir'
for d in "$SYSROOT/usr/lib/pkgconfig" "$SYSROOT/usr/share/pkgconfig" "$SYSROOT/usr/lib/cmake"; do
  [ -d "$d" ] || continue
  find "$d" -name '*.pc' | while read -r pc; do
    if [ "$PC_PREFIX" = usr ]; then
      sed -i -E "s#^($_vars)=$SYSROOT/usr(/|\$)#\1=/usr\2#" "$pc"
    else
      sed -i -E "s#^($_vars)=/usr(/|\$)#\1=$SYSROOT/usr\2#" "$pc"
    fi
  done
done

# Graphviz keeps a registry of its output plugins that is normally written by
# `dot -c` from the package's .INSTALL script.  We deliberately skip .INSTALL
# when staging, so a staged graphviz has no registry and reports "Format:
# svg_inline not recognized. No formats found." -- which is not a graphviz
# failure but a documentation failure in whatever is being built: at-spi2-core
# compiled all 310 targets and then died generating its gi-docgen docs.
# Rebuild the registry in place whenever graphviz is present.
if [ -x "$SYSROOT/usr/bin/dot" ]; then
  LD_LIBRARY_PATH="$SYSROOT/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  GVBINDIR="$SYSROOT/usr/lib/graphviz" \
    "$SYSROOT/usr/bin/dot" -c >/dev/null 2>&1 || true
fi

# liblto_plugin.so ships with gcc, not binutils, and lives in /usr/lib/bfd-plugins
# as a symlink into gcc's directory.  Staging binutils gives the sysroot its own
# bfd-plugins directory that shadows the system one and does not contain it, so
# ar/ranlib/nm can no longer read symbols out of LTO objects inside static
# archives -- and OPTIONS carries lto, so every convenience library is one.
# exfatprogs and exempi both failed with undefined references to their own
# symbols because of this.  Put the plugin back.
if [ -d "$SYSROOT/usr/lib/bfd-plugins" ] &&
   [ ! -e "$SYSROOT/usr/lib/bfd-plugins/liblto_plugin.so" ] &&
   [ -e /usr/lib/bfd-plugins/liblto_plugin.so ]; then
  ln -sf "$(readlink -f /usr/lib/bfd-plugins/liblto_plugin.so)" \
     "$SYSROOT/usr/lib/bfd-plugins/liblto_plugin.so" 2>/dev/null || true
fi
