$ErrorActionPreference = 'Stop'

& zig fmt --check build.zig src tests examples adapters
if ($LASTEXITCODE -ne 0) { throw 'zig fmt check failed' }

& git diff --check
if ($LASTEXITCODE -ne 0) { throw 'git diff check failed' }

& rg -n 'TODO|FIXME' src tests examples adapters include
if ($LASTEXITCODE -eq 0) { throw 'TODO or FIXME remains in release sources' }
if ($LASTEXITCODE -ne 1) { throw 'source policy scan failed' }

foreach ($dependency in @('deps/fund', 'deps/spindle')) {
    $dirty = & git -C $dependency status --porcelain
    if ($LASTEXITCODE -ne 0) { throw "cannot inspect $dependency" }
    if ($dirty) { throw "$dependency has uncommitted changes" }
}
