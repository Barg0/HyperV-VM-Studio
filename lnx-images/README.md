# lnx-images\ — the cloud image cache

`New-Vhdx.ps1` downloads Linux cloud images into this folder and converts them into
golds in `vhdx\`. Nothing here is edited by hand, and nothing here is tracked: the
`.gitignore` beside this file keeps the contents out of git, exactly as `isos\` does
for Windows media, so a several-hundred-MB image can never be committed by accident.

## What lands here

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

## Re-use and re-download

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
