# isos\ — where to park your Windows media

Optional, but handy: keep every ISO this project consumes in one place next to the scripts.
Nothing enforces it — both scripts browse the whole machine — but if you do use this folder,
their ISO pickers open here instead of at the drive list.

`.gitignore` in this folder keeps the contents out of git. Only the placeholder notes are
tracked, so a multi-GB ISO can never be committed by accident.

## What goes here

| ISO | Used by | Notes |
|-----|---------|-------|
| Windows Server 2016 – 2025 | `New-Vhdx.ps1` | The install medium a gold VHDX is built from |
| Windows 11 | `New-Vhdx.ps1` | Same, for client golds |
| Windows 11 "Languages and Optional Features" | `Build-Vms.ps1` | RSAT capabilities. Must match the client build (24H2 vs 23H2) |
| Windows Server "Languages and Optional Features" | `Build-Vms.ps1` | Server Core App Compatibility. **One per Windows Server release** — a 2022 medium cannot service a 2025 image |

The two Features on Demand ISOs are consumed **directly**: when a VM needs one,
`Build-Vms.ps1` offers to browse for it, mounts it, installs from it, and dismounts it
afterwards. Nothing has to be extracted into a folder first.

Windows Server FoD ISO downloads:
[2025](https://go.microsoft.com/fwlink/?linkid=2273506) ·
[2022](https://go.microsoft.com/fwlink/?linkid=2195333) ·
[2019](https://go.microsoft.com/fwlink/?linkid=2195335)

## Suggested layout

```text
isos\
  Windows_Server_2025.iso
  Windows_Server_2022.iso
  Windows_11_24H2.iso
  fod\
    Windows_Server_2025_LanguagesAndOptionalFeatures.iso
    Windows_11_LanguagesAndOptionalFeatures.iso
```

Subfolders are fine — the ISO browser navigates into them.
