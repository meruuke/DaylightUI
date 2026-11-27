# DaylightUI — Retail port (fork)

This fork keeps upstream DaylightUI (https://github.com/dayightt/DaylightUI) intact on `main`
and carries the Retail port on the `retail` branch.

- `main`: a mirror of upstream `main`. Never commit port work here.
- `retail`: upstream + the Retail changes. Started from upstream v2.2.3.

## What the port changes

- Every `.toc`: `## Interface: 120105, 16001` so the same files load on Retail and on Forever.
- `Core.lua`: `DUI.SafeRegister`, which skips events this client doesn't have
  (for example `UNIT_HAPPINESS` or `COMBO_TARGET_CHANGED` on Retail) instead of reporting an error.
- Unit frames and nameplates: event registration goes through `DUI.SafeRegister`.
- `Book/`: the talent window reads Retail's class, spec and hero trees, choice nodes and builds.

## Taking upstream updates

    git remote add upstream https://github.com/dayightt/DaylightUI.git   # once
    git fetch upstream
    git checkout main && git merge --ff-only upstream/main && git push origin main
    git checkout retail && git merge main
    # fix any conflicts (usually the Interface line of a .toc), test in game, then
    git push origin retail

When upstream adds a new `RegisterEvent`/`RegisterUnitEvent` call through `DUI.SafeCall`,
switch it to `DUI.SafeRegister` if the event might not exist on Retail.
