# Implementation Plan: Migrate Plex Library to Kubernetes

**Branch**: `002-migrate-plex-library` | **Date**: 2026-02-02 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-migrate-plex-library/spec.md`

## Summary

Migrate existing Plex Media Server library from Ubuntu VM (192.168.13.21) to Kubernetes deployment using the Plex Helm Chart's init container migration feature. The migration will preserve all database content, user data, watch history, metadata cache, and preferences while updating media paths from `/mnt/nas-plex` to `/media/library` and `/mnt/nas-plex-optimized` to `/media/optimized`. The source VM remains untouched for rollback capability.

**Technical Approach**: Leverage Plex Helm Chart's built-in init container support to import a compressed archive of the Plex Library directory. Create a migration script that runs on the source VM to stop Plex, verify integrity, compress the entire library as-is (no database modifications), and serve it via HTTP for the init container to download during pod initialization. Plex will automatically handle any necessary path adjustments when it starts.

## Technical Context

**Language/Version**: Bash 5.x or Python 3.9+ (for scripting automation)
**Primary Dependencies**:
- Plex Media Server (version-matched between source and target)
- Plex Helm Chart (plexinc/pms-docker charts/plex-media-server)
- SQLite 3.x (for database path updates)
- OpenSSH (for remote execution)
- kubectl (for Kubernetes interaction)

**Storage**:
- Source: Local filesystem on Ubuntu VM
- Target: Kubernetes PersistentVolume (proxmox-zpool storage class, 50Gi)
- NFS mounts for media access (diskstation.krebiehl.com)

**Testing**: Manual verification via playback tests and database integrity checks

**Target Platform**: Kubernetes cluster (existing deployment at clusters/talos-cluster)

**Project Type**: Infrastructure automation / migration scripts

**Performance Goals**:
- Complete migration within 4 hours for 10,000 media items
- Database integrity verification < 5 minutes

**Constraints**:
- Non-destructive migration (source VM must remain operational)
- Idempotent init container (safe on pod restarts)
- Version matching required (no schema upgrade during migration)

**Scale/Scope**:
- Single Plex server migration
- Database size: typically 500MB-2GB
- Metadata cache: 2-10GB depending on library size

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### ✅ I. Reusability First
**Status**: PASS
**Rationale**: While this is a one-time migration script, the Helm Chart configuration (base/plex/) is already reusable across clusters. Migration scripts will be documented in specs/ directory for reference but are not intended for repeated use.

### ✅ II. Cluster-Specific Overlays
**Status**: PASS
**Rationale**: Plex deployment exists in base/plex/ as a reusable kustomization. No cluster-specific overlays needed for this migration—it targets the existing deployment.

### ✅ III. Declarative Infrastructure (NON-NEGOTIABLE)
**Status**: PASS with JUSTIFICATION
**Rationale**: The migration process itself is procedural (run-once scripts), but the target state (Plex on Kubernetes with imported data) is fully declarative via Helm Chart values. The init container configuration will be added to base/plex/release.yaml as declarative Helm values.
**Justification**: Migration is a transitional operation; once complete, all infrastructure remains declarative.

### ✅ IV. Validation Before Commit
**Status**: PASS
**Rationale**: Init container configuration will be validated with `helm template` before commit. The Helm Chart's built-in safety checks prevent database overwriting.

### ✅ V. Documentation and Context
**Status**: PASS
**Rationale**: Complete documentation in specs/002-migrate-plex-library/ including this plan, research notes, and quickstart guide. Migration procedure will be documented step-by-step.

### Security and Compliance

**Secret Management**: PASS - No new secrets required (uses existing SSH keys and kubectl context)
**Resource Limits**: N/A - No new workloads, using existing Plex deployment

### Testing Strategy

**Pre-Production Testing**: Migration will be executed against production environment with full backup and rollback capability documented.

**Post-Migration Verification Checklist**:
1. Verify all libraries visible in Plex UI
2. Test playback from multiple libraries
3. Verify user watch history preserved
4. Check metadata/artwork display
5. Confirm NFS mount accessibility

---

**Constitution Check Result**: ✅ PASS - All gates satisfied. Migration approach aligns with GitOps principles while acknowledging the procedural nature of data migration.

---

## Project Structure

### Documentation (this feature)

```text
specs/002-migrate-plex-library/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
│   └── plex-library-archive.yaml  # Archive structure specification
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
base/plex/
├── release.yaml         # Helm Chart values (will add initContainer config)
├── kustomization.yaml
├── namespace.yaml
├── repository.yaml
└── (other existing files)

scripts/
└── migrate-plex/        # Migration automation scripts (created by this feature)
    ├── prepare-source.sh       # Runs on source VM
    ├── verify-database.sh      # Database integrity checks
    ├── create-archive.sh       # Compress library for transfer
    └── README.md               # Usage instructions
