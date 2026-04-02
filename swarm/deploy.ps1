<#
.SYNOPSIS
    AI Swarm - Team deployment script for psmux

.DESCRIPTION
    Deploys one or more AI swarm teams as psmux sessions.
    Each team = 1 Router + 5 Workers.

.EXAMPLE
    ./deploy.ps1 dev                     # Dev team only
    ./deploy.ps1 dev article             # Dev + Article teams
    ./deploy.ps1 dev -Battle             # Dev team, all Opus
    ./deploy.ps1 -All                    # All teams
    ./deploy.ps1 -All -Battle            # All teams, all Opus
    ./deploy.ps1 dev -Clean              # Dev team, fresh board
    ./deploy.ps1 -All -SetupOnly         # All sessions, no Claude
    ./deploy.ps1 -List                   # Show available teams
#>

param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Teams,

    [switch]$All,
    [switch]$Battle,
    [switch]$Clean,
    [switch]$SetupOnly,
    [switch]$List
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location "$ScriptDir\.."

# ============================================================
# Constants
# ============================================================
$WorkersPerTeam = 5
$RouterModel = "opus"
$WorkerModel = if ($Battle) { "opus" } else { "sonnet" }
$RouterThinkingPrefix = if ($Battle) { "" } else { "MAX_THINKING_TOKENS=0 " }
$FormationLabel = if ($Battle) { "BATTLE (All Opus)" } else { "Default (Router:Opus / Workers:Sonnet)" }

# ============================================================
# Discover available teams from swarm/teams/*.yaml
# ============================================================
$TeamsDir = "swarm/teams"
$AvailableTeams = @()
if (Test-Path $TeamsDir) {
    $AvailableTeams = Get-ChildItem "$TeamsDir/*.yaml" | ForEach-Object { $_.BaseName }
}

