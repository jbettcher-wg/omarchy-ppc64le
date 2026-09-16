# Rules for working in this repo

Read before doing anything here, human or agent.

## 1. Never run Omarchy's installer or configuration scripts

Not `upstream/omarchy/install/**`, not `upstream/omarchy/bin/omarchy-*`, not
`boot.sh`, not anything fetched from omarchy.org. Not to see what it does, not
with `--dry-run`, not piped to a shell.

**Why.** The build host (192.168.2.24) is a working daily-driver AC922 running a
COSMIC desktop, not a scratch machine. The Omarchy installer rewrites `/etc` and
`~/.config`, replaces `pacman.conf` and the mirrorlist with
`pkgs.omarchy.org` — which has **no ppc64le tree**, so that step alone breaks
package management — enables systemd units, and installs limine bootloader and
snapper hooks. POWER9 boots through petitboot/OPAL, so parts of that are not
merely unwanted but wrong for this hardware.

The install flow gets tested in a VM later. This repo's job is only to make the
packages exist.

## 2. Scope: back-filling packages, nothing else

Allowed:

- Reading any Omarchy file, install scripts included, to learn what a package needs.
- Writing PKGBUILDs and patches in the packaging tree
  ([omarchy-ppc64le-packaging](https://github.com/jbettcher-wg/omarchy-ppc64le-packaging),
  `$OMARCHY_PACKAGING`).
- `makepkg` builds; running the built binaries from `repo/` or a temp directory
  to verify them.
- `sudo pacman -S --needed` for **build dependencies**.

Ask first:

- Executing any Omarchy script.
- Writing to `/etc`, `/usr` outside makepkg's own `$pkgdir`, `~/.config`,
  `~/.local/share`, or systemd unit directories.
- `pacman -U` to install a built package into the live system. Build and verify
  in place instead.
- Editing `pacman.conf`, the mirrorlist, or adding repositories.
- Enabling or starting services.

If verifying a package seems to require installing it system-wide, that is a
signal to stage it — `PATH`/`LD_LIBRARY_PATH` against a staging directory, or a
container — or to stop and ask. It is not a reason to install.

## 3. Recipes are the asset, not artifacts

A previous set of ppc64le builds on this machine was lost with no backup. Commit
PKGBUILDs and patches as you go. Built packages are gitignored on purpose; they
are reproducible from what is tracked, and only what is tracked survives.

## 4. Keep patches minimal and say why

Every patch carries a header comment stating what it fixes and whether it is a
**portability fix worth sending upstream** or a **local workaround**. When adding
`powerpc64le` to `arch=()` was the only change needed, say so — it keeps the
packages that needed real work visible.
