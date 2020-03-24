local access = {}

local lfs = require "filesystem.local"
local vfsinternal = require "firmware.vfs"
local crypt = require "crypt"

local function load_package(path)
    if not lfs.is_directory(path) then
        error(('`%s` is not a directory.'):format(path:string()))
    end
    local cfgpath = path / "package.lua"
    if not lfs.exists(cfgpath) then
        error(('`%s` does not exist.'):format(cfgpath:string()))
    end
    local config = dofile(cfgpath:string())
    for _, field in ipairs {'name'} do
        if not config[field] then
            error(('Missing `%s` field in `%s`.'):format(field, cfgpath:string()))
        end
    end
    return config.name
end

function access.repopath(repo, hash, ext)
	if ext then
		return repo._repo /	hash:sub(1,2) / (hash .. ext)
	else
		return repo._repo /	hash:sub(1,2) / hash
	end
end

function access.readmount(mountpoint, filename)
	local f = assert(lfs.open(filename, "rb"))
	for line in f:lines() do
		local name, path = line:match "^%s*(.-)%s+(.-)%s*$"
		if name == nil then
			if not (line:match "^%s*#" or line:match "^%s*$") then
				f:close()
				error ("Invalid .mount file : " .. line)
			end
		end
		path = lfs.path(path:gsub("%s*#.*$",""))	-- strip comment
		if name == '@pkg-one' then
			local pkgname = load_package(path)
			mountpoint['pkg/'..pkgname] = path
		elseif name == '@pkg' then
			for pkgpath in path:list_directory() do
				local pkgname = load_package(pkgpath)
				mountpoint['pkg/'..pkgname] = pkgpath
			end
		else
			mountpoint[name] = path
		end
	end
	f:close()
end

function access.mountname(mountpoint)
	local mountname = {}

	for name in pairs(mountpoint) do
		if name ~= '' then
			table.insert(mountname, name)
		end
	end
	table.sort(mountname, function(a,b) return a>b end)
	return mountname
end

function access.realpath(repo, pathname)
	pathname = pathname:match "^/?(.-)/?$"
	local mountnames = repo._mountname
	for _, mpath in ipairs(mountnames) do
		if pathname == mpath then
			return repo._mountpoint[mpath]
		end
		local n = #mpath + 1
		if pathname:sub(1,n) == mpath .. '/' then
			return repo._mountpoint[mpath] / pathname:sub(n+1)
		end
	end
	return repo._root / pathname
end

function access.virtualpath(repo, pathname)
	pathname = pathname:string()
	local mountpoints = repo._mountpoint
	-- TODO: ipairs
	for name, mpath in pairs(mountpoints) do
		mpath = mpath:string()
		if pathname == mpath then
			return repo._mountname[mpath]
		end
		local n = #mpath + 1
		if pathname:sub(1,n) == mpath .. '/' then
			return name .. '/' .. pathname:sub(n+1)
		end
	end
end

function access.hash(repo, path)
	if repo._loc then
		local rpath = access.realpath(repo, path)
		return access.sha1_from_file(rpath)
	else
		if not repo._internal then
			repo._internal = vfsinternal.new(repo._root:string())
		end
		local _, hash = repo._internal:realpath(path)
		return hash
	end
end

function access.list_files(repo, filepath)
	local rpath = access.realpath(repo, filepath)
	local files = {}
	if lfs.exists(rpath) then
		for name in rpath:list_directory() do
			local filename = name:filename():string()
			if filename:sub(1,1) ~= '.' then	-- ignore .xxx file
				files[filename] = true
			end
		end
	end
	local ignorepaths = rpath / ".ignore"
	local f = lfs.open(ignorepaths, "rb")
	if f then
		for name in f:lines() do
			files[name] = nil
		end
		f:close()
	end
	filepath = (filepath:match "^/?(.-)/?$") .. "/"
	if filepath == '/' then
		-- root path
		for mountname in pairs(repo._mountpoint) do
			if mountname ~= ''  and not mountname:find("/",1,true) then
				files[mountname] = true
			end
		end
	else
		local n = #filepath
		for mountname in pairs(repo._mountpoint) do
			if mountname:sub(1,n) == filepath then
				local name = mountname:sub(n+1)
				if not name:find("/",1,true) then
					files[name] = true
				end
			end
		end
	end
	return files
end

-- sha1
local function byte2hex(c)
	return ("%02x"):format(c:byte())
end

function access.sha1(str)
	return crypt.sha1(str):gsub(".", byte2hex)
end

local sha1_encoder = crypt.sha1_encoder()

function access.sha1_from_file(filename)
	sha1_encoder:init()
	local ff = assert(lfs.open(filename, "rb"))
	while true do
		local content = ff:read(1024)
		if content then
			sha1_encoder:update(content)
		else
			break
		end
	end
	ff:close()
	return sha1_encoder:final():gsub(".", byte2hex)
end

local function readfile(filename)
	local f = assert(lfs.open(filename))
	local str = f:read "a"
	f:close()
	return str
end

local function writefile(filename, str)
	lfs.create_directories(filename:parent_path())
	local f = assert(lfs.open(filename, "wb"))
	f:write(str)
	f:close()
end

local function rawtable(filename)
	local env = {}
	local r = assert(lfs.loadfile(filename, "t", env))
	r()
	return env
end

local function calchash(plat, depends)
	sha1_encoder:init()
	sha1_encoder:update(plat)
	for _, dep in ipairs(depends) do
		sha1_encoder:update(dep[1])
	end
	return sha1_encoder:final():gsub(".", byte2hex)
end

