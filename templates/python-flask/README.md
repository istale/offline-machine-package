# Python Flask service template

Containerized Flask app. Build → push to Nexus → run on any RHEL 8.10 host
via podman + systemd (Quadlet).

## Local dev (no container)

```bash
pip install -r requirements.txt
flask --app app run --debug         # http://127.0.0.1:5000/
```

## Build & push (manually, before CI is wired up)

```bash
podman build -t hub.internal:8082/myapp:dev .
podman login --tls-verify=false hub.internal:8082
podman push --tls-verify=false hub.internal:8082/myapp:dev
```

After `.gitea/workflows/build.yml` is set up, every push to `main` does this
automatically. Add `NX_USER`, `NX_PASS` as repo secrets in Gitea.

## Deploy on target host

```bash
mkdir -p ~/.config/containers/systemd
cp myapp.container ~/.config/containers/systemd/myapp.container
# edit Image=... if your repo / tag differs

systemctl --user daemon-reload
systemctl --user start myapp
journalctl --user -u myapp -f

# health check
curl http://127.0.0.1:8000/healthz
```

## Why gunicorn, not `flask run`?

`flask run` (the dev server) is single-threaded, has debug mode security holes,
and is **explicitly not for production** (the Flask docs say so on the first
page). gunicorn is the standard WSGI server — same code, multiple workers,
graceful reloads, battle-tested.
