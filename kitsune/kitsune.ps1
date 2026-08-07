# Helper for the Kitsune (brave-core fork) build on the-beast-windows.
# Usage: .\kitsune.ps1 <command> [args]
#   status         - git status/branch + tool versions
#   sync           - pull latest Chromium + brave-core
#   build          - component build (default)
#   build-release  - release build (WARNING: likely OOMs at 16 GB RAM)
#   package        - stage a runnable tree for copying to another machine
#   branch <name>  - create/checkout a branch off upstream/master
#   push           - push current branch to origin (refuses on master)
#   pull-upstream  - fast-forward master from upstream
#
# Tuning: -Jobs <n> overrides compile parallelism (default 8).
#   16 GB RAM / 12 vCPU. Raise toward 10-12 if you never see swapping;
#   drop to 4-6 if the box thrashes. A 32 GB pagefile is the backstop.

param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'sync', 'build', 'build-release', 'package', 'branch', 'push', 'pull-upstream')]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Arg,

    [int]$Jobs = 8
)

$ErrorActionPreference = 'Stop'

$Root     = 'C:\kitsune'
$RepoRoot = "$Root\src\brave"
$OutDir   = "$Root\src\out\Component"

$pnpmDir = (Get-ChildItem 'C:\Users\beast\AppData\Local\Microsoft\WinGet\Packages' -Filter 'pnpm.pnpm*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
$env:Path = "C:\Program Files\nodejs;C:\Program Files\Git\cmd;$pnpmDir;$env:Path"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'

if (-not $Command) {
    Write-Host "Usage: .\kitsune.ps1 <status|sync|build|build-release|package|branch|push|pull-upstream> [arg] [-Jobs n]"
    exit 1
}

# --- Kitsune de-Brave-ing + low-RAM build args -------------------------------
# Passed on every build so they can't drift. `--gn k:v` values are JSON-parsed,
# so `false` becomes a real boolean.
#   *_symbol_level=0 : debug symbols are the single biggest RAM and disk cost.
#     Raise to 1-2 only if you need a real debugger, and expect out/ to balloon.
#   treat_warnings_as_errors=false : this toolchain is newer than Brave CI's,
#     so upstream-clean code can still trip new warnings.
# Only MACHINE tuning belongs here. The Kitsune feature removals (wallet,
# talk, rewards, web discovery) are baked into the fork's buildflag defaults
# under components/*/buildflags/buildflags.gni, so they are version-controlled
# and apply to every checkout without special build invocation.
#
#   *_symbol_level=0 : debug symbols are the biggest RAM and disk cost on this
#     16 GB box. Raise to 1-2 if you need a real debugger; out/ will balloon.
#   treat_warnings_as_errors=false : this toolchain is newer than Brave CI's,
#     so upstream-clean code can still trip new warnings.
$GnArgs = @(
    '--gn', 'symbol_level:0'
    '--gn', 'blink_symbol_level:0'
    '--gn', 'v8_symbol_level:0'
    '--gn', 'treat_warnings_as_errors:false'
)
$NinjaArgs = @('--ninja', "j:$Jobs")

Set-Location $RepoRoot

switch ($Command) {
    'status' {
        Write-Host "--- branch ---" -ForegroundColor Cyan
        git branch --show-current
        Write-Host "--- status ---" -ForegroundColor Cyan
        git status --short
        Write-Host "--- remotes ---" -ForegroundColor Cyan
        git remote -v
        Write-Host "--- tools ---" -ForegroundColor Cyan
        node --version; pnpm --version; git --version
        Write-Host "--- memory ---" -ForegroundColor Cyan
        $os = Get-CimInstance Win32_OperatingSystem
        "RAM free: {0:N1} GB / {1:N1} GB" -f ($os.FreePhysicalMemory / 1MB), ($os.TotalVisibleMemorySize / 1MB)
        "Jobs default: $Jobs"
        if (Test-Path $OutDir) {
            $sz = (Get-ChildItem $OutDir -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB
            "out/Component: {0:N1} GB" -f $sz
        }
    }
    'sync' {
        pnpm run sync
        # $ErrorActionPreference='Stop' does NOT catch native command failures,
        # so propagate explicitly or callers see a false success.
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Sync FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
            exit $LASTEXITCODE
        }
    }
    'build' {
        Write-Host "Building with $Jobs jobs (symbol_level=0)..." -ForegroundColor Cyan
        pnpm run build @GnArgs @NinjaArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Build FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
            exit $LASTEXITCODE
        }
        $exe = "$OutDir\brave.exe"
        if (-not (Test-Path $exe)) {
            Write-Host "Build reported success but $exe is missing." -ForegroundColor Red
            exit 1
        }
        Copy-Item $exe "$OutDir\Kitsune.exe" -Force
        Write-Host "Built: $OutDir\Kitsune.exe" -ForegroundColor Green
    }
    'build-release' {
        Write-Host "WARNING: release builds do full LTO and commonly OOM at 16 GB RAM." -ForegroundColor Yellow
        Write-Host "Continuing in 5s (Ctrl+C to abort)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        pnpm run build Release @GnArgs @NinjaArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Release build FAILED (exit $LASTEXITCODE)" -ForegroundColor Red
            exit $LASTEXITCODE
        }
    }
    'package' {
        # A component build is split across many DLLs - the whole tree is the
        # deliverable, not just the .exe. Stage only what's needed to run.
        if (-not (Test-Path "$OutDir\brave.exe")) {
            Write-Host "No build found at $OutDir - run '.\kitsune.ps1 build' first." -ForegroundColor Red
            exit 1
        }
        $stage = "$Root\dist\Kitsune"
        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
        New-Item -ItemType Directory -Path $stage -Force | Out-Null

        Write-Host "Staging runtime files to $stage ..." -ForegroundColor Cyan
        # Runtime needs: executables, libraries, resource packs, locales, ICU.
        # Excluded: obj/ gen/ and .pdb - build intermediates and symbols.
        Get-ChildItem $OutDir -File | Where-Object {
            $_.Extension -in '.exe', '.dll', '.pak', '.bin', '.dat', '.json', '.manifest'
        } | ForEach-Object { Copy-Item $_.FullName $stage -Force }

        foreach ($sub in @('locales', 'resources', 'swiftshader')) {
            if (Test-Path "$OutDir\$sub") {
                Copy-Item "$OutDir\$sub" $stage -Recurse -Force
            }
        }

        $zip = "$Root\dist\Kitsune.zip"
        if (Test-Path $zip) { Remove-Item $zip -Force }
        Compress-Archive -Path "$stage\*" -DestinationPath $zip -CompressionLevel Optimal
        $mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
        Write-Host "Packaged: $zip ($mb MB)" -ForegroundColor Green
        Write-Host "Copy to your machine with:" -ForegroundColor Cyan
        Write-Host "  scp the-beast-windows:$zip ." -ForegroundColor Cyan
    }
    'branch' {
        if (-not $Arg) { Write-Host "Usage: .\kitsune.ps1 branch <name>"; exit 1 }
        git fetch upstream
        git checkout -b $Arg upstream/master
    }
    'push' {
        $current = (git branch --show-current).Trim()
        if ($current -eq 'master') {
            Write-Host "Refusing to push master directly." -ForegroundColor Red
            exit 1
        }
        git push -u origin $current
    }
    'pull-upstream' {
        $current = (git branch --show-current).Trim()
        if ($current -ne 'master') { git checkout master }
        git fetch upstream
        git merge --ff-only upstream/master
    }
}
