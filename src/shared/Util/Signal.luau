--!strict
--[[
	Signal: in-process event dispatcher (never replicated).

	Listeners run in their own coroutine through task.spawn so a yielding or erroring listener cannot
	break dispatch for the others. Disconnecting during dispatch is safe because Fire iterates a snapshot.
]]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

type ListenerRecord = {
	fn: (...any) -> (),
	connection: Connection,
	once: boolean,
}

local Signal = {}
Signal.__index = Signal

export type Signal = typeof(setmetatable({} :: { _listeners: { ListenerRecord }, _waiting: { thread } }, Signal))

local function removeRecord(listeners: { ListenerRecord }, record: ListenerRecord)
	local index = table.find(listeners, record)
	if index then
		table.remove(listeners, index)
	end
end

function Signal.new(): Signal
	return setmetatable({ _listeners = {}, _waiting = {} }, Signal)
end

function Signal.Connect(self: Signal, fn: (...any) -> ()): Connection
	local listeners = self._listeners
	local record: ListenerRecord
	local connection = {} :: Connection
	connection.Connected = true
	function connection.Disconnect(conn: Connection)
		if not conn.Connected then
			return
		end
		conn.Connected = false
		removeRecord(listeners, record)
	end
	record = { fn = fn, connection = connection, once = false }
	table.insert(listeners, record)
	return connection
end

function Signal.Once(self: Signal, fn: (...any) -> ()): Connection
	local connection = self:Connect(fn)
	local record = self._listeners[#self._listeners]
	record.once = true
	return connection
end

function Signal.Fire(self: Signal, ...: any)
	local snapshot = table.clone(self._listeners)
	for _, record in snapshot do
		if record.connection.Connected then
			if record.once then
				record.connection:Disconnect()
			end
			task.spawn(record.fn, ...)
		end
	end
	if #self._waiting > 0 then
		local waiting = self._waiting
		self._waiting = {}
		for _, thread in waiting do
			task.spawn(thread, ...)
		end
	end
end

function Signal.Wait(self: Signal): ...any
	table.insert(self._waiting, coroutine.running())
	return coroutine.yield()
end

function Signal.DisconnectAll(self: Signal)
	for _, record in table.clone(self._listeners) do
		record.connection:Disconnect()
	end
	table.clear(self._listeners)
end

function Signal.Destroy(self: Signal)
	self:DisconnectAll()
	for _, thread in self._waiting do
		task.cancel(thread)
	end
	table.clear(self._waiting)
end

return Signal
