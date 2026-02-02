# Data Model: Plex Library Migration

**Feature**: 002-migrate-plex-library
**Date**: 2026-02-02

## Overview

This document describes the data structures and entities involved in migrating a Plex Media Server library from an Ubuntu VM to Kubernetes. The migration is primarily concerned with the Plex Library directory structure and the Helm Chart configuration needed to import it.

## Entity Descriptions

### 1. Plex Library Directory

**Purpose**: Complete Plex Media Server application data including database, metadata, preferences, and cache

**Location (Source)**: `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/`

**Location (Target)**: `/config/Library/Application Support/Plex Media Server/` (inside Kubernetes pod)

**Structure**:
```
Library/
└── Application Support/
    └── Plex Media Server/
        ├── Plug-in Support/
        │   ├── Databases/
        │   │   ├── com.plexapp.plugins.library.db  (main database)
        │   │   ├── com.plexapp.plugins.library.db-shm
        │   │   └── com.plexapp.plugins.library.db-wal
        │   ├── Data/
        │   └── Caches/
        ├── Metadata/
        │   ├── Movies/
        │   ├── TV Shows/
        │   ├── Artists/
        │   └── Photos/
        ├── Cache/
        │   └── Transcode/
        ├── Preferences.xml
        ├── Logs/
        └── Crash Reports/
```

**Key Subdirectories**:
| Path | Size (typical) | Required? | Description |
|------|----------------|-----------|-------------|
| Plug-in Support/Databases/ | 500MB-2GB | **YES** | SQLite databases with all library metadata |
| Metadata/ | 2-10GB | **YES** | Artwork, posters, thumbnails (per clarification) |
| Preferences.xml | <1MB | **YES** | Server configuration including machine ID |
| Cache/ | 500MB-5GB | NO | Transcoder cache, can be regenerated |
| Logs/ | 10-100MB | NO | Historical logs, not needed |
| Crash Reports/ | Variable | NO | Debug data, not needed |

**Migration Scope**: All directories will be migrated as-is to preserve complete state

### 2. Plex Database (SQLite)

**File**: `com.plexapp.plugins.library.db`

**Type**: SQLite 3 database

**Purpose**: Stores all library metadata, user data, watch history, collections, playlists

**Critical Tables** (read-only for migration):
| Table | Records (est.) | Purpose |
|-------|----------------|---------|
| library_sections | 5-20 | Library definitions (Movies, TV Shows, etc.) |
| metadata_items | 1000-50000 | Individual media items |
| media_items | 1000-50000 | Media file references |
| media_parts | 1000-50000 | Physical file paths |
| accounts | 1-10 | User accounts |
| metadata_item_settings | 1000-50000 | User ratings, watch status |

**Validation**: Integrity verified via `PRAGMA integrity_check`

**Path References**: Contains absolute file paths (e.g., `/mnt/nas-plex/Movies/Title.mp4`)
- **Migration approach**: Do NOT modify database
- **Post-migration**: Administrator updates paths via Plex UI

### 3. Migration Archive

**Purpose**: Compressed transfer package containing complete Plex Library directory

**Format**: tar.gz (gzip compressed tarball)

**Filename**: `plex-library.tar.gz`

**Creation**:
```bash
cd /var/lib/plexmediaserver
tar czf /tmp/plex-library.tar.gz Library/
```

**Size Estimates**:
| Library Size | Compressed | Compression Ratio |
|--------------|-----------|-------------------|
| 5GB | ~2GB | 40% |
| 10GB | ~4GB | 40% |
| 20GB | ~8GB | 40% |

**Transfer Method**: HTTP via Python http.server

**Extraction Target**: `/config/` in Kubernetes pod

**Post-extraction Structure**: `/config/Library/Application Support/Plex Media Server/`

### 4. Helm Chart Configuration

**Purpose**: Declarative configuration for Plex deployment with init container migration

**File**: `base/plex/release.yaml`

**Relevant Values**:
```yaml
image:
  tag: "1.40.1.8227-c0dd5a73e"  # Match source VM version

initContainer:
  script: |
    #!/bin/sh
    if [ -d "/config/Library" ]; then
      echo "PMS library already exists, exiting."
      exit 0
    fi

    echo "Downloading Plex library archive..."
    curl -L http://192.168.13.21:8080/plex-library.tar.gz -o /tmp/plex-library.tar.gz

    echo "Extracting to /config..."
    cd /config
    tar xzf /tmp/plex-library.tar.gz
    rm /tmp/plex-library.tar.gz

    echo "Migration complete!"

pms:
  storageClassName: proxmox-zpool
  configStorage: 50Gi
```

