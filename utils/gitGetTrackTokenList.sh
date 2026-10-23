#!/usr/bin/env bash
set -euo pipefail

# Initialize working path constraints to resolve fully qualified system routes
WORKSPACE_ROOT="$(pwd)"

# 1. Source configuration properties relative to the script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.sh"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
else
  echo "❌ Error: Configuration file '$CONFIG_FILE' not found." >&2
  exit 1
fi

# Ensure symbols exist even if left blank in config
releaseLeftSymbol="${releaseLeftSymbol:-}"
releaseRightSymbol="${releaseRightSymbol:-}"

# Initialize runtime variables
FORWARD_ARGS=()
ONLY_PROJECT=""

# Parse input parameters
while [[ $# -gt 0 ]]; do
  case "$1" in
    -since-tag|-since-branch)
      FORWARD_ARGS+=("$1" "$2")
      shift 2
      ;;
    -onlyProject)
      ONLY_PROJECT="$2"
      shift 2
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# 2. Collect commit payload logs from base tracking script
COMMIT_LOG_SCRIPT="${SCRIPT_DIR}/gitGetCommitSince.sh"

if [[ ! -x "$COMMIT_LOG_SCRIPT" ]]; then
  echo "❌ Error: Log script '$COMMIT_LOG_SCRIPT' is missing or not executable." >&2
  exit 1
fi

JSON_PAYLOAD=$("$COMMIT_LOG_SCRIPT" "${FORWARD_ARGS[@]}")

# Rule Validation: Exit -2 if empty or structurally void
if [[ -z "${JSON_PAYLOAD:-}" ]] || [ "$JSON_PAYLOAD" == "[]" ] || [ "$JSON_PAYLOAD" == "null" ]; then
  echo "⚠️ Commit log payload is empty or not found." >&2
  exit 2
fi

if ! echo "$JSON_PAYLOAD" | jq empty 2>/dev/null; then
  echo "❌ Error: Script output is not a valid JSON structure." >&2
  exit 1
fi

# 3. Discover all project files matching configuration filters across workspace
PROJECT_EXTENSIONS=()
if [[ -n "${projectIdDetected+x}" ]] && [ ${#projectIdDetected[@]} -gt 0 ]; then
  for ext in "${projectIdDetected[@]}"; do
    PROJECT_EXTENSIONS+=("-name" "*.$ext" "-o")
  done
  unset 'PROJECT_EXTENSIONS[${#PROJECT_EXTENSIONS[@]}-1]' # Drop trailing '-o'
else
  echo "❌ Error: 'projectIdDetected' variable must be populated inside config.sh." >&2
  exit 1
fi

ALL_PROJECT_FILES=()
while IFS= read -r line; do
  if [[ -n "$line" ]]; then
    # Native Bash string cleaning (replaces find prefix sed lines)
    CLEAN_LINE="${line#./}"
    CLEAN_LINE="${CLEAN_LINE#/}"
    ALL_PROJECT_FILES+=("$CLEAN_LINE")
  fi
done < <(find . -type f \( "${PROJECT_EXTENSIONS[@]}" \) 2>/dev/null)

# 4. Generate dynamic regular expression string values using JQ's native literal escaping
escape_regex() {
  jq -rn --arg str "$1" '$str | gsub("[\\.\\[\\]\\*\\+\\?\\^\\$\\{\\}\\(\\)\\|\\\\\\/]"; "\\\\\\&")'
}

# Constructs whole-word boundary wrappers with space tolerances depending on delimiter presence
build_regex_list() {
  local -n current_array=$1
  local processed_tokens=()
  for raw_t in "${current_array[@]}"; do
    processed_tokens+=("$(escape_regex "$raw_t")")
  done

  local left_bound=""
  [[ -n "$releaseLeftSymbol" ]] && left_bound="$(escape_regex "$releaseLeftSymbol")[[:space:]]*"
  
  local right_bound=""
  [[ -n "$releaseRightSymbol" ]] && right_bound="[[:space:]]*$(escape_regex "$releaseRightSymbol")"
  
  (local IFS="|"; echo "${left_bound}(${processed_tokens[*]})${right_bound}")
}

# Compile target match definitions
REGEX_FEAT=$(build_regex_list releaseFeatureTokens)
REGEX_FIX=$(build_regex_list releaseFixTokens)
REGEX_BREAK=$(build_regex_list releaseBreakingTokens)
REGEX_NOTE=$(build_regex_list releaseNoteTokens)
REGEX_WIP=$(build_regex_list releaseDirtyTokens)
REGEX_TRACE=$(build_regex_list releaseNoTriggerTokens)
REGEX_NOLOG=$(build_regex_list releaseNoLogTokens)

# 5. Execute internal JSON structural parsing using JQ with clean message extraction
PROCESSED_JSON=$(echo "$JSON_PAYLOAD" | jq \
  --arg feat_p "$REGEX_FEAT" \
  --arg fix_p "$REGEX_FIX" \
  --arg break_p "$REGEX_BREAK" \
  --arg note_p "$REGEX_NOTE" \
  --arg wip_p "$REGEX_WIP" \
  --arg trace_p "$REGEX_TRACE" \
  --arg nolog_p "$REGEX_NOLOG" \
  '
  map(
    . + {
      releaseFeatureTokenId: [],
      releaseFixTokenId: [],
      releaseBreakingTokenId: [],
      releaseNoteTokenId: [],
      releaseWipTokenId: [],
      releaseTraceTokenId: []
    } |
    
    if (.commit_message | test($feat_p; "i")) then .releaseFeatureTokenId += [(.commit_message | sub($feat_p; ""; "i") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))] else . end |
    if (.commit_message | test($fix_p; "i")) then .releaseFixTokenId += [(.commit_message | sub($fix_p; ""; "i") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))] else . end |
    if (.commit_message | test($break_p; "i")) then .releaseBreakingTokenId += [(.commit_message | sub($break_p; ""; "i") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))] else . end |
    if (.commit_message | test($note_p; "i")) then .releaseNoteTokenId += [(.commit_message | sub($note_p; ""; "i") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))] else . end |
    if (.commit_message | test($wip_p; "i")) then .releaseWipTokenId += [(.commit_message | sub($wip_p; ""; "i") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))] else . end |
    if (.commit_message | test($trace_p; "i")) then .releaseTraceTokenId += [(.commit_message | sub($trace_p; ""; "i") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))] 
    elif (.commit_message | test($nolog_p; "i")) then .releaseTraceTokenId += [(.commit_message | sub($nolog_p; ""; "i") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))]
    else . end |
    
    del(.commit_message)
  )
