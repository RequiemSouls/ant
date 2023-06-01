local platform = require "bee.platform"
local ltask = require "ltask"
local ServiceRmlui; do
    ltask.fork(function ()
        ServiceRmlui = ltask.queryservice "ant.rmlui|rmlui"
    end)
end

local function create(world, type)
    local keymap = require(type.."_keymap")
    local ev = {}
    function ev.touch(...)
        if ServiceRmlui then
            ltask.call(ServiceRmlui, "touch", ...)
        end
    end
    function ev.gesture(...)
        if ServiceRmlui then
            if ltask.call(ServiceRmlui, "gesture", ...) then
                return
            end
        end
        world:pub {"gesture", ...}
    end
    function ev.keyboard(key, press, state)
        world:pub {"keyboard", keymap[key], press, {
            CTRL	= (state & 0x01) ~= 0,
            SHIFT	= (state & 0x02) ~= 0,
            ALT		= (state & 0x04) ~= 0,
            SYS		= (state & 0x08) ~= 0,
        }}
    end
    function ev.size(w, h)
        world:pub {"resize", w, h}
    end
    if platform.os ~= "ios" and platform.os ~= "android" then
        function ev.touch_event(...)
            world:pub {"touch", ...}
        end
        require "mouse_gesture" (ev)
    end
    return ev
end

return {
    create = create,
}
