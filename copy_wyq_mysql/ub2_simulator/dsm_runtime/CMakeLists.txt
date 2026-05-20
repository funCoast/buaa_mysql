cmake_minimum_required(VERSION 3.16)

# 强制使用 GCC/G++：必须在 project() 之前设置；若已配置过，请删除 build 目录后重新运行 cmake
find_program(GCC_PATH gcc REQUIRED)
find_program(GXX_PATH g++ REQUIRED)
set(CMAKE_C_COMPILER   "${GCC_PATH}" CACHE FILEPATH "C compiler" FORCE)
set(CMAKE_CXX_COMPILER "${GXX_PATH}" CACHE FILEPATH "C++ compiler" FORCE)

project(ub2_simulator LANGUAGES C CXX)

# 工程根目录（本文件位于 dsm_runtime/ 下）
set(PROJ_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
set(SRC_DIR    "${PROJ_ROOT}/src")
set(INC_DIR    "${PROJ_ROOT}/include")

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# 对齐 Makefile: -g（Debug 信息）+ -Wall
add_library(build_options INTERFACE)
target_compile_options(build_options INTERFACE
  $<$<COMPILE_LANGUAGE:C>:-Wall -g>
  $<$<COMPILE_LANGUAGE:CXX>:-Wall -g>
)

# 对齐 Makefile: C11 / C++14（并发索引使用 shared_timed_mutex）
target_compile_features(build_options INTERFACE
  c_std_11
  cxx_std_14
)

# 头文件目录（Makefile: INCLUDES = -Iinclude）
target_include_directories(build_options INTERFACE 
  "${INC_DIR}"
  "${CMAKE_CURRENT_LIST_DIR}"  # 包含 dsm_runtime 目录，用于 dsm_config.h
)

# 对齐 Makefile: mpicc/mpicxx
find_package(MPI REQUIRED)
find_package(Threads REQUIRED)

# --- simulator (可执行文件) ---
add_executable(simulator
  "${PROJ_ROOT}/simulator.cpp"
  "${SRC_DIR}/addr_table.cpp"
  "${SRC_DIR}/export.cpp"
  "${SRC_DIR}/import.cpp"
  "${SRC_DIR}/libobmm_server.cpp"
  "${SRC_DIR}/addr_allocator.cpp"
)
target_link_libraries(simulator PRIVATE build_options MPI::MPI_C MPI::MPI_CXX)

# --- libobmm_client.a (静态库) ---
add_library(libobmm_client STATIC
  "${SRC_DIR}/libobmm_client.cpp"
)
set_target_properties(libobmm_client PROPERTIES OUTPUT_NAME "libobmm_client")
target_link_libraries(libobmm_client PRIVATE build_options MPI::MPI_CXX)

# --- example_client (可执行文件) ---
add_executable(example_client
  "${PROJ_ROOT}/example_client.c"
)
target_link_libraries(example_client PRIVATE build_options MPI::MPI_C libobmm_client)

# --- test_mpi_client (可执行文件) ---
add_executable(test_mpi_client
  "${PROJ_ROOT}/test_mpi_client.c"
)
target_link_libraries(test_mpi_client PRIVATE build_options MPI::MPI_C libobmm_client)

# --- uffd_shm_demo (可执行文件；Makefile: -D_GNU_SOURCE -lpthread) ---
# Makefile 默认不构建该 demo；仅在显式目标 `uffd_demo` 时构建
option(BUILD_UFFD_DEMO "Enable userfaultfd demo targets (built only via target uffd_demo)" OFF)
if(BUILD_UFFD_DEMO)
  find_package(Threads REQUIRED)

  # 不加入默认 ALL，避免影响正常构建
  add_executable(uffd_shm_demo EXCLUDE_FROM_ALL
    "${PROJ_ROOT}/uffd_shm_demo.c"
  )
  target_compile_definitions(uffd_shm_demo PRIVATE _GNU_SOURCE)
  target_link_libraries(uffd_shm_demo PRIVATE build_options Threads::Threads)

  # 对齐 Makefile: `make uffd_demo`
  add_custom_target(uffd_demo DEPENDS uffd_shm_demo)
endif()

# --- export_client (可执行文件；基于 dsm_runtime/export.cpp) ---
add_executable(export_client
  "${CMAKE_CURRENT_LIST_DIR}/export.cpp"
)
target_link_libraries(export_client PRIVATE build_options MPI::MPI_CXX libobmm_client)

add_executable(example_after_export
  "${CMAKE_CURRENT_LIST_DIR}/init.cpp"
)
target_link_libraries(example_after_export PRIVATE build_options MPI::MPI_CXX libobmm_client)

# --- concurrent_index_test (并发索引单元测试) ---
add_executable(concurrent_index_test
  "${CMAKE_CURRENT_LIST_DIR}/concurrent_index_test.cpp"
)
target_link_libraries(concurrent_index_test PRIVATE build_options)
target_link_libraries(concurrent_index_test PRIVATE Threads::Threads)

# --- dsm_runtime_lib (供 MySQL 等宿主进程链接的静态库) ---
# 包含纯 C++ 的 runtime 类 + dsm_bridge 薄接口，不依赖 MPI。
add_library(dsm_runtime_lib STATIC
  "${CMAKE_CURRENT_LIST_DIR}/runtime.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/dsm_bridge.cpp"
)
# 使用 -fPIC 便于被 MySQL 的共享模块链接
set_target_properties(dsm_runtime_lib PROPERTIES POSITION_INDEPENDENT_CODE ON)
target_include_directories(dsm_runtime_lib PUBLIC
  "${CMAKE_CURRENT_LIST_DIR}"
  "${INC_DIR}"
)
target_compile_features(dsm_runtime_lib PUBLIC cxx_std_14)
target_link_libraries(dsm_runtime_lib PUBLIC Threads::Threads)

# 供宿主项目（如 MySQL）通过 find_library 查找的头文件安装位置提示：
# /workspace/ub2_simulator/dsm_runtime (头) + 本目录/build/libdsm_runtime_lib.a (静态库)

# --- dsm_runtime_smoke: 独立的本地烟雾测试（不需要 simulator）---
add_executable(dsm_runtime_smoke EXCLUDE_FROM_ALL
  "${CMAKE_CURRENT_LIST_DIR}/runtime_smoke.cpp"
)
target_link_libraries(dsm_runtime_smoke PRIVATE build_options dsm_runtime_lib)