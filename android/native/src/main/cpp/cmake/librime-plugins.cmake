# Plugin sources pinned by commit and checksum (SebType). The override/librime_plugins cmakes build
# them from where they are extracted.
# Lua comes from the official GitHub mirror of lua.org.
download_and_extract(
    "lua"
    "5.4.9"
    ".tar.gz"
    "https://github.com/lua/lua/archive/refs/tags/v5.4.9.tar.gz"
    "76def9b3b100e029bfbe37c985d869d0ed993a0cf1a157df282d6dcd9d6a4e15"
)

download_and_extract(
    "librime-lua"
    "6da5d6cedb853380ed1b5b9b6979cb1a9c028353"
    ".tar.gz"
    "https://github.com/hchunhui/librime-lua/archive/6da5d6cedb853380ed1b5b9b6979cb1a9c028353.tar.gz"
    "300a65a7bdb59496cdfb49d70f2137f838bc44d8e889a2c37c332f4dee8bf52e"
)

download_and_extract(
    "librime-octagram"
    "57d18b9f58e5284bd891d559f6bdd16cf60341e9"
    ".tar.gz"
    "https://github.com/lotem/librime-octagram/archive/57d18b9f58e5284bd891d559f6bdd16cf60341e9.tar.gz"
    "7b9c77bcf17566b64204791b72cdb1b4471e22efec5eef9b79ca764ab99a1576"
)
