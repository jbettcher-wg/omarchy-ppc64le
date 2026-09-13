/*
 * get-fonts: a ppc64le replacement for Obsidian's bundled
 * resources/app.asar.unpacked/node_modules/get-fonts/binding.node
 *
 * LOCAL WORKAROUND, not upstreamable. Obsidian ships this module only as an
 * x86-64 binary. Its package.json says "license": "UNLICENSED", lists
 * binding.cc/binding.gyp that aren't included, and there is no published
 * source. What it does was read from three places: its index.js, the ELF's
 * symbol table, and the one call site in obsidian.asar.
 *
 *   index.js:       module.exports = { getFonts: () => binding.getFonts() }
 *   obsidian.asar:  await require("get-fonts").getFonts()  -> array of names
 *   x86 binding:    a FontWorker (Napi::AsyncWorker) whose Execute() calls
 *                   FcInit, FcPatternCreate, FcObjectSetBuild, FcFontList,
 *                   FcPatternGetString(FC_FAMILY); resolved with a
 *                   napi_create_promise deferred
 *
 * So: getFonts() -> Promise<string[]> of fontconfig family names, listed on a
 * worker thread. This does the same in plain C Node-API, so it needs no
 * node-addon-api. obsidian.asar de-duplicates the list itself (it collects
 * into a Set), so this doesn't.
 *
 * SPDX-License-Identifier: 0BSD
 */
#define NAPI_VERSION 8
#include <node_api.h>

#include <fontconfig/fontconfig.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  napi_async_work work;
  napi_deferred deferred;
  char **families;
  size_t count;
  const char *error;
} font_job;

/* Worker thread: no JavaScript values may be touched here. */
static void list_families(napi_env env, void *data) {
  font_job *job = data;
  FcPattern *pattern = NULL;
  FcObjectSet *objects = NULL;
  FcFontSet *set = NULL;
  (void)env;

  if (!FcInit()) {
    job->error = "getFonts: FcInit failed";
    return;
  }
  pattern = FcPatternCreate();
  objects = FcObjectSetBuild(FC_FAMILY, (char *)NULL);
  if (pattern && objects)
    set = FcFontList(NULL, pattern, objects);
  if (!set) {
    job->error = "getFonts: FcFontList failed";
    goto out;
  }

  job->families = calloc((size_t)set->nfont + 1, sizeof(char *));
  if (!job->families) {
    job->error = "getFonts: out of memory";
    goto out;
  }
  for (int i = 0; i < set->nfont; i++) {
    FcChar8 *family;
    if (FcPatternGetString(set->fonts[i], FC_FAMILY, 0, &family) == FcResultMatch) {
      char *copy = strdup((const char *)family);
      if (copy)
        job->families[job->count++] = copy;
    }
  }

out:
  if (set)
    FcFontSetDestroy(set);
  if (objects)
    FcObjectSetDestroy(objects);
  if (pattern)
    FcPatternDestroy(pattern);
}

/* Main thread: settle the promise and free the job. */
static void settle(napi_env env, napi_status status, void *data) {
  font_job *job = data;
  napi_value value;

  if (status == napi_ok && !job->error &&
      napi_create_array_with_length(env, job->count, &value) == napi_ok) {
    for (size_t i = 0; i < job->count; i++) {
      napi_value name;
      if (napi_create_string_utf8(env, job->families[i], NAPI_AUTO_LENGTH, &name) == napi_ok)
        napi_set_element(env, value, (uint32_t)i, name);
    }
    napi_resolve_deferred(env, job->deferred, value);
  } else {
    napi_value message;
    const char *text = job->error ? job->error : "getFonts: cancelled";
    napi_create_string_utf8(env, text, NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, NULL, message, &value);
    napi_reject_deferred(env, job->deferred, value);
  }

  for (size_t i = 0; i < job->count; i++)
    free(job->families[i]);
  free(job->families);
  napi_delete_async_work(env, job->work);
  free(job);
}

static napi_value get_fonts(napi_env env, napi_callback_info info) {
  napi_value promise, resource_name;
  font_job *job = calloc(1, sizeof *job);
  (void)info;

  if (!job) {
    napi_throw_error(env, NULL, "getFonts: out of memory");
    return NULL;
  }
  if (napi_create_promise(env, &job->deferred, &promise) != napi_ok ||
      napi_create_string_utf8(env, "getFonts", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
      napi_create_async_work(env, NULL, resource_name, list_families, settle, job,
                             &job->work) != napi_ok) {
    free(job);
    napi_throw_error(env, NULL, "getFonts: could not create work");
    return NULL;
  }
  if (napi_queue_async_work(env, job->work) != napi_ok) {
    napi_delete_async_work(env, job->work);
    free(job);
    napi_throw_error(env, NULL, "getFonts: could not queue work");
    return NULL;
  }
  return promise;
}

NAPI_MODULE_INIT() {
  napi_value fn;
  if (napi_create_function(env, "getFonts", NAPI_AUTO_LENGTH, get_fonts, NULL, &fn) != napi_ok ||
      napi_set_named_property(env, exports, "getFonts", fn) != napi_ok)
    return NULL;
  return exports;
}
