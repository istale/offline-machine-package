# Architecture

```
                         ┌─────────────────────────┐
                         │  Enterprise Nexus OSS   │  (IT-reviewed, may not have your package)
                         │  pip / npm / dnf only   │
                         └────────────┬────────────┘
                                      │ proxy (HTTP, optional auth)
                                      ▼
┌──────── Mac (online) ────────┐   ┌────────────── Hub (RHEL 8.10, webadmin) ─────────────┐
│ manifests/*.txt              │   │  Nexus 3 (rootless podman, systemd --user)            │
│  → scripts/mac/sideload-*.sh │   │   blobstore on NetApp /srv/nexus-data                 │
│  → dist/*-bundle-*.tar.gz    │──▶│   pypi-{proxy,internal,group}                         │
│     (ship via USB/gateway)   │   │   npm-{proxy,internal,group}                          │
└──────────────────────────────┘   │   rocky-8-baseos-proxy / appstream-proxy / epel-proxy │
                                   │   rpm-internal                                        │
                                   │   docker-hosted (no upstream; sideload only)          │
                                   │   raw-bundles                                         │
                                   │  Gitea (existing) + act_runner(s)                     │
                                   └────────────────────┬──────────────────────────────────┘
                                                        │ HTTP only
                                          ┌─────────────┴──────────────┐
                                          ▼                            ▼
                                   ┌────────────┐               ┌────────────┐
                                   │ dev box #1 │  ...  ×10+    │ prod box   │
                                   │ dnf/pip/npm/podman → hub   │            │
                                   └────────────┘               └────────────┘
```

## Why each piece

- **One Nexus**: single REST API for agents, one place to back up (NetApp), one
  service to upgrade. PyPI/npm/dnf/docker/raw all under one roof.
- **Group repos**: clients see one URL per ecosystem. Hidden behind it: internal
  hosted (priority) + proxy to enterprise OSS (fallback). Adding a sideloaded
  package is zero-touch on clients.
- **Docker hosted only**: enterprise OSS doesn't mirror docker, by policy.
  Every image is sideloaded from Mac via the howto flow.
- **Gitea + Actions**: CI was the missing piece. `act_runner` runs as another
  podman container on the hub; workflows pull images from `docker-hosted` and
  packages from group repos, so CI is fully self-contained.

## Flow families

- **Ecosystem flows** map to a downstream protocol or toolchain:
  `pypi`, `npm`, `images`, `rpms`, `repos`
- **Raw-bundles flows** publish installable tarballs through Nexus
  `raw-bundles/` and rely on dedicated client installers:
  `uv`, `hermes`

This distinction is intentional. `uv` and `hermes` are not extra package
repository types; they are shipped application/tool bundles.

## What is not in this architecture

- TLS / CA — explicitly out of scope.
- Harbor / devpi / verdaccio — Nexus subsumes them.
- A second hub / HA — single hub, NetApp absorbs the durability story. If
  this changes, revisit.
