#!/bin/bash

# Vantra Branded EXE Build Script
# Usage: ./build-exe.sh --vbs-path /path/to/installer.vbs \
#                       [--ico-path /path/to/custom.ico] \
#                       --output /path/to/installer.exe

VBS_PATH=""
ICO_PATH=""
OUTPUT_PATH=""
MANUFACTURER=""

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
        --manufacturer)
            MANUFACTURER="$2"
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
if [[ -z "$MANUFACTURER" ]]; then
    MANUFACTURER="Vantra Technologies"
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

# Generate random version numbers for the VERSIONINFO block
VER_MAJOR=$(shuf -i 2-5 -n 1)
VER_MINOR=$(shuf -i 0-9 -n 1)
VER_PATCH=$(shuf -i 0-99 -n 1)
VER_STR="${VER_MAJOR}.${VER_MINOR}.${VER_PATCH}.0"
VER_CSV="${VER_MAJOR},${VER_MINOR},${VER_PATCH},0"
CUR_YEAR=$(date +%Y)

# Write application manifest (requireAdministrator + modern OS compatibility)
cat > "$BUILD_TEMP/launcher.manifest" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="1.0.0.0" name="setup" type="win32"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
    </application>
  </compatibility>
</assembly>
EOF

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
1 24 "launcher.manifest"
101 RCDATA "launcher.vbs"
VS_VERSION_INFO VERSIONINFO
 FILEVERSION     $VER_CSV
 PRODUCTVERSION  $VER_CSV
 FILEFLAGSMASK   0x3fL
 FILEFLAGS       0x0L
 FILEOS          0x40004L
 FILETYPE        0x1L
 FILESUBTYPE     0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "CompanyName",      "$MANUFACTURER\0"
            VALUE "FileDescription",  "Remote Management Setup\0"
            VALUE "FileVersion",      "$VER_STR\0"
            VALUE "InternalName",     "setup\0"
            VALUE "LegalCopyright",   "Copyright $CUR_YEAR $MANUFACTURER\0"
            VALUE "OriginalFilename", "setup.exe\0"
            VALUE "ProductName",      "Remote Management Agent\0"
            VALUE "ProductVersion",   "$VER_STR\0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0409, 1200
    END
END
EOF
else
    cat > "$BUILD_TEMP/launcher.rc" <<EOF
1 24 "launcher.manifest"
101 RCDATA "launcher.vbs"
VS_VERSION_INFO VERSIONINFO
 FILEVERSION     $VER_CSV
 PRODUCTVERSION  $VER_CSV
 FILEFLAGSMASK   0x3fL
 FILEFLAGS       0x0L
 FILEOS          0x40004L
 FILETYPE        0x1L
 FILESUBTYPE     0x0L
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "CompanyName",      "$MANUFACTURER\0"
            VALUE "FileDescription",  "Remote Management Setup\0"
            VALUE "FileVersion",      "$VER_STR\0"
            VALUE "InternalName",     "setup\0"
            VALUE "LegalCopyright",   "Copyright $CUR_YEAR $MANUFACTURER\0"
            VALUE "OriginalFilename", "setup.exe\0"
            VALUE "ProductName",      "Remote Management Agent\0"
            VALUE "ProductVersion",   "$VER_STR\0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0409, 1200
    END
END
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