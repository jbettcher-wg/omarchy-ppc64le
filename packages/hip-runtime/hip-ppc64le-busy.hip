// Keeps the GPU busy for ~N seconds so rocm-smi can be sampled meanwhile,
// and checks its own arithmetic so it is not a no-op that got optimised away.
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <chrono>

__global__ void spin(float* out, int iters) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  float x = 1.0f + i * 1e-7f;
  for (int k = 0; k < iters; k++) x = x * 1.0000001f + 1e-9f;  // dependent chain
  out[i] = x;
}

int main(int argc, char** argv) {
  int seconds = argc > 1 ? atoi(argv[1]) : 8;
  const int n = 256 * 4096;
  float* d; hipMalloc(&d, n * sizeof(float));
  auto t0 = std::chrono::steady_clock::now();
  long launches = 0;
  while (std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() < seconds) {
    hipLaunchKernelGGL(spin, dim3(n / 256), dim3(256), 0, 0, d, 20000);
    launches++;
    if (launches % 8 == 0) hipDeviceSynchronize();
  }
  hipDeviceSynchronize();
  float h[4]; hipMemcpy(h, d, sizeof h, hipMemcpyDeviceToHost);
  double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  printf("busy: %ld launches in %.1fs, out[0..3]=%g %g %g %g (err=%s)\n", launches, secs, h[0], h[1], h[2], h[3],
         hipGetErrorString(hipGetLastError()));
  return 0;
}
