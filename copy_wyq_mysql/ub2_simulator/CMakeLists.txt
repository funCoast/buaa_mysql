cmake_minimum_required(VERSION 3.10)
project(obmm_simulator 
    VERSION 2.1.0
    LANGUAGES C CXX
    DESCRIPTION "OBMM Simulator - Memory Management Simulator"
)

# ============================================================================
# compile options
# ============================================================================
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall -g")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -g")

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# ============================================================================
# requirements check
# ============================================================================
find_package(MPI REQUIRED COMPONENTS C CXX)

# ============================================================================
# include directory
# ============================================================================
include_directories(${CMAKE_SOURCE_DIR}/include)

# ============================================================================
# source file
# ============================================================================
set(SERVER_SOURCES
        simulator.cpp
    src/addr_table.cpp
    src/export.cpp
    src/import.cpp
    src/libobmm_server.cpp
    src/addr_allocator.cpp
)

set(CLIENT_SOURCES
    src/libobmm_client.cpp
        include/libobmm_client.h
        include/libobmm_cacheable.hpp
        src/obmm_cacheable.cpp
)

# ============================================================================
# build target: client lib
# ============================================================================
add_library(obmm_client STATIC ${CLIENT_SOURCES})
target_include_directories(obmm_client 
    PUBLIC 
        ${CMAKE_SOURCE_DIR}/include
        ${MPI_C_INCLUDE_PATH}
)
target_compile_options(obmm_client PRIVATE ${MPI_C_COMPILE_FLAGS})
target_link_libraries(obmm_client PRIVATE pthread)
target_compile_definitions(obmm_client PRIVATE _GNU_SOURCE)

# ============================================================================
# build target: simulator server
# ============================================================================
add_executable(simulator ${SERVER_SOURCES})
target_link_libraries(simulator 
    PRIVATE
        ${MPI_C_LIBRARIES}
        ${MPI_CXX_LIBRARIES}
)
target_include_directories(simulator 
    PRIVATE 
        ${MPI_C_INCLUDE_PATH}
        ${MPI_CXX_INCLUDE_PATH}
)
target_compile_options(simulator 
    PRIVATE 
        ${MPI_C_COMPILE_FLAGS}
        ${MPI_CXX_COMPILE_FLAGS}
)

# ============================================================================
# build target: example user program
# ============================================================================
add_executable(example_client example_client.c)
target_link_libraries(example_client PRIVATE obmm_client)
target_include_directories(example_client 
    PRIVATE 
        ${MPI_C_INCLUDE_PATH}
)
target_compile_options(example_client PRIVATE ${MPI_C_COMPILE_FLAGS})

# ============================================================================
# build target: example user program (MPI)
# ============================================================================
add_executable(test_mpi_client test_mpi_client.c)
target_link_libraries(test_mpi_client 
    PRIVATE 
        obmm_client
        ${MPI_C_LIBRARIES}
)
target_include_directories(test_mpi_client 
    PRIVATE 
        ${MPI_C_INCLUDE_PATH}
)
target_compile_options(test_mpi_client PRIVATE ${MPI_C_COMPILE_FLAGS})

# ============================================================================
# build target: page fault demo
# ============================================================================
add_executable(uffd_shm_demo demo/uffd_shm_demo.c)
target_compile_definitions(uffd_shm_demo PRIVATE _GNU_SOURCE)
target_link_libraries(uffd_shm_demo PRIVATE pthread)

add_executable(uffd_move_pool_demo demo/uffd_move_pool_demo.c)
target_compile_definitions(uffd_move_pool_demo PRIVATE _GNU_SOURCE)
target_link_libraries(uffd_move_pool_demo PRIVATE pthread)

# ============================================================================
# build target: OBMM Cacheable MPI test
# ============================================================================
add_executable(test_obmm_cacheable_mpi test_obmm_cacheable_mpi.cpp)
target_link_libraries(test_obmm_cacheable_mpi 
    PRIVATE 
        obmm_client
        ${MPI_CXX_LIBRARIES}
        pthread
)
target_include_directories(test_obmm_cacheable_mpi 
    PRIVATE 
        ${CMAKE_SOURCE_DIR}/include
        ${MPI_CXX_INCLUDE_PATH}
)
target_compile_options(test_obmm_cacheable_mpi 
    PRIVATE 
        ${MPI_CXX_COMPILE_FLAGS}
)
target_compile_definitions(test_obmm_cacheable_mpi PRIVATE _GNU_SOURCE)

# ============================================================================
# for install
# ============================================================================
install(TARGETS obmm_client
    ARCHIVE DESTINATION lib
    LIBRARY DESTINATION lib
)

install(TARGETS simulator example_client test_mpi_client test_obmm_cacheable_mpi uffd_shm_demo
    RUNTIME DESTINATION bin
)

install(DIRECTORY include/
    DESTINATION include
    FILES_MATCHING PATTERN "*.h"
)
