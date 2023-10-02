# CMake: FetchContent-Based Superbuild

We recently moved to a new hardware-architecture at work, a process that comes with a lot of changes as we reconsider the approaches we took on the last architecture, decide which code we want to keep and where we want to start over, and generally re-evaluate how we go about doing things. This has been great for me, as I've had a chance to advocate for a lot of the things that I think could bring up our code quality across the board (type hinting in Python!).

One of the things that I took an interest in during this period is how we can better manager our dependencies and otherwise modernize our build process. We have some minor forks of huge projects (LLVM, I am looking at you) which comprise the majority of our build time despite seeing only a small amount of development. On a fresh build of our compiler, our own components represents less than 30s of build time while LLVM takes about an hour on our laptops. Just configuring LLVM takes 20-30s. For the vast majority of developers who never make changes to these components, this is purely a waste of time. With our CI building LLVM all the time, why can't we just take the artifacts from the CI servers and use them locally?

Essentially, the flow we were looking for has CMake using the pre-built CI artifacts if there are no changes in the components. The components were already included as submodules (ah...), so the challenge amounted to:
- determine whether the source code of a component matched the source code used to build an artifact on CI
- expose CI artifacts in such a way that they could be used transparently as build dependencies of other components transparently

As of CMake 3.24, cmake has the tools necessary to (mostly) solve both of these problems.

## Find Package and Fetch Content

If you aren't familiar with these:
- `find_package` is a function used to find pre-built package binaries in the local filesystem
- `FetchContent` is a collection of related functionality used to download and build projects from source

We will be using the `FIND_PACKAGE_ARGS` argument to `FetchContent_Declare`. `FIND_PACKAGE_ARGS` was introduced in CMake 3.24, and allows a user to pass a list of arguments to forward to a `find_package` call that happens before any source is fetched by `FetchContent`. If the call succeeds, `FetchContent` is skipped.

### Find Package Configs

`find_package` uses configuration files installed with the package to determine:
1. whether a package satisfies a dependency;
2. which variables/targets the package exports.

