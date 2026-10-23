#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Initializing changelog pipeline execution..." >&2

# Determine script directories and source config
SCRIPTPATH="$(cd "$(dirname "${BASH_SOURCE}")" &>/dev/null && pwd)"
if [ -f "$SCRIPTPATH/../config.sh" ]; then
    echo "[INFO] Sourcing pipeline variables from: $SCRIPTPATH/../config.sh" >&2
    source "$SCRIPTPATH/../config.sh"
else
    echo "[ERROR] Environment abort: config.sh not found at $SCRIPTPATH/../config.sh" >&2
    exit 1
fi

# Explicitly contain authorized log tracking keys (omitting Traces and WIP)
CONFIG_KEYS=(
    "releaseFeatureTokenId"
    "releaseBreakingTokenId"
    "releaseFixTokenId"
    "releaseNoteTokenId"
)

# Initialize default arguments
AUTO_SPLIT_PROJECT=false
AUTO_FAIL_EMPTY_RESULT=false
LINK_COMMITS=false
ONLY_PROJECT=""
OUTPUT_DIR=""

echo "[INFO] Parsing operational parameters..." >&2

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -autoSplitProject)
            AUTO_SPLIT_PROJECT=true
            echo "[DEBUG] Parameter enabled: -autoSplitProject" >&2
            shift
            ;;
        -autoFailEmptyResult)
            AUTO_FAIL_EMPTY_RESULT=true
            echo "[DEBUG] Parameter enabled: -autoFailEmptyResult" >&2
            shift
            ;;
        -linkCommits)
            LINK_COMMITS=true
            echo "[DEBUG] Parameter enabled: -linkCommits" >&2
            shift
            ;;
        -onlyProject)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                ONLY_PROJECT="$2"
                echo "[DEBUG] Target scope: $ONLY_PROJECT" >&2
                shift 2
            else
                echo "[ERROR] Parameter error: -onlyProject requires a value." >&2
                exit 1
            fi
            ;;
        -output)
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                OUTPUT_DIR="$2"
                echo "[DEBUG] Output path defined: $OUTPUT_DIR" >&2
                shift 2
            else
                echo "[ERROR] Parameter error: -output requires a directory path." >&2
                exit 1
            fi
            ;;
        *)
            echo "[ERROR] Unknown argument $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$OUTPUT_DIR" ]; then
    echo "[ERROR] -output argument is mandatory." >&2
    exit 1
fi

PROJECT_NAME=""
if [ -n "$ONLY_PROJECT" ]; then
    PROJECT_FILE_NAME="${ONLY_PROJECT##*/}"
    PROJECT_NAME="${PROJECT_FILE_NAME%.*}"
fi

mkdir -p "$OUTPUT_DIR"

if [ -n "$PROJECT_NAME" ]; then
    touch "$OUTPUT_DIR/${PROJECT_NAME}.md"
fi

GIT_BASE_URL=""
if [ "$LINK_COMMITS" = true ]; then
    RAW_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
    if [ -z "$RAW_REMOTE" ]; then
        echo "[ERROR] -linkCommits is true but remote origin URL is unreachable." >&2
        exit 1
    fi
    if [[ "$RAW_REMOTE" =~ ^git@ ]]; then
        GIT_BASE_URL=$(echo "$RAW_REMOTE" | sed -E 's|git@([^:]+):|https://\1/|' | sed 's|\.git$||')
    else
        GIT_BASE_URL=${RAW_REMOTE%.git}
    fi
fi

FETCH_ARGS=()
if [ -n "$ONLY_PROJECT" ]; then
    FETCH_ARGS+=("-onlyProject" "$ONLY_PROJECT")
fi

if [ ! -f "$SCRIPTPATH/gitGetTrackTokenList.sh" ]; then
    echo "[ERROR] Script missing: $SCRIPTPATH/gitGetTrackTokenList.sh" >&2
    exit 1
fi

JSON_DATA=$("$SCRIPTPATH/gitGetTrackTokenList.sh" "${FETCH_ARGS[@]}")

if [ "$AUTO_FAIL_EMPTY_RESULT" = true ]; then
    if [ -z "$JSON_DATA" ] || [ "$JSON_DATA" == "null" ] || [ "$(echo "$JSON_DATA" | jq '. | length')" -eq 0 ]; then
        echo "[ERROR] JSON payload validation failed." >&2
        exit 1
    fi
fi

