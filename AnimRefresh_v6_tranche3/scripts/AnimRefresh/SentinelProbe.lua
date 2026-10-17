---@omw-context player
--[[ SentinelProbe v3 - TWO sentinels, to settle what the first two runs could not.

     THIS IS A DIAGNOSTIC, NOT A MOD. Install it, play, read the log, remove it.

     WHAT RUNS 1 AND 2 ESTABLISHED
     Run 2 (22:28-22:50, 45 losses) was decisive on the positive side:
       * 41 of 45 losses paired EXACTLY with a change in animation.hasBone on a witness
         bone - a direct, player-specific read of the live skeleton. No false positives.
       * 8 of 8 save loads reported the sentinel cleared.
       * 4 losses had no rig swap: two at an inventory (Interface) close, two during weapon
         stance activity in first person. Those are rebuild causes camera-mode inference
         CANNOT see, which is the strongest argument for a sentinel at all.

     And decisive on the negative side:
       * 0 of 5 rebuilding-menu closes (Rest x2, Travel x2, Training x1) cleared it. The one
         loss 0.54s after a Rest close also had a simultaneous rig swap, which fully
         explains it on its own.

     THE QUESTION THIS VERSION ANSWERS
     A sentinel surviving means Animation::clearAnimSources() did not run. It does NOT mean
     a consumer's animation survived, because there is a second way to lose one:
     Animation::play erases every other state with an EQUAL AnimPriority
     (mwrender/animation.cpp:905-911, operator== over all four bone groups in
     mwrender/animationpriority.hpp:19-25).

     Sentinel A is deliberately immune to that sweep - its RightArm differs from its other
     three groups, and no engine-built AnimPriority does that (mwmechanics/character.cpp
     only ever mixes LowerBody and LeftArm, at :274, :454-455, :1356). That immunity is what
     made run 2 free of false positives. It is ALSO what makes A blind to the sweep. So A
     cannot distinguish "the menu did nothing" from "the menu swept states at an ordinary
     priority".

     Sentinel B is what a real consumer looks like: a uniform Priority_Scripted, the
     priority a mod-applied pose or VFX actually uses, and therefore sweepable.

     READ THE LOG FOR THIS, AT A Rest / Training / Travel CLOSE:
       B lost, A survived  -> the sweep is real. Item 5's latch is NECESSARY and no sentinel
                              can replace it, because the only sentinel that avoids false
                              positives is the one that cannot see the sweep.
       both survived       -> those menus genuinely do nothing to the player's animation
                              states, and item 5 is guarding a non-event. That would
                              simplify the fix list substantially.
       both lost           -> a full rebuild, which run 2 happened not to catch.

     B is expected to be noisier than A during ordinary play - anything else playing at
     Scripted will sweep it. That noise is the point: it is the same exposure a consumer has.
     Compare the two columns, not B's absolute count.
]]

local self      = require('openmw.self')
local animation = require('openmw.animation')
local camera    = require('openmw.camera')
local core      = require('openmw.core')
local I         = require('openmw.interfaces')

local POLL      = 0.1
local HEARTBEAT = 60

-- Two distinct groups are required: one group is one state, so two sentinels cannot share
-- one name. Both must exist on the player and neither should be played by the character
-- controller. Run 2 confirmed 'idle9' is safe for 22 minutes.
local CANDIDATES = { 'idle9', 'idle8', 'idle7', 'idle6',
                     'pickprobe', 'inventoryhandtohand', 'idlestorm' }

local WITNESS_BONE = 'Bip01 L Finger4'

local PRIORITY_UNIQUE = {
    [animation.BONE_GROUP.LowerBody] = animation.PRIORITY.Default,
    [animation.BONE_GROUP.Torso]     = animation.PRIORITY.Default,
    [animation.BONE_GROUP.LeftArm]   = animation.PRIORITY.Default,
    [animation.BONE_GROUP.RightArm]  = animation.PRIORITY.Scripted,
}

local sentinels = {
    { label = 'A-unique',   priority = PRIORITY_UNIQUE },
    -- A bare enum, not a table, so AnimPriority(Priority_Scripted) is uniform across all
    -- four bone groups - exactly what getPriorityArgument returns for a plain `priority`
    -- (mwlua/animationbindings.cpp:54-56) and what a consumer's own playBlended produces.
    { label = 'B-sweepable', priority = animation.PRIORITY.Scripted },
}

