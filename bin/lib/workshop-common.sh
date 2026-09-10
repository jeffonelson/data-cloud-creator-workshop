#!/usr/bin/env bash
# Shared helpers for the SVL workshop scripts. Source this file; do not execute
# it. Callers must set repo_root before sourcing.
#
# Nothing here may print, log, or persist an API-key value.

# ---------------------------------------------------------------------------
# Status output
#
# Color is a secondary channel only. Every message keeps its plain-text label,
# so a piped log, a captured bug report, and a monochrome terminal all read
# exactly the same as an attendee's screen. Color is suppressed when NO_COLOR
# is set, when TERM is dumb, or when the destination stream is not a terminal.
# ---------------------------------------------------------------------------

WORKSHOP_SGR_RED=$'\033[0;31m'
WORKSHOP_SGR_GREEN=$'\033[0;32m'
WORKSHOP_SGR_YELLOW=$'\033[1;33m'
WORKSHOP_SGR_CYAN=$'\033[0;36m'
WORKSHOP_SGR_BOLD=$'\033[1m'
WORKSHOP_SGR_RESET=$'\033[0m'

# Colorability is decided per stream, because a piped stdout must not strip
# color from the stderr the attendee is still reading in their terminal.
workshop_stream_supports_color() {
  [[ -z "${NO_COLOR:-}" ]] || return 1
  [[ "${TERM:-}" != dumb ]] || return 1
  [[ -t "$1" ]]
}

# Prints one message on the given file descriptor, coloring only the label.
# Usage: workshop_print_status SGR LABEL FD MESSAGE
#
# Never call the printing helpers inside a command substitution: stdout is a
# pipe there, so the terminal test would always fail and color would be lost.
# Build the message first, then print it.
workshop_print_status() {
  local sgr="$1" label="$2" fd="$3" message="$4"
  local start='' end=''

  if [[ -n "$sgr" ]] && workshop_stream_supports_color "$fd"; then
    start="$sgr"
    end="$WORKSHOP_SGR_RESET"
  fi

  if [[ "$fd" == 2 ]]; then
    printf '%s%s%s  %s\n' "$start" "$label" "$end" "$message" >&2
  else
    printf '%s%s%s  %s\n' "$start" "$label" "$end" "$message"
  fi
}

# Prints a whole line in one color, for summaries that carry no label.
# Usage: workshop_print_line SGR FD TEXT
workshop_print_line() {
  local sgr="$1" fd="$2" text="$3"
  local start='' end=''

  if [[ -n "$sgr" ]] && workshop_stream_supports_color "$fd"; then
    start="$sgr"
    end="$WORKSHOP_SGR_RESET"
  fi

  if [[ "$fd" == 2 ]]; then
    printf '%s%s%s\n' "$start" "$text" "$end" >&2
  else
    printf '%s%s%s\n' "$start" "$text" "$end"
  fi
}

# Procedure output, for scripts that narrate a sequence of steps. Progress
# goes to stdout and problems go to stderr, so a caller can separate the
# narration from what actually went wrong.
#
# bin/doctor deliberately does not use these: it reports a table of checks
# rather than a procedure, so it defines its own PASS/FAIL/WARN labels on top
# of workshop_print_status. The printing core is the part that must not drift,
# not the choice of label.
workshop_step() {
  local number="$1" total="$2" title="$3"
  echo
  workshop_print_line "$WORKSHOP_SGR_CYAN$WORKSHOP_SGR_BOLD" 1 "[$number/$total] $title"
}

workshop_info()  { workshop_print_status "$WORKSHOP_SGR_CYAN$WORKSHOP_SGR_BOLD" '==>' 1 "$1"; }
workshop_ok()    { workshop_print_status "$WORKSHOP_SGR_GREEN" '  ok' 1 "$1"; }
workshop_warn()  { workshop_print_status "$WORKSHOP_SGR_YELLOW" '  !!' 2 "$1"; }
workshop_error() { workshop_print_status "$WORKSHOP_SGR_RED" '  xx' 2 "$1"; }

