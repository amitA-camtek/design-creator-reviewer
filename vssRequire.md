# Jobs VSS Manager — Engineering Requirements

**Project:** JobsVssManager
**Document type:** Engineering Requirements Specification
**Status:** Baseline

---

## 1. Purpose & Scope

Jobs VSS Manager is a Windows desktop application that lets an operator create, list, restore from, and delete Volume Shadow Copy Service (VSS) snapshots scoped to job folders on a target volume. The application is intended for internal use on Windows workstations that host job data and require point-in-time backup/restore capability without a full backup infrastructure.

In scope:
- Snapshot create / list / delete on a configured volume.
- Restore of a selected job folder from a chosen snapshot.
- Custom snapshot description metadata kept alongside Windows VSS state.
- Restore-state tracking with the ability to resume an interrupted restore.

Out of scope:
- Network/remote VSS targets.
- Scheduled / unattended snapshot creation.
- Multi-user / multi-machine coordination.
- Backup of arbitrary files outside the configured `JobsRoot`.

---

## 2. Stakeholders & Users

- **Primary user:** Local operator running the workstation as Administrator.
- **Maintainers:** Internal .NET / WPF developers.
- **Operating environment owner:** IT (controls VSS storage area, retention, disk capacity).

---

## 3. System Context

| Item | Value |
|------|-------|
| Application type | WPF desktop application (single window) |
| Target framework | .NET 6 (Windows). Port to .NET Framework 4.8 covered in `assessment.md`. |
| OS | Windows 10 / Windows Server with VSS support |
| Privilege level | Must run **elevated (Administrator)** |
| Backup mechanism | Windows VSS via WMI (`Win32_ShadowCopy`) and `vssadmin.exe` |
| Persistence | `appsettings.json` (config), `%AppData%\JobsVssManager\snapshots.json` (snapshot descriptions), restore-state JSON (resume support) |

---

## 4. Functional Requirements

