# Tasks: Migrate Plex Library to Kubernetes

**Input**: Design documents from `/specs/002-migrate-plex-library/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Not requested - manual verification via quickstart.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

This is an infrastructure migration project with:
- **Migration scripts**: `scripts/migrate-plex/` at repository root
- **Declarative config**: `base/plex/` (existing Plex deployment)
- **Documentation**: `specs/002-migrate-plex-library/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create migration script structure and verify prerequisites

- [x] T001 Create scripts directory structure at scripts/migrate-plex/
- [x] T002 Verify SSH access to source VM (alex@192.168.13.21)
- [x] T003 Verify kubectl access to Kubernetes cluster and plex namespace
- [x] T004 Verify NFS mounts are configured in base/plex/release.yaml

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core scripts that ALL user stories depend on

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [x] T005 [P] Create database integrity verification script in scripts/migrate-plex/verify-database.sh
- [x] T006 [P] Create archive creation script in scripts/migrate-plex/create-archive.sh
- [x] T007 [P] Create version detection script in scripts/migrate-plex/detect-version.sh
- [x] T008 Create main orchestration script in scripts/migrate-plex/migrate.sh
- [x] T009 Create migration README with prerequisites and rollback instructions in scripts/migrate-plex/README.md

**Checkpoint**: Foundation ready - user story implementation can now begin

---

## Phase 3: User Story 1 - Migrate Core Library Data (Priority: P1) 🎯 MVP

**Goal**: Copy complete Plex library from source VM to Kubernetes pod, preserving all database content, user data, watch history, metadata cache, and preferences

