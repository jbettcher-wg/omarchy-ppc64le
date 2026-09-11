# `file`

Arch's recipe with one change: `--disable-libseccomp`.

## Why

`file` sandboxes itself with seccomp and kills the process (SIGSYS) on any
syscall outside its allowlist. `fakeroot` works by `LD_PRELOAD`ing libfakeroot,
which talks to the `faked` daemon over SysV IPC — `msgget`, `msgsnd`, `semop`.
Those are not on the allowlist, so **`file` dies whenever it runs under
fakeroot**, which is how makepkg runs every `package()`:

```
$ fakeroot -- file -b /usr/bin/python3.14 ; echo $?
159                      # 128 + 31 (SIGSYS)
$ coredumpctl list /usr/bin/file
... SIGSYS  present  /usr/bin/file
```

Seven cores accumulated in one day of building here.

## What it does not break

makepkg itself is unaffected: `/usr/share/makepkg/tidy/50-pestrip.sh` calls
`file --no-sandbox` explicitly, so stripping still works — verified against
`coin`, `ngspice`, `mgard` and `adios2`, all of which come out `stripped`. The
cores come from individual packages' own build scripts invoking plain `file`,
and every one of those builds still succeeded.

So this is noise, not breakage. It is fixed here because the noise is
indistinguishable from a real crash in `coredumpctl`, and a build host that
cries wolf seven times a day trains you to ignore it.

## Why disabling is the right trade

The sandbox exists to contain malicious *input* — `file` parsing a hostile
document. On a build host it is inspecting our own build output under fakeroot.
The threat it defends against is not present; the failure it causes is.

Upstream would rather add the IPC syscalls to the allowlist. If they do, drop
this directory.