CMake is capable of generating the config files itself, but this requires some changes to the `CMakeLists.txt`. For information about how to write and use configuration files for your projects, see the [CMake documentation](https://cmake.org/cmake/help/latest/command/find_package.html#id8).

For external projects that aren't shipped with config files, one can incorporate the dependency with a [find module](https://cmake.org/cmake/help/latest/manual/cmake-developer.7.html#find-modules).

## Dependency Providers

[Dependency providers](https://cmake.org/cmake/help/latest/command/cmake_language.html#dependency-providers) were also introduced in 3.24 and provide a mechanism to replace all calls to `find_package` and `FetchContent` with custom logic. Dependency providers are declared in a seperate file and included via `CMAKE_PROJECT_TOP_LEVEL_INCLUDES`. This makes them particularly convenient for changing the way that a project sets up its dependencies without changing the CMake code of the project itself.

For this use case, we modify the `find_package` call to first query an external object store for artifacts matching those that will be built. If the artifacts are found, they are downloaded to a cache directory and copied into the installation directory for use in the project, otherwise `FetchContent` is allowed to proceed as usual.

## Versioning

Versioning is handled by splitting the 8 digit hexadecimal git hash of each submodule into 4 and converting each part into a decimal (for compatibility with CMake version specifiers). When artifacts are packaged, the version information is included in their `find_package` Config files, where it is used to filter out queries for version specifiers that do not match exactly.

Other versioning schemes are possible, this was just convenient for us. In particular, version schemes that include information about the build environment could be useful (c.f. [Known Issues](#known-issues)).

## Usage

Subprojects are delcared in the top-level `CMakeLists.txt` file as follows:
```cmake
include(CMakeDependentOption)

set(SUPERPROJECT_BUCKET ...)
set(SUPERPROJECT_PACKAGE_REGEX ...)
set(SUPERPROJECT_PACKAGE_CACHE_DIR ...)

# OPTIONS
option(FORCE_ALL_FROM_SOURCE "Build all subprojects from source" OFF)
cmake_dependent_option(FORCE_<project>_FROM_SOURCE "Force <project> to build from source"
    #[[Value if Cond]] OFF
    #[[Cond]] "NOT FORCE_ALL_FROM_SOURCE"
    #[[Value if not Cond]] ON
)
cmake_dependent_option(REQUIRE_<project>_FOUND "Fail if a pre-built <project> is not found"
    #[[Value if Cond]] OFF
    #[[Cond]] "NOT FORCE_<project>_FROM_SOURCE"
    #[[Value if not Cond]] OFF
)

# PROJECT CONTROL
get_version_number(<project>_VERSION ${CMAKE_SOURCE_DIR}/src/<project>)
if(NOT ${FORCE_<project>_FROM_SOURCE})
    set(<project>_ADDITIONAL_FETCH_CONTENT_ARGS
            FIND_PACKAGE_ARGS ${<project>_VERSION} CONFIG NO_DEFAULT_PATH PATHS ${CMAKE_INSTALL_PREFIX}
    )
    if(REQUIRE_<project>_FOUND)
        list(APPEND <project>_ADDITIONAL_FETCH_CONTENT_ARGS REQUIRED)
    endif()
endif()

FetchContent_Declare(<project>
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/src/<project>/
    BINARY_DIR ${CMAKE_BINARY_DIR}/src/<project>/
    INSTALL_DIR ${CMAKE_INSTALL_PREFIX}
    ${<project>_ADDITIONAL_FETCH_CONTENT_ARGS}
)

# Reconfiguration is run automatically when this file is changed, i.e. branch pointer moves
# All of the logic for find_package vs FetchContent happens at configuration time
# This can lead to unexpected behaviour when running the build step alone if any
# files in the subproject, c.f. known issues
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/.git/modules/<project>/HEAD)

list(APPEND NAMES_TO_MAKE_AVAILABLE <project>)

# After all subprojects have been declared
FetchContent_MakeAvailable(${NAMES_TO_MAKE_AVAILABLE})
```

The sub-project should expose its information, including an appropriate version number, in a `find_package` Config file:
```cmake
# Example target export
add_library(example_lib ...)

# Export target at install
install(
    TARGETS example_lib
    EXPORT ExampleLibExports
    LIBRARY DESTINATION lib
)

# Install exported target
install(
    EXPORT ExampleLibExports
    FILE ExampleLibTargets.cmake
    DESTINATION share/cmake/<package>
    NAMESPACE <package>::
)

# Alias lib with namespace to ensure target has same name when included via find_package and FetchContent
add_library(<package>::example_lib ALIAS example_lib)

get_version_number(<package>_INTERNAL_VERSION_NUMBER ${CMAKE_CURRENT_SOURCE_DIR})

message("Configuring <package> with internal version number: ${<package>_INTERNAL_VERSION_NUMBER}")
write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/<package>ConfigVersion.cmake"
    VERSION ${<package>_INTERNAL_VERSION_NUMBER}
    COMPATIBILITY ExactVersion
)

install(
    FILES
        "${CMAKE_CURRENT_BINARY_DIR}/<package>Config.cmake"
        "${CMAKE_CURRENT_BINARY_DIR}/<package>ConfigVersion.cmake"
    DESTINATION share/cmake/<package>
)
```

## Known Issues

This approach suffers from two problems:
- developers working on submodules optionally provided as artifacts must make a commit to the submodule for CMake to detect that the project has changed. The subprojects are configured to use the latest commit for versioning, so until the branch pointer moves off the main branch artifacts from the main branch will continue to be used. Once the branch pointer moves, artifact usage is disabled and subprojects build from source until the configure stage is run again.
- subproject versioning only accounts for changes to the submodules, it does not incorporate any information about the CMake variables passed through to the subproject from the super-project. This can cause a discrepency between the artifacts used and the artifacts that would have been produced if they had been rebuilt.

For both these cases, the best approach is for the developer to force the subprojects to build from source, either temporarily or permanently.