local started, pendingLoadCheck = false, false
local timer, heartbeatAt        = 0, 0
local lastBone                  = nil
local lastMenu, lastMenuGone    = nil, nil
local menuOpen, menuCloses      = false, 0

-- Run 3 showed B is swept about once every 10s by ordinary priority contention, which is
-- far too noisy to attribute a single coincidence to a menu. So the probe now does the
-- accounting itself: time and losses are split between the window just after a menu close
-- and everything else, and both rates are printed. A sweep at menu close has to show up as
-- a rate difference, not as one suggestive line.
local WINDOW    = 1.5
local winTime, winLossA, winLossB = 0, 0, 0
local bgTime,  bgLossA,  bgLossB  = 0, 0, 0

local MODE_NAME = {}
for name, value in pairs(camera.MODE) do MODE_NAME[value] = name end

local function modeText()
    local mode = camera.getMode()
    return (MODE_NAME[mode] or 'unknown') .. '(' .. tostring(mode) .. ')'
end

local function log(message) print('[SentinelProbe] ' .. message) end

local function menuContext()
    if lastMenu == nil then return 'lastMenu=none' end
    if lastMenuGone == nil then return 'lastMenu=' .. lastMenu .. ' STILL OPEN' end
    return ('lastMenu=%s closed %.2fs ago'):format(lastMenu,
            core.getSimulationTime() - lastMenuGone)
end

local REBUILDING = { Rest = true, Travel = true, Training = true,
                     Jail = true, ChargenRace = true }

local function uiStackText()
    local uiInterface = I.UI
    if uiInterface == nil then return '<no UI interface>' end
    local modes = uiInterface.modes
    if modes == nil then return '<no mode stack>' end
    -- userdata (util.makeReadOnly, luastate.cpp:312-336): index only, never # or pairs.
    local parts, index, seen = {}, 1, false
    while true do
        local mode = modes[index]
        if mode == nil then break end
        if REBUILDING[mode] then seen = true end
        parts[index] = mode
        index = index + 1
    end

    -- v3 bug: this tested `lastMenu ~= mode`, so reopening the SAME mode never re-latched
    -- and the following close was never logged. Every Rest after the first was invisible,
    -- and `lastMenuGone` went stale - producing lines that said `ui=Rest` and
    -- `lastMenu=Rest closed 7.29s ago` at once. Track open/closed as its own state instead
    -- of inferring it from the mode name.
    if seen and not menuOpen then
        menuOpen = true
        lastMenu, lastMenuGone = parts[index - 1], nil
        log('rebuilding menu OPEN: ' .. tostring(lastMenu) .. '  camera=' .. modeText())
    elseif not seen and menuOpen then
        menuOpen     = false
        lastMenuGone = core.getSimulationTime()
        menuCloses   = menuCloses + 1
        log(('rebuilding menu CLOSED: %s (close #%d) -- watch the next %.1fs')
            :format(tostring(lastMenu), menuCloses, WINDOW))
    end

    if index == 1 then return 'gameplay' end
    return table.concat(parts, '>')
end

