/*
 * btime: a ppc64le replacement for Obsidian's bundled
 * resources/app.asar.unpacked/node_modules/btime/binding.node
 *
 * LOCAL WORKAROUND, not upstreamable. This is Obsidian's own module, not npm
 * btime 1.0.3 (github.com/keldonia/bTime). That package is an unrelated
 * pure-JS scheduling library with no native code. Obsidian's copy has
 * package.json "btime" 1.0.0, "license": "UNLICENSED", "Change the birth time
 * (btime) of a file on Windows and MacOS", and no published source. Its
 * index.js loads the binding unconditionally but calls it only on darwin and
 * win32:
 *
 *   binding.btime(path: Buffer, NUL-terminated, btime: integer ms) -> number
 *       0 on success; anything else makes index.js throw
 *   ...
 *   // Linux does not support btime.
 *
 * Linux has no system call that sets a file's birth time, so there is nothing
 * to implement. The module still has to load. If require('./binding.node')
 * throws, as an x86-64 .node does here, obsidian.asar's try/catch drops btime
 * support without a word. That is harmless on Linux, but it is an exception
 * on every launch. This binding checks its arguments the way the original's
 * index.js expects and returns ENOSYS, so anything that did call it on Linux
 * gets an error rather than a false success.
 *
 * SPDX-License-Identifier: 0BSD
 */
#define NAPI_VERSION 8
#include <node_api.h>

#include <errno.h>
#include <stdbool.h>

static napi_value btime(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2], result;
  bool is_buffer = false;
  napi_valuetype type = napi_undefined;

  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2) {
    napi_throw_type_error(env, NULL, "btime(path, btime): two arguments required");
    return NULL;
  }
  napi_is_buffer(env, argv[0], &is_buffer);
  if (!is_buffer) {
    napi_throw_type_error(env, NULL, "path must be a buffer");
    return NULL;
  }
  napi_typeof(env, argv[1], &type);
  if (type != napi_number) {
    napi_throw_type_error(env, NULL, "btime must be a number");
    return NULL;
  }
  napi_create_int32(env, ENOSYS, &result);
  return result;
}

NAPI_MODULE_INIT() {
  napi_value fn;
  if (napi_create_function(env, "btime", NAPI_AUTO_LENGTH, btime, NULL, &fn) != napi_ok ||
      napi_set_named_property(env, exports, "btime", fn) != napi_ok)
    return NULL;
  return exports;
}
