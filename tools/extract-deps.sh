#!/bin/bash
# Extract dep arrays from a PKGBUILD without building.
f="$1"
(
  set +e
  export CARCH=powerpc64le CHOST=powerpc64le-unknown-linux-gnu
  srcdir=/tmp/x pkgdir=/tmp/y startdir=/tmp
  source "$f" >/dev/null 2>&1
  printf "PKGBASE\t%s\n" "${pkgbase:-${pkgname[0]}}"
  printf "PKGNAMES\t%s\n" "${pkgname[*]}"
  printf "PKGVER\t%s\n" "$pkgver"
  printf "ARCH\t%s\n" "${arch[*]}"
  for d in "${depends[@]}"; do printf "DEP\t%s\n" "$d"; done
  for d in "${makedepends[@]}"; do printf "MAKEDEP\t%s\n" "$d"; done
  for d in "${checkdepends[@]}"; do printf "CHECKDEP\t%s\n" "$d"; done
) 2>/dev/null