### 4.1 Configuration
- **FR-CFG-1** — On startup the application MUST load `appsettings.json` from the executable directory.
- **FR-CFG-2** — Required configuration keys: `JobsRoot` (absolute path to the folder containing job subfolders), `Volume` (volume that hosts `JobsRoot`, e.g. `C:\`), `SnapshotExpirationHours` (integer, hours until a snapshot is considered expired).
- **FR-CFG-3** — If configuration is missing or invalid, the application MUST display a clear error and refuse to perform VSS operations.

### 4.2 Privilege Check
- **FR-PRIV-1** — On startup the application MUST verify the current process is running as Administrator (`WindowsPrincipal.IsInRole(Administrator)`).
- **FR-PRIV-2** — If not elevated, the application MUST display an error explaining the requirement and disable all VSS operations.

### 4.3 Job Discovery
- **FR-JOB-1** — The application MUST enumerate immediate subdirectories of `JobsRoot` and present them as selectable jobs.
- **FR-JOB-2** — The job list MUST refresh on user request and reflect new/removed directories without restart.
- **FR-JOB-3** — Each job entry exposes a display `Name` and absolute `Path`.

### 4.4 Snapshot Creation
- **FR-SNAP-CREATE-1** — The user can create a snapshot of the configured `Volume`.
- **FR-SNAP-CREATE-2** — Creation MUST use the WMI `Win32_ShadowCopy.Create` method or equivalent provider abstraction (`IVssProvider.CreateSnapshotAsync`).
- **FR-SNAP-CREATE-3** — A user-supplied description (default: `"Snapshot {timestamp}"`) MUST be persisted to the metadata file `%AppData%\JobsVssManager\snapshots.json` keyed by snapshot ID.
- **FR-SNAP-CREATE-4** — Each snapshot MUST carry an `ExpiresAt = CreatedAt + SnapshotExpirationHours`.
- **FR-SNAP-CREATE-5** — The operation MUST be non-blocking on the UI thread (async / `Task`).

### 4.5 Snapshot Listing
- **FR-SNAP-LIST-1** — The application MUST list all VSS snapshots whose source volume matches the configured `Volume`.
- **FR-SNAP-LIST-2** — Each list entry MUST show: ID, creation time (from VSS, not estimated), description (joined from metadata file; default text if missing), expiration time, and an "expired" indicator.
- **FR-SNAP-LIST-3** — Snapshots created outside the application MUST still appear with a default description.

### 4.6 Snapshot Deletion
- **FR-SNAP-DEL-1** — The user can delete a selected snapshot.
- **FR-SNAP-DEL-2** — Deletion MUST invoke `vssadmin delete shadows` or equivalent and MUST remove the matching entry from the metadata file.
- **FR-SNAP-DEL-3** — A confirmation prompt MUST be shown before destructive deletion.

### 4.7 Restore From Snapshot
- **FR-RESTORE-1** — The user can restore the contents of a selected job folder from a selected snapshot into the live `JobsRoot\<JobName>` location.
- **FR-RESTORE-2** — Restore MUST resolve the snapshot device path (`\\?\GLOBALROOT\Device\...`) and copy the corresponding subtree.
- **FR-RESTORE-3** — Restore MUST perform a smart sync: copy/overwrite changed files and remove files in the target that do not exist in the snapshot for that job folder.
- **FR-RESTORE-4** — Before starting, restore MUST persist a `RestoreState` (snapshot id, target path, start time, status, snapshot description) to disk so an interrupted operation can be detected.
- **FR-RESTORE-5** — On startup, if a `RestoreState` with `Status == InProgress` exists, the application MUST prompt the user to resume or discard.
- **FR-RESTORE-6** — On completion or failure, `RestoreState.Status` MUST be updated to `Completed` or `Failed` respectively.

### 4.8 Status & Progress
- **FR-UI-STATUS-1** — A status bar MUST show the current operation, last result, and elapsed duration of long-running operations.
- **FR-UI-STATUS-2** — While an operation is running, the UI MUST show a busy/blocking overlay and disable conflicting actions.

---

## 5. Non-Functional Requirements

### 5.1 Reliability
- **NFR-REL-1** — All VSS / file operations MUST be wrapped with exception handling that surfaces a human-readable message; raw exceptions are logged but never shown unparsed.
- **NFR-REL-2** — Metadata writes (`snapshots.json`, restore state) MUST be tolerant of concurrent process exits — write to a temp file then atomically replace.
- **NFR-REL-3** — A failed restore MUST leave the metadata in a state from which the user can retry without restarting the app.

### 5.2 Performance
- **NFR-PERF-1** — Startup to interactive UI: < 2 seconds on the target workstation (cold start, excluding VSS query latency).
- **NFR-PERF-2** — Snapshot list refresh: < 3 seconds for up to 64 snapshots.
- **NFR-PERF-3** — UI MUST remain responsive (no input freeze > 200 ms) during VSS / restore operations; long work runs on background tasks.

### 5.3 Security
- **NFR-SEC-1** — The application MUST refuse to operate without Administrator privileges (see FR-PRIV).
- **NFR-SEC-2** — The application MUST NOT write outside `JobsRoot` or `%AppData%\JobsVssManager` during normal operation.
- **NFR-SEC-3** — Inputs to `vssadmin` and WMI calls MUST be validated (no arbitrary command construction from UI text).
- **NFR-SEC-4** — The metadata files MUST contain no credentials or PII.

### 5.4 Usability
- **NFR-UX-1** — The main window MUST follow MVVM (`BaseViewModel` + `INotifyPropertyChanged` + `RelayCommand`); no business logic in code-behind.
- **NFR-UX-2** — All destructive actions (delete, restore-overwrite) MUST require explicit confirmation.
- **NFR-UX-3** — Errors MUST be presented in a dialog or status panel, not silently logged.

### 5.5 Maintainability
- **NFR-MNT-1** — VSS access MUST be behind the `IVssProvider` abstraction so the underlying mechanism (WMI / vssadmin / future provider) can be swapped.
- **NFR-MNT-2** — Models, ViewModels, Services, Utilities, and Views MUST be in separate folders/namespaces (current layout).
- **NFR-MNT-3** — New code SHOULD remain compatible with both .NET 6 and .NET Framework 4.8 (avoid C# language features unsupported on net48 — see `assessment.md`).

### 5.6 Portability
- **NFR-PORT-1** — Code MUST avoid POSIX-only APIs and Linux/macOS-only paths.
- **NFR-PORT-2** — A documented downgrade path to .NET Framework 4.8 MUST be preserved (see `assessment.md`): no nullable reference types in public surface that would block the port without trivial edits, no implicit-usings-only constructs in shared logic.

### 5.7 Logging
- **NFR-LOG-1** — All VSS operations (create, delete, restore start/end) MUST be logged with timestamp, operation, snapshot id, and outcome.
- **NFR-LOG-2** — Logs MUST be written to a local file under `%AppData%\JobsVssManager` with rotation/size cap (implementation defined).

---

## 6. External Interfaces

### 6.1 Configuration File — `appsettings.json`
```json
{
  "JobsRoot": "C:\\job\\<machine-folder>",
  "Volume": "C:\\",
  "SnapshotExpirationHours": 24
}
```

### 6.2 Metadata File — `%AppData%\JobsVssManager\snapshots.json`
- Map of `snapshotId -> { description, expiresAt }`.
- Authoritative source for descriptions; VSS itself is authoritative for existence and creation time.

### 6.3 Restore State File — `%AppData%\JobsVssManager\restore-state.json`
- Single object: `{ snapshotId, targetPath, startedAt, status, snapshotDescription }`.
- `status ∈ { InProgress, Completed, Failed }`.

### 6.4 OS Interfaces
- `System.Management` (WMI) — `Win32_ShadowCopy` for create / enumerate / device path.
- `vssadmin.exe` — for delete operations.
- File system APIs (`System.IO`) for restore copy and folder enumeration.

---

## 7. Architecture Overview

| Layer | Components |
|-------|------------|
| Views | `MainWindow.xaml(.cs)` — pure presentation, binds to `MainViewModel`. |
| ViewModels | `BaseViewModel`, `JobViewModel`, `MainViewModel` — orchestrate user actions, expose observable state. |
| Services | `IVssProvider`, `VssAdminProvider` (WMI + vssadmin), `VssSnapshotService` (orchestration), `RestoreStateManager` (persistence of restore state). |
| Models | `JobModel`, `SnapshotModel`, `RestoreState`. |
| Utilities | `RelayCommand` for `ICommand`. |

Data flow: user action → command on ViewModel → service call → `IVssProvider` / file ops → result mapped to model → ViewModel raises `PropertyChanged` / updates `ObservableCollection`.

---

## 8. Constraints

- **C-1** — Must run on Windows only (WPF + VSS).
- **C-2** — Must run elevated; the app does not self-elevate.
- **C-3** — Single-instance assumption per workstation; no locking is implemented for concurrent app instances.
- **C-4** — Snapshots and restored data live on the same physical volume as `JobsRoot`; cross-volume scenarios are unsupported.
- **C-5** — Disk space for VSS storage area is managed by the OS / IT, not the application.

---

## 9. Assumptions

- The configured `Volume` is local, fixed (not removable / network).
- The user has write access to `JobsRoot` and to `%AppData%`.
- The Windows VSS service (`VSS`) is running and healthy.
- `vssadmin.exe` is present at its default Windows path.

---

## 10. Acceptance Criteria

The release is acceptance-ready when:

1. Launching as Administrator brings up the main window in under 2 seconds with the configured jobs visible.
2. Creating a snapshot adds an entry to the snapshot list with a non-empty description and an `ExpiresAt` consistent with `SnapshotExpirationHours`.
3. After app restart, the description of a previously created snapshot is still shown.
4. Deleting a snapshot removes it from both the VSS list and the metadata file.
5. Restore of a job folder produces a folder whose contents match the snapshot's contents for that path (verified by file count + checksum spot-check).
6. Killing the app mid-restore and relaunching presents a resume/discard prompt; choosing resume completes the restore correctly.
7. Running without Administrator privileges blocks all VSS operations and shows a clear error.
8. All operations log a start and end record with outcome.

---

## 11. Open Questions / Future Work

- Automatic deletion of expired snapshots (background sweeper) — currently manual.
- Per-job snapshot scoping vs whole-volume snapshot — currently whole-volume.
- Multi-volume support.
- Audit-log export.
- Localization (currently en-US only).
