<#
.SYNOPSIS
    AI Swarm - Team deployment script for psmux

.DESCRIPTION
    Deploys one or more AI swarm teams as psmux sessions.
    Each team = 1 Router + 5 Workers.

.PARAMETER Teams
    Team names to deploy (e.g., dev, design, article)

.PARAMETER All
    Deploy all defined teams

.PARAMETER Battle
    All agents use Opus (full power mode)

.PARAMETER Clean
    Reset boards and results before starting

.PARAMETER SetupOnly
    Create sessions only, don't launch Claude Code

.EXAMPLE
    ./deploy.ps1 dev                    # Dev team only
    ./deploy.ps1 dev article            # Dev + Article teams
    ./deploy.ps1 dev -Battle            # Dev team, all Opus
    ./deploy.ps1 -All                   # All teams
    ./deploy.ps1 -All -Battle           # All teams, all Opus
    ./deploy.ps1 dev -Clean             # Dev team, fresh board
    ./deploy.ps1 -All -SetupOnly        # All sessions, no Claude
#>

param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Teams,

    [switch]$All,
    [switch]$Battle,
    [switch]$Clean,
    [switch]$SetupOnly
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location "$ScriptDir\.."

$WorkersPerTeam = 5

# ============================================================
# Discover available teams
# ============================================================
$AvailableTeams = Get-ChildItem "swarm/teams/*.yaml" | ForEach-Object { $_.BaseName }

