# AnimRefresh v6 — consumer and author documentation

Item 16 of the v6 fix list. This replaces the v5-era notes wholesale; four claims that
appeared in them are wrong and are corrected explicitly in **Claims retired** at the end.

Evidence labels are kept throughout, in the audit's sense:

- **Contract** — read from OpenMW source at pin `f4bec41444214a7903bebd178389ca22ca13f646`,
  with file and line.
- **Measured** — observed by running something: an offline harness, or the in-game
  SentinelProbe sessions of 2026-10-16.
- **Derived** — reasoned from the two above. Sound, but not itself observed.

---

## 1. What this service is for

AnimRefresh tells a subscriber that the player's animation object may have been replaced,
so the subscriber can re-apply whatever it owns — a pose, a VFX, a blended idle.

**It is a notification service and nothing more.** It does not hold your state, does not
re-apply anything for you, and cannot tell you that a rebuild definitely happened — only
that one was observed or inferred. The service owns transient registrations and delivery
episodes; **you own your desired state and your action's lifetime.**

### What it does not cover, and this matters more than the rest of this document

**Measured.** A consumer's animation state is erased roughly **once every 6 to 10 seconds of
ordinary play**, with no rebuild involved. Four probe sessions ran two sentinel animations
side by side, identical except for priority:

| | priority | losses | cause of every loss |
|---|---|---|---|
| A | `{Default, Default, Default, Scripted}` | ~60 over 35 min | a genuine rebuild, every one |
| B | uniform `Priority_Scripted` | ~30 in 5 min | mostly ordinary priority contention |

**Contract.** `Animation::play` erases every other state whose `AnimPriority` is **equal**
to the incoming one (`mwrender/animation.cpp:905-911`), and `operator==` compares all four
bone-group entries (`mwrender/animationpriority.hpp:19-25`). The engine itself only ever
builds a *mixed* priority on `LowerBody` and `LeftArm` (`mwmechanics/character.cpp:274`,
`:454-455`, `:1356`) — everything else uses the uniform `AnimPriority(int)` constructor.

**Derived, and the practical consequence:** no notification service can fix this, because
the loss is not tied to any event the service can observe. If you hold an ongoing pose,
**give it a priority whose `RightArm` entry differs from its other three**, which no engine
priority does:

```lua
animation.playBlended(self, group, {
    priority = {
        [animation.BONE_GROUP.LowerBody] = animation.PRIORITY.Default,
        [animation.BONE_GROUP.Torso]     = animation.PRIORITY.Default,
        [animation.BONE_GROUP.LeftArm]   = animation.PRIORITY.Default,
        [animation.BONE_GROUP.RightArm]  = animation.PRIORITY.Scripted,
    },
    autoDisable = false,
})
```

**Contract.** A table is required: `getPriorityArgument` fills unnamed groups with
`Priority_Default` and overrides the named ones (`mwlua/animationbindings.cpp:60-71`),
whereas a bare enum is uniform across all four and therefore sweepable. Choose a *distinct*
combination per mod, or two consumers will sweep each other.

---

## 2. The surface

```lua
local I = require('openmw.interfaces')

I.AnimRefresh.subscribe(key, callback, opts)   -- opts: { verify = bool, verifyDelay = n }
I.AnimRefresh.unsubscribe(key)
I.AnimRefresh.refreshNow(detail)               -- detail is an optional string
I.AnimRefresh.getMode()                        -- live camera mode
I.AnimRefresh.isFirstPerson()                  -- live; see §7
I.AnimRefresh.version                          -- 6
I.AnimRefresh.retire(successor)                -- providers only; see §9
```

`callback(mode, previousMode, meta)`. The first two arguments are unchanged from v5, so a
two-argument consumer written against v5 keeps working untouched — `meta` is additive and
ignorable. Return `false` to mean "not ready, retry"; anything else, including nil, means
done.

A malformed `key`, `callback` or `opts` raises, and leaves the registry byte-for-byte as it
was. `verify` must be a boolean or nil; `nil` and `false` both mean "no options", for v5
compatibility.

---

## 3. Episodes, and why your callback may be called more than once

Every cause gets an **episode**: an identity carrying its reason, the mode observed when it
was raised, and a snapshot of recipients as `key → token`. Every `subscribe()` mints a fresh
token.

Deferred work carries its episode and is dropped if a newer cause has happened since, or if
the key's token has changed. So:

- a reused key never receives a callback meant for its previous owner;
- an unsubscribed registration cannot be called again by work already in flight;
- a stale retry is **discarded**, not re-stamped with a fresh mode and delivered.

`meta.episode` and `meta.cause` make this visible. A verification shares its boundary's
`cause` and has its own `episode`.

### Causes

