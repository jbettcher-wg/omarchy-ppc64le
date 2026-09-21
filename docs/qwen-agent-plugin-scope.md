# Qwen local-model agent plugin for Omarchy — scope + handoff

Written 2026-09-19 by the Qwen Code session on the Power9 host, for the
re-launched (VS Code) session that will pick this work up. A reviewer agent
produced a first design draft; every load-bearing claim below was then
fact-checked against the installed system (`/usr/share/omarchy`) and the
upstream checkout. Where the reviewer draft was wrong, the correction is
called out in §5. **The reviewer's draft was never saved to disk — this
document supersedes it.**

## 1. Task and constraints

Build a **standalone Quickshell plugin** for Omarchy so that bug reports etc.
get issued to local models through Qwen — i.e. an OpenAI-compatible
`/v1/chat/completions` endpoint on the machine (served by the MAX stack's
`max serve`).

Hard constraints from the maintainer:

1. **No modifications to existing packages** in the standalone phase.
2. Ship as a **separate plugin first** (`omarchy plugin add`-able git repo),
   integrate upstream later.
3. It must **update the agent menu** (both surfaces, see §2.5).
4. It must **ask for server information through a settings dialog** if not
   already configured.

## 2. Verified system facts

Machine notes: verified on the Power9 (ppc64le) host with Omarchy installed.
If the new session runs elsewhere, re-verify paths with `ls /usr/share/omarchy`
before relying on line numbers.

### 2.1 Shell architecture

- `omarchy-shell` is **one long-running Quickshell instance** hosting bar,
  panels and all plugins in-process
  (`/usr/share/omarchy/shell/README.md`).
- A plugin = **git repo with `manifest.json` at its root**. Third-party
  install: `omarchy plugin add <git-url>` → clone into
  `~/.config/omarchy/plugins/<id>/`; `omarchy plugin update/remove/enable`;
  manual drop + `omarchy-shell shell rescanPlugins` + `omarchy plugin enable
  <id>` also works. **Verify in phase 0 that `omarchy plugin add` accepts a
  local path** (fallback: manual drop).
- `kinds`: `bar-widget`, `panel`, `overlay`, `menu`, `service`, `bar`.
  `service` + `bar-widget` in one plugin is an established pattern
  (`omarchy.media`). `keepLoaded: true` keeps a service mounted across
  hot-reloads (lock-screen precedent) — relevant to our timer-owning service.
- Entry points receive host injection (`omarchyPath`, `shell`, `manifest`,
  `pluginRegistry`, `barWidgetRegistry`); third-party plugins get
  capability-scoped facades. Plugins run **unsandboxed inside omarchy-shell**.
- IPC: `omarchy-shell shell <method>` — `summon`, `toggle`, `call <id>
  <method> <arg>`, `listPlugins`, `rescanPlugins`, `setPluginEnabled`. Plugins
  can register **extra IPC targets** of their own (image-picker's
  `image-selector` is the precedent).
- **Settings persist inline on the shell.json entry**
  (`~/.config/omarchy/shell.json`, no separate config file), described by the
  manifest's `barWidget.schema` (key/type/label/min/max/options) + `defaults`.
  The widget gets `settings` injected at load and on change
  (`shell/plugins/bar/Bar.qml`, `injectProps()` ~line 1997). Persisting from a
  widget: `omarchy bar set <id> <key> <value> [--json]` via `bar.run(...)`;
  settings-only shell.json writes **live-patch running widgets**
  (`Bar.qml:591-611`, `applySettingsDelta`). The agents plugin documents
  exactly this pattern.
- `barWidget.settingsForm` (a form name, e.g. weather ships
  `"settingsForm": "weatherSettings"`) is passed through
  (`shell.qml:1407`) and "the settings panel reads metadata from the
  registry" — but **no consumer of `settingsForm` exists in the installed
  shell tree** (grep-verified; only the two manifests + shell.qml mention
  it). Phase 0 must find the consumer in the upstream checkout, or we build
  our own form UI (shared kit in `shell/Ui/`: `Panel`, `PanelHero`,
  `TextField`, `NumberField`, `Dropdown`, `Toggle`, `ConfirmDialog`,
  `Commons/Style.qml` — demoed by the `dev-gallery` plugin).
