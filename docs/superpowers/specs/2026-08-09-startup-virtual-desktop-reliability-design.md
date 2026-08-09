# Startup Virtual Desktop Reliability Design

## Summary

Replace the timing-dependent startup loop with a state reconciler. The reconciler creates the named desktops, locates or starts each configured application, moves the resulting top-level window to the intended desktop, verifies placement, and records a structured log.

The implementation remains PowerShell-based because PSVirtualDesktop already supplies desktop creation, window movement, placement checks, and Windows 11 wallpaper support. A native rewrite would still need the same application-window correlation logic.

## Goals

- Recreate the configured virtual-desktop layout after Windows sign-in.
- Remove desktop-level fixed sleeps and the final ten-second sleep.
- Explicitly move and verify every managed application window.
- Support launchers, shortcuts, single-instance applications, and Chromium/Electron applications.
- Remain compatible with existing `path`, `fullscreen`, `wallpaperAbsolutePath`, and `waitSeconds` settings.
- Continue processing other applications when one application fails.
- Produce enough diagnostics to identify launch, matching, movement, and verification failures.
- Prevent concurrent copies of the script from racing with each other.

## Non-goals

- Closing desktops or applications that are not present in the configuration.
- Closing duplicate windows.
- Managing window coordinates or monitor placement.
- Guaranteeing control over elevated windows from a non-elevated script.
- Replacing PSVirtualDesktop's private Windows virtual-desktop integration.

## Selected Approach

Use a PowerShell state reconciler with two modules:

| Component | Responsibility |
|---|---|
| `StartupVirtualDesktop.Core.psm1` | Settings normalization, validation, window selection, polling, orchestration, and result objects |
| `StartupVirtualDesktop.Windows.psm1` | Win32 window enumeration, process launch, PSVirtualDesktop calls, wallpaper changes, and maximizing windows |
| `Startup-VirtualDesktop.ps1` | Dependency checks, mutex, logging, adapter construction, invocation, and exit code |

The core accepts an adapter object made of callable operations. Tests use an in-memory fake adapter, while production uses the Windows adapter. This keeps timing and selection behavior testable without moving real windows.

## Processing Flow

1. Resolve every project path from `$PSScriptRoot`.
2. Acquire a named per-user mutex. Exit successfully with a warning if another run is active.
3. Verify Windows, PowerShell, VirtualDesktop module version 1.5.9 or later, and Explorer readiness; warn below the recommended 1.5.11.
4. Read, normalize, and validate the JSON settings.
5. Create or retrieve all named desktops before launching applications.
6. Apply each configured per-desktop wallpaper through `Set-DesktopWallpaper` when available.
7. Process applications sequentially so a newly created window can be attributed to one launch request.
8. Reuse an unassigned matching window when the existing-window policy is `Move`.
9. Otherwise snapshot windows, launch the application, and poll until a matching top-level window appears or the timeout expires.
10. Move the window with `Move-Window`, verify with `Test-Window`, and maximize when requested.
11. Record one result per application and continue after failures.
12. Exit nonzero when any configured desktop or application could not be reconciled.

The flow does not switch the visible desktop. Window placement therefore does not depend on switch animation or application startup speed.

## Window Correlation

### Explicit matching

An application may define `windowMatch` with all supplied fields combined using AND:

```json
{
  "processName": "chrome",
  "titleRegex": "SoundCloud",
  "classNameRegex": "Chrome_WidgetWin"
}
```

Supported fields are `processName`, `titleRegex`, and `classNameRegex`. Invalid regular expressions are rejected during settings validation.

### Backward-compatible inference

When `windowMatch` is omitted:

- Executable and command names infer the process name.
- Windows shortcuts are resolved to their target executable.
- The shortcut filename is used as a preferred title fragment.
- A new unassigned window belonging to the inferred process is preferred after launch.
- An existing unassigned window belonging to that process may be reused.

Each selected handle is reserved for the remainder of the run so one window cannot satisfy multiple application entries. Ambiguous applications should add an explicit `windowMatch`; this is particularly useful for multiple Chrome applications sharing `chrome.exe`.

## Configuration

Existing configuration remains valid. New optional properties are:

| Property | Default | Meaning |
|---|---:|---|
| `arguments` | empty | Command-line arguments, represented as a JSON string array |
| `workingDirectory` | empty | Application working directory |
| `timeoutSeconds` | `30` | Maximum time to wait for a window |
| `onExisting` | `Move` | `Move`, `Skip`, or `Launch` |
| `windowMatch` | inferred | Explicit window identity |
| `maximized` | value of `fullscreen` | Maximize after verified movement |

`waitSeconds` is accepted and logged as deprecated but no longer delays processing. `fullscreen` remains a compatibility alias for `maximized`; it means maximized, not exclusive full screen.

Desktop names must be non-empty and unique. Application paths must be non-empty. Timeouts must be positive and bounded to 300 seconds.

## Error Handling and Results

Every desktop and application operation returns a result object rather than relying only on console output.

| Status | Meaning |
|---|---|
| `Moved` | Existing or new window was moved and verified |
| `AlreadyPlaced` | Matching window was already on the target desktop |
| `Skipped` | Existing window was found and `onExisting` was `Skip` |
| `Failed` | Launch, matching, movement, or verification failed |

Logs include timestamps, OS build, PowerShell version, VirtualDesktop module version, desktop name, configured path, selected handle, process name, elapsed time, status, and error text. Logs are written under `logs/` next to the script and are not tracked by Git.

The entry script uses `try/finally` to release the mutex and flush logging. It does not need to restore the original desktop because reconciliation does not switch desktops.

## Startup Integration

The README will document a startup shortcut whose target invokes `pwsh.exe` with `-NoProfile -File` and an absolute script path. Script-relative paths remove the requirement to configure the shortcut's “Start in” field.

Explorer readiness is condition-polled with a bounded timeout rather than delayed by a fixed startup sleep.

## Testing

Pester tests cover:

- Existing settings normalization and compatibility aliases.
- Rejection of duplicate desktops, invalid timeouts, and invalid regular expressions.
- Existing-window reuse without launching a new process.
- Polling until a window appears without fixed desktop waits.
- Timeout behavior that does not stop later applications.
- Explicit window matching and prevention of handle reuse.
- Move, verification, maximization, and result statuses.
- Entry-script path resolution and parse validity.

Windows integration verification checks the production modules import under PowerShell 7 without invoking desktop mutations. Actual cold-start behavior remains a manual acceptance test because it requires sign-out or reboot and the configured desktop applications.

## Acceptance Criteria

- No `Start-Sleep` remains for desktop sequencing or process shutdown.
- A successful application result has a concrete top-level window handle and verified target desktop.
- One failed application does not prevent later applications from being processed.
- Existing JSON files remain readable without modification.
- Relative current-working-directory changes do not affect module or settings loading.
- Automated tests pass under the installed PowerShell 7 runtime.
- The README contains configuration, startup, diagnostics, and troubleshooting instructions.
