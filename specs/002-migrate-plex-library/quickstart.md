# Quickstart: Migrate Plex Library to Kubernetes

**Feature**: 002-migrate-plex-library
**Estimated Time**: 1-2 hours (depending on library size)

## Prerequisites

- [ ] SSH access to source VM (alex@192.168.13.21)
- [ ] kubectl access to Kubernetes cluster
- [ ] Kubernetes Plex deployment running (base/plex/)
- [ ] NFS mounts configured and accessible
- [ ] Sufficient local disk space (~4-10GB for archive)
- [ ] Plex web UI accessible

## Overview

This migration copies the complete Plex library from the Ubuntu VM to Kubernetes without modifying the database. After migration, you'll update library paths through the Plex web UI.

**Migration Flow**:
1. Detect Plex version on source VM
2. Stop source Plex service
3. Verify database integrity
4. Create compressed archive
5. Copy archive to local computer
6. Upload archive to Kubernetes pod
7. Extract archive in pod
8. Restart pod to start Plex
9. Update library paths via Plex UI

---

## Step 1: Detect Plex Version

**On your local computer:**

```bash
# Get Plex version from source VM
ssh alex@192.168.13.21 "sudo -u plex /usr/lib/plexmediaserver/Plex\ Media\ Server --version"

# Example output: 1.40.1.8227-c0dd5a73e
# Save this version number - you'll need it in Step 7
```

**Record version here**: `_________________`

---

## Step 2: Stop Source Plex Service

**On source VM (via SSH):**

```bash
ssh alex@192.168.13.21

# Stop Plex service
sudo systemctl stop plexmediaserver

# Verify it's stopped
sudo systemctl status plexmediaserver
# Should show "inactive (dead)"
```

⚠️ **Important**: Plex is now offline on the source VM

---

## Step 3: Verify Database Integrity

**On source VM:**

```bash
# Navigate to Plex directory
cd "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"

# Run integrity check
sqlite3 "Plug-in Support/Databases/com.plexapp.plugins.library.db" "PRAGMA integrity_check;"

# Expected output: ok
```

✅ If you see "ok", proceed. ❌ If you see errors, **DO NOT PROCEED** - contact support.

---

## Step 4: Create Archive

**On source VM:**

```bash
# Navigate to parent directory
cd /var/lib/plexmediaserver

# Create compressed archive (this may take 5-15 minutes)
sudo tar czf /tmp/plex-library.tar.gz Library/

# Check archive size
ls -lh /tmp/plex-library.tar.gz
# Typical size: 2-10GB
```

**Archive size**: `___________ GB`

---

## Step 5: Copy Archive to Local Computer

**On your local computer:**

```bash
# Copy archive from source VM to your computer
scp alex@192.168.13.21:/tmp/plex-library.tar.gz ~/Downloads/

# Verify copy completed
ls -lh ~/Downloads/plex-library.tar.gz
```

---

## Step 6: Upload Archive to Kubernetes Pod

**On your local computer:**

```bash
# Get the exact pod name
kubectl get pods -n plex
# Look for: plex-plex-media-server-0

# Copy archive to pod (this may take 5-10 minutes)
kubectl cp ~/Downloads/plex-library.tar.gz plex/plex-plex-media-server-0:/tmp/plex-library.tar.gz

# Verify copy completed
kubectl exec -n plex plex-plex-media-server-0 -- ls -lh /tmp/plex-library.tar.gz
```

---

## Step 7: Extract Archive in Pod

**On your local computer:**

```bash
# Extract archive
kubectl exec -n plex plex-plex-media-server-0 -- tar xzf /tmp/plex-library.tar.gz -C /config/

# Verify extraction
kubectl exec -n plex plex-plex-media-server-0 -- ls -la /config/Library/

# Clean up archive
kubectl exec -n plex plex-plex-media-server-0 -- rm /tmp/plex-library.tar.gz
```

---

## Step 8: Update Helm Chart with Correct Version

**On your local computer:**

```bash
cd /Users/alex/projects/terraform/infrastructure/flux-kustomizations

# Edit base/plex/release.yaml
# Update image.tag to the version from Step 1
```

**Edit `base/plex/release.yaml`:**

```yaml
image:
  tag: "1.40.1.8227-c0dd5a73e"  # <-- Use version from Step 1
```

**Commit and push:**

```bash
git add base/plex/release.yaml
git commit -m "Set Plex version to match source VM"
git push
```

---

## Step 9: Restart Pod to Apply Migration

**On your local computer:**

```bash
# Delete pod (will recreate automatically)
kubectl delete pod -n plex plex-plex-media-server-0

# Watch pod restart
kubectl get pods -n plex -w

# Wait for pod to be Running (may take 2-5 minutes)
```