- **HTTP pattern in this stack: QML does no networking.** Grep-verified: no
  `NetworkAccessManager`/`fetch(` in the shell tree. Collectors are
  **python3 + stdlib `urllib.request`** scripts (e.g.
  `/usr/bin/omarchy-agent-usage-claude` — python3, no deps, probe
  min-interval 15 s, cache under `~/.cache/omarchy/agent-usage`).
  **Pattern to copy: QML UI spawns a small python/bash helper via `Process`.**
- User's live config today: bar right section = tray, agents, bluetooth,
  network, audio, monitor, power; `plugins: [firstpick.skill-manager]`.

### 2.2 Agent dispatch chain (the bug-report path)

`/usr/bin/omarchy-agent` (bash; read in full, verified):

- Flags: `--inline`, `--pick`, `--prompt <text>`.
- `agent=$(omarchy-default-agent)` — reads `~/.config/omarchy/defaults/agent`
  (`omarchy default agent [name]` sets it).
- `omarchy-cmd-missing "$agent"` gates on the binary being on PATH.
- Then a **hardcoded `case` with exactly 13 names**: `opencode gemini copilot
  crush claude grok openclaw codex cursor-agent hermes muse omp pi`. Anything
  else → `Unsupported default agent`. **There is no extension hook** — a new
  agent name requires editing this script (integration phase).
- Launch: `omarchy-launch-tui --app-id=org.omarchy.agent <command>` (or plain
  `exec` with `--inline`). `--pick` with no default summons
  `setup.default.agent` in the menu.

`/usr/bin/omarchy-agent-crash <pid> [comm] [exe] [signal]`:

- Invoked from the **"Process crashed:" notification**
  (`omarchy-crash-watch.service` is enabled).
- Gathers facts (e.g. `coredumpctl list` timestamp, tolerated failure) and
  points the prompt at
  `$OMARCHY_PATH/default/agents/skills/diagnose-crash/SKILL.md` — the
  diagnose-crash method lives in that skill so it works with whichever agent
  is default; the script only gathers facts. Its `reporting.md` covers
  upstream bug reporting.
- The prompt then flows through `omarchy-agent-prompt` →
  `omarchy agent --prompt "..."` → the default agent's case arm.

### 2.3 The `omarchy.agents` bar widget (usage dashboard)

`/usr/share/omarchy/shell/plugins/agents/` (`manifest.json`, `Main.qml`,
`Panel.qml`, `Agent.qml`, `README.md`):

- **Discovery is file-based**: `Main.qml:16` sets
  `usageDir = (XDG_STATE_HOME || ~/.local/state) + /omarchy/agents/usage`,
  `Main.qml:27` runs `find <usageDir> -maxdepth 1 -name "*.json"`.
  **Any `*.json` record that appears there becomes a tab — regardless of who
  wrote it** (README, explicit).
- Refresh (timer `refreshIntervalSec` default 900 s, or manual `r`/Enter)
  invokes `omarchy-agent-usage-update`, passing `--except <id>` for
  providers disabled in settings (`Main.qml:147-152`). Providers **default to
  enabled for every discovered agent** (`Main.qml:213-214`).
- IPC: `omarchy-shell shell call omarchy.agents <open|close|toggle|refresh|next>`.
- Bar icon: left = panel, right = launch agent, middle = next subscription.
  Self-hides when no agent has records.

**Record contract** (agents README + `Main.qml` field reads):
`id`, `name`, `updatedAt`, `ready`, `tierLabel`, `usageStatusText`,
`authHelpText`, `todayPrompts`, `todaySessions`, `todayTotalTokens`,
`recentDays[{date, messageCount}]`, `modelUsage{<model>:{inputTokens,
outputTokens, ...}}`, `limits[{...percent, resetsAt}]`, optional
`"scope": "account"` (account-global stats merge by widest value; machine
local is the default).

### 2.4 Usage collectors — where they must live

`/usr/bin/omarchy-agent-usage-update` (read in full, verified):

- Globs **`"$OMARCHY_PATH"/bin/omarchy-agent-usage-*`** — i.e. the
  **installed package bin dir only, not user PATH**. A collector in
  `~/.local/bin` will *not* be run by the widget's refresh.
