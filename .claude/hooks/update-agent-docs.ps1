# PostToolUse hook — regenerate doc files when any .claude/agents/*.md is changed.
# Claude Code passes tool call info as JSON on stdin.

$rawInput = [Console]::In.ReadToEnd()

try {
    $data = $rawInput | ConvertFrom-Json -ErrorAction Stop
} catch {
    exit 0
}

$filePath = $data.tool_input.file_path
if (-not $filePath) { exit 0 }

# Normalize to forward slashes for cross-platform matching
$normalizedPath = $filePath -replace '\\', '/'

# Only fire for files under .claude/agents/ with .md extension
if ($normalizedPath -notmatch '\.claude/agents/.+\.md$') { exit 0 }

$repoPath = "C:\Claude\design-creator-reviewer"

$prompt = "A file under .claude/agents/ was just modified: $filePath. " +
    "Read ALL files under .claude/agents/ in $repoPath and regenerate these three documentation files " +
    "to accurately reflect the current agent and skill definitions: " +
    "1) commands.md - update slash commands, natural language triggers, argument tables, and examples; " +
    "2) agent-relations.md - update system overview diagram, folder structure, agent catalogue table, flow diagrams, and I/O tables; " +
    "3) multi-agent-tutorial.md - update any agent names, tool lists, or capability descriptions that reference changed agents. " +
    "Write the files directly. Do not ask questions."

# Start-Process launches claude detached so the hook returns immediately
Start-Process -NoNewWindow -FilePath "claude" `
    -ArgumentList @("--print", $prompt) `
    -WorkingDirectory $repoPath

exit 0