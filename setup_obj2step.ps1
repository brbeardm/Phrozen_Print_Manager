<#  One-time setup for the OBJ -> STEP converter used by the Revo Print Manager.

    Creates a Python virtual environment at files\.venv and installs the CAD
    dependencies (trimesh, pymeshlab, cadquery-ocp, numpy, scipy). This pulls a
    large one-time download (~600 MB - cadquery-ocp bundles the OpenCascade
    kernel). Safe to re-run: if the venv already works it just reports and exits.

    Run:  powershell -ExecutionPolicy Bypass -File setup_obj2step.ps1
          (or double-click setup_obj2step.cmd)
#>
param([switch]$Force)   # -Force rebuilds the venv from scratch

$ErrorActionPreference = "Stop"
$root    = $PSScriptRoot
$filesDir= Join-Path $root "files"
$venvDir = Join-Path $filesDir ".venv"
$venvPy  = Join-Path $venvDir "Scripts\python.exe"
$req     = Join-Path $filesDir "requirements.txt"
$script  = Join-Path $filesDir "obj2step.py"

function Say($m,$c="Gray"){ Write-Host $m -ForegroundColor $c }

Say "== OBJ -> STEP converter setup ==" Cyan

if (-not (Test-Path $script)) { Say "ERROR: $script not found - run this from the project folder." Red; exit 1 }
if (-not (Test-Path $req))    { Say "ERROR: $req not found." Red; exit 1 }

# --- already set up? (unless -Force) -------------------------------------
function Test-VenvReady {
  if (-not (Test-Path $venvPy)) { return $false }
  & $venvPy -c "import trimesh, pymeshlab, OCP, numpy, scipy" 2>$null
  return ($LASTEXITCODE -eq 0)
}
if (-not $Force -and (Test-VenvReady)) {
  Say "Already set up - the venv exists and all dependencies import. Nothing to do." Green
  Say "(Re-run with -Force to rebuild from scratch.)"
  exit 0
}

# --- find a suitable Python (3.10-3.14) ----------------------------------
# The tool's README warns about brand-new Python, but as of 2026 the CAD wheels
# ship for 3.14, so any 3.10-3.14 works. Prefer the py launcher, then PATH python.
function Resolve-Python {
  $cands = @()
  $py = (Get-Command py -ErrorAction SilentlyContinue).Source
  if ($py) { foreach ($v in '3.12','3.11','3.13','3.14','3.10','3') { $cands += ,(@($py) + @("-$v")) } }
  $px = (Get-Command python -ErrorAction SilentlyContinue).Source
  if ($px) { $cands += ,(@($px)) }
  foreach ($c in $cands) {
    $exe = $c[0]; $pre = @($c[1..($c.Count-1)])
    try {
      $v = & $exe @pre -c "import sys;print('%d.%d'%sys.version_info[:2]);import sys as _;sys.exit(0 if (3,10)<=sys.version_info[:2]<(3,15) else 1)" 2>$null
      if ($LASTEXITCODE -eq 0 -and $v) { return @{ exe=$exe; pre=$pre; ver="$v" } }
    } catch {}
  }
  return $null
}

$P = Resolve-Python
if (-not $P) {
  Say "ERROR: no compatible Python found (need 3.10-3.14)." Red
  Say "Install Python 3.12 from https://www.python.org/downloads/ (check 'Add python.exe to PATH'), then re-run." Yellow
  exit 1
}
Say ("Using Python {0}  ({1} {2})" -f $P.ver, $P.exe, ($P.pre -join ' '))

# --- (re)create the venv -------------------------------------------------
if ($Force -and (Test-Path $venvDir)) {
  Say "Removing existing venv (-Force)..." Yellow
  Remove-Item $venvDir -Recurse -Force
}
if (-not (Test-Path $venvPy)) {
  Say "Creating virtual environment at files\.venv ..." Yellow
  & $P.exe @($P.pre) -m venv $venvDir
  if (-not (Test-Path $venvPy)) { Say "ERROR: venv creation failed." Red; exit 1 }
}

# --- install dependencies (the big download) -----------------------------
Say "Upgrading pip ..." Yellow
& $venvPy -m pip install --upgrade pip
Say "Installing CAD dependencies - this is the large one-time download (~600 MB). Please wait..." Yellow
& $venvPy -m pip install -r $req
if ($LASTEXITCODE -ne 0) { Say "ERROR: dependency install failed (see pip output above)." Red; exit 1 }

# --- verify --------------------------------------------------------------
Say "Verifying imports ..." Yellow
if (Test-VenvReady) {
  Say ""
  Say "SUCCESS - the OBJ -> STEP converter is ready." Green
  Say "Reload the Print Manager page and use the 'Tinkercad OBJ -> Fusion STEP' card." Green
  exit 0
} else {
  Say "ERROR: dependencies installed but one or more failed to import." Red
  Say "Try:  powershell -ExecutionPolicy Bypass -File setup_obj2step.ps1 -Force" Yellow
  exit 1
}
