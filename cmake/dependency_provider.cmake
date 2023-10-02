cmake_minimum_required(VERSION 3.24)

# dependecy_provider.cmake : implementation of a dependency provider with versioning and minio artifact storage
#
# Expects:
#   - ${SUPERPROJECT_BUCKET}              : bucket on minio server storing pre-built artifacts
#   - ${SUPERPROJECT_PACKAGE_REGEX}       : regex matching projects stored on minio server
#   - ${SUPERPROJECT_PACKAGE_CACHE_DIR}   : local directory to use as download cache
#
# Usage in super-project:
#    cmake -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=<project-root>/cmake/dependency_provider.cmake
# or
#    list(APPEND CMAKE_PROJECT_TOP_LEVEL_INCLUDES ${CMAKE_CURRENT_SOURCE_DIR}/cmake/dependency_provider.cmake)
#
# Usage in sub-project:
#    include(CMakePackageConfigHelpers)

#    configure_package_config_file(
#        cmake/<subproject>Config.cmake.in
#        "${CMAKE_CURRENT_BINARY_DIR}/<subproject>Config.cmake"
#        INSTALL_DESTINATION share/cmake/<subproject>
#    )
#
#
#    if(GIT_INTEGRATIONS)
#        get_version_number(<subproject>_INTERNAL_VERSION_NUMBER ${CMAKE_CURRENT_SOURCE_DIR})
#    else()
#        # always added as subdirectory if git is not available
#        set(<subproject>_INTERNAL_VERSION_NUMBER 00.00.00.00)
#    endif()
#
#    message("Configuring <subproject> with internal version number: ${<subproject>_INTERNAL_VERSION_NUMBER}")
#    write_basic_package_version_file(
#        "${CMAKE_CURRENT_BINARY_DIR}/<subproject>ConfigVersion.cmake"
#        VERSION ${<subproject>_INTERNAL_VERSION_NUMBER}
#        COMPATIBILITY ExactVersion
#    )
#
#    install(
#        FILES
#            "${CMAKE_CURRENT_BINARY_DIR}/<subproject>Config.cmake"
#            "${CMAKE_CURRENT_BINARY_DIR}/<subproject>ConfigVersion.cmake"
#        DESTINATION share/cmake/<subproject>
#    )



#! get_version_number : generates a valid four-part decimal version for a git repo
#
# Function mapping a git hash to a four-part version of the form \d+\.\d+\.\d+\.\d+
# for use with cmake find_package version arguments
#
# \arg:OUTPUT_VAR   variable to store the version in
# \arg:PATH         path to the repo under versioning
#
macro(get_version_number OUTPUT_VAR PATH)
    execute_process(
        COMMAND bash -c [[echo "$(set -- $(git rev-parse --short=8 HEAD | sed 's/\(..\)\(..\)\(..\)\(..\)/0x\1 0x\2 0x\3 0x\4/'); printf "%d.%d.%d.%d\n" $1 $2 $3 $4)"]]
        WORKING_DIRECTORY "${PATH}"
        OUTPUT_VARIABLE ${OUTPUT_VAR}
        OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY
    )
endmacro()


#! _get_version_from_find_package_args : extract the version argument from the arguments of a find_package call
#
# \arg:OUTPUT_VAR   variable to store the version in
#
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


#! _minio_package_present : query minio server for package with version
#
# Return True if package is present on server, otherwise return false.
# Assumes package is stored at ${SUPERPROJECT_BUCKET}/${LOWER_NAME}/${VERSION}.tar.gz
#
# \arg:OUTPUT_VAR     variable to store the result (true|false) in
# \arg:PACKAGE_NAME   name of the package to query
# \arg:VERSION        version of the package to query, c.f. get_version_number
#
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


#! _minio_get_and_extract : get the package from minio and extract it
#
# Get the package from minio server and extract tar.gz to:
#     ${SUPERPROJECT_PACKAGE_CACHE_DIR}/${LOWER_NAME}/${VERSION}.tar.gz
#
# \arg:PACKAGE_NAME   name of the package to query
# \arg:VERSION        version of the package to query, c.f. get_version_number
#
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


#! _find_package : find_package with minio server integration
#
# Wraps find_package to first query server for pre-built package before
# defering to original implementation
#
# \arg:PACKAGE_NAME   name of the package to query
#
macro(_find_package PACKAGE_NAME)
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


#! _provide_dependency : dependency provider with minio integration
#
# Wrap find_package for packages matching "${SUPERPROJECT_PACKAGE_REGEX}"
# to check for pre-built packages on server before using built-in find_package
#
# \arg:METHOD         find_package or fetchcontent_makeavailable
# \arg:PACKAGE_NAME   name of the package to query
#
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

