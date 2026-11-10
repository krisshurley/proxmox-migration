# Development: restart-aware VMware Tools cleanup

This branch collects the test-VM procedure into step 3. It is experimental. The existing source readiness, VirtIO preparation, state capture and network restoration code is preserved. The default menu runner enables the extended cleanup **on `dev`**. The standalone restore script retains its previous default unless passed `-UseExtendedToolsCleanup` or resuming an existing workflow.

## Operator flow

1. Run steps 1 and 2 on VMware and take the migration backup as usual.
2. Restore to Proxmox, preserve source MAC addresses, finish Firstboot conversion, and run step 3 using this branch.
3. The extended worker backs up the cached MSI and performs the modified MSI uninstall. The report requests a manual restart. Restart Windows through the Start menu and verify console input/RDP.
4. Run step 3 again. The saved workflow resumes with narrowly scoped residual cleanup and requests another manual restart.
5. Restart and run step 3 again. Only the cleanup verification phase runs at this point; the migration script also performs its normal network/state validation.

No automatic reboot, startup service or scheduled task is installed. If the same step is run again before a required restart, no MSI/residual worker is repeated. Rerunning the completed workflow repeats read-only cleanup verification. For both Veeam/Firstboot and DirectImport, step 3 rechecks live adapter identity, addresses, DNS, metrics and route stores before deciding whether network writes are necessary. Drift uses the existing guarded restoration/rollback path. At each pending restart it saves an `IntermediateRestartRequired` report with network checks and guarded obsolete-route cleanup, then defers full state comparison and operational log export until final validation. A partial report is not migration approval. PnP INF bindings are queried in bulk with individual fallback for missing/ambiguous results or provider failure; presence and ownership are still rechecked before removal. Full device inventories remain in JSON reports; the terminal shows counts.

Status is stored in `Export-MigrationState/State/VMwareToolsCleanup/Workflow.json`, alongside separate MSI, residual and final verification directories. These paths are relative to the selected capture, not the current date's report folder. The state is bound to the computer name, Windows MachineGuid and SHA-256 of `PreMigrationState.json`. Keep the entire capture and all backups across restarts. The normal post-migration report links the workflow state and manual follow-up action.

To select the previous cleanup path for a **new** migration:

```powershell
.\Migrate-VmwareToProxmox.ps1 -UseExtendedToolsCleanup:$false
```

An existing extended workflow is always resumed/reviewed; the flag does not bypass it. Read-only `ValidateOnly`/`CompareOnly` and `-WhatIf` do not run the cleanup worker. The legacy explicit `VmwareUninstall` mode is unchanged and does not start the extended workflow.

## Components

- `../Invoke-VMwareToolsCleanup.ps1`: workflow, target/Firstboot checks, exclusive execution lock, persistent checkpoints and worker orchestration.
- `../Migration.VMwareToolsCleanup.ps1`: pure state/identity/verification helpers.
- `Invoke-MsiUninstall.ps1`: backed-up transactional MSI modification and logged uninstall. Default standalone invocation is inspection only. Writes require explicit `-Uninstall`; skipping Guest Handler restoration additionally requires `-SkipGuestHandlerRestore`.
- `Remove-Residuals.ps1`: Audit/Cleanup only. Requires absent Tools product/service registrations, stopped VMware drivers and verified absent devices. Dynamically identifies published packages, exports them before removal, uses no `/force`, and preserves Microsoft PCI bridges/controllers and the current Microsoft mouse driver. Does not change file ownership/ACLs or forcibly delete protected SYS files.
- `Test-FinalState.ps1`: read-only COM+, startup, process, product registration, scoped Guest Handler and directory checks. Only report files are written. The workflow also reruns the driver/package audit.

No Microsoft `.diagcab`, unattended troubleshooting wrapper, manual mouse-switch prototype or third-party cleanup script is included. The successful MSI path removed the active VMware mouse and balloon drivers in the test; a separate manual Device Manager change was not required.

## Supported scope and verification limits

The preceding MSI method and combined Veeam workflow were exercised on Windows Server 2019 x64 with VMware Tools 13.0.10.0. The new dynamic selector is not a claim of Windows compatibility with other versions. Package version numbers are no longer allowlisted. A unique registered product, matching cached MSI product code/name/version, QEMU/KVM target, running QEMU Guest Agent and healthy present PCI VirtIO SCSI controller are still required. Present VMware network/storage hardware blocks the MSI test.