local function chooseGroups()
    local found, rejected = {}, {}
    for _, candidate in ipairs(CANDIDATES) do
        if animation.hasGroup(self, candidate) then
            found[#found + 1] = candidate
            if #found == #sentinels then break end
        else
            rejected[#rejected + 1] = candidate
        end
    end
    if #found < #sentinels then
        log('FOUND ONLY ' .. #found .. ' usable group(s); this version needs ' ..
            #sentinels .. '. Rejected: ' .. table.concat(rejected, ', ') ..
            '. Add groups your animations provide to CANDIDATES.')
        return false
    end
    for index, sentinel in ipairs(sentinels) do
        sentinel.group = found[index]
        log(('sentinel %s -> group %q'):format(sentinel.label, sentinel.group))
    end
    return true
end

local function playOne(sentinel)
    sentinel.plays      = (sentinel.plays or 0) + 1
    sentinel.losses     = sentinel.losses or 0
    sentinel.cleanSince = core.getSimulationTime()
    animation.playBlended(self, sentinel.group, {
        priority    = sentinel.priority,
        blendMask   = 0,        -- affects no bones: visually inert
        autoDisable = false,
        loops       = 4294967295,
        forceLoop   = true,
        speed       = 1,
    })
end

local function playAll()
    for _, sentinel in ipairs(sentinels) do playOne(sentinel) end
end

local function onUpdate(dt)
    if not started then
        started = true
        if not chooseGroups() then return end
        lastBone = animation.hasBone(self, WITNESS_BONE)
        log('witness bone ' .. WITNESS_BONE .. ' present=' .. tostring(lastBone) ..
            '  camera=' .. modeText())
        playAll()
        heartbeatAt = core.getSimulationTime()
        -- The session's first onLoad fires before this, so its deferred check would run one
        -- frame after the sentinels were established and report SURVIVED for free. v4 did
        -- exactly that. Only loads during play can say anything, so drop the pending check.
        if pendingLoadCheck then
            pendingLoadCheck = false
            log('(startup: skipping the load check - the sentinels were only just placed)')
        end
        return
    end
    if sentinels[1].group == nil then return end

    -- A load clears mStates, so both should read as lost. Check before replaying.
    if pendingLoadCheck then
        pendingLoadCheck = false
        local report = {}
        for _, sentinel in ipairs(sentinels) do
            report[#report + 1] = sentinel.label .. '=' ..
                (animation.isPlaying(self, sentinel.group) and 'SURVIVED' or 'cleared')
        end
        log('after load: ' .. table.concat(report, ' ') .. '  camera=' .. modeText())
        lastBone = animation.hasBone(self, WITNESS_BONE)
        playAll()
        heartbeatAt = core.getSimulationTime()
        return
    end

    timer = timer + dt
    if timer < POLL then return end
    timer = 0

    local now = core.getSimulationTime()
    local ui  = uiStackText()

    local bone = animation.hasBone(self, WITNESS_BONE)
    local rigSwap = bone ~= lastBone
    if rigSwap then
        log('witness bone changed to present=' .. tostring(bone) ..
            '  camera=' .. modeText() .. '  ui=' .. ui)
        lastBone = bone
    end

    -- One line per poll in which ANY sentinel fell, naming which - so the three-way
    -- discriminator in the header is read off a single line.
    -- Which bucket this poll belongs to: the post-close window, or background.
    local inWindow = lastMenuGone ~= nil and (now - lastMenuGone) <= WINDOW
                     and not menuOpen
    if inWindow then winTime = winTime + POLL else bgTime = bgTime + POLL end

    local fallen, survivors = {}, {}
    for _, sentinel in ipairs(sentinels) do
        if animation.isPlaying(self, sentinel.group) then
            survivors[#survivors + 1] = sentinel.label
        else
            sentinel.losses = sentinel.losses + 1
            fallen[#fallen + 1] = ('%s(#%d after %.2fs)')
                :format(sentinel.label, sentinel.losses, now - sentinel.cleanSince)
            local isA = sentinel.label == 'A-unique'
            if inWindow then
                if isA then winLossA = winLossA + 1 else winLossB = winLossB + 1 end
            else
                if isA then bgLossA = bgLossA + 1 else bgLossB = bgLossB + 1 end
            end
        end
    end

    if now - heartbeatAt >= HEARTBEAT then
        heartbeatAt = now
        local function rate(losses, seconds)
            if seconds <= 0 then return 'n/a' end
            if losses == 0 then return ('0 in %.0fs'):format(seconds) end
            return ('%d in %.0fs = 1/%.1fs'):format(losses, seconds, seconds / losses)
        end
        log(('RATES post-close(%.1fs x %d closes): A %s | B %s')
            :format(WINDOW, menuCloses, rate(winLossA, winTime), rate(winLossB, winTime)))
        log(('RATES background:                 A %s | B %s')
            :format(rate(bgLossA, bgTime), rate(bgLossB, bgTime)))
    end

    if #fallen == 0 then return end

    log(('LOST %s | survived %s | t=%.2f camera=%s ui=%s rigSwap=%s witnessBone=%s %s')
        :format(table.concat(fallen, ' '),
                #survivors > 0 and table.concat(survivors, ' ') or 'none',
                now, modeText(), ui, tostring(rigSwap), tostring(bone), menuContext()))

    for _, sentinel in ipairs(sentinels) do
        if not animation.isPlaying(self, sentinel.group) then playOne(sentinel) end
    end
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad = function()
            pendingLoadCheck = true
            lastMenu, lastMenuGone = nil, nil
            log('onLoad: will check both sentinels before replaying')
        end,
    },
}
