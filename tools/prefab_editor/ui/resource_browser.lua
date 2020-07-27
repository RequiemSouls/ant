local imgui     = require "imgui"
local lfs       = require "filesystem.local"
local fs        = require "filesystem"
local uiconfig  = require "ui.config"
local uiutils   = require "ui.utils"
local world
local assetmgr
local m = {}

local resourceTree = nil
local resourceRoot = nil
local currentFolder = {files = {}}
local currentFile = nil

local previewImages = {}

local function on_drop_files(files)
    local current_path = lfs.path(tostring(currentFolder[1]))
    for k, v in pairs(files) do
        local path = lfs.path(v)
        local dst_path = current_path / tostring(path:filename())
        if lfs.is_directory(path) then
            lfs.create_directories(dst_path)
            lfs.copy(path, dst_path, true)
        else
            lfs.copy_file(path, dst_path, true)
        end
    end
end

local function path_split(fullname)
    local root = (fullname:sub(1, 1) == "/") and "/" or ""
    local stack = {}
	for elem in fullname:gmatch("([^/\\]+)[/\\]?") do
        if #elem == 0 and #stack ~= 0 then
        elseif elem == '..' and #stack ~= 0 and stack[#stack] ~= '..' then
            stack[#stack] = nil
        elseif elem ~= '.' then
            stack[#stack + 1] = elem
        end
    end
    return root, stack
end

function m.set_root(root)
    resourceRoot = root
end

function m.show(rhwi)
    local sw, sh = rhwi.screen_size()
    imgui.windows.SetNextWindowPos(0, sh - uiconfig.ResourceBrowserHeight, 'F')
    imgui.windows.SetNextWindowSize(sw, uiconfig.ResourceBrowserHeight, 'F')
    local function constructResourceTree(fspath)
        local tree = {files = {}, dirs = {}}
        for item in fspath:list_directory() do
            if fs.is_directory(item) then
                table.insert(tree.dirs, {item, constructResourceTree(item), parent = {tree}})
            else
                table.insert(tree.files, item)
            end
        end
        return tree
    end

    if resourceTree == nil then
        resourceTree = {files = {}, dirs = {{resourceRoot, constructResourceTree(resourceRoot)}}}
        local function set_parent(tree)
            for _, v in pairs(tree[2].dirs) do
                v.parent = tree
                set_parent(v)
            end
        end
        set_parent(resourceTree.dirs[1])
        currentFolder = resourceTree.dirs[1]
    end

    local function doShowBrowser(folder)
        for k, v in pairs(folder.dirs) do
            local dir_name = tostring(v[1]:filename())
            local base_flags = imgui.flags.TreeNode { "OpenOnArrow", "SpanFullWidth" } | ((currentFolder == v) and imgui.flags.TreeNode{"Selected"} or 0)
            local skip = false
            if (#v[2].dirs == 0) then
                imgui.widget.TreeNode(dir_name, base_flags | imgui.flags.TreeNode { "Leaf", "NoTreePushOnOpen" })
            else
                local adjust_flags = base_flags | (string.find(currentFolder[1]._value, "/" .. dir_name) and imgui.flags.TreeNode {"DefaultOpen"} or 0)
                if imgui.widget.TreeNode(dir_name, adjust_flags) then
                    if imgui.util.IsItemClicked() then
                        currentFolder = v
                    end
                    skip = true
                    doShowBrowser(v[2])
                    imgui.widget.TreePop()
                end
            end
            if not skip and imgui.util.IsItemClicked() then
                currentFolder = v
            end
        end 
    end

    for _ in uiutils.imgui_windows("ResourceBrowser", imgui.flags.Window { "NoCollapse", "NoScrollbar", "NoClosed" }) do
        imgui.windows.PushStyleVar(imgui.enum.StyleVar.ItemSpacing, 0, 6)
        imgui.widget.Button(tostring(resourceRoot:parent_path()))
        imgui.cursor.SameLine()
        local _, split_dirs = path_split(tostring(fs.relative(currentFolder[1], resourceRoot:parent_path())))
        for i = 1, #split_dirs do
            if imgui.widget.Button("/" .. split_dirs[i])then
                if tostring(currentFolder[1]:filename()) ~= split_dirs[i] then
                    local lookup_dir = currentFolder.parent
                    while lookup_dir do
                        if tostring(lookup_dir[1]:filename()) == split_dirs[i] then
                            currentFolder = lookup_dir
                            lookup_dir = nil
                        else
                            lookup_dir = lookup_dir.parent
                        end
                    end
                end
            end
            if i < #split_dirs then
                imgui.cursor.SameLine()
            end
        end
        imgui.windows.PopStyleVar(1)
        imgui.cursor.Separator()

        local min_x, min_y = imgui.windows.GetWindowContentRegionMin()
        local max_x, max_y = imgui.windows.GetWindowContentRegionMin()
        local width = imgui.windows.GetWindowContentRegionWidth() * 0.2
        local height = (max_y - min_y) * 0.5

        imgui.windows.BeginChild("ResourceBrowserDir", width, height, false);
        doShowBrowser(resourceTree)
        imgui.windows.EndChild()
        imgui.cursor.SameLine()
        imgui.windows.BeginChild("ResourceBrowserContent", width * 3, height, false);
        local folder = currentFolder[2]
        if folder then
            local icons = require "common.icons"(assetmgr)
            for _, path in pairs(folder.files) do
                local icon = icons.get_file_icon(path)
                imgui.widget.Image(icon.handle, icon.texinfo.width, icon.texinfo.height)
                imgui.cursor.SameLine()
                if imgui.widget.Selectable(tostring(path:filename()), currentFile == path, 0, 0, imgui.flags.Selectable {"AllowDoubleClick"}) then
                    currentFile = path
                    if imgui.util.IsMouseDoubleClicked(0) then
                        local prefab_file
                        if path:equal_extension(".prefab") then
                            prefab_file = tostring(path)
                        elseif path:equal_extension(".glb") then
                            prefab_file = tostring(path) .. "|mesh.prefab"
                        end
                        if prefab_file then
                            world:pub {"instance_prefab", prefab_file}
                        end
                    end
                    if path:equal_extension(".png") then
                        if not previewImages[currentFile] then
                            local rp = fs.relative(path, resourceRoot)
                            local pkg_path = "/pkg/ant.tools.prefab_editor/" .. tostring(rp)
                            previewImages[currentFile] = assetmgr.resource(pkg_path, { compile = true })
                        end
                    end
                end
                
                if path:equal_extension(".material")
                    or path:equal_extension(".png")
                    or path:equal_extension(".prefab")
                    or path:equal_extension(".glb") then
                    if imgui.widget.BeginDragDropSource() then
                        imgui.widget.SetDragDropPayload("Drag", tostring(path))
                        imgui.widget.EndDragDropSource()
                    end
                end
            end
            for _, path in pairs(folder.dirs) do
                imgui.widget.Image(icons.ICON_FOLD.handle, icons.ICON_FOLD.texinfo.width, icons.ICON_FOLD.texinfo.height)
                imgui.cursor.SameLine()
                if imgui.widget.Selectable(tostring(path[1]:filename()), currentFile == path[1], 0, 0, imgui.flags.Selectable {"AllowDoubleClick"}) then
                    currentFile = path[1]
                    if imgui.util.IsMouseDoubleClicked(0) then
                        currentFolder = path
                    end
                end
                
            end
        end
        imgui.windows.EndChild()
        imgui.cursor.SameLine()
        imgui.windows.BeginChild("ResourceBrowserPreview", width, height, false);
        
        
        if fs.path(currentFile):equal_extension(".png") then
            local preview = previewImages[currentFile]
            if preview then
                imgui.widget.Text(preview.texinfo.width .. "x" .. preview.texinfo.height .. " ".. preview.texinfo.format)
                imgui.widget.Image(preview.handle, preview.texinfo.width, preview.texinfo.height)
            end
        end
        imgui.windows.EndChild()
    end
    local payload = imgui.widget.GetDragDropPayload()
    if payload then
        print(payload)
    end
end

return function(w, am)
    world = w
    assetmgr = am
    return m
end