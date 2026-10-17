---@omw-context player
-- AnimRefresh v6: tells subscribers when the player model is rebuilt
-- (first-person boundary, Rest/Travel/Training/Jail, load). See docs/animrefresh.md.
--   I.AnimRefresh.subscribe(key, fn(mode, previousMode) [-> false to retry], { verify = true })
--   I.AnimRefresh.unsubscribe(key)
--
-- TRANCHES 1 and 2 of the v6 fix list: items 8, 3, 12, 7 then 1, 2, 4, 11.
-- Public surface is unchanged. Callbacks still receive exactly (mode, previousMode);
-- the metadata third argument is item 9 and is not here.
--
-- Still open, by design: item 5 (menu/race latch - Training and exterior Travel close
-- through Dialogue and are missed), item 6 (type hints), item 9 (metadata),
-- item 13 (retiring a superseded provider's handlers).

local camera = require('openmw.camera')
local async  = require('openmw.async')
local I      = require('openmw.interfaces')

local MY_VERSION = 6

-- Item 8 (provider guard). The interface is userdata, not a table, so it must not be
-- type-checked as one - only its `version` field is inspected, and only as a number.
-- A foreign provider with a missing or non-numeric version used to break the comparison
-- outright and take this script's startup with it.
do
    local existing = I.AnimRefresh
    if existing ~= nil then
        local theirVersion = existing.version
        if type(theirVersion) == 'number' then
            if theirVersion >= MY_VERSION then
                return -- a compatible equal or newer provider is already published
            end
        else
            -- Overwriting is still the lesser harm here: a non-numeric version cannot be
            -- shown to be newer, and standing down would leave every consumer on a
            -- service of unknown contract. Loud, never silent.
            print("[AnimRefresh] an existing AnimRefresh provider reports version " ..
                  tostring(theirVersion) .. " (" .. type(theirVersion) ..
                  "), which is not a number; publishing v" .. MY_VERSION ..
                  " over it. The other provider's handlers and timers are NOT retired " ..
                  "(v6 fix list item 13).")
        end
    end
end

local POLL_INTERVAL = 0.1

-- Item 1 (camera phase). Dispatch is deferred with a zero-delay simulation timer created
-- from onUpdate, an event handler or onLoad. Traced in OpenMW f4bec414:
--
--   engine.cpp::frame()      230 synchronizedUpdate (onFrame, queued actions)
--                            302 mWorld->update          <- the camera rebuild lands here
--                            352 LuaWorker allowUpdate -> LuaManager::update()
--   LuaManager::update()     processTimers -> events -> engine handlers -> onUpdate
--
-- processTimers runs *before* onUpdate within the same LuaManager::update(), so a timer
-- created in onUpdate cannot fire in that pass. It fires in the next frame's
-- processTimers, which is after the next frame's line 302 - i.e. after the rebuild that
-- the boundary was inferred from. That is the whole of the G2 fix.
--
-- Note the asymmetry the engine imposes: updateTimerQueue is a `while` loop over a heap,
-- so a timer created *inside* a timer callback with a deadline already past is popped in
-- the same pass. Deferral therefore only buys a phase guarantee when the episode is
-- raised from onUpdate/event/onLoad, which is where every camera boundary is raised.
local DISPATCH_DELAY = 0

local JOIN_DELAY = 0.10
local LOAD_DELAY = 0.10

local VERIFY_DELAY = 1.0

-- Item 11. A load or a join is one reconciliation of existing desired state, so its
-- retries stretch further rather than being repeated as fresh notices. This covers the
-- window v5 reached with a second load delivery at 0.60 while emitting one notice.
local RETRY_DELAYS = {
    boundary = { 0.10, 0.10 },
    menu     = { 0.10, 0.10 },
    manual   = { 0.10, 0.10 },
    verify   = { 0.10, 0.10 },
    reconcile = { 0.10, 0.20, 0.40 },
}

-- UI modes that rebuild the model.
local REBUILD_UI_MODES = {
    Rest     = true,
    Travel   = true,
    Training = true,
    Jail     = true,
}

-- Item 3 (registration identity). `registrations[key]` holds the token of the live
-- registration for that key. Every subscribe() mints a fresh token, so deferred work
-- captured against an older registration can be recognised and dropped even when the
-- key has been reused by a different owner.
local registrations   = {}   -- key -> token (an opaque table)
local callbacks       = {}   -- token -> function
local verifiers       = {}   -- token -> true
local inFlight        = {}   -- token -> episode id, while its callback is running
local subscriberCount = 0
local pollTimer       = 0

-- Item 3 (episode identity). One episode per reconciliation cause. `latestCause` is the
-- id of the most recent cause; deferred work from a superseded episode is dropped rather
-- than replayed, which is what stops a retry landing after - and overwriting the meaning
-- of - a newer boundary.
local episodeCounter = 0
local latestCause    = 0

-- Item 12 (bounded reentrancy).
local dispatching = false

-- Item 11 (join/load coalescing).
local pendingReconcile = nil   -- set of keys awaiting one primary reconciliation

local function isFirstPersonMode(mode)
    return mode == camera.MODE.FirstPerson
end

-- The poll's baseline. Deliberately not what isFirstPerson() reports - see item 7.
local baselineFirstPerson = isFirstPersonMode(camera.getMode())
local lastMode            = camera.getMode()

-- ---------------------------------------------------------------------------
-- EPISODES
-- ---------------------------------------------------------------------------

local function newEpisode(reason, mode, previous, recipients)
    episodeCounter = episodeCounter + 1
    local episode = {
        id         = episodeCounter,
        reason     = reason,
        mode       = mode,
        previous   = previous,
        recipients = recipients,
        retries    = RETRY_DELAYS[reason] or RETRY_DELAYS.boundary,
    }
    if reason == 'reconcile' then
        -- A join or load reconciles state that is already desired; it reports no
        -- transition and does not supersede anything. Both halves of its
        -- (mode, previousMode) resolve at dispatch, because freezing only `previous`
        -- would let a non-crossing change (ThirdPerson -> Preview, which fires no
        -- boundary) deliver mode ~= previous and read as one.
        episode.cause    = latestCause
        episode.liveMode = true
    else
        latestCause   = episode.id
        episode.cause = episode.id
    end
    return episode
end

-- Deferred work is only still wanted if no newer cause has happened since.
local function episodeIsCurrent(episode)
    return latestCause == episode.cause
end

local function captureAll()
    local recipients = {}
    for key, token in pairs(registrations) do recipients[key] = token end
    return recipients
end

local function forget(key)
    local token = registrations[key]
    if token == nil then return false end
    registrations[key] = nil
    callbacks[token]   = nil
    verifiers[token]   = nil
    inFlight[token]    = nil
    subscriberCount    = subscriberCount - 1
    return true
end

-- ---------------------------------------------------------------------------
-- DELIVERY
-- ---------------------------------------------------------------------------

-- Item 2 (subscriber isolation), without a pcall. Each recipient is invoked from its own
-- simulation timer, and ScriptsContainer::callTimer wraps every timer callback in its own
-- try/catch (scriptscontainer.cpp:719-743). So a subscriber that throws is reported by the
-- engine and cannot truncate the fan-out, cancel other recipients' retries or stop
-- verification being scheduled.
--
-- The cost the audit flags is real: callTimer does `mTemporaryCallbacks.erase(id)` *after*
-- the call and inside the try, so a throwing callback is retained for the lifetime of the
-- script. It is bounded here by quarantining the registration, which needs a Lua-visible
-- signal because engine-level isolation tells Lua nothing. `inFlight` is that signal: it
-- is set before the call and cleared after, so an entry still present at the next dispatch
-- means the previous call never returned.
local dispatchOne

-- `dispatching` guards against reentrancy from inside a callback, so it must be true only
-- while one is running. A callback that throws never reaches the line that clears it, and
-- with engine-level isolation Lua never finds out - so a stranded `true` would silence
-- every later cause. Every entry point the engine calls is outside any callback by
-- construction, so each one clears it first and a leak cannot outlive one timer or frame.
local function enterFromEngine()
    dispatching = false
end

local function quarantine(key, token, episodeId)
    print("[AnimRefresh] '" .. tostring(key) .. "' raised an error during episode " ..
          tostring(episodeId) .. " (the engine logged it as 'callTimer failed'); " ..
          "removing that registration. Re-subscribe after fixing it.")
    if registrations[key] == token then forget(key) end
    inFlight[token] = nil
end

dispatchOne = function(episode, key, attempt)
    enterFromEngine()
    if not episodeIsCurrent(episode) then return end

    local token = episode.recipients[key]
    if token == nil or registrations[key] ~= token then return end

    local previousFlight = inFlight[token]
    if previousFlight ~= nil then
        quarantine(key, token, previousFlight)
        return
    end

    local callback = callbacks[token]
    if callback == nil then return end

    local mode, previous = episode.mode, episode.previous
    if episode.liveMode then
        -- A reconcile reports no transition, so both halves are the mode now. Using
        -- `lastMode` for `previous` is not safe: processTimers runs before onUpdate in
        -- LuaManager::update, so a reconcile can beat the first poll after a non-crossing
        -- change (ThirdPerson -> Preview) and deliver mode ~= previous - which is the only
        -- signal a two-argument consumer has for "a real boundary happened". v5 has the
        -- same race; making them equal by construction is what finally makes
        -- `mode ~= previousMode` a dependable discriminator.
        mode = camera.getMode()
        previous = mode
    end

    local wasDispatching = dispatching
    dispatching = true
    inFlight[token] = episode.id

    local result = callback(mode, previous)

    inFlight[token] = nil
    dispatching = wasDispatching

    if result ~= false then return end

    local delay = episode.retries[attempt + 1]
    if delay == nil then
        print("[AnimRefresh] '" .. tostring(key) .. "' still not ready after " ..
              tostring(#episode.retries + 1) ..
              " attempts; giving up on this change")
        return
    end
    async:newUnsavableSimulationTimer(delay, function()
        dispatchOne(episode, key, attempt + 1)
    end)
end

local function dispatch(episode, delay)
    for key in pairs(episode.recipients) do
        async:newUnsavableSimulationTimer(delay, function()
            dispatchOne(episode, key, 0)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- CAUSES
-- ---------------------------------------------------------------------------

local function raise(reason, previous, recipients, delay)
    if subscriberCount == 0 then return nil end
    -- Item 12: a refreshNow() raised from inside a callback is covered by the episode
    -- already running. It creates no nested fan-out and no self-generated chain.
    if dispatching then return nil end
    local episode = newEpisode(reason, camera.getMode(), previous, recipients)
    dispatch(episode, delay)
    return episode
end

local function fireBoundary(previous)
    local episode = raise('boundary', previous, captureAll(), DISPATCH_DELAY)
    if episode == nil then return end
    if next(verifiers) == nil then return end

    -- Item 2: scheduled at the cause rather than after the fan-out returns, so no
    -- subscriber's failure can cancel it. Item 3: it belongs to this boundary, so a
    -- subscriber that joined afterwards is not one of its verifiers and a newer cause
    -- retires it altogether.
    async:newUnsavableSimulationTimer(VERIFY_DELAY, function()
        if not episodeIsCurrent(episode) then return end
        local again = nil
        for key, token in pairs(episode.recipients) do
            if verifiers[token] and registrations[key] == token then
                again = again or {}
                again[key] = token
            end
        end
        if again == nil then return end
        local followUp = newEpisode('verify', camera.getMode(), episode.previous, again)
        -- A verification is a follow-up to its boundary, not a new cause.
        followUp.cause = episode.cause
        latestCause = episode.cause
        dispatch(followUp, DISPATCH_DELAY)
    end)
end

-- Item 11. One primary reconciliation per batch of joins and loads, instead of v5's two
-- load deliveries plus a join per subscriber for the same single restoration need.
local function requestReconcile(keys, delay)
    local scheduling = pendingReconcile == nil
    pendingReconcile = pendingReconcile or {}
    for key, token in pairs(keys) do pendingReconcile[key] = token end
    if not scheduling then return end

    async:newUnsavableSimulationTimer(delay, function()
        local batch = pendingReconcile
        pendingReconcile = nil
        if batch == nil or subscriberCount == 0 then return end
        local recipients = nil
        for key, token in pairs(batch) do
            if registrations[key] == token then
                recipients = recipients or {}
                recipients[key] = token
            end
        end
        if recipients == nil then return end
        local episode = newEpisode('reconcile', camera.getMode(), lastMode, recipients)
        dispatch(episode, DISPATCH_DELAY)
    end)
end

-- ---------------------------------------------------------------------------
-- DETECTION
-- ---------------------------------------------------------------------------

-- The poll is the only writer of the baseline.
local function checkBoundary()
    -- Item 4. v5 returned here whenever a mode change was queued, which left the baseline
    -- unwritten for as long as the queue was held. An applied crossing followed by a held
    -- return then landed back on the old baseline and both rebuilds vanished (G19). A
    -- queued request is a possible *future* change and is never a reason to skip sampling
    -- what the camera is doing now. `getQueuedMode()` being nil was never settlement
    -- evidence either: Camera::setMode assigns mMode immediately and defers the rebuild
    -- through mProcessViewChange (camera.cpp:217-245, consumed at :137).
    local mode = camera.getMode()
    local nowFirst = isFirstPersonMode(mode)
    local previous = lastMode
    lastMode = mode

    if nowFirst == baselineFirstPerson then return end
    baselineFirstPerson = nowFirst
    fireBoundary(previous)
end

local function onUpdate(dt)
    enterFromEngine()
    if subscriberCount == 0 then return end
    pollTimer = pollTimer + dt
    if pollTimer < POLL_INTERVAL then return end
    pollTimer = 0
    checkBoundary()
end

-- Fires when a rebuilding menu closes.
local function uiModeChanged(data)
    enterFromEngine()
    if subscriberCount == 0 then return end
    if data and data.newMode == nil and data.oldMode and REBUILD_UI_MODES[data.oldMode] then
        raise('menu', lastMode, captureAll(), DISPATCH_DELAY)
    end
end

local function onLoad()
    enterFromEngine()
    requestReconcile(captureAll(), LOAD_DELAY)
end

-- ---------------------------------------------------------------------------
-- INTERFACE
-- ---------------------------------------------------------------------------

-- Item 8: everything is checked before anything is written, so a rejected call leaves
-- the registry exactly as it was. In v5 the opts read happened after the registration
-- was already stored, so a bad `opts` raised but still left the callback live.
local function validate(key, callback, opts)
    if type(key) ~= 'string' or key == '' then
        return ("[AnimRefresh] subscribe() needs a non-empty string key, got %s")
               :format(type(key) == 'string' and '""' or type(key))
    end
    if callback ~= nil and type(callback) ~= 'function' then
        return ("[AnimRefresh] subscribe('%s', ...) needs a function, got %s")
               :format(key, type(callback))
    end
    -- nil and false both mean "no options", for compatibility.
    if opts ~= nil and opts ~= false then
        if type(opts) ~= 'table' then
            return ("[AnimRefresh] subscribe('%s', ...) options must be a table, got %s")
                   :format(key, type(opts))
        end
        if opts.verify ~= nil and type(opts.verify) ~= 'boolean' then
            return ("[AnimRefresh] subscribe('%s', ...) options.verify must be a boolean, got %s")
                   :format(key, type(opts.verify))
        end
    end
    return nil
end

local function unsubscribe(key)
    if type(key) ~= 'string' or key == '' then return end
    forget(key)
end

local function subscribe(key, callback, opts)
    local problem = validate(key, callback, opts)
    if problem then error(problem) end

    -- v5 accepted a nil callback as an unsubscribe. Kept working, but routed through the
    -- one implementation rather than being a second, undocumented path that also
    -- silently discarded opts.
    if callback == nil then
        forget(key)
        return
    end

    local firstSubscriber = subscriberCount == 0
    forget(key)   -- replacing an existing registration retires its token first

    -- Item 3: a fresh token per registration. Deferred work captured against the old
    -- token can no longer reach the new owner of this key.
    local token = {}
    registrations[key] = token
    callbacks[token]   = callback
    verifiers[token]   = (opts and opts.verify) or nil
    subscriberCount    = subscriberCount + 1

    if firstSubscriber then
        -- 0 -> 1 subscribers: re-baseline, so a view change nobody was listening for
        -- is not reported as news.
        lastMode            = camera.getMode()
        baselineFirstPerson = isFirstPersonMode(lastMode)
        pollTimer           = 0
    end

    -- Item 11: the joiner's refresh joins any reconciliation already pending rather than
    -- becoming another notice for the same need.
    requestReconcile({ [key] = token }, JOIN_DELAY)
end

-- For model changes this service cannot see.
local function refreshNow()
    raise('manual', lastMode, captureAll(), DISPATCH_DELAY)
end

local function getMode()
    return camera.getMode()
end

-- Item 7: live, and documented as the current camera mode rather than the generation of
-- the current skeleton. v5 returned the cached poll value, which was stale indefinitely
-- with no subscribers and whenever queue sampling was suppressed.
local function isFirstPersonNow()
    return isFirstPersonMode(camera.getMode())
end

return {
    interfaceName = "AnimRefresh",
    interface = {
        version       = MY_VERSION,
        subscribe     = subscribe,
        unsubscribe   = unsubscribe,
        refreshNow    = refreshNow,
        getMode       = getMode,
        isFirstPerson = isFirstPersonNow,
    },
    -- An event, not an engine handler. See docs/animrefresh.md.
    eventHandlers = {
        UiModeChanged  = uiModeChanged,
    },
    engineHandlers = {
        onUpdate       = onUpdate,
        onLoad         = onLoad,
    },
}
