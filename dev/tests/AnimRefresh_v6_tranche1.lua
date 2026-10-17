---@omw-context player
-- AnimRefresh v6: tells subscribers when the player model is rebuilt
-- (first-person boundary, Rest/Travel/Training/Jail, load). See docs/animrefresh.md.
--   I.AnimRefresh.subscribe(key, fn(mode, previousMode) [-> false to retry], { verify = true })
--   I.AnimRefresh.unsubscribe(key)
--
-- TRANCHE 1 of the v6 fix list: items 8, 3, 12 and 7. Detection and delivery are
-- deliberately unchanged from v5, so these remain open and are expected to keep
-- reproducing until tranche 2:
--   G2  a boundary can be delivered before the camera rebuild it was inferred from
--   G7  one subscriber's exception still interrupts the shared fan-out
--   G19 the queued-mode guard still hides an out-and-back round trip
--
-- Public surface is unchanged. Callbacks still receive exactly (mode, previousMode);
-- the metadata third argument is item 9 and is not here.

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

local MAX_RETRIES = 2
local RETRY_DELAY = 0.10

local LOAD_DELAYS = { 0.10, 0.60 }

local JOIN_DELAY = 0.10

local VERIFY_DELAY = 1.0

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
local registrations  = {}   -- key -> token (an opaque table)
local callbacks      = {}   -- token -> function
local verifiers      = {}   -- token -> true
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
    }
    if reason == 'join' then
        -- A join serves one late registration and does not supersede anything; it is
        -- simply obsolete once a real cause has happened. It also reports no transition,
        -- so its mode is resolved at dispatch rather than frozen here - unlike a
        -- boundary, whose observed mode is the whole point of the notice.
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

-- ...and only for recipients whose registration is still the one that was captured.
local function recipientIsCurrent(episode, key)
    local token = episode.recipients[key]
    return token ~= nil and registrations[key] == token and callbacks[token] ~= nil
end

local function captureAll()
    local recipients = {}
    for key, token in pairs(registrations) do recipients[key] = token end
    return recipients
end

-- ---------------------------------------------------------------------------
-- DELIVERY
-- ---------------------------------------------------------------------------

local deliver

deliver = function(episode, keys, attempt)
    if not episodeIsCurrent(episode) then return end

    local notReady = nil
    local wasDispatching = dispatching
    dispatching = true

    for key in pairs(keys) do
        if recipientIsCurrent(episode, key) then
            local callback = callbacks[episode.recipients[key]]
            local mode, previous = episode.mode, episode.previous
            if episode.liveMode then
                -- A join reports no transition, so both halves are resolved now. Freezing
                -- only `previous` would let a non-crossing change (ThirdPerson -> Preview,
                -- which fires no boundary) deliver mode ~= previous and read as one.
                mode, previous = camera.getMode(), lastMode
            end
            -- G7 is tranche 2: a throw here still escapes and truncates the fan-out.
            local result = callback(mode, previous)
            if result == false then
                notReady = notReady or {}
                notReady[key] = true
            end
        end
    end

    dispatching = wasDispatching

    if not notReady then return end

    if attempt < MAX_RETRIES then
        async:newUnsavableSimulationTimer(RETRY_DELAY, function()
            deliver(episode, notReady, attempt + 1)
        end)
    else
        for key in pairs(notReady) do
            print("[AnimRefresh] '" .. tostring(key) ..
                  "' still not ready after " .. tostring(MAX_RETRIES + 1) ..
                  " attempts; giving up on this change")
        end
    end
end

local function fire(reason, previous)
    if subscriberCount == 0 then return end
    -- Item 12: a refreshNow() raised from inside a callback is covered by the episode
    -- already running. It creates no nested fan-out and no self-generated chain.
    if dispatching then return end
    local mode = camera.getMode()
    local episode = newEpisode(reason, mode, previous, captureAll())
    deliver(episode, episode.recipients, 0)
    return episode
end

local function fireBoundary(previous)
    local episode = fire('boundary', previous)
    if episode == nil then return end
    if next(verifiers) == nil then return end

    async:newUnsavableSimulationTimer(VERIFY_DELAY, function()
        -- Item 3: verification belongs to the boundary that scheduled it. A subscriber
        -- that joined afterwards is not a verifier of this boundary, and a newer cause
        -- retires it altogether.
        if not episodeIsCurrent(episode) then return end
        local again = nil
        for key, token in pairs(episode.recipients) do
            if verifiers[token] and recipientIsCurrent(episode, key) then
                again = again or {}
                again[key] = true
            end
        end
        if again then deliver(episode, again, 0) end
    end)
end

-- ---------------------------------------------------------------------------
-- DETECTION
-- ---------------------------------------------------------------------------

-- The poll is the only writer of the baseline.
local function checkBoundary()
    -- G19 is tranche 2 (item 4): while a return is queued this skips sampling entirely,
    -- so an out-and-back round trip is still invisible.
    if camera.getQueuedMode() ~= nil then return end

    local mode = camera.getMode()
    local nowFirst = isFirstPersonMode(mode)
    local previous = lastMode
    lastMode = mode

    if nowFirst == baselineFirstPerson then return end
    baselineFirstPerson = nowFirst
    -- G2 is tranche 2 (item 1): this fires in the same onUpdate that observed the
    -- change, which can be before the camera update that actually rebuilds the model.
    fireBoundary(previous)
end

local function onUpdate(dt)
    if subscriberCount == 0 then return end
    pollTimer = pollTimer + dt
    if pollTimer < POLL_INTERVAL then return end
    pollTimer = 0
    checkBoundary()
end

-- Fires when a rebuilding menu closes.
local function uiModeChanged(data)
    if subscriberCount == 0 then return end
    if data and data.newMode == nil and data.oldMode and REBUILD_UI_MODES[data.oldMode] then
        fire('menu', lastMode)
    end
end

local function onLoad()
    for _, delay in ipairs(LOAD_DELAYS) do
        async:newUnsavableSimulationTimer(delay, function() fire('load', lastMode) end)
    end
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

local function forget(key)
    local token = registrations[key]
    if token == nil then return false end
    registrations[key] = nil
    callbacks[token]   = nil
    verifiers[token]   = nil
    subscriberCount    = subscriberCount - 1
    return true
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

    -- One refresh for the joiner alone.
    local episode = newEpisode('join', camera.getMode(), lastMode, { [key] = token })
    async:newUnsavableSimulationTimer(JOIN_DELAY, function()
        deliver(episode, episode.recipients, 0)
    end)
end

-- For model changes this service cannot see.
local function refreshNow()
    fire('manual', lastMode)
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
