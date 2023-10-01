cmake_minimum_required(VERSION 3.24)


macro(get_version_number OUTPUT_VAR PATH)
    execute_process(
        COMMAND bash -c [[echo "$(set -- $(git rev-parse --short=8 HEAD | sed 's/\(..\)\(..\)\(..\)\(..\)/0x\1 0x\2 0x\3 0x\4/'); printf "%d.%d.%d.%d\n" $1 $2 $3 $4)"]]
        WORKING_DIRECTORY "${PATH}"
        OUTPUT_VARIABLE ${OUTPUT_VAR}
        OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY
    )
endmacro()


macro(_get_version_from_find_package_args OUTPUT_VAR)
    # QUIET gets appended before vesion, workaround to get version
    cmake_parse_arguments(arg
        "QUIET;EXACT;MODULE;REQUIRED;GLOBAL;NO_POLICY_SCOPE;BYPASS_PROVIDER"
        "REGISTRY_VIEW"
        "COMPONENTS;OPTIONAL_COMPONENTS"
        "${ARGV}"
    )

    list(GET arg_UNPARSED_ARGUMENTS 2 ${OUTPUT_VAR})   # arg 0 is OUTPUT_VAR, arg 1 is package name
endmacro()


macro(_minio_package_present OUTPUT_VAR PACKAGE_NAME VERSION)
    find_program(MINIO_CONSOLE mc REQUIRED)
    string(TOLOWER ${PACKAGE_NAME} LOWER_NAME)

    if(NOT DEFINED SUPERPROJECT_BUCKET)
        message(FATAL_ERROR "SUPERPROJECT_BUCKET must be defined")
    endif()
    execute_process(
        COMMAND ${MINIO_CONSOLE} head ${SUPERPROJECT_BUCKET}/${LOWER_NAME}/${VERSION}.tar.gz
        OUTPUT_QUIET
        ERROR_QUIET
        RESULT_VARIABLE ARTIFACT_FOUND
    )

    if(NOT ARTIFACT_FOUND)
        set(${OUTPUT_VAR} TRUE)
    else()
        set(${OUTPUT_VAR} FALSE)
    endif()
endmacro()


macro(_minio_get_and_extract PACKAGE_NAME VERSION)
    find_program(MINIO_CONSOLE mc REQUIRED)
    string(TOLOWER ${PACKAGE_NAME} LOWER_NAME)

    if(NOT DEFINED SUPERPROJECT_PACKAGE_CACHE_DIR)
        message(FATAL_ERROR "SUPERPROJECT_PACKAGE_CACHE_DIR must be defined")
    endif()
    set(PACKAGE_TAR ${SUPERPROJECT_PACKAGE_CACHE_DIR}/${LOWER_NAME}/${VERSION}.tar.gz)
    if(NOT DEFINED SUPERPROJECT_BUCKET)
        message(FATAL_ERROR "SUPERPROJECT_BUCKET must be defined")
    endif()

    if(EXISTS ${PACKAGE_TAR})
        set(MINIO_CP_RESULT 0)
    else()
        message("Downloading ${PACKAGE_NAME} (${VERSION}) to ${PACKAGE_TAR}.")
        execute_process(
            COMMAND ${MINIO_CONSOLE} cp ${SUPERPROJECT_BUCKET}/${LOWER_NAME}/${VERSION}.tar.gz ${PACKAGE_TAR}
            RESULT_VARIABLE MINIO_CP_RESULT
        )
    endif()

    if("${MINIO_CP_RESULT}" STREQUAL "0")
        file(ARCHIVE_EXTRACT
            INPUT ${PACKAGE_TAR}
            DESTINATION ${CMAKE_INSTALL_PREFIX}
            TOUCH
        )
    else()
        message(WARNING "Failed to pull ${PACKAGE_NAME} (${VERSION}) from minio server.")
    endif()
endmacro()


macro(_find_package PACKAGE_NAME)
    # Replacement for `find_package`, tries to populate installation directory with package from MinIO
    find_package(${ARGV} BYPASS_PROVIDER)  # use install if present
    _get_version_from_find_package_args(VERSION ${ARGV})

    if(NOT ${PACKAGE_NAME}_FOUND)
        find_program(MINIO_CONSOLE mc)

        if(DEFINED MINIO_CONSOLE)
            _minio_package_present(IS_PRESENT ${PACKAGE_NAME} ${VERSION})
            if(IS_PRESENT)
                _minio_get_and_extract(${PACKAGE_NAME} ${VERSION})
            else()
                message("Pre-built ${PACKAGE_NAME} (${VERSION}) package not present locally or on servers, building from source.")
            endif()
            # ${PACKAGE_NAME} not set, fall through to built in find_package
        endif()
    endif()
endmacro()


macro(_provide_dependency METHOD PACKAGE_NAME)
    if(NOT DEFINED SUPERPROJECT_PACKAGE_REGEX)
        message(FATAL_ERROR "SUPERPROJECT_PACKAGE_REGEX must be defined")
    endif()
    if("${METHOD}" STREQUAL "FIND_PACKAGE" AND "${PACKAGE_NAME}" MATCHES "${SUPERPROJECT_PACKAGE_REGEX}")
        set(MUTABLE_ARGS ${ARGV})
        list(REMOVE_AT MUTABLE_ARGS 0)
        _find_package(${MUTABLE_ARGS})
    endif()   # ELSE fall-back to built-in provider
endmacro()


cmake_language(
    SET_DEPENDENCY_PROVIDER _provide_dependency
    SUPPORTED_METHODS FIND_PACKAGE
)

