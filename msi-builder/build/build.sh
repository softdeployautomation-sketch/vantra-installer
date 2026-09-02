#!/bin/bash
set -e

# Vantra MSI Build Script
# Usage: ./build.sh --client-id <id> --site-id <id> --agent-type <workstation|server> \
#                   --auth-token <token> --api-url <url> --manufacturer <name>

CLIENT_ID=""
SITE_ID=""
AGENT_TYPE=""
AUTH_TOKEN=""
API_URL="https://api.instaweb.top"
MANUFACTURER=""

# Parse named arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --client-id)
            CLIENT_ID="$2"
            shift 2
            ;;
        --site-id)
            SITE_ID="$2"
            shift 2
            ;;
        --agent-type)
            AGENT_TYPE="$2"
            shift 2
            ;;
        --auth-token)
            AUTH_TOKEN="$2"
            shift 2
            ;;
        --api-url)
            API_URL="$2"
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
if [[ -z "$CLIENT_ID" ]]; then
    echo "Error: --client-id is required"
    exit 1
fi
if [[ -z "$SITE_ID" ]]; then
    echo "Error: --site-id is required"
    exit 1
fi
if [[ -z "$AGENT_TYPE" ]]; then
    echo "Error: --agent-type is required"
    exit 1
fi
if [[ -z "$AUTH_TOKEN" ]]; then
    echo "Error: --auth-token is required"
    exit 1
fi
if [[ -z "$MANUFACTURER" ]]; then
    echo "Error: --manufacturer is required"
    exit 1
fi

# Check wixl is installed
if ! command -v wixl &> /dev/null; then
    echo "Error: wixl not found. Install with:"
    echo "  sudo apt-get install msitools"
    exit 1
fi

# Get script directory (where build.sh is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check payload files exist
if [[ ! -f "$PROJECT_ROOT/payload/guide.pdf" ]]; then
    echo "Error: payload/guide.pdf not found"
    exit 1
fi
if [[ ! -f "$PROJECT_ROOT/payload/tacticalagent.exe" ]]; then
    echo "Error: payload/tacticalagent.exe not found"
    exit 1
fi

# Generate 6 UUIDs
echo "Generating UUIDs..."
GUID_PRODUCT=$(uuidgen)
GUID_UPGRADE=$(uuidgen)
GUID_COMP_AGENT=$(uuidgen)
GUID_COMP_GUIDE=$(uuidgen)
GUID_COMP_PS1=$(uuidgen)
GUID_COMP_SHORTCUT=$(uuidgen)

echo "GUID_PRODUCT:    $GUID_PRODUCT"
echo "GUID_UPGRADE:    $GUID_UPGRADE"
echo "GUID_COMP_AGENT: $GUID_COMP_AGENT"
echo "GUID_COMP_GUIDE: $GUID_COMP_GUIDE"
echo "GUID_COMP_PS1:   $GUID_COMP_PS1"
echo "GUID_COMP_SHORTCUT: $GUID_COMP_SHORTCUT"

# Create temp build directory
BUILD_TEMP=$(mktemp -d)
trap "rm -rf $BUILD_TEMP" EXIT

echo "Building in temp directory: $BUILD_TEMP"

# Copy payload files
cp "$PROJECT_ROOT/payload/guide.pdf" "$BUILD_TEMP/"
cp "$PROJECT_ROOT/payload/tacticalagent.exe" "$BUILD_TEMP/"

# Copy and substitute template files
echo "Substituting placeholders..."

# Orchestrator script
sed -e "s|{{CLIENT_ID}}|$CLIENT_ID|g" \
    -e "s|{{SITE_ID}}|$SITE_ID|g" \
    -e "s|{{AGENT_TYPE}}|$AGENT_TYPE|g" \
    -e "s|{{AUTH_TOKEN}}|$AUTH_TOKEN|g" \
    -e "s|{{API_URL}}|$API_URL|g" \
    "$PROJECT_ROOT/src/orchestrator.ps1.template" > "$BUILD_TEMP/orchestrator.ps1"

# WiX Product file
sed -e "s|{{GUID_PRODUCT}}|$GUID_PRODUCT|g" \
    -e "s|{{GUID_UPGRADE}}|$GUID_UPGRADE|g" \
    -e "s|{{GUID_COMP_AGENT}}|$GUID_COMP_AGENT|g" \
    -e "s|{{GUID_COMP_GUIDE}}|$GUID_COMP_GUIDE|g" \
    -e "s|{{GUID_COMP_PS1}}|$GUID_COMP_PS1|g" \
    -e "s|{{GUID_COMP_SHORTCUT}}|$GUID_COMP_SHORTCUT|g" \
    -e "s|{{MANUFACTURER}}|$MANUFACTURER|g" \
    "$PROJECT_ROOT/src/Product.wxs.template" > "$BUILD_TEMP/Product.wxs"

# Create dist directory if it doesn't exist
mkdir -p "$PROJECT_ROOT/dist"

# Run wixl
echo ""
echo "Running wixl..."
WIXL_COMMAND="wixl -v -a x64 -D BuildDir=$BUILD_TEMP -D PayloadDir=$BUILD_TEMP $BUILD_TEMP/Product.wxs -o $PROJECT_ROOT/dist/VantraAgent.msi"
echo "$WIXL_COMMAND"
echo ""

if ! eval "$WIXL_COMMAND"; then
    echo "Error: wixl build failed"
    exit 1
fi

# Print output and file size
echo ""
echo "Build successful!"
ls -lh "$PROJECT_ROOT/dist/VantraAgent.msi"

echo ""
echo "Build complete."
echo "Next: sign the MSI (see msi-builder/signing/SIGNING.md), then scan with"
echo "VirusTotal before distributing to customers."
