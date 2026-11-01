# AAPS Build Scripts

Personal build pipeline for [AndroidAPS](https://github.com/nightscout/AndroidAPS), designed to run on a home lab / Proxmox LXC with a systemd timer. Pulls upstream source at build time, builds signed release APKs, validates them, and optionally ships them to a location of your liking over rsync with ntfy notifications.


**Not affiliated with the AAPS project.** This is a self-hosted alternative to the official [AAPS Builder](https://androidaps.readthedocs.io/en/latest/SettingUpAaps/BrowserBuild.html) for people who want to control their own build environment. The official browser build is simpler for most users; this is for people who already run a homelab and prefer not to hand a Google account to a build pipeline.

> **Attribution note:** The scripts here are hand-written and hand-debugged. This README was drafted with LLM assistance, but the pipeline it documents was not "vibe coded".

## What it does

1. Clones or updates `nightscout/AndroidAPS` at the latest tagged release
2. Detects required Java / SDK / NDK versions from upstream's own `Versions.kt` and `jdk-map.json`
3. Installs missing SDK components, accepts licenses
4. Builds three targets:
   - `:app:assembleFullRelease` &rarr; master AAPS app
   - `:app:assembleAapsclientRelease` &rarr; AAPSClient (follower)
   - `:wear:assembleAapsclientRelease` &rarr; Wear OS client
5. Validates each APK: signature scheme, signer count, cert&harr;keystore fingerprint match, zipalign
6. Copies APKs to a versioned output directory, maintains a `latest` symlink
7. Optionally mirrors xDrip+ releases (stable and nightly)
8. Optionally rsyncs the last N builds to a VPS
9. Optionally sends ntfy notifications on success/failure

## Why not just use the official AAPS Builder?

The official browser build runs on GitHub Actions. That's fine, but:

- It requires a **Google account** (Drive is where the APK lands) and a **private GitHub fork**
- Private repo runners are **2 vCPU / ~7 GiB RAM**, which is why upstream's workflow adds swap before R8
- You don't control the toolchain, the JDK, or the SDK version

This pipeline runs on your own hardware, ships to your own server, and notifies via [ntfy](https://ntfy.sh) instead of Drive. If you don't already have a homelab with spare resources, the official builder is the better choice.

## Requirements

- **OS**: Debian/Ubuntu (apt) or RHEL/Fedora (dnf)
- **RAM**: $\geq$ 24 GiB recommended. 16 GiB *works* but R8 will OOM-kill the JVM during minification on a cold build. Swap helps but isn't a substitute.
- **CPU**: 8+ cores recommended. Worker count is auto-set to `nproc / 2`.
- **Disk**: ~10 GiB for source + Gradle caches + build outputs
- **Packages** (installed automatically): `wget`, `git`, `unzip`, `grep`, `jq`
- **Signing keystore**: generated automatically if missing (see `genkey` in `buildprep`)

## Setup

### 1. Clone somewhere sensible

```bash
git clone https://github.com/shoaib42/AAPS-build-scripts.git /opt/AAPS
```

The scripts assume they live in `/opt/AAPS/scripts` and that `/opt/AAPS` is the root for everything else (source tree, SDK, keystores, build outputs). If you want a different root, edit `ROOT_DIR` in `conf`.

### 2. Create your config

```bash
cd /opt/AAPS/scripts
cp conf.sample conf
chmod 600 conf
```

Edit `conf`. The important bits:

| Variable | What it does |
|---|---|
| `ROOT_DIR` | Root for source, SDK, keystores, outputs. Default `/opt/AAPS` |
| `KEYSTORE_PASSWORD` | **Change this.** Used for both the keystore and the key |
| `DNAME` | Cert subject - fill in `NAME`, `ORG`, `CITY`, etc. |
| `NTFY` | `no` by default. Set to `yes` to enable notifications |
| `NTFY_URL`, `NTFY_TOKEN`, `NTFY_ERR_TOPIC`, `NTFY_SUCCES_TOPIC` | ntfy config, only used if `NTFY=yes` |
| `RSYNC` | `no` by default. Set to `yes` to enable VPS sync |
| `SSH_KEY`, `VPS_USER`, `VPS_HOST`, `REMOTE_LOC`, `DL_PATH` | rsync config, only used if `RSYNC=yes` |
| `NUMKEEP` | How many recent builds to keep on the remote |

**Important**: `conf` is not committed (it contains your keystore password and SSH key path). Only `conf.sample` is in the repo.

### 3. First run

```bash
cd /opt/AAPS/scripts
./runbuild.sh
```

First run will:
- Install required packages
- Download Android command-line tools
- Install JDK (version determined from upstream)
- Clone AndroidAPS
- Install SDK components
- Generate a keystore if one doesn't exist
- Build (this will take longer time on the first run - it's compiling the entire KMP module graph)
- Validate and copy APKs to `/opt/AAPS/build/aaps/<version>/`

Subsequent runs on the same version are faster (warm Gradle cache, incremental build).

### 4. systemd timer (optional)

Run twice daily at 11:30 and 23:30:

`/etc/systemd/system/build-aaps.service`:
```ini
[Unit]
Description=Build AAPS
Wants=build-aaps.timer

[Service]
Type=oneshot
ExecStart=/opt/AAPS/scripts/runbuild.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=build_aaps
TimeoutStartSec=6h
```

`/etc/systemd/system/build-aaps.timer`:
```ini
[Unit]
Description=Build AAPS twice daily

[Timer]
OnCalendar=*-*-* 11,23:30:00
Persistent=true
Unit=build-aaps.service

[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload
systemctl enable --now build-aaps.timer
```

Note: `TimeoutStartSec=6h` is deliberate. The default systemd timeout may kill a cold build.

## Command-line flags

```bash
./runbuild.sh           # normal incremental build (if new version exists)
./runbuild.sh -f        # force rebuild: git clean -xfd + ./gradlew clean
./runbuild.sh -c        # force clean cache: wipe Gradle/Android/Kotlin user homes
./runbuild.sh -f -c     # both - full cold rebuild, longer time
./runbuild.sh -r        # reinstall Android command-line tools
./runbuild.sh -s        # rsync only, no build (requires RSYNC=yes)
```

`-f` and `-c` are separate on purpose. `-f` removes project `build/` directories (via `gradlew clean`), forcing a full recompile. `-c` wipes the *cache* under `$GRADLE_USER_HOME` etc., but leaves `build/` intact. See "Cache strategy" below.

## Cache strategy

This is the part that matters most for build times.

**What gets wiped:**
- `force_clean_cache_fn` deletes `$GRADLE_USER_HOME`, `$ANDROID_USER_HOME`, `$KOTLIN_USER_HOME` - all under `.cache/`
- **It does not touch project `build/` directories**

**What this means in practice:**

| Scenario | Time |
|---|---|
| Truly cold (no caches, no `build/`) | +++++++ |
| Cache wipe only (`-c`, or SDK changed) | ++++ |
| Incremental (new tag, no toolchain change) | ++ |
| No new version | :rocket: |

`FROM-CACHE` task lines within a single run are **expected and correct** - the variant matrix (`fullRelease` vs `aapsclientRelease` vs `aapsclient2Release` vs `aapsclient3Release`) shares cache entries produced *during that same run*. Seeing `FROM-CACHE` after a `-c` invocation is not a bug.

`FORCE_REBUILD` is set by `setup_java_tools` when it installs new SDK components, and by `-f` on the command line. It's what triggers `./gradlew clean` in `build_aaps` - the only path that deletes project `build/`.

## Known quirks handled

### SDK 37+ package naming

API 37 is packaged by Google as `platforms;android-37.0` (with a decimal), not `android-37`. Without the fix in `setup_java_tools`, the script reinstalls a non-existent package every run, which (because install triggers `FORCE_REBUILD=true`) wipes the cache every run:

```bash
if [[ "$COMPILE_SDK_L" =~ ^[0-9]+$ ]] && [ "$COMPILE_SDK_L" -ge 37 ]; then
    COMPILE_SDK_L="${COMPILE_SDK_L}.0"
fi
```

### Chicken-and-egg between git and tool detection

`refresh_git` must run before `setup_java_tools` (the SDK/JDK versions come from the source tree). But `setup_java_tools` is what decides whether a clean rebuild is needed. The script acknowledges this and defers the actual `./gradlew clean` to `build_aaps`, which runs after both:

```bash
install_soft_stack
refresh_git          # source first
init_build_targets
setup_java_tools     # detects, may set FORCE_REBUILD
genkey
if ... ; then
    build_aaps       # ./gradlew clean runs here if FORCE_REBUILD=true
fi
```

`refresh_git`'s own `git clean -xfd` (triggered by `FORCE_REBUILD`) is effectively dead code for the `-f` flag on first run because the variable isn't set yet - but it does fire if `FORCE_REBUILD` is already true from a previous context. It's kept for that edge case; the `gradlew clean` in `build_aaps` is the reliable path.

### R8 OOM on 16 GiB

R8 (minification) spikes memory well above the steady-state heap. On a 16 GiB LXC with no swap, this produces a silent death:

```
Memory cgroup out of memory: Killed process ... (java) anon-rss:8548112kB
```

No java process remains, `journalctl -t build_aaps -f` shows no further task lines, and the build appears hung. **Check `dmesg | grep -i oom` before assuming a hang. (check it on the host if this is running in a container)** Fix: 32 GiB RAM, and 8 GiB swap as a safety net. The `-Xmx` value in `conf.sample` is calculated as `(MemTotal - 6144) / 1024`, which gives ~10 GiB on 32 GiB - enough for R8 with headroom.

### Deprecated `sdkmanager`

The script uses `$SDKMANAGER_PATH` (traditional `sdkmanager`). Google deprecates it in favour of `android sdk` (Android CLI), but the old tool still works and the CLI isn't always installed. Migration is a future TODO.

## Output layout

```
/opt/AAPS/build/aaps/
|-- 4.0.0
|   |-- AAPS
|   |   |-- app-full-release_4.0.0.apk
|   |   |-- baselineProfiles        # side artifact, not part of the APK
|   |   `-- output-metadata.json
|   |-- AAPSClient
|   |   |-- app-aapsclient-release_4.0.0.apk
|   |   |-- baselineProfiles        # side artifact, not part of the APK
|   |   `-- output-metadata.json
|   |-- WearClient
|   |   |-- baselineProfiles        # side artifact, not part of the APK
|   |   |-- output-metadata.json
|   |   `-- wear-aapsclient-release_4.0.0.apk
|   `-- git_info.txt
|-- last_ver_epoch.txt
`-- latest -> 4.0.0
```

`git_info.txt` records the commit and `git status -sb` at build time. Useful for reproducing a build or checking what was actually compiled.

## Validation

Every built APK is validated before being copied to the output directory:

1. `apksigner verify --verbose` - at least one signing scheme passes
2. Signer count $\geq$ 1
3. `verify_certificate_match` - APK cert SHA-256 fingerprint equals keystore key fingerprint (proves the APK was signed with *your* key, not a debug key)
4. `zipalign -c -v 4` - alignment check

If validation fails, the target is left in `BUILD_TARGETS` and retried on the next run.

Manual verification after a build:

```bash
APK=/opt/AAPS/build/aaps/4.0.0/AAPS/app-full-release_4.0.0.apk
/opt/AAPS/android-sdk/build-tools/37.0.0/aapt2 dump badging "$APK" | grep -E 'versionName|compileSdk'
/opt/AAPS/android-sdk/build-tools/37.0.0/apksigner verify --print-certs "$APK"
```

Expect `versionName='4.0.0'`, `compileSdkVersion='37'`, and a cert fingerprint matching your keystore.

## Logs

If running via systemd:
```bash
journalctl -t build_aaps -f          # follow
journalctl -t build_aaps --since "2 hours ago"
```

If running manually, stdout only - the script doesn't write a log file by itself.

## Notes on upstream warnings

AAPS 4.x emits many Kotlin/Metro warnings (`SUGGEST_CLASS_INJECTION`, `DESUGARED_PROVIDER_WARNING`, `UNUSED_GRAPH_INPUT_WARNING`, `RETURN_IN_FUNCTION_WITH_EXPRESSION_BODY_WARNING`, etc.) and Gradle configuration-time deprecations. These are **upstream code issues, not build failures**. The only thing that matters is `BUILD SUCCESSFUL` at the end.

Do not enable `org.gradle.configuration-cache=true` until upstream clears the config-time process warnings - it will hard-fail the build.

## Security notes

- `conf` contains `KEYSTORE_PASSWORD` and a path to your SSH key. It is **not committed** and should be `chmod 600`.
- If you enable `RSYNC`, restrict the remote with an `authorized_keys` command restriction:
  ```
  command="rrsync /path/to/builds",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding ssh-ed25519 AAAA... build@host
  ```
  This limits the key to `rsync` into that directory only.
- If you serve the output directory over HTTP, put auth in front of it. These APKs are signed with your key, and they're for you - not for distribution.

## License

Scripts are yours to do with as you like. AndroidAPS itself is GPL-3.0; AAPS build scripts that link against it are derivative in spirit but operate on it externally.