# ============================================================
# -List: show available teams and exit
# ============================================================
if ($List) {
    Write-Host ""
    Write-Host "  Available teams:" -ForegroundColor Cyan
    foreach ($t in $AvailableTeams) {
        # Read first line of description from YAML
        $desc = ""
        $yamlPath = "$TeamsDir/$t.yaml"
        if (Test-Path $yamlPath) {
            $desc = (Get-Content $yamlPath | Select-String "^description:" | ForEach-Object { $_ -replace "^description:\s*`"?", "" -replace "`"$", "" }) -join ""
        }
        $padded = $t.PadRight(12)
        Write-Host "    $padded $desc" -ForegroundColor White
    }
    Write-Host ""
    exit 0
}

# ============================================================
# Determine which teams to deploy
# ============================================================
if ($All) {
    $Teams = $AvailableTeams
} elseif (-not $Teams -or $Teams.Count -eq 0) {
    Write-Host ""
    Write-Host "  AI Swarm - Team Deployment" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Usage:" -ForegroundColor White
    Write-Host "    ./deploy.ps1 <team> [team2] [options]" -ForegroundColor Gray
    Write-Host "    ./deploy.ps1 -List                      # Show teams" -ForegroundColor Gray
    Write-Host "    ./deploy.ps1 -All                       # All teams" -ForegroundColor Gray
    Write-Host "    ./deploy.ps1 dev article -Battle        # Specific teams, all Opus" -ForegroundColor Gray
    Write-Host "    ./deploy.ps1 dev -Clean                 # Fresh board" -ForegroundColor Gray
    Write-Host "    ./deploy.ps1 dev -SetupOnly             # No Claude launch" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Available teams: $($AvailableTeams -join ', ')" -ForegroundColor Yellow
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

# ============================================================
# Banner
# ============================================================
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║  AI SWARM - Team Deployment                             ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Formation : $FormationLabel" -ForegroundColor White
Write-Host "  Teams     : $($Teams -join ', ')" -ForegroundColor White
Write-Host "  Per team  : 1 Router ($RouterModel) + $WorkersPerTeam Workers ($WorkerModel)" -ForegroundColor White
$totalAgents = $Teams.Count * ($WorkersPerTeam + 1)
Write-Host "  Total     : $totalAgents agents across $($Teams.Count) team(s)" -ForegroundColor White
Write-Host ""

# ============================================================
# Ensure runtime directories exist
# ============================================================
$RuntimeDirs = @(
    "swarm/boards",
    "swarm/results",
    "swarm/projects",
    "swarm/handoffs",
    "swarm/status",
    "swarm/skill-proposals"
)
foreach ($dir in $RuntimeDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ============================================================
# Deploy each team
# ============================================================
foreach ($teamName in $Teams) {
    $session = $teamName
    Write-Host "  [$teamName] " -ForegroundColor Yellow -NoNewline

    # ----------------------------------------------------------
    # Kill existing session
    # ----------------------------------------------------------
    psmux kill-session -t $session 2>$null

    # ----------------------------------------------------------
    # Board: reset (-Clean) or ensure exists
    # ----------------------------------------------------------
    $boardPath = "swarm/boards/${teamName}.yaml"
    if ($Clean) {
        # Backup if has content
        if (Test-Path $boardPath) {
            $content = Get-Content $boardPath -Raw
            if ($content -match "task_") {
                $backupDir = "swarm/logs/backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                Copy-Item $boardPath "$backupDir/"
            }
        }
        $boardContent = "# $teamName team task board`ntasks: []"
        $boardContent | Set-Content $boardPath -Encoding UTF8
    } else {
        if (-not (Test-Path $boardPath)) {
            $boardContent = "# $teamName team task board`ntasks: []"
            $boardContent | Set-Content $boardPath -Encoding UTF8
        }
    }

    # ----------------------------------------------------------
    # Status file: ensure exists
    # ----------------------------------------------------------
    $statusPath = "swarm/status/${teamName}.yaml"
    if (-not (Test-Path $statusPath)) {
        $statusContent = "team: $teamName`nupdated_at: `"`"`nactive: []`ncompleted_today: []`nblocked: []`nskill_proposals: []"
        $statusContent | Set-Content $statusPath -Encoding UTF8
    }

    # ----------------------------------------------------------
    # Create psmux session (1 window, 6 panes: Router + 5 Workers)
    # ----------------------------------------------------------
    # Pane 0: Router
    psmux new-session -d -s $session -n "team"
    psmux set-option -p -t "${session}:team.0" @agent_id "router"
    psmux set-option -p -t "${session}:team.0" @team_name $teamName
    psmux send-keys -t "${session}:team.0" "cd `"$(Get-Location)`"" Enter

    # Panes 1-5: Workers
    for ($i = 0; $i -lt $WorkersPerTeam; $i++) {
        $paneIndex = $i + 1
        if ($paneIndex % 2 -eq 1) {
            psmux split-window -t "${session}:team" -h
        } else {
            psmux split-window -t "${session}:team" -v
        }
        psmux set-option -p -t "${session}:team.${paneIndex}" @agent_id "worker_$i"
        psmux set-option -p -t "${session}:team.${paneIndex}" @team_name $teamName
        psmux send-keys -t "${session}:team.${paneIndex}" "cd `"$(Get-Location)`"" Enter
    }

    psmux select-layout -t "${session}:team" tiled 2>$null

    # Pane border labels
    psmux set-option -t $session -w pane-border-status top
    psmux set-option -t $session -w pane-border-format '#{@team_name}/#{@agent_id}'

    Write-Host "session created" -ForegroundColor Gray -NoNewline

    # ----------------------------------------------------------
    # Launch Claude Code (unless -SetupOnly)
    # ----------------------------------------------------------
    if (-not $SetupOnly) {
        # Router
        # Router (pane 0)
        psmux send-keys -t "${session}:team.0" "${RouterThinkingPrefix}claude --model $RouterModel --dangerously-skip-permissions"
        psmux send-keys -t "${session}:team.0" Enter

        Start-Sleep -Seconds 2

        # Workers (panes 1-5)
        for ($i = 0; $i -lt $WorkersPerTeam; $i++) {
            $paneIndex = $i + 1
            psmux send-keys -t "${session}:team.${paneIndex}" "claude --model $WorkerModel --dangerously-skip-permissions"
            psmux send-keys -t "${session}:team.${paneIndex}" Enter
            Start-Sleep -Milliseconds 500
        }

        Write-Host " → Claude launched" -ForegroundColor Gray -NoNewline

        # Wait for Router ready (max 30s)
        $ready = $false
        for ($w = 0; $w -lt 30; $w++) {
            $capture = psmux capture-pane -t "${session}:team.0" -p 2>$null
            if ($capture -match "bypass permissions") {
                $ready = $true
                break
            }
            Start-Sleep -Seconds 1
        }

        if ($ready) {
            # Load instructions: Router (pane 0)
            psmux send-keys -t "${session}:team.0" "Read swarm/router.md, swarm/teams/${teamName}.yaml, swarm/config.yaml. You are the Router of the ${teamName} team."
            Start-Sleep -Milliseconds 500
            psmux send-keys -t "${session}:team.0" Enter

            Start-Sleep -Seconds 2

            # Load instructions: Workers (panes 1-5)
            for ($i = 0; $i -lt $WorkersPerTeam; $i++) {
                $paneIndex = $i + 1
                psmux send-keys -t "${session}:team.${paneIndex}" "Read swarm/worker.md and swarm/teams/${teamName}.yaml. You are worker_$i in the ${teamName} team."
                Start-Sleep -Milliseconds 300
                psmux send-keys -t "${session}:team.${paneIndex}" Enter
                Start-Sleep -Seconds 1
            }
            Write-Host " → instructions loaded" -ForegroundColor Gray -NoNewline
        } else {
            Write-Host " → WARNING: Router not ready in 30s" -ForegroundColor Yellow -NoNewline
        }
    }

    Write-Host " → Ready" -ForegroundColor Green
}

# ============================================================
# Start dashboard watcher (background)
# ============================================================
$WatcherScript = @'
param($StatusDir, $StatusMd, $GoogleEnabled, $SpreadsheetId, $GoogleTool)
$lastHash = ""
while ($true) {
    Start-Sleep -Seconds 10
    $files = Get-ChildItem "$StatusDir/*.yaml" -ErrorAction SilentlyContinue
    if (-not $files) { continue }
    $currentHash = ($files | ForEach-Object { (Get-Item $_).LastWriteTime.Ticks }) -join ","
    if ($currentHash -eq $lastHash) { continue }
    $lastHash = $currentHash

    # Generate status.md from status/*.yaml
    $lines = @("# Swarm Status", "Last updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "")
    $lines += "## Active Tasks"
    $lines += "| Team | Task | Worker | Phase | Started |"
    $lines += "|------|------|--------|-------|---------|"
    $sheetsActive = @()
    $sheetsCompleted = @()

    foreach ($f in $files) {
        $yaml = Get-Content $f.FullName -Raw
        $team = $f.BaseName

        # Parse active tasks (simple regex, not full YAML parser)
        $inActive = $false; $inCompleted = $false
        foreach ($line in (Get-Content $f.FullName)) {
            if ($line -match "^active:") { $inActive = $true; $inCompleted = $false; continue }
            if ($line -match "^completed_today:") { $inActive = $false; $inCompleted = $true; continue }
            if ($line -match "^(blocked|skill_proposals|team|updated_at):") { $inActive = $false; $inCompleted = $false; continue }

            if ($inActive -and $line -match "description:\s*(.+)") {
                $desc = $Matches[1].Trim('"')
                $lines += "| $team | $desc | | | |"
                $sheetsActive += "$team,$desc"
            }
            if ($inCompleted -and $line -match "description:\s*(.+)") {
                $desc = $Matches[1].Trim('"')
                $sheetsCompleted += "$(Get-Date -Format 'HH:mm'),$team,$desc"
            }
        }
    }

    $lines += ""
    $lines += "## Completed Today"
    $lines += "| Time | Team | Task |"
    $lines += "|------|------|------|"
    # (populated from completed_today sections above)
    $lines += ""

    $lines -join "`n" | Set-Content $StatusMd -Encoding UTF8

    # Google Sheets sync (if enabled)
    if ($GoogleEnabled -eq "true" -and $SpreadsheetId) {
        try {
            if ($GoogleTool -eq "gog") {
                # Update Active tab
                if ($sheetsActive.Count -gt 0) {
                    $data = ($sheetsActive -join "`n")
                    & gog sheets write $SpreadsheetId --range "Active!A2:B" --clear-first --data $data 2>$null
                }
            }
        } catch { }  # Sheets sync failure is non-fatal
    }
}
'@

Write-Host "  Starting dashboard watcher..." -ForegroundColor Yellow
$watcherArgs = @(
    "swarm/status",
    "swarm/status.md",
    "true",     # google enabled
    "",         # spreadsheet_id (read from config at runtime)
    "gog"       # google tool
)
# Read spreadsheet_id from config
$configContent = Get-Content "swarm/config.yaml" -Raw -ErrorAction SilentlyContinue
if ($configContent -match 'spreadsheet_id:\s*"([^"]+)"') {
    $watcherArgs[3] = $Matches[1]
}
$watcher = Start-Job -ScriptBlock ([ScriptBlock]::Create($WatcherScript)) -ArgumentList $watcherArgs
Write-Host "  Dashboard watcher running (Job $($watcher.Id))." -ForegroundColor Green
Write-Host ""

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║  All teams deployed.                                    ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Connect:" -ForegroundColor White
foreach ($t in $Teams) {
    $padded = $t.PadRight(12)
    Write-Host "    psmux attach -t $padded  # Router + $WorkersPerTeam Workers" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  Files:" -ForegroundColor White
Write-Host "    Boards    : swarm/boards/{team}.yaml" -ForegroundColor Gray
Write-Host "    Results   : swarm/results/" -ForegroundColor Gray
Write-Host "    Status    : swarm/status.md" -ForegroundColor Gray
Write-Host "    Projects  : swarm/projects/" -ForegroundColor Gray
Write-Host "    Proposals : swarm/skill-proposals/" -ForegroundColor Gray
Write-Host ""
