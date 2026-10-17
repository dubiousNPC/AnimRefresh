# AnimRefresh v6 — complete, tranches 1 to 4

All sixteen fix-list items are now resolved: **fifteen implemented, one dropped with
reasons.** 866 lines against v5's 219. No `pcall` anywhere in the service.

The first two callback arguments are unchanged, so a two-argument consumer written against
v5 keeps working untouched.

```
AnimRefresh_v6_tranche3/          <- THE DATA DIRECTORY. Game data only.
  AnimRefresh_v6.omwscripts
  SentinelProbe.omwscripts
  scripts/AnimRefresh/AnimRefresh_v6.lua
  scripts/AnimRefresh/SentinelProbe.lua

dev/                              <- NOT game data. Do not add as a data directory.
  tests/      tranche1..4, nonx, the three earlier builds, runlua.py, luacheck54.py
  annotations/AnimRefresh.lua     editor-only LuaLS definitions (item 15)

docs/animrefresh.md               consumer and author documentation (item 16)
```

`dev/` is outside the data directory on purpose: item 15's gate asks that editor annotation
libraries stay out of installed game data, and the tests have no business being shipped into
the VFS either. If you previously installed with the data path pointing at the package root,
**point it at `AnimRefresh_v6_tranche3/` instead.**

```
cd dev/tests
S=../../AnimRefresh_v6_tranche3/scripts/AnimRefresh/AnimRefresh_v6.lua
python3 -I runlua.py tranche1.lua $S
python3 -I runlua.py tranche2.lua $S
python3 -I runlua.py tranche3.lua $S
python3 -I runlua.py tranche4.lua $S
python3 -I runlua.py tranche1.lua AnimRefresh_v5.lua     # the baseline, for comparison
```

Needs only `liblua5.4`. No LuaJIT, no OpenMW. Each harness **refuses to run without a
service argument** — a default silently tests the wrong file and reports a pass for it,
which happened once.

## Results

| | t1 def | t1 beh | t2 def | t2 beh | t3 def | t3 beh | t4 beh |
|---|---|---|---|---|---|---|---|
| v5 (219 lines) | 8 | 8/14 | 3 | 5/11 | 3 | 6/20 | 2/14 |
| tranche 1 (381) | 2 | 14/14 | 3 | 5/11 | 3 | 6/20 | 2/14 |
| tranche 2 (486) | 0 | 14/14 | 0 | 9/11 | 3 | 6/20 | 2/14 |
| tranche 3 (699) | 0 | 14/14 | 0 | 11/11 | 0 | 20/20 | 2/14 |
| **tranche 4 (866)** | **0** | **14/14** | **0** | **11/11** | **0** | **20/20** | **14/14** |

Each row scores like the one above it on every *earlier* harness and only improves on the
new one. That is the evidence each tranche changed what it claimed to and nothing else.

## What tranche 4 added

**Item 10 — verification, with a measured delay.** The gate rejects a universal safety bound
and asks for a delay "chosen from recorded engine tests". Four in-game SentinelProbe
sessions recorded 64 player rebuilds, each detected directly as a cleared animation state
rather than inferred. The 60 inter-rebuild gaps are bimodal:

| population | n | min | median | p90 | max |
|---|---|---|---|---|---|
| rapid follow-on (≤ 2 s) | 20 | 0.20 | 0.84 | **1.78** | 1.95 |
| independent (> 2 s) | 40 | 2.14 | 11.48 | — | 119.67 |

Only the first is reachable by a verification; the second is independent user activity
spread over tens of seconds, which no bounded delay covers. **1.8 s** covers 95% of the
rapid population and 2.0 s all of it, against 55% for v5's 1.0 s. Subscribers can also pass
their own `verifyDelay`, and each verifier now gets its own timer at its own delay rather
than sharing one — which also stops one subscriber's delay holding up another's check.

On the gate's "a late verification never restarts an expired one-shot": the service cannot
know an action expired, so the two mechanisms are `unsubscribe` (V4 confirms a verification
never arrives afterwards) and checking `meta.reason == 'verify'`. Under v5 the second was
impossible, which is why item 9's metadata is what makes item 10's lifetime rule
satisfiable at all.

**Item 13 — handover.** Two engine facts shaped this, both **Contract**:

- Publication is by **load order, not version**: `addInterface` publishes only when no later
  script publishes the same name (`scriptscontainer.cpp:283`), so the highest script id
  wins. The version guard is a courtesy on top of that.
- `onInterfaceOverride` is called on *this* script with the interface it displaces
  (`:265`), which is the gate's "recipient passed directly because publication has not
  happened yet". It is an accepted handler, extracted at `:153` before the unsupported-name
  check at `:157` — which is exactly where v4's `UiModeChanged` falls through and is
  rejected outright.

What is achievable depends on the displaced provider, and the gate says so. Against one
offering `retire()` there is a real handover: registrations move once, scheduling stops, and
cached references forward. Against v5 there is only per-key de-duplication, because v5
cannot enumerate its registrations and has nothing to stop its poll — **that residue is G12
and is not fixed.** It is logged when it happens, naming G12.

`retire()` is idempotent, refuses a successor without a `subscribe()` rather than leaving
consumers providerless, and never serializes a callback. Interfaces are never compared or
type-checked, since the gate states raw table/proxy equality is invalid — H6 passes a
userdata-like proxy whose `__eq`, `__len` and `__pairs` all raise.

