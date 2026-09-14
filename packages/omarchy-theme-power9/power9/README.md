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
| `preview.png` | Thumbnail in the `omarchy theme` picker. |
| `preview-unlock.png` | Lock-screen preview in the theme switcher. |
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

Available logos, all pre-coloured:

| File | Size | Notes |
|---|---|---|
| `logo-swirl.txt` | 40 × 20 | Face-on swirl. Default. |
| `logo-cube.txt` | 56 × 30 | Isometric cube, half-blocks. |
| `logo-cube-50.txt` | 50 × 20 | Cube + centered wordmark, half-blocks. Squashed to fit. |
| `logo-cube-braille-50.txt` | 50 × 20 | Cube + wordmark in braille dots. 8× the sample density. |
| `logo-cube-braille-52.txt` | 52 × 30 | Braille at true isometric proportion. Sharpest of the set. |

Braille packs 2 × 4 dots into each cell, so it resolves the spiral far better
than half-blocks at the same width. Two caveats: your font needs U+2800–28FF
coverage (most Nerd Fonts have it), and a few terminals render braille cells
slightly narrow, which shears the cube. Check with `cat` before committing to it.

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

## Obsidian (`obsidian/`)

**Read this first:** Omarchy 4 already generates Obsidian theming from
`colors.toml`, so you may not need this at all. Run `omarchy theme set power9`
and check Obsidian before installing anything here.

What the generated output gives you is the palette. What this folder adds is
structural CSS the template cannot express — squared corners, the heading
colour ladder, the gradient blockquote rail, bordered inline code. Install it
only if you want those.

It is a standalone Obsidian theme, installed the Obsidian way:

```bash
mkdir -p /path/to/vault/.obsidian/themes/power9
cp /usr/share/doc/omarchy-theme-power9/obsidian/* /path/to/vault/.obsidian/themes/power9/
```

Then Settings → Appearance → Themes → **power9**. Per-vault, so repeat it for
each vault.

Colours come straight from `colors.toml`. Editorial choices worth knowing:

- Headings step blue → green as they get deeper (h1 white, h2 `#78a9ff`, h3 `#9fe870`)
- Internal links green, external links blue — so you can tell them apart at a glance
- Inline code green, matching how strings read in the terminal
- Corners squared (`--radius-*: 0`) to match the rest of the theme
- Graph view: nodes blue, focused node green
- Syntax keeps magenta for keywords and red for errors — a two-colour code
  view is unreadable

If you would rather layer on top of your current theme than replace it, use it
as a snippet instead:

```bash
cp /usr/share/doc/omarchy-theme-power9/obsidian/theme.css /path/to/vault/.obsidian/snippets/power9.css
```

Enable under Settings → Appearance → CSS snippets.

## Distributing it

If you push this as a public repo, name it `omarchy-power9-theme` — Omarchy
strips the `omarchy-` prefix and `-theme` suffix, so it appears as **power9**
in the theme menu. Others install it with:

```bash
omarchy theme install https://github.com/<you>/omarchy-power9-theme
```

A cloned theme is filtered at staging: Omarchy drops anything that can execute
code — `*.lua`, `alacritty.toml`, `foot.ini`, `ghostty.conf`, `kitty.conf`,
`vscode.json`, and symlinks at any depth — and regenerates those from its own
templates instead. Dropped files are named on stderr.

This theme ships none of those, so it survives cloning intact. `btop.theme`
is explicitly on the kept list ("everything a cloned theme ships that is
colour is kept"), which is why the hand-written btop override works for other
people and not just for you.

Move `ascii/` and `obsidian/` out before publishing if you want the repo to be
pure theme — neither is part of the spec, and the theme gallery only checks for
`colors.toml` plus a README with a screenshot.

## Hiding the minimize button

Short answer: not from the theme, and no Omarchy theme does it — there is
nothing in the theme spec for window controls.

Where it actually lives depends on the app:

**Hyprland itself** draws no titlebars at all. There is no server-side
minimize button to hide, and Hyprland has no minimize concept — `special`
workspaces are the closest thing.

**GTK apps** (Nautilus, GNOME Text Editor, etc.) draw their own client-side
decorations, and the button set is a GTK setting, not a theme file:

```bash
gsettings set org.gnome.desktop.wm.preferences button-layout ':close'
```

That leaves only close on the right. `':'` alone removes all of them. To make
it stick across reboots, add it to `~/.config/gtk-3.0/settings.ini`:

```ini
[Settings]
gtk-decoration-layout=:close
```

and the same key in `~/.config/gtk-4.0/settings.ini`.

**Electron apps** (Obsidian, VS Code, Discord) draw their own title bars, and
there is no theme or GTK setting that hides just the minimize button there.
Obsidian's own title bar (the default, **Native frame** off) always shows
minimize, maximize and close. Under Hyprland, pressing minimize leaves the
window frozen on screen, because Hyprland has no minimize state to return
from. Avoid the button until Electron treats minimize as a no-op on
compositors that don't advertise it.

Checked against Omarchy's theming docs: there is no window-control key in the
theme spec at any level. The full list a theme may ship is `colors.toml`,
hand-written config overrides, `backgrounds/`, `preview.png`,
`preview-unlock.png`, `icons.theme`, `keyboard.rgb`, `unlock.png` and a
`light.mode` marker. Window buttons are not in it, so this stays a GTK-level
change regardless of theme.

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