| `meta.reason` | `meta.origin` | raised when |
|---|---|---|
| `boundary` | `poll` | the camera crossed into or out of first person |
| `menu` | `uiMode` or `poll` | a latched rebuilding menu closed; `detail` names it |
| `reconcile` | `subscribe`, `load`, `init` | you joined, or a save loaded, or this script was added |
| `manual` | `api` | someone called `refreshNow()`; `detail` is theirs |
| `verify` | `verify` | the opt-in follow-up to a boundary |

`reconcile` deliberately covers both a join and a load, because item 11 coalesces them into
one episode for one restoration need; `origin` separates them if you care.

### Telling a real boundary from everything else

`mode ~= previousMode` is now a dependable discriminator, and **it was not in v5**. A
reconcile reports no transition, so v6 makes its `previousMode` equal its `mode` by
construction. **Measured:** in v5, `processTimers` running before `onUpdate` let a join beat
the first poll after a non-crossing change (`ThirdPerson → Preview`, which rebuilds
nothing), delivering `(Preview, ThirdPerson)` — a join wearing a boundary's clothes. If you
relied on that test under v5 you were getting false positives, not safety. Prefer
`meta.reason` now that it exists.

---

## 4. Timing, and the frame it lands in

**Contract**, traced in `engine.cpp::frame()`:

| line | phase |
|---|---|
| 203 | input |
| 230 | `synchronizedUpdate()` — onFrame, queued actions |
| **302** | **`mWorld->update()` — the camera rebuild lands here** |
| 352 | `allowUpdate()` → `LuaManager::update()` |

and inside `LuaManager::update()` (`luamanagerimp.cpp:214`): `processTimers` → event
handlers → queued callbacks → engine handlers → `onUpdate`.

Because `processTimers` runs **before** `onUpdate` in the same pass, a zero-delay timer
created in `onUpdate` cannot fire in that pass. It fires in the next frame's
`processTimers`, which is after that frame's line 302 — after the rebuild the boundary was
inferred from. **That is the whole reason delivery is deferred by one frame**, and it is why
your repair is not undone by the rebuild that prompted it.

One asymmetry, **Contract**: `updateTimerQueue` is a `while` loop over a heap, so a timer
created *inside* a timer callback with a deadline already past is popped in the same pass.
Deferral buys a phase guarantee only when the episode is raised from an engine handler or
event, which is where every boundary is raised.

**Do not assume a mode setter has settled.** `Camera::setMode` (`camera.cpp:217`) assigns
`mMode` immediately and defers the rebuild through `mProcessViewChange`, consumed at
`camera.cpp:137`. So between a successful setter and the rebuild, `getMode()` already
reports the new mode.

---

## 5. Pause

**Contract.** `LuaManager::update` calls `processTimers` only when unpaused, and reaches
`onUpdate` as `asLocal(ptr)->update(isPaused ? 0 : frameDuration)`. So while paused:

- no timer fires, and none are lost — deadlines are in simulation time, which does not
  advance;
- `onUpdate` is still called, with `dt == 0`, so the poll does not advance either;
- event and engine handlers still run.

**Measured** (tranche2 P8/P9): a delivery pending when the game pauses arrives after
unpausing, and a camera crossing made during a pause is reported once play resumes. Nothing
is dropped and nothing is duplicated. Note this is the engine's guarantee, which a
timer-based design inherits — v5 behaves the same way here.

---

## 6. Retries are bounded, and so is verification

If your callback returns `false`, the episode retries on a fixed schedule and then **gives
up with a log line naming your key**. It does not retry forever.

| cause | retry delays after the first attempt |
|---|---|
| boundary, menu, manual, verify | 0.10, 0.10 |
| reconcile (join / load / init) | 0.10, 0.20, 0.40 |

The longer reconcile chain replaces v5's second load delivery at 0.60 s, so the covered
window is wider than v5's while the notice count drops from three to one. **That 0.60 value
is explained nowhere in v5 or the audit**; the chain is a deliberate reconstruction of what
it was for, and is worth confirming against a consumer that needed it.

### The verification delay, and why it is 1.8 s

Opt in with `verify = true`. You get one extra delivery after each boundary, with
`meta.reason == 'verify'`.

**Measured.** Four probe sessions recorded 64 player rebuilds; the 60 gaps between
consecutive rebuilds are bimodal:

| population | n | min | median | p90 | max |
|---|---|---|---|---|---|
| rapid follow-on (≤ 2 s) | 20 | 0.20 | 0.84 | **1.78** | 1.95 |
| independent (> 2 s) | 40 | 2.14 | 11.48 | — | 119.67 |

Only the first population is reachable by a verification. The second is independent
user-driven activity — opening inventory, changing stance — spread over tens of seconds,
which no bounded delay covers and none should try to. Sizing against the rapid population:
**1.8 s covers 95% of it, 2.0 s all 20 observations, and v5's 1.0 s covers 55%.** There is
no universal safety bound here and none is claimed.

