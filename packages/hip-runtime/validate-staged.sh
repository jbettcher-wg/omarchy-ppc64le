#!/bin/bash
# Run the HIP smoke tests against bq's staged /opt/rocm (7.2.4, ppc64le)
# using the same read-only bubblewrap overlay bq builds under.  Nothing is
# installed; the live /opt/rocm is the lower layer and untouched.
#
# ROCM_PATH and LD_LIBRARY_PATH are what an *installed* rocm-core provides
# through /etc/profile.d/rocm.sh and /etc/ld.so.conf.d/rocm.conf; the
# overlay covers /usr and /opt only, so they are set here by hand.  Without
# ROCM_PATH hipcc's clang deduces the ROCm root as /opt/rocm/lib (see
# ../rocm-llvm/README.md) and cannot find hip/hip_runtime.h; without the
# library path rocminfo cannot load librocprofiler-register.so.0.
set -u
SYSROOT=${SYSROOT:-/var/tmp/hip-bq/sysroot}
T=$(dirname "$(readlink -f "$0")")
OUT=${OUT:-/var/tmp/hip-bq/validate}; mkdir -p $OUT
BW=(bwrap --dev-bind / / --overlay-src /usr --overlay-src $SYSROOT/usr --ro-overlay /usr
          --overlay-src /opt --overlay-src $SYSROOT/opt --ro-overlay /opt)
run() { echo "\$ $*"; "${BW[@]}" env TMPDIR=/var/tmp/hip-bq/tmp ROCM_PATH=/opt/rocm LD_LIBRARY_PATH=/opt/rocm/lib "$@"; echo "[exit $?]"; }
case "${1:-all}" in
  versions|all)
    run cat /opt/rocm/.info/version
    run /opt/rocm/lib/llvm/bin/clang --version
    run /opt/rocm/bin/hipconfig --full
    ;;&
  rocminfo|all)
    run /opt/rocm/bin/rocminfo
    run /opt/rocm/bin/rocm_agent_enumerator
    ;;&
  compile|all)
    run /opt/rocm/bin/hipcc -v --offload-arch=gfx1100 -O2 -o $OUT/vecadd $T/hip-ppc64le-vecadd.hip
    run /opt/rocm/bin/hipcc --offload-arch=gfx1100 -O2 -o $OUT/busy $T/hip-ppc64le-busy.hip
    run /opt/rocm/bin/hipcc --offload-arch=gfx1100 -O2 -o $OUT/archtest $T/test.cpp
    run file $OUT/vecadd
    run bash -c "readelf -d $OUT/vecadd | grep -E 'NEEDED|RUNPATH'"
    ;;&
  run|all)
    run $OUT/vecadd
    run $OUT/archtest
    ;;&
  busy|all)
    "${BW[@]}" env LD_LIBRARY_PATH=/opt/rocm/lib $OUT/busy 10 > $OUT/busy.log 2>&1 &
    sleep 4
    for i in 1 2 3; do run /opt/rocm/bin/rocm-smi --showuse --showpower --showclocks | grep -E "GPU use|Average Graphics|sclk|mclk|GPU\[0\]" ; sleep 1.5; done
    wait; cat $OUT/busy.log
    sleep 3; run /opt/rocm/bin/rocm-smi --showuse | grep -E "GPU use"
    ;;
esac
