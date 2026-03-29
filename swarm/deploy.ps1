<#
.SYNOPSIS
    AI Swarm deployment script for psmux (Windows native tmux)

.DESCRIPTION
    Creates a psmux session with Router + Worker Pool architecture.
    Equivalent to shutsujin_departure.sh but for the swarm pattern.

.PARAMETER Formation
    Deployment formation: default, battle, lean

.PARAMETER Clean
    Reset task board and results before starting

.PARAMETER SetupOnly
    Create psmux session only (don't launch Claude Code)

.EXAMPLE
    ./deploy.ps1                    # Default formation
    ./deploy.ps1 -Formation battle  # All Opus
    ./deploy.ps1 -Clean             # Fresh start
    ./deploy.ps1 -SetupOnly         # Manual Claude launch
#>

param(
    [ValidateSet("default", "battle", "lean")]
    [string]$Formation = "default",

    [switch]$Clean,
    [switch]$SetupOnly
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir\..

# ============================================================
# Load configuration
# ============================================================
# Simple YAML parser for config (powershell-yaml module or manual)
$config = @{
    session = "swarm"
    router = @{ model = "opus"; thinking = $false }
    pools = @{
        code     = @{ model = "sonnet"; workers = 2; persona = "Senior Software Engineer" }
        docs     = @{ model = "sonnet"; workers = 1; persona = "Technical Writer" }
        research = @{ model = "sonnet"; workers = 1; persona = "Research Analyst" }
    }
}

# Apply formation overrides
switch ($Formation) {
    "battle" {
        $config.router.thinking = $true
        $config.pools.code.model = "opus"; $config.pools.code.workers = 4
        $config.pools.docs.model = "opus"; $config.pools.docs.workers = 2
        $config.pools.research.model = "opus"; $config.pools.research.workers = 2
    }
    "lean" {
        $config.router.model = "sonnet"
        $config.pools.code.workers = 1
        $config.pools.docs.model = "haiku"; $config.pools.docs.workers = 1
        $config.pools.research.model = "haiku"; $config.pools.research.workers = 1
    }
}

$SessionName = $config.session

# ============================================================
# Banner
# ============================================================
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║  AI SWARM - Router + Worker Pool                ║" -ForegroundColor Cyan
Write-Host "  ║  Formation: $($Formation.PadRight(38))║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# Step 1: Clean existing session
# ============================================================
Write-Host "  [1/5] Cleaning up existing sessions..." -ForegroundColor Yellow
psmux kill-session -t $SessionName 2>$null
Write-Host "  Done." -ForegroundColor Green

# ============================================================
# Step 2: Reset board and results (if -Clean)
# ============================================================
if ($Clean) {
    Write-Host "  [2/5] Resetting task board and results..." -ForegroundColor Yellow

    # Backup if board has content
    if (Test-Path "swarm/board.yaml") {
        $backupDir = "logs/backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Copy-Item "swarm/board.yaml" "$backupDir/" -ErrorAction SilentlyContinue
        Copy-Item "swarm/results/*" "$backupDir/" -ErrorAction SilentlyContinue
    }

    # Reset board
    @"
# AI Swarm Task Board
# Router writes tasks here. Workers pick them up.
tasks: []
"@ | Set-Content "swarm/board.yaml" -Encoding UTF8

    # Clear results
    if (Test-Path "swarm/results") {
        Remove-Item "swarm/results/*" -Force -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory -Path "swarm/results" -Force | Out-Null
    }

    # Reset status
    @"
# Swarm Status
Last updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')

## Active Tasks
None

## Completed
None
"@ | Set-Content "swarm/status.md" -Encoding UTF8

    Write-Host "  Board and results reset." -ForegroundColor Green
} else {
    Write-Host "  [2/5] Keeping existing board state." -ForegroundColor Yellow
    # Ensure directories exist
    @("swarm/results") | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }
}

# ============================================================
# Step 3: Create psmux session with windows
# ============================================================
Write-Host "  [3/5] Creating psmux session..." -ForegroundColor Yellow

# Create session with Router window
psmux new-session -d -s $SessionName -n "router"
psmux set-option -p -t "${SessionName}:router.0" @agent_id "router"
psmux send-keys -t "${SessionName}:router" "cd `"$(Get-Location)`"" Enter

# Create a window per pool
foreach ($poolName in $config.pools.Keys) {
    $pool = $config.pools[$poolName]
    $workerCount = $pool.workers

    psmux new-window -t $SessionName -n $poolName
    psmux set-option -p -t "${SessionName}:${poolName}.0" @agent_id "${poolName}_0"
    psmux send-keys -t "${SessionName}:${poolName}.0" "cd `"$(Get-Location)`"" Enter

    # Split panes for additional workers
    for ($i = 1; $i -lt $workerCount; $i++) {
        psmux split-window -t "${SessionName}:${poolName}" -h
        psmux set-option -p -t "${SessionName}:${poolName}.$i" @agent_id "${poolName}_$i"
        psmux send-keys -t "${SessionName}:${poolName}.$i" "cd `"$(Get-Location)`"" Enter
    }

    # Balance pane layout
    psmux select-layout -t "${SessionName}:${poolName}" tiled 2>$null
}

# Show pane borders with agent IDs
psmux set-option -t $SessionName -w pane-border-status top
psmux set-option -t $SessionName -w pane-border-format '#{pane_index} #{@agent_id}'

Write-Host "  Session created." -ForegroundColor Green

# ============================================================
# Step 4: Launch Claude Code (unless -SetupOnly)
# ============================================================
if (-not $SetupOnly) {
    Write-Host "  [4/5] Launching Claude Code on all agents..." -ForegroundColor Yellow

    # Router
    $routerModel = $config.router.model
    $routerThinking = if ($config.router.thinking) { "" } else { "MAX_THINKING_TOKENS=0 " }
    psmux send-keys -t "${SessionName}:router.0" "${routerThinking}claude --model $routerModel --dangerously-skip-permissions"
    psmux send-keys -t "${SessionName}:router.0" Enter
    Write-Host "    Router ($routerModel) launched." -ForegroundColor Gray

    Start-Sleep -Seconds 2

    # Workers
    foreach ($poolName in $config.pools.Keys) {
        $pool = $config.pools[$poolName]
        $workerCount = $pool.workers
        $model = $pool.model

        for ($i = 0; $i -lt $workerCount; $i++) {
            psmux send-keys -t "${SessionName}:${poolName}.$i" "claude --model $model --dangerously-skip-permissions"
            psmux send-keys -t "${SessionName}:${poolName}.$i" Enter
            Start-Sleep -Seconds 1
        }
        Write-Host "    $poolName pool ($workerCount x $model) launched." -ForegroundColor Gray
    }

    Write-Host "  All agents launched." -ForegroundColor Green

    # ============================================================
    # Step 5: Load instructions
    # ============================================================
    Write-Host "  [5/5] Loading instructions..." -ForegroundColor Yellow

    # Wait for Router to be ready
    Write-Host "    Waiting for Claude Code to start (max 30s)..." -ForegroundColor Gray
    for ($i = 0; $i -lt 30; $i++) {
        $capture = psmux capture-pane -t "${SessionName}:router.0" -p 2>$null
        if ($capture -match "bypass permissions") {
            Write-Host "    Router ready (${i}s)." -ForegroundColor Gray
            break
        }
        Start-Sleep -Seconds 1
    }

    # Send instructions to Router
    psmux send-keys -t "${SessionName}:router.0" "Read swarm/router.md and swarm/config.yaml. You are the Router."
    Start-Sleep -Milliseconds 500
    psmux send-keys -t "${SessionName}:router.0" Enter

    Start-Sleep -Seconds 2

    # Send instructions to Workers
    foreach ($poolName in $config.pools.Keys) {
        $pool = $config.pools[$poolName]
        $workerCount = $pool.workers

        for ($i = 0; $i -lt $workerCount; $i++) {
            $agentId = "${poolName}_$i"
            psmux send-keys -t "${SessionName}:${poolName}.$i" "Read swarm/worker.md. You are worker $agentId in the $poolName pool."
            Start-Sleep -Milliseconds 300
            psmux send-keys -t "${SessionName}:${poolName}.$i" Enter
            Start-Sleep -Seconds 1
        }
    }

    Write-Host "  Instructions loaded." -ForegroundColor Green
} else {
    Write-Host "  [4/5] Setup only mode. Claude Code not launched." -ForegroundColor Yellow
    Write-Host "  [5/5] Skipped (no Claude Code)." -ForegroundColor Yellow
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║  Swarm Ready                                    ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Session: $SessionName" -ForegroundColor White
Write-Host "  Formation: $Formation" -ForegroundColor White
Write-Host ""

# Show formation details
Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor Gray
Write-Host "  │  Windows:                                        │" -ForegroundColor Gray
Write-Host "  │    router   - Router ($($config.router.model))$(if(-not $config.router.thinking){' (no thinking)'})" -ForegroundColor Gray
foreach ($poolName in $config.pools.Keys) {
    $pool = $config.pools[$poolName]
    $padded = $poolName.PadRight(10)
    Write-Host "  │    $padded - $($pool.workers) x $($pool.model)" -ForegroundColor Gray
}
Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor Gray
Write-Host ""

$totalWorkers = ($config.pools.Values | ForEach-Object { $_.workers } | Measure-Object -Sum).Sum
Write-Host "  Total: 1 Router + $totalWorkers Workers = $($totalWorkers + 1) agents" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Connect:" -ForegroundColor White
Write-Host "    psmux attach -t $SessionName         # Full session" -ForegroundColor Gray
Write-Host "    psmux select-window -t ${SessionName}:router  # Router only" -ForegroundColor Gray
Write-Host ""
