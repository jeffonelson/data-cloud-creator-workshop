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

workshop_region_is_valid() {
  [[ "${1:-}" =~ ^[a-z]+(-[a-z]+)+[0-9]+$ ]]
}

# Read the selected project's region as data, never by sourcing project.env.
# Older checkouts must rerun setup instead of silently assuming us-central1.
workshop_load_project_region() {
  local state_file region cloud_run_region
  state_file="$(workshop_project_state_file)"
  region="$(sed -n 's/^ALLOYDB_REGION=//p' "$state_file" 2>/dev/null)" || region=''
  cloud_run_region="$(sed -n 's/^CLOUD_RUN_REGION=//p' "$state_file" 2>/dev/null)" || cloud_run_region=''
  if ! workshop_region_is_valid "$region" || ! workshop_region_is_valid "$cloud_run_region"; then
    workshop_error "No valid saved workshop region. Run: ./bin/setup PROJECT_ID --region REGION"
    return 1
  fi
  DAK_GCP_REGION="$region"
  CLOUD_RUN_REGION="$cloud_run_region"
}

# ---------------------------------------------------------------------------
# Data Agent Kit version
#
# DAK_REF in config/workshop.env is an override and is normally empty. When it
# is empty, bin/setup resolves the newest upstream release tag once and records
# it in .workshop-state/dak-ref, so every agent on this machine installs the
# same version and nothing drifts during a workshop. bin/teardown removes the
# record, so teardown followed by setup moves to the current release.
# ---------------------------------------------------------------------------

DAK_REF_PATTERN='^(v?[0-9]+\.[0-9]+\.[0-9]+|[0-9a-fA-F]{40})$'

workshop_dak_ref_state_file() {
  printf '%s' "$repo_root/.workshop-state/dak-ref"
}

workshop_dak_ref_is_valid() {
  [[ "${1:-}" =~ $DAK_REF_PATTERN ]]
}

# Echoes the newest upstream release tag: MAJOR.MINOR.PATCH with an optional v
# prefix and no prerelease suffix. Returns non-zero when it cannot be
# determined. git ls-remote needs no token and has no per-IP rate limit, unlike
# the GitHub API, which a room on shared wifi would exhaust during setup.
workshop_latest_dak_release() {
  local tags
  command -v git >/dev/null 2>&1 || return 1
  tags="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "$DAK_REPOSITORY" 2>/dev/null)" || return 1
  printf '%s\n' "$tags" \
    | sed -n 's|.*refs/tags/||p' \
    | awk -F. '/^v?[0-9]+\.[0-9]+\.[0-9]+$/ { t = $0; sub(/^v/, "", t); split(t, p, "."); print p[1], p[2], p[3], $0 }' \
    | sort -k1,1n -k2,2n -k3,3n \
    | tail -n 1 \
    | awk 'NF { printf "%s", $4 }' \
    | grep .
}

# Echoes the ref recorded by setup, or nothing when none is recorded.
workshop_saved_dak_ref() {
  local state_file
  state_file="$(workshop_dak_ref_state_file)"
  [[ -f "$state_file" ]] || return 0
  head -n 1 "$state_file"
}

# Echoes the ref this checkout should be using: the DAK_REF override when set,
# otherwise the recorded release. Returns non-zero when neither exists or the
# value is malformed.
workshop_effective_dak_ref() {
  local ref="${DAK_REF:-}"
  [[ -n "$ref" ]] || ref="$(workshop_saved_dak_ref)"
  workshop_dak_ref_is_valid "$ref" || return 1
  printf '%s' "$ref"
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
  ' "$agent" "$kind" "${3:-$DAK_PLUGIN}" "${3:-$DAK_MARKETPLACE}" <<<"$listing"
}

