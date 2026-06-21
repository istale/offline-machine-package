# FastAPI service template

Containerized FastAPI app. Same deploy story as the Flask template — see
`docs/service-deploy-guide.md`.

## Local dev

```bash
pip install -r requirements.txt
uvicorn app:app --reload     # http://127.0.0.1:8000 — hot reload
# OpenAPI docs:               http://127.0.0.1:8000/docs
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
curl http://127.0.0.1:8000/healthz
```

## Why gunicorn + UvicornWorker?

Bare `uvicorn` works but lacks: graceful worker reload, restart-on-crash for
individual workers, robust signal handling under load. The combo:

- **gunicorn**: battle-tested process manager (forks workers, restarts dead
  ones, handles SIGHUP for reload)
- **UvicornWorker**: each worker is an async ASGI server — full FastAPI
  performance

Single command: `gunicorn app:app -k uvicorn.workers.UvicornWorker -w 4`.

For light dev work `uvicorn app:app --reload` is fine. Don't ship it.
