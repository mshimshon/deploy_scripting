# Deploy scripting utilities

These utilities automate release preparation from Git commit history. They classify commit messages using configured release tokens, calculate the next semantic version, and produce Markdown changelog entries. They can be run locally or from GitHub Actions.

## Utilities

- `utils/generateNextVersion.sh` prints the next `MAJOR.MINOR.PATCH` version to standard output. Breaking-change, feature, and fix tokens determine the version increment.
- `utils/generateChangelogs.sh` generates changelog entries. It requires `-output <directory>` and also supports `-onlyProject <path>`, `-autoSplitProject`, `-autoFailEmptyResult`, and `-linkCommits`.
- `utils/gitGetCommitSince.sh` gathers commits and changed files since a local Git reference.
- `utils/gitGetTrackTokenList.sh` classifies commit messages with configured tokens and maps changes to detected projects.
- `prePushUtility.ps1` is a PowerShell helper for checking and consolidating commit messages before pushing.

## Changelog generation

Run `utils/generateChangelogs.sh -output <directory>` to create Markdown changelog files from classified commits. Each file starts with `# Changelog` and includes sections for configured feature, breaking-change, fix, and note headings. Entries are labeled `Feature:`, `Breaking:`, `Fix:`, or `Note:`. Use `-linkCommits` to include commit links; this requires a reachable `origin` remote.

For example, with matching configured headings, output can look like:

```markdown
# Changelog

## Features
- Feature: add export option

## Fixes
- Fix: handle empty input
```

By default, entries are written to the global changelog file named by `globalChangelogName`. With `-autoSplitProject`, entries associated with detected projects are added to each project's `<project-name>.md` file and grouped under the project name in the global changelog. Entries without a detected project remain only in the global file. Use `-onlyProject <path>` to filter to one project and write to that project's file instead of splitting output. Empty headings are removed after generation.

For a monorepo, treat the global changelog as the main release changelog: the main release is always produced. Project changelog files identify which subprojects had detected changes, so a build or release action can discover the affected project names from the generated files and decide which subprojects to release. Subprojects follow the same versioning rules as the main release, but their releases are optional and can be skipped when no relevant changes were detected. These scripts generate changelogs; the build or release action is responsible for making and applying that per-project release decision.

Each configured release category can have multiple token patterns or aliases. The classifier evaluates feature, breaking, fix, and note patterns independently; therefore, a commit matching multiple categories can appear in multiple changelog sections. Matching commits are accumulated under their corresponding headings. Configure token patterns and headings in `config.sh` or override supported settings in `.github/config/deploy_utils.json`.

The Bash scripts require Bash, Git, and `jq`, and run from a Git checkout. Configure the tracking branch, initial version, project extensions, release tokens, and changelog headings in `config.sh`. Supported values can also be overridden in `.github/config/deploy_utils.json`. Commit messages should follow the configured token conventions.

## Commit tokens

By default, `config.sh` uses `feat` and `feature` for minor releases, `fix`, `patch`, and `bugfix` for patch releases, and `feat!`, `break`, and `breaking` for major releases. These defaults can be overridden in `.github/config/deploy_utils.json`; check the active configuration before choosing a token. The configured right-hand delimiter is `:`, so the examples use forms such as `feat: ...` and `breaking: ...`.

The version outcomes below assume the current version is `1.4.2` and only the shown commit is being evaluated. Any commit that triggers the workflow results in at least a patch bump; a commit that suppresses the workflow does not cause a workflow version bump.

```text
git commit -m "breaking: remove legacy config support"
# Expected: breaking change; next version is 2.0.0 (major bump).

git commit -m "feat: add export option"
# Expected: feature; next version is 1.5.0 (minor bump).

git commit -m "fix: handle empty input"
# Expected: fix; next version is 1.4.3 (patch bump).

git commit -m "note: update migration guidance"
# Expected: release annotation; because the workflow runs, the version bumps at least to 1.4.3.

git commit -m "clarify setup instructions"
# Expected: treated as dirty/trash WIP; blocked from protected branches by the pre-push checks.

git commit -m "trace: adjust internal diagnostics"
# Expected: pipeline evaluation runs and the version bumps at least to 1.4.3, but this change is omitted from changelogs.

git commit -m "trace!: update generated metadata"
# Expected: if `trace!` is on the latest commit when the pre-push helper runs, it applies a `skipci` tag; otherwise, no tag is applied. With CI/CD configured to honor the tag, the action workflow is skipped, so there is no workflow version bump.

git commit -m "wip: draft deployment changes"
# Expected: configured dirty token; blocked from protected branches by the pre-push checks.
```

The other default tokens include `note` for release annotations, `action!` as a no-trigger token, `action` as a changelog-omission token, and `work` as a dirty/WIP token. Use the release-version tokens only when their category matches the change. In general, avoid using the configured delimiter in commit messages except to separate a configured token from its description; the default delimiter is `:`. Merely mentioning a token string in ordinary text does not make it a token. Before publishing, review the generated version and changelog to verify the classification.

To use tokens safely, match the category to the actual impact, spell the token exactly as configured, and keep the commit message clear and focused. Avoid using the configured delimiter (`:` by default) unless it is separating a configured token from its description. Before publishing, review the generated version and changelog to verify that the commits were classified as intended.

## Pre-push helper

`prePushUtility.ps1` checks and consolidates commit messages before they are pushed. It applies a `skipci` tag only when the latest commit contains the configured `trace!` no-trigger token at the time the helper runs; otherwise, it does not apply a tag. Configure the repository's CI/CD workflow to recognize the tag and skip the action; otherwise, the workflow may still run. Running the helper locally gives contributors an early opportunity to catch and fix issues, helping avoid unnecessary cleanup by GitHub Actions. This is a preventive check, not a replacement for the workflow: keep the action as a fallback and have it perform cleanup only when changes are merged.

Configure the repository's tracking branch, release tokens, and other supported settings in `config.sh` or `.github/config/deploy_utils.json`, and keep `prePushUtility.ps1` in the repository root. Run the helper manually from the root of the checkout with:

```powershell
.\prePushUtility.ps1
```

To activate it automatically before pushes, create `.git/hooks/pre-push` in your local clone with this Git Bash hook:

```sh
#!/bin/sh
repo_root="$(git rev-parse --show-toplevel)"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repo_root/prePushUtility.ps1"
```

In Git Bash, make the hook executable with `chmod +x .git/hooks/pre-push`. Git runs it before each push; a nonzero exit from the helper blocks the push, allowing you to address any issues first. Hooks are local to each clone and are not shared automatically, so each contributor must install the hook in their own checkout.

