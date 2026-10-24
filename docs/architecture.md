Living document — update these diagrams when adding features.
# lampy-installer — Architecture

Windows installer for the Lampy WSL stack. The repo holds the PowerShell install/uninstall scripts, the NSIS wrapper definitions, the chunk manifest, and build-time helpers. It has no runtime application of its own: `install.ps1` is the product, and it performs a one-shot install of the Lampy system image as a WSL2 distro named `lampy`, then configures it and registers a Windows boot task.

**2026-10-24 revision — installer v2 is now the production installer.** `install-v2.ps1` (added 2026-10-05, README rewritten for v2.0.0 on 2026-10-07) supersedes the v1 flow described in sections 1–2 for fresh installs: 14 chunks under the v2 manifest shape, a password prompted securely twice with no default and no bypass flag, a client-side from-source database build (`build-database.sh`), forum setup (`setup-forum-v2.py`), and a Bible-website refresh fetched from `kitcosby/bible-project`. The v1 processes are retained below because `install.ps1` remains in the repo; the v2-only processes are numbered 9.0–11.0 in the DFD, and the ERD now describes the v2 manifest.

The install is **per-user**: no elevation is required. Elevation matters only for the one-time WSL feature enablement (if WSL is missing, the script throws and tells the user to re-run once as administrator, enable WSL, reboot, and re-run normally). When run elevated, the boot task is registered at-startup as SYSTEM (previous behavior); the normal per-user path registers an at-logon task as the installing user. WSL distros are per-user (registered under HKCU), so an elevated SYSTEM task would not see the user's distro.

## 1. Context diagram (level 0)

```mermaid
flowchart
    E1["End user on Windows"]
    E2["GitHub (Releases, API, raw content)"]
    E3["Windows OS (WSL, Task Scheduler)"]
    E4["kitcosby/bible-project repository"]

    subgraph SYS["Lampy installer — system boundary"]
        S("0 Lampy installer")
    end

    E1 -->|"install parameters (InstallDir, DistroName, TarballPath, InstallMode)"| S
    S -->|"progress output, install.log, and generated passwords (shown once)"| E1
    E1 -->|"uninstall request with YES confirmation"| S
    S -->|"uninstall progress"| E1
    S -->|"latest-release tag query (public API)"| E2
    E2 -->|"latest installer release tag"| S
    S -->|"manifest.json fetch (network, cache, or bundled fallback)"| E2
    E2 -->|"manifest with 14 chunk descriptors (v2) or 7 chunk descriptors (v1)"| S
    S -->|"chunk download requests (HTTP Range resume, 3 retries)"| E2
    E2 -->|"image chunks (14 in v2, 7 in v1)"| S
    S -->|"Bible website file requests (app_v2.py, papyrus-tile.png)"| E4
    E4 -->|"current Bible website files"| S
    S -->|"distro import / unregister requests"| E3
    E3 -->|"distro registration state"| S
    S -->|"WSL feature-enablement request (dism, admin only)"| E3
    E3 -->|"WSL availability"| S
    S -->|"boot-task registration / removal request"| E3
    E3 -->|"task registration state"| S
    S -->|"boot-script start request and service-probe commands"| E3
    E3 -->|"service probe results"| S
```

## 2. Level-1 data flow diagram

