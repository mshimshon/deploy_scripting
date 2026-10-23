using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

internal static class Program
{
	private static bool DebugMode;
	private static bool KeepDuplicate;
	private static bool KeepLogTrace;

	private static string MasterBranch = "origin/main";
	private static string[] ReleaseFeatureTokens = { "feat", "feature" };
	private static string[] ReleaseFixTokens = { "fix", "patch", "bugfix" };
	private static string[] ReleaseBreakingTokens = { "feat!", "break", "breaking" };
	private static string[] ReleaseNoteTokens = { "note" };
	private static string[] ReleaseDirtyTokens = { "wip", "work" };
	private static string[] ReleaseNoTriggerTokens = { "trace!", "action!" };
	private static string[] ReleaseNoLogTokens = { "trace", "action" };
	private static string ReleaseLeftSymbol = "";
	private static string ReleaseRightSymbol = ":";
	private static string[] ReleaseIndicator = Array.Empty<string>();

	private static int Main(string[] args)
	{
		DebugMode = HasSwitch(args, "Debug");
		KeepDuplicate = HasSwitch(args, "keepDuplicate");
		KeepLogTrace = HasSwitch(args, "keepLogTrace");

		WriteDebugInfo("Debug mode enabled; the final reset and recommit will be skipped.");
		ReleaseIndicator = ReleaseFeatureTokens.Concat(ReleaseFixTokens)
			.Concat(ReleaseBreakingTokens).Concat(ReleaseNoteTokens)
			.Concat(ReleaseNoTriggerTokens).ToArray();

		LoadConfiguration("./.github/config/deploy_utils.json");

		try
		{
			WriteDebugInfo("Fetching remote updates.");
			RunGit("fetch", "--quiet");

			string branchName = RunGit("symbolic-ref", "--quiet", "--short", "HEAD", allowFailure: true).Trim();
			if (branchName.Length == 0) throw new InvalidOperationException("Detached HEAD; refusing to rewrite history.");
			WriteDebugInfo($"Current branch: {branchName}.");

			string status = RunGit("status", "--porcelain");
			string[] statusEntries = SplitLines(status).Where(line => line.Length > 0).ToArray();
			WriteDebugInfo($"Working tree status entry count: {statusEntries.Length}.");
			if (statusEntries.Length > 0) throw new InvalidOperationException("Working tree is not clean; refusing to rewrite history.");

			WriteDebugInfo($"Checking whether HEAD descends from {MasterBranch}.");
			RunGit("merge-base", "--is-ancestor", MasterBranch, "HEAD");

			string[] hashes = SplitLines(RunGit("rev-list", "--reverse", MasterBranch + "..HEAD"))
				.Where(line => line.Length > 0).ToArray();
			WriteDebugInfo($"Found {hashes.Length} commit(s) since {MasterBranch}: {string.Join(", ", hashes)}.");
			if (hashes.Length == 0)
			{
				WriteDebugInfo("Nothing to process.");
				return 0;
			}

			var commits = new List<CommitInfo>();
			foreach (string hash in hashes)
			{
				WriteDebugInfo($"Reading commit {hash}.");
				string message = RunGit("show", "-s", "--format=%B", hash);
				bool hasIndicator = TestConfiguredToken(message, ReleaseIndicator);
				bool isDirty = TestConfiguredToken(message, ReleaseDirtyTokens) || !hasIndicator;
				string[] tokenMessages = GetTokenMessagePairs(message,
					ReleaseIndicator.Concat(ReleaseDirtyTokens).Concat(ReleaseNoLogTokens).ToArray(),
					dirtyFirst: hash == hashes[hashes.Length - 1]);

				if (!KeepLogTrace)
				{
					tokenMessages = tokenMessages.Where(part =>
					{
						string firstLine = SplitLines(part).FirstOrDefault() ?? "";
						return !TestConfiguredToken(firstLine,
							ReleaseNoLogTokens.Concat(ReleaseNoTriggerTokens).ToArray(), atStart: true);
					}).ToArray();
				}

				if (hash != hashes[hashes.Length - 1])
					tokenMessages = tokenMessages.Where(part => !TestConfiguredToken(part, ReleaseDirtyTokens)).ToArray();

				WriteDebugInfo($"Commit {hash} classification: indicator={hasIndicator}, dirty={isDirty}. Message:\n{message}");
				commits.Add(new CommitInfo(hash, string.Join("\n", tokenMessages), hasIndicator, isDirty));
			}

			int firstDirty = commits.FindIndex(commit => commit.IsDirty);
			if (firstDirty < 0)
			{
				WriteDebugInfo("No dirty or unclassified commits found; no rewrite is needed.");
				return 0;
			}
			WriteDebugInfo($"First dirty/unclassified commit is {commits[firstDirty].Hash} at index {firstDirty}.");

			List<CommitInfo> selected = commits.Skip(firstDirty).Where(commit => commit.HasIndicator).ToList();
			WriteDebugInfo($"Selected {selected.Count} indicator-bearing commit(s) for the replacement message.");
			if (selected.Count == 0) throw new InvalidOperationException("No release-indicator messages found; refusing to create an empty commit.");

			string oldestHash = commits[firstDirty].Hash;
			string parent = RunGit("rev-parse", new[] { oldestHash + "^" }, allowFailure: true).Trim();
			if (parent.Length == 0) throw new InvalidOperationException($"Cannot rewrite from root commit {oldestHash}.");
			WriteDebugInfo($"Rewrite starts at {oldestHash}; replacement parent is {parent}.");

			CommitInfo headCommit = commits[commits.Count - 1];
			bool headHasDirtyToken = TestConfiguredToken(headCommit.Message, ReleaseDirtyTokens);
			WriteDebugInfo($"HEAD commit {headCommit.Hash} has a dirty token: {headHasDirtyToken}.");
			var messageParts = new List<string>();
			if (headHasDirtyToken) messageParts.Add(headCommit.Message.TrimEnd('\r', '\n'));

			string[][] priorityTokens = { ReleaseBreakingTokens, ReleaseFeatureTokens, ReleaseFixTokens, ReleaseNoteTokens };
			var priorityGroups = Enumerable.Range(0, 5).Select(_ => new List<CommitInfo>()).ToArray();
			foreach (CommitInfo commit in selected)
			{
				if (headHasDirtyToken && commit.Hash == headCommit.Hash) continue;
				int priority = 4;
				for (int i = 0; i < priorityTokens.Length; i++)
				{
					if (!TestConfiguredToken(commit.Message, priorityTokens[i])) continue;
					priority = i;
					break;
				}
				priorityGroups[priority].Add(commit);
			}
			foreach (List<CommitInfo> group in priorityGroups)
				messageParts.AddRange(group.Select(commit => commit.Message.TrimEnd('\r', '\n')));

			string tempFile = Path.Combine(Path.GetTempPath(), oldestHash);
			IEnumerable<string> cleanMessageParts = messageParts.Select(part => string.Join("\n",
				SplitLines(part).Select(line => line.Trim()).Where(line => !string.IsNullOrWhiteSpace(line))));
			if (!KeepDuplicate)
			{
				var seenParts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
				cleanMessageParts = cleanMessageParts.Select(part =>
				{
					var uniqueLines = new List<string>();
					foreach (string line in SplitLines(part))
					{
						if (string.IsNullOrWhiteSpace(line)) continue;
						string normalizedLine = Regex.Replace(line, @"\s+", "");
						if (seenParts.Add(normalizedLine)) uniqueLines.Add(line);
					}
					return string.Join("\n", uniqueLines);
				}).Where(part => !string.IsNullOrWhiteSpace(part));
			}

			string newMessage = string.Join("\n", SplitLines(string.Join("\n", cleanMessageParts))
				.Where(line => !string.IsNullOrWhiteSpace(line))) + "\n";
			WriteDebugInfo($"Generated replacement commit message:\n{newMessage}");
			File.WriteAllText(tempFile, newMessage, new UTF8Encoding(false));
			WriteDebugInfo($"Wrote replacement message to {tempFile}.");

			Console.WriteLine("=== Commit message preview ===");
			Console.Write(newMessage);
			Console.WriteLine("============================");

			if (DebugMode)
			{
				WriteDebugInfo("Debug dry run complete; removing temporary message file and skipping git reset and git commit.");
				File.Delete(tempFile);
				return 0;
			}

			WriteDebugInfo($"Performing soft reset to {parent}.");
			try { RunGit("reset", "--soft", parent); }
			catch { throw new InvalidOperationException($"Soft reset failed; message file retained at {tempFile}."); }

			WriteDebugInfo($"Creating replacement commit from {tempFile}.");
			try { RunGit("commit", "-F", tempFile); }
			catch { throw new InvalidOperationException($"Commit failed; staged changes and message file retained at {tempFile}."); }

			File.Delete(tempFile);
			WriteDebugInfo("Replacement commit completed; temporary file removed.");
			return 0;
		}
		catch (Exception ex)
		{
			WriteDebugInfo($"Execution stopped with error: {ex.Message}");
			Console.Error.WriteLine(ex.Message);
			return 1;
		}
	}