# A continuation line under a warning or error. It carries no label of its own
# and lines up with the message column above it, so a remedy reads as part of
# the problem rather than as a second, separate failure.
workshop_hint()  { workshop_print_status '' '    ' 2 "$1"; }

PROJECT_ID_PATTERN='^[a-z][a-z0-9-]{4,28}[a-z0-9]$'

workshop_load_config() {
  # shellcheck source=../../config/workshop.env
  source "$repo_root/config/workshop.env"
}

workshop_state_dir() {
  printf '%s' "$repo_root/.workshop-state"
}

workshop_project_state_file() {
  printf '%s' "$repo_root/.workshop-state/project.env"
}

# Echoes the saved project ID, or nothing when no selection is recorded.
workshop_saved_project() {
  local state_file
  state_file="$(workshop_project_state_file)"
  [[ -f "$state_file" ]] || return 0
  sed -n 's/^GCP_PROJECT_ID=//p' "$state_file"
}

workshop_project_id_is_valid() {
  [[ "${1:-}" =~ $PROJECT_ID_PATTERN ]]
}

# Scopes Google Cloud project selection to this process only. It never changes
# the user's global gcloud configuration.
workshop_export_project_env() {
  local project_id="$1"
  export CLOUDSDK_CORE_PROJECT="$project_id"
  export GOOGLE_CLOUD_PROJECT="$project_id"
  export GOOGLE_CLOUD_QUOTA_PROJECT="$project_id"
}

# Optional local-development override. Normal workshop launches retrieve every
# missing credential from Secret Manager instead.
workshop_source_env_local() {
  [[ -f "$repo_root/.env.local" ]] || return 0
  set -a
  # shellcheck disable=SC1091
  source "$repo_root/.env.local"
  set +a
}

# Loads one API key into the named variable when it is not already set.
# The value is never echoed, logged, or written to disk.
workshop_load_secret_if_unset() {
  local variable_name="$1"
  local secret_id="$2"
  local project_id="$3"
  local secret_value

  if [[ -n "${!variable_name:-}" ]]; then
    return 0
  fi

  if ! command -v gcloud >/dev/null 2>&1; then
    workshop_error "Cannot load $variable_name: gcloud is not installed."
    return 1
  fi

  if ! secret_value="$(
    gcloud secrets versions access "$SECRET_VERSION" \
      --secret="$secret_id" \
      --project="$project_id"
  )"; then
    workshop_error "Cannot load $variable_name from Secret Manager secret: $secret_id"
    workshop_hint "Run ./bin/doctor for authentication and IAM diagnostics."
    return 1
  fi

  if [[ -z "$secret_value" ]]; then
    workshop_error "Secret Manager returned an empty value for: $secret_id"
    return 1
  fi

  printf -v "$variable_name" '%s' "$secret_value"
  export "$variable_name"
  unset secret_value
}

# ---------------------------------------------------------------------------
# Data Agent Kit MCP proxy
#
# The Cloud Run MCP server is an ordinary Google Cloud endpoint that wants an
# OAuth access token, not an API key. The Data Agent Kit plugin already ships a
# stdio proxy that mints and refreshes one from Application Default
# Credentials, and it accepts any https://*.googleapis.com/**/mcp target, so
# this repository reuses it rather than implementing token refresh again.
#
# The catch is locating it. Both agents install the plugin under a directory
# named for the plugin version, so the path cannot be committed to .mcp.json or
# .codex/config.toml. Ask the agent instead, and let bin/mcp-dak-proxy exec
# whatever comes back.
# ---------------------------------------------------------------------------

