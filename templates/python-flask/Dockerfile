# syntax=docker/dockerfile:1
# Build inside Rocky 8.10 so glibc 2.28 / cp312 wheels work on RHEL 8.10 hosts.
FROM hub.internal:8082/python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# pip picks up /etc/pip.conf (set by bootstrap-client.sh in the build env);
# inside Gitea Actions runner you may need to inject it. The /pip.conf below
# is a fallback that hardcodes the hub URL.
COPY pip.conf /etc/pip.conf

COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY . .

# gunicorn for production. Workers = 2 × CPU + 1 is a safe default; tune.
ENV PORT=8000
EXPOSE 8000
CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:8000", "app:app", "--access-logfile", "-"]
