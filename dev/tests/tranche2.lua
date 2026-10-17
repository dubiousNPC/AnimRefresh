--[[ Tranche 2 verification against a phase-accurate frame model.

       python3 -I runlua.py tranche2.lua AnimRefresh_v5.lua
       python3 -I runlua.py tranche2.lua AnimRefresh_v6b.lua

     tranche1.lua's stub runs onUpdate and then drains timers, which is enough for the
     internal-correctness findings but cannot express G2 at all: it has no camera update
     phase, so there is no such thing as repairing the wrong skeleton. This model has one.

     Frame phases, traced in OpenMW at the audit's pin f4bec414:

       engine.cpp::frame()   230  mLuaManager->synchronizedUpdate()   onFrame, queued actions
                             302  mWorld->update()                    <- the rebuild lands here
                             352  mLuaWorker->allowUpdate()           -> LuaManager::update()
       LuaManager::update()  255  processTimers        (while front().mTime <= time)
                             262  callEventHandlers
                             269  callEngineHandlers
                             275  asLocal->update(dt)                 onUpdate, float dt, 0 if paused

     Camera::setMode (camera.cpp:217) assigns mMode immediately and defers the rebuild via
     mProcessViewChange, consumed inside the camera update at camera.cpp:137 and cleared at
     368. When a state holds the crossing it sets mQueuedMode and leaves mMode alone.
     Animation::clearAnimSources() does mStates.clear(), so the rebuild drops repairs.

     The skeleton is modelled as a generation counter. A subscriber "repairs" by recording
     the generation it saw; the repair survives only if no rebuild followed it.
]]

local SERVICE = (...) or error('no service given. Usage: python3 -I runlua.py <harness>.lua <AnimRefresh>.lua', 0)

local results = {}
local function defect(id, claim, reproduced, detail)
    results[#results + 1] = { id = id, kind = 'defect', claim = claim,
                              holds = reproduced, detail = detail }
end
local function behaviour(id, claim, ok, detail)
    results[#results + 1] = { id = id, kind = 'behaviour', claim = claim,
                              holds = ok, detail = detail }
end

-- ---------------------------------------------------------------------------