Pass `verifyDelay` to choose your own when you know your action's lifetime.

### Expired actions, and one-shots

**A late verification must not restart something that has finished, and the service cannot
know that it has.** Two mechanisms are yours to use:

1. `unsubscribe(key)` when your action ends. Work already in flight for that token is then
   dropped — **Measured**, tranche4 V4: a verification never arrives after its subscriber
   left.
2. Check `meta.reason` and ignore `'verify'` if your action is a one-shot. Under v5 this was
   impossible, because a verification was indistinguishable from a boundary — which is why
   item 9's metadata is what makes item 10's lifetime rule satisfiable at all.

Set `verifyDelay` shorter than your action's lifetime, or do not ask for verification.

---

## 7. `isFirstPerson()` reports the camera, not the skeleton

It reads `openmw.camera.getMode()` live. In v5 it returned the poll's cached value, which
was stale indefinitely with no subscribers. It is now live — **and it still does not tell
you which skeleton is attached.**

If you need that, ask the skeleton directly. **Contract:** `animation.hasBone` resolves
through `anim->getNode()` against the live scene graph
(`mwlua/animationbindings.cpp:238-241`), so it is an exact read of the rig that exists right
now, with no inference:

```lua
local firstPersonRig = animation.hasBone(self, 'Bip01 L Finger4')
```

**Measured:** across 41 rig swaps in one session, that test tracked the attached rig
exactly, matching the per-skeleton bone sets recorded in the phantom-bones work — extended
fingers present on the `.1st` rigs and absent on the third-person ones. Pick a witness bone
that differs between *your* install's rigs; it will not distinguish vampirism, which swaps
body parts rather than the skeleton.

`camera.MODE` has five members: `Static`, `FirstPerson`, `ThirdPerson`, `Vanity`, `Preview`.
**Vanity** appears in neither v5 nor the audit's lists. Only `FirstPerson` is treated as
first person; every other mode, Vanity included, is not.

---

## 8. Menus

Rest, Travel, Training, Jail and ChargenRace are **latched** when seen in either field of
`UiModeChanged`, and the latch is consumed when the mode stack empties.

**Contract**, and why v5 could not do this: `GM_Travel` and `GM_Training` are pushed from
inside the dialogue window (`mwgui/dialogue.cpp:453`, `:462`), so the stack is
`{Dialogue, Travel}` and closing the window pops to `Dialogue` — the event carries
`newMode == "Dialogue"`, never nil. Rest (`mwinput/actionmanager.cpp:226`) and Jail
(`mwgui/windowmanagerimp.cpp:1545`) are pushed over nothing, which is exactly why only those
two worked in v5. Reading both fields is well founded because `ui.lua`'s `oldMode` is
assigned *after* the event is sent (`ui.lua:135-136`), so it holds the mode just popped.

The latch is also fed from the existing poll via `I.UI.modes`, which makes it independent of
the event arriving at all. **Contract:** `receiveEvent` walks handlers in reverse
registration order and breaks only on an explicit `return false`
(`scriptscontainer.cpp:368-373`); a handler that merely throws does not break the chain,
since each is individually wrapped. So the exposure is a *later-loaded* handler returning
false, and the backstop removes it. Which path observes gameplay first is undetermined, so
`meta.origin` records which one did and is **not** a suppression indicator.

**Honest status, Measured.** Across four probe sessions and 10+ menu closes, no rebuilding
menu ever cleared a collision-proof animation state, and a consumer-shaped state was swept
*less* often inside a menu (1 / 10.0 s) than outside it (1 / 6.2 s). **On this evidence the
menu latch guards something that does not happen.** It is kept because it is cheap — one
userdata index per poll — and because Jail and ChargenRace were never exercised. Treat it as
insurance, not as a fix for a demonstrated defect.

`I.UI.modes` is **userdata**, not a table: `util.makeReadOnly` returns zero-size userdata
carrying `__index`, `__len` and `__pairs` (`luastate.cpp:312-336`). Index it; do not
type-check it as a table, and do not rely on `#` or `pairs`, since `__ipairs` was removed in
Lua 5.3.

---

## 9. Versions, load order, and running two providers

**Contract, and the important correction:** publication is decided by **load order, not
version**. `addInterface` assigns `mPublicInterfaces[name]` only when no later script
publishes the same name (`scriptscontainer.cpp:283`), so the highest script id wins. The
version check in this script is a courtesy on top of that.

v6 stands down for a provider reporting version ≥ 6. A provider whose version is not a
number is reported loudly and overwritten: it cannot be shown to be newer, and standing down
would leave consumers on a service of unknown contract. The audit prefers preserving it; this
is a declared disagreement.

