#!/usr/bin/env bash
# Smoke-test p9-install's logic without hardware.
#
# Everything the installer does before it touches a disk -- argument handling,
# repo-server precedence, the platform branches, manifest resolution, the guard
# conditions -- is reachable under --dry-run, and none of it needs a POWER9
# machine or a spare drive. This exists because tonight's changes (repo-server
# precedence, the timezone prompt, console=/video= defaults, the $P9_MNT guard)
# were all shipped untested: the only way to exercise them was to cut an ISO and
# install, which is a twenty-minute round trip per typo.
#
# `pacman` is stubbed: preflight requires it on PATH, and resolve_packages needs
# root even with a private --dbpath, so neither can run here. That means this
# checks the installer's own logic, NOT that the package set resolves -- for
# that, see tools/repo-gaps.py, which does it from the databases directly.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALLER="$HERE/../installer/p9-install"
[[ -x $INSTALLER || -f $INSTALLER ]] || { echo "no p9-install at $INSTALLER" >&2; exit 2; }

STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$STUB/pacman"
chmod +x "$STUB/pacman"

pass=0 fail=0

# A case that should complete without an error line.
ok() {
  local desc=$1; shift
  local out
  out=$(PATH="$STUB:$PATH" bash "$INSTALLER" --dry-run "$@" 2>&1)
  if grep -qiE 'ERROR:|unbound variable|command not found|syntax error' <<<"$out"; then
    printf '  %-44s FAIL\n' "$desc"
    grep -iE 'ERROR:|unbound|not found|syntax' <<<"$out" | head -2 | sed 's/^/        /'
    ((fail++))
  else
    printf '  %-44s ok\n' "$desc"; ((pass++))
  fi
}

# A case that must be refused. A guard that stops refusing is as much a
# regression as a path that stops working.
rejects() {
  local desc=$1; shift
  if PATH="$STUB:$PATH" bash "$INSTALLER" --dry-run "$@" >/dev/null 2>&1; then
    printf '  %-44s *** ACCEPTED, should not have\n' "$desc"; ((fail++))
  else
    printf '  %-44s rejected\n' "$desc"; ((pass++))
  fi
}

D=(--disk /dev/sda)
S=(--repo-siglevel 'PackageNever DatabaseOptional TrustAll')

echo "accepted paths:"
ok "powernv, defaults"        "${D[@]}" "${S[@]}" --platform powernv
ok "pseries"                  "${D[@]}" "${S[@]}" --platform pseries
ok "user + password"          "${D[@]}" "${S[@]}" --platform powernv --user tester --password hunter2
ok "deferred account"         "${D[@]}" "${S[@]}" --platform powernv
ok "explicit repo-server"     "${D[@]}" "${S[@]}" --platform powernv --repo-server http://host/repo
ok "two repo-servers"         "${D[@]}" "${S[@]}" --platform powernv \
                                 --repo-server file:///run/archiso/bootmnt/p9repo/omarchy-power9 \
                                 --repo-server http://host/repo
ok "repo-server none"         "${D[@]}" "${S[@]}" --platform powernv --repo-server none
ok "custom cmdline"           "${D[@]}" "${S[@]}" --platform powernv --cmdline quiet
ok "custom kernel"            "${D[@]}" "${S[@]}" --platform powernv --kernel linux
ok "SigLevel Required"        "${D[@]}" --repo-siglevel Required --platform powernv

echo "guards:"
rejects "no --repo-siglevel"  "${D[@]}" --platform powernv
rejects "no --disk"           "${S[@]}" --platform powernv
rejects "bad platform"        "${D[@]}" "${S[@]}" --platform bogus
rejects "repo under \$P9_MNT" "${D[@]}" "${S[@]}" --platform powernv --repo-server file:///mnt/x

# --serial is the guard that stops the installer eating the wrong disk, so the
# meaningful assertion is that a serial which does NOT match is refused. An
# earlier version of this file asserted the opposite -- that an arbitrary
# --serial was accepted -- which passed only on hosts with no /dev/sda, where
# assert_disk_is_safe returns early under --dry-run and never reaches the check.
# It failed the moment it was run on a machine with a real disk, which is the
# only place it was testing anything.
if [[ -b /dev/sda ]]; then
  rejects "mismatched --serial"  "${D[@]}" "${S[@]}" --platform powernv --serial NOPE-NOT-THIS-DISK
  real=$(lsblk -dn -o SERIAL /dev/sda 2>/dev/null | head -1)
  if [[ -n $real ]]; then
    ok "matching --serial"       "${D[@]}" "${S[@]}" --platform powernv --serial "$real"
  else
    echo "  matching --serial                            skipped (disk reports no serial)"
  fi
else
  echo "  --serial cases                               skipped (no /dev/sda on this host)"
fi

echo
echo "$pass passed, $fail failed"
exit $(( fail > 0 ))