The entire `CustomAction` table is inspected. Recognized roles are `VM_LogStart` (type 257, entrypoint `VMLogStart`), `VM_CheckRequirements` (type 257, entrypoint `VMCheckRequirements`) and `VM_UninstGHIRestGuestHandle` (type 3073, entrypoint `VMUninstallGHIRestoreGuestHandlers`). These names may have no suffix or one structured GUID suffix; the GUID value is not hardcoded. DLL stream names are read from the actual rows and selected actions must reference exactly one existing `Binary` stream. This validates package structure, not the behavior of arbitrary vendor DLL code.

Missing individual roles are accepted; no fabricated action names are deleted. Unknown role/name/entrypoint/type combinations, duplicate roles, missing/ambiguous Binary references and completely unrecognized layouts stop before MSI modification. Unrelated custom actions are preserved and their complete row contents are rechecked before transaction commit. This is not a general bypass of all VMware checks or support for every package layout.

Inspect a target's package first, without uninstalling or modifying MSI/service/driver/network configuration:

```powershell
.\VMwareToolsCleanup\Invoke-MsiUninstall.ps1 -SkipGuestHandlerRestore
```

Use elevated 64-bit Windows PowerShell 5.1 on Proxmox; the target/Firstboot/agent/storage gates still apply. Inspection writes evidence only. `inspection.json` records actual package identity, all action rows, the selected plan and `RecognizedLayout`/`Blocked` status with an error explanation when action validation fails. Early identity/environment failures are in the transcript. Default inspection never opens the MSI for writing.

The automatic workflow requests the Guest Handler bypass only if that recognized action exists. `GuestHandlerRestoreRequested`, `GuestHandlerRestorePlannedSkip` and `GuestHandlerRestoreSkipped` are separate evidence fields (inspection alone never reports an executed skip); the workflow reports whether MSI was actually modified and Guest Handler restoration actually skipped. A recognized standalone package with no selected changes can use ordinary uninstall without patching. Backups/hash verification remain required. Unrecognized layouts never fall back to blanket action deletion, service deletion or Microsoft troubleshooting.

This modifies a vendor MSI where selected actions require it and is **not represented as vendor-supported uninstallation**. Guest Handler restoration crashed with `0xc0000096` in the tested 13.0.10 package; that observation does not establish a crash on other versions. Scoped registry backups cover the machine and currently loaded user hives. Unloaded profiles and all shell/file associations or MSI component references are not fully verified. A completed workflow means its defined checks passed; the report retains the verification-limit warning.

If Tools has already been fully removed by Firstboot, a new workflow only verifies the result. Residuals found in that case require manual review: the workflow does not guess which old product/version owned them. The helpers recheck Firstboot. DirectImport explicitly declares no Firstboot only when the captured method is DirectImport; an existing unverified conversion still blocks the workflow. Local fixture tests cover both methods and synthetic alternate versions/layouts; these fixtures are not real vendor packages or Windows uninstall tests.

## Failure handling

An interrupted `MsiInProgress`/`ResidualsInProgress`, failed worker or inconsistent capture stops automatic retry. Failed or interrupted verification is recorded separately and may retry read-only checks; it never repeats MSI or residual removal. MSI rollback is not assumed complete. Keep the backup of the original cached MSI, worker logs and capture, and investigate before restoring or retrying. Registry exports are not complete MSI/PnP rollback. Do not delete or edit `Workflow.json` to force progress, and do not import an entire `Run.reg` over unrelated startup settings.

A workflow-wide file lock prevents concurrent cleanup orchestration. Windows Installer's execution mutex is separately checked by the MSI helper. This is a point-in-time check, not a substitute for keeping other installer activity idle during migration. Native installer hangs are not forcibly killed or automatically repaired.

## Provenance

The approach was investigated from the linked community MSI-editing scripts; their code was not imported wholesale. In particular the implementation avoids `Win32_Product`, backs up before MSI writes, uses transactional modification, makes inspection non-mutating, checks the exact targeted actions and records actual MSI exit codes.