# Both callers check the actual installed version as well as its marketplace.
workshop_check_dak_installation() {
  local agent="$1" ref="$2" marketplace plugin
  marketplace="$(workshop_agent_entry "$agent" marketplace)" || return 1
  plugin="$(workshop_agent_entry "$agent" plugin)" || return 1
  printf '%s\n%s\n' "$marketplace" "$plugin" |
    node -e '
      const fs = require("fs"), {spawnSync} = require("child_process");
      const [agent, ref, repository, mode] = process.argv.slice(1);
      let failed = false;
      const report = (ok, text) => { console.log((ok ? "PASS " : "FAIL ") + agent + ": " + text); failed ||= !ok; };
      try {
        const [market, plugin] = fs.readFileSync(0,"utf8").trim().split("\n").map(JSON.parse);
        const source = agent === "codex" ? market?.marketplaceSource?.source : market?.url;
        const actualRef = agent === "codex" ? market?.marketplaceSource?.ref : market?.ref;
        const sameSource = Boolean(source) && source.replace(/\.git$/, "") === repository.replace(/\.git$/, "");
        report(sameSource, "DAK marketplace source " + (sameSource ? "matches" : "differs from") + " the workshop repository");
        if (agent !== "codex" || actualRef !== undefined)
          report(actualRef === ref, `marketplace ref is ${actualRef || "the default branch"}; expected ${ref}`);
        let version = /^v?\d+\.\d+\.\d+$/.test(ref) ? ref.replace(/^v/, "") : "";
        if (!version && market && /^[0-9a-f]{40}$/i.test(ref)) {
          const root = agent === "codex" ? market.root : market.installLocation;
          if (root) {
            const git = args => spawnSync("git", ["-C", root, ...args], {encoding:"utf8"});
            const head = git(["rev-parse", "HEAD"]);
            const target = git(["rev-parse", "--verify", ref + "^{commit}"]);
            if (head.status === 0 && target.status === 0 && head.stdout === target.stdout) {
              const manifest = git(["show", "HEAD:plugin.json"]);
              if (manifest.status === 0) version = JSON.parse(manifest.stdout).version;
            }
          }
        }
        if (plugin || mode !== "existing") {
          report(Boolean(plugin && version && plugin.version === version), `installed DAK version is ${plugin?.version || "missing"}; expected ${version || ref}`);
          report(Boolean(plugin) && plugin.enabled !== false && (agent !== "claude" || plugin.scope === "user"), "DAK must be enabled at the supported user scope");
        }
      } catch { report(false, "cannot verify DAK installation metadata; check the CLI listing and retry"); }
      process.exitCode = failed ? 1 : 0;
    ' "$agent" "$ref" "$DAK_REPOSITORY" "${3:-}"
}

# Upstream owns this non-secret user config. Only remove a file we created and
# whose content still matches our marker; never overwrite another DAK setup.
workshop_dak_settings() {
  node -e '
    const fs = require("fs"), path = require("path"), {isDeepStrictEqual: equal} = require("util");
    const [mode, state, project, region] = process.argv.slice(1);
    const file = path.join(require("os").homedir(), ".config/data-agent-kit/config.json");
    const marker = path.join(state, "dak-config-added-by-workshop");
    const read = p => fs.existsSync(p) ? JSON.parse(fs.readFileSync(p,"utf8")) : null;
    try {
      const current = read(file), owned = read(marker);
      const wanted = {projectId:project, region, services:["BigQuery", "AlloyDB"]};
      if (mode === "remove") {
        if (owned) {
          if (equal(current, owned)) fs.unlinkSync(file);
          else if (current) console.error("Preserved the upstream DAK configuration because it was changed after setup.");
          fs.unlinkSync(marker);
        }
      } else if (mode === "check" || mode === "record") {
        if (!equal(current, wanted)) throw Error("DAK project, region, or services differ; run ./bin/setup PROJECT_ID --region REGION.");
        if (mode === "record" && owned)
          fs.writeFileSync(marker, JSON.stringify(wanted) + "\n", {mode:0o600});
      } else {
        if (current && !equal(current, wanted) && !equal(current, owned))
          throw Error("Existing upstream DAK configuration differs. Preserve or reconfigure it with upstream dak-setup before retrying; workshop setup will not overwrite it.");
        // Keep the previous ownership snapshot until upstream actually saves
        // a new project, so an interrupted switch can be retried safely.
        if (mode === "claim" && !current)
          fs.writeFileSync(marker, JSON.stringify(wanted) + "\n", {mode:0o600});
      }
    } catch (error) {
      console.error(error instanceof SyntaxError || error.code ? "Cannot read or update upstream DAK configuration; check its JSON and file permissions." : error.message);
      process.exitCode = 1;
    }
  ' "$1" "$(workshop_state_dir)" "${2:-}" "$DAK_GCP_REGION"
}