')

# 6. Closest-Ancestor Project Location Resolution Engine & Filter Matrix
FINAL_OUTPUT_ARRAY=()

# Native Bash prefix cleaning to safely sanitize input without invoking sed
CLEAN_ONLY_PROJECT="${ONLY_PROJECT:-}"
CLEAN_ONLY_PROJECT="${CLEAN_ONLY_PROJECT#./}"
CLEAN_ONLY_PROJECT="${CLEAN_ONLY_PROJECT#/}"
# Strip leading/trailing spaces
CLEAN_ONLY_PROJECT="$(echo "$CLEAN_ONLY_PROJECT" | xargs)"

while IFS= read -r commit_item; do
  [[ -z "$commit_item" ]] && continue
  
  AFFECTED_FILES_JSON=$(echo "$commit_item" | jq -c '.affected_files')
  AFFECTED_PROJECTS=()
  MATCHES_FILTER=false
  
  while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue
    
    # Native Bash text matching strings instead of nested sed logic blocks
    CLEAN_FILE_PATH="${file_path#./}"
    CLEAN_FILE_PATH="${CLEAN_FILE_PATH#/}"
    
    BEST_MATCH=""
    BEST_RELATIVE_MATCH=""
    BEST_DEPTH=-1
    
    for proj_file in "${ALL_PROJECT_FILES[@]}"; do
      PROJ_DIR=$(dirname "$proj_file")
      [[ "$PROJ_DIR" == "." ]] && PROJ_DIR=""
      
      if [[ "$CLEAN_FILE_PATH" == "$PROJ_DIR"* ]]; then
        if [ "$PROJ_DIR" == "" ]; then
          DEPTH=0
        else
          DEPTH=$(tr -cd '/' <<< "$PROJ_DIR" | wc -c)
          DEPTH=$((DEPTH + 1))
        fi
        
        # Closest ancestor match wins
        if [ "$DEPTH" -gt "$BEST_DEPTH" ]; then
          BEST_DEPTH=$DEPTH
          BEST_RELATIVE_MATCH="$proj_file"
          BEST_MATCH="${WORKSPACE_ROOT}/${proj_file}"
        fi
      fi
    done
    
    if [[ -n "$BEST_MATCH" ]]; then
      AFFECTED_PROJECTS+=("$BEST_MATCH")
      
      # Relative path verification
      if [[ -n "$CLEAN_ONLY_PROJECT" ]] && [[ "$BEST_RELATIVE_MATCH" == "$CLEAN_ONLY_PROJECT" ]]; then
        MATCHES_FILTER=true
      fi
    fi
  done < <(echo "$AFFECTED_FILES_JSON" | jq -r '.[]')
  
  # Filter-out logic tracking checks
  if [[ -n "$CLEAN_ONLY_PROJECT" ]] && [ "$MATCHES_FILTER" = false ]; then
    continue
  fi
  
  # Deduplicate projects array contents
  SORTED_PROJECTS=()
  if [ ${#AFFECTED_PROJECTS[@]} -gt 0 ]; then
    while IFS= read -r uniq_proj; do
      [[ -n "$uniq_proj" ]] && SORTED_PROJECTS+=("$uniq_proj")
    done < <(printf '%s\n' "${AFFECTED_PROJECTS[@]}" | sort -u)
  fi
  
  # Map arrays directly into structural objects and delete affected_files
  UPDATED_ITEM=$(echo "$commit_item" | jq \
    --argjson projs "$(printf '%s\n' "${SORTED_PROJECTS[@]:-}" | jq -R . | jq -s .)" \
    '. + {affected_projects: $projs} | del(.affected_files)')
  
  FINAL_OUTPUT_ARRAY+=("$UPDATED_ITEM")
  
done < <(echo "$PROCESSED_JSON" | jq -c '.[]')

# Formulate single collective payload map matrix
printf '%s\n' "${FINAL_OUTPUT_ARRAY[@]:-}" | jq -s .