init_markdown_file() {
    local target_file="$1"
    if [ ! -f "$target_file" ] || [ ! -s "$target_file" ]; then
        echo "# Changelog" > "$target_file"
        echo "" >> "$target_file"
        
        for key in "${CONFIG_KEYS[@]}"; do
            declare -n current_array="$key"
            if [ ${#current_array[@]} -ge 2 ]; then
                echo "## ${current_array[1]}" >> "$target_file"
                echo "" >> "$target_file"
            fi
        done
    fi
}

append_to_markdown() {
    local file="$1"
    local section_title="$2"
    local subsection_title="$3"
    local message_line="$4"

    init_markdown_file "$file"

    local tmp_file
    tmp_file=$(mktemp)

    local inserted=false
    local found_main_section=false
    local found_subsection=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^"## " ]] && [ "$found_main_section" = true ]; then
            if [ -n "$subsection_title" ] && [ "$inserted" = false ] && [ "$found_subsection" = false ]; then
                echo "### $subsection_title" >> "$tmp_file"
                echo "$message_line" >> "$tmp_file"
                echo "" >> "$tmp_file"
                inserted=true
            fi
            found_main_section=false
        fi

        echo "$line" >> "$tmp_file"

        if [ "$line" == "## $section_title" ]; then
            found_main_section=true
            if [ -z "$subsection_title" ] && [ "$inserted" = false ]; then
                echo "$message_line" >> "$tmp_file"
                inserted=true
            fi
            continue
        fi

        if [ "$found_main_section" = true ] && [ -n "$subsection_title" ]; then
            if [ "$line" == "### $subsection_title" ]; then
                found_subsection=true
                echo "$message_line" >> "$tmp_file"
                inserted=true
            fi
        fi
    done < "$file"

    if [ "$inserted" = false ]; then
        if [ "$found_main_section" = true ] && [ -n "$subsection_title" ]; then
            echo "" >> "$tmp_file"
            echo "### $subsection_title" >> "$tmp_file"
            echo "$message_line" >> "$tmp_file"
        else
            echo "$message_line" >> "$tmp_file"
        fi
    fi

    mv "$tmp_file" "$file"
}

process_payload_element() {
    local item="$1"
    
    local PARENT_COMMIT
    PARENT_COMMIT=$(echo "$item" | jq -r '.commit_id // ""')
    local AFFECTED_PROJECTS
    AFFECTED_PROJECTS=$(echo "$item" | jq -r '.affected_projects // [] | .[]')

    for key in "${CONFIG_KEYS[@]}"; do
        declare -n token_config="$key"
        if [ ${#token_config[@]} -lt 2 ]; then continue; fi

        local JSON_PROPERTY="${key}"  
        local SECTION_NAME="${token_config[1]}"   
        
        local ENTRY_PREFIX=""
        case "$key" in
            "releaseFeatureTokenId")  ENTRY_PREFIX="Feature: " ;;
            "releaseBreakingTokenId") ENTRY_PREFIX="Breaking: " ;;
            "releaseFixTokenId")      ENTRY_PREFIX="Fix: " ;;
            "releaseNoteTokenId")     ENTRY_PREFIX="Note: " ;;
        esac

        local TOKENS_STREAM
        TOKENS_STREAM=$(echo "$item" | jq -c ".${JSON_PROPERTY} // [] | .[]" 2>/dev/null || echo "")

        if [ -n "$TOKENS_STREAM" ]; then
            while read -r token || [[ -n "$token" ]]; do
                if [ -z "$token" ] || [ "$token" == "null" ]; then continue; fi

                local MESSAGE=""
                local COMMIT_ID=""

                if echo "$token" | jq -e '.message' &>/dev/null; then
                    MESSAGE=$(echo "$token" | jq -r '.message // ""')
                    COMMIT_ID=$(echo "$token" | jq -r '.commit_id // ""')
                else
                    MESSAGE=$(echo "$token" | jq -r '.')
                    COMMIT_ID="$PARENT_COMMIT"
                fi

                if [ -z "$MESSAGE" ] || [ "$MESSAGE" == "null" ]; then continue; fi
                MESSAGE=$(echo "$MESSAGE" | xargs)

                local RENDERED_ENTRY
                if [ "$LINK_COMMITS" = true ] && [ -n "$COMMIT_ID" ]; then
                    local SHORT_SHA="${COMMIT_ID:0:7}"
                    local MD_LINK="[$SHORT_SHA]($GIT_BASE_URL/commit/$COMMIT_ID)"
                    RENDERED_ENTRY="- ${ENTRY_PREFIX}${MESSAGE} (${MD_LINK})"
                else
                    RENDERED_ENTRY="- ${ENTRY_PREFIX}${MESSAGE}"
                fi

                echo "[DEBUG] Dynamic Routing Execution: [Prefix: $ENTRY_PREFIX] under Target Section Heading: [## $SECTION_NAME]" >&2

                if [ -n "$ONLY_PROJECT" ]; then
                    local TARGET_FILE="$OUTPUT_DIR/${PROJECT_NAME}.md"
                    append_to_markdown "$TARGET_FILE" "$SECTION_NAME" "" "$RENDERED_ENTRY"
                    continue
                fi

                if [ "$AUTO_SPLIT_PROJECT" = true ]; then
                    local VALID_AFFECTED=0
                    for proj in $AFFECTED_PROJECTS; do
                        if [ -n "$proj" ]; then
                            VALID_AFFECTED=$((VALID_AFFECTED + 1))
                        fi
                    done

                    if [ "$VALID_AFFECTED" -gt 0 ]; then
                        for proj in $AFFECTED_PROJECTS; do
                            if [ -z "$proj" ]; then continue; fi
                            local MAIN_FILE="$OUTPUT_DIR/$globalChangelogName"
                            local AFFECTED_PROJECT_FILE="${proj##*/}"
                            local AFFECTED_PROJECT_NAME="${AFFECTED_PROJECT_FILE%.*}"
                            local PROJ_FILE="$OUTPUT_DIR/${AFFECTED_PROJECT_NAME}.md"
                            
                            append_to_markdown "$MAIN_FILE" "$SECTION_NAME" "$AFFECTED_PROJECT_NAME" "$RENDERED_ENTRY"
                            append_to_markdown "$PROJ_FILE" "$SECTION_NAME" "" "$RENDERED_ENTRY"
                        done
                    else
                        local MAIN_FILE="$OUTPUT_DIR/$globalChangelogName"
                        append_to_markdown "$MAIN_FILE" "$SECTION_NAME" "" "$RENDERED_ENTRY"
                    fi
                else
                    local MAIN_FILE="$OUTPUT_DIR/$globalChangelogName"
                    append_to_markdown "$MAIN_FILE" "$SECTION_NAME" "" "$RENDERED_ENTRY"
                fi
            done <<< "$TOKENS_STREAM"
        fi
    done
}

