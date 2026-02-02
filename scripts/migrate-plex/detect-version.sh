#!/bin/bash
#
# Plex Version Detection Script
# Detects Plex Media Server version from source VM
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Source VM details
SOURCE_VM_USER="${SOURCE_VM_USER:-alex}"
SOURCE_VM_HOST="${SOURCE_VM_HOST:-192.168.13.21}"

function log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function detect_plex_version() {
    log_info "Detecting Plex Media Server version on source VM..."
    log_info "Connecting to: ${SOURCE_VM_USER}@${SOURCE_VM_HOST}"

    # Try to detect version from the Plex binary
    local version=$(ssh "${SOURCE_VM_USER}@${SOURCE_VM_HOST}" \
        "/usr/lib/plexmediaserver/Plex\\ Media\\ Server --version 2>&1 | head -1" 2>/dev/null || echo "")

    if [ -z "$version" ]; then
        log_warn "Could not detect version from Plex binary"

        # Try alternate method: check package version
        log_info "Trying alternate detection method (package version)..."
        version=$(ssh "${SOURCE_VM_USER}@${SOURCE_VM_HOST}" \
            "dpkg -l | grep plexmediaserver | awk '{print \$3}'" 2>/dev/null || echo "")
    fi

    if [ -z "$version" ]; then
        log_error "Could not detect Plex version from source VM"
        return 1
    fi

    # Extract version number (format: 1.40.5.8897-e5c93e3f1)
    local version_number=$(echo "$version" | grep -oP '\d+\.\d+\.\d+\.\d+-[a-z0-9]+' | head -1)

    if [ -z "$version_number" ]; then
        log_error "Could not parse Plex version: $version"
        return 1
    fi

    log_info "${GREEN}Detected Plex version: ${version_number}${NC}"
    echo "$version_number"
    return 0
}

# Main execution
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    detect_plex_version
fi
