# Research Notes: Plex Library Migration to Kubernetes

**Feature**: 002-migrate-plex-library
**Date**: 2026-02-02
**Status**: Complete

## Executive Summary

Research confirms that the Plex Helm Chart provides official init container support for database migration. The migration approach is straightforward: compress the Plex Library directory on the source VM, serve via HTTP, and let the init container download and extract during pod initialization. Path updates can be safely performed using Python's sqlite3 module with SQL UPDATE statements.

## Research Areas

### 1. Plex Helm Chart Migration Capabilities

**Investigation**: Review official Plex Helm Chart documentation for migration features

**Key Findings**:
- Chart version: 1.4.0 (as of investigation)
- Init container support via `initContainer.script` Helm value
- Alpine Linux base image includes curl, tar, gzip
- Safety requirement: Check `/config/Library` exists before importing
- Two supported methods: web-hosted download or manual copy

**References**:
- https://github.com/plexinc/pms-docker/tree/master/charts/plex-media-server
- https://github.com/plexinc/pms-docker/blob/master/charts/plex-media-server/README.md

**Example Init Script**:
```bash
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
```

### 2. Plex Database and Path Handling

**Investigation**: How should the database be handled during migration given path changes?

**Key Findings**:
- Plex has built-in library path management through web UI
- Settings → Libraries → [Library] → Edit → Manage Library → Edit allows path updates
- Plex can detect when media is unavailable and prompt for path updates
- Manual database modification risks corruption and loss of Plex support
- Simpler to use Plex's official path update mechanism post-migration

**Decision**: **Do NOT modify database during migration**
- Copy database exactly as-is from source to target
- After migration, use Plex web UI to update library folder paths
- Process: Edit each library → Update folder path from `/mnt/nas-plex/...` to `/media/library/...`

**Advantages**:
- Zero risk of database corruption
- Uses Plex's supported path update mechanism
- Maintains data integrity guarantees
- Simpler migration script (one less step)
- Preserves Plex support eligibility

**Post-Migration Path Update** (via Plex UI):
1. Login to Plex web interface
2. Settings → Libraries
3. For each library, click "..." → Edit
4. Update folder path to match new NFS mount locations
5. Plex automatically updates internal path references

### 3. Version Compatibility and Detection

**Investigation**: Determine how to match Plex versions between source and target

**Key Findings**:
- Source VM version command: `/usr/lib/plexmediaserver/Plex\ Media\ Server --version`
- Output format: `1.40.1.8227-c0dd5a73e` (semantic version + build hash)
- Docker image tags match this format: `plexinc/pms-docker:1.40.1.8227-c0dd5a73e`
- Helm Chart default: `image.tag: "public"` (latest release)
- Schema changes possible between versions

**Version Detection Script**:
```bash
#!/bin/bash
SSH_HOST="alex@192.168.13.21"
VERSION=$(ssh $SSH_HOST "sudo -u plex /usr/lib/plexmediaserver/Plex\ Media\ Server --version")
echo "Detected Plex version: $VERSION"
echo "Update Helm values to: image.tag: \"$VERSION\""
```

**Helm Configuration**:
```yaml
# base/plex/release.yaml
image:
  tag: "1.40.1.8227-c0dd5a73e"  # Match source VM version
```

### 4. Database Integrity Verification

**Investigation**: Methods to validate Plex database health before and after migration

**Key Findings**:
- SQLite integrity_check: `PRAGMA integrity_check;`
- Foreign key check: `PRAGMA foreign_key_check;`
- Quick check (faster): `PRAGMA quick_check;`
- Plex doesn't enforce foreign keys, so foreign_key_check less critical

**Verification Layers**:

**Layer 1 - Structural Integrity**:
```bash
sqlite3 com.plexapp.plugins.library.db "PRAGMA integrity_check;" | grep -v "^ok$"
# Empty output = healthy
```

**Layer 2 - Table Existence**:
```bash
REQUIRED_TABLES="library_sections metadata_items media_items media_parts"
for table in $REQUIRED_TABLES; do
  sqlite3 com.plexapp.plugins.library.db "SELECT COUNT(*) FROM $table;"
done
```

**Layer 3 - Record Count Comparison**:
```bash
# Before migration
sqlite3 com.plexapp.plugins.library.db "SELECT 'media_parts', COUNT(*) FROM media_parts UNION SELECT 'metadata_items', COUNT(*) FROM metadata_items;" > counts_before.txt

# After migration (on target)
kubectl exec -n plex plex-plex-media-server-0 -- sqlite3 /config/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases/com.plexapp.plugins.library.db "SELECT 'media_parts', COUNT(*) FROM media_parts UNION SELECT 'metadata_items', COUNT(*) FROM metadata_items;" > counts_after.txt

diff counts_before.txt counts_after.txt
```

