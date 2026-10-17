# Installing — and what the 2026-10-16 log showed

**The previous package was not installable.** The data directory was added:

```
[21:28:02.842 I] Adding data directory .../- Dubious Works/AnimRefresh_v6_tranche3
```

…but it contained no `.omwscripts` file, so nothing in it was ever registered. 1,297 content
files loaded that session and none were from it. Neither `AnimRefresh_v6.lua` nor
`SentinelProbe.lua` ran, which is why the log has no `[SentinelProbe]` line. A data directory
only puts files in the VFS; a `PLAYER:` entry in a loaded `.omwscripts` is what runs them.

This package adds the two files that were missing, and moves the probe under
`scripts/AnimRefresh/` so both scripts sit in one place.

## Steps

**The layout changed in tranche 4.** The data directory is now the inner
`AnimRefresh_v6_tranche3/` folder, so that `dev/` (tests and editor annotations) and `docs/`
stay out of installed game data — item 15's gate. Your existing `data=` line already points
at a folder of that name, so the fix is to make sure it points at the one *inside* this
package:

```
data="C:/Users/dubio/.../- Dubious Works/AnimRefresh_v6/AnimRefresh_v6_tranche3"
```

Nothing else about the install changes, and the two `content=` lines below are unchanged.

Add the content lines. **Order matters — put them at the END of the `content=` list**, after
`Bardcraft.omwscripts` (see below):

```
content=AnimRefresh_v6.omwscripts
content=SentinelProbe.omwscripts
```

Or tick both in the launcher's Content Files tab, making sure they sit below Bardcraft.

Confirm it took effect — the log should show, on the next run:

```
Loading content file AnimRefresh_v6.omwscripts
... PLAYER : scripts/animrefresh/animrefresh_v6.lua
[SentinelProbe] using sentinel group '...'
```

If `[SentinelProbe]` says **none of the candidate groups exist**, edit `CANDIDATES` at the top
of `scripts/AnimRefresh/SentinelProbe.lua` to a group your animation set does provide. The
probe reports what it tried.

Run it for a session: go first person and back, sleep, train, travel, change cell, load a save.
Then `grep SentinelProbe openmw.log` and send it over. Disable
`SentinelProbe.omwscripts` afterwards — it is a diagnostic, not a mod.

## Read this before enabling v6: you already run two AnimRefresh providers

`Bardcraft_AnimRefresh/00 Core/Bardcraft` ships **both** v4 and v5, and both load:

```
#683 PLAYER : scripts/animrefresh/animrefresh_v4.lua
#883 PLAYER : scripts/animrefresh/animrefresh_v5.lua
#889 PLAYER : scripts/animrefresh/animrefresh_v5.lua
#894 PLAYER : scripts/animrefresh/animrefresh_v5.lua
```

- v4 loads first and publishes version 4. v5 then publishes over it — but **v4's `onUpdate`
  and timers keep running**. That is G12, live, today. Two polls, one publisher.
- v5 is registered three times because three mods each ship a copy. That part is harmless:
  its own version guard makes the 2nd and 3rd stand down without registering handlers.
- Adding v6 makes it publish over v5 (6 > 5) and makes **three** polls. Correct behaviour
  from every subscriber's point of view, but wasteful, and item 13 (`onInterfaceOverride`) is
  what finally retires the older ones.

Loading v6 **after** Bardcraft is what makes the version guard resolve in the right
direction. Loading it before means v6 publishes, then v5 sees 6 ≥ 5 and stands down — which
also works — but v4 still publishes version 4 over nothing and the ordering gets confusing.
After is simpler.

## A real defect in the v4 you are running

Three times per session, once per load:

```
[21:28:39.813 E] Not supported handler 'UiModeChanged' in L@0x1[scripts/animrefresh/animrefresh_v4.lua]
```

v4 registers `UiModeChanged` under `engineHandlers`. It is an **event**, not an engine
handler, so OpenMW rejects the registration outright and **v4's menu detection has never run
at all** in this install. Independent confirmation that v6's placement under `eventHandlers`
is the correct one — and worth reporting upstream to Bardcraft.

Combined with G1, that means menu-triggered rebuilds in this install are currently covered
only by v5, and only for Rest and Jail — Travel and Training close through Dialogue and are
missed by all of v4 and v5. v6 is the first build that catches them.
