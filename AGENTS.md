# AGENTS.md — cold-start brief for AI agents

You (a fresh AI session) have been asked to operate this repo. Read this top to
bottom before doing anything. **Do not skim.** The user has 10+ offline RHEL
8.10 machines and limited patience for rework.

## What this repo is

A manifest-driven toolkit that ships pip / npm / container images / RPMs / git
repos from an internet-connected Mac to an offline environment. The offline
environment has:

- A **central hub machine** running Nexus 3 (rootless podman, systemd `--user`
  unit, runs as user `webadmin`). Storage on NetApp at `/srv/nexus-data`
  (user-configurable in bootstrap-hub.sh).
- A **Gitea** instance (pre-existing) for source control + CI (Gitea Actions).
- **10+ RHEL 8.10 client machines** that have been bootstrapped to point dnf /
  pip / npm / podman at the hub.
- An **enterprise Nexus OSS** that mirrors *some* of public PyPI / npm / dnf —
  but **IT security strictly reviews what gets mirrored**, so any given package
  may not be there. Docker is NOT mirrored at all. Plan for absence as the
  default case, not the exception.
- **HTTP only.** No CA, ever. Don't propose TLS.

## The model: manifest → tarball → upload

Everything flows through three steps and three folders:

```
manifests/<thing>.txt   →   scripts/mac/sideload-<thing>.sh   →   dist/<thing>-bundle-*.tar.gz
                                                                          ↓ ship
                            scripts/hub/upload-<thing>.sh    ←   dist/<thing>-bundle-*.tar.gz
                                       ↓
                                Nexus ecosystem repo / raw-bundles / Gitea
```

There are two flow families:

- **Ecosystem flows**: `pypi`, `npm`, `images`, `rpms`, `repos`
- **Raw-bundles flows**: `uv`, `hermes`

Each flow is independent — adding a wheel does NOT require rebuilding the image
bundle.

## Crucial rules

1. **Linux/amd64, glibc 2.28.** All pip download / npm pack / docker pull MUST
   happen inside a `rockylinux/rockylinux:8.10` container with
   `--platform linux/amd64`. The sideload scripts already do this; don't
   bypass them. See `cross-os-offline-tarball-howto.md` for why.
2. **Client machines only talk to `*-group` repos.** Never instruct a client
   to hit `*-proxy` or `*-internal` directly. The group merges them, with
   `*-internal` taking priority.
3. **OSS may not have the package.** Always design fallback through
   `*-internal`. Never tell the user "ask IT to add it to OSS" as the only
   path — sideloading is the supported path.
4. **No docker upstream exists.** All images are hosted-only on our hub.
   Sideload via `manifests/images.txt`.
5. **Don't introduce new services without asking.** Architecture is locked at
   Nexus + Gitea + Gitea Actions runners. Adding Harbor / devpi / verdaccio
   etc. is regression.
6. **`dist/` and `workspace/` are gitignored.** Don't commit tarballs.

## File map

| Path | Purpose |
|---|---|
### Ecosystem flows (downstream tool consumes directly)
| Path | Purpose |
|---|---|
| `manifests/pypi.txt` | pip specs to sideload |
| `manifests/npm.txt` | npm specs to sideload |
| `manifests/images.txt` | container images to sideload (always linux/amd64) |
| `manifests/rpms.txt` | RPMs OSS doesn't carry |
| `manifests/repos.txt` | `<url> <gitea-owner/name>` per line |
| `scripts/mac/sideload-{pypi,npm,images,rpms,repos}.sh` | read manifest, produce `dist/<x>-bundle-*.tar.gz` |
| `scripts/hub/upload-{pypi,npm,images,rpms,repos}.sh` | load a bundle into the matching Nexus ecosystem repo or Gitea |
| `scripts/mac/prepare-nexus-image.sh` | legacy: same as sideload-images on the seven Phase-0 images. Keep for reference. |

