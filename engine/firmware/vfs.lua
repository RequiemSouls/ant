local fastio = require "fastio"

local function sha1(str)
	return fastio.str2sha1(str)
end

local vfs = {} ; vfs.__index = vfs

local uncomplete = {}

-- dir object example :
-- f vfs.txt 90a5c279259fd4e105c4eb8378e9a21694e1e3c4 1533871795

local function read_history(self)
	local history = {}
	local f = io.open(self.path .. "root", "rb")
	if f then
		for hash in f:lines() do
			history[#history+1] = hash:match "[%da-f]+"
		end
		f:close()
	end
	return history
end

local function update_history(self, new)
	local history = read_history(self)
	for i, h in ipairs(history) do
		if h == new then
			table.remove(history, i)
			table.insert(history, 1, h)
			return history
		end
	end
	table.insert(history, 1, new)
	history[11] = nil
	return history
end

function vfs:history_root()
	local f = io.open(self.path .. "root", "rb")
	if f then
		local hash = f:read "l"
		f:close()
		return (hash:match "[%da-f]+")
	end
end

function vfs.new(repopath)
	local repo = {
		path = repopath:gsub("[/\\]?$","/") .. ".repo/",
		cache = {},--setmetatable( {} , { __mode = "kv" } ),
		root = nil,
	}
	setmetatable(repo, vfs)
	return repo
end

local function dir_object(self, hash)
	local dir = self.cache[hash]
	if dir then
		return dir
	end
	local realname = self.path .. hash
	local df = io.open(realname, "rb")
	if df then
		local dir = {}
		for line in df:lines() do
			local type, name, hash = line:match "^([dfr]) (%S*) (%S*)$"
			if type then
				dir[name] = {
					type = type,
					hash = hash,
				}
			end
		end
		df:close()
		self.cache[hash] = dir
		return dir
	end
end

local function get_cachepath(name)
	local filename = name:match "[/]?([^/]*)$"
	local ext = filename:match "[^/]%.([%w*?_%-]*)$"
	local hash = sha1(name)
	return ("res/%s/%s_%s"):format(ext, filename, hash)
end

local ListSuccess <const> = 1
local ListFailed <const> = 2
local ListNeedGet <const> = 3
local ListNeedResource <const> = 4

local function fetch_file(self, hash, fullpath)
	local dir = dir_object(self, hash)
	if not dir then
		return ListNeedGet, hash
	end

	local path, name = fullpath:match "^([^/]+)/?(.*)$"
	local subpath = dir[path]
	if subpath then
		if name == "" then
			if subpath.type == 'r' then
				local h = self.resource[subpath.hash]
				if h then
					return ListSuccess, h
				end
				local cachepath = get_cachepath(subpath.hash)
				if cachepath then
					local r, h = fetch_file(self, hash, cachepath)
					if r ~= ListFailed then
						return r, h
					end
				end
				return ListNeedResource, subpath.hash
			else
				return ListSuccess, subpath.hash
			end
		else
			if subpath.type == 'd' then
				return fetch_file(self, subpath.hash, name)
			elseif subpath.type == 'r' then
				local h = self.resource[subpath.hash]
				if h then
					return fetch_file(self, h, name)
				end
				return ListNeedResource, subpath.hash
			end
		end
	end
	-- invalid repo, root change
	return ListFailed
end

function vfs:list(path)
	local hash = self.root
	if path ~= "/" then
		local r, h = fetch_file(self, hash, path:sub(2))
		if r ~= ListSuccess then
			return nil, r, h
		end
		hash = h
	end
	local dir = dir_object(self, hash)
	if not dir then
		return nil, ListNeedGet, hash
	end
	return dir
end

local function split_path(path)
	local r = {}
	path:gsub("[^/]+", function(s)
		r[#r+1] = s
	end)
	return r
end

function vfs:gethash(path)
	local hash = self.root
	local pathlst = split_path(path)
	local n = #pathlst
	for i = 1, n-1 do
		local v = dir_object(self, hash)
		if not v then
			return {
				uncomplete = true,
				hash = hash,
				path = table.concat(pathlst, "/", i, n)
			}
		end
		local name = pathlst[i]
		local info = v[name]
		if not info or info.type ~= 'd' then
			local errorpath = table.concat(pathlst, "/", 1, i)
			return nil, "Not exist: "..errorpath.." (when get "..path..")"
		end
		hash = info.hash
	end
	local v = dir_object(self, hash)
	if not v then
		return {
			uncomplete = true,
			hash = hash,
			path = "",
		}
	end
	if n == 0 then
		return {
			hash = hash,
			type = "d"
		}
	end
	local name = pathlst[n]
	local info = v[name]
	if not info then
		return nil, "Not exist path: "..path
	end
	return info
end

function vfs:updatehistory(hash)
	local history = update_history(self, hash)
	local f <close> = assert(io.open(self.path .. "root", "wb"))
	f:write(table.concat(history, "\n"))
end

function vfs:changeroot(hash)
	self.root = hash
	self.resource = {}
end

function vfs:add_resource(name, hash)
	self.resource[name] = hash
end

function vfs:realpath(path)
	if not self.root then
		return
	end
	local r, hash = fetch_file(self, self.root, path)
	if r ~= ListSuccess then
		return
	end
	return self:hashpath(hash)
end

function vfs:hashpath(hash)
	return self.path .. hash
end

local function writefile(filename, data)
	local temp = filename .. ".download"
	local f = io.open(temp, "wb")
	if not f then
		print("Can't write to", temp)
		return
	end
	f:write(data)
	f:close()
	if not os.rename(temp, filename) then
		os.remove(filename)
		if not os.rename(temp, filename) then
			print("Can't rename", filename)
			return false
		end
	end
	return true
end

-- REMARK: Main thread may reading the file while writing, if file server update file.
-- It's rare because the file name is sha1 of file content. We don't need update the file.
-- Client may not request the file already exist.
function vfs:write_blob(hash, data)
	local hashpath = self:hashpath(hash)
	if writefile(hashpath, data) then
		return true
	end
end

function vfs:write_file(hash, size)
	uncomplete[hash] = { size = tonumber(size), offset = 0 }
end

function vfs:write_slice(hash, offset, data)
	offset = tonumber(offset)
	local hashpath = self:hashpath(hash)
	local tempname = hashpath .. ".download"
	local f = io.open(tempname, "ab")
	if not f then
		print("Can't write to", tempname)
		return
	end
	local pos = f:seek "end"
	if pos ~= offset then
		f:close()
		f = io.open(tempname, "r+b")
		if not f then
			print("Can't modify", tempname)
			return
		end
		f:seek("set", offset)
	end
	f:write(data)
	f:close()
	local filedesc = uncomplete[hash]
	if filedesc then
		local last_offset = filedesc.offset
		if offset ~= last_offset then
			print("Invalid offset", hash, offset, last_offset)
		end
		filedesc.offset = last_offset + #data
		if filedesc.offset == filedesc.size then
			-- complete
			uncomplete[hash] = nil
			if not os.rename(tempname, hashpath) then
				-- may exist
				os.remove(hashpath)
				if not os.rename(tempname, hashpath) then
					print("Can't rename", hashpath)
				end
			end
			return true
		end
	else
		print("Offset without header", hash, offset)
	end
end

return vfs
