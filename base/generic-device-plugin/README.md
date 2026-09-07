# Generic Device Plugin

Exposes host device nodes to pods as schedulable Kubernetes extended resources. Deployed here to
make the AMD iGPU on `talos-cluster-gpu-1` usable for VAAPI encode/decode by ordinary,
unprivileged workloads.

Upstream: [squat/generic-device-plugin](https://github.com/squat/generic-device-plugin).

## Why a device plugin and not a hostPath

This is the part worth remembering, because the hostPath approach looks like it should work and
does not.

Mounting `/dev/dri` into a pod as a `hostPath` volume makes the device node **visible** in the
container's filesystem but does not grant **access** to it. Container runtimes maintain a device
cgroup allowlist, and a bind-mounted device node is not on it. The failure is unintuitive because
it is not a file-permission error:

```console
$ kubectl exec <pod> -- ls -l /dev/dri/renderD128
crw-rw-rw-. 1 root root 226, 128 /dev/dri/renderD128     # mode 0666

$ kubectl exec <pod> -- dd if=/dev/dri/renderD128 of=/dev/null bs=1 count=0
dd: failed to open '/dev/dri/renderD128': Operation not permitted   # ...as root
```

Root, on a world-writable device, denied. The only ways onto the allowlist are
`securityContext.privileged: true` — a large concession for an application pod — or a device
plugin, which hands the kubelet a `DeviceSpec` that the CRI turns into a properly injected device.

That is what this DaemonSet does. Consumers get the device with **no** privilege, **no** hostPath,
and their namespaces stay on PodSecurity `baseline`.

## Components

- **Namespace**: `generic-device-plugin`, labelled `pod-security.kubernetes.io/*: privileged`. The
  plugin needs it (it mounts `/dev` and the kubelet socket directory); consumers do not.
- **DaemonSet**: one privileged pod, pinned by `nodeSelector` to `node.krebiehl.com/gpu=amd` — the
  only node with an iGPU. `priorityClassName: system-node-critical` keeps it from being evicted
  under node pressure, which would silently strip the resource from every consumer.

## Configuration

Devices are declared with repeatable `--device` arguments taking inline YAML. Currently one:

```yaml
name: dri
groups:
  - count: 10
    paths:
      - path: /dev/dri/renderD128
```

- **`--domain=devic.es`** is set explicitly. It is also the upstream default, but pinning it means
  an image bump cannot rename the resource out from under consumers.
- **`count: 10`** is a *sharing* limit, not a hardware one. The render node can genuinely be used by
  several processes at once — the kernel driver arbitrates — so this caps how many pods may hold it
  concurrently. Raise it if you run out; there is no per-pod isolation either way.
- **`renderD128` only.** `card0` is mode 0600 and exists for modesetting; VAAPI encode/decode needs
  only the render node.

To expose something else (a TPU, a serial dongle, `/dev/fuse`), add another `--device` block. See
upstream for the `usb:` selector and glob support in `paths`.

## Consuming a device

Request it under `resources.limits`. Extended resources must be limits — Kubernetes copies the
value to requests automatically, and specifying only a request is rejected.

```yaml
spec:
  nodeSelector:
    node.krebiehl.com/gpu: amd
  containers:
    - name: app
      resources:
        limits:
          devic.es/dri: 1
```

The device appears in the container at the same path, `/dev/dri/renderD128`. No `securityContext`
is required.

Note that this gets the **device** into a container; it does not supply userspace **drivers**. The
container image still needs a working VA driver (`radeonsi_drv_video.so` from Mesa, for AMD). Most
images that advertise VAAPI support ship one; Plex notably does not — see below.

## Verification

### 1. The DaemonSet is running on the GPU node

```bash
kubectl -n generic-device-plugin get ds,pods -o wide
```

Expected: `DESIRED 1 / READY 1`, pod on `talos-cluster-gpu-1`.

### 2. The node advertises the resource

```bash
kubectl get node talos-cluster-gpu-1 -o jsonpath='{.status.allocatable}' | tr ',' '\n' | grep devic
```

Expected: `"devic.es/dri":"10"`.

### 3. An unprivileged pod can actually open the device

The regression test for the whole point of this component:

```bash
kubectl run dri-probe --image=alpine:3.22 --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"node.krebiehl.com/gpu":"amd"},"containers":[{"name":"dri-probe","image":"alpine:3.22","command":["/bin/sh","-c","ls -l /dev/dri/renderD128 && dd if=/dev/dri/renderD128 of=/dev/null bs=1 count=0 && echo DEVICE-OPEN-OK"],"resources":{"limits":{"devic.es/dri":"1"}}}]}}'
kubectl logs dri-probe
kubectl delete pod dri-probe
```

Expected: the device listing followed by `DEVICE-OPEN-OK`. The pod runs in `default` with no
securityContext — if it opens the device, the cgroup injection is working.

## Troubleshooting

### Consumer pod stuck `Pending`

`kubectl describe pod` reports `Insufficient devic.es/dri`. Either the plugin is not running on
that node (check the DaemonSet and its `nodeSelector`), the resource name is misspelled, or all
`count` slots are held. Confirm with verification step 2.

### Consumer pod runs but has no `/dev/dri/renderD128`

The resource was requested under `requests` rather than `limits`, or on a different container in
the pod than the one you looked in. Extended resources are injected per-container.

### Plugin pod `CrashLoopBackOff`

`kubectl -n generic-device-plugin logs ds/generic-device-plugin`. A malformed `--device` YAML block
or an invalid `--domain` (it must be a DNS-1123 subdomain) both fail at startup.

### Device opens but the application still says "no hardware transcoding"

Almost always a missing userspace driver in the image, not a problem with this plugin. Verify with
`vainfo` (or the app's own probe) inside the container. See the note under "Consuming a device".

## References

- [squat/generic-device-plugin](https://github.com/squat/generic-device-plugin)
- [Kubernetes device plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/)
- GPU node definition: `worker_pools.gpu` in `talos-clusters/terraform.tfvars`; passthrough and
  gotchas in `talos-clusters/README.md`