- Each collector prints one display-ready JSON record (validated with
  `jq -e .`); the script atomically writes `$USAGE_DIR/<agent>.json`
  (mktemp + mv). It never deletes unknown files, so a `qwen.json` we write
  ourselves survives refreshes.

### 2.5 The "agent menu" — two surfaces, not one

1. **omarchy-menu → Setup → Defaults → Agent**:
   `/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc` lines 131-146 —
   `setup.default.agent` plus one entry per agent with `when:`/`checked:`
   bash expressions and `action: omarchy-default-agent <name>`. The menu
   engine also parses the **user extension file
   `~/.config/omarchy/extensions/omarchy-menu.jsonc`** with
   `watchChanges: true` (plugins/README.md, "Omarchy menu") — **a documented
   extension point that needs no package change**.
2. **The `omarchy.agents` bar-widget panel** (usage dashboard, §2.3).

"Quattro" is the current Omarchy release codename (migrations reference
`OMARCHY_UPGRADE_TO_QUATTRO_LIVE`); it is not a separate component.

### 2.6 Source locations

| what | where |
|---|---|
| this project (ppc64le distro) | `/mnt/arch/home/jbettcher/Development/omarchy-ppc64le` (this repo: `docs/`, `packages/`, `manifest/`, `repo-ppc64le`, `upstream/`, …) |
| Omarchy upstream checkout (read-only reference + future PR target) | `/mnt/arch/home/jbettcher/Development/omarchy-ppc64le/upstream/omarchy` (git) |
| ppc64le packaging | `/mnt/arch/home/jbettcher/Development/omarchy-ppc64le-packaging` (git) |
| ISO | `/mnt/arch/home/jbettcher/Development/omarchy-ppc64le/upstream/omarchy-iso` (git) |
| installed tree | `/usr/share/omarchy` (`shell/`, `bin/` → `/usr/bin/omarchy-*`, `default/`, `migrations/`) |

## 3. Consolidated design (post fact-check)

### 3.1 Shape

- **id**: `jbettcher.qwen` (standalone phase) → `omarchy.qwen` (integration).
- **kinds**: `["service", "bar-widget"]` (media-plugin precedent).
- **IPC target**: `qwen` (registered from the service, image-picker precedent)
  with `status`, `send`, `configure`-style methods.
- **Repo layout** (manifest.json at root, per the third-party contract):

  ```
  jbettcher.qwen/
  ├── manifest.json         # kinds, entry points, barWidget.schema+defaults
  ├── Service.qml           # IPC target, health-probe timer, record writer
  ├── Panel.qml             # bar button + popup: status, settings form, prompt box
  ├── bin/
  │   ├── qwen-local.py     # ALL HTTP (python3 stdlib, urllib): probe, chat, record
  │   └── qwen-agent-shim   # bash; shadows one of the 13 hardcoded agent names
  └── install.sh            # optional: shim symlink + menu extension + enable
  ```

**Repo (exists as of 2026-09-19):** `/mnt/arch/home/jbettcher/Development/jbettcher.qwen`
(git, `main`) — phase-0 files implemented and validated live on the Power9
host; installed at `~/.config/omarchy/plugins/jbettcher.qwen`, enabled, bar
icon in the right section.

### 3.2 Settings + first-run dialog

- `barWidget.schema` keys: `baseUrl` (string, **default `""` = unconfigured**),
  `model` (string), `apiKey` (string, default `""`; local endpoints usually
  need none), `timeoutMs` (integer, 1000-120000, default 60000).
- First run / unconfigured: opening the panel shows a "not configured" hero
  plus an inline form (shared `Ui/` components). Save persists each key with
  `omarchy bar set jbettcher.qwen <key> <value> --json` via `bar.run(...)`,
  which live-patches the widget; the service starts its probe timer.
- **Single source of truth = the shell.json entry.** The bash shim reads it
  with `jq` (no second settings file to drift). Trade-off: `apiKey` sits in
  plaintext shell.json — acceptable for a local-only endpoint, note it in the
  UI.
- Phase 0 check: find the `settingsForm` consumer in the upstream checkout;
  if a generic schema renderer exists, prefer it over the hand-built form.

