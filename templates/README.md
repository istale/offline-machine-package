# Service templates

Copy-paste starters for the three deployment patterns described in
`docs/service-deploy-guide.md`. Each subfolder is a self-contained example;
keep what fits, delete the rest.

| Folder | Pattern | When to use |
|---|---|---|
| `systemd-user/` | bare `systemd --user` unit running a binary on the host | quick internal service; no container needed |
| `python-flask/` | Flask app → gunicorn → container → podman + systemd | shareable Python service, prod-grade |
| `python-fastapi/` | FastAPI app → gunicorn + UvicornWorker → container | async Python service (OpenAPI, websockets) |
| `nodejs/` | Node app → container → podman + systemd | shareable Node service, prod-grade |

All templates assume the host has been bootstrapped with
`scripts/client/bootstrap-client.sh` (dnf / pip / npm / podman all point at the
hub). They never call out to the internet.
