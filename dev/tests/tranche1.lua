--[[ Tranche 1 verification: run the v5 finding set and the new positive tests against
     whichever service file is named on the command line.

       python3 -I runlua.py tranche1.lua AnimRefresh_v5.lua
       python3 -I runlua.py tranche1.lua AnimRefresh_v6.lua

     Expected after tranche 1 (items 8, 3, 12, 7):
       G10, G5, G5+, G11, G20   CONFIRMED on v5  ->  FIXED on v6
       G7, G19                  CONFIRMED on both (tranche 2: items 2 and 4)
       T1..T6                   the new behaviour, which v5 cannot satisfy

     Needs only liblua5.4 through ctypes. No LuaJIT, no OpenMW.
]]

local SERVICE = (...) or error('no service given. Usage: python3 -I runlua.py <harness>.lua <AnimRefresh>.lua', 0)

local results = {}
local function record(id, claim, holds, detail)
    results[#results + 1] = { id = id, claim = claim, holds = holds, detail = detail }
end

-- A "defect" check: holds == true means the defect reproduced.
local function defect(id, claim, reproduced, detail)
    record(id, claim, reproduced, detail)
    results[#results].kind = 'defect'
end

-- A "behaviour" check: holds == true means the required v6 behaviour is present.
local function behaviour(id, claim, ok, detail)
    record(id, claim, ok, detail)
    results[#results].kind = 'behaviour'
end

-- ---------------------------------------------------------------------------

local function skip(id, claim, why)
    record(id, claim, false, why)
    results[#results].kind = 'behaviour'
end

local function newEngine(preexistingInterface)
    local engine = { timers = {}, mode = 'ThirdPerson', queued = nil, clock = 0, lastError = nil }

    package.loaded['openmw.camera'] = {
        MODE = { FirstPerson = 'FirstPerson', ThirdPerson = 'ThirdPerson',
                 Static = 'Static', Preview = 'Preview' },
        getMode = function() return engine.mode end,
        getQueuedMode = function() return engine.queued end,
    }
    package.loaded['openmw.async'] = {
        newUnsavableSimulationTimer = function(_, delay, fn)
            table.insert(engine.timers, { at = engine.clock + delay, fn = fn })
        end,
    }
    package.loaded['openmw.interfaces'] = { AnimRefresh = preexistingInterface }

    -- A service may legitimately return nothing (it stood down), and v5 can raise here
    -- outright when a foreign provider's version is not a number (G15) - so loading is
    -- itself an observation rather than an assumption.
    local chunk = assert(loadfile(SERVICE))
    local ok, loaded = pcall(chunk)
    engine.loadError = (not ok) and loaded or nil
    engine.loaded = ok and loaded or nil
    engine.service = engine.loaded and engine.loaded.interface or nil

    function engine.advance(dt)
        engine.clock = engine.clock + dt
        engine.lastError = nil
        local handler = engine.loaded and engine.loaded.engineHandlers
                        and engine.loaded.engineHandlers.onUpdate
        if handler then
            local ok, err = pcall(handler, dt)
            if not ok then engine.lastError = err end
        end
        -- ScriptsContainer::updateTimerQueue is `while front().mTime <= time`, so a timer
        -- created inside a timer callback with a deadline already past is popped in the
        -- same pass. Model that, or deferred dispatch looks like it never arrives.
        local guard = 0
        while true do
            local pick = nil
            for index, timer in ipairs(engine.timers) do
                if timer.at <= engine.clock and (pick == nil or timer.at < engine.timers[pick].at) then
                    pick = index
                end
            end
            if pick == nil then break end
            guard = guard + 1
            if guard > 10000 then engine.lastError = 'timer storm'; break end
            local timer = table.remove(engine.timers, pick)
            -- callTimer wraps every timer callback in its own try/catch, so a throwing
            -- subscriber is isolated here exactly as the engine isolates it.
            local ok, err = pcall(timer.fn)
            if not ok then engine.lastError = err end
        end
    end

    function engine.settle(n)
        for _ = 1, (n or 3) do engine.advance(0.05) end
    end

    return engine
end

-- ---------------------------------------------------------------------------
-- The v5 defect set
-- ---------------------------------------------------------------------------

-- G7 (tranche 2): one throw truncates the shared fan-out.
--
-- Repeated, because a single trial is not a reliable verdict. The audit already noted that
-- `pairs` order decides who gets cut off ("4 of 8, not 0 or 8"); the corollary is that when
-- the thrower happens to sort LAST, every healthy subscriber is reached and v5 looks fixed.
-- With 8 healthy and 1 thrower that is roughly 1 run in 9, and it duly happened once an
-- unrelated edit perturbed the hash layout. A defect test that can report "fixed" by luck
-- would just as happily hand v6 a false pass, so take the worst of several trials.
do
    local TRIALS = 20
    local worst = 8
    for _ = 1, TRIALS do
        local engine = newEngine()
        local service = engine.service
        local seen = {}
        for index = 1, 8 do
            local key = 'healthy' .. index
            service.subscribe(key, function() seen[key] = true end)
        end
        service.subscribe('thrower', function() error('subscriber exploded') end,
                          { verify = true })
        engine.settle()

        seen = {}
        engine.mode = 'FirstPerson'
        engine.advance(0.2)
        local notified = 0
        for _ in pairs(seen) do notified = notified + 1 end
        if notified < worst then worst = notified end
    end
    defect('G7', 'a throw truncates the fan-out', worst < 8,
           ('worst of %d trials: %d of 8 healthy subscribers notified'):format(TRIALS, worst))
end

-- G10: a rejected subscribe leaves a live registration behind.
do
    local engine = newEngine()
    local service = engine.service
    local ran = 0
    pcall(service.subscribe, 'bad', function() ran = ran + 1 end, 42)
    engine.mode = 'FirstPerson'
    engine.advance(0.2)
    defect('G10', 'a rejected subscribe still registered the callback', ran > 0,
           ('the callback ran %d time(s)'):format(ran))
end

-- G5 / G5+: a retry replays a mode that is no longer live, arriving after the correct
-- newer notice.
do
    local engine = newEngine()
    local service = engine.service
    local log = {}
    local asked = false
    service.subscribe('retryer', function(mode)
        log[#log + 1] = { mode = mode, live = engine.mode }
        if not asked then asked = true; return false end
    end)
    engine.advance(0.05); engine.advance(0.05)
    engine.mode = 'FirstPerson'
    engine.settle()

    local stale, afterFresh, sawLive = 0, false, false
    for _, entry in ipairs(log) do
        if entry.mode == entry.live then sawLive = true
        else stale = stale + 1; if sawLive then afterFresh = true end end
    end
    defect('G5', 'a retry carries a mode no longer live', stale > 0,
           ('%d of %d deliveries stale'):format(stale, #log))
    defect('G5+', 'the stale retry arrives after the correct notice', afterFresh,
           afterFresh and 'ordering trap present' or 'no out-of-order delivery')
end

-- G11: isFirstPerson() disagrees with the live camera mode.
do
    local engine = newEngine()
    local service = engine.service
    engine.mode = 'FirstPerson'
    engine.advance(0.2)
    defect('G11', 'isFirstPerson() is stale while getMode() is live',
           service.isFirstPerson() == false and service.getMode() == 'FirstPerson',
           ('isFirstPerson=%s getMode=%s'):format(tostring(service.isFirstPerson()), service.getMode()))
end

-- G19 (tranche 2): the queued-mode guard hides an out-and-back round trip.
do
    local engine = newEngine()
    local service = engine.service
    local fires = 0
    service.subscribe('roundtrip', function() fires = fires + 1 end)
    engine.settle()
    fires = 0
    engine.mode = 'FirstPerson'; engine.queued = 'ThirdPerson'
    engine.advance(0.2)
    engine.queued = nil; engine.mode = 'ThirdPerson'
    engine.advance(0.2)
    defect('G19', 'both rebuilds hidden by the queue guard', fires == 0,
           ('%d notices for 2 rebuilds'):format(fires))
end

-- G20: refreshNow() from inside a callback re-enters the fan-out.
do
    local engine = newEngine()
    local service = engine.service
    local depth, deepest = 0, 0
    service.subscribe('recursive', function()
        depth = depth + 1
        if depth > deepest then deepest = depth end
        if depth < 60 then service.refreshNow() end
        depth = depth - 1
    end)
    engine.settle()
    defect('G20', 'refreshNow() re-enters the fan-out', deepest > 1,
           ('nesting reached %d'):format(deepest))
end

-- ---------------------------------------------------------------------------
-- Tranche 1 required behaviour
-- ---------------------------------------------------------------------------

-- T1 (item 8): a rejected subscribe changes nothing at all.
do
    local engine = newEngine()
    local service = engine.service
    service.subscribe('good', function() end)
    local before = service.isFirstPerson()
    local badOpts = { pcall(service.subscribe, 'x', function() end, 42) }
    local badVerify = { pcall(service.subscribe, 'y', function() end, { verify = 'yes' }) }
    local badKey = { pcall(service.subscribe, '', function() end) }
    local badCallback = { pcall(service.subscribe, 'z', 'not a function') }
    local ranX, ranY = 0, 0
    -- if either registered, a boundary would reach it
    engine.mode = 'FirstPerson'
    engine.advance(0.2)
    local raised = {}
    for _, pair in ipairs({ { 'opts', badOpts }, { 'verify', badVerify },
                            { 'key', badKey }, { 'callback', badCallback } }) do
        raised[#raised + 1] = pair[1] .. '=' .. (pair[2][1] and 'ACCEPTED' or 'raised')
    end
    behaviour('T1', 'all four malformed subscribes rejected',
              not badOpts[1] and not badVerify[1] and not badKey[1] and not badCallback[1],
              table.concat(raised, ' '))
    behaviour('T1b', 'verify must be a boolean', not badVerify[1],
              tostring(badVerify[2]):match('verify.*$') or '')
end

-- T2 (item 8): nil and false still mean "no options".
do
    local engine = newEngine()
    local service = engine.service
    local a = pcall(service.subscribe, 'nilopts', function() end, nil)
    local b = pcall(service.subscribe, 'falseopts', function() end, false)
    behaviour('T2', 'nil and false opts remain compatible', a and b, 'both accepted')
end

-- G15 / T3 (item 8): a foreign provider with a non-numeric version must not break
-- startup, and a genuinely newer provider must win.
do
    local broken = newEngine({ version = 'five' })
    local newer  = newEngine({ version = 99 })
    local older  = newEngine({ version = 2 })
    defect('G15', 'a non-numeric foreign version breaks startup',
           broken.loadError ~= nil, tostring(broken.loadError):match('[^\n]*') or '')
    behaviour('T3', 'non-numeric foreign version does not break startup',
              broken.service ~= nil and broken.service.version ~= nil,
              broken.loadError and 'service failed to load'
              or ('published v%s over a version="five" provider'):format(tostring(broken.service and broken.service.version)))
    behaviour('T3b', 'stands down for a newer provider', newer.loaded == nil,
              'returned without publishing')
    behaviour('T3c', 'replaces an older provider', older.service ~= nil,
              ('published v%s over v2'):format(tostring(older.service and older.service.version)))
end

-- T4 (item 3): a reused key does not receive the previous owner's deferred work.
do
    local engine = newEngine()
    local service = engine.service
    local first, second = 0, 0
    service.subscribe('shared', function() first = first + 1 end)
    service.unsubscribe('shared')
    service.subscribe('shared', function() second = second + 1 end)
    engine.settle(4)
    behaviour('T4', 'a reused key gets no callback meant for the old owner',
              first == 0, ('old owner ran %d time(s), new owner %d'):format(first, second))
end

-- T5 (item 3): a subscriber that joins after a boundary is not verified for it.
do
    local engine = newEngine()
    local service = engine.service
    local early, late = 0, 0
    service.subscribe('early', function() early = early + 1 end, { verify = true })
    engine.settle()
    early = 0
    engine.mode = 'FirstPerson'
    engine.advance(0.2)                      -- boundary; schedules verification
    local atBoundary = early
    service.subscribe('late', function() late = late + 1 end, { verify = true })
    engine.advance(0.15)                     -- drain the late join
    local afterJoin = late
    engine.advance(1.2)                      -- the boundary's verification lands
    behaviour('T5', 'a late verifier does not inherit the earlier boundary',
              late == afterJoin,
              ('late subscriber: %d at join, %d after verification'):format(afterJoin, late))
end

-- T6 (item 12): refreshNow() from inside a callback is coalesced, not nested.
do
    local engine = newEngine()
    local service = engine.service
    local depth, deepest, calls = 0, 0, 0
    service.subscribe('recursive', function()
        calls = calls + 1
        depth = depth + 1
        if depth > deepest then deepest = depth end
        service.refreshNow()                 -- unconditional, every time
        depth = depth - 1
    end)
    engine.settle(6)
    behaviour('T6', 'an unconditional refreshNow() cycle terminates without nesting',
              deepest == 1, ('max nesting %d over %d calls'):format(deepest, calls))
end

-- T7 (item 7): isFirstPerson() tracks the live mode with no subscribers and while queued.
do
    local engine = newEngine()
    local service = engine.service
    engine.mode = 'FirstPerson'
    local noSubs = service.isFirstPerson()
    engine.queued = 'ThirdPerson'
    local whileQueued = service.isFirstPerson()
    engine.mode = 'ThirdPerson'; engine.queued = nil
    local backAgain = service.isFirstPerson()
    behaviour('T7', 'isFirstPerson() is live in all three states',
              noSubs == true and whileQueued == true and backAgain == false,
              ('noSubscribers=%s whileQueued=%s afterReturn=%s')
              :format(tostring(noSubs), tostring(whileQueued), tostring(backAgain)))
end

-- T8: the two real consumer shapes still work. FLOW subscribes once at activation with
-- verify; Take a Seat subscribes on sitting and unsubscribes on standing.
do
    local engine = newEngine()
    local service = engine.service
    local flow, seat = 0, 0
    service.subscribe('FLOW', function() flow = flow + 1 end, { verify = true })
    engine.settle()
    local flowAtJoin = flow

    service.subscribe('TakeASeat', function() seat = seat + 1 end)   -- sat down
    engine.settle()
    local seatAtJoin = seat

    engine.mode = 'FirstPerson'                                      -- a real boundary
    engine.advance(0.2)
    local flowAtBoundary, seatAtBoundary = flow, seat
    -- Generous on purpose. Item 10 makes the verification delay a measured value rather
    -- than a fixed one, so a test tuned to the exact constant breaks every time the
    -- measurement is revisited - which is what happened when it moved from 1.0s to 1.8s.
    engine.advance(3.0)                                              -- FLOW's verification
    local flowAfterVerify = flow

    service.unsubscribe('TakeASeat')                                 -- stood up
    seat = 0
    engine.mode = 'ThirdPerson'
    engine.advance(0.2)

    behaviour('T8', 'FLOW gets join, boundary and its verification',
              flowAtJoin == 1 and flowAtBoundary == 2 and flowAfterVerify == 3,
              ('join=%d boundary=%d afterVerify=%d'):format(flowAtJoin, flowAtBoundary, flowAfterVerify))
    behaviour('T8b', 'Take a Seat gets join and boundary, nothing after unsubscribe',
              seatAtJoin == 1 and seatAtBoundary == 2 and seat == 0,
              ('join=%d boundary=%d afterUnsubscribe=%d'):format(seatAtJoin, seatAtBoundary, seat))
end

-- T9 (item 3): subscribing and unsubscribing from inside a callback. The newcomer must
-- not be swept into the episode already in flight, and a subscriber removed during the
-- fan-out must not still be called by it.
--
-- The mutator only acts on its SECOND call, so the newcomer's very first registration
-- happens inside the boundary fan-out. (A newcomer that subscribed earlier is a genuine
-- recipient of that boundary, which is why an earlier version of this test was wrong.)
do
    local engine = newEngine()
    local service = engine.service
    local newcomer, doomed, calls = 0, 0, 0
    service.subscribe('doomed', function() doomed = doomed + 1 end)
    service.subscribe('mutator', function()
        calls = calls + 1
        if calls < 2 then return end
        service.subscribe('newcomer', function() newcomer = newcomer + 1 end)
        service.unsubscribe('doomed')
    end)
    engine.settle()
    newcomer, doomed = 0, 0

    engine.mode = 'FirstPerson'
    engine.advance(0.2)                      -- the boundary: mutator's second call
    local duringEpisode = newcomer
    local doomedInEpisode = doomed
    engine.advance(0.15)                     -- the newcomer's own join
    behaviour('T9', 'a mid-fan-out subscriber is not swept into the live episode',
              duringEpisode == 0 and newcomer == 1,
              ('newcomer: %d during the episode, %d after its join'):format(duringEpisode, newcomer))
    behaviour('T9b', 'a subscriber removed mid-fan-out is not called again by it',
              doomedInEpisode <= 1,
              ('the removed subscriber ran %d time(s) in that episode'):format(doomedInEpisode))
end

-- ---------------------------------------------------------------------------

print(('service: %s\n'):format(SERVICE))
print(('%-5s %-12s %-54s %s'):format('ID', 'KIND', 'CLAIM', 'RESULT'))
local defectsOpen, behavioursOk, behavioursTotal = 0, 0, 0
for _, row in ipairs(results) do
    local verdict
    if row.kind == 'defect' then
        verdict = row.holds and 'REPRODUCED' or 'fixed'
        if row.holds then defectsOpen = defectsOpen + 1 end
    else
        behavioursTotal = behavioursTotal + 1
        verdict = row.holds and 'PASS' or 'FAIL'
        if row.holds then behavioursOk = behavioursOk + 1 end
    end
    print(('%-5s %-12s %-54s %-11s %s'):format(row.id, row.kind, row.claim, verdict, row.detail or ''))
end
print(('\ndefects still reproducing: %d    tranche-1 behaviour: %d/%d')
      :format(defectsOpen, behavioursOk, behavioursTotal))
