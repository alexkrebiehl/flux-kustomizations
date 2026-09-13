# Jellyfin Media Server

Jellyfin on Kubernetes, reading the same NAS media library as [Plex](../plex/README.md) and
transcoding on the AMD iGPU in `talos-cluster-gpu-1`.

## Overview

This deployment uses:
- **Manifests**: plain Deployment / Service / Ingress, no Helm chart
- **Image**: `docker.io/jellyfin/jellyfin:12.0`
- **Storage**:
  - `jellyfin-config` - 50Gi on proxmox-zpool (database, metadata, trickplay images)
  - `jellyfin-cache` - 30Gi on proxmox-zpool (transcode segments, image cache)
- **NFS Mounts** (both read-only, same exports and paths as Plex):
  - `/media/library` - diskstation.krebiehl.com:/volume1/plex
  - `/media/optimized` - diskstation.krebiehl.com:/volume1/plex-optimized
- **GPU**: `devic.es/dri` from [generic-device-plugin](../generic-device-plugin/README.md)
- **Ingress**: HTTPS via Traefik with Let's Encrypt certificate
- **Service**: LoadBalancer on port 8096

## Dependencies

`jellyfin-ks.yaml` depends on `traefik`, `proxmox-csi-plugin`, `cert-manager-issuer` and
`generic-device-plugin`. The last one matters most: without it the pod sits `Pending` on
`Insufficient devic.es/dri`.

## Access

- **HTTPS**: https://jellyfin.krebiehl.com
- **Direct**: `http://<EXTERNAL-IP>:8096`, where the IP comes from `kubectl -n jellyfin get svc jellyfin`

## First run

None of this can be done from Git. Jellyfin keeps it in `/config`.

1. **Setup wizard**: open the UI and create the admin user.
2. **Libraries**: add folders under `/media/library/...`. These are the same paths Plex uses.
3. **Networking** (Dashboard -> Networking):
   - *LAN networks*: `172.21.10.0/24`, which matches Plex's `ALLOWED_NETWORKS`.
   - *Known proxies*: `10.244.0.0/16`, the pod CIDR. Traffic through the ingress arrives from the
     Traefik pod. Without this, Jellyfin sees every HTTPS client as that pod's IP and misjudges which
     clients are local and which are remote.
4. **Hardware transcoding**: see below.

## Hardware transcoding

Two things are needed, and here they come from different places:

- **The device.** A `hostPath` mount of `/dev/dri` makes the device visible but not usable, because
  the node is not on the container's device cgroup allowlist. The render node comes instead from
  `generic-device-plugin` as `devic.es/dri`, requested under the container's `limits`. That request
  is also what schedules Jellyfin onto the GPU node: no other node advertises the resource, so no
  `nodeSelector` is needed. The device arrives as mode 0666, so no render group and no
  `securityContext` changes are needed either.
- **The driver.** The image already has one, unlike Plex. `jellyfin-ffmpeg8` builds Mesa's
  `radeonsi` VA driver (plus RADV for Vulkan) into `/usr/lib/jellyfin-ffmpeg/lib/dri` and points
  its own libva there. It also ships `vainfo`.

### Enabling it

Hardware transcoding is a server setting, stored in `/config/config/encoding.xml`. Set it in
**Dashboard -> Playback -> Transcoding**:

- **Hardware acceleration**: `Video Acceleration API (VAAPI)`
- **VA-API Device**: `/dev/dri/renderD128`
- **Enable hardware decoding for**: tick only the codecs that `vainfo` lists as `VAEntrypointVLD`
  (check 1 below). The Granite Ridge iGPU (RDNA2) is expected to decode H.264, HEVC, VP9 and AV1.
- **Enable 10-Bit hardware decoding for HEVC / VP9**: on, if `vainfo` lists `HEVCMain10` /
  `VP9Profile2`
- **Enable hardware encoding**: on
- **Allow encoding in HEVC format**: only if your clients play HEVC. RDNA2 encodes H.264 and HEVC,
  but **not AV1**, so leave AV1 encoding off.

### Verifying it

Work through these in order. Each one checks something the previous one does not.

**1. The driver loads on the device.**

```bash
kubectl -n jellyfin exec deploy/jellyfin -- \
  /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128
```

Expect a `radeonsi` driver line and a list of profiles. `VAEntrypointVLD` means decode and
`VAEntrypointEncSlice` means encode.

**2. A real hardware encode completes.**

```bash
kubectl -n jellyfin exec deploy/jellyfin -- /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner \
  -init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va \
  -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 5 \
  -vf format=nv12,hwupload -c:v h264_vaapi -f null - 2>&1 | tail -3
```

Expect `frame=  150` and no `Failed to initialise VAAPI`.

