#!/usr/bin/env bash

DOT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dot"
DOT_PROFILES_DIR="${DOT_ROOT:-$(pwd)}/profiles"

DOT_COLOR_MODE="${DOT_COLOR:-auto}"
if [[ "$DOT_COLOR_MODE" == "always" && -z "${NO_COLOR:-}" ]]; then
    DOT_USE_COLOR=1
elif [[ "$DOT_COLOR_MODE" == "never" || -n "${NO_COLOR:-}" ]]; then
    DOT_USE_COLOR=0
elif [[ -t 1 ]]; then
    DOT_USE_COLOR=1
else
    DOT_USE_COLOR=0
fi

if [[ "$DOT_USE_COLOR" -eq 1 ]]; then
    DOT_RESET=$'\033[0m'
    DOT_BOLD=$'\033[1m'
    DOT_DIM=$'\033[2m'
    DOT_RED=$'\033[31m'
    DOT_GREEN=$'\033[32m'
    DOT_YELLOW=$'\033[33m'
    DOT_BLUE=$'\033[34m'
    DOT_MAGENTA=$'\033[35m'
    DOT_CYAN=$'\033[36m'
else
    DOT_RESET=""
    DOT_BOLD=""
    DOT_DIM=""
    DOT_RED=""
    DOT_GREEN=""
    DOT_YELLOW=""
    DOT_BLUE=""
    DOT_MAGENTA=""
    DOT_CYAN=""
fi

dot_info() { printf '%b\n' "${DOT_CYAN}✨ dot${DOT_RESET} $*"; }
dot_ok() { printf '%b\n' "${DOT_GREEN}✓ dot${DOT_RESET} $*"; }
dot_warn() { printf '%b\n' "${DOT_YELLOW}⚠ dot${DOT_RESET} $*" >&2; }
dot_die() { printf '%b\n' "${DOT_RED}✗ dot${DOT_RESET} $*" >&2; exit 1; }
dot_section() { printf '\n%b\n' "${DOT_BOLD}${DOT_MAGENTA}◆ $*${DOT_RESET}"; }
dot_step() { printf '%b\n' "${DOT_BLUE}→${DOT_RESET} $*"; }

dot_usage() {
    cat <<'EOF'
Usage:
  dot init <profile>
  dot status
  dot down [--fetch-only] [--apply-only] [--no-doctor]
  dot up [item] [-m message] [--skip-dirty]
  dot doctor [--deep]
  dot profile

Core flow:
  dot down    Bring profile repos down to this machine and apply them.
  dot up      Commit and push local changes from profile repos.
              With --skip-dirty, leave dirty repos alone (push only clean-and-ahead).
  dot doctor  Check profile repos (+ tools/symlinks with --deep).
EOF
}

dot_main() {
    local command="${1:-}"
    if [[ $# -gt 0 ]]; then
        shift
    fi

    case "$command" in
        init) dot_cmd_init "$@" ;;
        status|st) dot_cmd_status "$@" ;;
        down|d) dot_cmd_down "$@" ;;
        up|u) dot_cmd_up "$@" ;;
        doctor) dot_cmd_doctor "$@" ;;
        profile) dot_cmd_profile "$@" ;;
        help|-h|--help|"") dot_usage ;;
        *) dot_die "unknown command: $command" ;;
    esac
}

dot_cmd_init() {
    local profile="${1:-}"
    [[ -n "$profile" ]] || dot_die "usage: dot init <profile>"
    dot_profile_path "$profile" >/dev/null

    mkdir -p "$DOT_STATE_DIR"
    printf '%s\n' "$profile" > "$DOT_STATE_DIR/profile"
    dot_ok "active profile: ${DOT_BOLD}$profile${DOT_RESET}"
    dot_cmd_down --no-doctor
}

dot_cmd_profile() {
    dot_ok "active profile: ${DOT_BOLD}$(dot_active_profile)${DOT_RESET}"
}

