<#
.SYNOPSIS
    Lampy installer logic v2.0. Bundled into Lampy-Setup.exe, runs on the target machine.
.DESCRIPTION
    Installs the Lampy stack via WSL2 with client-side from-source database build:
      1. Prompts for a password (or accepts -Password for testing)
      2. Ensures WSL2 is enabled and set as default
      3. Downloads 14 chunks from GitHub Releases (kitcosby/lampy-installer)
      4. Verifies chunk hashes, assembles tarball, verifies tarball SHA
      5. Imports the lampy WSL distro from the tarball
      6. Runs build-database.sh: compiles PostgreSQL 16.10, TimescaleDB 2.17.2,
         pgvector 0.8.0, pgvectorscale 0.9.1 from staged sources (no apt/net/docker)
      7. Initializes PostgreSQL cluster, creates extensions
      7b. Sets up forum database (role, schema) and patches supervisor config
      8. Stores password in locked file (/root/.lampy-secrets, 600 perms)
      9. Configures supervisord for ollama/apache2/codeserver; postgres via pg_ctl
      10. Registers Scheduled Task for boot startup
      11. Verifies all services are responding
    Idempotent: safe to re-run. Runs per-user (no elevation needed).
#>
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Lampy",
    [string]$DistroName = "lampy",
    [string]$TarballPath = "",
    [string]$ReleaseTag = "",
    [string]$DownloadDir = "",
    [string]$InstallMode = "fresh",
    [string]$FallbackManifest = ""
)

$ErrorActionPreference = "Continue"

function Write-Step($msg) { Write-Output "`n=== $msg ===" }

$script:LogPath = $null
function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Write-Output $line
    if ($script:LogPath) { Add-Content -Path $script:LogPath -Value $line -ErrorAction SilentlyContinue }
}

