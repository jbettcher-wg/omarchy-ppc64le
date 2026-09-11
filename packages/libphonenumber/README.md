# `libphonenumber`

Arch's recipe with a JDK put on `PATH` in `build()`. Nothing else changed.

## Why

libphonenumber's cmake runs `find_required_program(java)` and dies with

    Can't find Java Runtime Environment: can't locate java.  Please read the README.

The JDK is not missing. `jre-openjdk-headless` and `java-runtime-common` are
both staged, and `sysroot/usr/lib/jvm/java-26-openjdk/bin/java` exists. The
problem is that **no package owns `/usr/bin/java`** — on Arch it is a symlink
created by `archlinux-java set`, a post-install action. bq extracts packages
into a sysroot and never runs post-install hooks, so the JVM is present but not
activated, and nothing puts its `bin/` on `PATH`.

So `build()` picks the newest `/usr/lib/jvm/java-*-openjdk` and exports
`JAVA_HOME` and `PATH` itself. Globbed rather than pinned to java-26, so a JDK
bump does not silently break it again.

This affects **any** package that needs java at build time, not just this one.
If a second case appears, the fix belongs in bq's `build_env()` rather than in
each recipe.

## Why it is in our repo at all

It is not a package we want; it is one our overlay stranded. libphonenumber
depends on `libprotobuf.so=34.1.0-64` while our repo ships protobuf 35, so
`pacman -S libphonenumber` was unresolvable. Found by `tools/soname-gaps.py`.