# Configure an isolated installed copy, never a marketplace staging checkout.
# Clear inherited agent indicators so running setup inside one agent cannot
# accidentally configure the other agent using the wrong MCP format.
workshop_configure_dak() {
  local agent="$1" plugin_root="$2" project="$3" indicator manifest
  case "$agent" in
    codex) indicator=CODEX_THREAD_ID=workshop-setup; manifest=mcp.json ;;
    claude) indicator=CLAUDECODE=1; manifest=.claude-plugin/mcp.json ;;
    antigravity) indicator=ANTIGRAVITY_AGENT=1; manifest=mcp_config.json ;;
    *) return 1 ;;
  esac
  if [[ ! -f "$plugin_root/skills/dak-setup/scripts/dak-setup.js" ]]; then
    workshop_error "$agent: the bundled GA DAK setup script is missing; inspect the installed plugin."
    return 1
  fi
  workshop_dak_settings claim "$project" || return 1
  env -u ANTIGRAVITY_AGENT -u ANTIGRAVITY_CONVERSATION_ID -u CLAUDECODE \
    -u CLAUDE_CODE_ENTRYPOINT -u CODEX_THREAD_ID -u CODEX_SESSION_ID -u PLUGIN_ROOT \
    "$indicator" node "$plugin_root/skills/dak-setup/scripts/dak-setup.js" save \
    --project-id "$project" --region "$DAK_GCP_REGION" --services BigQuery AlloyDB || return 1
  # DAK 1.1.0 can report a write failure with exit status zero. Verify outputs.
  workshop_dak_settings record "$project" || return 1
  workshop_check_dak_configuration "$plugin_root" "$manifest"
}

workshop_check_dak_configuration() {
  node -e '
    try {
      const fs = require("fs"), path = require("path"), root = process.argv[1];
      const servers = JSON.parse(fs.readFileSync(path.join(root, process.argv[2]), "utf8")).mcpServers;
      const names = ["dak-bigquery", "dak-alloydb", "dak-notebook", "dak-viz"];
      // Codex can restore the upstream catalog after setup. Extra upstream
      // servers do not invalidate the workshop services; never rewrite its cache.
      const allowExtra = process.argv[3] === "codex";
      if ((!allowExtra && Object.keys(servers).length !== names.length) ||
          names.some(name => !servers[name] || servers[name].disabled)) throw Error();
      if (!fs.existsSync(path.join(root, "skills/bigquery-ai-ml/SKILL.md"))) throw Error();
    } catch { console.error("DAK service configuration is incomplete; inspect the installed plugin and retry setup."); process.exitCode = 1; }
  ' "$1" "$2" "${3:-}"
}

workshop_dak_plugin_root() {
  local entry
  entry="$(workshop_agent_entry "$1" plugin)" || return 1
  node -e '
    const [agent, home] = process.argv.slice(1);
    const entry = JSON.parse(require("fs").readFileSync(0,"utf8"));
    const root = agent === "codex"
      ? entry?.marketplaceName && entry.name && entry.version && require("path").join(home,"plugins/cache",entry.marketplaceName,entry.name,entry.version)
      : entry?.installPath;
    if (!root) process.exit(1);
    console.log(root);
  ' "$1" "${CODEX_HOME:-$HOME/.codex}" <<<"$entry"
}

# Echoes the absolute path of an installed Data Agent Kit MCP proxy, or returns
# non-zero when neither agent has one. Pass claude or codex to check a single
# agent; pass nothing to accept whichever is installed.
workshop_dak_proxy_path() {
  local agent plugin_root candidate
  for agent in ${1:-claude codex}; do
    command -v "$agent" >/dev/null 2>&1 || continue
    plugin_root="$(workshop_dak_plugin_root "$agent")" || continue
    candidate="$plugin_root/$DAK_PROXY_RELATIVE_PATH"
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
    workshop_hint "Run: ./bin/setup PROJECT_ID --region REGION"
    return 1
  fi

  if ! workshop_project_id_is_valid "$project_id"; then
    workshop_error "The saved workshop project ID is invalid. Run: ./bin/setup PROJECT_ID --region REGION"
    return 1
  fi

  workshop_load_project_region || return 1
  workshop_dak_settings check "$project_id" || return 1
  workshop_export_project_env "$project_id"
  workshop_source_env_local
  workshop_load_secret_if_unset WORKSHOP_DK_API_KEY "$DK_SECRET_ID" "$project_id" || return 1
  workshop_load_secret_if_unset WORKSHOP_MAPS_API_KEY "$MAPS_SECRET_ID" "$project_id" || return 1
  workshop_export_dak_proxy "$agent"

  WORKSHOP_PROJECT_ID="$project_id"
}

# shellcheck source=antigravity.sh
source "$repo_root/bin/lib/antigravity.sh"
