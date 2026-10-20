--!strict
--[[
	DeployRules: pure validation for room deployment and recall (S05, S06, S07, R06).

	The server calls these with its authoritative bookkeeping; the client calls the same functions to
	explain the placement preview (U05) so both sides always agree on the reason a request is blocked.
	Requests are processed one at a time on the server, so the first valid claim on a socket wins and
	the second gets "SocketOccupied" (two simultaneous requests can never claim the same socket).
]]

export type SocketClaim = {
	owner: number,
	slot: number,
	room: string,
}

export type DeployState = {
	phase: string,
	sockets: { [string]: SocketClaim }, -- socketId -> claim
	validSockets: { [string]: boolean },
	disabledRooms: { [string]: boolean },
	perPlayerCap: number,
	teamCap: number,
}

export type PlayerView = {
	userId: number,
	inRoster: boolean,
	active: boolean, -- not downed / eliminated
	loadout: { string },
	deployed: { [number]: string }, -- slot -> socketId
	distanceToSocket: number?,
	range: number,
	cooldownRemaining: number,
}

export type Reason =
	"Ok"
	| "NotInRun"
	| "NotActive"
	| "WrongPhase"
	| "InvalidSlot"
	| "SlotEmpty"
	| "RoomDisabled"
	| "UnknownSocket"
	| "SocketOccupied"
	| "SlotAlreadyDeployed"
	| "PlayerCap"
	| "TeamCap"
	| "OutOfRange"
	| "Cooldown"
	| "NotDeployed"
	| "Occupied"

local DEPLOY_PHASES: { [string]: boolean } = { Explore = true, Escape = true }

local DeployRules = {}

function DeployRules.countPlayer(state: DeployState, userId: number): number
	local n = 0
	for _, claim in state.sockets do
		if claim.owner == userId then
			n += 1
		end
	end
	return n
end

function DeployRules.countTeam(state: DeployState): number
	local n = 0
	for _ in state.sockets do
		n += 1
	end
	return n
end

-- Validate a deploy request. `checkRange` is false when the client previews a far socket.
function DeployRules.canDeploy(
	state: DeployState,
	player: PlayerView,
	slot: number,
	socketId: string,
	checkRange: boolean?
): (boolean, Reason)
	if not player.inRoster then
		return false, "NotInRun"
	end
	if not DEPLOY_PHASES[state.phase] then
		return false, "WrongPhase"
	end
	if not player.active then
		return false, "NotActive"
	end
	if slot < 1 or slot > #player.loadout or math.floor(slot) ~= slot then
		return false, "InvalidSlot"
	end
	local room = player.loadout[slot]
	if room == nil or room == "" then
		return false, "SlotEmpty"
	end
	if state.disabledRooms[room] then
		return false, "RoomDisabled"
	end
	if not state.validSockets[socketId] then
		return false, "UnknownSocket"
	end
	local claim = state.sockets[socketId]
	if claim ~= nil then
		return false, "SocketOccupied"
	end
	if player.deployed[slot] ~= nil then
		return false, "SlotAlreadyDeployed"
	end
	if DeployRules.countPlayer(state, player.userId) >= state.perPlayerCap then
		return false, "PlayerCap"
	end
	if DeployRules.countTeam(state) >= state.teamCap then
		return false, "TeamCap"
	end
	if checkRange ~= false then
		local distance = player.distanceToSocket
		if distance == nil or distance > player.range then
			return false, "OutOfRange"
		end
	end
	if player.cooldownRemaining > 0 then
		return false, "Cooldown"
	end
	return true, "Ok"
end

-- Validate a recall. `occupants` is the number of players/cargo inside the room's occupancy zone.
function DeployRules.canRecall(
	state: DeployState,
	player: PlayerView,
	slot: number,
	occupants: number
): (boolean, Reason)
	if not player.inRoster then
		return false, "NotInRun"
	end
	if not DEPLOY_PHASES[state.phase] then
		return false, "WrongPhase"
	end
	if not player.active then
		return false, "NotActive"
	end
	local socketId = player.deployed[slot]
	if socketId == nil then
		return false, "NotDeployed"
	end
	local claim = state.sockets[socketId]
	if claim == nil or claim.owner ~= player.userId then
		return false, "NotDeployed"
	end
	if occupants > 0 then
		return false, "Occupied"
	end
	if player.cooldownRemaining > 0 then
		return false, "Cooldown"
	end
	return true, "Ok"
end

-- Localization key that explains a reason to the player (U05 / U07 / U14).
function DeployRules.reasonKey(reason: Reason): string
	return "deploy.reason." .. reason
end

return DeployRules
