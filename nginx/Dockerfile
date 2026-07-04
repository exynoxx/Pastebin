# Single image that (1) builds the React app and (2) serves the static build directly
# from nginx — no Node runtime container. The Node SDK is used only at build time.
# Build context is the repo root: docker build -f nginx/Dockerfile .
# Build on the host's NATIVE arch ($BUILDPLATFORM) instead of the target arm64: the React
# build is just static JS/CSS, so it's architecture-neutral and there's no reason to run npm
# under QEMU emulation. Only the final nginx image below is built for arm64.
FROM --platform=$BUILDPLATFORM node:20-alpine AS build
WORKDIR /app
COPY pastebin-frontend/package*.json ./
RUN npm ci || npm install
COPY pastebin-frontend/ ./
RUN npm run build

FROM nginx:alpine
COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf
# Kept OUT of conf.d (nginx auto-loads conf.d/*.conf as servers); included by absolute path.
COPY nginx/security-headers.conf /etc/nginx/security-headers.conf
# CRA emits ./build; older/newer tooling may emit ./dist — copy whichever exists.
COPY --from=build /app/build /usr/share/nginx/html
