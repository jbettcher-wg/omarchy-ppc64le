# Reaching the AUR from ppc64le

What `yay` can and cannot do on this machine, what was measured rather than
assumed, and what the tool that replaces it has to look like.

## Short version

`yay` is built and works — for **searching, inspecting and fetching**. It is
not the route by which AUR packages get *installed* here, and no flag makes it
one. Building is not the hard part: `makepkg -A` compiles an unmodified AUR
recipe on POWER9 and labels the result correctly. The friction is entirely on
the metadata-and-install side, and the fix is to own the pipeline rather than
to configure a helper.

## What `yay` does here

Built from `packages/yay` (13.0.1-2). It needed one non-obvious change to work
at all — `-buildmode=pie` makes purego's ppc64le FFI trampoline segfault on the
first libalpm call, so this architecture builds without PIE; the full diagnosis
is in that PKGBUILD's header. With that, verified against the staged package:

| Command | Result |
|---|---|
| `yay --version` | `yay v13.0.1 - libalpm v16.0.1`, exit 0 |
| `yay -Ss cliamp` | correct AUR hits, exit 0 |
| `yay -Sia cliamp` | full AUR package info, exit 0 |
| `yay -Gp cliamp` | prints the AUR PKGBUILD, exit 0 |
| `yay -Qi`, `yay -Qu`, `yay -Ps` | all correct, exit 0 |

So the AUR RPC, the `.SRCINFO`/PKGBUILD fetch and every read-only alpm path are
fine on ppc64le. That is genuinely useful: it is how you find out what exists
and read a recipe before deciding to build it.

## What was measured about building

`makepkg` has `-A` / `--ignorearch` (`/usr/bin/makepkg:1108`, sets
`IGNOREARCH=1`). Tested on an unmodified AUR checkout of `cliamp` 2.0.1, whose
`arch=('x86_64' 'aarch64')` excludes this machine:

```
$ makepkg -d --nocheck --nobuild
==> ERROR: cliamp is not available for the 'powerpc64le' architecture.

$ makepkg -dA --nocheck
==> Finished making: cliamp 2.0.1-1
$ ls $PKGDEST
cliamp-2.0.1-1-powerpc64le.pkg.tar.zst
cliamp-debug-2.0.1-1-powerpc64le.pkg.tar.zst
```

Two things worth stating plainly:

1. **The build itself was never the problem.** An AUR recipe written for x86_64
   compiled on POWER9 with no edit at all — same result as the 65-of-93 figure
   from the ported packages, arriving by a different route.
2. **The output is honestly labelled.** `get_pkg_arch` still tags the package
   `powerpc64le`; `-A` skips the *check*, it does not mislabel the artifact.

## Why the helper route is closed anyway

The user has hit this before: yay does not get you past it, and the guard is in
libalpm rather than in the helper. libalpm carries the check and its messages —

```
$ strings /usr/lib/libalpm.so.16 | grep -i architecture
package %s does not have a valid architecture
package architecture is not valid
skipping architecture checks
alpm_option_add_architecture
```

— which is `ALPM_ERR_PKG_INVALID_ARCH`. Being in libalpm rather than in yay is
the load-bearing detail: it means `paru` will behave the same way, because the
guard is below both of them, and it means passing flags *through* a helper to
makepkg cannot help, because the refusal happens after makepkg has already
finished its work.

**Not verified here, and deliberately so:** no `yay -S` was run against an
`arch=(x86_64)` package on this machine, so this document carries no captured
yay-side error message. Running an install command is outside what this repo is
allowed to do (see `RULES.md` §2), and the environment blocked it. What is
recorded above is what could be established without installing anything: the
build half works, the guard exists in libalpm, and the field report says the
combination does not.

## What the tool has to be

Not a wrapper around yay. A pipeline that finishes before alpm ever sees a
foreign architecture:

```
  fetch PKGBUILD  ->  rewrite arch=()  ->  regenerate .SRCINFO
       ->  makepkg  ->  classify the failure  ->  local repo
```

The order matters. Rewriting `arch=()` **and** regenerating `.SRCINFO` before
resolution means dependency resolution runs against the local repo plus Arch
POWER's, on metadata that says `powerpc64le`, rather than against AUR metadata
that says `x86_64`. `.SRCINFO` carries its own `arch` field and arch-suffixed
keys (`depends_x86_64`, `source_x86_64`, ...), so a rewrite that touches only
the PKGBUILD leaves the metadata lying.

`yay` keeps its place in that picture as the search and inspection front end —
`yay -Ss` to find something, `yay -Sia` to read its metadata, `yay -Gp` to see
the recipe — and hands off to the pipeline for anything that builds.

## Omarchy's own tools that call yay

Five scripts in `upstream/omarchy/bin/` reference yay. Two only *read*, and
work here unchanged:

- `omarchy-pkg-remove` — `yay -Qi` preview, then `pacman -Rns`. Local packages
  only; nothing AUR-specific. Works.

The other three drive installs and would each need repointing:

| Script | What it does | What it needs here |
|---|---|---|
| `omarchy-pkg-aur-install` | **the fzf tool.** `yay -Slqa \| fzf` to pick, `yay -Siia {1}` / `yay -Gpa {1}` as live previews, then `xargs yay -S --noconfirm` | The whole browsing half works as-is — listing, preview, PKGBUILD preview are all read-only AUR queries. Only the last line has to change, from `yay -S` to the local pipeline. |
| `omarchy-pkg-aur-add` | `yay -S --noconfirm --needed "$@"`, used by install scripts | Same substitution; it is one line. |
| `omarchy-update-aur-pkgs` | `yay -Sua` to upgrade foreign packages | Needs the pipeline's rebuild path, and a notion of which locally built packages are AUR-derived. |

Worth being blunt about the size of this: for `omarchy-pkg-aur-install` it is
**not a config tweak**. There is no `yay` setting that makes `yay -S` work
here, so the change is structural — swap the install command for a call into
the pipeline — even though the fzf UI, the previews and the package list around
it all survive untouched. That is a good trade: the interactive part, which is
the part that would be tedious to rebuild, is exactly the part that already
works.
