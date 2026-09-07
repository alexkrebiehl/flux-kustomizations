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

## Hardware transcoding (not working - transcodes run on the CPU)

The GPU is present and functional, but **Plex cannot use it**, and this deployment no longer tries.

Plex's transcoder segfaults whenever `-copyts` is combined with `h264_vaapi`, and Plex sends
`-copyts` on every segmented streaming session. What you see is: Plex decides on hardware, starts the
job, the job dies in Plex's own bundled ffmpeg within about half a second, and Plex silently re-plans
without hardware. The dashboard shows a plain "Transcode" with no `(hw)`, and CPU use is high.

It is a Plex bug, not a configuration problem here. It reproduces with Plex's own downloaded VA
driver and on a completely unmodified image. Full diagnosis and a minimal reproduction:
[PLEX-BUG-REPORT.md](https://github.com/alexkrebiehl/plex-amd/blob/main/PLEX-BUG-REPORT.md).

The GPU itself is fine - without `-copyts`, the same pipeline hardware-encodes at every resolution up
to 4K.

### Why the stock image, and why no device request

An earlier attempt ran a custom image ([alexkrebiehl/plex-amd](https://github.com/alexkrebiehl/plex-amd))
that added Mesa's VAAPI driver, on the premise that Plex ships none. Two things made that a dead end:

- **Plex 1.43 downloads its own AMD driver** into `Cache/va-dri-linux-x86_64` and overrides
  `LIBVA_DRIVERS_PATH` when launching the transcoder. The bundled Mesa only ever fed Plex Media
  Server's in-process capability probe.
- **Making that probe succeed made things worse.** Plex then attempts hardware, crashes, and falls
  back - so every playback start costs a crashed process and ~0.5 s. With the stock image the probe
  finds no driver, Plex goes straight to software, and playback starts cleanly.

So `devic.es/dri` is no longer requested either: with no usable hardware path it would only pin
scheduling for nothing. Re-enabling is a small diff (`image`, the resource limit, and the
`generic-device-plugin` entry in `plex-ks.yaml`) if the Plex crash is ever fixed.

`generic-device-plugin` stays deployed - it is cluster-wide and other workloads use it.

### If you want to re-check whether Plex has fixed it

The GPU-side check, which passes today and is not the problem:

```bash
kubectl -n plex exec plex-plex-media-server-0 -- sh -c '
dd if=/dev/urandom of=/tmp/in.nv12 bs=1382400 count=30 2>/dev/null
MESA_SHADER_CACHE_DISABLE=true "/usr/lib/plexmediaserver/Plex Transcoder" -hide_banner \
  -f rawvideo -pix_fmt nv12 -s 1280x720 -r 30 -i /tmp/in.nv12 \
  -init_hw_device vaapi=hw:/dev/dri/renderD128 -filter_hw_device hw \
  -vf hwupload -c:v h264_vaapi -f null - 2>&1 | tail -3
rm -f /tmp/in.nv12'
```

(That needs `devic.es/dri` back in the pod spec to have a device at all.)

The check that actually matters is whether a hardware job survives. Play something that transcodes,
then look for a crashed transcoder:

```bash
kubectl -n plex exec plex-plex-media-server-0 -- \
  grep -a "exit code for process" \
  "/config/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log" | tail -3
```

`is -11 (signal: Segmentation fault)` means the bug is still there. Note that Plex's
`Reached Decision ... encoder=h264_vaapi` line is **not** evidence of success - it records the
decision, not the outcome, and it says `h264_vaapi` even when the job then crashes. Check the running
process instead:

```bash
kubectl -n plex exec plex-plex-media-server-0 -- sh -c \
  'for p in $(pgrep -f "Plex Transcoder"); do tr "\0" "\n" < /proc/$p/cmdline | grep -xE "h264_vaapi|libx264"; done'
```

### Enabling it, if it ever works again

Hardware transcoding is a server setting, not a container setting:
**Settings -> Transcoder -> "Use hardware acceleration when available"** (requires Plex Pass).
Nothing in Git can turn this on. It is already enabled on this server.

## Resource limits

`pms.resources` deliberately sets **no CPU limit**. The constitution asks for requests and limits on
every workload, but CFS throttling mid-transcode is directly audible as playback stutter, and this
is the one workload where that trade is not worth making. Requests are set so the scheduler still
accounts for Plex properly.

Note that these values must live under `pms:` - the chart reads `.Values.pms.resources`. They sat at
the top level of `values` from initial deployment until 2026-09-07, where the chart never looked, so
the StatefulSet ran with `resources: {}` that whole time.

The no-CPU-limit choice matters more now that transcoding happens on the CPU: a 4K transcode will
happily use most of the node's cores, and throttling it would be audible.

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

Plex updates itself. The image is built `FROM plexinc/pms-docker:public`, which carries no Plex
binary; its `50-plex-update` init script reads `version=public` from `/version.txt` and installs the
newest public release at every container start. The daily `plex-restart` CronJob turns that into
daily updates. To update immediately:

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
