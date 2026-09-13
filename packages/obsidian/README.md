# obsidian (powerpc64le)

Obsidian is closed source, and its release tarball is Electron plus JavaScript.
Arch's recipe installs only the tarball's `resources/` on top of the system
`electron43`, and this recipe does the same. The one thing that stops that
working unchanged on ppc64le is `resources/app.asar.unpacked/node_modules/`,
which holds two x86-64 Node-API modules. Both are Obsidian's own. Their
`package.json` files say `"license": "UNLICENSED"` and list `binding.cc` and
`binding.gyp`, which the tarball doesn't include, and neither module is
published anywhere. `btime.c` and `get-fonts.c` here are small ppc64le
replacements with the same exported interface, built with node-gyp against
Electron 43.7.0's node headers.

## btime

**Not npm `btime`.** npm `btime` 1.0.3 (github.com/keldonia/bTime, MIT) is an
unrelated pure-JS scheduling library with no native code. Obsidian's module is
`btime` 1.0.0, "Change the birth time (btime) of a file on Windows and MacOS".

| | |
|---|---|
| interface (`index.js`) | `binding.btime(pathBuffer, btimeMs)` returns 0 on success, otherwise `index.js` throws |
| when it is called | only when `process.platform` is `darwin` or `win32`. The Linux branch is the comment `// Linux does not support btime.` |
| x86 ELF | Node-API only (`napi_is_buffer`, `napi_get_value_int64`, ...), `libstdc++`, no other libraries |
| obsidian.asar | `try { (p = require("btime")) && (h = (e, t) => p.btime(e, t)) } catch (e) {}` |

Linux has no system call that sets a file's birth time, so the replacement
checks its arguments and returns `ENOSYS`. It is never called on Linux. It
exists so the module loads: an x86-64 `.node` makes `require` throw on every
launch, and although obsidian.asar catches that, the throw still happens.

## get-fonts

| | |
|---|---|
| interface (`index.js`) | `getFonts: () => binding.getFonts()` |
| obsidian.asar | `await require("get-fonts").getFonts()`, results collected into a Set for the font pickers (Settings > Appearance), failure swallowed |
| x86 ELF | links `libfontconfig.so.1`. Imports `FcInit FcPatternCreate FcObjectSetBuild FcFontList FcPatternGetString FcFontSetDestroy`, and `napi_create_promise`/`napi_create_async_work`. Symbols `FontWorker::Execute/OnOK/OnError`, `getAvailableFonts(std::vector<char*>&)`, source file `fontsLinux.cc` |

So `getFonts()` returns a Promise of fontconfig family names, listed on a worker
thread. The macOS counterpart `fontsMac.mm`, which is in the tarball, confirms
the shape: one family name per matched font descriptor. `get-fonts.c` does the
fontconfig work in Node-API async work and resolves an array of UTF-8 strings.

If it were removed, the call would reject and Obsidian would swallow the error,
so the app would still work. The font pickers would just list no installed
fonts.

## No x86 code shipped

`package()` installs `resources/` except the two `.node` files, installs the
two ppc64le builds in their place, and then fails if `file` reports any ELF in
`$pkgdir` that isn't PowerPC. The tarball's Electron runtime, `obsidian-cli`
and top-level `.so` files are never installed, exactly as in Arch's recipe.

## Licence

`license=('LicenseRef-Obsidian')`, the same as Arch. `LICENSE-Obsidian` is
Obsidian's licence overview. It permits free use and reserves Obsidian's rights
to the app's code, and it does not grant redistribution. Arch ships the package
under a written permission from Obsidian to Arch Linux: the file `Packaging
permission from Arch Linux.eml` in Arch's packaging repository. That permission
names Arch, so it isn't copied here and doesn't cover this repository.