```

**Structure Decision**: Migration scripts in `scripts/migrate-plex/` directory as they're one-time operational tools, not infrastructure-as-code. The declarative Kubernetes configuration remains in `base/plex/` following standard structure.

## Complexity Tracking

> No constitutional violations requiring justification. Migration approach leverages existing Helm Chart capabilities and maintains GitOps principles.

---

# Phase 0: Research & Discovery

## Research Tasks

### R1: Plex Helm Chart Init Container Implementation

**Question**: What are the exact parameters and structure for the Plex Helm Chart's init container migration feature?

**Findings**:
- Chart supports `initContainer.script` value for custom initialization logic
- Init script must check for existing database: `if [ -d "/config/Library" ]; then exit 0; fi`
- Two methods supported:
  1. Web-hosted: Download tar.gz via curl from HTTP server
  2. Manual: Copy archive to pod, rename to trigger extraction
- Target location: `/config/Library` directory in pod
- Alpine Linux base image provides curl, tar, gzip by default

**Decision**: Use web-hosted method with lightweight HTTP server on source VM
**Rationale**: Minimizes manual steps, allows single-command execution, HTTP server can be stopped after migration
**Alternatives Considered**:
- Manual kubectl cp: Requires multiple steps, harder to automate
- NFS mount of entire library: Risks source VM modification during migration

**References**:
- https://github.com/plexinc/pms-docker/tree/master/charts/plex-media-server
- Helm Chart values: initContainer.script

### R2: Plex Database Path Handling

**Question**: How will Plex handle the changed media paths after migration?

**Findings**:
- Plex stores absolute filesystem paths in SQLite database
- When Plex starts and paths don't match, it will detect NFS mounts at new locations
- Plex has built-in library path update capability through the UI
- Manual database modification risks corruption and isn't necessary

**Decision**: Do NOT modify database - copy as-is
**Rationale**: Simpler, safer, non-destructive. Administrator can use Plex UI to update library paths post-migration through "Edit Library" → "Manage Library" → "Edit" → Update folder paths
**Alternatives Considered**:
- Python sqlite3 UPDATE queries: Unnecessary risk, adds complexity
- sed/awk on exported SQL: Fragile, risks database corruption

**Post-Migration Action**: Administrator updates library paths via Plex web UI (Settings → Libraries → Edit → Update folder paths)

### R3: Plex Version Detection and Matching

**Question**: How do we detect the Plex version on source VM and configure Helm Chart to match?

**Findings**:
- Plex version available via: `/usr/lib/plexmediaserver/Plex\ Media\ Server --version`
- Helm Chart uses `image.tag` value (default: latest)
- Plex Docker images tagged with version numbers (e.g., `1.40.1.8227-c0dd5a73e`)
- Docker Hub plexinc/pms-docker tags: https://hub.docker.com/r/plexinc/pms-docker/tags

**Decision**: Extract version from source, set Helm Chart `image.tag` to match exact version
**Rationale**: Eliminates schema compatibility issues, safest migration path
**Implementation**:
1. SSH to source VM: `ssh alex@192.168.13.21 "sudo -u plex /usr/lib/plexmediaserver/Plex\ Media\ Server --version"`
2. Parse version string (format: "1.40.1.8227-c0dd5a73e")
3. Update base/plex/release.yaml: `image.tag: "1.40.1.8227-c0dd5a73e"`

### R4: Database Integrity Verification

**Question**: What tools and checks ensure Plex database integrity before and after migration?

**Findings**:
- SQLite PRAGMA integrity_check: Validates database structure and consistency
- Returns "ok" if healthy, or list of errors if corrupted
- Plex-specific checks: Verify critical tables exist (library_sections, metadata_items, media_parts)
- Table count verification: Compare record counts before/after migration

**Decision**: Multi-layer verification approach
1. SQLite integrity_check (structural validation)
2. Table existence check (Plex-specific validation)
3. Record count comparison (data loss detection)

**Implementation**:
```bash
sqlite3 com.plexapp.plugins.library.db "PRAGMA integrity_check;"
# Expected output: ok

sqlite3 com.plexapp.plugins.library.db "SELECT name FROM sqlite_master WHERE type='table';"
# Verify critical tables present

sqlite3 com.plexapp.plugins.library.db "SELECT COUNT(*) FROM media_parts;"
# Compare before/after
```

### R5: Archive Creation and Transfer Strategy

**Question**: What's the optimal way to compress and transfer the Plex Library directory (potentially 10GB+)?

**Findings**:
- Plex Library directory structure:
  - Plug-in Support/Databases/ (500MB-2GB)
  - Metadata/ (2-10GB artwork/posters)
  - Cache/ (variable, can be large)
  - Preferences.xml (small)
- tar with gzip compression: ~50-70% size reduction
- Python http.server module: Lightweight, no dependencies, perfect for one-time transfer
- Kubernetes init containers have network access to cluster-external IPs

**Decision**: Create tar.gz archive, serve via Python http.server on source VM
**Rationale**: Simple, no external dependencies, secure (one-time use, closed after migration)
**Implementation**:
```bash
# On source VM
cd /var/lib/plexmediaserver
tar czf /tmp/plex-library.tar.gz Library/
cd /tmp && python3 -m http.server 8080

# Helm Chart init container will curl http://192.168.13.21:8080/plex-library.tar.gz
```

**Alternatives Considered**:
- rsync: Requires daemon setup, more complex
- Cloud storage (S3/GCS): Adds external dependency, slower
- Direct kubectl cp: Doesn't work with init containers

---

## Technology Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Migration Method | Helm Chart init container with web-hosted archive | Official support, automated, idempotent |
| Path Handling | No database modification - update via Plex UI post-migration | Safest, non-destructive, uses Plex's built-in tools |
| Version Matching | Detect source version, set exact image tag | Eliminates schema compatibility risk |
| Integrity Verification | SQLite PRAGMA + table checks + record counts | Multi-layer validation catches all issues |
| Archive Transfer | tar.gz + Python http.server | Simple, no dependencies, secure |
| Database Backup | Copy before modification | Non-destructive requirement |
| Rollback Strategy | Keep source VM untouched, restart on failure | Safety-first approach |

---

# Phase 1: Design & Contracts

## Data Model

See [data-model.md](./data-model.md)

## API Contracts

See [contracts/](./contracts/)

## Quick Start Guide

See [quickstart.md](./quickstart.md)

---

**Next Step**: Run `/speckit.tasks` to generate actionable task list from this plan.
