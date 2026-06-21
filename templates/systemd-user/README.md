# systemd-user template

Run a Python / Node service as a user-mode systemd unit. No containers, no
sudo (after enable-linger). Good for small shared dev tools.

## Setup (once per user, once per host)

```bash
# allow user services to keep running after logout
loginctl enable-linger $(whoami)
```

## Per service

```bash
mkdir -p ~/.config/systemd/user
cp myservice.service ~/.config/systemd/user/myservice.service
# edit Description, WorkingDirectory, ExecStart for your app

systemctl --user daemon-reload
systemctl --user enable --now myservice

# observe
systemctl --user status myservice
journalctl --user -u myservice -f
```

## Restart on code change

```bash
git pull && systemctl --user restart myservice
```

## Notes

- **Flask dev server**: use `flask --debug run` only for local dev, never in a
  unit file. Production = gunicorn.
- **gunicorn** is installed via `pip install gunicorn` (add to your
  `requirements.txt`; the hub's `pypi-group` will serve it).
- **Port < 1024**: not allowed in rootless mode without setcap. Bind to
  127.0.0.1:8000 and front with a reverse proxy if you need :80/:443.
