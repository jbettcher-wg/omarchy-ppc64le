// vectorAdd with a real numeric check, plus the agent identity so the run
// cannot be mistaken for a host fallback.
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>

#define CK(x) do { hipError_t e = (x); if (e != hipSuccess) { \
  fprintf(stderr, "%s:%d %s -> %s\n", __FILE__, __LINE__, #x, hipGetErrorString(e)); return 2; } } while (0)

__global__ void vecadd(const float* a, const float* b, float* c, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) c[i] = a[i] * 2.0f + b[i];
}

int main() {
  int ndev = 0;
  CK(hipGetDeviceCount(&ndev));
  hipDeviceProp_t p;
  CK(hipGetDeviceProperties(&p, 0));
  printf("devices=%d name=\"%s\" gcnArchName=%s CUs=%d pci=%04x:%02x:%02x totalMem=%zu MiB\n",
         ndev, p.name, p.gcnArchName, p.multiProcessorCount, p.pciDomainID, p.pciBusID, p.pciDeviceID,
         (size_t)(p.totalGlobalMem >> 20));

  const int n = 1 << 22;  // 4M floats
  std::vector<float> a(n), b(n), c(n, -1.0f);
  for (int i = 0; i < n; i++) { a[i] = 0.001f * (i % 1000); b[i] = 3.0f - 0.5f * (i % 7); }
  float *da, *db, *dc;
  CK(hipMalloc(&da, n * sizeof(float)));
  CK(hipMalloc(&db, n * sizeof(float)));
  CK(hipMalloc(&dc, n * sizeof(float)));
  CK(hipMemcpy(da, a.data(), n * sizeof(float), hipMemcpyHostToDevice));
  CK(hipMemcpy(db, b.data(), n * sizeof(float), hipMemcpyHostToDevice));
  CK(hipMemset(dc, 0, n * sizeof(float)));
  hipLaunchKernelGGL(vecadd, dim3((n + 255) / 256), dim3(256), 0, 0, da, db, dc, n);
  CK(hipGetLastError());
  CK(hipDeviceSynchronize());
  CK(hipMemcpy(c.data(), dc, n * sizeof(float), hipMemcpyDeviceToHost));
  long bad = 0; double maxerr = 0;
  for (int i = 0; i < n; i++) {
    float want = a[i] * 2.0f + b[i];
    double err = fabs((double)c[i] - want);
    if (err > maxerr) maxerr = err;
    if (err > 1e-5f) { if (bad < 5) printf("  mismatch i=%d got=%f want=%f\n", i, c[i], want); bad++; }
  }
  printf("checked %d elements, %ld mismatches, max abs err %g\n", n, bad, maxerr);
  printf("c[0]=%f c[1]=%f c[n-1]=%f (want %f %f %f)\n", c[0], c[1], c[n-1],
         a[0]*2+b[0], a[1]*2+b[1], a[n-1]*2+b[n-1]);
  CK(hipFree(da)); CK(hipFree(db)); CK(hipFree(dc));
  puts(bad == 0 ? "VECADD-OK" : "VECADD-FAIL");
  return bad == 0 ? 0 : 1;
}
