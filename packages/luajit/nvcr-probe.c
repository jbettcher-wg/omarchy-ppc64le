/* ELFv2 non-volatile CR field probe.
 *
 * CR2, CR3 and CR4 are non-volatile in the ELFv2 ABI: a callee that writes
 * them must restore them.  GCC relies on this - neovim's do_cmdline() caches
 * `flags & DOCMD_EXCRESET` in CR3 across ~8000 instructions and many calls.
 *
 * This sets a known pattern in CR2/CR3/CR4, calls into LuaJIT, and reports
 * which fields came back changed.
 */
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

static inline unsigned rdcr(void)
{
  unsigned cr;
  __asm__ volatile("mfcr %0" : "=r"(cr));
  return cr;
}

/* CR0 is the most significant nibble. */
#define CRF(cr, n) (((cr) >> (28 - 4*(n))) & 0xF)

static int nclob = 0;

#define PROBE(label, stmt) do {                                            \
  unsigned before, after;                                                  \
  __asm__ volatile("cmpwi cr2, %0, 0\n\tcmpwi cr3, %1, 0\n\tcmpwi cr4, %2, 0" \
                   :: "r"(1), "r"(0), "r"(-1) : "cr2", "cr3", "cr4");      \
  before = rdcr();                                                         \
  stmt;                                                                    \
  after = rdcr();                                                          \
  if (CRF(before,2) != CRF(after,2) || CRF(before,3) != CRF(after,3)       \
      || CRF(before,4) != CRF(after,4)) {                                  \
    printf("CLOBBER %-28s cr2 %x->%x  cr3 %x->%x  cr4 %x->%x\n", label,    \
           CRF(before,2), CRF(after,2), CRF(before,3), CRF(after,3),       \
           CRF(before,4), CRF(after,4));                                   \
    nclob++;                                                               \
  } else {                                                                 \
    printf("ok      %-28s\n", label);                                      \
  }                                                                        \
} while (0)

static lua_State *L;

static void run(const char *code)
{
  if (luaL_loadstring(L, code) || lua_pcall(L, 0, 0, 0)) {
    fprintf(stderr, "lua error: %s\n", lua_tostring(L, -1));
    lua_pop(L, 1);
  }
}

static int cfunc(lua_State *l) { lua_pushinteger(l, 7); return 1; }

int main(void)
{
  L = luaL_newstate();
  luaL_openlibs(L);
  lua_pushcfunction(L, cfunc);
  lua_setglobal(L, "cfunc");

  PROBE("baseline (no lua)",            (void)0);
  PROBE("luaL_newstate done above",     (void)0);
  PROBE("lua_pcall trivial",            run("local x = 1"));
  PROBE("arith loop",                   run("local s=0 for i=1,100 do s=s+i end"));
  PROBE("string ops",                   run("local s='' for i=1,50 do s=s..i end"));
  PROBE("table ops",                    run("local t={} for i=1,200 do t[i]=i*2 end table.sort(t)"));
  PROBE("pcall error",                  run("pcall(function() error('x') end)"));
  PROBE("error through C boundary",     run("local ok,e = pcall(function() local t=nil return t.x end)"));
  PROBE("coroutine",                    run("local co=coroutine.wrap(function() coroutine.yield(1) return 2 end) co() co()"));
  PROBE("string.format/gsub",           run("local s=('%d'):format(42):gsub('4','5')"));
  PROBE("C function call from lua",     run("for i=1,100 do cfunc() end"));
  PROBE("string.buffer",                run("local sb=require('string.buffer') local b=sb.new() b:put('hi') b:get()"));
  PROBE("ffi cdef + call",              run("local ffi=require('ffi') ffi.cdef[[double pow(double,double);]] local x=ffi.C.pow(2,10)"));
  PROBE("bytecode dump/load",           run("local f=loadstring('return 1') local s=string.dump(f) loadstring(s)()"));
  PROBE("gc step",                      run("collectgarbage('collect')"));
  PROBE("hot loop (JIT compiles)",      run("local s=0 for i=1,2000000 do s=s+i%7 end"));
  PROBE("hot string loop",              run("local n=0 for i=1,200000 do n=n+#tostring(i) end"));
  PROBE("hot ffi loop",                 run("local ffi=require('ffi') local a=ffi.new('double[8]') for i=1,200000 do a[i%8]=i end"));
  PROBE("hot coroutine loop",           run("local co=coroutine.wrap(function() for i=1,200000 do coroutine.yield(i) end end) local s=0 for i=1,200000 do s=s+co() end"));
  PROBE("trace exit / side trace",      run("local s=0 for i=1,300000 do if i%1000==0 then s=s+1.5 else s=s+1 end end"));

  printf("\n%d clobbering operation(s)\n", nclob);
  lua_close(L);
  return nclob != 0;
}