local function newEngine()
    local engine = {
        clock = 0, frame = 0, timers = {},
        mode = 'ThirdPerson', queued = nil,
        pendingRebuild = false,
        upperBodyBusy = false,       -- a Hit/Weapon/Knockdown/Death priority state
        generation = 1,              -- the skeleton generation; a rebuild increments it
        rebuilds = 0,
        onFrameHooks = {}, onUpdateHooks = {},
    }

    local MODE = { FirstPerson = 'FirstPerson', ThirdPerson = 'ThirdPerson',
                   Static = 'Static', Preview = 'Preview', Vanity = 'Vanity' }

    local function setMode(newMode)
        if engine.mode == newMode then engine.queued = nil; return end
        local crossing = (newMode == MODE.FirstPerson or engine.mode == MODE.FirstPerson)
        if crossing and engine.upperBodyBusy then
            engine.queued = newMode          -- mMode is NOT changed while held
            return
        end
        engine.mode = newMode
        engine.queued = nil
        if crossing then engine.pendingRebuild = true end
    end
    engine.setMode = setMode

    package.loaded['openmw.camera'] = {
        MODE = MODE,
        getMode = function() return engine.mode end,
        getQueuedMode = function() return engine.queued end,
        setMode = setMode,
    }
    package.loaded['openmw.async'] = {
        newUnsavableSimulationTimer = function(_, delay, fn)
            table.insert(engine.timers, { at = engine.clock + delay, fn = fn })
        end,
    }
    package.loaded['openmw.interfaces'] = {}

    local chunk = assert(loadfile(SERVICE))
    local ok, loaded = pcall(chunk)
    engine.loaded = ok and loaded or nil
    engine.service = engine.loaded and engine.loaded.interface or nil

    local function call(fn, ...)
        if fn == nil then return end
        local success, err = pcall(fn, ...)
        if not success then engine.lastError = err end
    end

    engine.call = call

    function engine.runFrame(dt)
        dt = dt or (1 / 60)
        engine.frame = engine.frame + 1
        -- Simulation time is advanced at the END of the frame, so onFrame and onUpdate in
        -- one frame share the same timestamp, and it does not advance at all while paused.
        -- Both come from the audit's own corrected model (their RR09 verifies shared
        -- pre-increment onFrame/onUpdate time, paused timer deferral and a frozen paused
        -- clock, citing engine.cpp:1041-1051 and luamanagerimp.cpp:251-275). My model had
        -- advanced the clock at the start of the frame and kept advancing it while paused -
        -- which left paused timers firing all at once on resume rather than waiting out
        -- their deadlines in unpaused time. No verdict here changed, but diverging from a
        -- model they have already validated is not worth it.

        -- 230: synchronizedUpdate - onFrame and queued actions
        for _, hook in ipairs(engine.onFrameHooks) do call(hook, dt) end

        -- 302: mWorld->update - the camera update consumes mProcessViewChange
        if engine.pendingRebuild then
            engine.pendingRebuild = false
            engine.generation = engine.generation + 1
            engine.rebuilds = engine.rebuilds + 1
        end
        -- a queued crossing is retried once nothing holds it
        if engine.queued ~= nil and not engine.upperBodyBusy then
            local wanted = engine.queued
            engine.queued = nil
            setMode(wanted)
        end

        -- 255: processTimers, as a while loop over the heap.
        --
        -- LuaManager::update runs processTimers ONLY when unpaused (luamanagerimp.cpp:255),
        -- and reaches onUpdate as asLocal(ptr)->update(isPaused ? 0 : frameDuration), so a
        -- paused frame still calls onUpdate but with dt == 0. Event and engine handlers are
        -- called either way. Items 1 and 11 both gate on this ("plus pause", "paused time
        -- does not drain timers") and nothing modelled it until now.
        local guard = 0
        while not engine.paused do
            local pick = nil
            for index, timer in ipairs(engine.timers) do
                if timer.at <= engine.clock
                   and (pick == nil or timer.at < engine.timers[pick].at) then
                    pick = index
                end
            end
            if pick == nil then break end
            guard = guard + 1
            if guard > 10000 then engine.lastError = 'timer storm'; break end
            local timer = table.remove(engine.timers, pick)
            call(timer.fn)   -- callTimer's own try/catch, per subscriber
        end

        -- 269/275: engine handlers, then onUpdate with a zero dt while paused
        local liveDt = engine.paused and 0 or dt
        for _, hook in ipairs(engine.onUpdateHooks) do call(hook, liveDt) end
        if engine.loaded and engine.loaded.engineHandlers then
            call(engine.loaded.engineHandlers.onUpdate, liveDt)
        end

        if not engine.paused then engine.clock = engine.clock + dt end
    end

    function engine.runFrames(n, dt)
        for _ = 1, (n or 1) do engine.runFrame(dt) end
    end

    return engine
end

-- A subscriber that repairs the skeleton it was told about, the way a VFX or pose
-- consumer would: it records which generation it attached to.
local function repairer(engine, log)
    return function(mode, previous, meta)
        log[#log + 1] = { mode = mode, previous = previous, meta = meta,
                          generation = engine.generation, frame = engine.frame }
    end
end

-- ---------------------------------------------------------------------------
-- G2: a camera setter in the Lua update phase, sampled before the rebuild
-- ---------------------------------------------------------------------------

do
    local engine = newEngine()
    local service = engine.service
    local log = {}
    service.subscribe('vfx', repairer(engine, log), { verify = false })
    engine.runFrames(20)                      -- settle the join
    for i = #log, 1, -1 do log[i] = nil end

    -- Another mod flips the view from its own onUpdate, which is where mods normally do
    -- it. The rebuild cannot happen until the next frame's camera update.
    local done = false
    table.insert(engine.onUpdateHooks, function()
        if done then return end
        done = true
        engine.setMode('FirstPerson')
    end)

    engine.runFrames(25)

    local lost, survived = 0, 0
    for _, entry in ipairs(log) do
        if entry.generation < engine.generation then lost = lost + 1 else survived = survived + 1 end
    end
    local detail = ('%d notice(s); generation now %d, repairs at %s')
        :format(#log, engine.generation,
                (function()
                    local gens = {}
                    for _, e in ipairs(log) do gens[#gens + 1] = tostring(e.generation) end
                    return #gens > 0 and table.concat(gens, ',') or 'none'
                end)())

    defect('G2', 'the repair lands on a skeleton that is then rebuilt',
           #log > 0 and lost > 0 and survived == 0, detail)
    behaviour('P1', 'every boundary repair survives the rebuild it describes',
              #log > 0 and lost == 0, detail)
end

-- ---------------------------------------------------------------------------
-- G7: one subscriber's exception must not truncate the fan-out
-- ---------------------------------------------------------------------------

do
    local engine = newEngine()
    local service = engine.service
    local seen = {}
    for index = 1, 8 do
        local key = 'healthy' .. index
        service.subscribe(key, function() seen[key] = true end)
    end
    service.subscribe('thrower', function() error('subscriber exploded') end, { verify = true })
    engine.runFrames(20)
    seen = {}

    engine.setMode('FirstPerson')
    engine.runFrames(25)
    local notified = 0
    for _ in pairs(seen) do notified = notified + 1 end

    defect('G7', 'a throw truncates the fan-out', notified < 8,
           ('%d of 8 healthy subscribers notified'):format(notified))

    -- and the service must still be alive afterwards
    local after = {}
    for index = 1, 8 do
        local key = 'healthy' .. index
        service.subscribe(key, function() after[key] = true end)
    end
    engine.runFrames(20)
    engine.setMode('ThirdPerson')
    engine.runFrames(25)
    local alive = 0
    for _ in pairs(after) do alive = alive + 1 end
    behaviour('P2', 'the service still delivers after a subscriber threw',
              alive == 8, ('%d of 8 notified on the next boundary'):format(alive))
end

-- ---------------------------------------------------------------------------
-- G19 / item 4: an applied crossing followed by a held return (the RR12 sequence)
-- ---------------------------------------------------------------------------

do
    local engine = newEngine()
    local service = engine.service
    local log = {}
    service.subscribe('roundtrip', repairer(engine, log))
    engine.runFrames(20)
    for i = #log, 1, -1 do log[i] = nil end

    -- The trigger is narrow: both setters land inside one poll interval, so the poll
    -- never sees the outgoing crossing on its own. Spread them out and v5 catches the
    -- first one by luck and the finding does not reproduce.
    engine.setMode('FirstPerson')             -- applies; rebuild 1 next camera update
    engine.upperBodyBusy = true               -- a Weapon-priority state starts
    engine.setMode('ThirdPerson')             -- held: queued set, mMode stays FirstPerson
    engine.runFrames(10)                      -- polls run here, with a return queued
    engine.upperBodyBusy = false              -- released; the queued crossing applies
    engine.runFrames(25)

    local modes = {}
    for _, entry in ipairs(log) do modes[#modes + 1] = entry.mode end
    local detail = ('%d rebuilds, %d notices [%s]')
        :format(engine.rebuilds, #log, table.concat(modes, ','))

    defect('G19', 'both rebuilds are hidden by the queue guard', #log == 0, detail)
    behaviour('P3', 'RR12: FirstPerson while held, then ThirdPerson after release',
              #log == 2 and modes[1] == 'FirstPerson' and modes[2] == 'ThirdPerson', detail)
end

-- ---------------------------------------------------------------------------
-- Item 11: one primary reconciliation for a load, not two deliveries plus joins
-- ---------------------------------------------------------------------------

do
    local engine = newEngine()
    local service = engine.service
    local log = {}
    service.subscribe('consumer', repairer(engine, log))
    engine.runFrames(20)
    local atJoin = #log

    for i = #log, 1, -1 do log[i] = nil end
    if engine.loaded.engineHandlers.onLoad then engine.loaded.engineHandlers.onLoad() end
    engine.runFrames(60)                      -- past v5's 0.60 second delivery

    behaviour('P4', 'a join is one notice',
              atJoin == 1, ('%d notice(s) for the join'):format(atJoin))
    behaviour('P5', 'a load is one notice',
              #log == 1, ('%d notice(s) for the load'):format(#log))
end

-- ---------------------------------------------------------------------------
-- Item 11: a load arriving while a join is still pending must not double up
-- ---------------------------------------------------------------------------

do
    local engine = newEngine()
    local service = engine.service
    local log = {}
    service.subscribe('consumer', repairer(engine, log))
    if engine.loaded.engineHandlers.onLoad then engine.loaded.engineHandlers.onLoad() end
    engine.runFrames(60)
    behaviour('P6', 'a load coinciding with a join is still one notice',
              #log == 1, ('%d notice(s) for one restoration need'):format(#log))
end

-- ---------------------------------------------------------------------------
-- Regression: a non-crossing change must not read as a boundary
-- ---------------------------------------------------------------------------

do
    local engine = newEngine()
    local service = engine.service
    local log = {}
    service.subscribe('x', repairer(engine, log))
    engine.setMode('Preview')                 -- not a first-person crossing
    engine.runFrames(20)
    local looksLikeBoundary = false
    for _, entry in ipairs(log) do
        if entry.mode ~= entry.previous then looksLikeBoundary = true end
    end
    behaviour('P7', 'a non-crossing change never reads as a boundary',
              not looksLikeBoundary and engine.rebuilds == 0,
              ('%d notices, %d rebuilds, looksLikeBoundary=%s')
              :format(#log, engine.rebuilds, tostring(looksLikeBoundary)))
end

-- ---------------------------------------------------------------------------
-- PAUSE, and the lifecycle entries (items 1 and 11)
-- ---------------------------------------------------------------------------

do -- P8: paused time does not drain timers, and the work is not lost either
    local engine = newEngine()
    local log = {}
    engine.service.subscribe('p', repairer(engine, log))
    engine.paused = true
    engine.runFrames(120)                 -- 2s of paused frames
    local duringPause = #log
    engine.paused = false
    engine.runFrames(40)
    behaviour('P8', 'a pause defers delivery without losing it',
              duringPause == 0 and #log >= 1,
              duringPause .. ' notice(s) while paused, ' .. #log .. ' after unpausing')
end

do -- P9: a crossing that happens while paused is still reported once play resumes
    local engine = newEngine()
    local log = {}
    engine.service.subscribe('p', repairer(engine, log))
    engine.runFrames(30)
    local base = #log
    engine.paused = true
    engine.setMode('FirstPerson')
    engine.runFrames(120)
    local duringPause = #log - base
    engine.paused = false
    engine.runFrames(40)
    local after = #log - base
    behaviour('P9', 'a crossing during a pause is reported after it',
              duringPause == 0 and after == 1,
              duringPause .. ' while paused, ' .. after .. ' total after resuming')
end

do -- P10: onInit is the new-script-in-an-existing-save entry (item 11's gate)
    local engine = newEngine()
    local log = {}
    engine.service.subscribe('p', repairer(engine, log))
    engine.runFrames(30)
    local base = #log
    engine.call(engine.loaded.engineHandlers.onInit)
    engine.runFrames(40)
    local notices = #log - base
    local origin = log[#log] and log[#log].meta and log[#log].meta.origin
    behaviour('P10', 'onInit raises one reconciliation, labelled as a lifecycle cause',
              notices == 1 and origin == 'init',
              notices .. ' notice(s), origin=' .. tostring(origin))
end

do -- P11: item 3's gate - the originally observed mode survives into the metadata
    local engine = newEngine()
    local log = {}
    engine.service.subscribe('p', repairer(engine, log))
    engine.runFrames(30)
    engine.setMode('FirstPerson')
    engine.runFrames(30)
    local entry = log[#log]
    local m = entry and entry.meta
    behaviour('P11', 'metadata retains the mode observed when the cause was raised',
              m ~= nil and m.observedMode == 'FirstPerson'
              and m.observedPrevious == 'ThirdPerson',
              m and ('observedMode=' .. tostring(m.observedMode) ..
                     ' observedPrevious=' .. tostring(m.observedPrevious))
                or 'no metadata')
end

-- ---------------------------------------------------------------------------

print(('service: %s   (phase-accurate frame model)\n'):format(SERVICE))
print(('%-5s %-11s %-52s %-12s %s'):format('ID', 'KIND', 'CLAIM', 'RESULT', 'DETAIL'))
local open, ok, total = 0, 0, 0
for _, row in ipairs(results) do
    local verdict
    if row.kind == 'defect' then
        verdict = row.holds and 'REPRODUCED' or 'fixed'
        if row.holds then open = open + 1 end
    else
        total = total + 1
        verdict = row.holds and 'PASS' or 'FAIL'
        if row.holds then ok = ok + 1 end
    end
    print(('%-5s %-11s %-52s %-12s %s'):format(row.id, row.kind, row.claim, verdict, row.detail or ''))
end
print(('\ndefects still reproducing: %d    tranche-2 behaviour: %d/%d'):format(open, ok, total))