	private static void LoadConfiguration(string deployConfigFile)
	{
		if (!File.Exists(deployConfigFile))
		{
			WriteDebugInfo($"No configuration file found at {deployConfigFile}; using defaults.");
			return;
		}

		try
		{
			WriteDebugInfo($"Loading configuration from {deployConfigFile}.");
			using JsonDocument document = JsonDocument.Parse(File.ReadAllText(deployConfigFile));
			JsonElement root = document.RootElement;
			var scalarKeys = new HashSet<string>(new[] { "initialVersion", "masterBranch", "globalChangelogName", "releaseLeftSymbol", "releaseRightSymbol" }, StringComparer.Ordinal);
			var arrayKeys = new HashSet<string>(new[] {
				"projectIdDetected", "releaseFeatureTokenId", "releaseBreakingTokenId", "releaseFixTokenId", "releaseNoteTokenId",
				"releaseWipTokenId", "releaseTraceTokenId", "releaseFeatureTokens", "releaseFixTokens", "releaseBreakingTokens",
				"releaseNoteTokens", "releaseDirtyTokens", "releaseNoTriggerTokens", "releaseNoLogTokens", "releaseIndicator"
			}, StringComparer.Ordinal);
			bool valid = root.ValueKind == JsonValueKind.Object;

			if (valid)
			{
				foreach (JsonProperty property in root.EnumerateObject())
				{
					WriteDebugInfo($"Validating configuration key '{property.Name}'.");
					if (!scalarKeys.Contains(property.Name) && !arrayKeys.Contains(property.Name)) { valid = false; break; }
					if (scalarKeys.Contains(property.Name) && property.Value.ValueKind != JsonValueKind.String) { valid = false; break; }
					if (arrayKeys.Contains(property.Name))
					{
						if (property.Value.ValueKind != JsonValueKind.Array || property.Value.EnumerateArray().Any(item => item.ValueKind != JsonValueKind.String))
						{ valid = false; break; }
					}
				}
			}

			if (!valid)
			{
				WriteDebugInfo("Configuration validation failed; retaining defaults.");
				Console.Error.WriteLine($"ERROR: Invalid configuration in {deployConfigFile}; retaining defaults.");
				return;
			}

			WriteDebugInfo("Configuration is valid; applying configured values.");
			foreach (JsonProperty property in root.EnumerateObject())
			{
				WriteDebugInfo($"Applying configuration key '{property.Name}'.");
				switch (property.Name)
				{
					case "masterBranch": MasterBranch = property.Value.GetString()!; break;
					case "releaseLeftSymbol": ReleaseLeftSymbol = property.Value.GetString()!; break;
					case "releaseRightSymbol": ReleaseRightSymbol = property.Value.GetString()!; break;
					case "releaseFeatureTokens": ReleaseFeatureTokens = ReadStringArray(property.Value); break;
					case "releaseFixTokens": ReleaseFixTokens = ReadStringArray(property.Value); break;
					case "releaseBreakingTokens": ReleaseBreakingTokens = ReadStringArray(property.Value); break;
					case "releaseNoteTokens": ReleaseNoteTokens = ReadStringArray(property.Value); break;
					case "releaseDirtyTokens": ReleaseDirtyTokens = ReadStringArray(property.Value); break;
					case "releaseNoTriggerTokens": ReleaseNoTriggerTokens = ReadStringArray(property.Value); break;
					case "releaseNoLogTokens": ReleaseNoLogTokens = ReadStringArray(property.Value); break;
					case "releaseIndicator": ReleaseIndicator = ReadStringArray(property.Value); break;
				}
			}
		}
		catch (Exception ex)
		{
			WriteDebugInfo($"Configuration load failed: {ex.Message}");
			Console.Error.WriteLine($"ERROR: Could not read or parse {deployConfigFile}; retaining defaults.");
		}
	}

