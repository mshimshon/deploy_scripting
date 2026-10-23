#!/usr/bin/env bash
set -euo pipefail

# Initialize variables with defaults
SINCE_TAG=""
SINCE_BRANCH="main" # Defaulting to local branch name

# Keep track of whether the user explicitly passed a branch or tag argument
PASSED_TAG=false
PASSED_BRANCH=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -since-tag)
      SINCE_TAG="$2"
      PASSED_TAG=true
      shift 2
      ;;
    -since-branch)
      SINCE_BRANCH="$2"
      PASSED_BRANCH=true
      shift 2
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Verify if we are inside a valid git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "❌ Error: Not a valid git repository." >&2
  exit 1
fi

# Validation: Determine the local base reference
if [ "$PASSED_TAG" = false ] && [ "$PASSED_BRANCH" = false ]; then
  TARGET="$SINCE_BRANCH"
else
  if [[ -n "$SINCE_TAG" ]] && [[ -n "$SINCE_BRANCH" ]]; then
    # BOTH are provided: Validate local existence first
    if ! git rev-parse "$SINCE_TAG" >/dev/null 2>&1; then
      echo "❌ Error: Local tag '$SINCE_TAG' does not exist." >&2
      exit 1
    fi
    if ! git rev-parse "$SINCE_BRANCH" >/dev/null 2>&1; then
      echo "❌ Error: Local branch '$SINCE_BRANCH' does not exist." >&2
      exit 1
    fi

    # Pick whichever commit is newer (closer to your active local HEAD)
    if git merge-base --is-ancestor "$SINCE_BRANCH" "$SINCE_TAG"; then
      TARGET="$SINCE_TAG"
    else
      TARGET="$SINCE_BRANCH"
    fi
  elif [[ -n "$SINCE_TAG" ]]; then
    TARGET="$SINCE_TAG"
  elif [[ -n "$SINCE_BRANCH" ]]; then
    TARGET="$SINCE_BRANCH"
  else
    echo "❌ Error: Supplied arguments cannot evaluate to empty values." >&2
    exit 1
  fi
fi

# Verify if the chosen local target reference exists
if ! git rev-parse "$TARGET" >/dev/null 2>&1; then
  echo "❌ Error: Local reference '$TARGET' does not exist." >&2
  exit 1
fi

# Verify if jq is installed for parsing the payload
if ! command -v jq &> /dev/null; then
  echo "❌ Error: 'jq' command-line tool is required to run this script safely." >&2
  exit 1
fi

# Process the log locally from the target baseline up to the active HEAD
git log "${TARGET}..HEAD" --name-only --format="format:__COMMIT_START__%H__BODY_START__%B__FILES_START__" | \
jq -Rs '
  split("__COMMIT_START__") | 
  map(
    select(. != "") | 
    split("__BODY_START__") as $commit_parts |
    $commit_parts[0] as $id |
    ($commit_parts[1] | split("__FILES_START__")) as $msg_and_files |
    $msg_and_files[0] as $message |
    ($msg_and_files[1] | split("\n") | map(select(. != ""))) as $files |
    {
      commit_id: $id,
      commit_message: ($message | rtrimstr("\n")),
      affected_files: $files
    }
  )
'
