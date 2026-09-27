# toolbox\ — post-build maintenance

The scripts here are not part of the build pipeline. `New-Vhdx.ps1` and `Build-Vms.ps1`
in the project root get a lab *created*; these keep it healthy afterwards.

| Script | What it does |
|--------|--------------|
| `Migrate-Vms.ps1` | Export Hyper-V VMs to a USB / SATA disk or NAS, reinstall the host, import them back. Handles vTPM certificates and virtual switches |
| `Convert-Vhdx.ps1` | Convert Fixed (thick) VM disks to Dynamic (thin) and compact them, to reclaim host disk space |
| `Remove-Vms.ps1` | Delete VMs and their files — force turn off, leave the failover cluster, remove from Hyper-V, delete VHD/VHDX and configuration folders |
| `Repair-VmPlacement.ps1` | Find VMs whose files are not where the studio puts them and move them into place, per VM |

All of them run elevated on the Hyper-V host, all use the same arrow-key console menus as
the build scripts, and all are entirely optional.

```powershell
# From the project root
.\toolbox\Migrate-Vms.ps1
.\toolbox\Convert-Vhdx.ps1
.\toolbox\Remove-Vms.ps1
.\toolbox\Repair-VmPlacement.ps1
```

Logs still land in the project-wide `logs\` folder next to `Build-Vms.ps1`
(`logs\migrate-vms\`, `logs\convert-vhdx\`, `logs\remove-vms\`, `logs\repair-vmplacement\`), not in a second folder
under `toolbox\`.

`Convert-Vhdx.ps1` can use Sysinternals **SDelete** for its zero-free-space reclaim mode.
Drop `sdelete64.exe` in `toolbox\`, `toolbox\tools\`, the project root, or anywhere on
`PATH` — all are checked.

## Remove-Vms.ps1

**This deletes data permanently. There is no recycle bin.**

Menu: `All` (every VM on the host) or `Selected` (multi-select list). Per VM it force
turns the machine off — no graceful shutdown, it is being deleted anyway — removes the
failover cluster role if there is one, removes the VM from Hyper-V, then deletes the
disk files and the VM configuration folder. Empty parent folders are cleaned up too.

Two confirmations are required: a menu confirm, then typing `DELETE` in upper case.

Never touched:

- disks still attached to a VM that is *not* being deleted (shared VHD Sets included)
- pass-through physical disks
- differencing parents living outside the VM's own disk folder (shared gold images)
- the host default VM / VHD folders and any folder another VM still lives in

Parameters for unattended use:

```powershell
.\toolbox\Remove-Vms.ps1 -ListOnly                       # inventory only, deletes nothing
.\toolbox\Remove-Vms.ps1 -VmName srv01,srv02 -Force      # delete named VMs
.\toolbox\Remove-Vms.ps1 -All -Force                     # delete every VM
.\toolbox\Remove-Vms.ps1 -All -Force -KeepDisks          # unregister only, files stay
```

`-Force` is mandatory in parameter mode; without it the script prints what it would
delete and exits with code 1.

## Repair-VmPlacement.ps1

`Build-Vms.ps1` puts every VM in two folders named after it: the configuration (and
checkpoints) in `<VM path>\<name>\`, every disk in `<VHD path>\<name>\`, with the host's
Hyper-V defaults as the paths. This finds every VM that does not match and moves it into
place with `Move-VMStorage`. By default a running VM is shut down first — a graceful guest
shutdown, never a turn off; a VM that is not off within five minutes is skipped — and
started again once its files are in place, so the disks move cold. `-Live` (or "Move live"
in the menu) keeps it running instead, the same live storage migration Hyper-V Manager's
"Move..." does. Folders left empty behind are removed; host default folders and drive
roots never are.

Menu: `Check` (list every VM and what is out of place) or `Sort` (pick the misplaced VMs,
confirm, move). A VM renamed to its FQDN keeps the short folder name it was built with.

Left alone, and reported why: clustered VMs, VMs with checkpoints, shared disks (VHD Sets
and any disk attached to more than one VM), pass-through disks, and differencing parents —
only the VM's own child disk moves.

```powershell
.\toolbox\Repair-VmPlacement.ps1 -ListOnly                    # report only, moves nothing
.\toolbox\Repair-VmPlacement.ps1 -VmName files-01 -Force      # sort named VMs (shut down, move, start)
.\toolbox\Repair-VmPlacement.ps1 -VmName files-01 -Force -Live   # move while it keeps running
.\toolbox\Repair-VmPlacement.ps1 -All -Force                  # sort every misplaced VM
.\toolbox\Repair-VmPlacement.ps1 -VmPath E:\VMs -VhdPath F:\VHDs -ListOnly   # other roots
```

`-Force` is mandatory in parameter mode; without it the script prints the plan and exits
with code 1.

See the [project README](../README.md) for the full documentation of the other scripts.
