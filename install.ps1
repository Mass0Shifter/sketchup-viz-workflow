<#
.SYNOPSIS
  Installs the SketchUp MCP bridge on Windows.

.DESCRIPTION
  1. Copies the Ruby plugin into every SketchUp Plugins folder it finds
     (or only the version given with -SketchUpVersion).
  2. Creates a Python virtual environment in .venv and installs the MCP server.
  3. Adds a "sketchup" entry to Claude Desktop's claude_desktop_config.json
     (a backup is written next to it first).

  Run from the repository folder:
      powershell -ExecutionPolicy Bypass -File .\install.ps1

  Close SketchUp first. Restart SketchUp and Claude Desktop afterwards.
#>
[CmdletBinding()]
param(
    [string]$SketchUpVersion,          # e.g. "2024" - default: all installed
    [switch]$SkipPlugin,
    [switch]$SkipPython,
    [switch]$SkipClaudeConfig,
    [switch]$ConstructionTools,        # also expose the Medeek/framing tools
    [string]$ServerName = "sketchup"
)

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $MyInvocation.MyCommand.Path
function Info($m) { Write-Host "  $m" }
function Head($m) { Write-Host ""; Write-Host "== $m ==" -ForegroundColor Cyan }

if (Get-Process -Name "SketchUp" -ErrorAction SilentlyContinue) {
    Write-Warning "SketchUp is running. The plugin will load the next time SketchUp starts."
}

# ---------------------------------------------------------------- 1. Plugin
if (-not $SkipPlugin) {
    Head "SketchUp plugin"
    $root = Join-Path $env:APPDATA "SketchUp"
    $dirs = @()
    if (Test-Path $root) {
        $dirs = Get-ChildItem $root -Directory -Filter "SketchUp 20*" |
            Where-Object { -not $SketchUpVersion -or $_.Name -eq "SketchUp $SketchUpVersion" } |
            ForEach-Object { Join-Path $_.FullName "SketchUp\Plugins" }
    }
    if (-not $dirs) {
        throw "No SketchUp Plugins folder found under $root. Open SketchUp once, then re-run (or pass -SkipPlugin)."
    }
    foreach ($plugins in $dirs) {
        New-Item -ItemType Directory -Force -Path $plugins | Out-Null
        Copy-Item (Join-Path $Repo "sketchup_plugin\sketchup_mcp_server.rb") $plugins -Force
        $dest = Join-Path $plugins "sketchup_mcp"
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Copy-Item (Join-Path $Repo "sketchup_plugin\sketchup_mcp") $dest -Recurse -Force
        Info "Installed into $plugins"
        $oldLib = Join-Path $plugins "lib\construction.rb"
        if (Test-Path $oldLib) {
            Info "Note: an older copy of this plugin left $plugins\lib\ behind; it is no longer used and can be deleted."
        }
    }
}

# ---------------------------------------------------------------- 2. Python
$exe = Join-Path $Repo ".venv\Scripts\sketchup-mcp.exe"
if (-not $SkipPython) {
    Head "Python MCP server"
    $venv = Join-Path $Repo ".venv"
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if ($uv) {
        Info "Using uv"
        & uv venv $venv --python 3.12 | Out-Null
        & uv pip install --python (Join-Path $venv "Scripts\python.exe") -e $Repo
    } else {
        if (Get-Command py -ErrorAction SilentlyContinue) {
            & py -3 -m venv $venv
        } elseif (Get-Command python -ErrorAction SilentlyContinue) {
            & python -m venv $venv
        } else {
            throw "Python 3.10+ not found. Install it from python.org (tick 'Add to PATH') or install uv, then re-run."
        }
        if (-not (Test-Path (Join-Path $venv "Scripts\python.exe"))) { throw "Could not create the virtual environment in $venv" }
        & (Join-Path $venv "Scripts\python.exe") -m pip install --upgrade pip | Out-Null
        & (Join-Path $venv "Scripts\python.exe") -m pip install -e $Repo
    }
    if (-not (Test-Path $exe)) { throw "Install finished but $exe is missing." }
    Info "MCP server: $exe"
}

# ---------------------------------------------------------------- 3. Claude Desktop config
if (-not $SkipClaudeConfig) {
    Head "Claude Desktop config"
    $candidates = @(Join-Path $env:APPDATA "Claude\claude_desktop_config.json")
    $msix = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Packages") -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue
    foreach ($p in $msix) { $candidates += Join-Path $p.FullName "LocalCache\Roaming\Claude\claude_desktop_config.json" }
    $targets = $candidates | Where-Object { Test-Path (Split-Path $_ -Parent) }
    if (-not $targets) { $targets = @($candidates[0]); New-Item -ItemType Directory -Force (Split-Path $candidates[0] -Parent) | Out-Null }

    $entry = [ordered]@{ command = $exe; args = @(); env = [ordered]@{} }
    if ($ConstructionTools) { $entry.env["SU_MCP_CONSTRUCTION_TOOLS"] = "1" }

    foreach ($cfg in $targets) {
        $data = [ordered]@{}
        if (Test-Path $cfg) {
            Copy-Item $cfg "$cfg.bak" -Force
            $raw = Get-Content $cfg -Raw
            if ($raw.Trim()) {
                $obj = $raw | ConvertFrom-Json
                foreach ($prop in $obj.PSObject.Properties) { $data[$prop.Name] = $prop.Value }
            }
        }
        $servers = [ordered]@{}
        if ($data.Contains("mcpServers") -and $data["mcpServers"]) {
            foreach ($prop in $data["mcpServers"].PSObject.Properties) { $servers[$prop.Name] = $prop.Value }
        }
        $servers[$ServerName] = $entry
        $data["mcpServers"] = $servers
        $json = $data | ConvertTo-Json -Depth 32
        [IO.File]::WriteAllText($cfg, $json, (New-Object System.Text.UTF8Encoding($false)))
        Info "Updated $cfg (backup: $cfg.bak)"
    }
}

Head "Done"
Info "1. Start SketchUp and open your model. Ruby Console (Extensions > Developer > Ruby Console) should show 'Server running'."
Info "   (Extensions > MCP Server has Start/Stop/Restart and 'Show Token File'.)"
Info "2. Fully quit Claude Desktop (tray icon > Quit) and reopen it."
Info "3. In Claude, ask: 'Give me a model_summary of the SketchUp model.'"