dot_cmd_status() {
    dot_load_profile

    printf '%b\n\n' "${DOT_BOLD}Profile:${DOT_RESET} ${DOT_CYAN}${DOT_PROFILE_NAME}${DOT_RESET}"
    printf '%b\n' "${DOT_BOLD}Repos${DOT_RESET}"

    local item
    for item in "${DOT_ITEMS[@]}"; do
        dot_print_item_status "$item"
    done
}

dot_cmd_down() {
    local fetch_only=0
    local apply_only=0
    local run_doctor=1
    DOT_DOWN_BLOCKED=" "
    DOT_DOWN_HAD_BLOCKED=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fetch-only) fetch_only=1 ;;
            --apply-only) apply_only=1 ;;
            --no-doctor) run_doctor=0 ;;
            *) dot_die "unknown down option: $1" ;;
        esac
        shift
    done

    dot_load_profile

    # --apply-only: skip clone/reconcile, just re-run each item's APPLY command.
    # Cheaper than a full `down` when only local config files changed.
    if [[ "$apply_only" -eq 1 ]]; then
        printf '\n'
        local item
        for item in "${DOT_ITEMS[@]}"; do
            dot_apply_item "$item"
        done
        if [[ "$run_doctor" -eq 1 ]]; then
            printf '\n'
            dot_cmd_doctor
        fi
        return
    fi

    local item
    for item in "${DOT_ITEMS[@]}"; do
        dot_down_item "$item" "$fetch_only"
    done

    if [[ "$fetch_only" -eq 1 ]]; then
        dot_ok "fetch complete; run ${DOT_BOLD}dot status${DOT_RESET} to inspect incoming changes"
        return
    fi

    printf '\n'
    for item in "${DOT_ITEMS[@]}"; do
        dot_apply_item "$item"
    done

    if [[ "$DOT_DOWN_HAD_BLOCKED" -eq 1 ]]; then
        dot_die "one or more repos need manual resolution"
    fi

    if [[ "$run_doctor" -eq 1 ]]; then
        printf '\n'
        dot_cmd_doctor
    fi
}

dot_cmd_up() {
    local target=""
    local message=""
    local skip_dirty=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--message)
                shift
                [[ $# -gt 0 ]] || dot_die "missing message after -m"
                message="$1"
                ;;
            --skip-dirty)
                skip_dirty=1
                ;;
            -*)
                dot_die "unknown up option: $1"
                ;;
            *)
                [[ -z "$target" ]] || dot_die "only one item can be targeted"
                target="$1"
                ;;
        esac
        shift
    done

    dot_load_profile

    local pushed=0
    DOT_UP_HAD_BLOCKED=0
    local item
    for item in "${DOT_ITEMS[@]}"; do
        if [[ -n "$target" && "$target" != "$item" && "$target" != "$(dot_item_label "$item")" ]]; then
            continue
        fi
        dot_up_item "$item" "$message" "$skip_dirty" && pushed=1
    done

    if [[ "$DOT_UP_HAD_BLOCKED" -eq 1 ]]; then
        dot_die "one or more repos need manual resolution"
    fi

    if [[ -n "$target" && "$pushed" -eq 0 ]]; then
        dot_warn "nothing pushed for $target"
    elif [[ "$pushed" -eq 0 ]]; then
        dot_ok "nothing to push"
    fi
}

dot_cmd_doctor() {
    local deep=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --deep) deep=1 ;;
            *) dot_die "unknown doctor option: $1" ;;
        esac
        shift
    done

    dot_load_profile

    local ok=1
    command -v git >/dev/null 2>&1 || { dot_warn "git is not installed"; ok=0; }

    local item path apply
    for item in "${DOT_ITEMS[@]}"; do
        path="$(dot_item_path "$item")"
        apply="$(dot_item_apply "$item")"

        if [[ ! -d "$path/.git" ]]; then
            dot_warn "$(dot_item_label "$item") is missing or is not a git repo: $path"
            ok=0
            continue
        fi

        if [[ -n "$apply" && ! -e "$path/${apply%% *}" ]]; then
            dot_warn "$(dot_item_label "$item") apply command may be missing: $apply"
            ok=0
        fi
    done

    if [[ "$deep" -eq 1 ]]; then
        dot_doctor_deep || ok=0
    fi

    if [[ "$ok" -eq 1 ]]; then
        dot_ok "doctor passed"
    else
        dot_die "doctor found issues"
    fi
}

