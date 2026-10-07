# Lampy for Windows

Lampy is a self-hosted forum stack with AI features: PostgreSQL + TimescaleDB,
Apache, Ollama (local LLM), Apache James (mail), code-server, pgAI vectorizer,
and the Flask forum app. This installer runs it on Windows via WSL2 —
no Docker required.

## Requirements

- Windows 10 version 2004+ or Windows 11 (64-bit)
- 30 GB free disk space (the install is ~25 GB)
- 8 GB RAM minimum, 16 GB recommended
- Administrator rights (for the install only)
- Internet access (for the initial download)

## Install

1. Download **install-v2.ps1** from this repo
   (or clone it).
2. Right-click PowerShell → **Run as administrator**.
3. Run:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
   .\install-v2.ps1 -ReleaseTag v2.0.0
   ```
4. The installer will prompt you for a password (typed twice, never echoed)
   for the Lampy services, then:
   - Download the Lampy system image (13 GB, in 14 chunks from
     GitHub Releases) — this takes a while on first run
   - Verify each chunk's SHA256 against the manifest; on re-run it skips
     verified chunks and re-downloads only corrupt or missing ones
   - Enable WSL2 if it isn't already (may ask you to reboot once, then re-run)
   - Import the Lampy system as a WSL distro
   - Download `build-database.sh` from the repo automatically
   - Compile PostgreSQL 16.10, TimescaleDB 2.17.2, pgvector 0.8.0, and
     pgvectorscale 0.9.1 from source (10–15 minutes)
   - Store your password in a locked file (600 permissions)
   - Start all services
   - Register Lampy to start automatically when Windows boots
5. When it finishes, open your browser:
   - Forum: http://localhost/app/
   - R Theory site: http://localhost/r-theory/
   - Bible site: http://localhost/bible/
   - code-server: http://localhost:8080/
   - Ollama: http://localhost:11434/

That's it. No Docker, no command line beyond the install commands, no
configuration.

> **Note:** If you already have the tarball locally (e.g. `lampy-new.tar`
> on disk), pass it directly to skip the download:
> ```powershell
> .\install-v2.ps1 -ReleaseTag v2.0.0 -TarballPath "C:\path\to\lampy-new.tar"
> ```

## What gets installed

- **Location:** `%LOCALAPPDATA%\Lampy\` (per-user install)
  - `wsl\` — the Lampy Linux system (WSL2 distro)
  - `download\` — downloaded image chunks (safe to delete after install)
- **WSL distro:** named `lampy` (see it with `wsl --list`)
- **Boot startup:** a Scheduled Task named `Lampy` starts all services at boot
- **Ports used:** 80 (web), 443 (https), 5432 (PostgreSQL), 8080 (code-server),
  11434 (Ollama), 2525/2465/2587/1143/1993/1110 (mail)

## Uninstall

```powershell
.\uninstall.ps1 -DistroName lampy -InstallDir "$env:LOCALAPPDATA\Lampy"
```

This stops the scheduled task, unregisters the WSL distro, and removes the
install directory.

## Troubleshooting

**Installer says "running scripts is disabled":**
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

**A chunk keeps failing hash verification:**
The installer re-downloads bad chunks automatically (one retry). If it loops,
the manifest hash may be stale — re-download `install-v2.ps1` to get the
latest manifest pointer.

**Services won't start after reboot:**
```powershell
wsl --shutdown
Start-ScheduledTask -TaskName "Lampy"
```

**Forum shows a database error:**
Check PostgreSQL is running:
```powershell
wsl -d lampy -u root -- supervisorctl -c /etc/supervisor/conf.d/lampy.conf status
```

## Building from source

See [BUILD.md](BUILD.md) for the full pipeline
(Docker image → WSL tarball → GitHub Releases chunks).

## Build status (2026-10-07)

- **Release `v2.0.0`: COMPLETE** — all 14 chunks of `lampy-new.tar`
  (13 GB) are on GitHub Releases, verified installable from scratch
  on a fresh Windows 11 install
- **Password-free rebuild** — no default password; installer prompts
  securely (typed twice, rejects `password`)
- **Installer verifies downloads** — `install-v2.ps1` checks each chunk's
  SHA256 against the manifest; on re-run it skips verified chunks
- **Database built from source** — PostgreSQL 16.10, TimescaleDB 2.17.2,
  pgvector 0.8.0, pgvectorscale 0.9.1, all compiled client-side

## Version

- Installer: 2.0.0
- System image: `lampy-new.tar` (13 GB, 14 chunks, released 2026-10-07)
