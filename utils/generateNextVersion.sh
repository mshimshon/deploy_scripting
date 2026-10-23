#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.sh"
if [[ -f "$CONFIG_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$CONFIG_FILE"
fi

debug() {
		printf '[debug] %s\n' "$*" >&2

}

SCRIPT_PATH="${SCRIPT_PATH:-$SCRIPT_DIR}"
repo_url="$(git config --get remote.origin.url || true)"
if [[ -n "$repo_url" ]]; then
	printf 'Repository URL: %s\n' "$repo_url" >&2
fi
masterBranch="${masterBranch:-master}"
debug "Tracking branch: $masterBranch"
if ! git rev-parse --verify --quiet "${masterBranch}^{commit}" >/dev/null; then
	printf 'Error: tracking branch does not exist: %s\n' "$masterBranch" >&2
	exit 1
fi

# Keep the original tag for the since-tag query while sorting by its numeric version.
mapfile -t merged_tags < <(git tag --merged "$masterBranch")
if (( ${#merged_tags[@]} > 0 )); then
	for tag in "${merged_tags[@]}"; do
		debug "Tag on branch $masterBranch: $tag"
	done
else
	debug "No tags found on branch $masterBranch"
fi

latest_tag=""
while IFS= read -r tag; do
	if [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)([-+][0-9A-Za-z.-]+)?$ ]]; then
		latest_tag="$tag"
	fi
done < <(
	git tag --merged "$masterBranch" |
		grep -E '^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' |
		sort -V || true
)
debug "Latest merged version tag: ${latest_tag:-<none>}"

if [[ -n "$latest_tag" ]]; then
	version="${latest_tag#v}"
	version="${version%%[-+]*}"
	IFS=. read -r MAJOR MINOR PATCH <<< "$version"
else
	version="${initialVersion#v}"
	version="${version%%[-+]*}"
	IFS=. read -r MAJOR MINOR PATCH <<< "$version"
fi

PATCH=$((PATCH + 1))
debug "Starting version after default patch increment: $MAJOR.$MINOR.$PATCH"

token_output="$("$SCRIPT_PATH/gitGetTrackTokenList.sh" -since-tag "$latest_tag")"
# The helper returns a JSON array; discard any status text surrounding that array.
token_json="$token_output"
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$token_json"; then
	# Extract the JSON array even if helper status text shares its line or output.
	array_json="$(printf '%s\n' "$token_output" | awk '
		BEGIN { started = 0; depth = 0; in_string = 0; escaped = 0 }
		{
			for (i = 1; i <= length($0); i++) {
				c = substr($0, i, 1)
				if (!started) {
					if (c != "[") continue
					started = 1
				}
				printf "%s", c
				if (in_string) {
					if (escaped) escaped = 0
					else if (c == "\\") escaped = 1
					else if (c == "\"") in_string = 0
				} else if (c == "\"") in_string = 1
				else if (c == "[") depth++
				else if (c == "]") {
					depth--
					if (depth == 0) exit
				}
			}
			if (started) printf "\n"
		}'
	)"
	if [[ -n "$array_json" ]]; then
		token_json="$array_json"
	fi
fi
if ! jq -e 'type == "array"' >/dev/null <<< "$token_json"; then
	printf 'Error: gitGetTrackTokenList.sh did not return a valid JSON array\n' >&2
	exit 1
fi
debug "Retrieved token list since tag: ${latest_tag:-<none>}"

# Count every ID in every returned entry, including token groups not used for bumping.
releaseFeatureTokenIdCount="$(jq '[.[]? | select(type == "object") | (.releaseFeatureTokenId // [])[]?] | length' <<< "$token_json")"
releaseFixTokenIdCount="$(jq '[.[]? | select(type == "object") | (.releaseFixTokenId // [])[]?] | length' <<< "$token_json")"
releaseBreakingTokenIdCount="$(jq '[.[]? | select(type == "object") | (.releaseBreakingTokenId // [])[]?] | length' <<< "$token_json")"
releaseNoteTokenIdCount="$(jq '[.[]? | select(type == "object") | (.releaseNoteTokenId // [])[]?] | length' <<< "$token_json")"
releaseWipTokenIdCount="$(jq '[.[]? | select(type == "object") | (.releaseWipTokenId // [])[]?] | length' <<< "$token_json")"
releaseTraceTokenIdCount="$(jq '[.[]? | select(type == "object") | (.releaseTraceTokenId // [])[]?] | length' <<< "$token_json")"
debug "Token counts: breaking=$releaseBreakingTokenIdCount feature=$releaseFeatureTokenIdCount fix=$releaseFixTokenIdCount note=$releaseNoteTokenIdCount wip=$releaseWipTokenIdCount trace=$releaseTraceTokenIdCount"

if (( releaseBreakingTokenIdCount > 0 )); then
	MAJOR=$((MAJOR + 1))
	debug "Applied breaking-change bump; version is now $MAJOR.$MINOR.$PATCH"
fi
if (( releaseFeatureTokenIdCount > 0 )); then
	MINOR=$((MINOR + 1))
	debug "Applied feature bump; version is now $MAJOR.$MINOR.$PATCH"
fi
if (( releaseFixTokenIdCount > 0 )); then
	PATCH=$((PATCH + 1))
	debug "Applied fix bump; version is now $MAJOR.$MINOR.$PATCH"
fi

debug "Final version: v$MAJOR.$MINOR.$PATCH"
printf '%d.%d.%d\n' "$MAJOR" "$MINOR" "$PATCH"