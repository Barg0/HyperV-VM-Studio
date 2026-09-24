# media\ — what the golds are built from

Everything a gold is made from lives here: the Windows and Features on Demand ISOs you
bring, and the Linux cloud images `New-Vhdx.ps1` downloads for itself. What gets built
goes to `vhdx\`.

`.gitignore` in this folder keeps the contents out of git. Only the placeholder notes are
tracked, so a multi-GB ISO or a several-hundred-MB cloud image can never be committed by
accident.

## Your ISOs

Optional, but handy. Nothing enforces it — both scripts browse the whole machine — but
when this folder holds an ISO, their ISO pickers open here instead of at the drive list.

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

Subfolders are fine — the ISO browser navigates into them, and only lists `.iso` files,
so the cloud images below never show up in it.

## Linux cloud images

`New-Vhdx.ps1` downloads these on its own and keeps them here as a cache. Nothing in this
part is edited by hand.

| File | Where it comes from |
|------|---------------------|
| `ubuntu-24.04-server-cloudimg-amd64.img` | cloud-images.ubuntu.com, qcow2 |
| `ubuntu-26.04-server-cloudimg-amd64.img` | cloud-images.ubuntu.com, qcow2 |
| `debian-12-genericcloud-amd64.qcow2` | cloud.debian.org, qcow2 |
| `debian-13-genericcloud-amd64.qcow2` | cloud.debian.org, qcow2 |
| `Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2` | download.fedoraproject.org, qcow2 |
| `Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2` | download.fedoraproject.org, qcow2 |
| `Rocky-9-GenericCloud-Base.latest.x86_64.qcow2` | dl.rockylinux.org, qcow2 |
| `Rocky-10-GenericCloud-Base.latest.x86_64.qcow2` | dl.rockylinux.org, qcow2 |
| `Arch-Linux-x86_64-cloudimg.qcow2` | geo.mirror.pkgbuild.com, qcow2 |

A `.part` file is a download that did not finish. The builder writes to `<name>.part`
and renames only once the stream has closed cleanly, so a truncated file can never be
mistaken for a complete one — and it deletes the `.part` on its way out of a failure.

### Re-use and re-download

A cached image is re-used when its checksum still matches the one the distribution
publishes beside it; otherwise it is fetched again. Deleting a file here costs nothing
but the download.

Two listing formats are read, because the distributions do not agree on one. Ubuntu
and Debian publish coreutils format — `<hash>  <name>`, one line per file. Fedora and
Rocky publish BSD format — `SHA256 (<name>) = <hash>` — and Fedora wraps the whole
listing in a PGP clearsigned document, whose armour lines match neither pattern and
are simply skipped.

**What the checksum proves**: the image and its checksum listing arrived over the same
TLS connection from the same mirror. That catches a corrupted or truncated download.
It is **not** a signature check — not Ubuntu's signed `SHA256SUMS`, not Fedora's signed
`CHECKSUM`, not Rocky's detached `.asc` — because there is no gpg on a stock Windows
host. Do not read a passing checksum as "the mirror is trustworthy".

## Suggested layout

```text
media\
  Windows_Server_2025.iso
  Windows_Server_2022.iso
  Windows_11_24H2.iso
  fod\
    Windows_Server_2025_LanguagesAndOptionalFeatures.iso
    Windows_11_LanguagesAndOptionalFeatures.iso
  ubuntu-26.04-server-cloudimg-amd64.img      (downloaded)
  debian-13-genericcloud-amd64.qcow2          (downloaded)
```
