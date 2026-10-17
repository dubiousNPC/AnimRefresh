---@meta AnimRefresh
--
-- EDITOR-ONLY TYPE DEFINITIONS FOR ANIMREFRESH v6. NOT GAME DATA.
--
-- This file must never sit inside an OpenMW data directory. It declares types and defines
-- no behaviour, so loading it in game would be harmless but pointless; keeping it out is
-- what item 15's gate asks for, and it is why this lives beside the mod folder rather than
-- inside it.
--
-- To use it, add this folder to your LuaLS workspace library WITHOUT replacing your
-- existing .luarc.json — merge the entry, since item 15 also asks that the protections
-- already in that file be preserved:
--
--     { "workspace.library": [ "...existing entries...", "dev/annotations" ] }
--
-- Nothing here depends on Cod3x's annotation library, and nothing here should be copied
-- into one: it describes only AnimRefresh's own published surface.

---Metadata passed as the third callback argument (v6 fix list item 9).
---
---A fresh table per delivery, immutable by contract: two subscribers in one episode are
---never handed the same object, so neither can affect the other by writing to it. Not
---enforced — do not mutate it.
---@class AnimRefreshMeta
---Why this delivery happened. `reconcile` covers both a join and a load, because item 11
---coalesces them into one episode; `origin` separates them. A retry is not a reason —
---it is `attempt > 0`.
---@field reason 'boundary'|'menu'|'manual'|'verify'|'reconcile'
---Monotonic id of this episode.
---@field episode integer
---Id of the cause this episode belongs to. A verification shares its boundary's `cause`
---while having its own `episode`.
---@field cause integer
---0 on the first delivery of an episode to this subscriber, 1.. on each retry.
---@field attempt integer
---What observed or requested the cause. `poll` is the camera poll (and the menu-latch
---backstop), `uiMode` the UiModeChanged event, `api` a refreshNow call, `subscribe` a
---join, `load` a save load, `init` this script being added to an existing save.
---@field origin 'poll'|'uiMode'|'api'|'verify'|'subscribe'|'load'|'init'
---For `menu`, the latched mode(s), e.g. `"Training"` or `"Rest+Travel"`. For `manual`,
---whatever the caller passed to refreshNow. Otherwise nil.
---@field detail string|nil
---The camera mode read when the cause was RAISED, as against the `mode` argument, which
---for a reconcile is resolved at dispatch. They differ only for a reconcile.
---@field observedMode string
---@field observedPrevious string
---The provider version that produced this delivery.
---@field version integer

---Options for `subscribe`.
---@class AnimRefreshOptions
---Ask for one follow-up delivery after each boundary, as a safety net for ongoing desired
---state. Must be a boolean or nil.
---@field verify boolean|nil
---Seconds to wait before that follow-up. Must be above zero. Defaults to the service's own
---measured value; supply your own when you know your action's lifetime.
---@field verifyDelay number|nil

---The published AnimRefresh interface.
---@class AnimRefreshInterface
---@field version integer
local AnimRefresh = {}

---Register `callback` under `key`, replacing any existing registration for that key.
---
---The callback may return `false` to say "not ready, try again"; the service then retries
---on a bounded schedule and gives up with a log line. Any other return value, including
---nil, means done.
---
---Raises on a malformed key, callback or options, and leaves the registry untouched when
---it does.
---@param key string A non-empty identifier owned by your mod.
---@param callback fun(mode: string, previousMode: string, meta: AnimRefreshMeta): boolean|nil
---@param opts AnimRefreshOptions|nil
function AnimRefresh.subscribe(key, callback, opts) end

---Remove the registration for `key`, if any. Safe to call when nothing is registered.
---@param key string
function AnimRefresh.unsubscribe(key) end

---Ask for a reconciliation the service could not have observed itself — after your own
---code replaced part of the model, for instance.
---@param detail string|nil A short reason, surfaced to subscribers as `meta.detail`.
function AnimRefresh.refreshNow(detail) end

---The player's current camera mode, read live from `openmw.camera`.
---@return string
function AnimRefresh.getMode() end

---Whether the camera is in first person right now. This reports the camera mode and says
---nothing about which skeleton is currently attached.
---@return boolean
function AnimRefresh.isFirstPerson() end

---Hand this provider's registrations to a newer one and stop all of this provider's work
---(v6 fix list item 13). Called by a successor from its own `onInterfaceOverride`; not
---something a consumer calls. Idempotent: a second call does nothing.
---@param successor AnimRefreshInterface
function AnimRefresh.retire(successor) end

---@class openmw.interfaces
---@field AnimRefresh AnimRefreshInterface

return AnimRefresh
