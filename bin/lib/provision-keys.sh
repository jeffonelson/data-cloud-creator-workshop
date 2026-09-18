#!/usr/bin/env bash
# Shared project-scoped MCP key provisioning. Never emits key values.
set +x
set -euo pipefail
# A user's debug configuration must not persist API responses containing keys.
export CLOUDSDK_CORE_LOG_HTTP=false
export CLOUDSDK_CORE_DISABLE_FILE_LOGGING=true
export CLOUDSDK_CORE_VERBOSITY=warning

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../config/workshop.env
source "$repo_root/config/workshop.env"
# shellcheck source=../config/cloud-services.env
source "$repo_root/config/cloud-services.env"
# shellcheck source=lib/workshop-common.sh
source "$repo_root/bin/lib/workshop-common.sh"

project_id="${1:-}"
refresh="${2:-}"
if [[ -z "$project_id" || ( -n "$refresh" && "$refresh" != "--refresh" ) || $# -gt 2 ]]; then
  echo "Usage: $0 PROJECT_ID [--refresh]" >&2
  exit 2
fi

if [[ ! "$project_id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
  workshop_error "Invalid Google Cloud project ID: $project_id"
  exit 2
fi

if ! command -v gcloud >/dev/null 2>&1; then
  workshop_error "Missing required command: gcloud"
  exit 1
fi

active_account="$(gcloud auth list --project="$project_id" --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)"
if [[ -z "$active_account" ]]; then
  workshop_error "No active gcloud account. Run: gcloud auth login"
  exit 1
fi

if ! gcloud projects describe "$project_id" --project="$project_id" >/dev/null 2>&1; then
  workshop_error "The active account cannot access project: $project_id"
  exit 1
fi

workshop_info "Enabling workshop APIs in $project_id..."
gcloud services enable \
  apikeys.googleapis.com \
  secretmanager.googleapis.com \
  "$DK_API_SERVICE" \
  "$MAPS_API_SERVICE" \
  "$RUN_API_SERVICE" \
  "$COMPUTE_API_SERVICE" \
  --project="$project_id" \
  --quiet

# Display names are cosmetic; the exclusive API restriction is what matters.
key_display_name() {
  case "$1" in
    "$DK_API_SERVICE")   echo "SVL workshop Developer Knowledge MCP" ;;
    "$MAPS_API_SERVICE") echo "SVL workshop Maps Grounding Lite MCP" ;;
    *)                   echo "SVL workshop key ($1)" ;;
  esac
}

# gcloud prints the created key, keyString included, on stderr regardless of
# --format. Discard stdout, capture stderr, and surface it only on failure,
# with anything key-shaped redacted, so no key value can reach a terminal,
# a log, or an agent transcript.
create_restricted_key() {
  local required_service="$1"
  local create_stderr

  # Progress on stderr: this function's stdout carries the key name.
  workshop_print_status "$WORKSHOP_SGR_CYAN$WORKSHOP_SGR_BOLD" '==>' 2 "Creating an API key restricted to $required_service..."
  if ! create_stderr="$(
    gcloud services api-keys create \
      --project="$project_id" \
      --display-name="$(key_display_name "$required_service")" \
      --api-target="service=$required_service" \
      --quiet 2>&1 >/dev/null
  )"; then
    workshop_error "Failed to create an API key restricted to $required_service in $project_id."
    printf '%s\n' "$create_stderr" \
      | sed 's/AIza[0-9A-Za-z_-]\{20,\}/[redacted]/g' >&2
    return 1
  fi
}

list_restricted_keys() {
  gcloud services api-keys list \
    --project="$project_id" \
    --filter="restrictions.apiTargets.service=$1" \
    --format='value(name)'
}

count_lines() {
  printf '%s\n' "$1" | awk 'NF { count++ } END { print count + 0 }'
}

find_restricted_key() {
  local required_service="$1"
  local matches
  local match_count
  local key_name
  local restricted_services
  local waited

  matches="$(list_restricted_keys "$required_service")"
  match_count="$(count_lines "$matches")"

  # A project provisioned from scratch has no keys yet. Create the one this
  # service needs; a project that already has exactly one is left untouched,
  # which keeps repeat runs idempotent.
  if [[ "$match_count" -eq 0 ]]; then
    create_restricted_key "$required_service" || return 1

    # Newly created keys can take a moment to appear in list results.
    waited=0
    while [[ "$match_count" -eq 0 && "$waited" -lt 30 ]]; do
      sleep 3
      waited=$((waited + 3))
      matches="$(list_restricted_keys "$required_service")"
      match_count="$(count_lines "$matches")"
    done

    if [[ "$match_count" -eq 0 ]]; then
      workshop_error "Created an API key for $required_service but it did not appear in $project_id."
      return 1
    fi
    # Stderr again: stdout is this function's return value.
    workshop_print_status "$WORKSHOP_SGR_GREEN" '  ok' 2 "Created API key restricted to $required_service."
  fi

  if [[ "$match_count" -ne 1 ]]; then
    workshop_error "Expected exactly one API key restricted to $required_service in $project_id; found $match_count."
    return 1
  fi

  key_name="$(printf '%s\n' "$matches" | awk 'NF { print; exit }')"
  restricted_services="$(
    gcloud services api-keys describe "$key_name" \
      --project="$project_id" \
      --format='value(restrictions.apiTargets.service)'
  )"

  if [[ "$restricted_services" != "$required_service" ]]; then
    workshop_error "The selected API key must be restricted only to $required_service."
    return 1
  fi

  printf '%s' "$key_name"
}

store_key_in_secret() {
  local required_service="$1"
  local secret_id="$2"
  local key_name
  local enabled_version
  local key_value

  key_name="$(find_restricted_key "$required_service")"

  if ! gcloud secrets describe "$secret_id" --project="$project_id" >/dev/null 2>&1; then
    gcloud secrets create "$secret_id" \
      --project="$project_id" \
      --replication-policy=automatic \
      --labels=purpose=codex-mcp,workshop=svl,managed-by=data-cloud-creator \
      --quiet >/dev/null
    workshop_ok "Created secret: $secret_id"
  fi

  enabled_version="$(
    gcloud secrets versions list "$secret_id" \
      --project="$project_id" \
      --filter='state=ENABLED' \
      --format='value(name)' \
      --limit=1
  )"

  if [[ -n "$enabled_version" && "$refresh" != "--refresh" ]]; then
    workshop_ok "Secret already has an enabled version: $secret_id"
    return
  fi

  key_value="$(gcloud services api-keys get-key-string "$key_name" --project="$project_id" --format='value(keyString)')"
  if [[ -z "$key_value" ]]; then
    workshop_error "Google Cloud returned an empty API key value for $required_service."
    return 1
  fi

  printf '%s' "$key_value" | gcloud secrets versions add "$secret_id" \
    --project="$project_id" \
    --data-file=- \
    --quiet >/dev/null
  unset key_value
  workshop_ok "Stored the current $required_service API key in: $secret_id"
}

store_key_in_secret "$DK_API_SERVICE" "$DK_SECRET_ID"
store_key_in_secret "$MAPS_API_SERVICE" "$MAPS_SECRET_ID"

workshop_print_line "$WORKSHOP_SGR_GREEN$WORKSHOP_SGR_BOLD" 1 "Project provisioning complete: $project_id"
