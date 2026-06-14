#!/usr/bin/env bash

DOT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dot"
DOT_PROFILES_DIR="${DOT_ROOT:-$(pwd)}/profiles"

dot_info() { printf '[dot] %s\n' "$*"; }
dot_warn() { printf '[dot] warning: %s\n' "$*" >&2; }
dot_die() { printf '[dot] error: %s\n' "$*" >&2; exit 1; }

dot_usage() {
    cat <<'EOF'
Usage:
  dot init <profile>
  dot status
  dot down [--fetch-only] [--no-doctor]
  dot up [item] [-m message]
  dot doctor
  dot profile

Core flow:
  dot down    Bring profile repos down to this machine and apply them.
  dot up      Commit and push local changes from profile repos.
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
    dot_info "active profile: $profile"
    dot_cmd_down --no-doctor
}

dot_cmd_profile() {
    dot_info "active profile: $(dot_active_profile)"
}

dot_cmd_status() {
    dot_load_profile

    printf 'Profile: %s\n\n' "$DOT_PROFILE_NAME"
    printf 'Repos:\n'

    local item
    for item in "${DOT_ITEMS[@]}"; do
        dot_print_item_status "$item"
    done
}

dot_cmd_down() {
    local fetch_only=0
    local run_doctor=1
    DOT_DOWN_BLOCKED=" "
    DOT_DOWN_HAD_BLOCKED=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fetch-only) fetch_only=1 ;;
            --no-doctor) run_doctor=0 ;;
            *) dot_die "unknown down option: $1" ;;
        esac
        shift
    done

    dot_load_profile

    local item
    for item in "${DOT_ITEMS[@]}"; do
        dot_down_item "$item" "$fetch_only"
    done

    if [[ "$fetch_only" -eq 1 ]]; then
        dot_info "fetch complete; run 'dot status' to inspect incoming changes"
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

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--message)
                shift
                [[ $# -gt 0 ]] || dot_die "missing message after -m"
                message="$1"
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
        dot_up_item "$item" "$message" && pushed=1
    done

    if [[ "$DOT_UP_HAD_BLOCKED" -eq 1 ]]; then
        dot_die "one or more repos need manual resolution"
    fi

    if [[ -n "$target" && "$pushed" -eq 0 ]]; then
        dot_warn "nothing pushed for $target"
    elif [[ "$pushed" -eq 0 ]]; then
        dot_info "nothing to push"
    fi
}

dot_cmd_doctor() {
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

    if [[ "$ok" -eq 1 ]]; then
        dot_info "doctor passed"
    else
        dot_die "doctor found issues"
    fi
}

dot_down_item() {
    local item="$1"
    local fetch_only="$2"
    local label path repo
    label="$(dot_item_label "$item")"
    path="$(dot_item_path "$item")"
    repo="$(dot_item_repo "$item")"

    printf '\n==> %s\n' "$label"

    if [[ ! -d "$path/.git" ]]; then
        [[ -n "$repo" ]] || dot_die "$label has no repo configured"
        mkdir -p "$(dirname "$path")"
        dot_info "cloning $repo -> $path"
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

    printf '==> applying %s\n' "$label"
    (cd "$path" && eval "$apply")
}

dot_up_item() {
    local item="$1"
    local message="$2"
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
    else
        if ! dot_reconcile_item "$item"; then
            DOT_UP_HAD_BLOCKED=1
            return 1
        fi
    fi

    printf '\n==> %s\n' "$label"
    git -C "$path" status --short

    local commit_message="$message"
    if [[ -z "$commit_message" ]]; then
        commit_message="Update $label"
    fi

    dot_info "committing: $commit_message"
    git -C "$path" add -A
    git -C "$path" commit -m "$commit_message"
    dot_info "pushing $label"
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

    dot_info "reconciling $label"
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
        printf '\n==> %s\n' "$label"
        dot_info "pushing $label"
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
[dot] resolve manually:
  cd $path
  git status
  # fix conflicts, then follow git's rebase/merge instructions

[dot] then rerun:
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
        printf '  %-20s missing    %s\n' "$label" "$path"
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

    printf '  %-20s %-8s %-14s %s\n' "$label" "$dirty" "$branch" "$state"
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