remove_empty_markdown_sections() {
    local file="$1"
    local tmp_file
    local clean_file
    tmp_file=$(mktemp)
    clean_file=$(mktemp)

    awk '
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (lines[i] !~ /^#{2,6}[[:space:]]/) {
                    print lines[i]
                    continue
                }

                match(lines[i], /^#+/)
                level = RLENGTH
                has_content = 0
                for (j = i + 1; j <= NR; j++) {
                    if (lines[j] ~ /^#{2,6}[[:space:]]/) {
                        match(lines[j], /^#+/)
                        if (RLENGTH <= level) break
                    } else if (lines[j] ~ /[^[:space:]]/) {
                        has_content = 1
                        break
                    }
                }
                if (has_content) print lines[i]
            }
        }
    ' "$file" > "$tmp_file"

    awk '
        NF {
            if (seen && blank) print ""
            print
            seen = 1
            blank = 0
            next
        }
        seen { blank = 1 }
    ' "$tmp_file" > "$clean_file"

    mv "$clean_file" "$file"
    rm -f "$tmp_file"
}

echo "[INFO] Parsing payload blocks inside JSON array wrapper..." >&2

ARRAY_STREAM=$(echo "$JSON_DATA" | jq -c '.[]' 2>/dev/null || echo "")
if [ -n "$ARRAY_STREAM" ]; then
    while read -r item || [[ -n "$item" ]]; do
        process_payload_element "$item"
    done <<< "$ARRAY_STREAM"
fi

while IFS= read -r -d '' markdown_file; do
    remove_empty_markdown_sections "$markdown_file"
done < <(find "$OUTPUT_DIR" -type f -iname '*.md' -print0)

echo "[INFO] Output directory listing:" >&2
ls -la "$OUTPUT_DIR" >&2

echo "[SUCCESS] Processing cycle complete. All markdown outputs written safely." >&2
echo -e "\n[INFO] Current output directory listing:" >&2
for markdown_file in "$OUTPUT_DIR"/*.md; do
    echo "[FILE] $markdown_file" >&2
    [ -f "$markdown_file" ] || continue
    cat "$markdown_file"
    # rm "$markdown_file"
done
