# icebox.nvim

Cooldown-based commit resolver for Neovim.

icebox.nvim returns the most recent commit hash for a Git repository that has been "in the icebox" for at least a configurable number of days. Use it with your plugin manager's commit-pinning feature to avoid adopting freshly released commits before bugs — or malicious changes — have had time to surface.

## Motivation

Software supply-chain attacks against open-source packages have become a routine occurrence. Attackers compromise maintainer accounts (or introduce hostile commits through other means) and publish a poisoned release; users who auto-update within minutes are the first to be hit. A well-known mitigation is a **minimum release age** — refuse to install a version until it has been visible for at least N days, so that a malicious release has a chance to be noticed and revoked before it is adopted. Some package managers, notably pnpm, expose a `minimumReleaseAge` option in this direction, and similar proposals have been discussed in other ecosystems.

Neovim's plugin ecosystem does not have this affordance. Plugins are distributed almost exclusively as Git repositories on hosts like GitHub, and popular plugin managers pull the latest commit (or the newest tag) without any built-in delay. A compromised maintainer's push propagates to users on their next `:Lazy update` / `:PackerSync` / equivalent.

The obvious question is: **can we implement "minimum release age" using the timestamps already present in Git?** For the plain Git distribution model used by Neovim plugins, the answer is no — every timestamp such a repository exposes is under the attacker's control:

- **Author date / committer date** are arbitrary strings written into the commit object. Anyone with push access can set them to whatever value makes their commit look aged (`GIT_COMMITTER_DATE`, `git commit --date`, `git rebase --committer-date-is-author-date`, etc.).
- **Tag creation date** on annotated tags is likewise attacker-controlled at tag-creation time.
- **`refs/tags/*` / `refs/heads/*` mtimes** exist only on the server's filesystem and are not exposed over the Git protocol.
- Even if a timestamp *were* trustworthy, an attacker who has already replaced the upstream can also rewrite history and force-push, invalidating any prior observation of "old" commits.

Signed tags/commits with reproducible timestamping, or transparency logs such as Sigstore/Rekor, could in principle anchor a trustworthy publication time, but the Neovim plugin ecosystem does not use these mechanisms in a way plugin managers can rely on. In practice, no server-side timestamp a plain Git client sees can be trusted as "this commit has been publicly available for N days."

## Approach

icebox.nvim's approach is to **ignore all remote-provided timestamps and instead measure age from the moment this machine first observed the commit**. On every fetch the plugin records, per commit hash, the local `os.time()` at which it first became visible. Only commits whose local observation timestamp is at least `cooldown_days` old are eligible to be returned.

Concretely:

- The first time `thaw()` sees a commit hash, it is stamped with the current local time in a JSON store under `$XDG_DATA_HOME/icebox.nvim/`.
- Subsequent fetches never overwrite an existing timestamp, so each commit's "first observation" time is monotonic on this machine.
- `thaw()` returns the newest commit in the requested candidate set (branch history / tag / semver range) whose observation age has reached the cooldown. Anything more recent is withheld until it has aged locally.

Note that the observation timestamp is local: it measures how long the commit has been sitting in *your* store, not how long it has existed publicly. On a freshly installed machine, initial observations are inevitably "young" regardless of the commit's true age — see the notes on `trust_on_first_use` and initial installation below.

Why this is a meaningful defense:

