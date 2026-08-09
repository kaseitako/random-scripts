# Startup Virtual Desktop Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconcile configured application windows onto named Windows virtual desktops without fixed sequencing sleeps.

**Architecture:** A platform-independent PowerShell core normalizes settings, selects windows, polls with bounded timeouts, and orchestrates reconciliation through an injected adapter. A Windows adapter supplies Win32 window enumeration, process launch, PSVirtualDesktop integration, wallpaper handling, and maximization; the entry script owns dependency checks, logging, and the single-instance mutex.

**Tech Stack:** PowerShell 7.5+, Pester 3.4-compatible tests, PSVirtualDesktop 1.5.11+, Win32 user32 APIs

## Global Constraints

- Existing `path`, `fullscreen`, `wallpaperAbsolutePath`, and `waitSeconds` settings remain readable.
- No desktop-level or shutdown fixed sleeps.
- Every `Moved` or `AlreadyPlaced` result is verified with `Test-Window`.
- Application failures are isolated and later applications continue.
- Runtime paths resolve from `$PSScriptRoot`.
- Tests must not create desktops, launch configured applications, or move real windows.

---

### Task 1: Settings normalization and validation

**Files:**
- Create: `powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Core.psm1`
- Create: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Core.Tests.ps1`

**Interfaces:**
- Produces: `ConvertTo-DesktopLayoutSettings -InputObject <psobject>` returning normalized desktops and apps.
- Produces: `Test-DesktopLayoutSettings -Settings <psobject>` throwing one aggregated validation error.

- [ ] **Step 1: Write failing settings tests**

Cover legacy `fullscreen`, deprecated `waitSeconds`, default `timeoutSeconds = 30`, default `onExisting = Move`, duplicate desktop names, invalid timeout, and invalid regular expressions.

```powershell
Describe 'ConvertTo-DesktopLayoutSettings' {
    It 'normalizes legacy settings' {
        $input = [pscustomobject]@{ desktops = @([pscustomobject]@{
            name = 'Main'; waitSeconds = 10; apps = @([pscustomobject]@{ path = 'chrome'; fullscreen = $true })
        }) }
        $result = ConvertTo-DesktopLayoutSettings $input
        $result.desktops[0].apps[0].maximized | Should Be $true
        $result.desktops[0].apps[0].timeoutSeconds | Should Be 30
        $result.desktops[0].apps[0].onExisting | Should Be 'Move'
    }
}
```

- [ ] **Step 2: Run tests and confirm RED**

Run:

```powershell
Invoke-Pester -Script powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Core.Tests.ps1 -EnableExit
```

Expected: failures because the core module does not exist.

- [ ] **Step 3: Implement normalization and validation**

Use explicit defaults and return new objects instead of mutating the deserialized JSON. Validate unique non-empty desktop names, non-empty application paths, `1..300` timeouts, `Move|Skip|Launch` policies, string-array arguments, and compilable regex fields.

- [ ] **Step 4: Run tests and confirm GREEN**

Expected: all Task 1 tests pass with no warnings except the deliberate deprecation result recorded in normalized metadata.

### Task 2: Window selection and bounded polling

**Files:**
- Modify: `powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Core.psm1`
- Modify: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Core.Tests.ps1`

**Interfaces:**
- Produces: `Get-WindowMatchScore -Window <psobject> -App <psobject> -NewHandles <hashtable> -ExcludedHandles <hashtable>` returning `-1` for no match.
- Produces: `Wait-ApplicationWindow -App <psobject> -Adapter <psobject> -BeforeHandles <hashtable> -ExcludedHandles <hashtable>` returning a window or `$null`.
- Adapter consumes: `GetWindows`, `GetUtcNow`, and `Wait` scriptblocks.

- [ ] **Step 1: Write failing matching tests**

Test explicit AND matching, inferred process matching, shortcut-title preference, new-handle preference, excluded handles, delayed appearance, and timeout.

```powershell
It 'waits until a matching window appears' {
    $script:calls = 0
    $adapter = [pscustomobject]@{
        GetWindows = { $script:calls++; if ($script:calls -lt 3) { @() } else { @($script:window) } }
        GetUtcNow = { [datetime]'2026-08-09T00:00:00Z'.AddMilliseconds($script:calls * 200) }
        Wait = { param($milliseconds) }
    }
    $result = Wait-ApplicationWindow -App $script:app -Adapter $adapter -BeforeHandles @{} -ExcludedHandles @{}
    $result.Handle | Should Be 42
}
```

- [ ] **Step 2: Run the focused tests and confirm RED**

Expected: missing matching functions.

- [ ] **Step 3: Implement deterministic scoring and polling**

Explicit match criteria are mandatory when supplied. Otherwise score inferred process, shortcut title, launched-process ID, and new handle; select the highest score with handle order as a stable tie-breaker. Poll at 200 ms through the adapter until the app timeout.

- [ ] **Step 4: Run all core tests and confirm GREEN**

### Task 3: Desktop-layout orchestration

