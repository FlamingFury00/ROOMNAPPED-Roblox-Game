--!strict
--[[
	Trove: deterministic cleanup bag.

	Everything a run, room or UI screen creates is added to a trove so teardown is a single :Clean().
	Supports Instances, RBXScriptConnections, Signal connections, functions, threads and any object with a
	Destroy/Disconnect method. Items are cleaned in reverse insertion order (children before parents).
]]

local Trove = {}
Trove.__index = Trove

export type Trove = typeof(setmetatable({} :: { _items: { any }, _cleaning: boolean }, Trove))

local function cleanItem(item: any)
	local kind = typeof(item)
	if kind == "Instance" then
		item:Destroy()
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "function" then
		item()
	elseif kind == "thread" then
		if coroutine.status(item) ~= "dead" then
			pcall(task.cancel, item)
		end
	elseif kind == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		elseif type(item.Clean) == "function" then
			item:Clean()
		end
	end
end

function Trove.new(): Trove
	return setmetatable({ _items = {}, _cleaning = false }, Trove)
end

function Trove.Add<T>(self: Trove, item: T): T
	assert(not self._cleaning, "Cannot add to a trove while it is cleaning")
	table.insert(self._items, item)
	return item
end

-- Connect to an RBXScriptSignal or Signal and track the connection.
function Trove.Connect(self: Trove, signal: any, fn: (...any) -> ()): any
	local connection = signal:Connect(fn)
	table.insert(self._items, connection)
	return connection
end

-- Bind a function to RunService render step and unbind on cleanup (client only).
function Trove.BindToRenderStep(self: Trove, name: string, priority: number, fn: (number) -> ())
	local RunService = game:GetService("RunService")
	RunService:BindToRenderStep(name, priority, fn)
	table.insert(self._items, function()
		RunService:UnbindFromRenderStep(name)
	end)
end

-- Create a child trove whose lifetime is bounded by this one.
function Trove.Extend(self: Trove): Trove
	local child = Trove.new()
	table.insert(self._items, child)
	return child
end

-- Remove a tracked item without cleaning it.
function Trove.Remove(self: Trove, item: any): boolean
	local index = table.find(self._items, item)
	if index then
		table.remove(self._items, index)
		return true
	end
	return false
end

function Trove.Clean(self: Trove)
	if self._cleaning then
		return
	end
	self._cleaning = true
	local items = self._items
	self._items = {}
	for i = #items, 1, -1 do
		xpcall(cleanItem, function(err: any)
			warn("[Trove] cleanup error:", err, debug.traceback())
		end, items[i])
	end
	self._cleaning = false
end

function Trove.Destroy(self: Trove)
	self:Clean()
end

return Trove
