# Plex Library Migration Scripts

Scripts for migrating Plex Media Server library from Ubuntu VM to Kubernetes.

## Overview

This migration is **non-destructive** - the source VM remains unchanged and can be used for rollback if needed.

**Migration Flow:**
1. Stop Plex on source VM
2. Verify database integrity
3. Create archive of Library directory
4. Copy to local computer (intermediary)
5. Upload to Kubernetes pod
6. Extract in pod
7. Restart pod with migrated data

## Prerequisites

### On Local Computer

- **SSH access** to source VM (alex@192.168.13.21)
- **kubectl access** to Kubernetes cluster with plex namespace
- **Disk space**: ~10GB free in /tmp for archive
- **Tools**: ssh, scp, kubectl, tar

### On Source VM (192.168.13.21)

- Plex Media Server running
- SSH access enabled
- sudo privileges (for stopping Plex service)
- SQLite3 installed (for database verification)

### On Kubernetes Cluster

- Plex deployment running in `plex` namespace
- Pod name: `plex-plex-media-server-0`
- PVC with sufficient space (150Gi configured)
- NFS mounts configured for media library

## Pre-Migration Checklist

- [ ] Backup source VM (recommended but optional)
- [ ] Verify SSH access: `ssh alex@192.168.13.21 'echo OK'`
- [ ] Verify kubectl access: `kubectl get pod -n plex`
- [ ] Verify NFS mounts in Kubernetes deployment
- [ ] Note current Plex version on source VM
- [ ] Update `base/plex/release.yaml` with matching Plex version
- [ ] Ensure 150Gi storage is applied (check `kubectl get pvc -n plex`)

## Usage

### Step 1: Make scripts executable

```bash
chmod +x scripts/migrate-plex/*.sh
```

### Step 2: Run migration

```bash
./scripts/migrate-plex/migrate.sh
```

The script will:
1. Check all prerequisites
2. Detect Plex version from source VM
3. Verify source database integrity
4. Prompt you to stop Plex service on source VM
5. Create backup on source VM
6. Create archive of Library directory
7. Copy archive to local computer
8. Upload to Kubernetes pod
9. Extract in pod
10. Restart pod
11. Clean up temporary files

### Step 3: Post-migration tasks

After migration completes:

1. **Access Plex UI**: http://plex.krebiehl.com or http://172.20.6.102:32400/web

2. **Verify libraries visible**: All libraries should show with metadata intact

3. **Update library paths**:
   - Go to Settings → Manage → Libraries
   - For each library, click the "..." menu → Edit
   - Update paths:
     - `/mnt/nas-plex` → `/media/library`
     - `/mnt/nas-plex-optimized` → `/media/optimized`
   - Save changes

4. **Test playback**: Try playing media from each library type

5. **Verify user data**:
   - User accounts present
   - Watch history intact
   - Resume points preserved
   - Watchlist items present

## Individual Scripts

### detect-version.sh

Detects Plex Media Server version from source VM.

```bash
./scripts/migrate-plex/detect-version.sh
```

Output: Version string (e.g., "1.40.5.8897-e5c93e3f1")

### verify-database.sh

Verifies SQLite database integrity.

```bash
# On source VM
./scripts/migrate-plex/verify-database.sh "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"
```

Checks:
- Database integrity (PRAGMA integrity_check)
- Required tables exist (library_sections, metadata_items, etc.)
- Record counts for each table

### create-archive.sh

Creates compressed tar.gz archive of Library directory.

```bash
# Run on source VM
./scripts/migrate-plex/create-archive.sh
```

Output: `/tmp/plex-library.tar.gz`

### migrate.sh

Main orchestration script - runs all migration steps.

See "Usage" section above.

## Configuration

Environment variables (optional):

```bash
# Source VM connection
export SOURCE_VM_USER=alex
export SOURCE_VM_HOST=192.168.13.21

# Kubernetes
export K8S_NAMESPACE=plex
export K8S_POD_NAME=plex-plex-media-server-0
```

Defaults are set for this infrastructure.

## Rollback

If migration fails or you need to revert:

### Option 1: Restart source VM Plex

```bash
# On source VM
sudo systemctl start plexmediaserver
```

Source VM is unchanged - just start the service again.

### Option 2: Re-run migration

The migration can be run multiple times:
- Source VM archive remains at `/tmp/plex-library.tar.gz`
- Simply run `./scripts/migrate-plex/migrate.sh` again

### Option 3: Manual restore to Kubernetes

If you need to restore from source VM backup:

