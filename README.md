# offline-machine-package

Toolkit for maintaining 10+ offline RHEL 8.10 machines via a central Nexus 3 hub
on NetApp. Manifest-driven: edit `manifests/*.txt`, run the sideload script,
ship the resulting tarball to the hub, run the upload script.

The repo has two flow families:

- **Ecosystem flows**: `pypi`, `npm`, `images`, `rpms`, `repos`
- **Raw-bundles flows**: `uv`, `hermes`

## Architecture (one line)

```
Mac (online) ──tarball──▶ Hub (Nexus 3) ──HTTP──▶ 10 offline machines
                              │
                              └── proxies enterprise Nexus OSS for pip/npm/dnf
```

Enterprise OSS is **security-reviewed**: not every package is available there.
The `*-internal` hosted repos on our hub absorb anything OSS refuses, fed by the
sideload flow in this repo. Clients only ever talk to the `*-group` repos so
they never know the difference. Tools that are not native package ecosystems,
such as `uv` and `hermes`, are published through Nexus `raw-bundles/` and
installed via dedicated client scripts.

- **首次部署：** 照 [`docs/deployment-checklist.md`](docs/deployment-checklist.md) 18 步打勾
- **找人代下載：** 給對方看 [`HELPER.md`](HELPER.md)（單頁、不用懂技術）
- 人類維運：先讀 [`docs/operator-runbook.md`](docs/operator-runbook.md)
- 部署新服務：[`docs/service-deploy-guide.md`](docs/service-deploy-guide.md) + [`templates/`](templates/)
- 架構理由：[`docs/architecture.md`](docs/architecture.md)
- REST API 食譜：[`docs/ai-agent-cookbook.md`](docs/ai-agent-cookbook.md)
- AI agent 冷啟動：[`AGENTS.md`](AGENTS.md)

## Folder layout

```
manifests/       what to ship — edit these
scripts/mac/     run on Mac to build dist/*-bundle-*.tar.gz
scripts/hub/     run on hub machine (webadmin) to load bundles into Nexus / Gitea
scripts/client/  run on each offline machine once
docs/            human + agent runbooks
workspace/       git mirrors and pip/npm caches (gitignored)
dist/            finished tarballs to ship (gitignored)
```

## Quick start (first time)

1. Mac: `./scripts/mac/sideload-images.sh` → `dist/images-bundle-*.tar.gz`.
2. Ship to hub. On hub as `webadmin`: extract, run included `load-images.sh`.
3. Fill variables in `scripts/hub/bootstrap-hub.sh`, run it → Nexus is up.
4. Fill variables in `scripts/client/bootstrap-client.sh`, run on each of the
   10 offline machines.

## Day-to-day (adding stuff)

```bash
# A. someone needs pandas, react, nginx image, and a public repo
vi manifests/pypi.txt   # add: pandas==2.2.0
vi manifests/npm.txt    # add: react@18
vi manifests/images.txt # add: docker.io/library/nginx:1.27
vi manifests/repos.txt  # add: <url> <gitea-owner/name>

# B. build
./scripts/mac/sideload-all.sh        # or just the ones you changed

# C. ship dist/*.tar.gz to hub, then on hub:
export HUB_BASE=http://127.0.0.1:8081
export NX_USER=svc-agent NX_PASS=...
export DOCKER_HOST_REG=127.0.0.1:8082
export GITEA_BASE=http://gitea.internal:3000 GITEA_TOKEN=...
./scripts/hub/upload-all.sh
```

That's it — offline machines see new packages immediately via the group repos.
