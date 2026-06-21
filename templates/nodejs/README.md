# Node.js service template

Containerized Node app. Same flow as the Flask template — see
`docs/service-deploy-guide.md` for the full deploy story.

## Local dev (no container)

```bash
npm ci
npm run dev          # node --watch server.js — hot reload on file change
```

## Build & push

```bash
podman build -t hub.internal:8082/myapi:dev .
podman push --tls-verify=false hub.internal:8082/myapi:dev
```

## Deploy

```bash
cp myapi.container ~/.config/containers/systemd/myapi.container
systemctl --user daemon-reload
systemctl --user start myapi
journalctl --user -u myapi -f
```

## Why no PM2?

systemd already gives us: restart on crash (`Restart=on-failure`), log rotation
(journald), startup ordering (`After=`), and zero extra binaries. Inside the
container, the process supervisor is podman itself (and systemd outside).