- **The clock cannot be moved by the attacker.** The trust anchor is your own filesystem, not any Git metadata. A poisoned commit force-pushed today is treated as brand new even if it claims a committer date from 2020.
- **A malicious commit has time to be noticed before it is adopted.** During the cooldown window on your machine, the commit exists on the remote and can be reported and revoked by others. If the upstream removes it before your cooldown elapses, the next fetch drops it from the candidate set and you never adopt it — even though its local `fetched_at` remains recorded. Note that this depends on someone *else* noticing; the cooldown does not by itself detect malicious changes, it only creates a window during which detection can prevent adoption.
- **The default behavior fails safely on first observation.** When the store is empty for a URL, `thaw()` returns `ZERO_HASH` and schedules a background fetch; nothing gets pinned until the cooldown has been served on a subsequent startup. This means a machine that installs icebox on a day when the upstream is already compromised does not auto-adopt that state — but it also means no version is pinned at all until the store has aged. See `trust_on_first_use` for the opt-in escape hatch and its trade-offs.
- **`trusted_commit` lets you name a specific hash you have vetted.** In the normal path (populated store), it takes effect only when the hash belongs to the candidate set implied by `branch` / `tag` / `version` / `commit`, and `thaw()` returns whichever of `{trusted_commit, newest-cooled}` is newer. This lets you adopt a specific reviewed commit immediately without waiting for the cooldown, while still falling back to the cooldown-gated resolution once newer commits qualify. See the [`trusted_commit` semantics](#trusted_commit-semantics) section for the empty-store special case.
- **`trust_on_first_use = true` is an opt-in that trades this guarantee for a hash on the very first run.** When enabled and the store is empty for the URL, the initial call returns `trusted_commit` as-is if it is set (no candidate-set check, since there is no candidate set yet), otherwise it performs a synchronous fetch and returns the newest matching commit with the cooldown bypassed *once*. This is convenient for bootstrapping but leaves the initial-install-day window unprotected: if you install icebox on a day when the upstream is already compromised, that state will be adopted immediately. Prefer the default (`false`) unless you know the upstream is currently in a state you would sign off on manually.
- **No new infrastructure required.** Plugin authors do not need to sign releases, publish a manifest, or run a registry. Any Git host works. The mechanism is a thin wrapper around each plugin manager's existing commit-pinning feature.

icebox.nvim is not a substitute for signed releases or reproducible builds, and it cannot defend against an attack that remains undetected for the full cooldown window. It is a low-effort, defense-in-depth layer that converts "we adopt the upstream head within minutes" into "we adopt it after N days of quiet exposure."

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

icebox.setup({
  cooldown_days      = 7,
  trust_on_first_use = false,  -- default; keep it off unless you know why
})

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

**`opts`** — at most one of `branch` / `tag` / `version` / `commit` may be specified. Each defines a *candidate set*; `thaw()` returns the newest cooled commit in that set (see [How it works](#how-it-works)). `trusted_commit` is an orthogonal modifier that can bypass the wait for hashes already in the candidate set.

| Key | Type | Candidate set / description |
|-----|------|-------------|
| `branch` | string | Newest-first history of that branch, capped at `branch_commits_per_fetch` commits. |
| `tag` | string | The single commit the tag points at. |
| `version` | string | All tags in the store whose semver matches the range (`^1.0.0`, `~1.2.3`, `>=2.0.0`, …). Highest match wins among cooled tags. |
| `commit` | string | The single specified hash. Fully offline; cooldown starts from first observation. |
| `trusted_commit` | string | Hash trusted by the user. In the normal path, bypasses cooldown *only when it belongs to the candidate set* — see [`trusted_commit` semantics](#trusted_commit-semantics). |

If none of the above is specified, icebox.nvim falls back to:

1. Newest cooled semver tag (`>=0.0.0`), if any tags are already known.
2. Tip of the default branch, if `default_branch` has been recorded.
3. Otherwise, `ZERO_HASH` plus a background `git ls-remote` to seed both. The next invocation will fall into (1) or (2). With `trust_on_first_use = true` the fetch runs synchronously and returns immediately.

#### `trusted_commit` semantics

`trusted_commit` is a hash you assert as safe. In the normal (populated-store) path, it is not a blanket fallback — it only takes effect when the hash is actually part of the candidate set that the selected option produces:

1. Extract candidate commits from the store:
   - `branch` → history of that branch (newest-first array, from `git log --first-parent`)
   - `version` → tags matching the semver range
   - `tag` / `commit` → the single referenced commit
2. Find the newest cooled-down commit within that set.
3. If `trusted_commit` is set **and** appears in the candidate set, return whichever of `{trusted_commit, newest-cooled}` is newer.
   - "newer" means smaller array index for `branch`, higher semver for `version`, or identity for `tag` / `commit`. Timestamps on the commit object are never consulted.
4. Otherwise return the newest cooled commit, or `ZERO_HASH` if none.

Concretely: for `branch = "main", trusted_commit = <HEAD>`, the tip of `main` is returned immediately without waiting for its cooldown. For `version = "^1.0.0", trusted_commit = <v1.3.0 hash>`, `v1.3.0` is returned even before its cooldown. A `trusted_commit` that is *not* in the candidate set (e.g. a hash off the branch, or pointing at a tag outside the range) is ignored.

**Empty-store exception.** When the local store has no records for the URL yet, no candidate set exists, so the rule above cannot apply. Behaviour then depends on `trust_on_first_use`:

- `trust_on_first_use = false` (default): `trusted_commit` is **ignored** and `thaw()` returns `ZERO_HASH`. The very first observation is always withheld — including any user-supplied hash — so a machine that installs icebox on a day when the upstream is already compromised does not adopt anything from that first fetch. Re-run after at least one background fetch has recorded observations.
- `trust_on_first_use = true`: if `trusted_commit` is set, it is returned **as-is without a candidate-set check**. This is the opt-in escape hatch for bootstrapping (see `trust_on_first_use` below).

Also note that the candidate set for `branch` is capped at `branch_commits_per_fetch` (default 500) commits. A `trusted_commit` older than that window is treated as "outside the candidate set" and will be ignored in the normal path.

### `icebox.ZERO_HASH`

The sentinel value (`"0000000000000000000000000000000000000000"`) returned when no cooled commit is available. It is deliberately an invalid commit hash: passing it to a plugin manager as `commit = ...` is expected to fail loudly rather than silently adopt some other version, which enforces the cooldown as a hard gate.

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

**About `ZERO_HASH`.** When no cooled commit is available (empty store, cooldown not yet elapsed, or trusted_commit ignored), `thaw()` returns `icebox.ZERO_HASH`, and `cooldown()` assigns it to `spec.commit`. This is intentional: `ZERO_HASH` is not a real commit, so plugin managers such as lazy.nvim will fail to fetch it and refuse to load the plugin. That failure is a *feature* — it prevents adoption of any commit before the cooldown has served, at the cost of a startup error. To avoid the error on the very first run, either supply a vetted `trusted_commit` in `icebox_options` (with `trust_on_first_use = true`), or omit `icebox_options` and pin manually until the store has aged.

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
