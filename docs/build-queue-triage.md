# bq work queue

Generated 2026-09-05 21:52 from `.bq-state.json`. Grouped by failure class, because on POWER the class *is* the fix.

## broken-system-dep (1)

An installed library has an unresolved symbol -- an Arch POWER bug, not ours.

- **hyprgraphics** — `/usr/bin/ld: /usr/lib/libheif.so: undefined reference to 'de265_get_security_limits'`
  - log: `/tmp/omarchy-bq/logs/hyprgraphics.log`

## missing-dep (2)

A build dependency is not present. Build it first, or add it to the queue.

- **grim** — `not installed: bash-completion fish`
  - log: `/tmp/omarchy-bq/logs/grim.log`
- **libdatachannel** — `not installed: libsrtp`
  - log: `/tmp/omarchy-bq/logs/libdatachannel.log`
