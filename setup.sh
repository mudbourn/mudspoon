#!/usr/bin/env bash
# mudspoon runtime build #
    # Builds the Lua 5.4 runtime in runtime/ from source: lua.exe, lua54.dll and
    # cffi.dll (cffi-lua with libffi linked in), patched by runtime/cffi-lua.patch.
    # Run in Git Bash on the Windows PC. Needs gcc, g++ and ar from a
    # MinGW-w64 toolchain (WinLibs UCRT), plus curl, git and tar.
    # Usage: ./setup.sh [build-dir]   default ./.runtime-build
    # Set SOURCE_CACHE to a folder that already holds the three source archives.
# END #

set -euo pipefail

# Config #
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BUILD_DIR="${1:-$ROOT/.runtime-build}"
    LUA_VERSION="5.4.7"
    LIBFFI_VERSION="3.4.6"
    CFFI_REPO="https://github.com/q66/cffi-lua"
    CFFI_COMMIT="2621884230c9072ad77f7379609b74c9d6dbeb86"
    LUA_URL="https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz"
    LIBFFI_URL="https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz"
# END #

# Preflight #
    for tool in gcc g++ ar curl git tar; do
        command -v "$tool" >/dev/null || { echo "$tool not found"; exit 1; }
    done
# END #

# Fetch sources #
    mkdir -p "$BUILD_DIR/dl" "$BUILD_DIR/src" "$BUILD_DIR/out"

    CACHE="${SOURCE_CACHE:-$BUILD_DIR/dl}"

    [ -f "$CACHE/lua-$LUA_VERSION.tar.gz" ] || curl -sSL -o "$CACHE/lua-$LUA_VERSION.tar.gz" "$LUA_URL"

    [ -f "$CACHE/libffi-$LIBFFI_VERSION.tar.gz" ] || curl -sSL -o "$CACHE/libffi-$LIBFFI_VERSION.tar.gz" "$LIBFFI_URL"

    tar xzf "$CACHE/lua-$LUA_VERSION.tar.gz" -C "$BUILD_DIR/src"

    tar xzf "$CACHE/libffi-$LIBFFI_VERSION.tar.gz" -C "$BUILD_DIR/src"

    if [ ! -d "$BUILD_DIR/src/cffi-lua" ]; then
        git -c core.autocrlf=false clone "$CFFI_REPO" "$BUILD_DIR/src/cffi-lua"

        git -C "$BUILD_DIR/src/cffi-lua" checkout "$CFFI_COMMIT"

        git -C "$BUILD_DIR/src/cffi-lua" apply "$ROOT/runtime/cffi-lua.patch"
    fi
# END #

# Build Lua #
    LUA_SRC="$BUILD_DIR/src/lua-$LUA_VERSION/src"

    mkdir -p "$BUILD_DIR/obj/lua"

    LIB_SOURCES="lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject lopcodes lparser lstate lstring ltable ltm lundump lvm lzio lauxlib lbaselib lcorolib ldblib liolib lmathlib loadlib loslib lstrlib ltablib lutf8lib linit"

    OBJECTS=""

    for name in $LIB_SOURCES; do
        gcc -O2 -DLUA_BUILD_AS_DLL -c "$LUA_SRC/$name.c" -o "$BUILD_DIR/obj/lua/$name.o"

        OBJECTS="$OBJECTS $BUILD_DIR/obj/lua/$name.o"
    done

    gcc -shared -o "$BUILD_DIR/out/lua54.dll" $OBJECTS -Wl,--out-implib,"$BUILD_DIR/out/liblua54.dll.a"

    gcc -O2 -DLUA_BUILD_AS_DLL -c "$LUA_SRC/lua.c" -o "$BUILD_DIR/obj/lua/lua_main.o"

    gcc -o "$BUILD_DIR/out/lua.exe" "$BUILD_DIR/obj/lua/lua_main.o" -L"$BUILD_DIR/out" -llua54 -static-libgcc
# END #

# Build libffi #
    mkdir -p "$BUILD_DIR/obj/libffi"

    FFI_SRC="$BUILD_DIR/src/libffi-$LIBFFI_VERSION"

    FFI_DIR="$BUILD_DIR/obj/libffi"

    (
        cd "$FFI_DIR"

        "$FFI_SRC/configure" --disable-shared --enable-static --disable-docs --disable-dependency-tracking CC=gcc
    )

    FFI_OBJECTS=""

    for name in prep_cif types raw_api java_raw_api closures tramp; do
        gcc -w -O2 -DHAVE_CONFIG_H -I"$FFI_DIR" -I"$FFI_DIR/include" -I"$FFI_SRC/include" -I"$FFI_SRC/src" \
            -c "$FFI_SRC/src/$name.c" -o "$FFI_DIR/$name.o"

        FFI_OBJECTS="$FFI_OBJECTS $FFI_DIR/$name.o"
    done

    gcc -w -O2 -DHAVE_CONFIG_H -I"$FFI_DIR" -I"$FFI_DIR/include" -I"$FFI_SRC/include" -I"$FFI_SRC/src" \
        -c "$FFI_SRC/src/x86/ffiw64.c" -o "$FFI_DIR/ffiw64.o"

    gcc -w -O2 -DHAVE_CONFIG_H -I"$FFI_DIR" -I"$FFI_DIR/include" -I"$FFI_SRC/include" -I"$FFI_SRC/src" \
        -c "$FFI_SRC/src/x86/win64.S" -o "$FFI_DIR/win64.o"

    ar cr "$FFI_DIR/libffi.a" $FFI_OBJECTS "$FFI_DIR/ffiw64.o" "$FFI_DIR/win64.o"
# END #

# Build cffi-lua #
    mkdir -p "$BUILD_DIR/obj/cffi"

    for name in util ffilib parser ast lib ffi main; do
        g++ -std=c++14 -O2 -fno-rtti -fno-exceptions -DFFI_LITTLE_ENDIAN -DCFFI_LUA_DLL \
            -I"$LUA_SRC" -I"$FFI_DIR/include" -I"$FFI_DIR" \
            -c "$BUILD_DIR/src/cffi-lua/src/$name.cc" -o "$BUILD_DIR/obj/cffi/$name.o"
    done

    g++ -shared -o "$BUILD_DIR/out/cffi.dll" "$BUILD_DIR"/obj/cffi/*.o "$FFI_DIR/libffi.a" \
        -L"$BUILD_DIR/out" -llua54 -static-libgcc -static-libstdc++
# END #

# Install into runtime/ #
    cp "$BUILD_DIR/out/lua.exe" "$BUILD_DIR/out/lua54.dll" "$BUILD_DIR/out/cffi.dll" "$ROOT/runtime/"

    "$ROOT/runtime/lua.exe" -E -v

    echo "runtime ready in $ROOT/runtime"
# END #
