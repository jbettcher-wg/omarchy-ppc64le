# bq work queue

Generated 2026-10-04 19:56 from `.bq-state.json`. Grouped by failure class, because on POWER the class *is* the fix.

## broken-system-dep (1)

An installed library has an unresolved symbol -- an Arch POWER bug, not ours.

- **sddm** — `/var/tmp/omarchy-bq/sysroot/usr/bin/ld: /usr/lib/libQt6Quick.so.6.11.1: undefined reference to 'QUntypedPropertyBinding::QUntypedPropertyBinding(QPropertyBindin`
  - log: `/var/tmp/omarchy-bq/logs/sddm.log`

## x86-asm (6)

Genuine x86 assembly or intrinsics. Needs a generic fallback, a VSX port, or the SIMD path disabled.

- **gstreamer** — `gst-plugins-base| Has header "emmintrin.h" : YES`
  - log: `/var/tmp/omarchy-bq/logs/gstreamer.log`
- **libjxl** — `-- Performing Test CXX_MAVX2_SUPPORTED`
  - log: `/var/tmp/omarchy-bq/logs/libjxl.log`
- **libreoffice-fresh** — `checking whether ccache powerpc64le-unknown-linux-gnu-gcc supports -mno-avx... no`
  - log: `/var/tmp/omarchy-bq/logs/libreoffice-fresh.log`
- **libsoxr** — `-- Trying SIMD64 C flags: -mavx`
  - log: `/var/tmp/omarchy-bq/logs/libsoxr.log`
- **pulseaudio** — `Check usable header "cpuid.h" : NO`
  - log: `/var/tmp/omarchy-bq/logs/pulseaudio.log`
- **sdl2** — `-- Looking for immintrin.h`
  - log: `/var/tmp/omarchy-bq/logs/sdl2.log`

## missing-dep (8)

A build dependency is not present. Build it first, or add it to the queue.

- **dotnet-core** — `not in Arch POWER and not yet built: clang20 dotnet-source-built-artifacts llvm20`
  - log: `/var/tmp/omarchy-bq/logs/dotnet-core.log`
- **libbluray** — `not in Arch POWER and not yet built: apache-ant java-environment`
  - log: `/var/tmp/omarchy-bq/logs/libbluray.log`
- **pinentry** — `configure: WARNING: pkg-config could not find the modules elementary or ecore-x`
  - log: `/var/tmp/omarchy-bq/logs/pinentry.log`
- **purpose** — `-- Could NOT find org.kde.prison-QMLModule (missing: org.kde.prison-QMLModule_FOUND)`
  - log: `/var/tmp/omarchy-bq/logs/purpose.log`
- **rubberband** — `not in Arch POWER and not yet built: java-environment`
  - log: `/var/tmp/omarchy-bq/logs/rubberband.log`
- **runc** — `not in Arch POWER and not yet built: libpathrs`
  - log: `/var/tmp/omarchy-bq/logs/runc.log`
- **util-linux** — `Program po4a found: NO`
  - log: `/var/tmp/omarchy-bq/logs/util-linux.log`
- **xdg-desktop-portal** — `not in Arch POWER and not yet built: gamemode`
  - log: `/var/tmp/omarchy-bq/logs/xdg-desktop-portal.log`

## checksum (2)

Source integrity failure. Refresh sums or import the signing key.

- **fakeroot** — `==> ERROR: One or more files did not pass the validity check!`
  - log: `/var/tmp/omarchy-bq/logs/fakeroot.log`
- **zlib** — `==> ERROR: One or more files did not pass the validity check!`
  - log: `/var/tmp/omarchy-bq/logs/zlib.log`

## elf-pathguard (3)

Shipped ELF records a build-tree path. Fix the recipe's rpath handling; do not ship it.

- **boost** — `elf-pathguard: FAIL /usr/lib/python3.14/site-packages/boost/mpi.so: absolute RUNPATH outside /usr: /var/tmp/omarchy-bq/build/boost/src/boost_1_91_0/bin.v2/libs/`
  - log: `/var/tmp/omarchy-bq/logs/boost.log`
- **perl** — `elf-pathguard: FAIL /usr/lib/perl5/5.42/core_perl/auto/DB_File/DB_File.so: absolute RUNPATH outside /usr: /var/tmp/omarchy-bq/sysroot/usr/lib`
  - log: `/var/tmp/omarchy-bq/logs/perl.log`
- **signond** — `elf-pathguard: FAIL /usr/lib/libsignon-plugins.so.1.0.0: absolute RUNPATH outside /usr: /var/tmp/omarchy-bq/sysroot/usr/lib`
  - log: `/var/tmp/omarchy-bq/logs/signond.log`

## bq-error (1)

bq itself failed on this recipe -- a queue bug, not a package bug. See the recorded traceback.

- **tesseract-data** — `TimeoutExpired: Command '['makepkg', '--config', '/var/tmp/omarchy-bq/makepkg.conf', '--packagelist']' timed out after 120 seconds`
  - log: `?`

## unknown (35)

Unmatched -- read the log.

- **bun** — `  -> Cloning bun git repo...
Cloning into bare repository '/var/tmp/omarchy-bq/srcdest/bun'...
==> ERROR: 0001-Port-bun-to-ppc64le-POWER8-little-endian-glibc.pa`
  - log: `/var/tmp/omarchy-bq/logs/bun.log`
