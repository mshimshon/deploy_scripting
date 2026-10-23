#!/usr/bin/env bash

# ==============================================================================
# RELEASE PIPELINE CONFIGURATION
# ==============================================================================

initialVersion="0.0.1";

masterBranch="origin/main"
globalChangelogName="goodlife_changelog.md"

# All the extensions that correspond to what we detect as a project. (WARNING: Don't be broad place .sh or .py will be catasrophic)
projectIdDetected=("csproj") 

releaseFeatureTokenId=("features" "New Features")
releaseBreakingTokenId=("breaking_changes" "BREAKING CHANGES")
releaseFixTokenId=("fixes" "Fixes")
releaseNoteTokenId=("notes" "Notes")
releaseWipTokenId=("work_in_progress" "WORK IN PROGRESS")
releaseTraceTokenId=("traces" "Traces")

# Core feature delivery tokens. Triggers standard minor semantic version increases.
releaseFeatureTokens=("feat" "feature")

# Defect remediation tokens. Triggers standard patch semantic version increases.
releaseFixTokens=("fix" "patch" "bugfix")

# Breaking change tokens. Forces a major version increment across delivery targets.
releaseBreakingTokens=("feat!" "break" "breaking")

# Supplementary release annotations. Captures critical operational notices 
# or manual intervention documentation required during the deployment phase.
releaseNoteTokens=("note") 

# Work-In-Progress (WIP) definitions. Coupled with local pre-push hooks 
# to enforce history cleaning and force squashes prior to main/master integration.
# Commits carrying these designations are strictly blocked from protected branches.
# Does not trigger workflow on push
releaseDirtyTokens=("wip" "work") 

# Workflow bypass tokens. Utilized for non-functional modifications (e.g., updates 
# to documentation or assets) to prevent redundant pipeline executions.
# Does not trigger workflow on push
releaseNoTriggerTokens=("trace!" "action!") 

# Change-log omission filters. Triggers full pipeline evaluations to ensure 
# structural hotfixes run, but completely suppresses entries in release logs.
releaseNoLogTokens=("trace" "action") 

# Structural Commit Syntax Delimiters or Wrappers. These symbols are used to encapsulate the core commit message.
releaseLeftSymbol=""
releaseRightSymbol=":"

# Dynamic Token Evaluation Scope
# Aggregate matrix defining all valid indicators authorized to process changes.
releaseIndicator=(
  "${releaseFeatureTokens[@]}"
  "${releaseFixTokens[@]}"
  "${releaseBreakingTokens[@]}"
  "${releaseNoteTokens[@]}"
  "${releaseNoTriggerTokens[@]}"
)

# Optional custom configuration. Missing keys retain their defaults above.
deployConfigFile="./.github/config/deploy_utils.json"
if [[ ! -f "$deployConfigFile" ]]; then
  cat <<'EOF'
INFO: Optional custom configuration was not found at ./.github/config/deploy_utils.json.
Create the file below to customize these defaults (all keys are optional):
{
  "initialVersion": "0.0.1",
  "masterBranch": "origin",
  "globalChangelogName": "goodlife_changelog.md",
  "projectIdDetected": ["csproj"],
  "releaseFeatureTokenId": ["features", "New Features"],
  "releaseBreakingTokenId": ["breaking_changes", "BREAKING CHANGES"],
  "releaseFixTokenId": ["fixes", "Fixes"],
  "releaseNoteTokenId": ["notes", "Notes"],
  "releaseWipTokenId": ["work_in_progress", "WORK IN PROGRESS"],
  "releaseTraceTokenId": ["traces", "Traces"],
  "releaseFeatureTokens": ["feat", "feature"],
  "releaseFixTokens": ["fix", "patch", "bugfix"],
  "releaseBreakingTokens": ["feat!", "break", "breaking"],
  "releaseNoteTokens": ["note"],
  "releaseDirtyTokens": ["wip", "work"],
  "releaseNoTriggerTokens": ["trace!", "action!"],
  "releaseNoLogTokens": ["trace", "action"],
  "releaseLeftSymbol": "",
  "releaseRightSymbol": ":",
  "releaseIndicator": ["feat", "feature", "fix", "patch", "bugfix", "feat!", "break", "breaking", "note", "trace!", "action!"]
}
EOF
elif ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to load $deployConfigFile; retaining defaults." >&2
else
  # Validate every key and value before changing any default.
  if ! jq -e '
    def scalar_keys: ["initialVersion", "masterBranch", "globalChangelogName", "releaseLeftSymbol", "releaseRightSymbol"];
    def array_keys: ["projectIdDetected", "releaseFeatureTokenId", "releaseBreakingTokenId", "releaseFixTokenId", "releaseNoteTokenId", "releaseWipTokenId", "releaseTraceTokenId", "releaseFeatureTokens", "releaseFixTokens", "releaseBreakingTokens", "releaseNoteTokens", "releaseDirtyTokens", "releaseNoTriggerTokens", "releaseNoLogTokens", "releaseIndicator"];
    type == "object"
    and all(keys[]; . as $key | ((scalar_keys + array_keys) | index($key)) != null)
    and all(scalar_keys[]; . as $key | (has($key) | not) or (.[$key] | type == "string"))
    and all(array_keys[]; . as $key | (has($key) | not) or ((.[$key] | type == "array") and all(.[$key][]; type == "string")))
  ' "$deployConfigFile" >/dev/null 2>&1; then
    echo "ERROR: Invalid configuration in $deployConfigFile; retaining defaults." >&2
  else
    # Keys are restricted by validation; jq @sh safely quotes all configured values.
    _deployOverrides=$(jq -r '
      to_entries[] |
      if (.value | type) == "array" then
        .key + "=(" + (.value | map(@sh) | join(" ")) + ")"
      else
        .key + "=" + (.value | @sh)
      end
    ' "$deployConfigFile")
    if [[ $? -eq 0 ]]; then
      eval "$_deployOverrides"
    else
      echo "ERROR: Could not read $deployConfigFile; retaining defaults." >&2
    fi
    unset _deployOverrides
  fi
fi



