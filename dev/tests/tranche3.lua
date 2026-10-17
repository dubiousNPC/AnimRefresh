--[[ Tranche 3 verification: item 5 (menu/race latch) and item 9 (metadata).

       python3 -I runlua.py tranche3.lua AnimRefresh_v5.lua
       python3 -I runlua.py tranche3.lua AnimRefresh_v6c.lua

     Extends tranche2.lua's phase-accurate frame model with a faithful UI mode stack,
     because item 5 is entirely about the shape of the UiModeChanged event and that shape
     is not guessable - it is read off files/data/scripts/omw/ui.lua and
     components/lua/scriptscontainer.cpp:

       * ui.lua:135  self:sendEvent('UiModeChanged', {oldMode=, newMode=, arg=})
         newMode is newStack[#newStack], i.e. the *top of the stack*, nil only when the
         stack is empty. oldMode is a module-level variable assigned at :136, AFTER the
         send, so it holds the previous top - the mode just popped.

       * mwgui/dialogue.cpp:453 and :462 push GM_Travel and GM_Training from inside the
         dialogue window, so the stack is {Dialogue, Travel} and closing the window pops
         to Dialogue. The event for that pop carries newMode == "Dialogue", never nil.
         Rest (mwinput/actionmanager.cpp:226) and Jail (windowmanagerimp.cpp:1545) are
         pushed over nothing, which is why only those two worked in v5.

       * ui.lua's own onUiModeChanged is an engine handler, and sendEvent to self queues
         the event, so it lands in a LATER frame's callEventHandlers (262) - after that
         frame's camera/model update at 302. The model reproduces that one-frame delay.

       * scriptscontainer.cpp:368-373 walks the handler list in REVERSE registration order
         and breaks when a handler returns exactly false. A throwing handler does not break
         it (each is individually wrapped). engine.suppressUiEvents models a later-loaded
         handler that returns false - the audit's G16.

     I.UI.modes is util.makeReadOnly(modeStack), which is zero-size USERDATA carrying
     __index/__len/__pairs (luastate.cpp:312-336). The stub therefore exposes a proxy whose
     __len and __pairs raise, so any reliance on them fails loudly here rather than in game.
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

local LATCHING = { Rest = true, Travel = true, Training = true,
                   Jail = true, ChargenRace = true }

-- The service resolves `print` as a global at call time, not at load time, so the capture
-- has to stay installed for the whole run rather than only while the chunk is loading.
local realPrint = print
local printSink = nil
_G.print = function(...)
    if printSink == nil then return realPrint(...) end
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    printSink[#printSink + 1] = table.concat(parts, ' ')
end

local function newEngine()
    local engine = {
        clock = 0, frame = 0, timers = {},
        mode = 'ThirdPerson', queued = nil,
        pendingRebuild = false,
        upperBodyBusy = false,
        generation = 1,
        rebuilds = 0,
        uiStack = {},
        uiOldMode = nil,
        suppressUiEvents = false,
        events = {},
        prints = {},
    }

    local MODE = { FirstPerson = 'FirstPerson', ThirdPerson = 'ThirdPerson',
                   Static = 'Static', Preview = 'Preview', Vanity = 'Vanity' }

    local function setMode(newMode)
        if engine.mode == newMode then engine.queued = nil; return end
        local crossing = (newMode == MODE.FirstPerson or engine.mode == MODE.FirstPerson)
        if crossing and engine.upperBodyBusy then
            engine.queued = newMode
            return
        end
        engine.mode = newMode
        engine.queued = nil
        if crossing then engine.pendingRebuild = true end
    end
    engine.setMode = setMode

    -- The read-only view ui.lua publishes. Only __index is supported on purpose.
    local modesProxy = setmetatable({}, {
        __index = function(_, k) return engine.uiStack[k] end,
        __len   = function() error('I.UI.modes is userdata: # is not reliable', 2) end,
        __pairs = function() error('I.UI.modes is userdata: pairs is not reliable', 2) end,
    })

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
    package.loaded['openmw.interfaces'] = { UI = { modes = modesProxy } }

    printSink = engine.prints
    local chunk = assert(loadfile(SERVICE))
    local ok, loaded = pcall(chunk)
    engine.loaded = ok and loaded or nil
    engine.service = engine.loaded and engine.loaded.interface or nil

    local function call(fn, ...)
        if fn == nil then return nil end
        local success, a = pcall(fn, ...)
        if not success then engine.lastError = a; return nil end
        return a
    end
    engine.call = call

    -- ui.lua's onUiModeChanged: recompute the top, send, then advance oldMode.
    local function sendUiModeChanged()
        local mode = engine.uiStack[#engine.uiStack]
        local data = { oldMode = engine.uiOldMode, newMode = mode, arg = nil }
        engine.uiOldMode = mode
        if engine.suppressUiEvents then return end
        -- sendEvent to self is queued, so it is delivered in a later frame's phase 262.
        engine.events[#engine.events + 1] = { at = engine.frame + 1, data = data }
    end

    -- Input phase (203), i.e. before the model update at 302.
    function engine.pushUi(mode)
        engine.uiStack[#engine.uiStack + 1] = mode
        sendUiModeChanged()
    end

    function engine.popUi()
        local gone = engine.uiStack[#engine.uiStack]
        engine.uiStack[#engine.uiStack] = nil
        -- Leaving a rebuilding menu is what rebuilds the model.
        if LATCHING[gone] then engine.pendingRebuild = true end
        sendUiModeChanged()
    end

    -- For the case the event stream never covered: a stack that is already populated
    -- when this script or a subscriber comes up. No events are sent at all.
    function engine.seedUiStackSilently(...)
        for _, mode in ipairs({ ... }) do
            engine.uiStack[#engine.uiStack + 1] = mode
            engine.uiOldMode = mode
        end
    end

    function engine.runFrame(dt)
        dt = dt or (1 / 60)
        engine.frame = engine.frame + 1
        engine.clock = engine.clock + dt

        -- 302: mWorld->update
        if engine.pendingRebuild then
            engine.pendingRebuild = false
            engine.generation = engine.generation + 1
            engine.rebuilds = engine.rebuilds + 1
        end
        if engine.queued ~= nil and not engine.upperBodyBusy then
            local wanted = engine.queued
            engine.queued = nil
            setMode(wanted)
        end

        -- 255: processTimers, as a while loop over the heap
        local guard = 0
        while true do
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
            call(timer.fn)
        end

        -- 262: callEventHandlers
        local due, keep = {}, {}
        for _, event in ipairs(engine.events) do
            if event.at <= engine.frame then due[#due + 1] = event
            else keep[#keep + 1] = event end
        end
        engine.events = keep
        for _, event in ipairs(due) do
            if engine.loaded and engine.loaded.eventHandlers then
                engine.lastEventReturn =
                    call(engine.loaded.eventHandlers.UiModeChanged, event.data)
            end
        end

        -- 275: onUpdate
        if engine.loaded and engine.loaded.engineHandlers then
            call(engine.loaded.engineHandlers.onUpdate, dt)
        end
    end

    function engine.runFrames(n, dt)
        for _ = 1, (n or 1) do engine.runFrame(dt) end
    end

    return engine
end

-- Records what it was told and which skeleton generation was live at the time.
local function recorder(engine, log)
    return function(mode, previous, meta)
        log[#log + 1] = { mode = mode, previous = previous, meta = meta,
                          generation = engine.generation, frame = engine.frame }
    end
end

-- Subscribe and let the join reconcile land, so later counts are about the menu alone.
local function settled(engine, log, key)
    engine.service.subscribe(key or 'k', recorder(engine, log))
    engine.runFrames(30)
    return #log
end

-- ---------------------------------------------------------------------------
-- ITEM 5
-- ---------------------------------------------------------------------------

-- A menu pushed from dialogue, closed back through dialogue, then dialogue closed.
local function runNestedMenu(engine, menu)
    engine.pushUi('Dialogue');  engine.runFrames(3)
    engine.pushUi(menu);        engine.runFrames(3)
    engine.popUi();             engine.runFrames(3)   -- -> Dialogue
    engine.popUi();             engine.runFrames(20)  -- -> gameplay
end

do -- G1 / T13: Training
    local engine = newEngine()
    local log = {}
    local base = settled(engine, log)
    runNestedMenu(engine, 'Training')
    local notices = #log - base
    defect('G1', 'Training closes through Dialogue and is missed',
           notices == 0, notices .. ' notice(s) for the Training rebuild')
    behaviour('T13', 'Training produces exactly one eligible episode',
              notices == 1, notices .. ' notice(s)')
    local last = log[#log]
    behaviour('T13b', 'the repair lands on the post-rebuild skeleton',
              notices == 1 and last.generation == engine.generation,
              notices == 1 and ('repaired generation ' .. last.generation ..
                                ', now ' .. engine.generation) or 'no notice to check')
end

do -- G1b: exterior Travel, the same shape
    local engine = newEngine()
    local log = {}
    local base = settled(engine, log)
    runNestedMenu(engine, 'Travel')
    local notices = #log - base
    defect('G1b', 'exterior Travel closes through Dialogue and is missed',
           notices == 0, notices .. ' notice(s) for the Travel rebuild')
    behaviour('T14', 'Travel produces exactly one eligible episode',
              notices == 1, notices .. ' notice(s)')
end

do -- T15: Rest, which v5 already handled - check it is not regressed
    local engine = newEngine()
    local log = {}
    local base = settled(engine, log)
    engine.pushUi('Rest'); engine.runFrames(3)
    engine.popUi();        engine.runFrames(20)
    local notices = #log - base
    behaviour('T15', 'Rest still produces exactly one episode',
              notices == 1, notices .. ' notice(s)')
end

do -- T16: ChargenRace
    local engine = newEngine()
    local log = {}
    local base = settled(engine, log)
    engine.pushUi('ChargenRace'); engine.runFrames(3)
    engine.popUi();               engine.runFrames(20)
    local notices = #log - base
    behaviour('T16', 'ChargenRace produces exactly one episode',
              notices == 1, notices .. ' notice(s)')
end

do -- T17: a non-rebuilding menu must produce nothing
    local engine = newEngine()
    local log = {}
    local base = settled(engine, log)
    engine.pushUi('Journal'); engine.runFrames(3)
    engine.popUi();           engine.runFrames(20)
    local notices = #log - base
    behaviour('T17', 'a non-rebuilding menu produces nothing',
              notices == 0, notices .. ' notice(s)')
end

do -- T18: a subscription created while Training is already open still gets the notice
    local engine = newEngine()
    engine.pushUi('Dialogue'); engine.runFrames(2)
    engine.pushUi('Training'); engine.runFrames(2)   -- no subscribers yet
    local log = {}
    local base = settled(engine, log)
    engine.popUi(); engine.runFrames(3)
    engine.popUi(); engine.runFrames(20)
    local notices = #log - base
    behaviour('T18', 'a subscription created with a menu already open works',
              notices == 1, notices .. ' notice(s) after joining mid-menu')
end

do -- T18b: the same, but the push events were never observed at all
    local engine = newEngine()
    engine.seedUiStackSilently('Dialogue', 'Training')
    local log = {}
    local base = settled(engine, log)
    engine.popUi(); engine.runFrames(3)
    engine.popUi(); engine.runFrames(20)
    local notices = #log - base
    behaviour('T18b', 'a stack populated before the script loaded is still latched',
              notices == 1, notices .. ' notice(s) with no push event ever sent')
end

do -- T19: the latch is cleared once consumed
    local engine = newEngine()
    local log = {}
    local base = settled(engine, log)
    engine.pushUi('Rest'); engine.runFrames(3)
    engine.popUi();        engine.runFrames(20)
    local afterRest = #log - base
    engine.pushUi('Journal'); engine.runFrames(3)
    engine.popUi();           engine.runFrames(20)
    local total = #log - base
    behaviour('T19', 'the latch is cleared once consumed',
              afterRest == 1 and total == 1,
              'after Rest ' .. afterRest .. ', after a later Journal ' .. total)
end

do -- P8: a later-loaded handler returning false starves the event (G16)
    local engine = newEngine()
    local log = {}
    local base = settled(engine, log)
    engine.suppressUiEvents = true
    engine.pushUi('Dialogue'); engine.runFrames(3)
    engine.pushUi('Training'); engine.runFrames(3)
    engine.popUi();            engine.runFrames(3)
    engine.popUi();            engine.runFrames(20)
    local notices = #log - base
    defect('G16', 'a later-loaded handler returning false starves the menu notice',
           notices == 0, notices .. ' notice(s) with UiModeChanged suppressed')
    behaviour('T20', 'the poll backstop survives a suppressed UiModeChanged',
              notices == 1, notices .. ' notice(s) with the event suppressed')
end

do -- T21: this script must never break the handler chain for earlier handlers
    local engine = newEngine()
    local log = {}
    settled(engine, log)
    local handler = engine.loaded.eventHandlers.UiModeChanged
    local shapes = {
        { oldMode = nil,        newMode = 'Rest' },
        { oldMode = 'Rest',     newMode = nil    },
        { oldMode = 'Training', newMode = 'Dialogue' },
        { oldMode = 'Journal',  newMode = nil    },
        {},
    }
    local offender = nil
    for index, data in ipairs(shapes) do
        if engine.call(handler, data) == false then offender = index end
    end
    behaviour('T21', 'the UiModeChanged handler never returns false',
              offender == nil,
              offender and ('shape ' .. offender .. ' returned false')
                        or 'no shape returned false')
end

do -- T22: nil event data must not raise
    local engine = newEngine()
    local log = {}
    settled(engine, log)
    engine.lastError = nil
    engine.call(engine.loaded.eventHandlers.UiModeChanged, nil)
    behaviour('T22', 'nil event data does not raise',
              engine.lastError == nil, tostring(engine.lastError))
end

-- ---------------------------------------------------------------------------
-- ITEM 9
-- ---------------------------------------------------------------------------

do -- T23: every cause is identifiable
    local engine = newEngine()
    local log = {}
    engine.service.subscribe('m', recorder(engine, log), { verify = true })
    engine.runFrames(30)
    local join = log[#log]

    engine.setMode('FirstPerson')
    engine.runFrames(10)
    local boundary = log[#log]

    engine.runFrames(240)                       -- let verification land (see tranche1 T8)
    local verify = log[#log]

    engine.service.refreshNow('vfx reattached')
    engine.runFrames(10)
    local manual = log[#log]

    engine.pushUi('Rest'); engine.runFrames(3)
    engine.popUi();        engine.runFrames(20)
    local menu = log[#log]

    local function reason(entry) return entry and entry.meta and entry.meta.reason end
    local function origin(entry) return entry and entry.meta and entry.meta.origin end

    local got = table.concat({
        tostring(reason(join)) .. '/' .. tostring(origin(join)),
        tostring(reason(boundary)) .. '/' .. tostring(origin(boundary)),
        tostring(reason(verify)) .. '/' .. tostring(origin(verify)),
        tostring(reason(manual)) .. '/' .. tostring(origin(manual)),
        tostring(reason(menu)) .. '/' .. tostring(origin(menu)),
    }, ' ')

    local ok = reason(join) == 'reconcile'  and origin(join) == 'subscribe'
           and reason(boundary) == 'boundary' and origin(boundary) == 'poll'
           and reason(verify) == 'verify'
           and reason(manual) == 'manual'   and origin(manual) == 'api'
           and reason(menu) == 'menu'
    behaviour('T23', 'metadata identifies every cause', ok, got)

    behaviour('T23b', 'a manual refresh carries the caller detail',
              manual and manual.meta and manual.meta.detail == 'vfx reattached',
              tostring(manual and manual.meta and manual.meta.detail))
    behaviour('T23c', 'a menu episode names the latched mode',
              menu and menu.meta and menu.meta.detail == 'Rest',
              tostring(menu and menu.meta and menu.meta.detail))
    behaviour('T23d', 'a verification is a follow-up to its boundary, not a new cause',
              verify and boundary and verify.meta and boundary.meta
              and verify.meta.cause == boundary.meta.cause
              and verify.meta.episode ~= boundary.meta.episode,
              verify and boundary and verify.meta and boundary.meta
              and ('boundary episode ' .. tostring(boundary.meta.episode) ..
                   ' cause ' .. tostring(boundary.meta.cause) ..
                   ', verify episode ' .. tostring(verify.meta.episode) ..
                   ' cause ' .. tostring(verify.meta.cause)) or 'missing metadata')
end

do -- T24: metadata is a fresh snapshot per delivery
    local engine = newEngine()
    local seen = {}
    local vandal = function(_, _, meta)
        if type(meta) ~= 'table' then return end
        meta.reason = 'TAMPERED'
        meta.injected = true
        seen.vandalMeta = meta
    end
    local victim = function(_, _, meta)
        seen.victimReason = meta and meta.reason
        seen.victimInjected = meta and meta.injected
        seen.victimMeta = meta
    end
    engine.service.subscribe('a_vandal', vandal)
    engine.service.subscribe('z_victim', victim)
    engine.runFrames(40)

    local distinct = seen.vandalMeta ~= nil and seen.victimMeta ~= nil
                     and seen.vandalMeta ~= seen.victimMeta
    local clean = seen.victimReason == 'reconcile' and seen.victimInjected == nil
    behaviour('T24', 'one subscriber cannot affect another through metadata',
              distinct and clean,
              'distinct tables=' .. tostring(distinct) ..
              ' victim reason=' .. tostring(seen.victimReason) ..
              ' injected=' .. tostring(seen.victimInjected))
end

do -- T25: attempt increments across retries
    local engine = newEngine()
    local attempts = {}
    engine.service.subscribe('retry', function(_, _, meta)
        attempts[#attempts + 1] = meta and meta.attempt
        -- Not `#attempts < 3 and false or nil`: that expression is always nil, because
        -- `false or nil` is nil. It silently asked for no retry at all.
        if #attempts < 3 then return false end
        return nil
    end)
    engine.runFrames(60)
    local shape = table.concat({ tostring(attempts[1]), tostring(attempts[2]),
                                 tostring(attempts[3]) }, ',')
    behaviour('T25', 'meta.attempt counts retries of one episode',
              shape == '0,1,2', shape)
end

do -- T26: a two-argument consumer is unaffected
    local engine = newEngine()
    local got = {}
    -- Declared with exactly two parameters, as a v5-era consumer would be.
    engine.service.subscribe('legacy', function(mode, previousMode)
        got[#got + 1] = tostring(mode) .. '/' .. tostring(previousMode)
    end)
    engine.runFrames(30)
    engine.setMode('FirstPerson')
    engine.runFrames(20)
    behaviour('T26', 'an unchanged two-argument consumer still works',
              #got == 2 and got[1] == 'ThirdPerson/ThirdPerson'
              and got[2] == 'FirstPerson/ThirdPerson',
              table.concat(got, '  '))
end

do -- T27: refreshNow rejects a bad detail loudly without refusing the refresh
    local engine = newEngine()
    local log = {}
    local base = settled(engine, log)
    local before = #engine.prints
    engine.service.refreshNow(42)
    engine.runFrames(20)
    local complained = false
    for i = before + 1, #engine.prints do
        if engine.prints[i]:find('refreshNow', 1, true) then complained = true end
    end
    local notices = #log - base
    behaviour('T27', 'a bad refreshNow detail is reported and the refresh still happens',
              complained and notices == 1,
              'complained=' .. tostring(complained) .. ' notices=' .. notices)
end

-- ---------------------------------------------------------------------------

printSink = nil
print(('service: %s\n'):format(SERVICE))
print(('%-5s %-12s %-54s %s'):format('ID', 'KIND', 'CLAIM', 'RESULT'))
local defects, pass, total = 0, 0, 0
for _, row in ipairs(results) do
    local verdict
    if row.kind == 'defect' then
        verdict = row.holds and 'REPRODUCED' or 'fixed'
        if row.holds then defects = defects + 1 end
    else
        verdict = row.holds and 'PASS' or 'FAIL'
        total = total + 1
        if row.holds then pass = pass + 1 end
    end
    print(('%-5s %-12s %-54s %-11s %s'):format(
        row.id, row.kind, row.claim, verdict, tostring(row.detail)))
end
print(('\ndefects still reproducing: %d    tranche-3 behaviour: %d/%d')
      :format(defects, pass, total))