- [Discussion and source links](https://forum.proxmox.com/threads/collection-of-scripts-to-uninstall-remove-vmware-tools-in-windows-post-migration.175787/)
- [Community MSI approach](https://gist.github.com/Jason-Clark-FG/68e23b534f5be4e3f3b43f3bd37f1d65)
- [Broadcom: uninstall failure after migration to another hypervisor](https://knowledge.broadcom.com/external/article/414772/unable-to-uninstall-vmware-tools-from-wi.html)

## Cleanup choice and restart signal

Step 3 asks once per capture: `1) Automatic cleanup (default)` or `2) Manual cleanup`. The saved choice is bound to the computer name and capture hash in `ToolsCleanupChoice.json`. An explicit `-ToolsCleanupMode Manual` or `-ToolsCleanupMode Automatic` overrides it. This applies to both Veeam/Firstboot and DirectImport. Manual mode skips both extended and legacy Tools cleanup, including when a failed/pending workflow exists; it preserves workflow state/backups, reports manual follow-up, and continues network restoration and validation. It does not undo a previous MSI transaction or cancel a previously required restart. Remaining Tools are reported honestly as warnings. Firstboot and network safety gates still apply.

`-UseExtendedToolsCleanup:$false` selects the older automatic path, not manual mode. Standalone `Restore-And-TestMigrationState.ps1 -Mode Full` also accepts the choice parameter and uses a saved choice unless explicitly overridden. Read-only and network-only modes do not save or execute a Tools choice.

At a pending restart, the standalone restore exits `3010` after saving the intermediate report and printing `RESTART REQUIRED`. The menu consumes this dedicated status, prints restart instructions last and returns warning exit `1`. Generic warnings do not request a restart; other failures keep their failure codes.

## Approval across restart checkpoints

The menu's first step 3 confirmation covers the planned restart continuations for that exact VM/capture/options. `Step3Approval.json` is stored beside the selected capture. It binds computer/MachineGuid, target SMBIOS UUID, capture path/content, network capture, evidence inputs, current adapter GUID/MAC/description, script hashes and effective options (including custom map/application file contents). Interface indexes are deliberately excluded because they can change after restart.

Approval is reusable only in `AwaitingMsiReboot`/`AwaitingResidualReboot`, with a matching workflow identity and Automatic mode. Fresh, completed, interrupted or failed workflows cannot inherit it. `-Confirm` explicitly asks again; `-Confirm:$false` authorizes this invocation normally. WhatIf neither saves nor clears approval. Unavailable context, corrupt tokens or mismatches require a fresh confirmation. The menu removes approval after completion, cancellation or a handled error. A hard-killed process is still subject to workflow stage/identity validation on the next run.

A resumed invocation still verifies live network settings. If they drift or cannot be read, restoration requires renewed confirmation before snapshots/network writes; declining stops that invocation. All existing target, Firstboot, MSI, rollback and route ownership guards remain active. The internal `ResumeApproved` restore parameter enables this extra drift-confirmation behavior; it does not bypass safety checks. The internal `RestartBannerHandledByCaller` switch lets the menu own the final restart banner; standalone restore retains its own banner. No automatic reboot or scheduled task is added.

## Tools already removed by conversion

New workflows without a registered Tools product start in `ReadyForResiduals`, run the guarded residual worker, request one restart, then audit/final verification. They do not run the modified MSI worker. Older `VerificationFailed` checkpoints from the previous product-absent branch may take this route only if product, MSI-run and residual-run records are empty and no live Tools product exists. Completed workflows remain read-only; failed/interrupted mutations remain blocked. Source steps 1/2 retain their preparation behavior.

`pvscsi` pointing to Windows `pvscsii.sys` is separated as `PreservedDrivers` only when its inbox INF service/binary mapping, published INF/DriverStore bytes, installed SYS/DriverStore bytes and Microsoft signature are verified. It is not counted as a Tools residual and is never deleted. Unknown ownership blocks the audit. Vendor `pvscsi.sys` and exported vendor OEM packages retain the existing removal guards. Historical Microsoft PCI ports/bridges and generation counters are still preserved. PnP INF reads use batches of at most 32 with per-device fallback. Child exceptions (including failures before worker transcript startup) are saved as `*-error-*.json` with message, error ID, position and script stack under the capture's cleanup directory.

## Offline disks in step 3

The interactive menu offers `[y/N]` only for uniquely matched captured data disks. Default/No and noninteractive invocation leave disks unchanged; an explicit `-RepairOfflineDisks` opts in using the same guarded plan. Approval is saved in `OfflineDiskChoice.json` for the capture/VM during restart continuations, is included in the effective step-3 approval options and is cleared at completion/cancellation/handled failure. WhatIf does not save consent or change disks.

New captures add persistent disk GUID/signature fields without changing schema version or source preparation. Old captures use a preserved UniqueId/serial or a uniquely matching size/style/partition layout. Disk numbers alone never establish identity; two indistinguishable legacy layouts are left offline. Boot/system, RAW, unhealthy and ambiguous/unmatched disks are excluded. The child rechecks the current disk set, uniqueness and identity before writes, backs up before-state, then clears read-only/sets online and verifies the result. No SAN policy change, initialization, formatting, drive-letter assignment or automatic SQL/application-service start is performed.
