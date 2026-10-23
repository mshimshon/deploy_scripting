param([switch]$Debug, [switch]$keepDuplicate, [switch]$keepLogTrace)

function Write-DebugInfo {
    param([string]$Message)
    if ($Debug) { Write-Host "[DEBUG] $Message" }
}

Write-DebugInfo "Debug mode enabled; the final reset and recommit will be skipped."
$masterBranch = "origin/main"
# Core feature delivery tokens. Triggers standard minor semantic version increases.
$releaseFeatureTokens = @("feat", "feature")
# Defect remediation tokens. Triggers standard patch semantic version increases.
$releaseFixTokens = @("fix", "patch", "bugfix")
# Breaking change tokens. Forces a major version increment across delivery targets.
$releaseBreakingTokens = @("feat!", "break", "breaking")
# Supplementary release annotations. Captures critical operational notices 
# or manual intervention documentation required during the deployment phase.
$releaseNoteTokens = @("note") 
# Work-In-Progress (WIP) definitions. Coupled with local pre-push hooks 
# to enforce history cleaning and force squashes prior to main/master integration.
# Commits carrying these designations are strictly blocked from protected branches.
# Does not trigger workflow on push
$releaseDirtyTokens = @("wip", "work") 
# Workflow bypass tokens. Utilized for non-functional modifications (e.g., updates 
# to documentation or assets) to prevent redundant pipeline executions.
# Does not trigger workflow on push
$releaseNoTriggerTokens = @("trace!", "action!") 
# Change-log omission filters. Triggers full pipeline evaluations to ensure 
# structural hotfixes run, but completely suppresses entries in release logs.
$releaseNoLogTokens = @("trace", "action") 
# Structural Commit Syntax Delimiters or Wrappers. These symbols are used to encapsulate the core commit message.
$releaseLeftSymbol = ""
$releaseRightSymbol = ":"
$releaseIndicator = $releaseFeatureTokens + $releaseFixTokens + $releaseBreakingTokens + $releaseNoteTokens + $releaseNoTriggerTokens

# Optional custom configuration. Missing keys retain their defaults above.
$deployConfigFile = "./.github/config/deploy_utils.json"
$releaseIndicator = $releaseFeatureTokens + $releaseFixTokens + $releaseBreakingTokens + $releaseNoteTokens + $releaseNoTriggerTokens

# Optional custom configuration. Missing keys retain their defaults above.
$deployConfigFile = "./.github/config/deploy_utils.json"

if (Test-Path -Path $deployConfigFile -PathType Leaf) {
    try {
        Write-DebugInfo "Loading configuration from $deployConfigFile."
        # Read file and safely parse the JSON natively without external 'jq'
        $jsonContent = Get-Content -Raw -Path $deployConfigFile | ConvertFrom-Json -ErrorAction Stop
        
        # Define allowed keys and type requirements for explicit schema validation
        $scalarKeys = @("initialVersion", "masterBranch", "globalChangelogName", "releaseLeftSymbol", "releaseRightSymbol")
        $arrayKeys = @("projectIdDetected", "releaseFeatureTokenId", "releaseBreakingTokenId", "releaseFixTokenId", "releaseNoteTokenId", "releaseWipTokenId", "releaseTraceTokenId", "releaseFeatureTokens", "releaseFixTokens", "releaseBreakingTokens", "releaseNoteTokens", "releaseDirtyTokens", "releaseNoTriggerTokens", "releaseNoLogTokens", "releaseIndicator")
        $allowedKeys = $scalarKeys + $arrayKeys

        $isValid = $true

        # 1. Validate that no unexpected keys exist
        foreach ($property in $jsonContent.PSObject.Properties) {
            Write-DebugInfo "Validating configuration key '$($property.Name)'."
            if ($property.Name -notIn $allowedKeys) {
                Write-DebugInfo "Unexpected configuration key '$($property.Name)'."
                $isValid = $false
                break
            }
            
            # 2. Validate scalar strings
            if ($property.Name -in $scalarKeys -and $property.Value -isnot [string]) {
                $isValid = $false
                break
            }

            # 3. Validate arrays of strings
            if ($property.Name -in $arrayKeys) {
                if ($property.Value -isnot [array]) {
                    $isValid = $false
                    break
                }
                foreach ($item in $property.Value) {
                    if ($item -isnot [string]) {
                        $isValid = $false
                        break
                    }
                }
            }
        }

        if (-not $isValid) {
            Write-DebugInfo "Configuration validation failed; retaining defaults."
            Write-Error "ERROR: Invalid configuration in $deployConfigFile; retaining defaults."
        } else {
            Write-DebugInfo "Configuration is valid; applying configured values."
            # 4. Map JSON properties safely back onto existing scope variables
            foreach ($property in $jsonContent.PSObject.Properties) {
                Write-DebugInfo "Applying configuration key '$($property.Name)'."
                if ($property.Value -is [array]) {
                    # Explicitly cast JSON arrays into standard PowerShell string arrays
                    Set-Variable -Name $property.Name -Value ([string[]]$property.Value)
                } else {
                    Set-Variable -Name $property.Name -Value $property.Value
                }
            }
        }
    }
    catch {
        Write-DebugInfo "Configuration load failed: $($_.Exception.Message)"
        Write-Error "ERROR: Could not read or parse $deployConfigFile; retaining defaults."
    }
} else {
    Write-DebugInfo "No configuration file found at $deployConfigFile; using defaults."
}