```bash
# On source VM, find backup
ls -la /tmp/plex-backup-*

# Copy specific backup to local
scp -r alex@192.168.13.21:/tmp/plex-backup-YYYYMMDD-HHMMSS/com.plexapp.plugins.library.db /tmp/

# Copy to pod
kubectl cp /tmp/com.plexapp.plugins.library.db plex/plex-plex-media-server-0:/config/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases/

# Restart pod
kubectl delete pod -n plex plex-plex-media-server-0
```

## Troubleshooting

### SSH Connection Failed

```bash
# Test SSH connection
ssh -v alex@192.168.13.21

# Check SSH config
cat ~/.ssh/config
```

### Database Verification Failed

- Check SQLite3 is installed on source VM: `ssh alex@192.168.13.21 'which sqlite3'`
- Verify database file exists: `ssh alex@192.168.13.21 'ls -la /var/lib/plexmediaserver/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases/'`

### Archive Creation Failed

- Check disk space on source VM: `ssh alex@192.168.13.21 'df -h /tmp'`
- Check Library directory exists: `ssh alex@192.168.13.21 'ls -la /var/lib/plexmediaserver/Library'`

### Archive Copy Failed (scp)

- Check local disk space: `df -h /tmp`
- Verify archive exists on source: `ssh alex@192.168.13.21 'ls -lh /tmp/plex-library.tar.gz'`

### Upload to Pod Failed (kubectl cp)

- Verify pod is running: `kubectl get pod -n plex`
- Check pod has space: `kubectl exec -n plex plex-plex-media-server-0 -- df -h /config`
- Verify PVC is bound: `kubectl get pvc -n plex`

### Extraction Failed

- Check archive integrity: `kubectl exec -n plex plex-plex-media-server-0 -- tar tzf /config/plex-library.tar.gz | head`
- Verify sufficient space: `kubectl exec -n plex plex-plex-media-server-0 -- df -h /config`

### Pod Won't Start After Migration

- Check pod logs: `kubectl logs -n plex plex-plex-media-server-0`
- Check pod events: `kubectl describe pod -n plex plex-plex-media-server-0`
- Verify NFS mounts: `kubectl exec -n plex plex-plex-media-server-0 -- df -h`

### Libraries Not Visible After Migration

- Check Library directory exists: `kubectl exec -n plex plex-plex-media-server-0 -- ls -la /config/Library`
- Verify database file: `kubectl exec -n plex plex-plex-media-server-0 -- ls -la /config/Library/Application\ Support/Plex\ Media\ Server/Plug-in\ Support/Databases/`
- Check Plex logs: `kubectl logs -n plex plex-plex-media-server-0 | grep -i error`

### Media Not Playing

- NFS mounts not accessible - check pod events: `kubectl describe pod -n plex plex-plex-media-server-0`
- Library paths not updated - see "Post-migration tasks" section
- Verify NFS server permissions allow Kubernetes worker nodes

## Log Files

- **Migration log**: `scripts/migrate-plex/migrate.log`
- **Pod logs**: `kubectl logs -n plex plex-plex-media-server-0`
- **Plex logs in pod**: `/config/Library/Application Support/Plex Media Server/Logs/`

## Success Criteria

✅ Migration is successful when:

- [ ] All libraries visible in Plex UI with complete metadata
- [ ] User accounts with watch history preserved
- [ ] Collections and playlists intact
- [ ] Media playback works from all libraries
- [ ] Playback begins within 5 seconds
- [ ] No missing media errors
- [ ] Watch history shows resume points
- [ ] Watchlist items preserved
- [ ] User preferences (subtitles, audio) applied automatically

## Important Notes

- **Non-destructive**: Source VM is never modified (except for stopping service)
- **Database preservation**: Database is copied exactly as-is, no modifications
- **Version matching**: Source and target Plex versions must match exactly
- **Path updates**: Library paths must be updated via Plex UI after migration
- **NFS permissions**: Ensure NFS server allows Kubernetes worker nodes
- **Disk space**: Ensure sufficient space in /tmp and pod PVC (150Gi)

## Files

```
scripts/migrate-plex/
├── README.md              # This file
├── migrate.sh             # Main orchestration script
├── detect-version.sh      # Version detection
├── verify-database.sh     # Database integrity verification
├── create-archive.sh      # Archive creation
├── migrate.log            # Generated during migration
└── detected-version.txt   # Generated during migration
```

## Support

For issues or questions:
1. Check troubleshooting section above
2. Review migration log: `scripts/migrate-plex/migrate.log`
3. Check pod logs: `kubectl logs -n plex plex-plex-media-server-0`