### 3.3 Bug-report flow (core requirement)

Standalone phase cannot add a `qwen` arm to the hardcoded case, so the
recommended design is the **agent-name shim** (reviewer's design B, refined):

1. `install.sh` symlinks `bin/qwen-agent-shim` to `~/.local/bin/<SHADOW_NAME>`
   where `<SHADOW_NAME>` is one of the 13 hardcoded names the user does not
   use (open question Q1), verifies `~/.local/bin` precedes `/usr/bin` in
   PATH, and runs `omarchy default agent <SHADOW_NAME>`.
2. End-to-end: crash notification → `omarchy agent crash <pid>` →
   `omarchy-agent-crash` gathers facts + diagnose-crash prompt →
   `omarchy-agent --prompt "…"` → case arm for `<SHADOW_NAME>` →
   `omarchy-launch-tui` terminal → **shim** parses the flags for that case
   arm, reads settings from shell.json, execs `qwen-local.py chat` which
   POSTs `/v1/chat/completions` and **streams the reply to the terminal**.
   The existing UX (terminal window, app-id `org.omarchy.agent`) is preserved.
3. Not configured / endpoint down: the shim exits non-zero with a one-line
   actionable message — it must never hang the terminal.

Rejected alternatives (kept for the record): **A** pure-plugin (panel
gathers coredump facts itself and POSTs; the notification path still funnels
through the hardcoded dispatch, so it can't own the flow unmodified); **C**
custom CLI (`omarchy-qwen crash …` changes user habits).

Integration phase (4): add a first-class `qwen)` arm to
`omarchy-agent` (one small upstream diff) that invokes the helper directly;
the shim retires.

### 3.4 Agent-menu updates (both surfaces)

- **Usage dashboard tab**: in the standalone phase the widget's refresh
  *cannot* run our collector (package-bin glob, §2.4), so the **service
  itself writes the record**: a QML timer (e.g. 60-300 s) spawns
  `qwen-local.py record`, which atomically writes
  `~/.local/state/omarchy/agents/usage/qwen.json`. The panel picks it up
  automatically (`find`-based). For a local model: `limits: []` (no quota —
  verify in phase 0 that the panel renders empty limits cleanly; fireworks'
  balance shape is the closest analog), `ready` = probe result,
  `tierLabel` = model name or "Local (MAX)", `usageStatusText` when the
  endpoint is down, `todayPrompts`/`todayTotalTokens`/`recentDays`/
  `modelUsage` from a small machine-local request log the helper keeps
  (e.g. `~/.local/state/omarchy/qwen/requests.jsonl`; token counts from
  `response.usage` when the endpoint provides them).
  Integration phase: ship `omarchy-agent-usage-qwen` in the package bin so
  the standard refresh path owns it.
- **Default-agent menu entry**: append to
  `~/.config/omarchy/extensions/omarchy-menu.jsonc` (hot-reloaded):

  ```jsonc
  "setup.default.agent.qwen": {
    "label": "Qwen (local)",
    "when": "<bash: settings present in shell.json>",
    "checked": "[[ \"$(omarchy-default-agent)\" == \"<SHADOW_NAME>\" ]]",
    "action": "omarchy-default-agent <SHADOW_NAME>"
  }
  ```

  (phase 4: `checked`/`action` become `qwen`.)

### 3.5 Networking

- All HTTP in `qwen-local.py` (python3 + `urllib.request`, stdlib only —
  stack precedent). Modes: `probe` (GET `/v1/models`), `chat` (POST
  `/v1/chat/completions`; non-streaming for panel/IPC use, streaming to
  stdout for the terminal shim), `record` (emit usage JSON).
- Probe min-interval ~15 s (claude collector precedent); timeouts from
  settings; QML never blocks on generation (Process + async).

## 4. Milestones

| phase | proves | deliverables |
|---|---|---|
| 0 spike ✅ done 2026-09-19 | plugin loads + settings round-trip + probe works | see **phase-0 results** below the checklist |
| 1 connectivity ✅ built 2026-09-19 | `omarchy agent crash` reaches the local model | `chat` mode (plain+SSE), shim (all 8 names), install.sh — E2E-verified vs mock (`omarchy agent --inline --prompt` through the real dispatch); live wiring awaits the shadow-name choice (Q1) and a real endpoint (Q2) |
| 2 visibility | local model appears in the agent menu | record writer → usage tab; menu extension entry |
| 3 robustness | degrades gracefully | prompt truncation, timeouts, endpoint-down UX, `keepLoaded` decision, upgrade-drift guard |
| 4 upstream | first-class agent | `qwen` case arm, in-tree plugin (`omarchy.qwen`), `bin/omarchy-agent-usage-qwen`, menu entry in defaults, ppc64le packaging |

**Phase-0 verification checklist** (each item is an unknown that changes
design):

1. `omarchy plugin add` from a local git path/URL (else manual drop +
   `rescanPlugins` + `enable`).
2. Settings injection + `omarchy bar set jbettcher.qwen … --json`
   round-trip on a live widget.
3. Who consumes `barWidget.settingsForm` in the upstream checkout
   (`grep -rn settingsForm upstream/omarchy`).
4. Whether `omarchy-launch-tui` exports an env marker (would let the shim
   distinguish dispatch invocations from direct use — optional hardening).
5. Agents panel rendering of a record with `limits: []`.
6. Which of the 13 agent names are actually installed on this machine
   (`command -v`) to pick the shadow name safely.
7. `max serve` endpoint details: default port, model id, whether responses
   include `usage` (drives defaults + record stats).

### Phase 0 results (2026-09-19, Power9 host)

Phase 0 is **done and verified live** (plugin installed, enabled, IPC
target registered, probe round-trip both ways):

1. `omarchy plugin add` from a local path: not tested; manual `git clone`
   into `~/.config/omarchy/plugins/` + `rescanPlugins` + `omarchy plugin
   enable` works (enable needs no TTY).
2. Settings round-trip: verified. `omarchy bar set jbettcher.qwen baseUrl
   '…'` writes the inline entry; the running widget's `settings` live-patch
   confirmed by IPC `status` reflecting the new value.
3. `settingsForm` consumer: **does not exist** upstream either (only the
   weather/Spacer manifests + the shell.qml passthrough) — dead metadata.
   Our own form UI is the right call; it is built and works.
4. `omarchy-launch-tui`: no env marker (plain `setsid uwsm-app --
   xdg-terminal-exec --app-id=… -e <cmd>`). Shim guard stays name-based.
5. `limits: []`: the limits section simply hides
   (`agents/Panel.qml:593` `visible: root.limits.length > 0`). Safe.
6. Installed agent CLIs: **claude, cursor-agent, hermes, muse** — the other
   eight names are free shadow candidates. **Exclude `openclaw`**: its case
   arm runs `omarchy-launch-openclaw`, so shadowing `openclaw` would not
   intercept the dispatch.
7. `max` CLI is **not installed** on this machine (pixi + ROCm present, no
   serve process, no LLM port). Phase 0 was validated against a mock
   OpenAI endpoint (`/tmp/qwen-mock-server.py`, 127.0.0.1:8901, still
   running). Real bring-up is a separate task; `baseUrl` is configurable,
   so it can point at a remote serve host meanwhile.

**Verified end-to-end:** probe up (`ready:true` + model list), probe down
(`[Errno 111] Connection refused`, fast, no hang), IPC `status`/`probe`,
unconfigured first-run state.

**Build notes that cost a cycle each (recorded so we don't relearn them):**

- `IpcHandler` is a **`Quickshell.Io`** module type, not `Quickshell`
  (declared in `quickshell-io.qmltypes`) — the import is mandatory.
- `anchors.verticalCenter: true` on a `Text` inside the popup failed to
  compile ("unsupported type QQuickAnchorLine") — removed; Row baseline
  alignment is fine.
- **Hot-reload is broken in this quickshell build**: `shell.qml:1470`
  guards `Qt.clearComponentCache()`, which **does not exist in
  `/usr/bin/quickshell`** (strings-verified). The engine caches
  `QQmlComponent` per URL, so QML source edits to an already-loaded plugin
  are invisible until `omarchy-restart-shell`. Bare `rescanPlugins` does NOT
  clear the cache — it reuses the stale compiled component. Upstream bug
  worth filing (the shell README promises save-to-reload).
- Plugin rename `jbettcher.qwen` → `jbettcher.local-model` (2026-09-19,
  scope broadened to any OpenAI-compatible local model): settings saved
  under the old id in shell.json had to be migrated to the new entry —
  `omarchy bar set` keys on the current id, so a rename orphans saved
  values.

### Phase 1 + 2 results (2026-09-19)

**Phase 1 (connectivity) done + E2E-verified**: `chat` mode (plain + SSE
streaming), the 8-name shim, install.sh. Verified against the mock (8901)
and live against qwen3.8-27b on 192.168.2.50:8080 through the real
`omarchy agent --inline --prompt` dispatch. Generalized apply writers
(`apply --agent qwen|opencode`) verified against a copy of the real
`~/.qwen/settings.json` and a test opencode.json — panel buttons
"APPLY ENDPOINT TO" cover Qwen Code / OpenCode / omarchy shim.

**Phase 2 (visibility) done**: `record` now *always* persists
`~/.local/state/omarchy/agents/usage/jbettcher.local-model.json` (0600,
matching the other records) in **both** the configured and not-configured
branches — the earlier bug was an early `return 0` in the not-configured
path before the write, so the dashboard never saw the file. Stats come
from `requests.jsonl`; `todayTotalTokens` is accumulated from
`promptTokens`/`completionTokens` (the streaming path now captures
`usage` from the final SSE chunk — llama.cpp/MAX report it). Local model:
`limits: []` (confirmed with the maintainer: no limits for local, token
info is the useful part; the section hides cleanly). Panel height cap
bumped 420→640 (upstream's dense-panel value) because the status/error
line was clipped at 420. Verified: file on disk + `jq` clean, shell
restarted, IPC status `configured/ready true`.

### First-class Qwen Code agent — test aborted 2026-09-19 (findings kept)

Maintainer pivoted: instead of the shadow-name shim, **Qwen Code should be a
first-class Omarchy agent** — a "Qwen Code" entry in the default-agent menu,
bug reports (`omarchy agent crash`) delivered to the real `qwen` harness
(which talks to the local model), the plugin keeping its role as the
harness configurator. A live test was started and then **aborted at the
maintainer's request; no system files were modified** (the `/usr` edit
attempt failed EACCES before writing; no PATH shadows were created; default
agent is still `claude`). Facts learned, verified on this host:

- Crash flow is `exec omarchy-agent --prompt "$prompt"`
  (`omarchy-agent-crash:52`) — a `qwen)` case arm in the dispatch is the only
  delivery change needed.
- **Arm shape: `command=(qwen -y); [[ -n ${prompt:-} ]] && command+=("$prompt")`
  — bare positional, NO `--`.** `qwen -y -- "prompt"` fails on this build
  (gemini-cli fork): "No input provided via stdin" — the `--` swallows the
  positional. `-y` is the yolo flag. (The positive `qwen -y "prompt"` run
  was interrupted before confirmation — re-verify first thing.)
- `~/.local/bin/qwen` is the maintainer's wrapper: probes the .50 llama
  servers, sets `OPENAI_MODEL`/`OPENAI_BASE_URL`, execs user-level
  qwen-code 0.24.1 (`~/.local/lib/qwen-code/node_modules/.bin/qwen`). No
  `/usr/bin/qwen`. `omarchy-default-agent` needs a `qwen)` case too
  (`name="Qwen Code"`, no `agent_package` — `user_install()` already detects
  `~/.local/bin/qwen`).
- Menu entries live in the **omarchy-settings** package
  (`usr/share/omarchy/default/omarchy/omarchy-menu.jsonc`, plus config/skel
  copies); user-extension `~/.config/omarchy/extensions/omarchy-menu.jsonc`
  (hot-reloaded) can add `setup.default.agent.qwen` for a no-package test.
- **Test constraint:** no passwordless sudo; `omarchy agent` execs
  `$OMARCHY_BIN_DIR/omarchy-agent` by absolute path (`resolve_direct_route`),
  and `omarchy-agent-crash`'s `exec omarchy-agent` resolves
  `/usr/share/omarchy/bin` (PATH 5) before `~/.local/bin` (PATH 9) — so a
  production-path live test needs either a sudo edit of the installed
  script(s) or running a patched copy directly with a prefixed PATH.
- Future Qwen Code dashboard tab: `~/.qwen/usage_record.jsonl` has full
  per-session stats (per-model requests/in/out/cached/thoughts tokens,
  tools, files, skills); also `~/.qwen/usage/token-usage-YYYY-MM.jsonl`.

## 5. Corrections to the reviewer draft (do not re-derive)

The reviewer agent returned a design inline but **did not write the file it
was asked to create** (`omarchy-qwen-plugin-scope.md` was never on disk).
Its draft contained four errors, all fixed in this document:

1. *Collector on PATH*: it planned `~/.local/bin/omarchy-agent-usage-qwen` —
   dead, because `omarchy-agent-usage-update` only globs
   `$OMARCHY_PATH/bin` (§2.4). Fix: service writes the record file directly
   in the standalone phase.
2. *Agent menu*: it saw only the usage dashboard. The default-agent picker
   (omarchy-menu Setup → Defaults → Agent, with the user-extension JSONC
   point) is the other half of "the agent menu" (§2.5, §3.4).
3. *Networking*: it said "QML's NetworkAccessManager or similar". The shell
   does **no** QML networking; the stack pattern is python3+urllib helpers
   spawned from QML (§2.1, §3.5).
4. *Settings*: it assumed `barWidget.schema` is auto-rendered by a generic
   dialog. No such renderer exists in the installed tree (`settingsForm`
   consumer unfound); plan for a hand-built form from `Ui/` components,
   pending phase-0 item 3.
5. *Hijack guard*: it proposed symlinking a name without addressing that the
   shadow also intercepts **direct** use of the real agent. Mitigations:
   pick a name the user doesn't use (Q1), verify PATH order in install.sh,
   optional env-marker guard (phase-0 item 4).

## 6. Open questions for the maintainer

1. **Shadow name** — which of the 13 hardcoded agent names to shadow for the
   phase-1 shim? (Unused candidates to check: grok, crush, muse, omp, hermes,
   openclaw, copilot.)
2. **Endpoint defaults** — default `baseUrl` (what port does `max serve`
   run on here?) and default `model` id?
3. **Reporting scope** — should the local flow only *analyze* the crash, or
   also offer to file the bug upstream (diagnose-crash skill's
   `reporting.md` path) once analysis looks like an Omarchy bug?
4. **Settings UI** — is the panel-inline form sufficient, or do you want a
   dedicated "Local AI" settings panel (only matters if phase-0 item 3 finds
   no generic renderer)?
5. **Usage history retention** — the helper's request log gives real
   day/model/token stats for a local model; keep 7 days, 30 days, forever?
6. **Repo location** for the standalone phase — local git under
   `Development/`, private GitHub (cleaner for `omarchy plugin add/update`)?
7. **Terminal streaming** — stream the reply token-by-token in the shim's
   terminal (recommended) or print once at the end?

## 7. Risks (top)

- **Shadowing footgun**: `~/.local/bin/<name>` intercepts direct use of that
  real agent too. Pick an unused name; document loudly in the panel and
  install.sh output.
- **Upgrade drift**: the only contract is the flag shape of the shadowed
  case arm in `omarchy-agent`; an omarchy upgrade that changes it breaks the
  shim silently (it'll pass different flags to the helper). Phase 3: shim
  validates the flags it sees and errors loudly on unknown shapes.
- **Endpoint down during a crash flow**: shim must fail fast with an
  actionable message, never hang a terminal.
- **Payload size**: coredump backtraces can be large — helper enforces a
  `maxPromptChars` cap (default ~24k chars) with a truncation notice.
- **Hot-reload**: a timer-owning service torn down on plugin hot-reload;
  consider `keepLoaded: true` (lock-screen precedent) in phase 3.
- **Hot-reload gap (phase-0 finding)**: while the quickshell build lacks
  `Qt.clearComponentCache`, every QML iteration needs
  `omarchy-restart-shell` (file-watch "reloads" recompile stale source).
  File upstream; it also makes phase-3 iteration slower than it looks.