```mermaid
flowchart
    E1["End user on Windows"]
    E2["GitHub (Releases, API, raw content)"]
    E3["Windows OS (WSL, Task Scheduler)"]
    P1("1.0 Check pre-flight requirements")
    P2("2.0 Fetch chunk manifest")
    P3("3.0 Download, verify, and reassemble image")
    P4("4.0 Import lampy WSL distro")
    P5("5.0 Configure services inside WSL")
    P6("6.0 Register boot task")
    P7("7.0 Start and verify services")
    P8("8.0 Uninstall Lampy")
    P9("9.0 Build database from source (v2)")
    P10("10.0 Set up forum database (v2)")
    P11("11.0 Refresh Bible website (v2)")
    D1[("D1 Download cache")]
    D2[("D2 Lampy WSL distro")]
    D3[("D3 Locked-down secrets files in distro")]
    E1 -->|"install request with parameters"| P1
    P1 -->|"WSL availability probe"| E3
    E3 -->|"WSL availability"| P1
    P1 -->|"fatal error message"| E1
    P1 -->|"WSL enablement command (dism)"| E3
    P1 -->|"pre-flight OK with parameters and skip flags"| P2
    P2 -->|"release tag and manifest requests"| E2
    E2 -->|"release tag and manifest.json"| P2
    P2 -->|"manifest copy"| D1
    P2 -->|"chunk descriptors or SKIP"| P3
    P3 -->|"chunk download requests (HTTP Range resume)"| E2
    E2 -->|"chunk bytes"| P3
    D1 -->|"partial chunk lengths (resume inventory)"| P3
    P3 -->|"chunk files"| D1
    P3 -->|"reassembled tarball"| D1
    P3 -->|"install.log entries"| D1
    P3 -->|"verified tarball or SKIP"| P4
    P4 -->|"distro list query"| E3
    E3 -->|"distro registration state"| P4
    P4 -->|"data-deletion warning"| E1
    E1 -->|"YES confirmation"| P4
    P4 -->|"wsl --import and wsl --unregister commands"| E3
    P4 -->|"imported distro"| D2
    P4 -->|"imported or existing distro"| P5
    P5 -->|"boot-file version check"| D2
    D2 -->|"existing boot-file version"| P5
    P5 -->|"wsl-envfix.py invocation"| D2
    P5 -->|"password prompts"| E1
    E1 -->|"typed passwords"| P5
    P5 -->|"generated passwords (shown once)"| E1
    P5 -->|"supervisor config updates and ALTER ROLE"| D2
    P5 -->|"configured distro"| P6
    P6 -->|"task registration commands"| E3
    E3 -->|"task registration state"| P6
    P6 -->|"task registration notice"| E1
    P6 -->|"boot task and distro handle"| P7
    P7 -->|"lampy-boot.sh start"| D2
    P7 -->|"probe commands (pg_isready, curl)"| D2
    D2 -->|"probe results"| P7
    P7 -->|"ready URLs"| E1
    P7 -->|"service-check failure (exit 1)"| E1
    P4 -->|"imported distro with staged sources"| P9
    P9 -->|"build-database.sh fetch when not bundled"| E2
    E2 -->|"build-database.sh script"| P9
    P9 -->|"compiled PostgreSQL and extensions, initialized cluster"| D2
    P9 -->|"built database stack"| P10
    P10 -->|"setup-forum-v2.py fetch when not bundled"| E2
    E2 -->|"setup-forum-v2.py script"| P10
    P10 -->|"forum role, schema, and supervisor program"| D2
    P10 -->|"forum secrets (600, root only)"| D3
    P5 -->|"service password (typed twice, v2)"| D3
    P10 -->|"forum configured"| P11
    P11 -->|"Bible website file requests"| E4
    E4 -->|"app_v2.py and papyrus-tile.png files"| P11
    P11 -->|"refreshed website files in /opt/bible/website"| D2
    P11 -->|"configured distro"| P6
    E1 -->|"uninstall request"| P8
    P8 -->|"uninstall warning"| E1
    E1 -->|"YES confirmation"| P8
    P8 -->|"task command-line check"| E3
    E3 -->|"task command line"| P8
    P8 -->|"stop and unregister task (only if -d DistroName matches)"| E3
    P8 -->|"wsl --unregister command"| E3
    P8 -->|"install directory removal"| D1
    P8 -->|"uninstall progress"| E1
```

## 3. Entity–relationship diagram

No persistent application data model was observed: the repo has no schema, migration, model file, or config table — only scripts, manifests, and NSIS definitions. The only structured data definition in the repo is the chunk manifest, a download descriptor. This ERD describes that file's structure, not a managed data model. Runtime state (the WSL virtual disk, the scheduled task) lives in Windows/WSL, outside the repo.

```mermaid
erDiagram
    MANIFEST {
        string base_url
        string version PK
    }
    CHUNK {
        string file PK
        string manifest_version FK
        string sha256
        int size
    }
    TARBALL {
        string name PK
        string manifest_version FK
        int derived_size
    }
    MANIFEST ||--o{ CHUNK : lists
    MANIFEST ||--|| TARBALL : describes
```

## Grounding notes