if ($All) {
    $Teams = $AvailableTeams
} elseif (-not $Teams -or $Teams.Count -eq 0) {
    Write-Host ""
    Write-Host "  Usage: ./deploy.ps1 <team> [team2] [options]" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Available teams:" -ForegroundColor White
    foreach ($t in $AvailableTeams) {
        Write-Host "    - $t" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Options:" -ForegroundColor White
    Write-Host "    -All        Deploy all teams" -ForegroundColor Gray
    Write-Host "    -Battle     All Opus mode" -ForegroundColor Gray
    Write-Host "    -Clean      Reset boards" -ForegroundColor Gray
    Write-Host "    -SetupOnly  No Claude launch" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# Validate team names
foreach ($t in $Teams) {
    if ($t -notin $AvailableTeams) {
        Write-Host "  Error: Unknown team '$t'" -ForegroundColor Red
        Write-Host "  Available: $($AvailableTeams -join ', ')" -ForegroundColor Gray
        exit 1
    }
}

# Model selection
$RouterModel = "opus"
$WorkerModel = if ($Battle) { "opus" } else { "sonnet" }
$RouterThinking = if ($Battle) { "" } else { "MAX_THINKING_TOKENS=0 " }
$FormationLabel = if ($Battle) { "BATTLE (All Opus)" } else { "Default (Router:Opus / Workers:Sonnet)" }

# ============================================================
# Banner
# ============================================================
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║  AI SWARM - Team Deployment                         ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Formation : $FormationLabel" -ForegroundColor White
Write-Host "  Teams     : $($Teams -join ', ')" -ForegroundColor White
Write-Host "  Per team  : 1 Router ($RouterModel) + $WorkersPerTeam Workers ($WorkerModel)" -ForegroundColor White
$total = $Teams.Count * ($WorkersPerTeam + 1)
Write-Host "  Total     : $total agents" -ForegroundColor White
Write-Host ""

# ============================================================
# Ensure directories
# ============================================================
@("swarm/boards", "swarm/results", "swarm/projects") | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# ============================================================
# Deploy each team
# ============================================================
foreach ($teamName in $Teams) {
    $session = $teamName

    Write-Host "  [$teamName] Deploying..." -ForegroundColor Yellow

    # Kill existing session
    psmux kill-session -t $session 2>$null

    # Reset board if -Clean
    if ($Clean) {
        @"
# $teamName Team Task Board
tasks: []
"@ | Set-Content "swarm/boards/${teamName}.yaml" -Encoding UTF8
        Write-Host "    Board reset." -ForegroundColor Gray
    } else {
        # Create board if doesn't exist
        if (-not (Test-Path "swarm/boards/${teamName}.yaml")) {
            @"
# $teamName Team Task Board
tasks: []
"@ | Set-Content "swarm/boards/${teamName}.yaml" -Encoding UTF8
        }
    }

    # Create session with Router window
    psmux new-session -d -s $session -n "router"
    psmux set-option -p -t "${session}:router.0" @agent_id "router"
    psmux set-option -p -t "${session}:router.0" @team_name $teamName
    psmux send-keys -t "${session}:router" "cd `"$(Get-Location)`"" Enter

    # Create Workers window with splits
    psmux new-window -t $session -n "workers"

    for ($i = 0; $i -lt $WorkersPerTeam; $i++) {
        if ($i -gt 0) {
            # Alternate horizontal/vertical for grid layout
            if ($i % 2 -eq 1) {
                psmux split-window -t "${session}:workers" -h
            } else {
                psmux split-window -t "${session}:workers" -v
            }
        }
        psmux set-option -p -t "${session}:workers.$i" @agent_id "worker_$i"
        psmux set-option -p -t "${session}:workers.$i" @team_name $teamName
        psmux send-keys -t "${session}:workers.$i" "cd `"$(Get-Location)`"" Enter
    }

    psmux select-layout -t "${session}:workers" tiled 2>$null

    # Pane borders
    psmux set-option -t $session -w pane-border-status top
    psmux set-option -t $session -w pane-border-format '#{@team_name} / #{@agent_id}'

    Write-Host "    Session created." -ForegroundColor Gray

    # Launch Claude Code
    if (-not $SetupOnly) {
        # Router
        psmux send-keys -t "${session}:router.0" "${RouterThinking}claude --model $RouterModel --dangerously-skip-permissions"
        psmux send-keys -t "${session}:router.0" Enter
        Write-Host "    Router ($RouterModel) launched." -ForegroundColor Gray

        Start-Sleep -Seconds 2

        # Workers
        for ($i = 0; $i -lt $WorkersPerTeam; $i++) {
            psmux send-keys -t "${session}:workers.$i" "claude --model $WorkerModel --dangerously-skip-permissions"
            psmux send-keys -t "${session}:workers.$i" Enter
            Start-Sleep -Milliseconds 500
        }
        Write-Host "    Workers ($WorkersPerTeam x $WorkerModel) launched." -ForegroundColor Gray

        # Wait for Router to be ready
        Write-Host "    Waiting for Router..." -ForegroundColor Gray
        for ($w = 0; $w -lt 30; $w++) {
            $capture = psmux capture-pane -t "${session}:router.0" -p 2>$null
            if ($capture -match "bypass permissions") {
                Write-Host "    Router ready." -ForegroundColor Gray
                break
            }
            Start-Sleep -Seconds 1
        }

        # Load instructions
        psmux send-keys -t "${session}:router.0" "Read swarm/router.md and swarm/teams/${teamName}.yaml and swarm/config.yaml. You are the Router of the ${teamName} team."
        Start-Sleep -Milliseconds 500
        psmux send-keys -t "${session}:router.0" Enter

        Start-Sleep -Seconds 2

        for ($i = 0; $i -lt $WorkersPerTeam; $i++) {
            psmux send-keys -t "${session}:workers.$i" "Read swarm/worker.md and swarm/teams/${teamName}.yaml. You are worker_$i in the ${teamName} team."
            Start-Sleep -Milliseconds 300
            psmux send-keys -t "${session}:workers.$i" Enter
            Start-Sleep -Seconds 1
        }
        Write-Host "    Instructions loaded." -ForegroundColor Gray
    }

    Write-Host "  [$teamName] Ready." -ForegroundColor Green
    Write-Host ""
}

# ============================================================
# Summary
# ============================================================
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║  All teams deployed.                                ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Connect to a team:" -ForegroundColor White
foreach ($t in $Teams) {
    Write-Host "    psmux attach -t $t" -ForegroundColor Gray
}
Write-Host ""
