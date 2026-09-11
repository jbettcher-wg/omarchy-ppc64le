# power9 — an Omarchy theme

IBM Blue 60 (`#0f62fe`) and POWER9 green (`#9fe870`), split evenly. Blue owns
focus and structure, green owns confirmation and accent.

## Install

```bash
mkdir -p ~/.config/omarchy/themes
cp -r power9 ~/.config/omarchy/themes/
omarchy theme set power9
```

Because you wrote this theme yourself (no `.git` inside it), Omarchy treats it
as unrestricted and keeps every file. Cycle wallpapers with
`omarchy theme bg next`.

## What each file does

| File | Role |
|---|---|
| `colors.toml` | The only colour source. Omarchy generates alacritty, btop, hyprland, neovim, kitty, ghostty, foot, helix, chromium, vscode and `shell.toml` from it via `$OMARCHY_PATH/default/themed/*.tpl`. |
| `backgrounds/` | Three 3840×2160 wallpapers: cube mark, flat swirl, ASCII field. |
| `unlock.png` | Lock screen background (omarchy mark version). |
| `preview.png` | Thumbnail in `omarchy theme` picker. |
| `shell.lock.toml` | Optional override for the lock password field. Delete it to use the generated default. |
| `icons.theme` | GTK icon set. |
| `extras/unlock-openpower.png` | Alternate lock background using the OpenPOWER wordmark. Swap over `unlock.png` if you prefer it. |

Templates only write a file if the theme folder does not already contain one
(`omarchy-theme-set-templates`, line 396). So dropping a hand-written
`btop.theme`, `alacritty.toml` or `hyprland.lua` in here **overrides** the
generated version for this theme, and it will not be clobbered. This theme
ships a static `btop.theme` for exactly that reason — see below.

To change how an app is themed for *every* theme, override the template
instead:

```bash
mkdir -p ~/.config/omarchy/themed
cp /usr/share/omarchy/default/themed/btop.theme.tpl ~/.config/omarchy/themed/
```

## fastfetch

fastfetch is not part of the theme spec, so it is wired up separately. The
logos are ANSI-coloured raw text, blue→green.

```bash
mkdir -p ~/.config/fastfetch
ln -sf ~/.config/omarchy/themes/power9/fastfetch/config.jsonc \
       ~/.config/fastfetch/config.jsonc
```

`logo-swirl.txt` is the face-on swirl at 40 columns (default).
`logo-cube.txt` is the isometric cube at 56 columns — point `logo.source` at
it instead if you want the bigger mark.

Quick check without installing:

```bash
fastfetch --logo-type file-raw --logo ~/.config/omarchy/themes/power9/fastfetch/logo-cube.txt
```

Note that `omarchy-launch-about` re-renders its own layout and will defer to
`~/.config/fastfetch/config.jsonc` once it exists.

## ASCII art (`ascii/`)

Plain text, no theme hooks — install these by hand.

| File | Where it goes |
|---|---|
| `banner.txt` / `banner-ansi.txt` | Shell startup. Add `cat ~/.config/omarchy/themes/power9/ascii/banner-ansi.txt` to `~/.bashrc`. The ANSI one is pre-coloured blue→green; the plain one takes `tput setaf`. |
| `motd` | `sudo cp motd /etc/motd` |
| `issue` | `sudo cp issue /etc/issue` — keeps agetty escapes (`\S` `\r` `\m` `\l` `\n`) literal, so they expand at login. |
| `splash.txt` | Boot splash / initramfs `echo`. Centred for 80 columns. |
| `die.txt` | POWER9 floorplan, 44 cols. Good as a btop header or in the MOTD. |
| `chip-small.txt` | Compact chip, 28 cols. |

Widths are fixed — they assume a monospace font and will wrap below the column
count listed.

## btop

The stock template maps btop's chrome to `magenta`, `red` and `cyan`, which
drags purple and red into the UI. Bending those tokens in `colors.toml` would
fix btop but also recolour neovim's diff markers and error states.

So this theme ships a static `btop.theme` instead. Because the generator skips
any file already in the theme folder, it survives `omarchy theme set` and
affects nothing else.

What it does:

- Box borders blue and green only — cpu/proc `#0f62fe`, mem `#9fe870`, net `#78a9ff`
- CPU, process and used-memory gradients run green → cyan → blue
- Network split by direction: download in blues, upload in greens
- Free/available meters use the neutral ramp so they recede
- **Temperature keeps green → yellow → red.** Hot hardware should look wrong,
  and on an AC922 that matters more than palette purity. Change
  `temp_mid`/`temp_end` if you disagree.

Reload after editing:

```bash
omarchy-restart-btop
```

To apply the same treatment to every theme instead, copy it as a template:

```bash
mkdir -p ~/.config/omarchy/themed
cp ~/.config/omarchy/themes/power9/btop.theme ~/.config/omarchy/themed/btop.theme.tpl
```

Then swap the literal hexes back to `{{ blue }}`, `{{ green }}`,
`{{ bright_blue }}` and so on, so each theme fills in its own palette.

## Palette

| Token | Hex | |
|---|---|---|
| `background` | `#0a0e14` | terminal / bar |
| `dark_background` | `#07090d` | |
| `darker_background` | `#05070a` | |
| `lighter_background` | `#0d1219` | surfaces |
| `selection` | `#1b2230` | borders, selected rows |
| `muted` | `#3f4a5a` | dividers, inactive |
| `dark_foreground` | `#6b7789` | comments |
| `foreground` | `#c3cbd8` | body text |
| `light_foreground` | `#e6ebf2` | |
| `bright_foreground` | `#f4f7fb` | |
| `blue` | `#0f62fe` | IBM Blue 60 |
| `bright_blue` | `#78a9ff` | IBM Blue 40 |
| `green` / `accent` | `#9fe870` | POWER9 green |
| `cyan` | `#33b1ff` | |
| `yellow` | `#d2a106` | |
| `red` | `#fa4d56` | |
| `magenta` | `#be95ff` | |

Hyprland active border is the gradient `rgba(0f62feff) rgba(9fe870ff) 45deg`.

## Trademark note

The wallpapers place the POWER9 badge and an Omarchy-derived cube mark. Both
are third-party marks — fine on your own machine, worth clearing before you
publish the theme anywhere.
