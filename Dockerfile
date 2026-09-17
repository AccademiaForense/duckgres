# Build the admin console SPA (controlplane/admin/ui) so the kubernetes build
# embeds a FRESH dist/ via //go:embed all:ui/dist, overwriting the committed
# bundle. Runs before the Go build.
FROM node:20-bookworm-slim AS uibuilder
WORKDIR /ui
COPY controlplane/admin/ui/package.json controlplane/admin/ui/package-lock.json ./
RUN npm ci
COPY controlplane/admin/ui/ ./
RUN npm run build

# The all-in-one linux/amd64 image builds every external extension against the
# same pinned core. Dependency stages match the optional overlay recipe; the
# source fetch, patch, linkage and native-test gates live in shared scripts.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS bundle_dependencies
ARG TARGETARCH
RUN test "${TARGETARCH}" = amd64 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build git curl ca-certificates zip unzip pkg-config python3 perl autoconf automake libtool \
    && apt-get clean
WORKDIR /build
COPY scripts/ducklake-candidate/pins.env scripts/ducklake-candidate/prepare-deps.sh /build/candidate/
RUN sh /build/candidate/prepare-deps.sh

FROM bundle_dependencies AS extension_builder
RUN apt-get update && apt-get install -y --no-install-recommends bison flex && apt-get clean
COPY scripts/ducklake-candidate/scanner-pins.env scripts/ducklake-candidate/prepare-scanner.sh /build/candidate/
RUN sh /build/candidate/prepare-scanner.sh
ARG PATCH_SHA256
COPY scripts/ducklake-candidate/ /build/candidate/
COPY go.mod /build/go.mod
COPY Dockerfile /build/Dockerfile.bundle-build
RUN --mount=type=cache,id=duckgres-bundle-697fa-gcc12-amd64,target=/build/extension,sharing=locked \
    sh /build/candidate/check-pins.sh /build/go.mod \
    && PATCH_SHA256="${PATCH_SHA256:-$(sh /build/candidate/patch-digest.sh)}" \
       BUNDLE_BUILD_RECIPE=/build/Dockerfile.bundle-build \
       sh /build/candidate/build-extension.sh

FROM golang:1.25-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ libc6-dev curl gzip && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download

# The Go scanner regression and the final runtime use the very same rebuilt
# extension files. There is no fallback to upstream precompiled binaries.
COPY --from=extension_builder /out/ /build/duckdb-extensions/v1.5.5/linux_amd64/

COPY . .
# Overwrite the committed placeholder with the freshly built SPA so the
# kubernetes build embeds the real bundle.
COPY --from=uibuilder /ui/dist ./controlplane/admin/ui/dist
ARG VERSION=dev
ARG COMMIT=unknown
ARG BUILD_TAGS=""
RUN CGO_ENABLED=1 \
    DUCKGRES_TEST_DUCKDB_EXTENSION_DIRECTORY=/build/duckdb-extensions \
    go test -count=1 -tags "${BUILD_TAGS}" \
      -run '^TestDoCopyFromStdinIngestsPostgresBinaryWithBundledScanner$' \
      ./duckdbservice
RUN CGO_ENABLED=1 go build -tags "${BUILD_TAGS}" -ldflags "-X main.version=${VERSION} -X main.commit=${COMMIT} -X main.date=$(date -u +%Y-%m-%dT%H:%M:%SZ)" -o duckgres .

FROM chainguard/wolfi-base:latest

# postgresql-18-client provides pg_dump/pg_restore, used by the control-plane
# reshard runner's pre-flip catalog backup (docs/design/resharding.md). Pinned
# to PG 18 to match the cnpg shard major so it can dump PG-18 catalogs. mw-dev
# runs this single all-in-one image as BOTH control plane and workers, so the
# client must live here (not only in Dockerfile.controlplane). libstdc++ is
# the C++ runtime the CGO-linked DuckDB engine needs — present implicitly on
# debian-slim, but not in wolfi-base.
RUN apk add --no-cache ca-certificates-bundle libstdc++ postgresql-18-client \
    && addgroup -S duckgres && adduser -S -G duckgres -h /app duckgres

WORKDIR /app
COPY --from=builder /build/duckgres .
COPY --from=builder /build/duckdb-extensions ./extensions
COPY --from=extension_builder /out/native-tests/ /app/ducklake-candidate/native-tests/
COPY --from=extension_builder /out/vcpkg-status.txt /app/ducklake-candidate/vcpkg-status.txt
RUN mkdir -p data certs && chown -R duckgres:duckgres /app

USER duckgres

EXPOSE 5432 8816 9090

ENTRYPOINT ["/app/duckgres"]
