local ecs = ...
local world = ecs.world

local fbmgr 	= require "framebuffer_mgr"
local bgfx 		= require "bgfx"

local default_comp 	= import_package "ant.general".default

local irender 	= world:interface "ant.render|irender"
local ipf		= world:interface "ant.scene|iprimitive_filter"
local isp		= world:interface "ant.render|system_properties"
local iqc		= world:interface "ant.render|iquadcache"
local icamera	= world:interface "ant.camera|camera"

local wmt = ecs.transform "world_matrix_transform"
local function set_world_matrix(rc)
	bgfx.set_transform(rc.worldmat)
end

function wmt.process_entity(e)
	local rc = e._rendercache
	rc.set_transform = set_world_matrix
end

local rt = ecs.component "render_target"
local irq = world:interface "ant.render|irenderqueue"

function rt:init()
	irq.update_rendertarget(self)
	return self
end

function rt:delete()
	fbmgr.unbind(self.viewid)
end

local render_sys = ecs.system "render_system"

local function update_view_proj(viewid, cameraeid)
	local rc = world[cameraeid]._rendercache
	bgfx.set_view_transform(viewid, rc.viewmat, rc.projmat)
end

function render_sys:init()
	local vr = {w=world.args.width,h=world.args.height}
	local camera_eid = icamera.create{
		eyepos  = {0, 0, 0, 1},
		viewdir = {0, 0, 1, 0},
		frustum = default_comp.frustum(vr.w/vr.h),
        name = "default_camera",
	}
	irender.create_pre_depth_queue(vr, camera_eid)
	irender.create_main_queue(vr, camera_eid)
end

function render_sys:render_commit()
	iqc.update()
	isp.update()
	for _, eid in world:each "render_target" do
		local rq = world[eid]
		if rq.visible then
			local rt = rq.render_target
			local viewid = rt.viewid
			bgfx.touch(viewid)
			update_view_proj(viewid, rq.camera_eid)

			local filter = rq.primitive_filter
			local results = filter.result

			for _, fn in ipairs(filter.filter_order) do
				local result = results[fn]
				if result.sort then
					result:sort()
				end
				for _, item in ipf.iter_target(result) do
					irender.draw(viewid, item)
				end
			end
		end
		
	end
end

local pd_sys = ecs.system "pre_depth_system"
local pd_mbs = {}
function pd_sys:post_init()
	local pd_eid = world:singleton_entity_id "pre_depth_queue"
	if pd_eid == nil then
		return
	end

	local mq_eid = world:singleton_entity_id "main_queue"
	local mq = world[mq_eid]
	local callbacks = {
		view_rect = function (m)
			local vr = mq.render_target.view_rect
			irq.set_view_rect(pd_eid, vr)
		end,
		camera_eid = function (m)
			irq.set_camera(pd_eid, mq.camera_eid)
		end,
		framebuffer = function (m)
			error "not implement"
		end,
	}

	for n, cb in pairs(callbacks) do
		pd_mbs[n] = {
			mb = world:sub{"component_changed", n, mq_eid},
			cb = cb
		}
	end
end
function pd_sys:before_render()
	for _, d in pairs(pd_mbs) do
		local cb = d.cb
		for msg in d.mb:each() do
			cb(msg)
		end
	end
end

local mathadapter_util = import_package "ant.math.adapter"
local math3d_adapter = require "math3d.adapter"
mathadapter_util.bind("bgfx", function ()
	bgfx.set_transform = math3d_adapter.matrix(bgfx.set_transform, 1, 1)
	bgfx.set_view_transform = math3d_adapter.matrix(bgfx.set_view_transform, 2, 2)
	bgfx.set_uniform = math3d_adapter.variant(bgfx.set_uniform_matrix, bgfx.set_uniform_vector, 2)
	local idb = bgfx.instance_buffer_metatable()
	idb.pack = math3d_adapter.format(idb.pack, idb.format, 3)
	idb.__call = idb.pack
end)

