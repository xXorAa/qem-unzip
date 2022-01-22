cmake_minimum_required(VERSION 3.7)

project(qem-unzip)

find_package(PkgConfig)
pkg_check_modules(LIBZIP REQUIRED IMPORTED_TARGET libzip)

include_directories(${CMAKE_CURRENT_LIST_DIR} include/ ${LIBZIP_INCLUDE_DIRS})

add_executable(qem-unzip
    src/qem-unzip.c
    src/sqlux_hexdump.c
    )

target_link_libraries(qem-unzip
    PkgConfig::LIBZIP)

install(TARGETS qem-unzip
	DESTINATION ${CMAKE_INSTALL_PREFIX}/bin/
	)
