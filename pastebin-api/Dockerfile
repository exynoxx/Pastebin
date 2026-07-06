# Nim drop-in backend image. Mirrors the "native build, tiny runtime" ethos of
# pastebin-api/Dockerfile: the heavy compile runs on the host's NATIVE arch
# ($BUILDPLATFORM, amd64) — NOT under QEMU — and only the final runtime image is arm64.
#
# How the cross-compile stays QEMU-free: Nim compiles to C natively on amd64 (fast), then
# `zig cc` compiles that C for the target arch. We target **glibc** (…-linux-gnu), not musl:
# the SQLite and OpenSSL bindings load their .so via dlopen at RUNTIME, and zig's musl output
# is statically linked with NO dynamic loader, so dlopen can't work there — glibc output has a
# proper PT_INTERP and dlopen works. Nothing but libc is needed at link time; the arm64 shared
# libs come from the (glibc) runtime stage below.
#
#   docker buildx build --platform linux/arm64 -f pastebin-api/Dockerfile pastebin-api

ARG ZIG_VERSION=0.13.0
# Pin the target glibc low enough to run on the runtime image's glibc (bookworm = 2.36).
ARG GLIBC_VERSION=2.31

FROM --platform=$BUILDPLATFORM nimlang/nim:2.2.4-alpine AS build
ARG TARGETARCH
ARG ZIG_VERSION
ARG GLIBC_VERSION
WORKDIR /src

# zig = the cross C compiler/linker. Fetch the amd64 (build-host) zig; it can target any arch.
RUN apk add --no-cache curl xz && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
      | tar -xJ -C /opt && \
    ln -s "/opt/zig-linux-x86_64-${ZIG_VERSION}/zig" /usr/local/bin/zig

# Dependencies first, so this layer caches across source-only changes.
COPY pastebin.nimble nim.cfg ./
RUN nimble install -dy

COPY src ./src

# Map Docker's TARGETARCH -> (zig glibc target triple, nim cpu), wrap zig as a clang-compatible
# cc/linker, and cross-compile. -d:release + the nim.cfg flags (orc, useMalloc, threads, ssl).
RUN set -eux; \
    case "$TARGETARCH" in \
      arm64) ZTARGET="aarch64-linux-gnu.${GLIBC_VERSION}"; NIMCPU=arm64 ;; \
      amd64) ZTARGET="x86_64-linux-gnu.${GLIBC_VERSION}";  NIMCPU=amd64 ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac; \
    printf '#!/bin/sh\nexec zig cc -target %s "$@"\n'  "$ZTARGET" > /usr/local/bin/zcc; \
    printf '#!/bin/sh\nexec zig c++ -target %s "$@"\n' "$ZTARGET" > /usr/local/bin/zcxx; \
    chmod +x /usr/local/bin/zcc /usr/local/bin/zcxx; \
    nim c -d:release \
      --os:linux --cpu:$NIMCPU \
      --cc:clang --clang.exe:zcc --clang.linkerexe:zcc --clang.cpp.exe:zcxx --clang.cpp.linkerexe:zcxx \
      --passC:-fPIC \
      -o:/out/pastebin src/main.nim

# ---- runtime: minimal glibc (debian-slim), non-root, /data mount points ----
# glibc (not alpine/musl) so the dynamically-linked binary's loader + dlopen'd libs resolve.
FROM debian:bookworm-slim AS final
# libsqlite3 (metadata store) + openssl (ntfy HTTPS) are dlopen'd at runtime; ca-certificates
# so the ntfy TLS handshake can verify. No .NET runtime, no toolchain.
RUN apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-0 openssl ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /data/blobs /data/db && \
    groupadd -g 1654 app && useradd -u 1654 -g 1654 -M -N app && \
    chown -R 1654:1654 /data
COPY --from=build /out/pastebin /usr/local/bin/pastebin
USER 1654:1654
WORKDIR /data
EXPOSE 8080
# Binds 0.0.0.0:8080 itself (reads the port from PORT if set, else 8080).
ENTRYPOINT ["/usr/local/bin/pastebin"]