# --deep checks: essential tools + broken symlinks under the stow/overlay
# targets. Defers repo-specific checks to each repo's install.sh rather than
# hardcoding brew/stow into dot itself (preserves separation of concerns).
dot_doctor_deep() {
    local ok=1
    local sub_ok=1

    dot_section "deep checks"

    # Essential tools. `dot` itself needs git; the rest are what our profile's
    # apply scripts assume (Homebrew, Node/npm, pi). Missing ones are warnings,
    # not hard failures, since a profile may legitimately not use all of them.
    local tool
    for tool in git brew node npm pi; do
        if command -v "$tool" >/dev/null 2>&1; then
            dot_ok "tool present: $tool"
        else
            dot_warn "tool missing: $tool"
            sub_ok=0
        fi
    done

    # Broken symlinks under the two trees our install scripts target. Recurse
    # only one level into ~/.config (per-package dirs) and into ~/.pi/agent
    # (extensions/scripts/skills), then check each symlink resolves.
    dot_step "checking for broken symlinks"
    local broken=0
    local dir entry target
    for dir in "$HOME/.config" "$HOME/.pi/agent"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' entry; do
            if [[ -L "$entry" && ! -e "$entry" ]]; then
                target="$(readlink "$entry")"
                dot_warn "broken symlink: $entry -> $target"
            broken=1
            sub_ok=0
            fi
        done < <(find "$dir" -maxdepth 2 -type l -print0 2>/dev/null)
    done
    [[ "$broken" -eq 0 ]] && dot_ok "no broken symlinks under ~/.config or ~/.pi/agent"

    [[ "$sub_ok" -eq 1 ]]
}

dot_down_item() {
    local item="$1"
    local fetch_only="$2"
    local label path repo
    label="$(dot_item_label "$item")"
    path="$(dot_item_path "$item")"
    repo="$(dot_item_repo "$item")"

    dot_section "$label"

    if [[ ! -d "$path/.git" ]]; then
        [[ -n "$repo" ]] || dot_die "$label has no repo configured"
        mkdir -p "$(dirname "$path")"
        dot_step "cloning ${DOT_BOLD}$repo${DOT_RESET} -> $path"
        git clone "$repo" "$path"
        return
    fi

    if [[ "$fetch_only" -eq 1 ]]; then
        git -C "$path" fetch --prune
        dot_print_item_status "$item"
        return
    fi

    if ! dot_reconcile_item "$item"; then
        DOT_DOWN_BLOCKED="${DOT_DOWN_BLOCKED}${item} "
        DOT_DOWN_HAD_BLOCKED=1
        return
    fi
}

dot_apply_item() {
    local item="$1"
    local label path apply
    label="$(dot_item_label "$item")"
    path="$(dot_item_path "$item")"
    apply="$(dot_item_apply "$item")"

    [[ -n "$apply" ]] || return 0

    if [[ "${DOT_DOWN_BLOCKED:- }" == *" $item "* ]]; then
        dot_warn "skipping apply for $label because it needs conflict resolution"
        return 0
    fi

    dot_step "applying ${DOT_BOLD}$label${DOT_RESET}"
    (cd "$path" && eval "$apply")
}

