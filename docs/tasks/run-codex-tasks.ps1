[CmdletBinding()]
param(
    [string]$StateDir = ".codex-task-state",
    [string]$Model = "gpt-5.6-terra",
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3,
    [switch]$SkipPreflight
)

$ErrorActionPreference = "Stop"
$TaskDirectory = $PSScriptRoot
$SetupDocument = Join-Path $TaskDirectory "setup.md"
$TaskDocuments = @(
    "00-bootstrap.md",
    "01-foundation-domain.md",
    "02-model-stream.md",
    "03-tool-runtime.md",
    "04-context-session-budget.md",
    "05-trace-format.md",
    "06-agent-loop.md",
    "07-async-operations.md",
    "08-openai-compatible.md",
    "09-replay-diff.md",
    "10-c-abi.md",
    "11-spindle-adapter.md",
    "12-runtime-acceptance.md"
)

$RepositoryRoot = (git -C $TaskDirectory rev-parse --show-toplevel).Trim()
if (-not $RepositoryRoot) { throw "Unable to determine repository root." }
if (-not (Test-Path -LiteralPath $SetupDocument -PathType Leaf)) { throw "Missing setup document: $SetupDocument" }

$StateDirectory = Join-Path $RepositoryRoot $StateDir
New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null

function Get-HeadCommit { (git -C $RepositoryRoot rev-parse HEAD).Trim() }
function Get-WorkingTreeStatus { git -C $RepositoryRoot status --porcelain --untracked-files=all }
function Get-DocumentText([string]$Path) { [System.IO.File]::ReadAllText($Path) }

function Get-CodexThreadId([string]$EventsPath) {
    if (-not (Test-Path -LiteralPath $EventsPath -PathType Leaf)) { return $null }
    foreach ($line in Get-Content -LiteralPath $EventsPath) {
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
            if ($event.type -eq "thread.started" -and $event.thread_id) { return $event.thread_id.ToString() }
        }
        catch { }
    }
    return $null
}

function Test-TaskCommit([string]$InitialHead, [string]$TaskId) {
    $currentHead = Get-HeadCommit
    $subject = (git -C $RepositoryRoot log -1 --pretty=%s).Trim()
    git -C $RepositoryRoot merge-base --is-ancestor $InitialHead $currentHead
    $descends = $LASTEXITCODE -eq 0
    [PSCustomObject]@{
        CurrentHead = $currentHead
        Subject = $subject
        Expected = "$TaskId done"
        IsComplete = $currentHead -ne $InitialHead -and $descends -and $subject -eq "$TaskId done"
    }
}

function Invoke-Codex([System.IO.FileInfo]$Task, [int]$Attempt, [string]$SessionId) {
    $taskId = $Task.BaseName
    $kind = if ($SessionId) { "resume" } else { "attempt" }
    $resultPath = Join-Path $StateDirectory "$taskId.$kind-$Attempt.result.md"
    $eventsPath = Join-Path $StateDirectory "$taskId.$kind-$Attempt.jsonl"
    $setupText = Get-DocumentText $SetupDocument
    $taskText = Get-DocumentText $Task.FullName

    $prompt = @"
Implement exactly one task in the repository at:
$RepositoryRoot

The setup document is authoritative shared context. The task document is the complete scope for this invocation.

===== SETUP: $SetupDocument =====
$setupText
===== END SETUP =====

===== TASK: $($Task.FullName) =====
$taskText
===== END TASK =====

Required procedure:
1. Read AGENTS.md if present, then inspect relevant existing code, tests, dependency public APIs, and both documents above.
2. Implement only $taskId. Do not start later tasks or unrelated refactors.
3. Preserve unrelated changes. Never edit files inside deps/fund or deps/spindle.
4. Add real tests for normal, error, cancellation, resource exhaustion, ownership, and concurrency paths required by the task.
5. Run every acceptance command in the task and fix failures caused by this work.
6. Review git diff and public exports. Do not leave TODO, FIXME, placeholders, empty implementations, or fixed-success stubs.
7. Commit only when every acceptance criterion passes, with exactly this subject:

$taskId done

Do not use destructive Git commands or rewrite history. Do not change task documents or setup.md unless the task explicitly requires it.
If genuinely blocked by an unavailable dependency API, do not create the success commit. Leave useful work, record exact evidence and the smallest next action in the final response.
Your final response must state summary, files changed, commands and results, commit hash, and remaining risks.
"@

    if ($SessionId) {
        $arguments = @("exec", "resume", "--yolo", "--json", "--output-last-message", $resultPath, $SessionId, "-")
    }
    else {
        $arguments = @("exec", "--cd", $RepositoryRoot, "--model", $Model, "--yolo", "--json", "--output-last-message", $resultPath)
    }

    $oldError = $ErrorActionPreference
    $oldNative = $PSNativeCommandUseErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $PSNativeCommandUseErrorActionPreference = $false
        $prompt | & codex @arguments 2>&1 | ForEach-Object { $_.ToString() } | Tee-Object -FilePath $eventsPath | Out-Host
        return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; EventsPath = $eventsPath }
    }
    finally {
        $ErrorActionPreference = $oldError
        $PSNativeCommandUseErrorActionPreference = $oldNative
    }
}

