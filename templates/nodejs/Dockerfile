# syntax=docker/dockerfile:1
FROM hub.internal:8082/node:22 AS base

ENV NODE_ENV=production

WORKDIR /app

# npm reads npm-internal first via the group repo (set by bootstrap-client.sh
# on hosts; for CI runners we inject a project-local .npmrc).
COPY .npmrc ./
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY . .

EXPOSE 3000
CMD ["node", "server.js"]