dot_up_item() {
    local item="$1"
    local message="$2"
    local skip_dirty="${3:-0}"
    local label path
    label="$(dot_item_label "$item")"
    path="$(dot_item_path "$item")"

    if [[ ! -d "$path/.git" ]]; then
        dot_warn "$label is missing; skipping"
        return 1
    fi

    if dot_git_clean "$path"; then
        if ! dot_reconcile_item "$item"; then
            DOT_UP_HAD_BLOCKED=1
            return 1
        fi

        if dot_git_clean "$path"; then
            dot_push_if_ahead "$item"
            return $?
        fi
        # reconcile left it dirty — fall through to dirty handling
    fi

    # Reaching here means the repo is dirty (either was, or reconcile made it so).
    # With --skip-dirty, leave it alone for manual commit instead of sweeping
    # uncommitted changes into an auto-generated "Update <label>" commit.
    if [[ "$skip_dirty" -eq 1 ]]; then
        dot_warn "$label has uncommitted changes; skipping (--skip-dirty). Commit manually and rerun dot up."
        return 1
    fi

    if ! dot_reconcile_item "$item"; then
        DOT_UP_HAD_BLOCKED=1
        return 1
    fi

    dot_section "$label"
    git -C "$path" status --short

    local commit_message="$message"
    if [[ -z "$commit_message" ]]; then
        commit_message="Update $label"
    fi

    dot_step "committing: ${DOT_BOLD}$commit_message${DOT_RESET}"
    git -C "$path" add -A
    git -C "$path" commit -m "$commit_message"
    dot_step "pushing ${DOT_BOLD}$label${DOT_RESET}"
    git -C "$path" push
}

dot_reconcile_item() {
    local item="$1"
    local label path
    label="$(dot_item_label "$item")"
    path="$(dot_item_path "$item")"

    if dot_git_has_in_progress_operation "$path"; then
        dot_warn "$label has an unfinished git operation; resolve it in $path"
        dot_print_resolution_hint "$path"
        return 1
    fi

    dot_step "reconciling ${DOT_BOLD}$label${DOT_RESET}"
    if git -C "$path" pull --rebase --autostash --stat; then
        if dot_git_has_unmerged_files "$path"; then
            dot_warn "$label has conflicts after applying local changes"
            dot_print_resolution_hint "$path"
            return 1
        fi
        return 0
    fi

    dot_warn "$label could not reconcile automatically"
    dot_print_resolution_hint "$path"
    return 1
}

dot_push_if_ahead() {
    local item="$1"
    local label path ahead behind
    label="$(dot_item_label "$item")"
    path="$(dot_item_path "$item")"

    read -r ahead behind < <(dot_git_ahead_behind "$path")
    if [[ "$ahead" == "?" || "$behind" == "?" ]]; then
        return 1
    fi

    if [[ "$ahead" -gt 0 && "$behind" -eq 0 ]]; then
        dot_section "$label"
        dot_step "pushing ${DOT_BOLD}$label${DOT_RESET}"
        git -C "$path" push
        return 0
    fi

    return 1
}

dot_git_has_in_progress_operation() {
    local path="$1"
    local git_dir
    git_dir="$(git -C "$path" rev-parse --git-dir 2>/dev/null)" || return 1

    [[ -d "$git_dir/rebase-merge" ||
       -d "$git_dir/rebase-apply" ||
       -f "$git_dir/MERGE_HEAD" ||
       -f "$git_dir/CHERRY_PICK_HEAD" ||
       -f "$git_dir/REVERT_HEAD" ]]
}

dot_git_has_unmerged_files() {
    local path="$1"
    [[ -n "$(git -C "$path" diff --name-only --diff-filter=U)" ]]
}

dot_print_resolution_hint() {
    local path="$1"
    cat >&2 <<EOF
⚠ dot resolve manually:
  cd $path
  git status
  # fix conflicts, then follow git's rebase/merge instructions

✨ dot then rerun:
  dot status
  dot up
EOF
}

