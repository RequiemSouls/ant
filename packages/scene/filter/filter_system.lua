local ecs = ...
local world = ecs.world

ecs.import "ant.event"

local render = import_package "ant.render"
local ru = render.util
local computil = render.components

local filterutil = require "filter.util"

local assetpkg = import_package "ant.asset"
local assetmgr = assetpkg.mgr

local mathpkg = import_package "ant.math"
local ms = mathpkg.stack
local mu = mathpkg.util

local filter_properties = ecs.system "filter_properties"
filter_properties.singleton "render_properties"

function filter_properties:update()
	local render_properties = self.render_properties
	filterutil.load_lighting_properties(world, render_properties)
	filterutil.load_shadow_properties(world, render_properties)
	filterutil.load_postprocess_properties(world, render_properties)
end

local primitive_filter_sys = ecs.system "primitive_filter_system"
primitive_filter_sys.dependby 	"filter_properties"
primitive_filter_sys.depend 	"asyn_asset_loader"
primitive_filter_sys.singleton 	"hierarchy_transform_result"
primitive_filter_sys.singleton 	"event"

--luacheck: ignore self
local function reset_results(results)
	for k, result in pairs(results) do
		result.cacheidx = 1
	end
end

--[[	!NOTICE!
	the material component defined with 'multiple' property which mean:
	1. there is only one material, the 'material' component reference this material item;
	2. there are more than one material, the 'material' component itself keep the first material item 
		other items will store in array, start from 1 to n -1;
	examples:
	...
	world:create_entity {
		...
		material = {
			{ref_path=def_path1},
		}
	}
	...
	this entity's material component itself represent 'def_path1' material item, and NO any array item

	...
	world:create_entity {
		...
		material = {
			{ref_path=def_path1},
			{ref_path=def_path2},
		}
	}
	entity's material component same as above, but it will stay a array, and array[1] is 'def_path2' material item
	
	About the 'prim.material' field
	prim.material field it come from glb data, it's a index start from [0, n-1] with n elements

	Here 'primidx' stand for primitive index in mesh, it's a lua index, start from [1, n] with n elements
]]
local function get_material(prim, primidx, materialcomp, material_refs)
	local materialidx
	if material_refs then
		local idx = material_refs[primidx] or material_refs[1]
		materialidx = idx - 1
	else
		materialidx = prim.material or primidx - 1
	end

	return materialcomp[materialidx] or materialcomp
end

local function is_visible(meshname, submesh_refs)
	if submesh_refs == nil then
		return true
	end

	if submesh_refs then
		local ref = submesh_refs[meshname]
		if ref then
			return ref.visible
		end
	end
end

local function get_material_refs(meshname, submesh_refs)
	if submesh_refs then
		local ref = assert(submesh_refs[meshname])
		return assert(ref.material_refs)
	end
end

local function get_scale_mat(worldmat, scenescale)
	if scenescale and scenescale ~= 1 then
		return ms(worldmat, ms:srtmat(mu.scale_mat(scenescale)), "*P")
	end
	return worldmat
end

local function filter_element(eid, rendermesh, worldmat, materialcomp, filter)
	local meshscene = assetmgr.get_resource(assert(rendermesh.reskey))

	local sceneidx = computil.scene_index(rendermesh.lodidx, meshscene)

	local scenes = meshscene.scenes[sceneidx]
	local submesh_refs = rendermesh.submesh_refs
	for _, meshnode in ipairs(scenes) do
		local name = meshnode.meshname
		if is_visible(name, submesh_refs) then
			local trans = get_scale_mat(worldmat, meshscene.scenescale)
			if meshnode.transform then
				trans = ms(trans, meshnode.transform, "*P")
			end

			local material_refs = get_material_refs(name, submesh_refs)

			for groupidx, group in ipairs(meshnode) do
				local material = get_material(group, groupidx, materialcomp, material_refs)
				ru.insert_primitive(eid, group, material, trans, filter)
			end
		end
	end
end

local function is_entity_prepared(e)
	if e.asyn_load == nil then
		return true
	end

	return e.asyn_load == "loaded"
end

local function update_entity_transform(hierarchy_cache, eid)
	local e = world[eid]

	local transform = e.transform
	local worldmat = transform.world
	if e.hierarchy == nil then
		local peid = transform.parent
		
		if peid then
			local parentresult = hierarchy_cache[peid]
			if parentresult then
				local parentmat = parentresult.world
				local hie_result = parentresult.hierarchy
				local slotname = transform.slotname

				-- TODO: why need calculate one more time here.
				-- when delete a hierarchy node, it's children will not know parent has gone
				-- no update for 'transform.world', here will always calculate one more time
				-- if we want cache this result, we need to find all the children when hierarchy
				-- node deleted, and update it's children at that moment, then we can save 
				-- this calculation.
				local localmat = ms:srtmat(transform)
				if hie_result and slotname then
					local hiemat = ms:matrix(hie_result[slotname])
					ms(worldmat, parentmat, hiemat, localmat, "**=")
				else
					ms(worldmat, parentmat, localmat, "*=")
				end
			end
		end
	end

	return worldmat
end

local function reset_hierarchy_transform_result(hierarchy_cache)
	for k in pairs(hierarchy_cache) do
		hierarchy_cache[k] = nil
	end
end

function primitive_filter_sys:update()	
	local hierarchy_cache = self.hierarchy_transform_result
	for _, prim_eid in world:each "primitive_filter" do
		local e = world[prim_eid]
		local filter = e.primitive_filter
		reset_results(filter.result)
		local filtertag = filter.filter_tag

		for _, eid in world:each(filtertag) do
			local ce = world[eid]
			if ce[filtertag] then
				if is_entity_prepared(ce) then
					local worldmat = update_entity_transform(hierarchy_cache, eid)
					filter_element(eid, ce.rendermesh, worldmat, ce.material, filter)
				end
			end
		end
	end

	reset_hierarchy_transform_result(hierarchy_cache)
end

