#!/bin/bash
#
# Plex Library Migration Script
# Migrates Plex library from Ubuntu VM to Kubernetes pod
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SOURCE_VM_USER="${SOURCE_VM_USER:-alex}"
SOURCE_VM_HOST="${SOURCE_VM_HOST:-192.168.13.21}"
SOURCE_PLEX_DIR="/var/lib/plexmediaserver"
SOURCE_DB_PATH="$SOURCE_PLEX_DIR/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"
ARCHIVE_NAME="plex-library.tar.gz"
LOCAL_ARCHIVE="/tmp/$ARCHIVE_NAME"
REMOTE_ARCHIVE="/tmp/$ARCHIVE_NAME"
K8S_NAMESPACE="plex"
K8S_POD_NAME="plex-plex-media-server-0"
K8S_CONFIG_DIR="/config"
LOG_FILE="$SCRIPT_DIR/migrate.log"

# Source helper scripts
source "$SCRIPT_DIR/detect-version.sh"

function log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
    echo -e "${GREEN}${msg}${NC}"
    echo "$msg" >> "$LOG_FILE"
}

function log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1"
    echo -e "${YELLOW}${msg}${NC}"
    echo "$msg" >> "$LOG_FILE"
}

function log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    echo -e "${RED}${msg}${NC}"
    echo "$msg" >> "$LOG_FILE"
}

function log_step() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [STEP] $1"
    echo -e "${BLUE}${msg}${NC}"
    echo "$msg" >> "$LOG_FILE"
}

function check_prerequisites() {
    log_step "Checking prerequisites..."

    # Check SSH access
    log_info "Verifying SSH access to source VM..."
    if ! ssh -o ConnectTimeout=5 "${SOURCE_VM_USER}@${SOURCE_VM_HOST}" "echo 'SSH connection successful'" &>/dev/null; then
        log_error "Cannot connect to source VM: ${SOURCE_VM_USER}@${SOURCE_VM_HOST}"
        return 1
    fi
    log_info "✓ SSH access verified"

    # Check kubectl access
    log_info "Verifying kubectl access to Kubernetes cluster..."
    if ! kubectl get namespace "$K8S_NAMESPACE" &>/dev/null; then
        log_error "Cannot access namespace: $K8S_NAMESPACE"
        return 1
    fi
    log_info "✓ kubectl access verified"

    # Check if pod exists
    log_info "Verifying Plex pod exists..."
    if ! kubectl get pod -n "$K8S_NAMESPACE" "$K8S_POD_NAME" &>/dev/null; then
        log_error "Pod not found: $K8S_POD_NAME in namespace $K8S_NAMESPACE"
        return 1
    fi
    log_info "✓ Plex pod found"

    log_info "${GREEN}All prerequisites satisfied${NC}"
    return 0
}

function detect_and_verify_version() {
    log_step "Detecting Plex version..."

    local version=$(detect_plex_version)
    if [ -z "$version" ]; then
        log_error "Failed to detect Plex version"
        return 1
    fi

    log_info "Source Plex version: $version"
    echo "$version" > "$SCRIPT_DIR/detected-version.txt"

    log_warn "IMPORTANT: Target Kubernetes pod must use the same Plex version"
    log_info "Update base/plex/release.yaml with: image.tag: $version"

    return 0
}

function verify_source_database() {
    log_step "Verifying source database integrity..."

    # Run verification script on source VM
    log_info "Running database integrity check on source VM..."

    local verify_script=$(cat "$SCRIPT_DIR/verify-database.sh")
    local result=$(ssh "${SOURCE_VM_USER}@${SOURCE_VM_HOST}" "bash -s '$SOURCE_DB_PATH'" <<< "$verify_script" 2>&1)

    if echo "$result" | grep -q "all checks passed"; then
        log_info "${GREEN}✓ Source database integrity verified${NC}"
        return 0
    else
        log_error "Source database verification failed:"
        echo "$result"
        return 1
    fi
}

function prompt_stop_plex() {
    log_step "Plex service must be stopped before migration"

    echo ""
    log_warn "⚠️  CRITICAL: You must stop Plex on the source VM before continuing"
    echo ""
    echo "Run this command on the source VM:"
    echo "  sudo systemctl stop plexmediaserver"
    echo ""
    read -p "Have you stopped Plex on the source VM? (yes/no): " response

    if [[ ! "$response" =~ ^[Yy]es$ ]]; then
        log_error "Migration aborted - Plex must be stopped first"
        return 1
    fi

    log_info "User confirmed Plex service stopped"
    return 0
}

function create_backup() {
    log_step "Creating database backup on source VM..."

    ssh "${SOURCE_VM_USER}@${SOURCE_VM_HOST}" << 'EOF'
        BACKUP_DIR="/tmp/plex-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db" \
           "$BACKUP_DIR/"
        echo "Backup created: $BACKUP_DIR"
EOF

    log_info "${GREEN}✓ Database backup created on source VM${NC}"
    return 0
}