- **cups-filters** — `make: *** [Makefile:1349: all] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/cups-filters.log`
- **gnupg** — `fatal: unable to access 'https://dev.gnupg.org/source/gnupg.git/': Failed to connect to dev.gnupg.org:443 after 928 ms: Could not connect to server
==> ERROR: F`
  - log: `/var/tmp/omarchy-bq/logs/gnupg.log`
- **gpm** — `./configure: eval: line 13583: 'itz_cv_path_site_lisp= command-line-1(("-l" "/var/tmp/omarchy-bq/build/gpm/src/gpm/exec.el" "-exec" "(mapcar 'print load-path)")`
  - log: `/var/tmp/omarchy-bq/logs/gpm.log`
- **graphite** — `make: *** [Makefile:439: docs] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/graphite.log`
- **groff** — `make: *** [Makefile:19673: doc/groff.dvi] Error 1
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/groff.log`
- **jasper** — `make: *** [Makefile:166: all] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/jasper.log`
- **libasyncns** — `fatal: unable to access 'https://git.0pointer.net/clone/libasyncns.git/': SSL: no alternative certificate subject name matches target hostname 'git.0pointer.net`
  - log: `/var/tmp/omarchy-bq/logs/libasyncns.log`
- **libcanberra** — `fatal: unable to access 'https://git.0pointer.net/clone/libcanberra.git/': SSL: no alternative certificate subject name matches target hostname 'git.0pointer.ne`
  - log: `/var/tmp/omarchy-bq/logs/libcanberra.log`
- **libebur128** — `-- Configuring incomplete, errors occurred!
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/libebur128.log`
- **liblqr** — `make: *** [Makefile:400: all] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/liblqr.log`
- **libnewt** — `curl: (22) The requested URL returned error: 404
==> ERROR: Failure while downloading https://pagure.io/newt/archive/r0-52-25/newt-r0-52-25.tar.gz
    Aborting.`
  - log: `/var/tmp/omarchy-bq/logs/libnewt.log`
- **libnsbmp** — `curl: (6) Could not resolve host: download.netsurf-browser.org
==> ERROR: Failure while downloading https://download.netsurf-browser.org/libs/releases/libnsbmp-`
  - log: `/var/tmp/omarchy-bq/logs/libnsbmp.log`
- **libnsgif** — `curl: (6) Could not resolve host: download.netsurf-browser.org
==> ERROR: Failure while downloading https://download.netsurf-browser.org/libs/releases/libnsgif-`
  - log: `/var/tmp/omarchy-bq/logs/libnsgif.log`
- **libpipeline** — `curl: (22) The requested URL returned error: 502
==> ERROR: Failure while downloading https://download.savannah.gnu.org/releases/libpipeline/libpipeline-1.5.8.t`
  - log: `/var/tmp/omarchy-bq/logs/libpipeline.log`
- **librtas** — `make: *** [Makefile:456: all] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/librtas.log`
- **libsamplerate** — `-- Configuring incomplete, errors occurred!
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/libsamplerate.log`
- **libsasl** — `make: *** [Makefile:555: all] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/libsasl.log`
- **libxcrypt** — `make: *** [Makefile:1467: all] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/libxcrypt.log`
- **pam** — `A full log can be found at /var/tmp/omarchy-bq/build/pam/src/build/meson-logs/meson-log.txt
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/pam.log`
- **parted** — `make: *** [Makefile:1746: all] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/parted.log`
- **powerpc-utils** — `make: *** Waiting for unfinished jobs....
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/powerpc-utils.log`
- **python** — `make: *** [Makefile:1027: profile-run-stamp] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/python.log`
- **python-certifi** — `ValueError: Attempting to write certifi/cacert.pem outside of the target directory
==> ERROR: A failure occurred in package().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/python-certifi.log`
- **qpdf** — `make: Leaving directory '/var/tmp/omarchy-bq/build/qpdf/src/qpdf-12.3.2/build'
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/qpdf.log`
- **samba** — `yapp not found
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/samba.log`
- **tar** — `make: *** [Makefile:1822: all] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/tar.log`
- **texlive-bin** — `make: *** [Makefile:580: all-recursive] Error 1
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/texlive-bin.log`
- **thunderbird** — `Streaming resource usage profile to: /var/tmp/bq/build/thunderbird/src/thunderbird-155.0.1/obj-powerpc64le-unknown-linux-gnu/.mozbuild/logs/build/profile_log_20`
  - log: `/var/tmp/bq/logs/thunderbird.log`
- **vapoursynth** — `ERROR Backend subprocess exited when trying to invoke build_wheel
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/vapoursynth.log`
- **vulkan-icd-loader** — `-- Configuring incomplete, errors occurred!
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/vulkan-icd-loader.log`
- **xz** — `po4a/update-po: Translated man pages were not generated.
==> ERROR: A failure occurred in prepare().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/xz.log`
- **yt-dlp** — `/var/tmp/omarchy-bq/sysroot/usr/bin/python: No module named build
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/yt-dlp.log`
- **zbar** — `make: *** [Makefile:1000: all] Error 2
==> ERROR: A failure occurred in build().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/zbar.log`
- **zip** — `sed: -e expression #1, char 26: unknown option to 's'
==> ERROR: A failure occurred in prepare().
    Aborting...`
  - log: `/var/tmp/omarchy-bq/logs/zip.log`