---

## Step 10: Verify Migration Success

**Access Plex Web UI:**

```bash
# Get LoadBalancer IP
kubectl get svc -n plex plex-plex-media-server

# Access via: http://172.20.6.102:32400/web
# Or: http://plex.krebiehl.com (if DNS configured)
```

**Check in Plex UI:**
- [ ] All libraries visible
- [ ] User accounts present
- [ ] Collections intact
- [ ] Watch history preserved

⚠️ **Libraries will show "0 items" or errors - this is expected! Continue to Step 11.**

---

## Step 11: Update Library Paths

**In Plex Web UI:**

For **each library** (Movies, TV Shows, etc.):

1. Settings → Manage → Libraries
2. Click "..." next to library name → **Edit**
3. Click **"Manage Library"** → **"Edit"**
4. Update folder paths:
   - Old: `/mnt/nas-plex/Movies` → New: `/media/library/Movies`
   - Old: `/mnt/nas-plex-optimized/Movies` → New: `/media/optimized/Movies`
5. Click **"Save"**
6. Plex will scan and update paths (may take a few minutes)

**Repeat for all libraries.**

---

## Step 12: Final Verification

**Test playback:**

- [ ] Play a movie from Movies library
- [ ] Play an episode from TV Shows library
- [ ] Check optimized versions work (if applicable)
- [ ] Verify watch history shows resume points
- [ ] Confirm artwork/posters display correctly

---

## Step 13: Cleanup (Optional)

**On source VM:**

```bash
ssh alex@192.168.13.21

# Remove archive
sudo rm /tmp/plex-library.tar.gz

# Optionally: Leave Plex stopped or restart it
# To restart: sudo systemctl start plexmediaserver
```

**On local computer:**

```bash
# Remove local archive copy
rm ~/Downloads/plex-library.tar.gz
```

---

## Troubleshooting

### Pod CrashLooping

**Check logs:**
```bash
kubectl logs -n plex plex-plex-media-server-0
```

**Common causes:**
- NFS mounts not accessible
- Insufficient storage in PVC
- Version mismatch

### Libraries Show No Items

**This is expected immediately after migration.** Complete Step 11 (Update Library Paths).

### Playback Fails

**Check NFS mounts:**
```bash
kubectl exec -n plex plex-plex-media-server-0 -- ls -la /media/library
kubectl exec -n plex plex-plex-media-server-0 -- ls -la /media/optimized
```

**Verify permissions** - files should be readable by Plex user.

### Database Corruption Detected

**DO NOT PROCEED** with migration. Source VM database needs repair first.

**Rollback:**
```bash
# On source VM
sudo systemctl start plexmediaserver
```

---

## Rollback Procedure

If migration fails at any point:

**1. Source VM:**
```bash
ssh alex@192.168.13.21
sudo systemctl start plexmediaserver
```

**2. Kubernetes (if needed):**
```bash
kubectl delete pvc -n plex pms-config-plex-plex-media-server-0
kubectl delete pod -n plex plex-plex-media-server-0
```

Source VM database is unchanged and can be used to retry migration.

---

## Success Criteria

✅ Migration is successful when:

- [ ] All libraries visible in Plex UI
- [ ] Media playback works from all libraries
- [ ] User watch history preserved
- [ ] Metadata/artwork displays correctly
- [ ] Resume points work
- [ ] Optimized media accessible (if configured)
- [ ] Source VM untouched and can be restarted

---

## Estimated Timeline

| Step | Time | Cumulative |
|------|------|------------|
| 1-3: Prep & Verify | 5 min | 5 min |
| 4: Create Archive | 5-15 min | 10-20 min |
| 5: Copy to Local | 5-10 min | 15-30 min |
| 6: Upload to Pod | 5-10 min | 20-40 min |
| 7-9: Extract & Restart | 10 min | 30-50 min |
| 10-11: Verify & Update Paths | 15-30 min | 45-80 min |
| 12: Final Testing | 10-15 min | 55-95 min |

**Total**: ~1-2 hours depending on library size and network speed

---

## Next Steps

After successful migration:

1. Monitor Plex performance for 24 hours
2. Verify scheduled recordings work (if applicable)
3. Test remote access via plex.tv
4. Update DNS if needed (plex.krebiehl.com)
5. Optionally decommission source VM Plex installation

---

## Support Resources

- Plex Support: https://support.plex.tv
- FluxCD Docs: https://fluxcd.io/docs
- Helm Chart: https://github.com/plexinc/pms-docker/tree/master/charts/plex-media-server
