-- A non-crossing mode change must never make a join look like a boundary.
local timers, mode, clock = {}, 'ThirdPerson', 0
package.loaded['openmw.camera'] = { MODE={FirstPerson='FirstPerson',ThirdPerson='ThirdPerson',Preview='Preview'},
    getMode=function() return mode end, getQueuedMode=function() return nil end }
package.loaded['openmw.async'] = { newUnsavableSimulationTimer=function(_,d,fn) table.insert(timers,{at=clock+d,fn=fn}) end }
package.loaded['openmw.interfaces'] = {}
local SERVICE = (...) or error('no service given. Usage: python3 -I runlua.py <harness>.lua <AnimRefresh>.lua', 0)
local loaded = assert(loadfile(SERVICE))()
local svc, onUpdate = loaded.interface, loaded.engineHandlers.onUpdate
local function advance(dt)
    clock = clock + dt; pcall(onUpdate, dt)
    local due={}; for i,t in ipairs(timers) do if t.at<=clock then table.insert(due,i) end end
    for i=#due,1,-1 do local t=table.remove(timers,due[i]); pcall(t.fn) end
end
local got
svc.subscribe('x', function(m,p) got = { mode=m, previous=p } end)
mode = 'Preview'          -- not a first-person crossing: no boundary should fire
advance(0.05); advance(0.05); advance(0.05)
print(('%-22s join delivered mode=%s previous=%s  looksLikeBoundary=%s')
      :format(SERVICE, tostring(got and got.mode), tostring(got and got.previous),
              tostring(got ~= nil and got.mode ~= got.previous)))
