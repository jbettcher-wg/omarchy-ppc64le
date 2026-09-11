# `ngspice`

Local copy of Arch's recipe with one change, and only one:

```diff
-_manual_pkgver=46 # manual seems to lag a bit behind
+_manual_pkgver=47
```

Upstream's comment was true once. It is not now: the recipe builds the URL as

    .../ng-spice-rework/$pkgver/ngspice-$_manual_pkgver-manual.pdf

so with `pkgver=47` and `_manual_pkgver=46` it asks SourceForge for
`ng-spice-rework/47/ngspice-46-manual.pdf`, which does not exist -- the 46
manual was moved to `old-releases/46/` when 47 shipped. The 12 MB source
tarball downloads fine; the build dies at 100% on the PDF with

    curl: (22) The requested URL returned error: 404

`ngspice-47-manual.pdf` exists under `47/`, so the versions no longer need to
differ. Checked 2026-09-10: `47/ngspice-47-manual.pdf` 200,
`46/ngspice-46-manual.pdf` 404, `old-releases/46/ngspice-46-manual.pdf` 200.

Needed for `kicad`, whose cmake requires ngspice for the simulator and fails
configure without it. Nothing in Arch POWER ships ngspice.

Drop this directory when Arch bumps `_manual_pkgver` upstream.

The manual's `sha512sums`/`b2sums` entries are updated to match the 47 PDF;
the source tarball's checksums are untouched.

A note on getting that hash right: fetching the PDF by hand with
`curl -sL <sourceforge url>` returned a **1.4 MB** file, while makepkg's own
download of the same URL returned **2.6 MB**. Both were valid `%PDF-1.5`.
SourceForge hands out different mirrors and one of them serves a smaller copy,
so a checksum computed from a hand-fetched file does not necessarily match what
the build will see. These hashes come from the artifact in `$SRCDEST` after
makepkg downloaded it.