function create_archive() {
    log_step "Creating archive of Plex Library..."

    # Run archive creation script on source VM
    local archive_script=$(cat "$SCRIPT_DIR/create-archive.sh")
    ssh "${SOURCE_VM_USER}@${SOURCE_VM_HOST}" "bash -s" <<< "$archive_script"

    log_info "${GREEN}✓ Archive created on source VM${NC}"
    return 0
}

function copy_archive_local() {
    log_step "Copying archive to local computer..."

    log_info "Source: ${SOURCE_VM_USER}@${SOURCE_VM_HOST}:${REMOTE_ARCHIVE}"
    log_info "Destination: $LOCAL_ARCHIVE"

    # Remove old local archive if exists
    [ -f "$LOCAL_ARCHIVE" ] && rm -f "$LOCAL_ARCHIVE"

    # Copy from source VM to local
    if ! scp "${SOURCE_VM_USER}@${SOURCE_VM_HOST}:${REMOTE_ARCHIVE}" "$LOCAL_ARCHIVE"; then
        log_error "Failed to copy archive from source VM"
        return 1
    fi

    local size=$(du -h "$LOCAL_ARCHIVE" | cut -f1)
    log_info "${GREEN}✓ Archive copied to local computer (Size: $size)${NC}"
    return 0
}

function upload_archive_to_pod() {
    log_step "Uploading archive to Kubernetes pod..."

    log_info "Destination: $K8S_NAMESPACE/$K8S_POD_NAME:$K8S_CONFIG_DIR/"

    # Upload archive to pod
    if ! kubectl cp "$LOCAL_ARCHIVE" "$K8S_NAMESPACE/$K8S_POD_NAME:$K8S_CONFIG_DIR/$ARCHIVE_NAME"; then
        log_error "Failed to upload archive to pod"
        return 1
    fi

    log_info "${GREEN}✓ Archive uploaded to pod${NC}"
    return 0
}

function extract_archive_in_pod() {
    log_step "Extracting archive in pod..."

    # Extract archive in pod (this will create /config/Library/)
    kubectl exec -n "$K8S_NAMESPACE" "$K8S_POD_NAME" -- \
        tar xzf "$K8S_CONFIG_DIR/$ARCHIVE_NAME" -C "$K8S_CONFIG_DIR/" --strip-components=0

    # Verify extraction
    local library_exists=$(kubectl exec -n "$K8S_NAMESPACE" "$K8S_POD_NAME" -- \
        test -d "$K8S_CONFIG_DIR/Library" && echo "yes" || echo "no")

    if [ "$library_exists" != "yes" ]; then
        log_error "Library directory not found after extraction"
        return 1
    fi

    log_info "${GREEN}✓ Archive extracted successfully${NC}"

    # Clean up archive in pod
    kubectl exec -n "$K8S_NAMESPACE" "$K8S_POD_NAME" -- \
        rm -f "$K8S_CONFIG_DIR/$ARCHIVE_NAME"

    log_info "Archive file cleaned up from pod"
    return 0
}

function restart_plex_pod() {
    log_step "Restarting Plex pod..."

    kubectl delete pod -n "$K8S_NAMESPACE" "$K8S_POD_NAME"

    log_info "Waiting for pod to restart..."
    kubectl wait --for=condition=Ready pod -n "$K8S_NAMESPACE" "$K8S_POD_NAME" --timeout=300s

    log_info "${GREEN}✓ Plex pod restarted${NC}"
    return 0
}

function cleanup_temp_files() {
    log_step "Cleaning up temporary files..."

    # Clean up local archive
    if [ -f "$LOCAL_ARCHIVE" ]; then
        rm -f "$LOCAL_ARCHIVE"
        log_info "Removed local archive: $LOCAL_ARCHIVE"
    fi

    # Note: Remote archive on source VM is left in place for rollback
    log_info "Remote archive preserved on source VM for rollback: $REMOTE_ARCHIVE"

    return 0
}

function print_next_steps() {
    echo ""
    log_step "Migration Complete!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Next Steps:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "1. Access Plex web interface"
    echo "   - http://plex.krebiehl.com"
    echo ""
    echo "2. Verify libraries are visible with metadata"
    echo ""
    echo "3. Update library paths (Settings → Manage → Libraries → Edit):"
    echo "   - Change /mnt/nas-plex → /media/library"
    echo "   - Change /mnt/nas-plex-optimized → /media/optimized"
    echo ""
    echo "4. Test media playback from each library"
    echo ""
    echo "5. Verify user accounts and watch history"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Migration log: $LOG_FILE"
    echo ""
}

function main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Plex Library Migration Script"
    echo "  Source: ${SOURCE_VM_USER}@${SOURCE_VM_HOST}"
    echo "  Target: Kubernetes namespace: $K8S_NAMESPACE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Initialize log file
    echo "Migration started at $(date)" > "$LOG_FILE"

    # Execute migration steps
    check_prerequisites || exit 1
    detect_and_verify_version || exit 1
    verify_source_database || exit 1
    prompt_stop_plex || exit 1
    create_backup || exit 1
    create_archive || exit 1
    copy_archive_local || exit 1
    upload_archive_to_pod || exit 1
    extract_archive_in_pod || exit 1
    restart_plex_pod || exit 1
    cleanup_temp_files || exit 1

    print_next_steps
}

# Run main function
main "$@"
