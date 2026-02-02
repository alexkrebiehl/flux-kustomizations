# Feature Specification: Migrate Plex Library to Kubernetes

**Feature Branch**: `002-migrate-plex-library`
**Created**: 2026-02-02
**Status**: Draft
**Input**: User description: "Migrate my plex library from a Ubuntu VM (accessible via SSH alex@192.168.13.21) to the Plex Kubernetes deployment. Changes to the source VM should be non-destructive. Media paths have changed from 1) /mnt/nas-plex to /media/library and 2) /mnt/nas-plex-optimized to /media/optimized. Prompt me for anything requiring user interaction (e.g. logging out of the source plex)"

## Clarifications

### Session 2026-02-02

- Q: Metadata Migration Strategy - Should we migrate all metadata cache (artwork, posters, thumbnails) or regenerate? → A: Migrate all metadata cache (artwork, posters, thumbnails) - slower but preserves everything
- Q: Plex Version Compatibility Strategy - Should we match versions, allow upgrades during migration, or require pre-migration upgrade? → A: Match versions first (install same version on Kubernetes) - safest, eliminates schema issues
- Q: Corrupted Database Handling - What should happen if source database is corrupted? → A: Abort migration, document issue, keep source running - safest for non-destructive requirement
- Q: Acceptable Service Interruption Window - How long can the Plex service be down during migration? → A: Downtime is not an issue
- Q: Missing or Moved Media Files Handling - How should migration handle media files that no longer exist? → A: Continue migration, log warnings, let Plex mark unavailable - practical approach

**Note**: The official Plex Helm Chart provides init container support for migration from existing systems. The implementation should leverage this built-in capability, which includes safety checks to prevent database overwriting on pod restarts.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Migrate Core Library Data (Priority: P1)

As a Plex administrator, I need to migrate my existing Plex library database and configuration from the Ubuntu VM to the new Kubernetes deployment so that all my libraries, watch history, metadata, collections, and user preferences are preserved without having to rebuild them from scratch.

**Why this priority**: This is the core migration task - without the database, all other data is meaningless. This represents the MVP and must work for the migration to be considered successful.

**Independent Test**: Can be fully tested by copying the Plex database from the source VM, updating media paths, importing into the Kubernetes pod, and verifying that all libraries appear with their metadata intact.

**Acceptance Scenarios**:

1. **Given** the source Plex server is stopped, **When** the database is copied and imported to Kubernetes with updated paths, **Then** all libraries (Movies, TV Shows, Music, Photos) appear with complete metadata, artwork, and collections
2. **Given** multiple users exist on the source server, **When** migration completes, **Then** all user accounts with their watch history, ratings, and preferences are preserved
3. **Given** custom collections and playlists exist, **When** migration completes, **Then** all collections and playlists are intact and functional
4. **Given** the source VM remains untouched during migration, **When** any step fails, **Then** the administrator can roll back by restarting the source VM without data loss

---

### User Story 2 - Verify Media Accessibility (Priority: P2)

As a Plex administrator, I need to verify that the migrated Plex server can access all media files through the new NFS mount paths so that playback works correctly without broken links.

**Why this priority**: After core migration, media accessibility is critical for the system to be functional. This is independently testable by attempting playback of various media types.

**Independent Test**: Can be fully tested by attempting to play random media files from each library and confirming that playback starts successfully without "media unavailable" errors.

**Acceptance Scenarios**:

1. **Given** libraries have been migrated with updated paths, **When** an administrator attempts to play a movie, **Then** playback begins within 5 seconds
2. **Given** media files exist at the new paths, **When** Plex scans the libraries, **Then** no missing media errors appear
3. **Given** optimized media exists in the optimized directory, **When** a client requests optimized versions, **Then** optimized media is served correctly
4. **Given** the old path was /mnt/nas-plex and new path is /media/library, **When** path rewriting occurs, **Then** all media references are correctly updated

---

### User Story 3 - Preserve User Session State (Priority: P3)

As a Plex user, when the server migration occurs, I want to be able to log back into the new server and resume watching from where I left off so that my viewing experience is minimally disrupted.

**Why this priority**: User convenience feature that makes the migration transparent. Less critical than core functionality but improves user experience.

**Independent Test**: Can be fully tested by logging into the new server after migration and verifying that resume points, up-next queue, and on-deck items are preserved.

**Acceptance Scenarios**:

1. **Given** a user was watching a TV show episode halfway through, **When** they log into the new server, **Then** the episode appears in "On Deck" with the correct resume point
2. **Given** users have items in their watchlist, **When** migration completes, **Then** all watchlist items are preserved
3. **Given** users have specific playback settings (subtitles, audio tracks), **When** they resume playback, **Then** their preferences are applied automatically

---

### Edge Cases

