# Plex Media Server

Plex Media Server deployment on Kubernetes using the official Helm chart.

## Overview

This deployment uses:
- **Helm Chart**: Official Plex Media Server chart from plexinc
- **Image**: [`ghcr.io/alexkrebiehl/plex-amd`](https://github.com/alexkrebiehl/plex-amd) - the
  official image plus Mesa's AMD VAAPI driver (see [Hardware transcoding](#hardware-transcoding))
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

## Hardware transcoding

Plex transcodes on the AMD iGPU in `talos-cluster-gpu-1`. Two separate things had to be solved:

**The device.** A `hostPath` mount of `/dev/dri` does not work - it makes the device node visible
but not accessible, because a bind-mounted device is not on the container's device cgroup
allowlist. The render node arrives instead through
[`generic-device-plugin`](../generic-device-plugin/README.md) as the extended resource
`devic.es/dri`, requested under `pms.resources.limits`. That request is also what schedules Plex
onto the GPU node - it is the only node advertising the resource - so no `nodeSelector` is needed.

**The driver.** The official Plex image contains no VA driver at all: there is no `*_drv_video.so`
anywhere in `plexmediaserver_*_amd64.deb`. So the image comes from
[alexkrebiehl/plex-amd](https://github.com/alexkrebiehl/plex-amd), which adds Mesa's `radeonsi`
driver under `/vaapi-amdgpu` and points `LIBVA_DRIVERS_PATH` at it.

That image also ships a newer musl and replaces Plex's bundled copy at every container start,
because Plex's own musl 1.2.2 cannot load this Mesa. It has to cover all of Plex, not just the
transcoder: `Plex Media Server` links libavcodec directly and probes VAAPI in-process to decide
whether hardware transcoding is available at all. The swap is reapplied every start, since Plex
reinstalls itself over `/usr/lib/plexmediaserver` each time.

If hardware transcoding ever stops working, check that the swap happened:

```bash
kubectl -n plex logs plex-plex-media-server-0 | grep vaapi
# expect: [vaapi] replaced Plex's musl with musl 1.2.5 (2 file(s))
```

The plex-amd repo documents the full diagnosis.

### Enabling it

Hardware transcoding is a server setting, not a container setting. In the Plex UI:
**Settings -> Transcoder -> "Use hardware acceleration when available"** (requires Plex Pass).
Nothing in Git can turn this on.

### Verifying it

Plex's ffmpeg is built `--disable-avdevice`, so there is no `lavfi` input - feed it raw NV12
instead. This exercises device access, driver load, constructors and a real encode in one shot:

```bash
kubectl -n plex exec plex-plex-media-server-0 -- sh -c '
dd if=/dev/urandom of=/tmp/in.nv12 bs=1382400 count=30 2>/dev/null
MESA_SHADER_CACHE_DISABLE=true \
"/usr/lib/plexmediaserver/Plex Transcoder" -hide_banner \
  -f rawvideo -pix_fmt nv12 -s 1280x720 -r 30 -i /tmp/in.nv12 \
  -init_hw_device vaapi=hw:/dev/dri/renderD128 -filter_hw_device hw \
  -vf hwupload -c:v h264_vaapi -f null - 2>&1 | tail -3
rm -f /tmp/in.nv12'
```

Keep `MESA_SHADER_CACHE_DISABLE=true`. `kubectl exec` runs as root while Plex runs as `plex`, so
without it Mesa creates `/config/.cache` root-owned and mode 0700 and Plex can no longer write its
shader cache (`Failed to create /config/.cache/mesa_shader_cache ... Permission denied`). The image
repairs that at every start, so it self-corrects, but there is no reason to cause it.

Expect `frame=   30` and no `Failed to initialise VAAPI` or `va_openDriver() returns -1`. Add
`LIBVA_MESSAGING_LEVEL=2` to see libva's driver search.

That only proves the transcoder can. What Plex actually *decided* is in its own log, and this is the
authoritative check - play something that forces a transcode, then:

```bash
kubectl -n plex exec plex-plex-media-server-0 -- \
  grep -a "Reached Decision" \
  "/config/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log" | tail -1
```

Want `encoder=h264_vaapi`. A plain `encoder=h264`, or a nearby
`hardware transcoding: enabled, but no hardware decode accelerator found`, means Plex probed the GPU
and turned it down. The dashboard shows `(hw)` on the session when it worked.

## Resource limits

`pms.resources` deliberately sets **no CPU limit**. The constitution asks for requests and limits on
every workload, but CFS throttling mid-transcode is directly audible as playback stutter, and this
is the one workload where that trade is not worth making. Requests are set so the scheduler still
accounts for Plex properly.

Note that these values must live under `pms:` - the chart reads `.Values.pms.resources`. They sat at
the top level of `values` from initial deployment until 2026-09-07, where the chart never looked, so
the StatefulSet ran with `resources: {}` that whole time.

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

The custom image does not change this - it adds only `/vaapi-amdgpu` and never touches
`/usr/lib/plexmediaserver` or `/version.txt`. To update the *driver* side instead, push to
[plex-amd](https://github.com/alexkrebiehl/plex-amd); CI republishes `:latest` and the nightly
restart picks it up (`pullPolicy: Always`).

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