**Files:**
- Modify: `powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Core.psm1`
- Modify: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Core.Tests.ps1`

**Interfaces:**
- Produces: `Invoke-DesktopLayout -Settings <psobject> -Adapter <psobject> -Log <scriptblock>` returning application result objects.
- Adapter consumes: `GetOrCreateDesktop`, `SetWallpaper`, `GetWindows`, `StartApplication`, `MoveWindow`, `TestWindow`, `MaximizeWindow`, `GetUtcNow`, and `Wait`.

- [ ] **Step 1: Write failing orchestration tests**

Cover existing-window move without launch, already-placed detection, launch and delayed detection, maximization after movement, verification failure, timeout continuation, `Skip`, `Launch`, and handle reservation.

```powershell
It 'continues after an application timeout' {
    $results = Invoke-DesktopLayout -Settings $script:twoAppSettings -Adapter $script:adapter -Log { param($level, $message, $data) }
    $results.Count | Should Be 2
    $results[0].Status | Should Be 'Failed'
    $results[1].Status | Should Be 'Moved'
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

Expected: `Invoke-DesktopLayout` is missing.

- [ ] **Step 3: Implement reconciliation**

Create all desktops first. Process apps sequentially inside per-app `try/catch`, reserve selected handles, verify both pre-existing and moved windows, and return fields `DesktopName`, `Path`, `Status`, `Handle`, `ProcessName`, `ElapsedMilliseconds`, and `Error`.

- [ ] **Step 4: Run all core tests and confirm GREEN**

### Task 4: Windows platform adapter

**Files:**
- Create: `powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Windows.psm1`
- Create: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1`
- Modify: `powershell/startup-virtual-desktop/modules/Request-NamedDesktop.psm1`

**Interfaces:**
- Produces: `New-WindowsDesktopAdapter` returning every operation consumed by the core.
- Produces: `Get-StartupEnvironmentDiagnostics` returning OS, PowerShell, and module versions.

- [ ] **Step 1: Write failing adapter smoke tests**

Tests import the module, verify adapter operation names, resolve `cmd`, resolve a temporary `.lnk` created through `WScript.Shell`, enumerate windows without mutation, and confirm diagnostics fields.

- [ ] **Step 2: Run tests and confirm RED**

Expected: Windows module is missing.

- [ ] **Step 3: Implement the adapter**

Add a namespaced C# `WindowApi` type once. Enumerate visible unowned top-level windows with handle, title, class, PID, and process name. Resolve shortcuts and command paths, launch with `Start-Process -PassThru`, use `Move-Window`/`Test-Window`, maximize with `ShowWindowAsync(SW_MAXIMIZE)`, and use `Set-DesktopWallpaper` where supported.

- [ ] **Step 4: Run smoke tests and confirm GREEN**

The tests must not invoke the adapter's mutation operations.

### Task 5: Entry script, mutex, and logging

**Files:**
- Modify: `powershell/startup-virtual-desktop/Startup-VirtualDesktop.ps1`
- Create: `powershell/startup-virtual-desktop/tests/Startup-VirtualDesktop.Entry.Tests.ps1`
- Modify: `.gitignore`

**Interfaces:**
- Entry parameters: `-SettingsPath`, `-LogDirectory`, and `-ValidateOnly`.
- `-ValidateOnly` performs dependency, parse, normalization, and validation checks without desktop or application mutation.

- [ ] **Step 1: Write failing entry tests**

Use the PowerShell parser to require zero syntax errors. Invoke from a different current directory with `-ValidateOnly` against the sample settings. Assert no ten-second shutdown message, no desktop-loop `Start-Sleep`, and a successful exit code.

- [ ] **Step 2: Run tests and confirm RED**

Expected: current script lacks parameters and validate-only behavior.

- [ ] **Step 3: Implement the entry script**

Resolve paths from `$PSScriptRoot`, require VirtualDesktop 1.5.11 for runtime mode, condition-poll Explorer with a 30-second bound, acquire a per-user mutex, append UTF-8 JSON-lines logs under `logs/`, call the core, summarize statuses, release the mutex in `finally`, and exit `1` if any result failed.

- [ ] **Step 4: Run entry and complete test suites**

Expected: validate-only succeeds from outside the project directory and all Pester tests pass.

### Task 6: Sample configuration and operating documentation

**Files:**
- Modify: `powershell/startup-virtual-desktop/virtual-desktop-setting.sample.json`
- Create: `powershell/startup-virtual-desktop/virtual-desktop-setting.schema.json`
- Modify: `powershell/startup-virtual-desktop/README.md`

**Interfaces:**
- Documents all settings and migration behavior.

- [ ] **Step 1: Add failing documentation/config tests**

Validate sample JSON parsing and normalization, schema JSON parsing, every documented `onExisting` value, and absence of the old instruction that relies on shortcut working-directory behavior.

- [ ] **Step 2: Run tests and confirm RED**

- [ ] **Step 3: Update sample, schema, and README**

Include basic and explicit-match examples, startup shortcut target, module version check/update commands, validate-only usage, logs, elevated-window limitation, Chrome/PWA matching guidance, and cold-start acceptance steps.

- [ ] **Step 4: Run all tests and static checks**

Run:

```powershell
Invoke-Pester -Script powershell/startup-virtual-desktop/tests -EnableExit
```

Also parse every `.ps1` and `.psm1` through `System.Management.Automation.Language.Parser`, and parse every JSON file through `ConvertFrom-Json`.

- [ ] **Step 5: Review the final diff**

Confirm the personal `virtual-desktop-setting.json` remains unchanged, no fixed sequencing sleeps exist, no unrelated files changed, and all acceptance criteria map to passing tests or a documented cold-start manual check.