dot_print_item_status() {
    local item="$1"
    local label path branch dirty ahead behind state
    label="$(dot_item_label "$item")"
    path="$(dot_item_path "$item")"

    if [[ ! -d "$path/.git" ]]; then
        printf '  %b %-20s %b%-8s%b %s\n' "❔" "$label" "$DOT_YELLOW" "missing" "$DOT_RESET" "$path"
        return
    fi

    branch="$(git -C "$path" branch --show-current 2>/dev/null || true)"
    [[ -n "$branch" ]] || branch="detached"

    if dot_git_clean "$path"; then
        dirty="clean"
    else
        dirty="dirty"
    fi

    read -r ahead behind < <(dot_git_ahead_behind "$path")
    state="$(dot_remote_state "$ahead" "$behind")"

    printf '  %b %-20s %b%-8s%b %-14s %b\n' \
        "$(dot_status_icon "$dirty" "$ahead" "$behind")" \
        "$label" \
        "$(dot_dirty_color "$dirty")" \
        "$dirty" \
        "$DOT_RESET" \
        "$branch" \
        "$(dot_state_color "$ahead" "$behind")$state${DOT_RESET}"
}

dot_status_icon() {
    local dirty="$1"
    local ahead="$2"
    local behind="$3"

    if [[ "$ahead" == "?" || "$behind" == "?" ]]; then
        printf '❔'
    elif [[ "$dirty" == "dirty" ]]; then
        printf '●'
    elif [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
        printf '✓'
    else
        printf '↕'
    fi
}

dot_dirty_color() {
    local dirty="$1"
    if [[ "$dirty" == "clean" ]]; then
        printf '%s' "$DOT_GREEN"
    else
        printf '%s' "$DOT_YELLOW"
    fi
}

dot_state_color() {
    local ahead="$1"
    local behind="$2"

    if [[ "$ahead" == "?" || "$behind" == "?" ]]; then
        printf '%s' "$DOT_YELLOW"
    elif [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
        printf '%s' "$DOT_GREEN"
    else
        printf '%s' "$DOT_CYAN"
    fi
}

dot_remote_state() {
    local ahead="$1"
    local behind="$2"

    if [[ "$ahead" == "?" || "$behind" == "?" ]]; then
        printf 'no upstream'
    elif [[ "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
        printf 'up to date'
    else
        printf '%s ahead, %s behind' "$ahead" "$behind"
    fi
}

dot_git_clean() {
    local path="$1"
    [[ -z "$(git -C "$path" status --porcelain)" ]]
}

dot_git_ahead_behind() {
    local path="$1"
    if ! git -C "$path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
        printf '? ?\n'
        return
    fi
    git -C "$path" rev-list --left-right --count 'HEAD...@{upstream}'
}

dot_load_profile() {
    local profile
    profile="$(dot_active_profile)"
    # shellcheck source=/dev/null
    source "$(dot_profile_path "$profile")"
    [[ -n "${DOT_PROFILE_NAME:-}" ]] || dot_die "profile is missing DOT_PROFILE_NAME"
    [[ "${#DOT_ITEMS[@]}" -gt 0 ]] || dot_die "profile has no DOT_ITEMS"
}

dot_active_profile() {
    if [[ -f "$DOT_STATE_DIR/profile" ]]; then
        cat "$DOT_STATE_DIR/profile"
        return
    fi

    if [[ -f "$DOT_PROFILES_DIR/personal.env" ]]; then
        printf 'personal\n'
        return
    fi

    dot_die "no active profile; run 'dot init <profile>'"
}

dot_profile_path() {
    local profile="$1"
    local path="$DOT_PROFILES_DIR/$profile.env"
    [[ -f "$path" ]] || dot_die "profile not found: $profile"
    printf '%s\n' "$path"
}

dot_item_var() {
    local item="$1"
    local field="$2"
    local var="DOT_ITEM_${item}_${field}"
    printf '%s' "${!var:-}"
}

dot_item_label() { dot_item_var "$1" LABEL; }
dot_item_path() { eval "printf '%s' \"$(dot_item_var "$1" PATH)\""; }
dot_item_repo() { dot_item_var "$1" REPO; }
dot_item_apply() { dot_item_var "$1" APPLY; }
