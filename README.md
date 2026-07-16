# icebox.nvim

Cooldown-based commit resolver for Neovim.

icebox.nvim returns the most recent commit hash for a Git repository that has been "in the icebox" for at least a configurable number of days. Use it with your plugin manager's commit-pinning feature to avoid adopting freshly released commits before bugs have had time to surface.

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

## Usage

Call `setup()` once during startup, then pass the result of `thaw()` as a commit hash to your plugin manager.

```lua
local icebox = require("icebox")

icebox.setup({ cooldown_days = 7 })

return {
  {
    "nvim-telescope/telescope.nvim",
    commit = icebox.thaw("https://github.com/nvim-telescope/telescope.nvim"),
  },
}
```

On the first startup the local store is empty, so `thaw()` returns the zero hash and schedules a background fetch. From the second startup onward a real commit hash is returned once the cooldown has elapsed.

## API

### `icebox.setup(opts)`

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cooldown_days` | number | `7` | Days a commit must be known before it is returned. `0` disables cooldown. |
| `trust_on_first_use` | boolean | `false` | When `true`, performs a synchronous fetch on first use and returns a hash immediately, bypassing the cooldown for that first result. |
| `branch_commits_per_fetch` | number | `500` | Maximum number of branch commits pulled per fetch (`git log -n`). Older commits already recorded in the store keep their original `fetched_at`; a later fetch that reveals commits beyond this window will pick them up over subsequent runs. |

### `icebox.thaw(url, opts)`

Returns a 40-character commit hash, or `icebox.ZERO_HASH` if no cooled commit is available yet.

```lua
-- Check whether a usable hash was returned
local hash = icebox.thaw(url)
if hash == icebox.ZERO_HASH then
  -- not ready yet
end
```

The GitHub shorthand `owner/repo` is also accepted and expanded to `https://github.com/<owner>/<repo>.git` internally (same convention as lazy.nvim / packer.nvim). Use a full URL for non-GitHub hosts or SSH.

```lua
commit = icebox.thaw("nvim-telescope/telescope.nvim")
```

**`opts`** — at most one of the following may be specified:

| Key | Type | Description |
|-----|------|-------------|
| `branch` | string | Newest cooled commit on the branch. |
| `tag` | string | Commit the tag points to, if cooled. |
| `version` | string | Highest cooled tag matching the semver range (`^1.0.0`, `~1.2.3`, `>=2.0.0`, …). |
| `commit` | string | Specific commit hash; cooldown starts from first observation. |
| `trusted_commit` | string | Hash trusted by the user, bypassing cooldown *only when it belongs to the candidate set* for the selected `branch` / `tag` / `version` / `commit`. See below. |

If none of the above is specified, icebox.nvim uses the newest cooled semver tag (`>=0.0.0`) if any exist, otherwise the tip of the default branch.

#### `trusted_commit` semantics

`trusted_commit` is a hash you assert as safe. It is not a blanket fallback — it only takes effect when the hash is actually part of the candidate set that the selected option produces:

1. Extract candidate commits from the store:
   - `branch` → history of that branch (newest-first)
   - `version` → tags matching the semver range
   - `tag` / `commit` → the single referenced commit
2. Find the newest cooled-down commit within that set.
3. If `trusted_commit` is set **and** appears in the candidate set, return whichever of `{trusted_commit, newest-cooled}` is newer.
4. Otherwise return the newest cooled commit, or `ZERO_HASH` if none.

Concretely: for `branch = "main", trusted_commit = <HEAD>`, the tip of `main` is returned immediately without waiting for its cooldown. For `version = "^1.0.0", trusted_commit = <v1.3.0 hash>`, `v1.3.0` is returned even before its cooldown. A `trusted_commit` that is *not* in the candidate set (e.g. a hash off the branch, or pointing at a tag outside the range) is ignored.

### `icebox.ZERO_HASH`

The sentinel value (`"0000000000000000000000000000000000000000"`) returned when no cooled commit is available.

### `icebox.lazy.cooldown(spec)`

Helper for [lazy.nvim](https://github.com/folke/lazy.nvim). Wraps a single plugin spec: if `spec.icebox_options` is set, calls `icebox.thaw()` with the spec's identifier (`spec[1]` / `spec.url` / `file://spec.dir`) and the given options, and assigns the result to `spec.commit`. Specs without `icebox_options` are returned untouched.

The spec is mutated in place and also returned, so it works directly with `vim.tbl_map`:

```lua
local cooldown = require("icebox.lazy").cooldown

require("lazy").setup(vim.tbl_map(cooldown, {
  { "nvim-telescope/telescope.nvim", icebox_options = { branch = "master" } },
  { "folke/tokyonight.nvim",         icebox_options = { version = "^1.0.0" } },
  { "plain/plugin" },                            -- no icebox_options → passed through
}))
```

An existing `spec.commit` is overwritten when `icebox_options` is set; omit `icebox_options` for specs that already pin their own commit.

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

Store files live in `$XDG_DATA_HOME/icebox.nvim/` (default: `~/.local/share/icebox.nvim/`), one file per repository URL. They can be safely deleted; icebox.nvim will re-fetch on the next startup.

## License

MIT