### 5. Compression and Transfer Performance

**Investigation**: Optimal compression and transfer methods for 10GB+ library directories

**Key Findings**:
- Typical library size breakdown:
  - Databases: 500MB-2GB
  - Metadata cache: 2-10GB (artwork, thumbnails, posters)
  - Cache: 500MB-5GB (transcoder cache, tmp files)
- gzip compression ratio: ~60% (10GB → 4GB typical)
- tar.gz creation time: ~5-15 minutes for 10GB
- Network transfer (1Gbps): ~5 minutes for 4GB compressed
- Python http.server throughput: ~50-100MB/s on local network

**Compression Benchmarks** (estimated):
| Library Size | Compressed Size | tar Time | Transfer Time (1Gbps) |
|--------------|-----------------|----------|------------------------|
| 5GB | 2GB | 3 min | 2 min |
| 10GB | 4GB | 8 min | 4 min |
| 20GB | 8GB | 15 min | 8 min |

**Python HTTP Server**:
```bash
# Start server on source VM
cd /tmp
python3 -m http.server 8080

# Access from K8s init container
curl http://192.168.13.21:8080/plex-library.tar.gz -o /tmp/plex-library.tar.gz
```

**Security Considerations**:
- HTTP (not HTTPS) acceptable for trusted local network
- Server runs temporarily (stopped after migration)
- Firewall rules should limit access to K8s cluster IPs
- Alternative: Use authentication via basic auth in curl

### 6. Rollback and Safety Mechanisms

**Investigation**: Ensure non-destructive migration with rollback capability

**Key Findings**:
- Source VM modifications:
  - Plex service stopped (reversible: `sudo systemctl start plexmediaserver`)
  - Database copied (not moved)
  - Archive created in `/tmp` (doesn't affect source)
- No modifications to original `/var/lib/plexmediaserver/Library/` directory
- Init container idempotency: Checks `/config/Library` exists before running

**Safety Checklist**:
- [ ] Backup created before any modifications
- [ ] Database modifications on copy, not original
- [ ] Source Plex service can be restarted at any time
- [ ] Init container has early-exit check
- [ ] Kubernetes PVC can be deleted and recreated if needed

**Rollback Procedure**:
1. If migration fails during init container:
   - Pod will crashloop
   - Delete PVC: `kubectl delete pvc -n plex pms-config-plex-plex-media-server-0`
   - Recreate pod (will start fresh)
2. If migration fails on source VM:
   - Restart Plex: `sudo systemctl start plexmediaserver`
   - Source VM unchanged
3. If migration completes but Plex broken:
   - Source VM still has original database
   - Can rerun migration with fixes

## Technology Stack Decisions

### Selected Technologies

| Component | Technology | Version | Rationale |
|-----------|-----------|---------|-----------|
| Migration Orchestration | Bash scripts | 5.x | Simple, available on Ubuntu, macOS, Alpine |
| Database Verification | SQLite CLI | 3.x | Native tool, reliable, fast |
| Path Updates | Plex Web UI | N/A | Official supported method, post-migration |
| Archive Format | tar.gz | GNU tar | Standard, good compression, universal |
| Transfer Method | Python http.server | 3.9+ | No dependencies, one-liner, secure enough |
| Version Detection | SSH + grep | N/A | Remote execution, simple parsing |
| Helm Chart | Plex official | 1.4.0 | Supported migration path, idempotent |

### Rejected Alternatives

| Alternative | Reason for Rejection |
|-------------|----------------------|
| rsync for transfer | Requires daemon setup, more complex than HTTP |
| Manual database path modification | Unnecessary risk, Plex UI handles this safely |
| Direct kubectl cp | Doesn't work with init containers |
| Cloud storage intermediary | Adds dependency, slower, unnecessary |
| NFS mount entire library | Risks modifying source during migration |
| Manual SQL export/import | Slower, more error-prone than UPDATE |

## Open Questions RESOLVED

All technical unknowns have been resolved through research:

1. ~~How does Plex Helm Chart support migration?~~ → Init container with script value
2. ~~How to handle path changes?~~ → No database modification, use Plex UI post-migration
3. ~~How to match Plex versions?~~ → Detect via SSH, set image.tag in Helm
4. ~~How to verify database integrity?~~ → Multi-layer: PRAGMA + table checks + counts
5. ~~How to transfer 10GB+ efficiently?~~ → tar.gz + Python HTTP server

## Next Steps

1. Create data model document (data-model.md)
2. Define archive structure contract (contracts/plex-library-archive.yaml)
3. Write quickstart guide (quickstart.md)
4. Generate task list (/speckit.tasks)
5. Implement migration scripts
