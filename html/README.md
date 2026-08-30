# html\ — Hyper-V VM Studio

<div align="justify">

`hyperv-vm-studio.html` is the browser front end for `Build-Vms.ps1`. Open it in any
modern browser — it is a single self-contained file. No assets folder, no build step,
no network requests.

```powershell
Start-Process .\html\hyperv-vm-studio.html
```

Design the lab in the blades on the left, check the **Review and validate** blade, then
**Download config.json** and put that file next to `Build-Vms.ps1` in the project root.

The studio never touches Hyper-V and never runs anything — it only writes `config.json`.
It also keeps no state between visits: use **Save state** / **Resume state** in the top bar
to carry a design across sessions.

## Contents

| Path | What it is |
|------|------------|
| `hyperv-vm-studio.html` | The whole studio — markup, styling, icons and logic in one file |

Icons are 94 original glyphs generated from a template table in the file itself and tinted
to the active theme, so a copy of this one file is the whole studio. The sample lab lives
inside the HTML too, so there is no separate `config.sample.json`.

</div>