**Independent Test**:
1. Run migration script
2. Access Plex UI (http://plex.krebiehl.com or http://172.20.6.102:32400/web)
3. Verify all libraries visible with metadata intact
4. Verify user accounts present
5. Verify collections and playlists intact

### Implementation for User Story 1

- [ ] T010 [US1] Implement Plex version detection in scripts/migrate-plex/detect-version.sh
- [ ] T011 [US1] Implement database integrity check in scripts/migrate-plex/verify-database.sh
- [ ] T012 [US1] Add user prompt for stopping Plex service to scripts/migrate-plex/migrate.sh
- [ ] T013 [US1] Implement Plex service stop command in scripts/migrate-plex/migrate.sh
- [ ] T014 [US1] Implement database backup creation in scripts/migrate-plex/migrate.sh
- [ ] T015 [US1] Implement Library directory archiving in scripts/migrate-plex/create-archive.sh
- [ ] T016 [US1] Implement archive copy to local computer (scp) in scripts/migrate-plex/migrate.sh
- [ ] T017 [US1] Implement archive upload to Kubernetes pod (kubectl cp) in scripts/migrate-plex/migrate.sh
- [ ] T018 [US1] Implement archive extraction in pod (/config/) in scripts/migrate-plex/migrate.sh
- [ ] T019 [US1] Update base/plex/release.yaml with detected Plex version (image.tag)
- [ ] T020 [US1] Implement pod restart trigger in scripts/migrate-plex/migrate.sh
- [ ] T021 [US1] Add migration logging to scripts/migrate-plex/migrate.log
- [ ] T022 [US1] Implement rollback instructions in scripts/migrate-plex/README.md

**Checkpoint**: At this point, User Story 1 should be fully functional - database migrated, Plex running with all data intact

---

## Phase 4: User Story 2 - Verify Media Accessibility (Priority: P2)

**Goal**: Update library paths via Plex UI and verify all media files are accessible through new NFS mount paths

**Independent Test**:
1. Access Plex UI
2. Update each library path from /mnt/nas-plex to /media/library
3. Update optimized paths from /mnt/nas-plex-optimized to /media/optimized
4. Attempt playback from each library type (Movies, TV Shows, Music)
5. Verify playback begins within 5 seconds
6. Verify no missing media errors

### Implementation for User Story 2

- [ ] T023 [US2] Create path update guide in scripts/migrate-plex/update-paths-guide.md
- [ ] T024 [US2] Document library path update procedure (Settings → Libraries → Edit) in quickstart.md
- [ ] T025 [US2] Add NFS mount verification check to scripts/migrate-plex/migrate.sh
- [ ] T026 [US2] Create media accessibility verification script in scripts/migrate-plex/verify-media.sh
- [ ] T027 [US2] Add playback test instructions to quickstart.md Step 12

**Checkpoint**: At this point, User Stories 1 AND 2 should both work - database migrated and media accessible

---

## Phase 5: User Story 3 - Preserve User Session State (Priority: P3)

**Goal**: Verify that user watch history, resume points, watchlists, and playback preferences are preserved after migration

**Independent Test**:
1. Log into Plex with user account
2. Check "On Deck" for resume points
3. Verify watchlist items present
4. Start playback and verify preferences (subtitles, audio) applied
5. Verify "Continue Watching" shows correct resume points

### Implementation for User Story 3

- [ ] T028 [US3] Add user session state verification to scripts/migrate-plex/verify-database.sh
- [ ] T029 [US3] Document watch history verification steps in quickstart.md Step 12
- [ ] T030 [US3] Add user preference check to post-migration validation in scripts/migrate-plex/migrate.sh
- [ ] T031 [US3] Create session state validation checklist in scripts/migrate-plex/README.md

**Checkpoint**: All user stories should now be independently functional - complete migration with full data preservation

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Improvements that affect multiple user stories and final documentation

- [ ] T032 [P] Add comprehensive error handling to all scripts in scripts/migrate-plex/
- [ ] T033 [P] Add detailed logging for each migration step in scripts/migrate-plex/migrate.sh
- [ ] T034 [P] Create troubleshooting section in scripts/migrate-plex/README.md
- [ ] T035 [P] Validate all commands in quickstart.md work correctly
- [ ] T036 Add estimated time durations for each step in quickstart.md
- [ ] T037 Create rollback testing procedure in scripts/migrate-plex/README.md
- [ ] T038 [P] Add cleanup instructions for temporary files in scripts/migrate-plex/migrate.sh
- [ ] T039 [P] Document success criteria verification in scripts/migrate-plex/README.md
- [ ] T040 Test complete migration end-to-end following quickstart.md

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: Depends on Setup completion - BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Foundational - MVP, highest priority
- **User Story 2 (Phase 4)**: Depends on User Story 1 (requires migrated database to update paths)
- **User Story 3 (Phase 5)**: Depends on User Story 1 (requires migrated database to verify session state)
- **Polish (Phase 6)**: Depends on all user stories being implemented

### User Story Dependencies

- **User Story 1 (P1)**: Can start after Foundational (Phase 2) - Core migration, no dependencies on other stories
- **User Story 2 (P2)**: Depends on User Story 1 completion - Must have database migrated before updating paths
- **User Story 3 (P3)**: Depends on User Story 1 completion - Must have database migrated before verifying session state

### Within Each User Story

**User Story 1 (Migrate Core Library Data)**:
1. Version detection (T010)
2. Database integrity check (T011)
3. User prompt + Plex stop (T012, T013)
4. Backup creation (T014)
5. Archive creation (T015)
6. Copy to local (T016)
7. Upload to pod (T017)
8. Extract in pod (T018)
9. Update Helm Chart (T019)
10. Restart pod (T020)
11. Logging + rollback docs (T021, T022)

**User Story 2 (Verify Media Accessibility)**:
1. NFS verification (T025)
2. Path update guide (T023, T024)
3. Media verification script (T026)
4. Playback tests (T027)

**User Story 3 (Preserve User Session State)**:
1. Session state verification (T028)
2. Documentation (T029, T030, T031)

### Parallel Opportunities

- **Phase 1 (Setup)**: All verification tasks (T002, T003, T004) can run in parallel
- **Phase 2 (Foundational)**: Script creation tasks T005, T006, T007 can run in parallel (different files)
- **Phase 6 (Polish)**: All [P] marked tasks can run in parallel (T032, T033, T034, T035, T038, T039)

**Sequential within User Stories**: Most tasks within US1 must run sequentially (they represent a migration workflow), but documentation tasks can be done in parallel with implementation

---

## Parallel Example: Foundational Phase

```bash
# Launch all foundational script creation together:
Task T005: "Create database integrity verification script in scripts/migrate-plex/verify-database.sh"
Task T006: "Create archive creation script in scripts/migrate-plex/create-archive.sh"
Task T007: "Create version detection script in scripts/migrate-plex/detect-version.sh"

# These can be implemented simultaneously as they are independent scripts
```

---

## Parallel Example: Polish Phase

```bash
# Launch all polish tasks together:
Task T032: "Add comprehensive error handling to all scripts"
Task T033: "Add detailed logging for each migration step"
Task T034: "Create troubleshooting section in README"
Task T035: "Validate all commands in quickstart.md"
Task T038: "Add cleanup instructions for temporary files"
Task T039: "Document success criteria verification"

# These are independent documentation/improvement tasks
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (verify prerequisites)
2. Complete Phase 2: Foundational (create all base scripts)
3. Complete Phase 3: User Story 1 (full migration workflow)
4. **STOP and VALIDATE**: Run complete migration following quickstart.md
5. Verify all libraries visible, metadata intact, users preserved

**At this point you have a working migration!** US2 and US3 are enhancements.

### Incremental Delivery

1. Complete Setup + Foundational → Scripts ready
2. Add User Story 1 → Test independently → **Working migration! (MVP)**
3. Add User Story 2 → Test independently → Path updates + playback verified
4. Add User Story 3 → Test independently → Session state verified
5. Each story adds value without breaking previous functionality

### Timeline Estimates

| Phase | Tasks | Estimated Time | Cumulative |
|-------|-------|----------------|------------|
| Setup | 4 | 30 min | 30 min |
| Foundational | 5 | 2 hours | 2.5 hours |
| User Story 1 | 13 | 4 hours | 6.5 hours |
| User Story 2 | 5 | 1 hour | 7.5 hours |
| User Story 3 | 4 | 45 min | 8.25 hours |
| Polish | 9 | 2 hours | 10.25 hours |

**Total Implementation**: ~10 hours

**Actual Migration Execution**: 1-2 hours (following quickstart.md)

---

## Notes

- **[P] tasks** = different files, no dependencies
- **[Story] label** maps task to specific user story for traceability
- Each user story should be independently testable once its phase completes
- User Story 1 represents the MVP - a complete working migration
- User Story 2 and 3 are validation/verification enhancements
- Commit after each task or logical group
- Stop at any checkpoint to validate story independently
- Migration is **non-destructive** - source VM remains intact for rollback
- **No automated tests** - all verification via quickstart.md manual steps

---

## Success Criteria

✅ Migration is successful when:

- [ ] **US1**: All libraries visible in Plex UI with complete metadata
- [ ] **US1**: User accounts with watch history preserved
- [ ] **US1**: Collections and playlists intact
- [ ] **US1**: Source VM untouched and can be restarted
- [ ] **US2**: Media playback works from all libraries (Movies, TV Shows, etc.)
- [ ] **US2**: Playback begins within 5 seconds
- [ ] **US2**: No missing media errors
- [ ] **US3**: Watch history shows resume points
- [ ] **US3**: Watchlist items preserved
- [ ] **US3**: User preferences (subtitles, audio) applied automatically

---

## Task Count Summary

- **Phase 1 (Setup)**: 4 tasks
- **Phase 2 (Foundational)**: 5 tasks
- **Phase 3 (US1 - MVP)**: 13 tasks ⭐ Core migration
- **Phase 4 (US2)**: 5 tasks
- **Phase 5 (US3)**: 4 tasks
- **Phase 6 (Polish)**: 9 tasks

**Total**: 40 tasks

**MVP (US1 only)**: 22 tasks (Setup + Foundational + US1)

**Parallel opportunities**: 9 tasks can run in parallel (3 in Foundational, 6 in Polish)
