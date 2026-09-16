# Optional local overlay; official publication uses the ordinary root Dockerfile.
ARG BASE_IMAGE
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
# Preserve incremental objects across a failed qualification build. Sources,
# headers, archives and flags are still checked inputs to CMake/Ninja.
RUN --mount=type=cache,id=duckgres-bundle-697fa-gcc12-amd64,target=/build/extension,sharing=locked \
    sh /build/candidate/build-extension.sh

FROM ${BASE_IMAGE} AS candidate
ARG BASE_IMAGE_ID
ARG PATCH_SHA256
LABEL org.opencontainers.image.base.digest="${BASE_IMAGE_ID}" \
      org.duckgres.ducklake.candidate="6768849c-inline-null1" \
      org.duckgres.ducklake.patch.sha256="${PATCH_SHA256}"
COPY --from=extension_builder --chown=duckgres:duckgres \
    /out/ducklake.duckdb_extension /out/httpfs.duckdb_extension /out/postgres_scanner.duckdb_extension \
    /out/json.duckdb_extension /out/ducklake-build-manifest.txt /out/build-inputs.sha256 \
    /app/extensions/v1.5.5/linux_amd64/
COPY --from=extension_builder --chown=duckgres:duckgres \
    /out/native-tests/ /app/ducklake-candidate/native-tests/
COPY --from=extension_builder --chown=duckgres:duckgres \
    /out/vcpkg-status.txt /app/ducklake-candidate/vcpkg-status.txt
