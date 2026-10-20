--!strict
--[[
	Registry: late-bound service lookup so services can reference each other without cyclic requires.
	Services register during Init and resolve peers lazily (Registry.get) when they need them.
]]

local Registry = {}

local services: { [string]: any } = {}

function Registry.add(name: string, service: any)
	assert(services[name] == nil, "Service registered twice: " .. name)
	services[name] = service
end

function Registry.get(name: string): any
	local service = services[name]
	assert(service, "Service not registered: " .. name)
	return service
end

function Registry.has(name: string): boolean
	return services[name] ~= nil
end

return Registry
