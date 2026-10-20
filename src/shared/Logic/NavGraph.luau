--!strict
--[[
	NavGraph: waypoint graph with A* used by the Caretaker (S15).

	Nodes are corridor tile centres, room interiors and alcoves. Edges can be disabled at runtime (closed
	gates, recalled rooms) and the caretaker re-plans; when no path exists it falls back to its
	"phase through the walls" recovery behaviour.
]]

local NavGraph = {}
NavGraph.__index = NavGraph

type Node = { id: string, position: Vector3, enabled: boolean }
type Edge = { to: string, cost: number, enabled: boolean }

export type Graph = typeof(setmetatable(
	{} :: {
		nodes: { [string]: Node },
		edges: { [string]: { Edge } },
	},
	NavGraph
))

function NavGraph.new(): Graph
	return setmetatable({ nodes = {}, edges = {} }, NavGraph)
end

function NavGraph.addNode(self: Graph, id: string, position: Vector3)
	self.nodes[id] = { id = id, position = position, enabled = true }
	self.edges[id] = self.edges[id] or {}
end

function NavGraph.setNodeEnabled(self: Graph, id: string, enabled: boolean)
	local node = self.nodes[id]
	if node then
		node.enabled = enabled
	end
end

function NavGraph.removeNode(self: Graph, id: string)
	self.nodes[id] = nil
	self.edges[id] = nil
	for _, list in self.edges do
		for i = #list, 1, -1 do
			if list[i].to == id then
				table.remove(list, i)
			end
		end
	end
end

function NavGraph.addEdge(self: Graph, a: string, b: string, cost: number?)
	local na, nb = self.nodes[a], self.nodes[b]
	assert(na and nb, "addEdge needs existing nodes: " .. a .. " " .. b)
	local c = cost or (na.position - nb.position).Magnitude
	table.insert(self.edges[a], { to = b, cost = c, enabled = true })
	table.insert(self.edges[b], { to = a, cost = c, enabled = true })
end

function NavGraph.setEdgeEnabled(self: Graph, a: string, b: string, enabled: boolean)
	local fromA = self.edges[a]
	if fromA then
		for _, edge in fromA do
			if edge.to == b then
				edge.enabled = enabled
			end
		end
	end
	local fromB = self.edges[b]
	if fromB then
		for _, edge in fromB do
			if edge.to == a then
				edge.enabled = enabled
			end
		end
	end
end

function NavGraph.position(self: Graph, id: string): Vector3?
	local node = self.nodes[id]
	return if node then node.position else nil
end

function NavGraph.neighbors(self: Graph, id: string): { string }
	local out = {}
	local list = self.edges[id]
	if not list then
		return out
	end
	for _, edge in list do
		local node = self.nodes[edge.to]
		if edge.enabled and node and node.enabled then
			table.insert(out, edge.to)
		end
	end
	return out
end

-- Nearest enabled node to a position (optionally filtered).
function NavGraph.nearest(self: Graph, position: Vector3, filter: ((string) -> boolean)?): string?
	local bestId, bestDistance = nil, math.huge
	for id, node in self.nodes do
		if node.enabled and (filter == nil or filter(id)) then
			local d = (node.position - position).Magnitude
			if d < bestDistance or (d == bestDistance and bestId ~= nil and id < bestId) then
				bestId, bestDistance = id, d
			end
		end
	end
	return bestId
end

-- A* search. Returns the list of node ids from start to goal (inclusive) or nil when unreachable.
function NavGraph.path(self: Graph, startId: string, goalId: string): { string }?
	local start, goal = self.nodes[startId], self.nodes[goalId]
	if not start or not goal or not start.enabled or not goal.enabled then
		return nil
	end
	if startId == goalId then
		return { startId }
	end
	local open: { [string]: boolean } = { [startId] = true }
	local cameFrom: { [string]: string } = {}
	local g: { [string]: number } = { [startId] = 0 }
	local f: { [string]: number } = { [startId] = (start.position - goal.position).Magnitude }
	local openCount = 1
	while openCount > 0 do
		-- Small graphs: a linear scan of the open set is faster than a heap.
		local current: string? = nil
		local bestF = math.huge
		for id in open do
			local score = f[id]
			if score < bestF or (score == bestF and current ~= nil and id < current) then
				bestF = score
				current = id
			end
		end
		local cur = current :: string
		if cur == goalId then
			local path = { cur }
			while cameFrom[path[1]] do
				table.insert(path, 1, cameFrom[path[1]])
			end
			return path
		end
		open[cur] = nil
		openCount -= 1
		for _, edge in self.edges[cur] do
			local node = self.nodes[edge.to]
			if edge.enabled and node and node.enabled then
				local tentative = g[cur] + edge.cost
				if tentative < (g[edge.to] or math.huge) then
					cameFrom[edge.to] = cur
					g[edge.to] = tentative
					f[edge.to] = tentative + (node.position - goal.position).Magnitude
					if not open[edge.to] then
						open[edge.to] = true
						openCount += 1
					end
				end
			end
		end
	end
	return nil
end

return NavGraph