# Fetch before inspecting history. Refuse to rewrite if the local branch is behind
# or diverged from the configured upstream, or if the working tree is not clean.
try {
    Write-DebugInfo "Fetching remote updates."
    & git fetch --quiet
    if ($LASTEXITCODE -ne 0) { throw "git fetch failed; history was not changed." }

    $branchName = (& git symbolic-ref --quiet --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $branchName) { throw "Detached HEAD; refusing to rewrite history." }
    Write-DebugInfo "Current branch: $branchName."
    $status = @(& git status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect the working tree." }
    Write-DebugInfo "Working tree status entry count: $($status.Count)."
    if ($status.Count -gt 0) { throw "Working tree is not clean; refusing to rewrite history." }

    Write-DebugInfo "Checking whether HEAD descends from $masterBranch."
    & git merge-base --is-ancestor $masterBranch HEAD
    if ($LASTEXITCODE -ne 0) { throw "Local history is behind or diverged from $masterBranch; reconcile it before continuing." }

    $hashes = @(& git rev-list --reverse "$masterBranch..HEAD")
    if ($LASTEXITCODE -ne 0) { throw "Could not list commits since $masterBranch." }
    Write-DebugInfo "Found $($hashes.Count) commit(s) since ${masterBranch}: $($hashes -join ', ')."
    if ($hashes.Count -eq 0) { Write-DebugInfo "Nothing to process."; return }

    function Test-ConfiguredToken {
        param([string]$Text, [string[]]$Tokens, [switch]$AtStart)
        foreach ($token in $Tokens) {
            $pattern = [regex]::Escape($token)
            if (-not [string]::IsNullOrEmpty($releaseLeftSymbol)) {
                $pattern = [regex]::Escape($releaseLeftSymbol) + '\s*' + $pattern
            }
            if ($AtStart) {
                $pattern = '^\s*' + $pattern
            }
            if (-not [string]::IsNullOrEmpty($releaseRightSymbol)) {
                $pattern += '\s*' + [regex]::Escape($releaseRightSymbol)
            }
            if ([regex]::IsMatch($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                return $true
            }
        }
        return $false
    }

    function Get-TokenMessagePairs {
        param([string]$Text, [string[]]$Tokens, [switch]$DirtyFirst)

        $pairs = @()
        $currentLines = @()
        $recognizedToken = $false
        $tokenAlternation = ($Tokens | Sort-Object { $_.Length } -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $prefix = ''
        $suffix = ''
        if (-not [string]::IsNullOrEmpty($releaseLeftSymbol)) {
            $prefix = [regex]::Escape($releaseLeftSymbol) + '\s*'
        }
        if (-not [string]::IsNullOrEmpty($releaseRightSymbol)) {
            $suffix = '\s*' + [regex]::Escape($releaseRightSymbol)
        }
        $tokenPattern = '(?<![\w])' + $prefix + '(?<token>(?:' + $tokenAlternation + '))(?![\w])' + $suffix

        foreach ($line in ($Text -split "`r?`n")) {
            $matches = [regex]::Matches($line, $tokenPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($matches.Count -gt 0) {
                foreach ($match in $matches) {
                    if ($currentLines.Count -gt 0) { $pairs += ($currentLines -join "`n").TrimEnd() }
                    $recognizedToken = $true
                    $end = $line.Length
                    if ($match.NextMatch().Success) { $end = $match.NextMatch().Index }
                    $currentLines = @(($line.Substring($match.Index, $end - $match.Index)).Trim())
                }
            } elseif ($currentLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($line)) {
                $currentLines += $line.TrimEnd()
            }
        }
        if ($currentLines.Count -gt 0) { $pairs += ($currentLines -join "`n").TrimEnd() }

        if (-not $recognizedToken) {
            $dirtyToken = [string]$releaseDirtyTokens[0]
            $separator = if ([string]::IsNullOrEmpty($releaseRightSymbol)) { ' ' } else { $releaseRightSymbol + ' ' }
            $pairs = @($dirtyToken + $separator + $Text.Trim())
        }
        if ($DirtyFirst) {
            $dirtyPairs = @($pairs | Where-Object { Test-ConfiguredToken -Text $_ -Tokens ([string[]]$releaseDirtyTokens) })
            $otherPairs = @($pairs | Where-Object { -not (Test-ConfiguredToken -Text $_ -Tokens ([string[]]$releaseDirtyTokens)) })
            $pairs = @($dirtyPairs + $otherPairs)
        }
        return ,$pairs
    }

    $commits = @()
    foreach ($hash in $hashes) {
        Write-DebugInfo "Reading commit $hash."
        $message = (& git show -s --format=%B $hash | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "Could not read commit $hash." }
        $hasIndicator = Test-ConfiguredToken -Text $message -Tokens ([string[]]$releaseIndicator)
        $isDirty = (Test-ConfiguredToken -Text $message -Tokens ([string[]]$releaseDirtyTokens)) -or -not $hasIndicator
        $tokenMessages = Get-TokenMessagePairs -Text $message -Tokens ([string[]]($releaseIndicator + $releaseDirtyTokens + $releaseNoLogTokens)) -DirtyFirst:($hash -eq $hashes[-1])
        if (-not $keepLogTrace) {
            $tokenMessages = @($tokenMessages | Where-Object {
                $firstLine = ($_ -split "`r?`n", 2)[0]
                -not (Test-ConfiguredToken -Text $firstLine -Tokens ([string[]]($releaseNoLogTokens + $releaseNoTriggerTokens)) -AtStart)
            })
        }
        if ($hash -ne $hashes[-1]) {
            $tokenMessages = @($tokenMessages | Where-Object {
                -not (Test-ConfiguredToken -Text $_ -Tokens ([string[]]$releaseDirtyTokens))
            })
        }
        Write-DebugInfo "Commit $hash classification: indicator=$hasIndicator, dirty=$isDirty. Message:`n$message"
        $commits += [pscustomobject]@{ Hash = $hash; Message = ($tokenMessages -join "`n"); HasIndicator = $hasIndicator; IsDirty = $isDirty }
    }

    # Start at the oldest dirty/unclassified commit and retain the full messages
    # of all indicator-bearing commits from that point onward.
    $firstDirty = -1
    for ($i = 0; $i -lt $commits.Count; $i++) {
        if ($commits[$i].IsDirty) { $firstDirty = $i; break }
    }
    if ($firstDirty -lt 0) { Write-DebugInfo "No dirty or unclassified commits found; no rewrite is needed."; return }
    Write-DebugInfo "First dirty/unclassified commit is $($commits[$firstDirty].Hash) at index $firstDirty."

    $selected = @($commits[$firstDirty..($commits.Count - 1)] | Where-Object { $_.HasIndicator })
    Write-DebugInfo "Selected $($selected.Count) indicator-bearing commit(s) for the replacement message."
    if ($selected.Count -eq 0) { throw "No release-indicator messages found; refusing to create an empty commit." }

    $oldestHash = $commits[$firstDirty].Hash
    $parent = (& git rev-parse "$oldestHash^" 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $parent) { throw "Cannot rewrite from root commit $oldestHash." }
    Write-DebugInfo "Rewrite starts at $oldestHash; replacement parent is $parent."

    # Preserve all extracted token/message pairs from a dirty HEAD first.
    $headCommit = $commits[-1]
    $headHasDirtyToken = Test-ConfiguredToken -Text $headCommit.Message -Tokens ([string[]]$releaseDirtyTokens)
    Write-DebugInfo "HEAD commit $($headCommit.Hash) has a dirty token: $headHasDirtyToken."
    $messageParts = @()
    if ($headHasDirtyToken) {
        $messageParts += $headCommit.Message.TrimEnd("`r", "`n")
    }
    $priorityTokens = @(
        [string[]]$releaseBreakingTokens
        [string[]]$releaseFeatureTokens
        [string[]]$releaseFixTokens
        [string[]]$releaseNoteTokens
    )
    $priorityGroups = [System.Collections.Generic.List[System.Collections.Generic.List[object]]]::new()
    for ($i = 0; $i -lt 5; $i++) {
        $priorityGroups.Add([System.Collections.Generic.List[object]]::new())
    }
    foreach ($commit in $selected) {
        if ($headHasDirtyToken -and $commit.Hash -eq $headCommit.Hash) { continue }
        $priority = 4
        for ($i = 0; $i -lt $priorityTokens.Count; $i++) {
            if (Test-ConfiguredToken -Text $commit.Message -Tokens $priorityTokens[$i]) {
                $priority = $i
                break
            }
        }
        $priorityGroups[$priority].Add($commit)
    }
    foreach ($group in $priorityGroups) {
        $messageParts += @($group | ForEach-Object { $_.Message.TrimEnd("`r", "`n") })
    }

    # Remove empty lines from the assembled replacement commit message.
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) $oldestHash
    $cleanMessageParts = foreach ($part in $messageParts) {
        ($part -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    }
    if (-not $keepDuplicate) {
        $seenParts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $cleanMessageParts = @($cleanMessageParts | ForEach-Object {
            $uniqueLines = foreach ($line in ($_ -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $normalizedLine = $line -replace '\s+', ''
                    if ($seenParts.Add($normalizedLine)) { $line }
                }
            }
            ($uniqueLines -join "`n")
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $newMessage = (($cleanMessageParts -join "`n" -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n") + "`n"
    Write-DebugInfo "Generated replacement commit message:`n$newMessage"
    [System.IO.File]::WriteAllText($tempFile, $newMessage, [System.Text.UTF8Encoding]::new($false))
    Write-DebugInfo "Wrote replacement message to $tempFile."

    # Print the generated commit message to the console before creating the replacement commit.
    Write-Host "=== Commit message preview ==="
    Write-Host -NoNewline (Get-Content -LiteralPath $tempFile -Raw)
    Write-Host "============================"

    if ($Debug) {
        Write-DebugInfo "Debug dry run complete; removing temporary message file and skipping git reset and git commit."
        Remove-Item -LiteralPath $tempFile -Force
        return
    }

    Write-DebugInfo "Performing soft reset to $parent."
    & git reset --soft $parent
    if ($LASTEXITCODE -ne 0) { throw "Soft reset failed; message file retained at $tempFile." }
    Write-DebugInfo "Creating replacement commit from $tempFile."
    & git commit -F $tempFile
    if ($LASTEXITCODE -ne 0) { throw "Commit failed; staged changes and message file retained at $tempFile." }

    Remove-Item -LiteralPath $tempFile -Force
    Write-DebugInfo "Replacement commit completed; temporary file removed."
}
catch {
    Write-DebugInfo "Execution stopped with error: $($_.Exception.Message)"
    Write-Error $_
    exit 1
}
