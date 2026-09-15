-- blink.cmp: build the Rust fuzzy matcher here instead of downloading it.
--
-- blink.cmp's matcher is a Rust cdylib (`blink-cmp-fuzzy`). Upstream publishes
-- prebuilt binaries on GitHub releases for x86_64 and aarch64 only, and the
-- default `fuzzy.implementation = 'prefer_rust_with_warning'` tries to download
-- one. On ppc64le there is nothing to download, so every start produced a
-- warning and the matcher silently fell back to the Lua implementation.
--
-- Same shape as no-mason-downloads.lua -- a prebuilt-binary channel with no
-- POWER assets -- but the fix is the opposite one: the crate builds fine here,
-- so build it. `cargo build --release` in the plugin directory takes ~40s on
-- this machine (POWER9, rust 1.97, `-C target-cpu=pwr9` from ~/.cargo) and
-- produces target/release/libblink_cmp_fuzzy.so, which is exactly what the
-- downloader would have placed there. lazy.nvim runs `build` on install and on
-- every update, so it stays in step with the checked-out tag.
--
-- `implementation = 'prefer_rust'` rather than 'rust': if the build ever fails
-- (no cargo, no network for crates.io), completion still works through the Lua
-- matcher instead of erroring. Dropping the `_with_warning` suffix is the point
-- -- with downloads off, the warning would fire on a working setup.
--
-- Architecture-neutral: on x86_64 this builds from source rather than
-- downloading, which a distribution package should prefer anyway.
return {
  {
    "saghen/blink.cmp",
    build = "cargo build --release",
    opts = {
      fuzzy = {
        implementation = "prefer_rust",
        prebuilt_binaries = { download = false },
      },
    },
  },
}