### Raw-bundles flows (tool/app published as tarball, installed by a dedicated script)
| Path | Purpose |
|---|---|
| `manifests/uv.txt` | uv version pin |
| `scripts/mac/sideload-uv.sh` | downloads the `uv` static linux x86_64 binary from GitHub releases |
| `scripts/hub/upload-uv.sh` | publishes uv bundle to `raw-bundles/uv/{...,latest.tar.gz}` |
| `scripts/client/install-uv.sh` | installs `uv`/`uvx` to `/usr/local/bin`. Writes `/etc/profile.d/uv.sh` forcing `UV_PYTHON_PREFERENCE=only-system` + `UV_PYTHON_DOWNLOADS=never` so `uv run` / `uvx` (e.g. in MCP server READMEs) use system python3.12 and the hub's pypi-group, never the internet. We deliberately do NOT bundle python-build-standalone. |
| `manifests/hermes.txt` | Hermes ref pin |
| `scripts/mac/sideload-hermes.sh` | builds Hermes Agent Desktop fully installed inside a Rocky 8.10 container with **all cache env vars redirected into the bundled tree** (`ELECTRON_CACHE`, `PLAYWRIGHT_BROWSERS_PATH`, `XDG_CACHE_HOME`, `npm_config_cache`, `PIP_CACHE_DIR`) so Electron / Playwright / Node / Python binaries are captured. Fails fast if any large binary missing post-build. Then runs `verify-hermes-offline.sh`; refuses to declare success unless the bundle passes offline smoke test. |
| `scripts/mac/verify-hermes-offline.sh` | extracts a hermes-bundle into a Rocky 8.10 container with `--network=none`, asserts DNS is off, runs Electron/Node/Python `--version` plus Playwright Chromium presence check. Any tool that tries to phone home fails immediately (no route out). Sideload calls this automatically; you can also run it standalone against a tarball. |
| `scripts/hub/upload-hermes.sh` | publishes bundle to `raw-bundles/hermes/` (timestamped + `latest.tar.gz` alias) |
| `scripts/client/install-hermes.sh` | per-desktop installer; restores `$HERMES_HOME` (default `/opt/hermes`) + `$HERMES_LIB` (default `/usr/local/lib/hermes-agent`) + `/usr/local/bin/hermes`. Both vars overridable; if `$HERMES_LIB` is moved the script symlinks `/usr/local/lib/hermes-agent` → `$HERMES_LIB` because venv shebangs are baked. |

### One-shot setup + cross-cutting tooling
| Path | Purpose |
|---|---|
| `scripts/hub/bootstrap-hub.sh` | one-time: stand up Nexus + create all repos via REST |
| `scripts/hub/register-actions-runner.sh` | one-time: register `act_runner` to Gitea as a systemd `--user` unit (rootless podman). Requires `GITEA_BASE` + `RUNNER_TOKEN`. |
| `scripts/client/bootstrap-client.sh` | one-time per offline machine |
| `scripts/mac/sideload-all.sh` | run every flow (ecosystem + raw-bundles) |
| `scripts/hub/upload-all.sh` | run every upload using newest tarball in `dist/` |

### Mega-bundle (single-download distribution)
| Path | Purpose |
|---|---|
| `scripts/mac/package-mega-bundle.sh` | bundle the repo source + every `dist/*.tar.gz` into one (or split) tarball for GitHub Releases. Auto-splits at 1800 MiB (GitHub Release asset cap is 2 GiB). Emits a `gh release create` invocation. |
| `scripts/hub/extract-mega-bundle.sh` | reverse: accepts the single mega-bundle or `.partNN` pieces, verifies SHA, drops repo into `~/offline-machine-package` and bundles into `~/inbox/`. |
| `HELPER.md` | one-page instructions for a non-technical helper who only needs to download + ship the GitHub Release assets. Linked as the release `--notes-file`. |

