# syntax=docker/dockerfile:1
FROM hub.internal:8082/python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY pip.conf /etc/pip.conf
COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY . .

EXPOSE 8000
# gunicorn process manager + uvicorn ASGI workers = best of both:
# graceful reload, multi-worker, async-native. Tune -w to (2*CPU)+1.
CMD ["gunicorn", "app:app", \
     "-k", "uvicorn.workers.UvicornWorker", \
     "-w", "4", \
     "-b", "0.0.0.0:8000", \
     "--access-logfile", "-"]
