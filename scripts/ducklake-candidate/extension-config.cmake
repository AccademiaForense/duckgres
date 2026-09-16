if(NOT DUCKLAKE_LOCAL_BUILD_VERSION STREQUAL "6768849c-inline-null1")
    message(FATAL_ERROR "This candidate requires BUILD_VERSION=6768849c-inline-null1")
endif()

duckdb_extension_load(ducklake
    SOURCE_DIR /build/ducklake
    LOAD_TESTS
    EXTENSION_VERSION "${DUCKLAKE_LOCAL_BUILD_VERSION}"
)

# These loadable extensions must carry the identical static core and headers.
# Runtime PostgreSQL/S3 tests exercise the actual dynamic bundle separately.
duckdb_extension_load(httpfs SOURCE_DIR /build/httpfs DONT_LINK
    EXTENSION_VERSION "${HTTPFS_LOCAL_BUILD_VERSION}")
duckdb_extension_load(postgres_scanner SOURCE_DIR /build/postgres DONT_LINK
    EXTENSION_VERSION "${POSTGRES_LOCAL_BUILD_VERSION}")
duckdb_extension_load(json DONT_LINK EXTENSION_VERSION "697fa6fb44")

# The native test runner needs these built-ins, but rebuilding them would also
# rebuild much of DuckDB. Import the matching archives from the pinned release.
foreach(builtin core_functions parquet icu)
    duckdb_extension_load(${builtin}
        SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/prebuilt-extension"
        INCLUDE_DIR "/build/ducklake/duckdb/extension/${builtin}/include"
    )
endforeach()

# Run after DuckDB has created unittest and attached its generated loader and
# built-ins. A final archive group resolves their back-references to the core.
# DuckLake is static in this runner; the separately built loadable binary still
# needs the PostgreSQL-wire/S3 gate. Keep these link options runner-only.
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL target_link_libraries
    unittest "-Wl,--start-group" /build/prebuilt/libduckdb_static.a
    /build/prebuilt/libduckdb_skiplistlib.a "-Wl,--end-group" dl m pthread)