### Docs + service templates
| Path | Purpose |
|---|---|
| `docs/architecture.md` | topology + design rationale + flow-family definition |
| `docs/ai-agent-cookbook.md` | REST API recipes (search, upload, trigger CI) |
| `docs/operator-runbook.md` | human-oriented SOP — scenario → steps; refer humans here |
| `docs/service-deploy-guide.md` | 3-tier service deploy story (dev / staging systemd-user / prod podman+Quadlet). Refer here when anyone asks "how do I run my Flask/Node service?" |
| `templates/` | copy-paste service starters: `systemd-user/`, `python-flask/`, `python-fastapi/`, `nodejs/`. All wired to hub URLs already. |
| `cross-os-offline-tarball-howto.md` | the foundational glibc/manylinux rules |

## Common tasks

### "User wants package X added"

1. Check if it's already available:
   ```bash
   curl -s "$HUB_BASE/service/rest/v1/search?repository=pypi-group&name=X" | jq
   ```
2. If present → tell user `pip install X` works, done.
3. If absent → edit the right `manifests/*.txt`, run
   `scripts/mac/sideload-<type>.sh`, ship the resulting tarball, run
   `scripts/hub/upload-<type>.sh` on the hub. Verify via step 1 again.

### "User wants to ship a public GitHub repo to Gitea"

1. Append `<url> <gitea-owner/name>` to `manifests/repos.txt`.
2. `./scripts/mac/sideload-repos.sh` → `dist/repos-bundle-*.tar.gz`.
3. Ship. On hub: `export GITEA_BASE=... GITEA_TOKEN=...` then
   `./scripts/hub/upload-repos.sh dist/repos-bundle-*.tar.gz`.

### "User wants Hermes Agent Desktop / uv installed on offline machines" (raw-bundles)

These are NOT ecosystem flows — do not edit `manifests/pypi.txt` etc.

1. Mac: `./scripts/mac/sideload-hermes.sh` or `sideload-uv.sh` → `dist/{hermes,uv}-bundle-*.tar.gz`.
2. Hub: `./scripts/hub/upload-hermes.sh <bundle>` or `upload-uv.sh` → publishes to `raw-bundles/<tool>/{timestamped,latest.tar.gz}`.
3. Each target machine (sudo): `./scripts/client/install-hermes.sh` or `install-uv.sh`.

Path/env knobs (Hermes: `HERMES_HOME`, `HERMES_LIB`; uv: locked to system Python via `/etc/profile.d/uv.sh`) are documented in `docs/operator-runbook.md` §1.5–1.6.

### "Set up a new offline machine"

Edit `HUB_HOSTNAME` in `scripts/client/bootstrap-client.sh`, copy over, run
with sudo. Done.

### "Set up the hub from scratch" / "deploy this whole thing"

**Refer the user to `docs/deployment-checklist.md`** — it's an 18-step
pass/fail checklist covering Phase A (Mac prep) → B (hub bring-up) → C
(client roll-out) → D (CI) → E (handover). Don't paraphrase it here;
just walk them through one step at a time and verify the "pass condition"
before moving on.

The Gitea Actions runner registration (Phase B step 8) uses
`scripts/hub/register-actions-runner.sh`, which expects `GITEA_BASE` +
`RUNNER_TOKEN` from Gitea's Site Admin → Actions → Runners.

## Things to ask the user, not assume

- `HUB_HOSTNAME`, `NEXUS_DATA` (NetApp path), `ENTERPRISE_OSS_BASE` and the
  per-protocol paths under it, optional OSS creds, `GITEA_BASE`. These were
  intentionally left as blank variables.
- Whether a brand-new ecosystem element (CI runner host, metrics, secrets
  manager) is in scope — it probably isn't.

## Memory / state across sessions

The user's persistent memory at
`/Users/istale/.claude/projects/-Users-istale-Documents-offline-machine-package/memory/`
already has `project_offline_rhel_ecosystem.md` describing the constraints
above. If you discover something new and durable (a hostname, a permanent
exception, a recurring failure mode), update that memory.
