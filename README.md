# dot

`dot` syncs personal configuration packages across machines.

The interface is intentionally small:

```bash
./install.sh
dot init personal
dot status
dot down
dot up
dot doctor
```

## Commands

### `dot init <profile>`

Sets the active profile and runs an initial `dot down`.

### `dot status`

Shows local and remote state for every repo in the active profile.

### `dot down`

Brings config down to the current machine:

1. clones missing repos
2. reconciles existing repos with `git pull --rebase --autostash`
3. skips apply for repos that need manual conflict resolution
4. runs configured apply commands
5. runs `dot doctor`

Use `dot down --fetch-only` when you want to inspect upstream changes without pulling or applying them.

### `dot up`

Publishes local config changes:

1. reconciles each repo with `git pull --rebase --autostash`
2. commits dirty repos in the active profile
3. pushes local commits

By default, commits use `Update <repo>` as the message.

```bash
dot up -m "Update config"
dot up dotfiles -m "Update zsh aliases"
```

If Git cannot reconcile a repo automatically, `dot` stops that repo and prints the path to resolve manually.

### `dot doctor`

Checks that profile repos exist and configured apply commands are present.

## Profiles

Profiles live in `profiles/*.env`. The first profile is `profiles/personal.env`.

Each item needs a label, repo, path, and optional apply command:

```bash
DOT_ITEMS=(dotfiles)

DOT_ITEM_dotfiles_LABEL="dotfiles"
DOT_ITEM_dotfiles_REPO="git@github.com:ronsanzone/dotfiles.git"
DOT_ITEM_dotfiles_PATH="$HOME/code/dotfiles"
DOT_ITEM_dotfiles_APPLY="./install.sh"
```