# Password handling: always prompt securely, typed twice for confirmation, never echo.
# There is no default and no bypass flag.
$Password = ""
# Prompt twice securely and require match
$pw1 = $null; $pw2 = $null
try {
    $secPw1 = Read-Host -AsSecureString "Enter password for Lampy services"
    $bstr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPw1)
    try { $pw1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1) }

    $secPw2 = Read-Host -AsSecureString "Re-enter password to confirm"
    $bstr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPw2)
    try { $pw2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2) }

    if ($pw1 -cne $pw2) { throw "Passwords do not match. Please run the installer again." }
    $Password = $pw1
} finally {
    $pw1 = $null; $pw2 = $null; $secPw1 = $null; $secPw2 = $null
}
if ([string]::IsNullOrEmpty($Password)) { throw "Password is required." }
# Reject the well-known weak default
if ($Password -eq "password") {
    throw "The password 'password' is not allowed. Choose a stronger password."
}
Write-Output "Password accepted (not logged)."

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent() `
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Windows 11 floor check
$osv = [Environment]::OSVersion.Version
if ($osv.Major -lt 10 -or ($osv.Major -eq 10 -and $osv.Build -lt 22000)) {
    throw "Lampy requires Windows 11 or later. This PC runs Windows $($osv.Major) (build $($osv.Build))."
}
$virtFw = $null; $hypervisor = $null
try { $virtFw = (Get-CimInstance Win32_Processor -ErrorAction Stop).VirtualizationFirmwareEnabled }
catch { try { $virtFw = (Get-WmiObject Win32_Processor -ErrorAction Stop).VirtualizationFirmwareEnabled } catch {} }
try { $hypervisor = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent }
catch { try { $hypervisor = (Get-WmiObject Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch {} }
if (($virtFw -eq $false) -and ($hypervisor -ne $true)) {
    throw "This PC can't run WSL2: virtualization is unavailable. Enable VT-x/AMD-V in the firmware settings, then re-run."
}
Write-Output "Pre-flight OK: Windows 11 (build $($osv.Build)), virtualization available."

# Locate the tarball: explicit path, local file, or download from GitHub Releases
$tarball = $TarballPath
if (-not $tarball) {
    $localTar = Join-Path $PSScriptRoot "lampy-new.tar"
    if (Test-Path $localTar) {
        $tarball = $localTar
        Write-Output "Using local tarball: $tarball"
    }
}

function Get-ChunkResumable($url, $dest, $expectedSize) {
    $start = 0
    if (Test-Path $dest) { $start = (Get-Item $dest).Length }
    if ($expectedSize -and ($start -eq $expectedSize)) { return "already-complete" }
    if ($expectedSize -and ($start -gt $expectedSize)) {
        Write-Log "  Local file larger than expected ($start > $expectedSize); restarting from zero."
        $start = 0
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
    }
    if ($start -gt 0) { Write-Log "  Resuming $dest at $start / $expectedSize bytes..." }
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.UserAgent = "Lampy-Installer/2.0"
    $req.Timeout = 300000
    $req.ReadWriteTimeout = 1800000
    $req.AllowReadStreamBuffering = $false
    if ($start -gt 0) { $req.AddRange($start) }
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            $_.Exception.Response.Close()
            throw "HTTP $code downloading $url"
        }
        throw
    }
    try {
        $status = [int]$resp.StatusCode
        if ($status -ge 400) { throw "HTTP $status downloading $url" }
        if ($start -gt 0 -and $status -ne 206) {
            Write-Log "  Server did not honor resume (HTTP $status); restarting download from zero."
            $resp.Close()
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
            return Get-ChunkResumable $url $dest $expectedSize
        }
        $mode = if ($start -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
        $fs = New-Object System.IO.FileStream($dest, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream = $resp.GetResponseStream()
            $buf = New-Object byte[] 1048576
            $total = $start
            $lastReport = [DateTime]::UtcNow
            while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                $fs.Write($buf, 0, $n)
                $total += $n
                if (([DateTime]::UtcNow - $lastReport).TotalSeconds -ge 15) {
                    if ($expectedSize) { $pct = [math]::Round(100.0 * $total / $expectedSize, 1); Write-Log "  $total / $expectedSize bytes ($pct%)" }
                    else { Write-Log "  $total bytes..." }
                    $lastReport = [DateTime]::UtcNow
                }
            }
        } finally { $fs.Close() }
        return "downloaded"
    } finally { $resp.Close() }
}

function Get-ChunkWithRetry($url, $dest, $expectedSize) {
    for ($a = 1; $a -le 3; $a++) {
        try {
            return Get-ChunkResumable $url $dest $expectedSize
        } catch {
            $etype = $_.Exception.GetType().FullName
            Write-Log "  download attempt $a/3 failed [$etype]: $($_.Exception.Message)"
            if ($a -eq 3) { throw "Download failed after 3 attempts: $url" }
            Write-Log "  waiting 10s, then resuming where it stopped..."
            Start-Sleep -Seconds 10
        }
    }
}

# Manifest-driven download
$repairSkipDownload = ($InstallMode -eq "repair") -and (wsl --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $DistroName })
if ($repairSkipDownload) {
    Write-Output "Repair mode: distro '$DistroName' exists; skipping image download."
    $tarball = "SKIP"
}
if (-not $tarball) {
    Write-Step "Downloading Lampy system image (14 chunks)"
    if ([string]::IsNullOrEmpty($DownloadDir)) { $dlDir = Join-Path $InstallDir "download" } else { $dlDir = $DownloadDir }
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    $script:LogPath = Join-Path $dlDir "install.log"

    Write-Log "=== Lampy installer v2.0 run ==="
    Write-Log "Environment: PowerShell $($PSVersionTable.PSVersion) / OS $([Environment]::OSVersion.VersionString)"
    Write-Log "InstallDir=$InstallDir DownloadDir=$dlDir Mode=$InstallMode"

    # Manifest from kitcosby (Hotmail account) releases
    $manifest = $null; $manifestSource = ""; $wantTag = $ReleaseTag
    if ([string]::IsNullOrEmpty($wantTag)) {
        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/kitcosby/lampy-installer/releases/latest" -UseBasicParsing -TimeoutSec 30
            $wantTag = $rel.tag_name
            Write-Log "Latest installer release via public API: $wantTag"
        } catch { Write-Log "GitHub API unreachable ($($_.Exception.Message)); trying cached/bundled manifest." }
    } else { Write-Log "Release override: $wantTag" }
    if ($wantTag) {
        $murl = "https://raw.githubusercontent.com/kitcosby/lampy-installer/$wantTag/manifest.json"
        try {
            $resp = Invoke-WebRequest -Uri $murl -UseBasicParsing -TimeoutSec 30
            $manifest = $resp.Content | ConvertFrom-Json
            $manifestSource = "network ($murl)"
        } catch { Write-Log "Manifest fetch failed: $murl ($($_.Exception.Message))" }
    }
    $cachedManifest = Join-Path $dlDir "manifest.json"
    if (-not $manifest -and (Test-Path $cachedManifest)) {
        try { $manifest = Get-Content $cachedManifest -Raw | ConvertFrom-Json; $manifestSource = "cache ($cachedManifest)" }
        catch { Write-Log "Cached manifest is corrupt; ignoring." }
    }
    if (-not $manifest -and $FallbackManifest -and (Test-Path $FallbackManifest)) {
        $manifest = Get-Content $FallbackManifest -Raw | ConvertFrom-Json
        $manifestSource = "bundled fallback"
    }
    if (-not $manifest) { throw "No manifest available: network, cache, and bundled fallback all failed." }
    $manifestVersion = if ($manifest.version) { $manifest.version } else { $manifest.data_release }
    Write-Log "Manifest source: $manifestSource | version: $manifestVersion"

    # Normalize chunks: v2 manifest uses `file` for the chunk filename (v1 used `name`)
    $rawChunks = @($manifest.chunks)
    if ($rawChunks.Count -eq 0) { throw "Manifest has no chunks." }
    $chunks = @()
    foreach ($c in $rawChunks) {
        $fname = if ($c.file) { [string]$c.file } elseif ($c.name) { [string]$c.name } else { $null }
        if (-not $fname) { throw "Manifest chunk entry is missing its file/name key." }
        $chunks += [pscustomobject]@{
            FileName = $fname
            Size     = [long]$c.size
            Sha256   = if ($c.sha256) { "$($c.sha256)".ToLower() } else { $null }
        }
    }
    $baseUrl = $manifest.base_url
    # v2 manifest drops the tarball{} block: derive tarball name/size from the chunks
    if ($manifest.tarball -and $manifest.tarball.name) {
        $tarballName = [string]$manifest.tarball.name
        $tarballSize = [long]$manifest.tarball.size
        $tarballHash = $manifest.tarball.sha256
    } else {
        # chunk files look like "lampy-new.tar.part-aa" -> tarball "lampy-new.tar"
        $tarballName = $chunks[0].FileName -replace '\.part-[a-z]{2}$',''
        if (-not $tarballName -or $tarballName -eq $chunks[0].FileName) {
            throw "Cannot derive tarball name from chunk file '$($chunks[0].FileName)'."
        }
        $tarballSize = [long]($chunks | Measure-Object -Property Size -Sum).Sum
        $tarballHash = $null
        Write-Log "Manifest has no tarball block; derived tarball $tarballName ($tarballSize bytes) from $($chunks.Count) chunks."
    }
    Write-Log "$($chunks.Count) chunks, tarball $($tarballName) ($tarballSize bytes)."

    $tarball = Join-Path $dlDir $tarballName

    function Test-Tarball($path) {
        if (-not (Test-Path $path)) { return $false }
        if ((Get-Item $path).Length -ne $tarballSize) {
            Write-Log "Collated tarball wrong size ($((Get-Item $path).Length)/$tarballSize); will rebuild from chunks."
            return $false
        }
        if ($tarballHash) {
            Write-Log "Verifying collated tarball SHA256 (this takes a while)..."
            $actual = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $tarballHash) {
                Write-Log "Collated tarball FAILED hash check; will rebuild from chunks."
                return $false
            }
            Write-Log "Collated tarball hash OK."
        }
        return $true
    }

    if (-not (Test-Tarball $tarball)) {
        if (Test-Path $tarball) { Write-Log "Removing invalid tarball."; Remove-Item $tarball -Force }

        $i = 0
        $needDownload = @()
        foreach ($c in $chunks) {
            $i++
            $dest = Join-Path $dlDir $c.FileName
            $have = 0
            if (Test-Path $dest) { $have = (Get-Item $dest).Length }
            $want = [long]$c.Size
            if ($have -eq $want) {
                Write-Log "Chunk $i/$($chunks.Count): $($c.FileName) already complete, skipping."
            } else {
                Write-Log "Chunk $i/$($chunks.Count): $($c.FileName) missing/partial - will download."
                $needDownload += $c
            }
        }

        $i = 0
        foreach ($c in $needDownload) {
            $i++
            Write-Log "Downloading chunk $i/$($needDownload.Count): $($c.FileName)"
            Get-ChunkWithRetry "$baseUrl/$($c.FileName)" (Join-Path $dlDir $c.FileName) ([long]$c.Size) | Out-Null
        }

        $attempt = 0
        do {
            $attempt++
            $bad = @()
            foreach ($c in $chunks) {
                $dest = Join-Path $dlDir $c.FileName
                $want = [long]$c.Size
                $ok = (Test-Path $dest) -and ((Get-Item $dest).Length -eq $want)
                if ($ok -and $c.Sha256) {
                    $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToLower()
                    if ($actual -ne $c.Sha256) {
                        Write-Log "  $($c.FileName) FAILED hash check; will re-download."
                        $ok = $false
                    }
                }
                if (-not $ok) { $bad += $c }
            }
            foreach ($c in $bad) {
                $dest = Join-Path $dlDir $c.FileName
                Write-Log "Re-downloading $($c.FileName) ..."
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
                Get-ChunkWithRetry "$baseUrl/$($c.FileName)" $dest ([long]$c.Size) | Out-Null
            }
        } while ($bad.Count -gt 0 -and $attempt -lt 2)
        if ($bad.Count -gt 0) { throw "Chunk verification failed after re-download." }
        Write-Log "All $($chunks.Count) chunks verified."

        Write-Log "Reassembling tarball..."
        $outStream = [System.IO.File]::Create($tarball)
        try {
            foreach ($c in $chunks) {
                $inStream = [System.IO.File]::OpenRead((Join-Path $dlDir $c.FileName))
                try { $inStream.CopyTo($outStream) } finally { $inStream.Close() }
            }
        } finally { $outStream.Close() }
        Write-Log "Tarball reassembled: $tarball"
        if (-not (Test-Tarball $tarball)) { throw "Reassembled tarball failed validation." }
    } else {
        Write-Log "Tarball already downloaded and verified: $tarball"
    }
}
if ($tarball -ne "SKIP" -and -not (Test-Path $tarball)) { throw "Tarball not found: $tarball" }

Write-Step "1/6 Ensuring WSL2 is available"
$wslOk = $false
try {
    $wslList = wsl --list --verbose 2>&1
    $wslOk = ($LASTEXITCODE -eq 0)
} catch { $wslOk = $false }
if (-not $wslOk) {
    if (-not $isAdmin) {
        throw "WSL is not installed. Re-run this installer once AS ADMINISTRATOR to enable WSL, then re-run it normally."
    }
    Write-Output "Enabling WSL..."
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    Write-Output "WSL enabled. A reboot is required, then re-run the installer."
    exit 2
}
wsl --set-default-version 2 | Out-Null

Write-Step "2/6 Importing lampy WSL distro"
$wslDir = Join-Path $InstallDir "wsl"
New-Item -ItemType Directory -Force -Path $wslDir | Out-Null
$existing = wsl --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $DistroName }
if ($InstallMode -eq "repair" -and $existing) {
    Write-Output "Repair mode: distro '$DistroName' already registered -- skipping import."
} else {
    if ($existing) {
        Write-Warning "A WSL distro named '$DistroName' is already registered."
        $ans = Read-Host "Unregister it and import fresh? ALL DATA inside it will be DELETED. Type YES (all caps) to confirm"
        if ($ans -cne "YES") { throw "Installation cancelled; existing distro left untouched." }
        Write-Output "Unregistering '$DistroName'..."
        wsl --unregister $DistroName
        if ($LASTEXITCODE -ne 0) { throw "wsl --unregister failed" }
    }
    wsl --import $DistroName $wslDir $tarball
    if ($LASTEXITCODE -ne 0) { throw "wsl --import failed" }
    Write-Output "Distro '$DistroName' imported."
}

Write-Step "2b/6 Refreshing Bible website from GitHub (Kit 2026-10-07)"
# The base image predates the interlinear page. Fetch the latest website
# files from cosbykit-afk/bible-project so fresh installs get the current
# version (interlinear, papyrus theme, variant fixes).
$bibleBase = "https://raw.githubusercontent.com/kitcosby/bible-project/master/website"
$bibleFiles = @("app_v2.py", "papyrus-tile.png")
$tmpDir = Join-Path $env:TEMP "lampy-bible-refresh"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
foreach ($f in $bibleFiles) {
    $url = "$bibleBase/$f"
    $dest = Join-Path $tmpDir $f
    Write-Output "Downloading $url ..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 60
    } catch {
        throw "Failed to download Bible website file $f : $($_.Exception.Message)"
    }
}
# Copy into the distro via /mnt/c (binary-safe, no encoding issues)
$wslTmp = $tmpDir -replace '^([A-Za-z]):', '/mnt/$1' -replace '\\', '/'
$wslTmp = $wslTmp.ToLower()
foreach ($f in $bibleFiles) {
    wsl -d $DistroName -u root -- bash -c "cp '$wslTmp/$f' /opt/bible/website/$f"
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy $f into distro" }
}
Write-Output "Bible website refreshed from GitHub."

Write-Step "3/6 Building database from source (PostgreSQL, TimescaleDB, pgvector, pgvectorscale)"
# Copy build-database.sh into the distro and run it. This compiles everything
# from /opt/stage/ sources with no apt, no network, no Docker.
$buildScript = Join-Path $PSScriptRoot "build-database.sh"
if (-not (Test-Path $buildScript)) {
    # Fetch from the repo (same tag as the manifest) so a lone install-v2.ps1 works
    $buildUrl = "https://raw.githubusercontent.com/kitcosby/lampy-installer/$wantTag/build-database.sh"
    Write-Output "build-database.sh not found locally; downloading from $buildUrl ..."
    try {
        Invoke-WebRequest -Uri $buildUrl -OutFile $buildScript -UseBasicParsing -TimeoutSec 60
    } catch {
        throw "build-database.sh not found at $buildScript and download failed: $($_.Exception.Message)"
    }
    if (-not (Test-Path $buildScript)) { throw "build-database.sh download failed silently." }
    Write-Output "Downloaded build-database.sh."
}
Write-Output "Copying build script into distro..."
Get-Content -Path $buildScript -Raw | wsl -d $DistroName -u root -- bash -c "cat > /usr/local/bin/build-database.sh && chmod +x /usr/local/bin/build-database.sh"
if ($LASTEXITCODE -ne 0) { throw "Failed to copy build-database.sh into distro" }

Write-Output "Compiling database stack from source (this takes 10-15 minutes)..."
# Run the build directly (blocking). WSL kills backgrounded processes when the
# wsl session exits, so nohup & does NOT work here. The script writes progress
# to /tmp/db-build.log which we tail in a separate monitoring loop is not needed;
# we just wait for the blocking call to return.
# To show progress, we run the build in a PowerShell job and poll the log.
$buildJob = Start-Job -ScriptBlock {
    param($distro)
    wsl -d $distro -u root -- bash -c "/usr/local/bin/build-database.sh > /tmp/db-build.log 2>&1; echo EXITCODE=$? >> /tmp/db-build.log"
} -ArgumentList $DistroName
$dbBuildTimeout = 1800  # 30 minutes max
$dbBuildElapsed = 0
$dbBuildDone = $false
while ($dbBuildElapsed -lt $dbBuildTimeout) {
    Start-Sleep -Seconds 30
    $dbBuildElapsed += 30
    $jobState = (Get-Job -Id $buildJob.Id).State
    if ($jobState -eq "Completed") {
        # Job finished - verify it actually succeeded by checking the log
        $logTail = wsl -d $DistroName -u root -- bash -c "tail -5 /tmp/db-build.log 2>/dev/null" 2>$null
        if ($logTail -match "DATABASE BUILD COMPLETE") {
            $dbBuildDone = $true
            break
        } else {
            Write-Output "Database build job completed but did not report success. Log tail:"
            Write-Output $logTail
            throw "Database build failed (no COMPLETE marker). See /tmp/db-build.log in the distro."
        }
    }
    if ($jobState -eq "Failed") {
        $logTail = wsl -d $DistroName -u root -- bash -c "tail -20 /tmp/db-build.log 2>/dev/null" 2>$null
        Write-Output "Database build job failed. Log tail:"
        Write-Output $logTail
        throw "Database build failed. See /tmp/db-build.log in the distro."
    }
    $logTail = wsl -d $DistroName -u root -- bash -c "tail -3 /tmp/db-build.log 2>/dev/null" 2>$null
    if ($logTail -match "DATABASE BUILD COMPLETE") { $dbBuildDone = $true; break }
    if ($logTail -match "FATAL|FAILED") {
        Write-Output "Database build log tail:"
        Write-Output $logTail
        throw "Database build failed. See /tmp/db-build.log in the distro."
    }
    Write-Output "  Building... ($dbBuildElapsed s elapsed)"
}
if (-not $dbBuildDone) { throw "Database build timed out after $dbBuildTimeout seconds." }
Write-Output "Database build complete."

# Verify extensions
Write-Output "Verifying PostgreSQL extensions..."
$extCheck = wsl -d $DistroName -u postgres -- /usr/local/pgsql/bin/psql -d forum -t -c "SELECT name FROM pg_extension WHERE name IN ('timescaledb','vector','vectorscale');" 2>$null
if ($extCheck -notmatch "timescaledb" -or $extCheck -notmatch "vector" -or $extCheck -notmatch "vectorscale") {
    throw "Extension verification failed. Got: $extCheck"
}
Write-Output "Extensions verified: timescaledb, vector, vectorscale."

Write-Step "3b/6 Setting up forum (database role, schema, supervisor)"
# The base image has /opt/forum but the v2 installer was missing:
#   - [program:forum] in the supervisor config
#   - [supervisorctl]/[rpcinterface] sections (supervisorctl was broken)
#   - the 'forum' PostgreSQL role and schema
#   - FORUM_DB_PASS / FORUM_SECRET_KEY environment variables
# setup-forum-v2.py does all of this idempotently (Kit 2026-10-07).
$forumScript = Join-Path $PSScriptRoot "setup-forum-v2.py"
if (-not (Test-Path $forumScript)) {
    $forumUrl = "https://raw.githubusercontent.com/kitcosby/lampy-installer/$wantTag/setup-forum-v2.py"
    Write-Output "setup-forum-v2.py not found locally; downloading from $forumUrl ..."
    try {
        Invoke-WebRequest -Uri $forumUrl -OutFile $forumScript -UseBasicParsing -TimeoutSec 60
    } catch {
        throw "setup-forum-v2.py not found at $forumScript and download failed: $($_.Exception.Message)"
    }
    if (-not (Test-Path $forumScript)) { throw "setup-forum-v2.py download failed silently." }
    Write-Output "Downloaded setup-forum-v2.py."
}
Write-Output "Copying forum setup script into distro..."
Get-Content -Path $forumScript -Raw | wsl -d $DistroName -u root -- bash -c "cat > /usr/local/bin/setup-forum-v2.py && chmod +x /usr/local/bin/setup-forum-v2.py"
if ($LASTEXITCODE -ne 0) { throw "Failed to copy setup-forum-v2.py into distro" }
Write-Output "Running forum setup (creates role, loads schema, patches supervisor)..."
wsl -d $DistroName -u root -- python3 /usr/local/bin/setup-forum-v2.py
if ($LASTEXITCODE -ne 0) { throw "Forum setup failed. See output above." }
Write-Output "Forum setup complete."

Write-Step "4/6 Storing password in locked file"
# Password lives in /root/.lampy-secrets (600, root only). Never in config files.
$pwB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Password))
$pwScript = @"
import base64, os
pw = base64.b64decode('$pwB64').decode('utf-8')
with open('/root/.lampy-secrets', 'w') as f:
    f.write(pw)
os.chmod('/root/.lampy-secrets', 0o600)
print('Password stored in locked file.')
"@
$pwScript | wsl -d $DistroName -u root python3
if ($LASTEXITCODE -ne 0) { throw "Failed to store password" }
$Password = $null; $pwB64 = $null; $pwScript = $null
Write-Output "Password stored (not logged)."

Write-Step "5/6 Registering boot startup (Task Scheduler)"
$taskName = "Lampy"
$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d $DistroName -u root /usr/local/bin/lampy-boot.sh keepalive"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
if ($isAdmin) {
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
} else {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
}
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "Scheduled task '$taskName' registered."

Write-Step "6/6 Starting Lampy and verifying"
wsl -d $DistroName -u root -- supervisorctl -c /etc/supervisor/conf.d/lampy.conf shutdown 2>$null | Out-Null
Start-Sleep -Seconds 10
wsl -d $DistroName -u root /usr/local/bin/lampy-boot.sh
Write-Output "Waiting for services to boot..."
Start-Sleep -Seconds 60

# Start PostgreSQL (separate from supervisord)
Write-Output "Starting PostgreSQL..."
wsl -d $DistroName -u postgres -- /usr/local/pgsql/bin/pg_ctl -D /var/lib/postgresql/data -l /tmp/pg-server.log start 2>$null
Start-Sleep -Seconds 10

$checks = @(
    @{ Name = "PostgreSQL"; Cmd = "wsl -d $DistroName -u postgres /usr/local/pgsql/bin/pg_isready" },
    @{ Name = "Apache";     WslUrl = "http://localhost:80/" },
    @{ Name = "Ollama";     WslUrl = "http://localhost:11434/" },
    @{ Name = "Bible";      WslUrl = "http://localhost:5057/" },
    @{ Name = "Forum";      WslUrl = "http://localhost:8000/" }
)
$failed = 0
foreach ($c in $checks) {
    $ok = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($c.Cmd) {
            Invoke-Expression $c.Cmd | Out-Null
            $ok = $LASTEXITCODE -eq 0
        } else {
            $code = wsl -d $DistroName -- curl -s -o /dev/null -w '%{http_code}' $c.WslUrl --max-time 10 2>$null
            $ok = $code -eq "200"
        }
        if ($ok) { break }
        if ($attempt -lt 3) {
            Write-Output ("  {0}: attempt {1} failed, retrying in 15s..." -f $c.Name, $attempt)
            Start-Sleep -Seconds 15
        }
    }
    if ($ok) { $status = "OK" } else { $status = "FAILED"; $failed++ }
    Write-Output ("  {0}: {1}" -f $c.Name, $status)
}

if ($failed -gt 0) {
    Write-Warning "$failed service check(s) failed. See output above."
    exit 1
}
Write-Output "`nLampy v2.0 installed and running."
Write-Output "Home:    http://localhost/"
Write-Output "Forum:   http://localhost/app/"
Write-Output "Bible:   http://localhost/bible/"
Write-Output "R Theory: http://localhost/r-theory/"
Write-Output "Ollama:  http://localhost:11434/"