if (-not $SkipPreflight) {
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { throw "codex is not available on PATH." }
    if (-not (Get-Command zig -ErrorAction SilentlyContinue)) { throw "zig is not available on PATH." }
    $zigVersion = (zig version).Trim()
    if ($zigVersion -ne "0.16.0") { throw "Zig 0.16.0 is required; found $zigVersion." }

    git -C $RepositoryRoot submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "Submodule initialization failed." }

    $status = @(Get-WorkingTreeStatus | Where-Object { $_ -notmatch [regex]::Escape($StateDir) })
    if ($status.Count -ne 0) {
        throw "Working tree must be clean before task execution. Commit planning artifacts first.`n$($status -join "`n")"
    }
}

$tasks = foreach ($name in $TaskDocuments) {
    $path = Join-Path $TaskDirectory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing task document: $path" }
    Get-Item -LiteralPath $path
}

foreach ($task in $tasks) {
    $taskId = $task.BaseName
    $donePath = Join-Path $StateDirectory "$taskId.done"
    $failurePath = Join-Path $StateDirectory "$taskId.failed.md"
    if (Test-Path -LiteralPath $donePath -PathType Leaf) { Write-Host "[SKIP] $taskId"; continue }

    Write-Host ""
    Write-Host "========================================"
    Write-Host "[TASK] $taskId"
    Write-Host "========================================"
    $initialHead = Get-HeadCommit
    $sessionId = $null
    $success = $false

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "[ATTEMPT] $attempt / $MaxAttempts"
        $run = Invoke-Codex -Task $task -Attempt $attempt -SessionId $sessionId
        if (-not $sessionId) { $sessionId = Get-CodexThreadId $run.EventsPath }
        $commit = Test-TaskCommit -InitialHead $initialHead -TaskId $taskId

        if ($run.ExitCode -eq 0 -and $commit.IsComplete) {
            @"
task=$taskId
commit=$($commit.CurrentHead)
completed_at=$(Get-Date -Format o)
attempt=$attempt
"@ | Set-Content -LiteralPath $donePath -Encoding utf8
            Remove-Item -LiteralPath $failurePath -ErrorAction SilentlyContinue
            Write-Host "[DONE] $taskId"
            Write-Host "[COMMIT] $($commit.CurrentHead)"
            $success = $true
            break
        }

        $status = Get-WorkingTreeStatus
        @"
# Task failure

Task: $taskId
Attempt: $attempt
Exit code: $($run.ExitCode)
Initial HEAD: $initialHead
Current HEAD: $($commit.CurrentHead)
Expected commit: $($commit.Expected)
Actual commit: $($commit.Subject)
Session: $sessionId

## Working tree

~~~text
$status
~~~
"@ | Set-Content -LiteralPath $failurePath -Encoding utf8

        if ($attempt -lt $MaxAttempts) { Write-Warning "Task incomplete; retrying in the same Codex session when available." }
    }

    if (-not $success) { throw "Task $taskId failed after $MaxAttempts attempts. See $failurePath" }
}

Write-Host ""
Write-Host "All listed tasks completed."