**Idempotency Check**: `if [ -d "/config/Library" ]; then exit 0; fi`

**Lifecycle**: Init container runs once on first pod start, then exits early on subsequent restarts

### 5. Migration State Tracking

**Purpose**: Record migration progress and decisions for audit trail

**File**: `scripts/migrate-plex/migration.log` (created during migration)

**Content**:
- Source Plex version detected
- Database integrity check results
- Archive creation timestamp and size
- HTTP server start/stop times
- Helm release update status
- Post-migration verification results

**Format**: Timestamped log entries

**Example**:
```
[2026-02-02 10:00:00] Starting Plex migration from alex@192.168.13.21
[2026-02-02 10:00:05] Detected Plex version: 1.40.1.8227-c0dd5a73e
[2026-02-02 10:00:10] Database integrity check: OK
[2026-02-02 10:00:15] Stopping Plex service
[2026-02-02 10:01:00] Creating archive: /tmp/plex-library.tar.gz (4.2GB)
[2026-02-02 10:08:00] Archive created successfully
[2026-02-02 10:08:05] Starting HTTP server on port 8080
[2026-02-02 10:08:10] Updating Helm release with init container config
[2026-02-02 10:15:00] Pod starting, init container downloading archive
[2026-02-02 10:20:00] Init container extraction complete
[2026-02-02 10:22:00] Plex pod running
[2026-02-02 10:22:05] Stopping HTTP server
[2026-02-02 10:22:10] Migration complete
```

## Data Flow

```
┌──────────────────┐
│   Source VM      │
│  192.168.13.21   │
│                  │
│  /var/lib/       │
│  plexmediaserver/│
│    Library/      │
└─────────┬────────┘
          │
          │ 1. Stop Plex service
          │ 2. Verify integrity
          │ 3. tar czf
          │
          ▼
    ┌──────────────┐
    │ Archive File │
    │ .tar.gz (4GB)│
    └──────┬───────┘
           │
           │ 4. HTTP serve
           │    python -m http.server
           │
           ▼
┌─────────────────────┐
│ Kubernetes Cluster  │
│                     │
│  Init Container     │
│  (Alpine Linux)     │
│                     │
│  curl → extract     │
│  to /config/        │
└──────────┬──────────┘
           │
           │ 5. Extract to PVC
           │
           ▼
    ┌──────────────┐
    │ Plex Pod     │
    │ PVC: 50Gi    │
    │ /config/     │
    │   Library/   │
    └──────────────┘
```

## Post-Migration Actions

### Required: Update Library Paths

**Method**: Plex Web UI

**Steps**:
1. Access Plex at http://plex.krebiehl.com or http://172.20.6.102:32400
2. Settings → Manage → Libraries
3. For each library (Movies, TV Shows, etc.):
   - Click "..." menu → Edit
   - Click folder path
   - Update path from `/mnt/nas-plex/...` to `/media/library/...`
   - Update optimized path from `/mnt/nas-plex-optimized/...` to `/media/optimized/...`
   - Save

**Validation**: Play a media file from each library to confirm accessibility

## Constraints

### Size Constraints
- Maximum PVC size: 50Gi (configured in Helm chart)
- Recommended library size: <40GB to leave room for growth
- If source library exceeds 40GB, consider excluding Cache/ directory

### Version Constraints
- Source and target Plex versions must match exactly
- Database schema compatibility required
- No automatic upgrades during migration

### Network Constraints
- HTTP server must be accessible from Kubernetes cluster
- Source VM IP: 192.168.13.21
- Firewall rules may need adjustment

## Rollback Considerations

### Source VM State
- Plex service stopped during migration
- Original Library/ directory **unchanged**
- Can restart Plex service at any time: `sudo systemctl start plexmediaserver`

### Target Kubernetes State
- If migration fails: Delete PVC and retry
- Command: `kubectl delete pvc -n plex pms-config-plex-plex-media-server-0`
- Pod will recreate PVC on next start

### Data Safety
- No source data modified (copy, not move)
- Database copied as-is (no risky modifications)
- Init container idempotent (safe to retry)

## References

- Plex Library structure: https://support.plex.tv/articles/202915258-where-is-the-plex-media-server-data-directory-located/
- Plex database schema: https://github.com/pkkid/python-plexapi/wiki
- Helm Chart migration docs: https://github.com/plexinc/pms-docker/tree/master/charts/plex-media-server
