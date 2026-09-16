#!/bin/bash
# prime-dbpath.sh <dbpath> [repodir] -- populate a scratch pacman dbpath
# without root.
#
# `pacman -Sy` insists on being root even with --root/--dbpath, and there is no
# passwordless sudo here.  But every read-only operation (-Sp, -Si, -Sg, -T)
# works fine unprivileged against a dbpath whose sync databases are already in
# place.  So we place them: Arch POWER's are copied out of the live sync cache
# (read-only -- we never write to /var/lib/pacman), and ours is copied straight
# from the repo-add output.
#
# The local database is left EMPTY on purpose.  That is what makes a resolve
# here mean "what a bare install needs" rather than "what this workstation is
# still missing", and it is the whole reason the build queue can compute an
# install closure on a machine that already has 1374 packages on it.
set -euo pipefail

dbpath=${1:?usage: prime-dbpath.sh <dbpath> [repodir]}
repo=${2:-/home/jbettcher/Development/omarchy-ppc64le/repo}

# Fail closed.  A typo that resolves to the live database would have pacman
# writing into /var/lib/pacman, which RULES.md forbids outright.
case "$(readlink -f "$dbpath")" in
  /var/lib/pacman|/var/lib/pacman/*|/|/var|/var/lib)
    echo "prime-dbpath: refusing to touch the live pacman database" >&2
    exit 2 ;;
esac

mkdir -p "$dbpath/sync" "$dbpath/local"
for db in /var/lib/pacman/sync/*.db; do
  [ -e "$db" ] || continue
  cp -f "$db" "$dbpath/sync/"
done

# bq's staging database, copied in under the name tools/pacman-build.conf gives
# the stanza that serves it ([bq-staging]). It is not a published pool db --
# those are omarchy-ppc64le.db.tar.gz (baseline) and omarchy-power9.db.tar.gz.
if [ -e "$repo/bq-staging.db.tar.zst" ]; then
  cp -f "$repo/bq-staging.db.tar.zst" "$dbpath/sync/bq-staging.db"
fi

echo "prime-dbpath: $(ls -1 "$dbpath"/sync/*.db 2>/dev/null | wc -l) sync databases in $dbpath"
