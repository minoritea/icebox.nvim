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

### `icebox.thaw(url, opts)`

Returns a 40-character commit hash, or `icebox.ZERO_HASH` if no cooled commit is available yet.

```lua
-- Check whether a usable hash was returned
local hash = icebox.thaw(url)
if hash == icebox.ZERO_HASH then
  -- not ready yet
end
```

**`opts`** — at most one of the following may be specified:

| Key | Type | Description |
|-----|------|-------------|
| `branch` | string | Newest cooled commit on the branch. |
| `tag` | string | Commit the tag points to, if cooled. |
| `version` | string | Highest cooled tag matching the semver range (`^1.0.0`, `~1.2.3`, `>=2.0.0`, …). |
| `commit` | string | Specific commit hash; cooldown starts from first observation. |
| `trusted_commit` | string | Fallback hash returned instead of `ZERO_HASH` until a cooled result is available. |

If none of the above is specified, icebox.nvim uses the newest cooled semver tag (`>=0.0.0`) if any exist, otherwise the tip of the default branch.

### `icebox.ZERO_HASH`

The sentinel value (`"0000000000000000000000000000000000000000"`) returned when no cooled commit is available.

## How it works

```
resolve request
      │
┌─────▼──────────────────┐
│  local store (JSON)    │
│  fetched_at per hash   │
└─────┬──────────────────┘
      │
      fetched_at + cooldown_days <= now?
      │                    │
     yes                   no
      │                    │
 return hash         return ZERO_HASH
                     + schedule BG fetch
```

Store files live in `$XDG_DATA_HOME/icebox.nvim/` (default: `~/.local/share/icebox.nvim/`), one file per repository URL. They can be safely deleted; icebox.nvim will re-fetch on the next startup.

## License

MIT