	private static string[] ReadStringArray(JsonElement value) => value.EnumerateArray().Select(item => item.GetString()!).ToArray();

	private static string[] GetTokenMessagePairs(string text, string[] tokens, bool dirtyFirst)
	{
		var pairs = new List<string>();
		var currentLines = new List<string>();
		bool recognizedToken = false;
		string alternation = string.Join("|", tokens.OrderByDescending(token => token.Length).Select(Regex.Escape));
		string prefix = string.IsNullOrEmpty(ReleaseLeftSymbol) ? "" : Regex.Escape(ReleaseLeftSymbol) + @"\s*";
		string suffix = string.IsNullOrEmpty(ReleaseRightSymbol) ? "" : @"\s*" + Regex.Escape(ReleaseRightSymbol);
		string tokenPattern = @"(?<![\w])" + prefix + "(?<token>(?:" + alternation + @"))(?![\w])" + suffix;

		foreach (string line in SplitLines(text))
		{
			MatchCollection matches = Regex.Matches(line, tokenPattern, RegexOptions.IgnoreCase);
			if (matches.Count > 0)
			{
				for (int i = 0; i < matches.Count; i++)
				{
					if (currentLines.Count > 0) pairs.Add(string.Join("\n", currentLines).TrimEnd());
					recognizedToken = true;
					int end = i + 1 < matches.Count ? matches[i + 1].Index : line.Length;
					currentLines = new List<string> { line.Substring(matches[i].Index, end - matches[i].Index).Trim() };
				}
			}
			else if (currentLines.Count > 0 && !string.IsNullOrWhiteSpace(line))
			{
				currentLines.Add(line.TrimEnd());
			}
		}
		if (currentLines.Count > 0) pairs.Add(string.Join("\n", currentLines).TrimEnd());

		if (!recognizedToken)
		{
			string dirtyToken = ReleaseDirtyTokens.Length > 0 ? ReleaseDirtyTokens[0] : "";
			string separator = string.IsNullOrEmpty(ReleaseRightSymbol) ? " " : ReleaseRightSymbol + " ";
			pairs = new List<string> { dirtyToken + separator + text.Trim() };
		}
		if (dirtyFirst)
		{
			string[] dirtyPairs = pairs.Where(pair => TestConfiguredToken(pair, ReleaseDirtyTokens)).ToArray();
			string[] otherPairs = pairs.Where(pair => !TestConfiguredToken(pair, ReleaseDirtyTokens)).ToArray();
			pairs = dirtyPairs.Concat(otherPairs).ToList();
		}
		return pairs.ToArray();
	}

