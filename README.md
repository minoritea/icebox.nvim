# icebox.nvim

Cooldown-based commit resolver for Neovim.

icebox.nvim returns the most recent commit hash for a Git repository that has been "in the icebox" for at least a configurable number of days. Use it with your plugin manager's commit-pinning feature to avoid adopting freshly released commits before bugs — or malicious changes — have had time to surface.

## Why

Supply-chain attacks against Neovim plugins are a real threat. icebox.nvim brings a **minimum release age** style mitigation to the ecosystem: a commit is not adopted until it has been publicly visible for a cooldown period, giving you time to notice a malicious release and pull it before it reaches your editor.

The natural place to anchor such a cooldown would be the timestamps inside a Git commit, but every one of them (author date, committer date, annotated-tag date, ref mtimes) is written by whoever produced the commit. An attacker who controls the upstream can set them to anything, so they cannot mark a trustworthy publication time.

icebox.nvim instead measures elapsed time from the point at which your local machine first observed each commit hash. That clock is the one thing an attacker cannot rewind. The cooldown is exposed as a simple function that returns a commit hash once its local observation has aged past a configurable threshold; hand that hash to your plugin manager's existing commit-pinning feature and you are done.

## Requirements

- Neovim >= 0.10
- `git` on PATH

## Installation

Clone the repository manually (icebox.nvim must be on the runtimepath before your plugin manager runs):

```bash
git clone https://github.com/minoritea/icebox.nvim ~/.local/share/nvim/icebox.nvim
```

Then add it to your runtimepath at the top of `init.lua`, before your plugin manager is loaded:

```lua
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/icebox.nvim")
```

## Cooldown

A **cooldown** is the delay between the first time your local machine observes a commit and the moment icebox.nvim is willing to return it. Every commit hash icebox sees is stamped with the local `os.time()` on first observation and persisted to a JSON file on disk; only commits whose stored stamp is at least `cooldown_days` old are eligible to be returned. Anything younger is withheld.

Think of icebox.nvim as a freezer: commits arrive, sit inside for the cooldown period, and only come out once they are chilled enough to serve.

## Usage

`setup()` is optional.

```lua
local icebox = require("icebox")

icebox.setup({
  cooldown_days      = 7,
  trust_on_first_use = true,  -- opt-in; see the note below
})

local commit = icebox.thaw("stevearc/oil.nvim") -- returns a cooled commit; hand it to your plugin manager
```

**Note.** Observations are recorded in the background, so the very first call for a URL has nothing cooled to return and fails by default. You can opt out of this by setting `trust_on_first_use = true`, which returns the latest upstream commit on that first call without waiting for the cooldown. Alternatively, pass the `trusted_commit` option to `thaw()` to trust a specific commit for an individual repository. Both are opt-in escape hatches; use them at your own discretion.

## API

### `icebox.setup(opts)`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cooldown_days` | number | `7` | Days a commit must be known before it is returned. `0` disables cooldown. |
| `trust_on_first_use` | boolean | `false` | When `true`, performs a synchronous fetch on first use and returns a hash immediately, bypassing the cooldown for that first result. |
| `branch_commits_per_fetch` | number | `500` | Maximum number of branch commits pulled per fetch (`git log -n`). Older commits already recorded in the store keep their original `fetched_at`; a later fetch that reveals commits beyond this window will pick them up over subsequent runs. |

### `icebox.thaw(url, opts)` / `icebox.thaw(opts)`

Given a repository URL, returns the newest cooled commit hash. GitHub shorthand (`owner/repo`) is also accepted. `icebox.ZERO_HASH` is returned when no cooled commit is available yet or when an error occurs.

```lua
local commit = icebox.thaw("stevearc/oil.nvim")
```

Each `thaw()` call also triggers a background fetch of the repository's commit history. Newly-seen commits are recorded with their first-observation time and become available to subsequent calls. By default, that fetch keeps a persistent bare clone under `$XDG_CACHE_HOME/icebox.nvim/clones/`, so subsequent calls reuse the local objects instead of re-cloning.

To customize a call, pass an options table as the second argument (or as the first argument if you omit the URL). The recognized keys are:

| Key | Type | Description |
|-----|------|-------------|
| `url` | string | The Git URL, useful with the single-table form `thaw(opts)`. Mutually exclusive with the positional `url` argument and `clone_path`. |
| `clone_path` | string | Absolute path to an existing clone maintained by another tool (e.g. your plugin manager). The upstream URL is read from that clone's `origin` remote, and its objects are reused for `branch` history in place of icebox's own cache. Mutually exclusive with the positional `url` argument and `opts.url`. See [`doc/icebox.txt`](doc/icebox.txt) for details. |
| `branch` | string | Newest-first history of that branch, capped at `branch_commits_per_fetch` commits. |
| `version` | string | All tags in the store whose semver matches the range (`^1.0.0`, `~1.2.3`, `>=2.0.0`, …). Highest match wins among cooled tags. |
| `trusted_commit` | string | Hash trusted by the user. In the normal path, bypasses the cooldown only when it belongs to the candidate set. See [`doc/icebox.txt`](doc/icebox.txt) for the full resolution rules and empty-store exception. |
| `cooldown_days` | number | Overrides the `setup()` value for this call. |
| `trust_on_first_use` | boolean | Overrides the `setup()` value for this call. |
| `branch_commits_per_fetch` | number | Overrides the `setup()` value for this call. |
| `normalize` | function | Custom tag-name normalizer used with `version`. See [`doc/icebox.txt`](doc/icebox.txt) for details. |

When neither `branch` nor `version` (which are mutually exclusive) is specified, icebox.nvim treats the call as if the latest semver tag were requested when the repository has any semver tags, or as if the default branch were requested otherwise.

### `icebox.ZERO_HASH`

The value returned when no cooled commit is available or an error occurs. It is an all-zero Git hash string, which Git treats as an invalid commit hash. When combining with a plugin manager, the recommended usage is to pass it through unchanged and let the plugin manager fail on it.

### `icebox.lazy.cooldown(spec)`

Helper for lazy.nvim. Given a lazy plugin spec, if `spec.icebox_options` is set, it calls `thaw(spec[1] or spec.url or spec.dir, spec.icebox_options)` and pins the returned commit onto the spec before returning it.

```lua
local cooldown = require("icebox.lazy").cooldown

require("lazy").setup(vim.tbl_map(cooldown, {
  { "ibhagwan/fzf-lua",     icebox_options = { branch = "main" } },
  { "stevearc/oil.nvim",    icebox_options = { version = "^1.0.0" } },
  { "github/copilot.vim" }, -- no icebox_options → passed through
}))
```

## How it works

```
resolve request
      │
┌─────▼──────────────────┐
│  local store (JSON)    │
│  fetched_at per hash   │
└─────┬──────────────────┘
      │
      1. build candidate set from opts (branch history / tags in range / …)
      2. pick newest cooled commit in the set (fetched_at + cooldown_days <= now)
      3. if trusted_commit is in the set, return the newer of it and (2)
      4. else return (2), or ZERO_HASH + schedule BG fetch
```

The BG fetch step reads from either the cache directory (default) or `clone_path` when the caller supplied one.

The commit hashes and their first-observation times are persisted under `$XDG_DATA_HOME/icebox.nvim/`, one JSON store file per repository.

## License

MIT
