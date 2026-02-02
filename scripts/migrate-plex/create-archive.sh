#!/bin/bash
#
# Plex Library Archive Creation Script
# Creates compressed tar.gz archive of complete Plex Library directory
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function create_archive() {
    local source_dir="/var/lib/plexmediaserver"
    local output_path="/tmp/plex-library.tar.gz"

    log_info "Creating Plex library archive..."
    log_info "Source: $source_dir/Library"
    log_info "Output: $output_path"

    # Check if source directory exists
    if [ ! -d "$source_dir/Library" ]; then
        log_error "Plex Library directory not found: $source_dir/Library"
        return 1
    fi

    # Remove old archive if exists
    if [ -f "$output_path" ]; then
        log_warn "Removing existing archive: $output_path"
        rm -f "$output_path"
    fi

    # Create archive with progress
    log_info "Compressing Library directory (this may take 5-15 minutes)..."
    cd "$source_dir"

    tar czf "$output_path" Library/ 2>&1 | while read line; do
        log_info "  $line"
    done

    if [ ! -f "$output_path" ]; then
        log_error "Archive creation failed - file not created"
        return 1
    fi

    # Show archive size
    local size=$(du -h "$output_path" | cut -f1)
    log_info "${GREEN}Archive created successfully${NC}"
    log_info "Size: $size"
    log_info "Location: $output_path"

    return 0
}

# Main execution
create_archive
