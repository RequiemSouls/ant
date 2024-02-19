local utility = require "model.utility"

local function GetSkinsForScene(model, scene)
    local open = {}
    local found = {}
    for _, nodeIndex in ipairs(scene.nodes) do
        open[nodeIndex] = true
    end
    while true do
        local nodeIndex = next(open)
        if nodeIndex == nil then
            break
        end
        found[nodeIndex] = true
        open[nodeIndex] = nil
        local node = model.nodes[nodeIndex+1]
        if node.children then
            for _, childIndex in ipairs(node.children) do
                open[childIndex] = true
            end
        end
    end
    local skins = {}
    for _, skin in ipairs(model.skins) do
        if #skin.joints ~= 0 and found[skin.joints[1]] then
            skins[#skins+1] = skin
        end
    end
    return skins
end

local function FindSkinRootJointIndices(model, scene)
    local skins = GetSkinsForScene(model, scene)
    local roots = {}
    if #skins  == 0 then
        for _, nodeIndex in ipairs(scene.nodes) do
            roots[#roots+1] = nodeIndex
        end
        return roots
    end
    local parents = {}
    for nodeIndex, node in ipairs(model.nodes) do
        if node.children then
            for _, childIndex in ipairs(node.children) do
                parents[childIndex] = nodeIndex-1
            end
        end
    end
    local no_parent <const> = nil
    local visited <const> = true
    for _, skin in ipairs(skins) do
        if #skin.joints == 0 then
            goto continue
        end
        if skin.skeleton then
            parents[skin.skeleton] = visited
            roots[#roots+1] = skin.skeleton
            goto continue
        end

        local root = skin.joints[1]
        while root ~= visited and parents[root] ~= no_parent do
            root = parents[root]
        end
        if root ~= visited then
            roots[#roots+1] = root
        end
        ::continue::
    end
    return roots
end

local function fetch_skininfo(gltfscene, skin, remap)
    local ibm_idx      = skin.inverseBindMatrices
    local ibm          = gltfscene.accessors[ibm_idx+1]
    local ibm_bv       = gltfscene.bufferViews[ibm.bufferView+1]
    local start_offset = ibm_bv.byteOffset + 1
    local end_offset   = start_offset + ibm_bv.byteLength
    local joints       = skin.joints
    local jointsbin = {}
    for i = 1, #joints do
        jointsbin[i] = string.pack("<I2", assert(remap[joints[i]]))
    end
    local buf = gltfscene.buffers[ibm_bv.buffer+1]
    return {
        inverse_bind_matrices = buf.bin:sub(start_offset, end_offset-1),
        joints = table.concat(jointsbin),
    }
end

local function get_obj_name(obj, idx, defname)
    if obj.name then
        return obj.name
    end
    return defname .. idx
end

return function (status)
    local gltfscene = status.gltfscene
    status.skin = {}
    local skins = gltfscene.skins
    if skins == nil then
        return
    end
    local sceneidx = gltfscene.scene or 0
    local scene = gltfscene.scenes[sceneidx+1]
    local roots = FindSkinRootJointIndices(gltfscene, scene)
    local jointIndex = 0
    local remap = {}
    local function ImportNode(nodes)
        for _, nodeIndex in ipairs(nodes) do
            remap[nodeIndex] = jointIndex
            jointIndex = jointIndex + 1
            local node = gltfscene.nodes[nodeIndex+1]
            local c = node.children
            if c then
                ImportNode(c)
            end
        end
    end
    ImportNode(roots)

    for skinidx, skin in ipairs(gltfscene.skins) do
        local skinname = get_obj_name(skin, skinidx, "skin")
        local resname = skinname .. ".skinbin"
        utility.save_bin_file(status, "animations/"..resname, fetch_skininfo(gltfscene, skin, remap))
        status.skin[skinidx] = resname
    end
end