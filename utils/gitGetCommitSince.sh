#!/usr/bin/env bash
set -euo pipefail

# Initialize variables with defaults
SINCE_TAG=""

# Keep track of whether the user explicitly passed a tag argument
PASSED_TAG=false
ALL_HISTORY=false

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -since-tag)
      SINCE_TAG="$2"
      PASSED_TAG=true
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

# Use all history unless a non-empty tag was supplied
if [ "$PASSED_TAG" = false ] || [[ -z "$SINCE_TAG" ]]; then
  ALL_HISTORY=true
else
  TARGET="$SINCE_TAG"
  if ! git rev-parse "$TARGET" >/dev/null 2>&1; then
    echo "❌ Error: Local tag '$TARGET' does not exist." >&2
    exit 1
  fi
fi

# Verify if jq is installed for parsing the payload
if ! command -v jq &> /dev/null; then
  echo "❌ Error: 'jq' command-line tool is required to run this script safely." >&2
  exit 1
fi

# Process the log locally from the target baseline up to the active HEAD
if [ "$ALL_HISTORY" = true ]; then
  git log HEAD --name-only --format="format:__COMMIT_START__%H__BODY_START__%B__FILES_START__"
else
  git log "${TARGET}..HEAD" --name-only --format="format:__COMMIT_START__%H__BODY_START__%B__FILES_START__"
fi | \
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
