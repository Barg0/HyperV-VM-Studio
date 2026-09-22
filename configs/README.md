# configs

Drop any number of exported `config.json` files here, under whatever names you like:
`lab-dc.json`, `rds-farm.json`, `linux-only.json`. `Build-Vms.ps1` scans this folder at
startup and lets you pick which one to build from.

The `config.json` sitting next to `Build-Vms.ps1` still works exactly as before and
appears in the same list, so nothing you already do stops working.

## What counts as valid

A file is offered if it parses as JSON and carries at least one entry under `servers`.
Anything else is listed too, greyed out with the reason — a config you meant to use and
mistyped is more useful on screen than silently missing.

## Non-interactive runs

`-ConfigPath` always wins. With `-BuildAll` and no `-ConfigPath` the script does not
prompt: it takes `config.json` beside the script if there is one, otherwise the single
config in this folder, and fails with the list if there is more than one to choose from.

## Nothing here is committed

The `.gitignore` in this folder keeps the contents out of git. A config holds local
administrator passwords, the domain join password and the Arc service principal secret
in clear.