**3. Jellyfin's own transcodes use the GPU, and finish.** This is the check that matters. With Plex,
the server logged a hardware decision every time while the hardware job itself crashed and fell back
to the CPU. A decision in a log is not a result.

Play something that has to transcode (in the player, pick a lower quality). While it plays:

```bash
kubectl -n jellyfin exec deploy/jellyfin -- sh -c \
  'for p in $(pgrep -f jellyfin-ffmpeg/ffmpeg); do tr "\0" "\n" < /proc/$p/cmdline | grep -E "^(h264|hevc)_vaapi$|^libx26[45]$"; done'
```

`h264_vaapi` or `hevc_vaapi` means the GPU is encoding. `libx264` or `libx265` means software.

Then confirm the job did not die partway through:

```bash
kubectl -n jellyfin exec deploy/jellyfin -- sh -c \
  'tail -5 "$(ls -t /config/log/FFmpeg.Transcode-*.log | head -1)"'
```

**4. The dashboard agrees.** Under Dashboard -> Activity, the session's playback info shows
the transcode reason and a hardware-accelerated video codec.

## Resource limits

The container sets **no CPU limit**. The constitution asks for requests and limits on every
workload, but this is the same exception Plex makes. The GPU handles the video, but audio
transcodes, subtitle burn-in and trickplay generation still run on the CPU, and CFS throttling
mid-stream is audible as stutter. Requests are set so the scheduler still counts Jellyfin.

Memory is capped at **8Gi**, the same as Plex. It started at 4Gi, and the first library scan
outgrew that: the container was `OOMKilled` on 2026-09-13 about 13 minutes into the scan, which
cut the scan off partway. Check for a repeat with:

```bash
kubectl -n jellyfin get pod -l app.kubernetes.io/name=jellyfin \
  -o jsonpath='{.items[0].status.containerStatuses[0].lastState}'
```

A `"reason":"OOMKilled"` there means the limit was hit again.

## Storage

- **Why the cache is a PVC.** Jellyfin writes transcode segments to `/cache/transcodes`. On an
  `emptyDir` they would land on the only worker's 38G root disk. A few concurrent 4K transcodes
  filling that disk would get every pod in the cluster evicted, not just Jellyfin.
- **Why the media is read-only.** Plex owns these trees. Jellyfin's "Save artwork into media
  folders" and NFO saver options would otherwise write into them. With read-only mounts those
  options fail harmlessly and nothing on the NAS changes.
- **Strategy `Recreate`.** Both PVCs are RWO, so the old pod must release them before the new one
  starts.

## Troubleshooting

### Pod stuck `Pending`

`kubectl -n jellyfin describe pod -l app.kubernetes.io/name=jellyfin`

- `Insufficient devic.es/dri`: the device plugin is not running, or all of its slots are taken. See
  [generic-device-plugin troubleshooting](../generic-device-plugin/README.md#troubleshooting).
- A PVC is not bound: check `kubectl -n jellyfin get pvc` and `proxmox-csi-plugin`.

### `vainfo` fails, or Jellyfin says hardware transcoding is unavailable

If `ls -l /dev/dri/renderD128` works inside the pod, the device plugin is fine and the problem is
the driver or the settings. Check that the VA-API device in the transcoding settings is exactly
`/dev/dri/renderD128`. `card0` is not exposed.

### Media not visible

- `kubectl -n jellyfin exec deploy/jellyfin -- ls /media/library` should list `library` and
  `library-4k`
- Mount errors show up in `kubectl -n jellyfin describe pod`. Check that the NAS allows the node IP.

### Certificate issues

- `kubectl -n jellyfin get certificate jellyfin-tls`
- `kubectl -n jellyfin describe certificate jellyfin-tls`

## Maintenance

### Upgrading

Change the tag in `deployment.yaml` and merge. Read the release notes first, because some Jellyfin
upgrades need a full library rescan afterwards. The `12.0` tag follows 12.0 patch releases, but with
`IfNotPresent` a node keeps the image it already pulled. A version only changes when this file does.

### Restart and logs

```bash
kubectl -n jellyfin rollout restart deploy/jellyfin
kubectl -n jellyfin logs deploy/jellyfin -f
```

## Files

- `namespace.yaml` - namespace, PodSecurity `baseline` (restricted forbids `nfs` volumes)
- `pvc.yaml` - config and cache volumes
- `deployment.yaml` - Jellyfin, NFS mounts, GPU request
- `service.yaml` - LoadBalancer on 8096
- `ingress.yaml` - jellyfin.krebiehl.com via Traefik
- `kustomization.yaml` - Kustomize configuration

## Resources

- [Jellyfin hardware acceleration: AMD](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/amd)
- [jellyfin-ffmpeg](https://github.com/jellyfin/jellyfin-ffmpeg)
