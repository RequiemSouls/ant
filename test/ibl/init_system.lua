local ecs = ...
local world = ecs.world
local math3d = require "math3d"
local ientity = world:interface "ant.render|entity"
local imaterial = world:interface "ant.asset|imaterial"

local is = ecs.system "init_system"

local iblmb = world:sub {"ibl_updated"}
function is:init()
    --world:instance "/pkg/ant.test.ibl/assets/skybox.prefab"
    --world:instance "/pkg/ant.resources.binary/meshes/DamagedHelmet.glb|mesh.prefab"
end

function is:data_changed()
    -- for _, eid in iblmb:unpack() do
    --     local ibl = world[eid]._ibl
    --     imaterial.set_property(eid, "s_skybox", {stage=0, texture={handle=ibl.irradiance.handle}})
    -- end

    if test == nil then
        test = true
        local m = ientity.create_mesh{"p3", {
            -1, 1, 1,
             1, 1, 1,
             1, -1,1,
        }}

        world:luaecs_create_entity {
            policy = {
                "ant.render|render",
                "ant.general|name",
                "ant.scene|render_object",
                "ant.scene|scene_object",
            },
            data = {
                name = "test_luaecs",
                filter_material = {},
                scene = {
                    srt = math3d.ref(math3d.matrix()),
                },
                eid = world:create_entity{policy = {"ant.general|debug_TEST"}, data = {}},
                render_object = {},
                transform = {
                    t = {0, 1, 0},
                },
                render_object_update = true,
                material = "/pkg/ant.resources/materials/singlecolor.material",
                mesh = m,
                state = 7,
                INIT = true,
            }
        }
    end
end