local h = require("helpers")

-- Install a fake `icebox` module BEFORE requiring `icebox.lazy` so that the
-- module-level `require("icebox")` inside lazy.lua picks up the fake.
-- Each call captures its args for assertion.
local calls = {}
local fake_return = "cafebabe00000000000000000000000000000000"
package.loaded["icebox"] = {
  thaw = function(url, opts)
    calls[#calls + 1] = { url = url, opts = opts }
    return fake_return
  end,
}

local lazy = require("icebox.lazy")

local function reset()
  calls = {}
  -- reassign the same table field so the closure captured by the fake keeps
  -- writing into the fresh `calls` reference
  package.loaded["icebox"].thaw = function(url, opts)
    calls[#calls + 1] = { url = url, opts = opts }
    return fake_return
  end
end

h.suite("lazy.cooldown: icebox_options with spec[1] shorthand")
do
  reset()
  local spec = { "user/repo", icebox_options = { branch = "main" } }
  local ret = lazy.cooldown(spec)
  h.eq(ret, spec,                              "returns same spec")
  h.eq(spec.commit, fake_return,               "commit set from thaw()")
  h.eq(#calls, 1,                              "thaw called once")
  h.eq(calls[1].url, "user/repo",              "url = spec[1] (shorthand)")
  h.eq(calls[1].opts.branch, "main",           "opts forwarded")
end

h.suite("lazy.cooldown: icebox_options with explicit url")
do
  reset()
  local spec = { url = "https://example.com/x.git", icebox_options = { tag = "v1" } }
  lazy.cooldown(spec)
  h.eq(calls[1].url, "https://example.com/x.git", "url = spec.url when spec[1] absent")
  h.eq(calls[1].opts.tag, "v1",                    "opts.tag forwarded")
end

h.suite("lazy.cooldown: icebox_options with dir only")
do
  reset()
  local spec = { dir = "/home/user/local", icebox_options = { branch = "dev" } }
  lazy.cooldown(spec)
  h.eq(calls[1].url, "file:///home/user/local", "url = file:// + spec.dir")
end

h.suite("lazy.cooldown: no icebox_options → untouched")
do
  reset()
  local spec = { "plain/plugin" }
  local ret = lazy.cooldown(spec)
  h.eq(ret, spec,                    "returns same spec")
  h.is_nil(spec.commit,              "commit not set")
  h.eq(#calls, 0,                    "thaw not called")
end

h.suite("lazy.cooldown: spec[1] wins over spec.url")
do
  reset()
  local spec = {
    "user/repo",
    url = "https://example.com/other.git",
    icebox_options = {},
  }
  lazy.cooldown(spec)
  h.eq(calls[1].url, "user/repo", "spec[1] preferred over spec.url")
end

h.suite("lazy.cooldown: usable with vim.tbl_map")
do
  reset()
  local specs = {
    { "a/one", icebox_options = { branch = "main" } },
    { "b/two" },
    { "c/three", icebox_options = { tag = "v1" } },
  }
  local out = vim.tbl_map(lazy.cooldown, specs)
  h.eq(#out, 3,                        "same count")
  h.eq(out[1].commit, fake_return,     "first spec pinned")
  h.is_nil(out[2].commit,              "second spec untouched")
  h.eq(out[3].commit, fake_return,     "third spec pinned")
  h.eq(#calls, 2,                      "thaw called only for spec with icebox_options")
end

h.summary()