**Load only one provider.** If an older one loads after v6, or alongside it, its `onUpdate`
and timers keep running — two polls, two sets of deliveries. v6 does what it can:

- **against a provider offering `retire()`**: a real handover through
  `onInterfaceOverride(previous)`, which **Contract** is called on the new script with the
  interface it displaces (`scriptscontainer.cpp:265`). Registrations move once, the old
  provider's scheduling stops, and cached references to it forward here.
- **against v5**: only per-key de-duplication — as each key subscribes here, it is
  unsubscribed there. v5 cannot enumerate its registrations and has nothing to stop its
  poll, so **that residue is real and is not fixed.** It is logged when it happens.

Callbacks are never serialized across a handover: live functions, one live Lua state.

A future provider displacing v6 should call `previous.retire(ourInterface)` from its own
`onInterfaceOverride`. It is idempotent, and it refuses a successor without a `subscribe()`
rather than leaving consumers with no provider at all.

---

## 10. Assets, VFX ids, and profiling

- **Supported assets.** The service plays nothing and loads nothing. What you can play is
  whatever your install's animation set actually provides — check with
  `animation.hasGroup(self, name)` rather than assuming, since a group's presence depends on
  the installed replacers and differs per rig.
- **Unique VFX ids.** When you re-apply a VFX after a notice, use an id unique to your mod
  and remove yours by that id. There is **no** blanket rule that a known magic id can be
  removed unconditionally — removing an id you do not own will take another mod's effect
  with it.
- **Profiling.** The poll costs two camera reads plus one userdata index per 0.1 s while any
  subscriber exists, and nothing at all when none does. Per-subscriber dispatch costs one
  simulation timer per recipient per episode, on an event that happens a handful of times a
  session. Per-frame polling was considered and rejected: at 60–144 FPS it is 120–288 engine
  calls a second for a service whose job is to notice something rare, and its own gate
  concedes it fixes none of the detection findings.

---

## 11. Failure isolation, and what it costs

A subscriber that raises cannot truncate the fan-out, cancel another subscriber's retries or
stop verification being scheduled. **Contract:** each recipient is dispatched from its own
simulation timer, and `ScriptsContainer::callTimer` wraps every timer callback in its own
`try`/`catch` (`scriptscontainer.cpp:719-743`), so the engine already provides the
per-subscriber boundary. No `pcall` is used anywhere in this service.

**Measured:** v5 notified 2 of 8 healthy subscribers when one threw — and the count varies
per run, because `pairs` order decides who gets cut off. v6 notifies 8 of 8.

The cost is real and bounded. `callTimer` does `mTemporaryCallbacks.erase(id)` *after* the
call and *inside* the `try`, so a throwing callback is retained for the script's lifetime.
Engine-level isolation tells Lua nothing, so v6 detects it from the Lua side — an in-flight
marker still set at the next dispatch means the previous call never returned — and then
removes that registration with a log naming the key. **One leaked entry per broken
subscriber, not one per episode.** Fix your callback and re-subscribe.

If you wrap your own callback in a `pcall`, remove it: it hides the failure from both the
engine log and the quarantine, and the single-layer rule applies.

---

## 12. Claims retired

Four statements from the v5-era notes are wrong and should not be repeated:

1. **"All reissues restart."** They do not. Obsolete deferred work is discarded by episode
   and token identity (§3), and a reconcile is coalesced rather than reissued (§6).
2. **"One shared path means one script."** It does not. The same VFS path can be registered
   by several `.omwscripts` files and loaded several times over; one install was observed
   with the same provider registered three times, plus a different version alongside it.
   Publication is by load order (§9).
3. **"Queued nil means settled."** It does not. `getQueuedMode()` returning nil is not
   settlement evidence, because `setMode` assigns `mMode` before the rebuild (§4). v5 skipped
   sampling entirely while a change was queued, which hid both rebuilds of a
   crossing-and-return.
4. **Unconditional magic-id VFX removal.** Never remove a VFX id you do not own (§10).

---

## 13. Known gaps

- Jail and ChargenRace are latched but were never exercised in game.
- The reconcile retry chain replacing v5's 0.60 s delivery is unconfirmed against a consumer
  that needed it.
- Item 6's type hints are not implemented, and on the evidence in §1 and §7 should not be:
  `animation.hasBone` answers "which rig" exactly, and a sentinel animation answers
  "something rebuilt". Vampirism swaps body parts rather than the skeleton, so `hasBone`
  misses it — but a part swap rebuilds, which the sentinel catches.
- No in-game acceptance run has been recorded for v6 itself. Everything marked **Measured**
  above is either an offline harness result or a SentinelProbe observation, not a consumer
  acceptance pass.