# Return the workshop plugin or marketplace entry as JSON, or null if absent.
# A failed command or malformed listing is an error, never permission to install
# again. Both agents share this parser; their CLI commands remain explicit.
workshop_agent_entry() {
  local agent="$1" kind="$2" listing
  local args=(plugin)
  [[ "$kind" != marketplace ]] || args+=(marketplace)

  if ! listing="$("$agent" "${args[@]}" list --json 2>/dev/null)"; then
    workshop_error "Cannot list $agent ${kind}s; check '$agent plugin' and retry."
    return 1
  fi

  node -e '
    const [agent, kind, plugin, marketplace] = process.argv.slice(1);
    try {
      const doc = JSON.parse(require("fs").readFileSync(0, "utf8"));
      const list = agent === "codex"
        ? doc[kind === "plugin" ? "installed" : "marketplaces"] : doc;
      if (!Array.isArray(list)) throw new Error("invalid listing");
      const key = kind === "marketplace" ? "name" : agent === "codex" ? "pluginId" : "id";
      const id = kind === "marketplace" ? marketplace : plugin;
      console.log(JSON.stringify(list.find((entry) => entry && entry[key] === id) || null));
    } catch (error) {
      console.error("Cannot read " + agent + " " + kind + " listing; check the CLI and retry.");
      process.exit(1);
    }
  ' "$agent" "$kind" "$DAK_PLUGIN" "$DAK_MARKETPLACE" <<<"$listing"
}

# Echoes the absolute path of an installed Data Agent Kit MCP proxy, or returns
# non-zero when neither agent has one. Pass claude or codex to check a single
# agent; pass nothing to accept whichever is installed.
workshop_dak_proxy_path() {
  local agent entry candidate
  for agent in ${1:-claude codex}; do
    command -v "$agent" >/dev/null 2>&1 || continue
    entry="$(workshop_agent_entry "$agent" plugin)" || continue
    candidate="$(node -e '
      const [agent, codexHome, suffix] = process.argv.slice(1);
      const entry = JSON.parse(require("fs").readFileSync(0, "utf8"));
      if (!entry) process.exit(0);
      // Codex source.path is a staging checkout; rebuild the installed path.
      const root = agent === "codex"
        ? entry.marketplaceName && entry.name && entry.version &&
          [codexHome, "plugins/cache", entry.marketplaceName, entry.name, entry.version].join("/")
        : entry.installPath;
      if (root) console.log(root + "/" + suffix);
    ' "$agent" "${CODEX_HOME:-$HOME/.codex}" "$DAK_PROXY_RELATIVE_PATH" <<<"$entry")" || continue
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Publishes the resolved proxy path for bin/mcp-dak-proxy to exec.
#
# A missing proxy is a warning rather than a failure. It costs the workshop the
# Cloud Run exercise, which runs last, and there is no reason to block the rest
# of the session over it.
workshop_export_dak_proxy() {
  local agent="${1:-}"
  local proxy_path

  if proxy_path="$(workshop_dak_proxy_path "$agent")"; then
    export WORKSHOP_DAK_PROXY="$proxy_path"
    return 0
  fi

  workshop_warn "Could not locate the Data Agent Kit MCP proxy."
  workshop_hint "The Cloud Run MCP server will not start. Everything else is unaffected."
  workshop_hint "Run ./bin/doctor to diagnose the Data Agent Kit installation."
  return 0
}

# Common launcher preamble: resolve the saved project, scope the environment,
# load both workshop API keys, and publish the Data Agent Kit MCP proxy path.
# Sets WORKSHOP_PROJECT_ID on success. Takes the agent being launched.
#
# Call this directly, never inside a command substitution: the exported
# credentials would be confined to the subshell and lost.
workshop_prepare_launch() {
  local agent="${1:-}"
  local project_id
  project_id="$(workshop_saved_project)"

  if [[ -z "$project_id" ]]; then
    workshop_error "No workshop project is configured."
    workshop_hint "Run: ./bin/setup PROJECT_ID"
    return 1
  fi

  if ! workshop_project_id_is_valid "$project_id"; then
    workshop_error "The saved workshop project ID is invalid. Run: ./bin/setup PROJECT_ID"
    return 1
  fi

  workshop_export_project_env "$project_id"
  workshop_source_env_local
  workshop_load_secret_if_unset WORKSHOP_DK_API_KEY "$DK_SECRET_ID" "$project_id" || return 1
  workshop_load_secret_if_unset WORKSHOP_MAPS_API_KEY "$MAPS_SECRET_ID" "$project_id" || return 1
  workshop_export_dak_proxy "$agent"

  WORKSHOP_PROJECT_ID="$project_id"
}
