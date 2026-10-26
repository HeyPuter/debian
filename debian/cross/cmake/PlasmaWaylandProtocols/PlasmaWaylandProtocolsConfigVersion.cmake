# The build machine's version check without its 32/64-bit one: the package
# is protocol XML, the same for every target
set(CMAKE_SIZEOF_VOID_P_SAVED "${CMAKE_SIZEOF_VOID_P}")
set(CMAKE_SIZEOF_VOID_P "")
include(/usr/lib/x86_64-linux-gnu/cmake/PlasmaWaylandProtocols/PlasmaWaylandProtocolsConfigVersion.cmake)
set(CMAKE_SIZEOF_VOID_P "${CMAKE_SIZEOF_VOID_P_SAVED}")
unset(CMAKE_SIZEOF_VOID_P_SAVED)
