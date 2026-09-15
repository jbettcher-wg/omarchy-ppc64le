#!/bin/bash
# Run llama.cpp (this package, staged by bq) on the RX 7900 XTX through the
# staged ROCm 7.2.4 stack, under the same bwrap overlay bq builds with.
# Nothing is installed.  ROCM_PATH/LD_LIBRARY_PATH stand in for what an
# installed rocm-core's profile.d and ld.so.conf.d provide (../rocm-llvm).
set -u
SYSROOT=${SYSROOT:-/var/tmp/hip-bq/sysroot}
MODEL=${MODEL:-/mnt/back-up/models/Qwen3-8B-Q4_K_M.gguf}
OUT=${OUT:-/var/tmp/hip-bq/validate-llama}; mkdir -p $OUT
BW=(bwrap --dev-bind / / --overlay-src /usr --overlay-src $SYSROOT/usr --ro-overlay /usr
          --overlay-src /opt --overlay-src $SYSROOT/opt --ro-overlay /opt
    env ROCM_PATH=/opt/rocm LD_LIBRARY_PATH=/opt/rocm/lib HOME=$HOME)
run() { echo "\$ $*"; "${BW[@]}" "$@"; echo "[exit $?]"; }
PROMPT='Explain in three short paragraphs why the sky is blue, then list the three primary colours of light.'
case "${1:-all}" in
  info|all)
    run /usr/bin/llama-cli --version
    run bash -c "ldd /usr/bin/llama-completion | grep -E 'ggml|hip|rocblas|llama'"
    ;;&
  gen|all)
    # One-shot completion, greedy, fully offloaded.  The log lines that matter:
    #   ggml_cuda_init: found 1 ROCm devices: Device 0: AMD Radeon RX 7900 XTX
    #   load_tensors: offloaded 37/37 layers to GPU
    #   load_tensors: ROCm0 model buffer size = ...
    # and the timing block at the end (prompt eval / eval tokens per second).
    run /usr/bin/llama-completion -m "$MODEL" -ngl 99 -n 256 --temp 0 -t 16 \
        -p "$PROMPT" 2>&1 | tee $OUT/gen.log | grep -E "ROCm|offloaded|buffer size|tokens per second|eval time|load time|^llama_perf|ggml_cuda_init|Device 0|^[A-Za-z]" | head -80
    ;;&
  bench|all)
    ( sleep 25; for i in 1 2 3; do "${BW[@]}" /opt/rocm/bin/rocm-smi --showuse --showpower --showclocks 2>/dev/null | grep -E "GPU use|Average Graphics|sclk clock" ; sleep 3; done ) > $OUT/smi-during-bench.log 2>&1 &
    run /usr/bin/llama-bench -m "$MODEL" -ngl 99 -t 16 -p 512 -n 128 -r 3 2>&1 | tee $OUT/bench.log | tail -12
    wait; echo "--- rocm-smi during bench"; cat $OUT/smi-during-bench.log
    run bash -c "sleep 4; /opt/rocm/bin/rocm-smi --showuse --showpower | grep -E 'GPU use|Average Graphics'"
    ;;
esac