local function prebuild(repo, buildfile, deps)
	local depends = {}
	for _, name in ipairs(deps) do
		local vname = access.virtualpath(repo, name:is_absolute() and lfs.relative(name) or name)
		if vname then
			depends[#depends+1] = {access.sha1_from_file(name), lfs.last_write_time(name), vname}
		else
			print("MISSING DEPEND", name)
		end
	end
	local w = {}
	local dephash = calchash("", depends)
	w[#w+1] = ("dephash = %q"):format(dephash)
	w[#w+1] = "depends = {"
	for _, dep in ipairs(depends) do
		w[#w+1] = ("  {%q, %d, %q},"):format(dep[1], dep[2], dep[3])
	end
	w[#w+1] = "}"
	writefile(buildfile, table.concat(w, "\n"))
	return dephash
end

local function add_ref(repo, file, hash)
	local vfile = ".cache" .. file:string():sub(#repo._cache:string()+1)
	local timestamp = lfs.last_write_time(file)
	local info = ("f %s %d"):format(vfile, timestamp)

	local reffile = access.repopath(repo, hash) .. ".ref"
	if not lfs.exists(reffile) then
		local f = assert(lfs.open(reffile, "wb"))
		f:write(info)
		f:close()
		return
	end
	
	local w = {}
	for line in lfs.lines(reffile) do
		local name, ts = line:match "^[df] (.-) ?(%d*)$"
		if name == vfile and tonumber(ts) == timestamp then
			return
		else
			w[#w+1] = line
		end
	end
	w[#w+1] = info
	local f = lfs.open(reffile, "wb")
	f:write(table.concat(w, "\n"))
	f:close()
end

local function link(repo, srcfile, buildfile)
	local function localpath(path)
		return access.realpath(repo, path)
	end
	if lfs.exists(buildfile) then
		local param = rawtable(buildfile)
		local cpath = repo._cache / param.dephash:sub(1,2) / param.dephash
		if lfs.exists(cpath) then
			local binhash = readfile(cpath..".hash")
			add_ref(repo, cpath, binhash)
			return cpath, binhash
		end
		srcfile = access.realpath(repo, param.depends[1][3])
	end
	local fs = import_package "ant.fileconvert"
	local deps = fs.depend(srcfile)
	if deps then
		local dephash = prebuild(repo, buildfile, deps)
		local cpath = repo._cache / dephash:sub(1,2) / dephash
		if lfs.exists(cpath) then
			local binhash = readfile(cpath..".hash")
			add_ref(repo, cpath, binhash)
			return cpath, binhash
		end
		local dstfile = repo._repo / "tmp.bin"
		local ok = fs.link(repo._link, srcfile, dstfile, localpath)
		if not ok then
			return
		end
		if not pcall(lfs.rename, dstfile, cpath) then
			pcall(lfs.remove, dstfile)
			return
		end
		local binhash = access.sha1_from_file(cpath)
		writefile(cpath..".hash", binhash)
		add_ref(repo, cpath, binhash)
		return cpath, binhash
	else
		local dstfile = repo._repo / "tmp.bin"
		local deps = fs.link(repo._link, srcfile, dstfile, localpath)
		if not deps then
			return
		end
		local dephash = prebuild(repo, buildfile, deps)
		local cpath = repo._cache / dephash:sub(1,2) / dephash
		if lfs.exists(cpath) then
			local binhash = readfile(cpath..".hash")
			add_ref(repo, cpath, binhash)
			return cpath, binhash
		end
		if not pcall(lfs.remove, cpath) then
			pcall(lfs.remove, dstfile)
			return
		end
		if not pcall(lfs.rename, dstfile, cpath) then
			pcall(lfs.remove, dstfile)
			return
		end
		local binhash = access.sha1_from_file(cpath)
		writefile(cpath..".hash", binhash)
		add_ref(repo, cpath, binhash)
		return cpath, binhash
	end
end

local function sandbox_link(repo, srcfile, buildfile)
	local ok, r1, r2 = pcall(link, repo, srcfile, buildfile)
	if ok then
		return r1, r2
	end
end

local function getbuildpath(repo, path)
	local pathhash = access.sha1(path)
	local ext = (path:match "[^/](%.[%w*?_%-]*)$"):lower()
	local filename = path:match "[/]?([^/]*)$"
	return repo._build / pathhash / filename .. repo._link[ext].identity
end

function access.link_loc(repo, path)
	local srcfile = access.realpath(repo, path)
	local buildfile = getbuildpath(repo, path)
	return sandbox_link(repo, srcfile, buildfile)
end

function access.link(repo, path, buildhash)
	local srcfile = access.realpath(repo, path)
	local buildfile
	if buildhash then
		buildfile = repo:hash(buildhash)
	end
	if not buildfile then
		buildfile = getbuildpath(repo, path)
	end
	local dstfile, binhash = sandbox_link(repo, srcfile, buildfile)
	if not dstfile then
		return
	end
	if not buildhash then
		buildhash = access.sha1_from_file(buildfile)
	end
	return binhash, buildhash
end

function access.check_build(repo, buildfile)
	for _, dep in ipairs(rawtable(buildfile).depends) do
		local timestamp, filename = dep[2], dep[3]
		local realpath = access.realpath(repo, filename)
		if not realpath or not lfs.exists(realpath)  or timestamp ~= lfs.last_write_time(realpath) then
			lfs.remove(buildfile)
			return false
		end
	end
	return true
end

function access.clean_build(repo, path)
	path = path:match "^/?(.-)/?$"
	local buildfile = getbuildpath(repo, path)
	lfs.remove(buildfile)
end

return access
