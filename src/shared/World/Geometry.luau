--!strict
--[[
	Geometry contract (R11, A01): every module and room prefab is built from these dimensions, so any room
	snaps into any socket without covering the hallway or breaking the caretaker route.

	Tile space: a corridor tile is a 16x16 cell. `x` is lateral (+ = right of the heading), `a` is along
	(+ = forward along the route), `y` is height above the floor (floor top at y = 0).

	Room space: a room's frame sits on the outer face of the corridor wall at the socket opening, floor
	level, with LookVector pointing into the room. Interior: x in [-8, 8], y in [0, 14], depth d in [0, 14]
	(world point = roomCF * Vector3.new(x, y, -d)).
]]

local Geometry = {
	Tile = 16,
	Half = 8,
	Wall = 1,
	Inner = 7, -- interior half width of a corridor (walls occupy |x| in [7, 8])
	Ceiling = 14,
	FloorThickness = 1,

	SocketDoor = { Width = 8, Height = 10 },
	DecorDoor = { Width = 5, Height = 8.6 },

	Room = {
		Width = 16,
		Depth = 14,
		Height = 14,
		OccupancyInset = 0.75,
		OutletHeight = 5,
	},

	Pit = {
		Depth = 14,
		GapDepth = 22,
		WaterSurface = -1.4,
		IceTop = 0,
		IceThickness = 2.4,
	},

	Ledge = { Width = 3, RailHeight = 1.6 },
	Beam = { Width = 1.8 },

	Elevator = { Width = 12, Depth = 10, Height = 11, DoorWidth = 8, DoorHeight = 9.5 },

	Crate = { Size = 5.6, SlotDepth = 5.6 },

	Caretaker = { HoverY = 3.2, Radius = 2 },

	-- World placement of an expedition level relative to the lobby (far enough to never be visible).
	LevelOrigin = Vector3.new(0, 0, 3200),
	LobbyOrigin = Vector3.new(0, 0, 0),
}

-- World point inside a tile frame.
function Geometry.tilePoint(cf: CFrame, x: number, y: number, a: number): Vector3
	return cf * Vector3.new(x, y, -a)
end

-- CFrame of a part centred at tile coordinates (x, y, a), aligned with the tile.
function Geometry.tileCFrame(cf: CFrame, x: number, y: number, a: number): CFrame
	return cf * CFrame.new(x, y, -a)
end

-- World point inside a room frame (d = depth into the room).
function Geometry.roomPoint(roomCF: CFrame, x: number, y: number, d: number): Vector3
	return roomCF * Vector3.new(x, y, -d)
end

function Geometry.roomCFrame(roomCF: CFrame, x: number, y: number, d: number): CFrame
	return roomCF * CFrame.new(x, y, -d)
end

-- The occupancy box of a room (players or cargo inside block recall - S07).
function Geometry.roomOccupancy(roomCF: CFrame): (CFrame, Vector3)
	local r = Geometry.Room
	local inset = r.OccupancyInset
	local cf = roomCF * CFrame.new(0, (r.Height - 2) / 2, -r.Depth / 2)
	return cf, Vector3.new(r.Width - inset * 2, r.Height - 2, r.Depth - inset)
end

return table.freeze(Geometry)
