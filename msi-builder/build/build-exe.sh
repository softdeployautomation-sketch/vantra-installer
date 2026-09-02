#!/bin/bash

# Vantra Branded EXE Build Script
# Usage: ./build-exe.sh --vbs-path /path/to/installer.vbs \
#                       [--ico-path /path/to/custom.ico] \
#                       --output /path/to/installer.exe

VBS_PATH=""
ICO_PATH=""
OUTPUT_PATH=""

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --vbs-path)
            VBS_PATH="$2"
            shift 2
            ;;
        --ico-path)
            ICO_PATH="$2"
            shift 2
            ;;
        --output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$VBS_PATH" ]]; then
    echo "Error: --vbs-path is required (path to the generated installer.vbs)"
    exit 1
fi
if [[ -z "$OUTPUT_PATH" ]]; then
    echo "Error: --output is required (path where installer.exe should be written)"
    exit 1
fi

# Check x86_64-w64-mingw32-gcc is installed
if ! command -v x86_64-w64-mingw32-gcc &> /dev/null; then
    echo "Error: x86_64-w64-mingw32-gcc not found. Install with:"
    echo "  sudo apt-get install gcc-mingw-w64-x86-64"
    exit 1
fi

# Check x86_64-w64-mingw32-windres is installed
if ! command -v x86_64-w64-mingw32-windres &> /dev/null; then
    echo "Error: x86_64-w64-mingw32-windres not found. Install with:"
    echo "  sudo apt-get install gcc-mingw-w64-x86-64"
    exit 1
fi

# Get script directory (where build-exe.sh is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Create temp build directory
BUILD_TEMP=$(mktemp -d)
trap "rm -rf $BUILD_TEMP" EXIT

# Copy the VBS launcher
if [[ ! -f "$VBS_PATH" ]]; then
    echo "Error: VBS file not found at: $VBS_PATH"
    exit 1
fi
cp "$VBS_PATH" "$BUILD_TEMP/launcher.vbs"

# Build the resource file
if [[ -n "$ICO_PATH" ]]; then
    if [[ ! -f "$ICO_PATH" ]]; then
        echo "Error: ICO file not found at: $ICO_PATH"
        exit 1
    fi
    cp "$ICO_PATH" "$BUILD_TEMP/custom.ico"
    cat > "$BUILD_TEMP/launcher.rc" <<EOF
1 ICON "custom.ico"
101 RCDATA "launcher.vbs"
EOF
else
    cat > "$BUILD_TEMP/launcher.rc" <<EOF
101 RCDATA "launcher.vbs"
EOF
fi

# Compile the resource file with windres
if ! x86_64-w64-mingw32-windres \
    --input-format=rc \
    --output-format=coff \
    -I "$BUILD_TEMP" \
    "$BUILD_TEMP/launcher.rc" \
    -o "$BUILD_TEMP/launcher.res"; then
    echo "Error: windres failed to compile resource file"
    exit 1
fi

# Create output directory if it doesn't exist
mkdir -p "$(dirname "$OUTPUT_PATH")"

# Compile the EXE with gcc
if ! x86_64-w64-mingw32-gcc \
    -mwindows \
    -s \
    -O2 \
    "$PROJECT_ROOT/src/launcher.c" \
    "$BUILD_TEMP/launcher.res" \
    -o "$OUTPUT_PATH"; then
    echo "Error: gcc failed to compile launcher EXE"
    exit 1
fi

# Print output and file size
echo "EXE build successful!"
ls -lh "$OUTPUT_PATH"