- OBSERVED (install.ps1, repo main HEAD `237e12d` v1.1.10): runs per-user with no elevation (line 11: "Runs per-user (no elevation needed)"); elevation is only for the one-time WSL feature enablement. Pre-flight fails fast on OS floor (Windows 11 = Major 10 build 22000+, floor not exact match) and on missing virtualization (VT-x/AMD-V or hypervisor); if WSL is missing and the user is not admin it throws asking for one admin re-run, else it enables WSL via dism and exits 2 (reboot, re-run).
- OBSERVED (install.ps1): repair mode (`-InstallMode repair`) with the distro already registered sets `$tarball = "SKIP"` and skips the image download entirely (Kit-verified test G009); fresh mode (`G007`) starts the download; import skips when the distro is registered in repair mode, and a fresh install over an existing distro asks `YES (all caps)` before `wsl --unregister` — it never silently destroys a distro (the v1.1.2 wipe is named in a comment as the bug this guards).
- OBSERVED (install.ps1): manifest discovery tries, in order, the public GitHub releases API for the latest tag, `raw.githubusercontent.com/<tag>/manifest.json`, the cached `<DownloadDir>/manifest.json`, then the `-FallbackManifest` bundle; aborts when all fail.
- OBSERVED (install.ps1): chunk download uses `System.Net.HttpWebRequest` with `AddRange` resume (deliberately not HttpClient — v1.1.1 comment: some machines cannot load that assembly), 3 attempts per chunk, 10 s between retries, progress every 15 s; a legacy `C:\Lampy\download` one-time migration shim moves matching chunks to the new download dir.
- OBSERVED (install.ps1): verification checks every chunk's byte size, then SHA256; a bad chunk is deleted and re-downloaded once, and a second failure aborts ("Good chunks are NEVER deleted"); the tarball is reassembled by concatenating chunks in manifest order and re-validated by size and SHA256 before use.
- OBSERVED (install.ps1): step 3 runs `wsl-envfix.py` (piped to `python3` inside the distro) only when the distro's `LAMPY_BOOT_VERSION` is below the script's `BOOT_VERSION`; passwords are collected with `Read-Host -AsSecureString` (postgres, forum, code-server; empty = generate random unambiguous or disable code-server), applied via `set-passwords.py` over stdin as base64 JSON (never logged or on a command line), and synced to PostgreSQL roles with `ALTER ROLE` via stdin psql; generated passwords are printed once.
- OBSERVED (install.ps1): step 4 registers the scheduled task `Lampy` running `wsl.exe -d <DistroName> -u root /usr/local/bin/lampy-boot.sh keepalive`, with `-Force` on re-register (fix for step-4 re-run failure); elevated runs register at-startup as SYSTEM, per-user runs register at-logon as the installing user.
- OBSERVED (install.ps1): step 5 shuts down any old supervisord, runs `lampy-boot.sh`, waits 60 s, then probes PostgreSQL (`pg_isready`), Apache `/`, forum `/app/`, Ollama `/api/tags`, and code-server `/` (only when enabled) — each up to 3 attempts 15 s apart, verified **from inside WSL** (comment: Windows→WSL localhost forwarding is unreliable, verified broken on Toetop 2026-09-28 — never `Invoke-WebRequest http://localhost/` from Windows); exits 1 when any check fails; prints the ready URLs.
- OBSERVED (uninstall.ps1): per-user, asks `YES (all caps)` before deleting; removes the scheduled task only when its action's command line matches `-d <DistroName>` (the v1.1.10 task-safety fix — a task for a different distro is left alone; Kit-verified test G011); then `wsl --unregister`, then removes the install dir.
- OBSERVED (manifest.json): `base_url` `https://github.com/cosbykit-afk/lampy-installer/releases/download/v1.0.0`, `data_release` `v1.0.0`, 7 chunks `lampy-public.tar.part-aa`..`part-ag` (each with `name`, `sha256`, `size`; six are 1,887,436,800 bytes, the last 228,433,920), and `tarball` `{name: lampy-public.tar, sha256: f6f71015…, size: 11553054720}` (11,553,054,720 bytes ≈ 11.6 GB decimal / 10.8 GiB). `lampy-public.tar.full.sha256` carries the same tarball hash.
- OBSERVED (lampy-slim.nsi): the current wrapper — `PRODUCT_VERSION "1.1.10"`, `RequestExecutionLevel user`, `InstallDir $LOCALAPPDATA\Lampy`, permanent `DOWNLOAD_DIR $LOCALAPPDATA\Lampy\download`; bundles exactly `install.ps1`, `uninstall.ps1`, `manifest.json`, `wsl-envfix.py`, `set-passwords.py`; detects an existing virtual disk and offers Yes=Reinstall / No=Repair / Cancel; runs install.ps1 via `nsExec::ExecToLog` with `-InstallMode`; writes per-user Start Menu shortcuts and an HKCU uninstall registry entry. The older `lampy.nsi` (PRODUCT_VERSION 1.0.0, `RequestExecutionLevel admin`, 30 GB single-file payload) is superseded.
- OBSERVED (verify-bundle.py): build-time guard that parses install.ps1/uninstall.ps1 for every `Join-Path $PSScriptRoot "<name>"` reference and asserts each file is in the staging dir and the NSIS `File` list — the check that would have caught v1.1.1 shipping without `wsl-envfix.py`.
- OBSERVED (set-passwords.py): reads JSON from the `__CONFIG_B64__` placeholder (base64, filled by install.ps1 before piping over stdin); writes each password as exactly one `environment=` line in its supervisor program section.
- OBSERVED (wsl-envfix.py): `BOOT_VERSION = 2`; idempotent WSL adaptations (postgres PATH/PGDATA, supervisor RPC sections, boot script); password-related environment is owned by set-passwords.py, not this script.
- INFERRED: the DFD groups the scripts' linear numbered phases into 8 processes; the grouping is my synthesis. Install parameters (`InstallDir`, `DistroName`, `TarballPath`, `ReleaseTag`, `DownloadDir`, `InstallMode`, `FallbackManifest`) are the process inputs.
- INFERRED: the "End user on Windows" runs the NSIS `Lampy-Setup.exe` GUI or the raw scripts; the NSIS choice dialog maps to `-InstallMode fresh|repair|reinstall`.
- OBSERVED (`install-v2.ps1` header, commits e89bbf74 / c51d82bf / dfb0f202, 2026-10-05/06): v2.0 flow in 11 steps — secure typed-twice password prompt (no default, no bypass flag; the well-known weak default is rejected), WSL2 enablement, download of 14 chunks from GitHub Releases (`kitcosby/lampy-installer`), chunk-hash and assembled-tarball verification, distro import, `build-database.sh` database build, cluster init and extensions, forum setup (step 7b), password stored in the locked file `/root/.lampy-secrets` (600), supervisord configuration (postgres via `pg_ctl`), boot Scheduled Task registration, and service verification. Idempotent, per-user.
- OBSERVED (`manifest.json` at HEAD, v2.0.0): `{base_url: https://github.com/kitcosby/lampy-installer/releases/download/v2.0.0, version: v2.0.0, chunks: 14 entries}` — each chunk uses the `file` key (`lampy-new.tar.part-aa` … `part-an`, 943,718,400 bytes each except the last at 827,123,712) with `sha256` and `size`; there is NO `tarball` block — install-v2 derives the tarball name (`lampy-new.tar`) and size from the chunk list (Option B parser, commit dfb0f202). This supersedes the v1 manifest shape (7 chunks, `name` key, explicit tarball block) described in the older bullet below.
- OBSERVED (`build-database.sh`, commit abc51f75, 2026-10-07): client-side from-source build with no network, apt, or Docker — compiles PostgreSQL 16.10, TimescaleDB 2.17.2, pgvector 0.8.0, and pgvectorscale 0.9.1 (plus staged pgai 0.12.1 sources) from `/opt/stage/` and `/opt/extensions/` inside the imported image, installs to `/usr/local/pgsql/`, and initializes PGDATA at `/var/lib/postgresql/data/`. install-v2 fetches this script from the repo at the manifest tag when it is not bundled alongside (commit c2f082e2).
- OBSERVED (`setup-forum-v2.py`, commit 9dd7832f, 2026-10-07): called by install-v2 after the database build — patches `/etc/supervisor/conf.d/lampy.conf` (supervisorctl sections and `[program:forum]` when missing), creates the `forum` PostgreSQL role with a generated password, loads `/opt/forum/schema.sql`, generates `FORUM_SECRET_KEY`, and writes secrets to `/root/.lampy-forum-secrets` (600, root only). Idempotent.
- OBSERVED (`install-v2.ps1` step 2b, commits 9dd7832f / be5b24b8, 2026-10-07/10): on fresh installs the installer refreshes the Bible website from `https://raw.githubusercontent.com/kitcosby/bible-project/master/website` — it downloads `app_v2.py` and `papyrus-tile.png` and copies them into `/opt/bible/website/` in the distro (an earlier draft comment named the old account; the code URL is `kitcosby/bible-project`). This is a new cross-repository flow: lampy-installer → bible-project.
- OBSERVED (local git log at 237e12d; GitHub API): v1.1.4 (NSIS window output via nsExec, service-check retries), v1.1.5 (supervisord daemon mode, idempotent boot script), v1.1.6 (quoted-password detector — repair prompts on Toetop), v1.1.7 (NSIS window output, retries), v1.1.8 (boot-file version check in repair), v1.1.9 (remove redundant mkdir), `-Force` on `Register-ScheduledTask` (step-4 re-run fix), and v1.1.10 (`237e12d`): repair skips download, uninstall task-safety. The local commits 3cedb56–237e12d (v1.1.4–v1.1.10) are absent from GitHub main; note GitHub main (`2845fb5d`) is a divergent branch that carries its own v1.1.5/v1.1.6/v1.1.9-labeled commits, so the two mains will not fast-forward. Resolving the code divergence (merge vs force-push) is Kit's decision; this doc describes the local v1.1.10 code.

## Relationship to the other repo

lampy-installer creates the WSL distro that lampy-admin runs inside of. Since v2.0.0 it also fetches the current Bible website files (`app_v2.py`, `papyrus-tile.png`) from the bible-project repository on fresh installs, so a fresh Lampy install serves the current bible-project website without a separate Bible refresh step. The installer delivers the full Lampy stack including the forum app whose database the console reads and writes. The lampy-admin repo contains `Refresh-WslPortForwards.ps1`, a Windows-side script that complements the installer's port setup by refreshing WSL port forwards; the console's windowstools tab serves that same file and refreshes those forwards over SSH. The console updates itself from the lampy-admin GitHub releases, independent of any installer release.
