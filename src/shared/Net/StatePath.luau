--!strict
--[[
	StatePath: helpers for replicated state trees addressed by string paths ({ "roster", "123", "hearts" }).
	Shared by the server state channels and the client mirror so both apply patches identically.
]]

export type Path = { string }
export type Patch = { p: Path, v: any?, d: boolean? }

local StatePath = {}

function StatePath.key(path: Path): string
	return table.concat(path, ".")
end

function StatePath.get(root: { [string]: any }, path: Path): any
	local node: any = root
	for _, segment in path do
		if type(node) ~= "table" then
			return nil
		end
		node = node[segment]
	end
	return node
end

-- Apply a patch in place. Intermediate tables are created as needed.
function StatePath.apply(root: { [string]: any }, patch: Patch)
	local path = patch.p
	local count = #path
	if count == 0 then
		return
	end
	local node: any = root
	for i = 1, count - 1 do
		local segment = path[i]
		local child = node[segment]
		if type(child) ~= "table" then
			if patch.d then
				return
			end
			child = {}
			node[segment] = child
		end
		node = child
	end
	if patch.d then
		node[path[count]] = nil
	else
		node[path[count]] = patch.v
	end
end

-- True if `a` is a prefix of `b` (or equal).
function StatePath.isPrefix(a: Path, b: Path): boolean
	if #a > #b then
		return false
	end
	for i, segment in a do
		if b[i] ~= segment then
			return false
		end
	end
	return true
end

function StatePath.parse(text: string): Path
	local out = {}
	for segment in string.gmatch(text, "[^%.]+") do
		table.insert(out, segment)
	end
	return out
end

return StatePath