**Item 15 — annotations.** `dev/annotations/AnimRefresh.lua`, a `---@meta` file typing the
whole published surface including `meta` and the options table, plus an
`---@class openmw.interfaces` field so `I.AnimRefresh` resolves. Add the folder to
`workspace.library` by **merging** the entry, not replacing your `.luarc.json`; the gate asks
that its existing protections be preserved. Nothing depends on Cod3x's library.

**Item 16 — documentation.** `docs/animrefresh.md`, with the evidence labels kept
(Contract / Measured / Derived) and a closing section that names and refutes the four retired
claims rather than leaving them to be rediscovered. It leads with the finding that matters
most to consumers, which is not about this service at all — see below.

**Item 14 — dropped.** Its own gate concedes per-frame polling fixes none of G2, G4 or G19,
and at 60–144 FPS it is 120–288 engine calls a second for a service whose job is to notice
something rare.

## The finding a consumer should read first, which is not about this service

**Measured, four probe sessions.** Two sentinel animations ran side by side, identical except
for priority. The collision-proof one fell ~60 times in 35 minutes and every single fall was
a genuine rebuild. The consumer-shaped one — uniform `Priority_Scripted`, which is what
`playBlended` produces from a bare enum — fell roughly **once every 6 to 10 seconds of
ordinary play**, with no rebuild involved.

`Animation::play` erases every state whose `AnimPriority` is *equal* to the incoming one
(`animation.cpp:905-911`, comparing all four bone groups), and the engine only ever mixes
`LowerBody` and `LeftArm`. So a consumer holding an ongoing pose should give it a priority
whose **`RightArm` entry differs from its other three** — no engine priority does that — and
pick a distinct combination per mod. Four lines, and it fixes a failure mode no notification
service can reach. `docs/animrefresh.md` §1 has the code.

## Deviations from the gates, declared

Four are deliberate disagreements rather than oversights:

- **Item 8** asks to *preserve* a malformed foreign provider version; this overwrites it,
  loudly. A version that cannot be shown newer leaves consumers on a service of unknown
  contract; the operative word in the gate is "silently".
- **Item 3** asks for the latest valid mode at dispatch; boundaries do not re-stamp, because
  once identity is right, current work already carries the current mode and obsolete work
  should not be delivered at all. Joins and reconciles *do* resolve at dispatch. P7 is why
  re-stamping would have been actively harmful. `meta.observedMode` carries the originally
  observed mode either way, which is what the gate actually asks for.
- **Item 9's** reason vocabulary differs: `reconcile` collapses join and load because item
  11's coalescing requires one episode per need (`origin` separates them), and `retry` is
  `attempt > 0` rather than a reason of its own.
- **Item 2's** quarantine is deferred to the next dispatch, because engine-level isolation
  gives Lua no failure signal at all. Replacement registrations created during a failing
  call are protected, as the gate requires.

And two exceed their gates: **item 5** no longer leaves G16 as an integration limit, and
**item 6** is answered by measurement rather than implemented — see below.

## Findings to send back with this

- **P7**: the cause discriminator `mode ~= previousMode` was already unreliable in v5, not
  merely at risk from v6. A join could beat the first poll after a non-crossing change and
  arrive wearing a boundary's clothes. This changes item 16's migration note: consumers
  relying on it were getting false positives, not safety.
- **Item 6 should be dropped, on evidence.** `animation.hasBone` resolves through
  `anim->getNode()` against the live scene graph (`animationbindings.cpp:238-241`) and
  tracked the attached rig exactly across 41 swaps. A sentinel animation detects *any*
  rebuild, including the equipment and weapon-stance rebuilds that camera-mode inference
  cannot see at all. Two accessors replace the vampire-magnitude watcher, werewolf
  precedence, dead-vampire retention and owned prior-type state.
- **Item 5 has no measured basis.** Across 10+ menu closes, no rebuilding menu ever cleared a
  collision-proof animation state, and a consumer-shaped state was swept *less* often inside
  a menu (1 / 10.0 s) than outside it (1 / 6.2 s). The latch is kept as cheap insurance, and
  because Jail and ChargenRace were never exercised, but it should not be cited as fixing a
  demonstrated defect.
- **G16 is narrower than stated**: `receiveEvent` walks handlers in reverse registration
  order and breaks only on an explicit `return false`; a throwing handler does not break the
  chain, since each is individually wrapped.
- **`util.makeReadOnly` returns userdata**, so `I.UI.modes` bites item 5 exactly the way the
  interface bites item 8's provider guard. The item 5 citation `ui.lua:200-207` should be
  `:135`, where the event is sent, with `oldMode` assigned at `:136` *after* the send — which
  is what makes "either field" sound.
- **`luaL_loadfile` → `luaL_loadfilex`** in `run_tests.py`: in Lua 5.4 the former is a macro
  exporting no symbol, so the suite aborts against a stock `liblua5.4`. One identifier.
- **A live defect in the v4 that ships with Bardcraft**: it registers `UiModeChanged` under
  `engineHandlers`, which the engine rejects outright
  (`Not supported handler 'UiModeChanged'`), so v4's menu detection has never run at all.

## Still open

- No in-game acceptance run for v6 itself. Everything measured here is an offline harness
  result or a SentinelProbe observation, not a consumer acceptance pass.
- Jail and ChargenRace are latched but unexercised.
- The reconcile retry chain that replaced v5's unexplained 0.60 s load delivery is
  unconfirmed against a consumer that needed it.
- `docs/animrefresh.md` §13 keeps this list beside the contract it belongs to.
