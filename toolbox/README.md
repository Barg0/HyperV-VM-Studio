# toolbox\ — post-build maintenance

The scripts here are not part of the build pipeline. `New-Vhdx.ps1` and `Build-Vms.ps1`
in the project root get a lab *created*; these keep it healthy afterwards.

| Script | What it does |
|--------|--------------|
| `Migrate-Vms.ps1` | Export Hyper-V VMs to a USB / SATA disk or NAS, reinstall the host, import them back. Handles vTPM certificates and virtual switches |
| `Convert-Vhdx.ps1` | Convert Fixed (thick) VM disks to Dynamic (thin) and compact them, to reclaim host disk space |
| `Remove-Vms.ps1` | Delete VMs and their files — force turn off, leave the failover cluster, remove from Hyper-V, delete VHD/VHDX and configuration folders |

All of them run elevated on the Hyper-V host, all use the same arrow-key console menus as
the build scripts, and all are entirely optional.

```powershell
# From the project root
.\toolbox\Migrate-Vms.ps1
.\toolbox\Convert-Vhdx.ps1
.\toolbox\Remove-Vms.ps1
```

Logs still land in the project-wide `logs\` folder next to `Build-Vms.ps1`
(`logs\migrate-vms\`, `logs\convert-vhdx\`, `logs\remove-vms\`), not in a second folder
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

See the [project README](../README.md) for the full documentation of the other scripts.
