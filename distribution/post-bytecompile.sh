#!/usr/bin/env bash

#####
#
# "bytecompile" applicable lua files
#
# We wish to avoid relying on the user having to set $LUA_PATH or
# KONG_LUA_PACKAGE_PATH (or other techniques).
# Thus, move all .ljbc under an OpenResty-supported $LUA_PATH value,
# since we cannot specify our own at compile-time for now.
#
#####

# unofficial strict mode
set -euo pipefail
IFS=$'\n\t'

if [ -n "${DEBUG:-}" ]; then
    set -x
fi

SOURCE_TREE="${SOURCE_TREE:-/tmp/build/usr/local/share/lua/5.1/kong}"
SOURCE_DIRS="${SOURCE_DIRS:-gql enterprise_edition keyring openid-connect plugins}"
DESTINATION="${DESTINATION:-/tmp/build/usr/local/openresty/site/lualib/kong}"

SOURCE_DIRS=$(echo "$SOURCE_DIRS" | tr " " "\n")

function main() {
    echo '--- bytecompiling lua scripts ---'

    if [ -z "${ENABLE_LJBC:-}" ]; then
        echo "\$ENABLE_LJBC not set, skipping bytecompilation"
        return 0
    else
        echo "\$ENABLE_LJBC set, compiling Kong Lua sources"
    fi

    mkdir -pv "$DESTINATION"

    for subdirectory in $SOURCE_DIRS; do
        src="${SOURCE_TREE}/${subdirectory}"

        find "$src" -type f -name '*.lua' -print | while read -r source_path; do

            relative_path="${source_path//$src\//}"
            destination_path="${DESTINATION}/${subdirectory}/${relative_path}"

            mkdir -pv "$(dirname "$destination_path")"

            luajit \
                -b \
                -g \
                -t raw \
                -- \
                "$source_path" \
                "${destination_path//.lua/.ljbc}"

            rm -fv "$source_path"
        done
    done

    if [ -z "$(find "$DESTINATION" -type f -name '*.ljbc' -print)" ]; then
        echo "did not find any *.ljbc files at destination: ${DESTINATION}"
        exit 1
    fi

    find "${DESTINATION}/" -name '*.ljbc' -print

    echo '--- bytecompiled lua scripts ---'
}

main