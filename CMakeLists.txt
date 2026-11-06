# SPDX-License-Identifier: GPL-2.0-or-later
#
# CMake build of AHCIASPI's native transports (C, for OpenASPI's native
# layer in 32/64-bit kernels such as GonWare's GDOS). The DOS manager keeps
# its Makefile.
#
# Needs the OpenASPI::native target: a parent project provides it, or
# OPENASPI_SOURCE_DIR points to an OpenASPI checkout (default: ../OpenAspi
# or ../OpenASPI next to this one).

cmake_minimum_required(VERSION 3.20)
project(AHCIASPI LANGUAGES C)

if(NOT TARGET OpenASPI::native)
  set(OPENASPI_SOURCE_DIR "" CACHE PATH "OpenASPI source tree")
  if(NOT OPENASPI_SOURCE_DIR)
    foreach(_d OpenAspi OpenASPI)
      if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../${_d}/CMakeLists.txt")
        set(OPENASPI_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../${_d}")
      endif()
    endforeach()
  endif()
  if(NOT OPENASPI_SOURCE_DIR)
    message(FATAL_ERROR "AHCIASPI: set OPENASPI_SOURCE_DIR to an OpenASPI checkout")
  endif()
  add_subdirectory("${OPENASPI_SOURCE_DIR}" openaspi EXCLUDE_FROM_ALL)
endif()

add_library(ahciaspi_native STATIC native/ahci.c)
target_include_directories(ahciaspi_native PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(ahciaspi_native PUBLIC OpenASPI::native)
set_target_properties(ahciaspi_native PROPERTIES C_STANDARD 90 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF)
add_library(AHCIASPI::native ALIAS ahciaspi_native)

if(PROJECT_IS_TOP_LEVEL)
  target_compile_options(ahciaspi_native PRIVATE -Wall -Wextra -Werror -pedantic)
endif()
