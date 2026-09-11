#include <stdio.h>
#include <string.h>
#include <math.h>
__attribute__((noinline)) __bf16 tobf(float f) { return (__bf16)f; }
__attribute__((noinline)) float frombf(__bf16 b) { return (float)b; }
__attribute__((noinline)) __bf16 addbf(__bf16 a, __bf16 b) { return a + b; }
int main(void) {
  float vals[] = {1.0f, 1.5f, 3.140625f, -2.75f, 65504.0f, 1e-3f, 0.1f};
  int bad = 0;
  for (int i = 0; i < 7; i++) {
    __bf16 b = tobf(vals[i]); unsigned short bits; memcpy(&bits, &b, 2);
    float back = frombf(b);
    /* reference: round-to-nearest-even of the top 16 bits */
    unsigned u; memcpy(&u, &vals[i], 4); unsigned lsb = (u >> 16) & 1; unsigned r = (u + 0x7FFF + lsb) >> 16; float ref; unsigned ru = r << 16; memcpy(&ref, &ru, 4);
    printf("%12g -> 0x%04x -> %12g (ref %12g)%s\n", vals[i], bits, back, ref, back == ref ? "" : "  MISMATCH");
    if (back != ref) bad++;
  }
  __bf16 s = addbf(tobf(1.5f), tobf(2.25f)); printf("1.5+2.25 = %g\n", frombf(s)); if (frombf(s) != 3.75f) bad++;
  puts(bad ? "BF16-FAIL" : "BF16-OK"); return bad;
}