	private static bool TestConfiguredToken(string text, string[] tokens, bool atStart = false)
	{
		foreach (string token in tokens)
		{
			string pattern = Regex.Escape(token);
			if (!string.IsNullOrEmpty(ReleaseLeftSymbol)) pattern = Regex.Escape(ReleaseLeftSymbol) + @"\s*" + pattern;
			if (atStart) pattern = @"^\s*" + pattern;
			if (!string.IsNullOrEmpty(ReleaseRightSymbol)) pattern += @"\s*" + Regex.Escape(ReleaseRightSymbol);
			if (Regex.IsMatch(text, pattern, RegexOptions.IgnoreCase)) return true;
		}
		return false;
	}

	private static string RunGit(string command, params string[] arguments) => RunGit(command, arguments, false);

	private static string RunGit(string command, string arg1, string arg2, string arg3, bool allowFailure = false) =>
		RunGit(command, new[] { arg1, arg2, arg3 }, allowFailure);

	private static string RunGit(string command, string arg1, string arg2, string arg3, string arg4, bool allowFailure = false) =>
		RunGit(command, new[] { arg1, arg2, arg3, arg4 }, allowFailure);

	private static string RunGit(string command, string arg1, string arg2, string arg3, string arg4, string arg5, bool allowFailure = false) =>
		RunGit(command, new[] { arg1, arg2, arg3, arg4, arg5 }, allowFailure);

	private static string RunGit(string command, string[] arguments, bool allowFailure)
	{
		var start = new ProcessStartInfo("git") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
		start.ArgumentList.Add(command);
		foreach (string argument in arguments) start.ArgumentList.Add(argument);
		using Process process = Process.Start(start) ?? throw new InvalidOperationException("Could not start git.");
		string output = process.StandardOutput.ReadToEnd();
		string error = process.StandardError.ReadToEnd();
		process.WaitForExit();
		if (process.ExitCode != 0 && !allowFailure)
			throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? $"git {command} failed." : error.Trim());
		return output;
	}

	private static string[] SplitLines(string text) => Regex.Split(text, @"\r?\n");

	private static bool HasSwitch(string[] args, string name) =>
		args.Any(arg => arg.Equals("-" + name, StringComparison.OrdinalIgnoreCase) ||
						arg.Equals("--" + name, StringComparison.OrdinalIgnoreCase) ||
						arg.Equals("/" + name, StringComparison.OrdinalIgnoreCase));

	private static void WriteDebugInfo(string message)
	{
		if (DebugMode) Console.WriteLine("[DEBUG] " + message);
	}

	private sealed class CommitInfo
	{
		public string Hash { get; }
		public string Message { get; }
		public bool HasIndicator { get; }
		public bool IsDirty { get; }

		public CommitInfo(string hash, string message, bool hasIndicator, bool isDirty)
		{
			Hash = hash;
			Message = message;
			HasIndicator = hasIndicator;
			IsDirty = isDirty;
		}
	}
}
