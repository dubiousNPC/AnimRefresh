--[[ Tranche 4 verification: item 10 (verification) and item 13 (handover).

       python3 -I runlua.py tranche4.lua AnimRefresh_v6c.lua
       python3 -I runlua.py tranche4.lua AnimRefresh_v5.lua          # the baseline

     Item 13 is about two providers cooperating, so this harness can create a service and
     then hand it a *second* interface to displace, which the earlier harnesses never did.
     The engine facts it relies on, all from components/lua/scriptscontainer.cpp:

       * :283  addInterface publishes only when no later script publishes the same name, so
               the HIGHEST SCRIPT ID wins - publication is load order, not version.
       * :265  onInterfaceOverride is called on the new script with *prev->mInterface*, the
               interface being displaced. That is item 13's "recipient passed directly".
       * :153  onInterfaceOverride is extracted before the unsupported-name check at :157,
               so it is an accepted engineHandlers key (unlike v4's UiModeChanged).

     The displaced provider is modelled two ways, because what is achievable differs
     completely: a v5-shaped one that cannot enumerate or stop itself, and a retire-capable
     one. The gate is explicit that only per-key de-duplication is possible against v5.
]]

local SERVICE = (...) or error('no service given. Usage: python3 -I runlua.py <harness>.lua <AnimRefresh>.lua', 0)

-- The service resolves `print` as a global at CALL time, so a capture installed only
-- around loadfile misses everything said later - which hid two of item 13's diagnostics
-- on the first run of this harness. tranche3.lua had the identical bug.
local realPrint = print
local printSink = nil
_G.print = function(...)
    if printSink == nil then return realPrint(...) end
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    printSink[#printSink + 1] = table.concat(parts, ' ')
end

local results = {}
local function behaviour(id, claim, ok, detail)
    results[#results + 1] = { id = id, kind = 'behaviour', claim = claim,
                              holds = ok, detail = detail }
end

-- ---------------------------------------------------------------------------

local function newEngine(preexistingInterface)
    local engine = { timers = {}, mode = 'ThirdPerson', queued = nil, clock = 0,
                     prints = {} }

    package.loaded['openmw.camera'] = {
        MODE = { FirstPerson = 'FirstPerson', ThirdPerson = 'ThirdPerson',
                 Static = 'Static', Preview = 'Preview', Vanity = 'Vanity' },
        getMode = function() return engine.mode end,
        getQueuedMode = function() return engine.queued end,
    }
    package.loaded['openmw.async'] = {
        newUnsavableSimulationTimer = function(_, delay, fn)
            table.insert(engine.timers, { at = engine.clock + delay, fn = fn })
        end,
    }
    package.loaded['openmw.interfaces'] = { AnimRefresh = preexistingInterface }

    printSink = engine.prints
    local chunk = assert(loadfile(SERVICE))
    local ok, loaded = pcall(chunk)
    engine.loaded = ok and loaded or nil
    engine.loadError = (not ok) and loaded or nil
    engine.service = engine.loaded and engine.loaded.interface or nil

    local function call(fn, ...)
        if fn == nil then return nil end
        local success, value = pcall(fn, ...)
        if not success then engine.lastError = value; return nil end
        return value
    end
    engine.call = call

    -- A service may legitimately publish nothing (it stood down). Reaching for a handler
    -- then should report that, not abort the whole harness.
    function engine.handler(name)
        if engine.loaded == nil or engine.loaded.engineHandlers == nil then return nil end
        return engine.loaded.engineHandlers[name]
    end

    function engine.advance(dt)
        engine.clock = engine.clock + dt
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
            call(table.remove(engine.timers, pick).fn)
        end
        if engine.loaded and engine.loaded.engineHandlers then
            call(engine.loaded.engineHandlers.onUpdate, dt)
        end
    end

    function engine.settle(n)
        for _ = 1, (n or 3) do engine.advance(0.05) end
    end

    function engine.said(fragment)
        for _, line in ipairs(engine.prints) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    return engine
end

-- A displaced provider. `canRetire` decides whether it is v6-shaped (a real handover is
-- possible) or v5-shaped (only per-key de-duplication is).
local function fakeProvider(version, canRetire, record)
    local own = {}
    local provider = {
        version = version,
        subscribe = function(key, callback, opts)
            own[key] = { callback = callback, opts = opts }
            record[#record + 1] = 'their subscribe ' .. tostring(key)
        end,
        unsubscribe = function(key)
            own[key] = nil
            record[#record + 1] = 'their unsubscribe ' .. tostring(key)
        end,
        refreshNow = function() record[#record + 1] = 'their refreshNow' end,
        getMode = function() return 'ThirdPerson' end,
        isFirstPerson = function() return false end,
    }
    if canRetire then
        provider.retire = function(successor)
            record[#record + 1] = 'their retire'
            provider.retireCalls = (provider.retireCalls or 0) + 1
            for key, entry in pairs(own) do
                successor.subscribe(key, entry.callback, entry.opts)
            end
            own = {}
        end
    end
    provider.registrations = own
    return provider
end

-- ---------------------------------------------------------------------------
-- ITEM 10
-- ---------------------------------------------------------------------------

do -- V1: a subscriber's own verifyDelay is honoured instead of the service default
    local engine = newEngine()
    local hits = {}
    engine.service.subscribe('quick', function(_, _, meta)
        hits[#hits + 1] = { at = engine.clock, reason = meta and meta.reason }
    end, { verify = true, verifyDelay = 0.3 })
    engine.settle()
    local base = #hits
    engine.mode = 'FirstPerson'
    engine.advance(0.2)                       -- detected here...
    engine.advance(0.05)                      -- ...delivered here (item 1's deferral)
    local afterBoundary = #hits
    engine.advance(0.35)                      -- past its own 0.3s, far short of 1.8s
    local afterOwnDelay = #hits
    local reason = hits[#hits] and hits[#hits].reason
    behaviour('V1', 'a subscriber-supplied verifyDelay is used, not the default',
              afterBoundary == base + 1 and afterOwnDelay == base + 2
              and reason == 'verify',
              ('boundary=%d ownDelay=%d lastReason=%s')
              :format(afterBoundary - base, afterOwnDelay - base, tostring(reason)))
end

do -- V2: two verifiers with different delays each get their own, in order
    local engine = newEngine()
    local order = {}
    engine.service.subscribe('slow', function(_, _, m)
        if m and m.reason == 'verify' then order[#order + 1] = 'slow' end
    end, { verify = true, verifyDelay = 1.0 })
    engine.service.subscribe('fast', function(_, _, m)
        if m and m.reason == 'verify' then order[#order + 1] = 'fast' end
    end, { verify = true, verifyDelay = 0.3 })
    engine.settle()
    engine.mode = 'FirstPerson'
    engine.advance(0.2)
    engine.advance(2.0)
    behaviour('V2', 'each verifier gets its own delay, independently',
              #order == 2 and order[1] == 'fast' and order[2] == 'slow',
              table.concat(order, ' then '))
end

do -- V3: a bad verifyDelay is rejected before anything is written (item 8's discipline)
    local engine = newEngine()
    local ran = false
    local ok = pcall(engine.service.subscribe, 'bad', function() ran = true end,
                     { verify = true, verifyDelay = -1 })
    local ok2 = pcall(engine.service.subscribe, 'bad2', function() end,
                      { verify = true, verifyDelay = 'soon' })
    engine.settle()
    engine.mode = 'FirstPerson'
    engine.advance(0.5)
    behaviour('V3', 'a malformed verifyDelay is rejected and leaves no registration',
              not ok and not ok2 and not ran,
              ('negative rejected=%s non-number rejected=%s callback ran=%s')
              :format(tostring(not ok), tostring(not ok2), tostring(ran)))
end

do -- V4: a verification still obeys item 3 - unsubscribing cancels it
    local engine = newEngine()
    local verifies = 0
    engine.service.subscribe('leaver', function(_, _, m)
        if m and m.reason == 'verify' then verifies = verifies + 1 end
    end, { verify = true, verifyDelay = 0.5 })
    engine.settle()
    engine.mode = 'FirstPerson'
    engine.advance(0.2)
    engine.service.unsubscribe('leaver')      -- the action expired before verification
    engine.advance(2.0)
    behaviour('V4', 'a verification never arrives after its subscriber left',
              verifies == 0, verifies .. ' verification(s) after unsubscribe')
end

-- ---------------------------------------------------------------------------
-- ITEM 13
-- ---------------------------------------------------------------------------

-- Item 13 needs a cooperating pair, so a service lacking the protocol cannot be put
-- through any of it. Report that once rather than aborting the run: a harness that dies on
-- the baseline is no use for comparison, which is the whole point of keeping v5 around.
local probe = newEngine()
if probe.service == nil or type(probe.service.retire) ~= 'function' then
    local why = probe.service == nil
        and 'the service published no interface (it stood down for the pre-existing provider)'
        or 'the interface has no retire(): item 13 is not implemented in this build'
    for _, id in ipairs({ 'H1','H2','H2b','H3','H4','H5','H6','H7','H8' }) do
        behaviour(id, 'item 13 handover protocol', false, why)
    end
else

do -- H1: against a retire-capable provider, registrations transfer exactly once.
   -- Version 5 deliberately: a provider reporting 6 or higher makes this build stand down
   -- without publishing at all (correctly), so there is no override to test. The real v5
   -- has no retire(); this models any pre-6 provider that implements the protocol, because
   -- what is under test is the protocol and not v5's possession of it.
    local record = {}
    local previous = fakeProvider(5, true, record)
    local moved = {}
    previous.subscribe('theirs', function() moved[#moved + 1] = 'theirs' end,
                       { verify = true })
    local engine = newEngine(previous)
    engine.call(engine.handler('onInterfaceOverride'), previous)
    -- the transferred registration must now be live HERE: its join reconcile proves it
    engine.settle(6)
    local transferred = #moved
    engine.call(engine.handler('onInterfaceOverride'), previous)
    engine.settle(6)
    behaviour('H1', 'a retire-capable provider hands over, once',
              previous.retireCalls == 1 and transferred >= 1,
              ('retire called %s time(s), transferred registration notified %d time(s)')
              :format(tostring(previous.retireCalls), transferred))
end

do -- H2: against a v5-shaped provider, only known-key de-duplication happens
    local record = {}
    local previous = fakeProvider(5, false, record)
    local engine = newEngine(previous)
    engine.call(engine.handler('onInterfaceOverride'), previous)
    engine.service.subscribe('shared', function() end)
    engine.settle()
    local deduped = false
    for _, line in ipairs(record) do
        if line == 'their unsubscribe shared' then deduped = true end
    end
    behaviour('H2', 'a v5-shaped provider gets per-key unsubscribe as keys arrive',
              deduped, table.concat(record, ', '))
    behaviour('H2b', 'and the unfixable residue is stated, not hidden',
              engine.said('item 13') or engine.said('G12'),
              engine.said('G12') and 'G12 named in the log' or 'not stated')
end

do -- H3: retiring this build moves its registrations and silences it
    local record = {}
    local engine = newEngine()
    local notices = 0
    engine.service.subscribe('mine', function() notices = notices + 1 end,
                             { verify = true, verifyDelay = 0.4 })
    engine.settle()
    local successor = fakeProvider(7, false, record)
    engine.service.retire(successor)
    local handed = successor.registrations['mine'] ~= nil
    notices = 0
    engine.mode = 'FirstPerson'
    engine.advance(0.2); engine.advance(2.0)
    behaviour('H3', 'retire() transfers registrations and stops all further delivery',
              handed and notices == 0,
              ('handed over=%s, notices after retiring=%d'):format(tostring(handed), notices))
end

do -- H4: a cached reference to the retired interface keeps working
    local record = {}
    local engine = newEngine()
    local cached = engine.service              -- a consumer kept this from before
    local successor = fakeProvider(7, false, record)
    engine.service.retire(successor)
    cached.subscribe('late', function() end)
    cached.unsubscribe('late')
    cached.refreshNow('from a cached reference')
    local forwarded = 0
    for _, line in ipairs(record) do
        if line:find('their ', 1, true) then forwarded = forwarded + 1 end
    end
    behaviour('H4', 'cached references forward to the successor after retirement',
              forwarded == 3, table.concat(record, ', '))
end

do -- H5: a second retire is a no-op, and a useless successor is refused
    local record = {}
    local engine = newEngine()
    engine.service.subscribe('mine', function() end)
    engine.settle()
    local first  = fakeProvider(7, false, record)
    local second = fakeProvider(8, false, record)
    engine.service.retire(first)
    engine.service.retire(second)
    local onlyFirst = first.registrations['mine'] ~= nil
                      and second.registrations['mine'] == nil
    local engine2 = newEngine()
    engine2.service.subscribe('still', function() end)
    engine2.service.retire({})                 -- no subscribe(): must be refused
    engine2.settle()
    local refused = engine2.said('needs a successor')
    behaviour('H5', 'retirement happens once, and a successor without subscribe is refused',
              onlyFirst and refused,
              ('transferred to the first only=%s, bad successor refused=%s')
              :format(tostring(onlyFirst), tostring(refused)))
end

do -- H6: the displaced interface is never compared or type-checked (gate: raw equality
   -- is invalid). A userdata-like proxy with only __index must be accepted.
    local record = {}
    local inner = fakeProvider(5, false, record)
    local proxy = setmetatable({}, {
        __index = function(_, k) return inner[k] end,
        __eq = function() error('the gate says raw proxy equality is invalid', 2) end,
        __len = function() error('not a table', 2) end,
        __pairs = function() error('not a table', 2) end,
    })
    local engine = newEngine(proxy)
    engine.lastError = nil
    engine.call(engine.handler('onInterfaceOverride'), proxy)
    engine.service.subscribe('viaproxy', function() end)
    engine.settle()
    local deduped = false
    for _, line in ipairs(record) do
        if line == 'their unsubscribe viaproxy' then deduped = true end
    end
    behaviour('H6', 'a userdata-like provider proxy is handled without equality or pairs',
              engine.lastError == nil and deduped,
              engine.lastError and tostring(engine.lastError) or 'no error; de-duplicated')
end

do -- H7: onInterfaceOverride(nil) must not raise
    local engine = newEngine()
    engine.lastError = nil
    engine.call(engine.handler('onInterfaceOverride'), nil)
    behaviour('H7', 'onInterfaceOverride tolerates a nil predecessor',
              engine.lastError == nil, tostring(engine.lastError))
end

do -- H8: a non-numeric foreign version must not break the override path either
    local record = {}
    local previous = fakeProvider('five', false, record)
    local engine = newEngine()
    engine.lastError = nil
    engine.call(engine.handler('onInterfaceOverride'), previous)
    behaviour('H8', 'a non-numeric foreign version does not break the override path',
              engine.lastError == nil, tostring(engine.lastError))
end


end

-- ---------------------------------------------------------------------------
-- SANDBOX
-- ---------------------------------------------------------------------------

do -- S1: the service must write no globals. OpenMW sandboxes the environment, and a
   -- stray global is both a bug and a sandbox violation - worth a real check rather than
   -- a grep, since `PUBLISHED` was an accidental global for one revision of this file.
    local engine = newEngine()
    local written = {}
    local strict = setmetatable({}, {
        __index = _G,
        __newindex = function(_, k, v) written[#written + 1] = tostring(k)
                                       rawset(_G, k, v) end,
    })
    local chunk = assert(loadfile(SERVICE, 't', strict))
    pcall(chunk)
    behaviour('S1', 'the service writes no global variables',
              #written == 0,
              #written == 0 and 'none' or ('wrote ' .. table.concat(written, ', ')))
end

-- ---------------------------------------------------------------------------

printSink = nil
print(('service: %s\n'):format(SERVICE))
print(('%-5s %-12s %-56s %s'):format('ID', 'KIND', 'CLAIM', 'RESULT'))
local pass, total = 0, 0
for _, row in ipairs(results) do
    total = total + 1
    if row.holds then pass = pass + 1 end
    print(('%-5s %-12s %-56s %-6s %s'):format(
        row.id, row.kind, row.claim, row.holds and 'PASS' or 'FAIL', tostring(row.detail)))
end
print(('\ntranche-4 behaviour: %d/%d'):format(pass, total))