- If the source Plex database is corrupted or inconsistent, migration will abort immediately, document the corruption details, and leave the source VM running for administrator investigation
- Media files that have been moved or deleted since the last scan will be logged as warnings but will not block migration; Plex will mark these items as unavailable after migration
- If the Kubernetes pod restarts during migration, idempotency checks will detect the existing database and skip re-import to prevent data loss
- What if NFS mounts are not accessible during migration (network issues)?
- How do we handle custom Plex plugins or agents that may not be compatible with the new environment?
- How do we handle in-progress transcoding jobs when the migration occurs?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST create a complete backup of the source Plex database before any migration steps begin
- **FR-002**: System MUST stop the source Plex service before copying the database to ensure consistency
- **FR-003**: System MUST copy the Plex database directory from the source VM to the Kubernetes persistent volume
- **FR-004**: System MUST update all media path references in the database from /mnt/nas-plex to /media/library
- **FR-005**: System MUST update all optimized media path references from /mnt/nas-plex-optimized to /media/optimized
- **FR-006**: System MUST preserve the Plex server's unique identifier (machine ID) to maintain Plex Pass and authentication
- **FR-007**: System MUST migrate all critical Plex data directories including Preferences, complete Metadata cache (artwork, posters, thumbnails), Cache, and Plug-ins
- **FR-007a**: System MUST verify that source and target Plex versions match before beginning migration
- **FR-008**: System MUST prompt the administrator before stopping the source Plex service
- **FR-009**: System MUST verify database integrity before migration begins and abort if corruption is detected
- **FR-010**: System MUST verify database integrity after path updates and before starting the target Plex service
- **FR-011**: System MUST provide a rollback mechanism that leaves the source VM in its original working state
- **FR-012**: System MUST verify NFS mount accessibility before attempting to start the migrated Plex service
- **FR-013**: System MUST include idempotency checks to prevent overwriting an existing Plex database if the pod restarts during or after migration
- **FR-014**: System MUST document all migration steps taken for audit and troubleshooting purposes, including any detected corruption, errors, or missing media files

### Key Entities

- **Plex Database**: SQLite database containing all library metadata, user data, watch history, collections, and configuration. Located in the "Plug-in Support/Databases" directory.
- **Plex Preferences**: XML configuration files containing server settings, network configuration, and feature flags. Located in the Preferences.xml file.
- **Plex Metadata**: Downloaded artwork, posters, thumbnails, and metadata cache. Will be fully migrated to preserve all custom artwork and cached metadata.
- **Media Path Mapping**: Transformation rules that convert old file paths (/mnt/nas-plex/*) to new paths (/media/library/*) within the database.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Migration completes within 4 hours for a library containing up to 10,000 media items (includes full metadata transfer)
- **SC-002**: 100% of library items remain accessible after migration (no broken media links)
- **SC-003**: All user watch history and resume points are preserved with 100% accuracy
- **SC-004**: Source VM remains fully functional and can be restarted without issues after migration
- **SC-005**: Administrator can verify migration success by playing at least 10 random media items without errors
- **SC-006**: Zero database data loss occurs during migration (verified by comparing database record counts before and after)
- **SC-007**: All custom artwork, posters, and metadata cache are preserved (verified by comparing artwork for sample items)
- **SC-008**: Missing or unavailable media files are logged but do not prevent migration completion

## Scope *(mandatory)*

### In Scope

- Migrating Plex database, preferences, and complete metadata cache (artwork, posters, thumbnails)
- Updating media path references to match new mount points
- Verifying media accessibility through new NFS mounts
- Ensuring source VM remains intact and recoverable
- Providing step-by-step migration instructions with checkpoints

### Out of Scope

- Migrating Plex plugins (will need to be reinstalled on target)
- Updating DNS or external access URLs (separate infrastructure concern)
- Performance tuning or optimization of the Kubernetes deployment
- Setting up new Plex features not present in source installation

## Assumptions *(mandatory)*

- Source and target Plex servers will run identical versions to ensure database schema compatibility
- SSH access to source VM is available with appropriate permissions
- Kubernetes Plex pod has sufficient storage allocated for database plus complete metadata cache (typically 2-3x database size)
- NFS mounts are properly configured and accessible from Kubernetes cluster
- Network connectivity exists between source VM and Kubernetes cluster
- Administrator has appropriate credentials for both source VM and Kubernetes cluster
- Media files have already been moved to NFS shares and are accessible at new paths

## Dependencies *(include if there are external dependencies)*

### Internal Dependencies
- Kubernetes Plex deployment must be fully functional with NFS mounts working
- NFS shares must be accessible with correct permissions
- Plex Helm Chart's init container feature will be used for database import

### External Dependencies
- SSH connectivity to source VM at 192.168.13.21
- Network access from Kubernetes cluster to NFS server (diskstation.krebiehl.com)
- Source Plex service must be stoppable without disrupting other services
- Extended service downtime during migration is acceptable (no strict time constraints)
- Plex database and configuration will be imported to `/config/Library` directory in the Kubernetes pod
- Migration will leverage the Plex Helm Chart's built-in init container support for database import
