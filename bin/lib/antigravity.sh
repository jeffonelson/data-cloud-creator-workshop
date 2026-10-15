# Antigravity desktop and CLI share ~/.gemini/config. No credentials live there.
workshop_agy_path() {
  command -v agy 2>/dev/null || { [[ ! -x "$HOME/.local/bin/agy" ]] || printf '%s\n' "$HOME/.local/bin/agy"; }
}

workshop_has_antigravity() {
  [[ -n "$(workshop_agy_path)" || -d /Applications/Antigravity.app || -d "$HOME/Applications/Antigravity.app" ]]
}

workshop_antigravity_config() {
  node "$repo_root/scripts/antigravity-config.cjs" "$1" "$repo_root" "$HOME/.gemini/config" "$DAK_GCP_REGION" "$CLOUD_RUN_MCP_URL" "$DAK_PROXY_RELATIVE_PATH"
}

workshop_setup_antigravity() {
  local source_dir="$repo_root/.workshop-state/antigravity-source"
  local ref
  command -v git >/dev/null 2>&1 || { workshop_error 'Antigravity setup requires git.'; return 1; }
  ref="$(workshop_effective_dak_ref)" || { workshop_error 'No Data Agent Kit version is recorded; run ./bin/setup PROJECT_ID.'; return 1; }
  # Record ownership before fetching so interrupted downloads can be retried.
  if [[ ! -e "$source_dir" ]]; then
    touch "$repo_root/.workshop-state/antigravity-source-added-by-workshop"
    mkdir -p "$source_dir"
  fi
  if [[ ! -f "$repo_root/.workshop-state/antigravity-source-added-by-workshop" ]]; then
    workshop_error 'Unmanaged Antigravity source directory exists; move it before retrying.'
    return 1
  fi
  if [[ ! -d "$source_dir/.git" ]]; then git -C "$source_dir" init -q; fi
  if [[ ! -f "$source_dir/.workshop-ref" ]]; then
    git -C "$source_dir" fetch -q --depth=1 "$DAK_REPOSITORY" "$ref" || return 1
    git -C "$source_dir" checkout -q --detach FETCH_HEAD || return 1
    printf '%s\n' "$ref" > "$source_dir/.workshop-ref"
  elif [[ "$(cat "$source_dir/.workshop-ref")" != "$ref" ]]; then
    workshop_error 'Antigravity source is at a different Data Agent Kit version. Run ./bin/teardown, then ./bin/setup PROJECT_ID.'
    return 1
  fi
  # Retain the workshop desktop discovery path, but let upstream generate the
  # plugin configuration and select skills instead of shipping a fallback.
  workshop_configure_dak antigravity "$source_dir" "$GCP_PROJECT_ID" || return 1
  workshop_antigravity_config setup
}
