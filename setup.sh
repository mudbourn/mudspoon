#!/usr/bin/env bash
# mudspoon Windows setup #
    # Builds LuaJIT with MSVC and installs it, so the spike can run.
    # Run in Git Bash on the Windows PC. Needs git and Visual Studio
    # Build Tools with the Desktop C++ workload already installed.
    # Usage: ./setup.sh [install-dir]   default C:\tools\luajit
# END #

set -euo pipefail

# Config #
    INSTALL_DIR="${1:-/c/tools/luajit}"
    BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.luajit-build"
    LUAJIT_REPO="https://luajit.org/git/luajit.git"
# END #

# Preflight #
    command -v git >/dev/null || { echo "git not found"; exit 1; }
    command -v cygpath >/dev/null || { echo "cygpath not found, run this in Git Bash"; exit 1; }

    VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    [ -x "$VSWHERE" ] || { echo "vswhere not found, install Visual Studio Build Tools"; exit 1; }
# END #

# Already installed #
    if [ -x "$INSTALL_DIR/luajit.exe" ]; then
        echo "luajit already at $INSTALL_DIR"
        exit 0
    fi
# END #

# Locate MSVC #
    VS_PATH="$("$VSWHERE" -latest -products '*' \
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
        -property installationPath)"
    [ -n "$VS_PATH" ] || { echo "no MSVC C++ toolset found, add the Desktop C++ workload"; exit 1; }

    VCVARS="$VS_PATH\\VC\\Auxiliary\\Build\\vcvars64.bat"
# END #

# Fetch source #
    if [ ! -d "$BUILD_DIR" ]; then
        git clone "$LUAJIT_REPO" "$BUILD_DIR"
    fi
# END #

# Build #
    SRC_WIN="$(cygpath -w "$BUILD_DIR/src")"
    cmd //c "call \"$VCVARS\" && cd /d \"$SRC_WIN\" && msvcbuild.bat"
# END #

# Install #
    mkdir -p "$INSTALL_DIR"
    cp "$BUILD_DIR/src/luajit.exe" "$INSTALL_DIR/"
    cp "$BUILD_DIR/src/lua51.dll" "$INSTALL_DIR/"
    echo "installed luajit to $INSTALL_DIR"
# END #

# Path hint #
    INSTALL_WIN="$(cygpath -w "$INSTALL_DIR")"
    echo ""
    echo "Add to PATH if it is not already there:"
    echo "    setx PATH \"%PATH%;$INSTALL_WIN\""
    echo ""
    echo "Then from the share, at the physical console:"
    echo "    luajit spike_hook_loop_alert.lua"
# END #
