#!/bin/bash
#
# Plex Database Integrity Verification Script
# Verifies SQLite database integrity before and after migration
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Database path on source VM
DB_PATH="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"

function log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function verify_database() {
    local db_path="$1"
    log_info "Verifying database integrity: $db_path"

    # Check if database file exists
    if [ ! -f "$db_path" ]; then
        log_error "Database file not found: $db_path"
        return 1
    fi

    # Run SQLite integrity check
    log_info "Running PRAGMA integrity_check..."
    local integrity_result=$(sqlite3 "$db_path" "PRAGMA integrity_check;" 2>&1)

    if [ "$integrity_result" != "ok" ]; then
        log_error "Database integrity check FAILED:"
        echo "$integrity_result"
        return 1
    fi

    log_info "Database integrity check: ${GREEN}OK${NC}"

    # Verify critical tables exist
    log_info "Verifying critical Plex tables..."
    local required_tables=("library_sections" "metadata_items" "media_items" "media_parts" "accounts")

    for table in "${required_tables[@]}"; do
        local count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$table';" 2>&1)
        if [ "$count" != "1" ]; then
            log_error "Required table '$table' not found in database"
            return 1
        fi
        log_info "  ✓ Table '$table' exists"
    done

    # Count records in critical tables
    log_info "Record counts:"
    for table in "${required_tables[@]}"; do
        local count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM $table;" 2>&1)
        log_info "  - $table: $count records"
    done

    log_info "${GREEN}Database verification complete - all checks passed${NC}"
    return 0
}

# Main execution
if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <database_path>"
    echo "Example: $0 \"$DB_PATH\""
    exit 1
fi

verify_database "$1"
