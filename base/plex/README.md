# Plex Media Server

Plex Media Server deployment on Kubernetes using the official Helm chart.

## Overview

This deployment uses:
- **Helm Chart**: Official Plex Media Server chart from plexinc
- **Storage**: 150Gi PVC on proxmox-zpool storage class
- **NFS Mounts**:
  - `/media/library` - Read-only media library (diskstation.krebiehl.com:/volume1/plex)
  - `/media/optimized` - Read-write optimized media (diskstation.krebiehl.com:/volume1/plex-optimized)
- **Ingress**: HTTPS via Traefik with Let's Encrypt certificate
- **Service**: LoadBalancer on port 32400

## Access

- **HTTPS**: https://plex.krebiehl.com
- **Direct**: http://172.20.6.102:32400/web

## Migrating from an Existing Plex Installation

If you're migrating from an existing Plex server (VM, Docker, etc.), follow these steps:

### Prerequisites

1. **SSH access** to source Plex server
2. **kubectl access** to Kubernetes cluster
3. **Disk space**: ~10GB free in /tmp for archive
4. **Stop Plex** on source server before migration

### Migration Process

The migration scripts are located in `../../scripts/migrate-plex/`. See the [Migration Scripts README](../../scripts/migrate-plex/README.md) for detailed instructions.

**Quick migration:**

```bash
# 1. Stop Plex on source server
ssh user@source-server 'sudo systemctl stop plexmediaserver'

# 2. Run migration script
cd ../../scripts/migrate-plex
./migrate.sh

# 3. Follow the prompts
# The script will:
# - Create archive of Plex library
# - Copy to local machine
# - Upload to Kubernetes pod
# - Extract automatically via init container
```

### Post-Migration Steps

After migration completes:

1. **Access Plex UI**: https://plex.krebiehl.com

2. **Update library paths** (Settings → Manage → Libraries → Edit):
   - Change `/mnt/nas-plex/...` → `/media/library/...`
   - Change `/mnt/nas-plex-optimized/...` → `/media/optimized/...`

3. **Verify**:
   - All libraries visible with metadata
   - Media playback works
   - Watch history preserved
   - User accounts intact

### Init Container

The deployment includes an init container that automatically extracts the library archive on pod startup:

- Checks if `/config/Library` exists
- If archive present at `/config/plex-library.tar.gz`, extracts it
- Removes archive after successful extraction
- Safe for normal pod restarts (no-op if no archive)

This allows you to:
1. Upload archive to pod: `kubectl cp plex-library.tar.gz plex/plex-plex-media-server-0:/config/`
2. Restart pod: `kubectl delete pod -n plex plex-plex-media-server-0`
3. Archive extracts automatically before Plex starts

## Configuration

### Environment Variables

Configured via `extraEnv` in release.yaml:

- `ALLOWED_NETWORKS`: Networks allowed without authentication (172.21.10.0/24)
- `TZ`: Timezone (Etc/New_York)

### Scheduled Restart

A CronJob restarts Plex daily at 5 AM Eastern to apply updates and clear caches:

```bash
kubectl get cronjob -n plex plex-restart
```

## Storage

The deployment uses a 150Gi PVC for Plex configuration and metadata:

```bash
kubectl get pvc -n plex
```

Media files are served from NFS mounts (not stored in PVC).

## Troubleshooting

### Library Not Visible After Migration

- Check if Library directory exists: `kubectl exec -n plex plex-plex-media-server-0 -- ls -la /config/Library`
- Check pod logs: `kubectl logs -n plex plex-plex-media-server-0`
- Verify init container ran: `kubectl logs -n plex plex-plex-media-server-0 -c library-extractor`

### Media Not Playing

- Verify NFS mounts: `kubectl exec -n plex plex-plex-media-server-0 -- df -h`
- Check library paths in Plex UI match NFS mount points
- Verify NFS server allows Kubernetes worker nodes

### Certificate Issues

- Check certificate status: `kubectl get certificate -n plex plex-tls`
- View certificate details: `kubectl describe certificate -n plex plex-tls`
- Certificate auto-renews via cert-manager

## Rollback

To rollback to source server:

1. Start Plex on source server: `ssh user@source 'sudo systemctl start plexmediaserver'`
2. Source server data is unchanged during migration

## Files

- `release.yaml` - Helm release configuration
- `cronjob.yaml` - Daily restart CronJob
- `role.yaml` - RBAC role for restart job
- `rolebinding.yaml` - RBAC role binding
- `serviceaccount.yaml` - Service account for restart job
- `kustomization.yaml` - Kustomize configuration

## Maintenance

### Update Plex Version

The deployment uses the `public` image tag, which downloads the latest version on startup. To update:

```bash
kubectl delete pod -n plex plex-plex-media-server-0
```

### Manual Restart

```bash
kubectl rollout restart statefulset -n plex plex-plex-media-server
```

### View Logs

```bash
kubectl logs -n plex plex-plex-media-server-0 -f
```

## Resources

- [Plex Docker Chart](https://github.com/plexinc/pms-docker/tree/master/charts/plex-media-server)
- [Migration Scripts](../../scripts/migrate-plex/README.md)
- [Plex Support](https://support.plex.tv/)
