--!strict
--[[
	CaretakerLook: the catalog items that dress the Caretaker (A03, A10).

	The server builds an R15 model from these with Players:CreateHumanoidModelFromDescriptionAsync
	(AssetLibraryService) and publishes it for the clients (Visual/CaretakerHuman). Catalog items work in an
	NPC's description whether or not anyone owns them. Item ids that stop existing simply leave that piece
	off; if the whole build fails the server retries without the accessories, then with the Roblox-made
	`fallback` pieces, and if even that fails the clients keep the part-built bellhop.

	The look: a tall, lanky night bellhop in a burgundy double-breasted uniform with brass buttons and drawn
	white gloves, a burgundy-and-gold pillbox hat, a black bow tie and a key ring, ashen skin, a grey fringe
	under the hat and a wide "service with a smile" grin. Picked and checked against the public catalog on
	2026-10-21 (docs/CONTENT_OWNERSHIP.md).
]]

export type Accessory = { id: number, type: string }

export type Look = {
	enabled: boolean,
	face: number?,
	shirt: number?,
	pants: number?,
	head: number?, -- a dynamic head (it carries the face, so `face` stays empty)
	mood: number?, -- the dynamic head's mood animation
	torso: number?,
	leftArm: number?,
	rightArm: number?,
	leftLeg: number?,
	rightLeg: number?,
	accessories: { Accessory }, -- type = Enum.AccessoryType name (Hat, Hair, Face, Neck, Shoulder, Front, Back, Waist)
	scales: { height: number, width: number, depth: number, head: number, bodyType: number, proportion: number },
	skin: Color3,
	-- Roblox-made stand-ins for the user-made pieces, used when the full outfit cannot be built.
	fallback: { head: number?, mood: number?, hat: number? },
}

local look: Look = {
	enabled = true,
	shirt = 10126112559, -- "Bellhop [+]" (Eclipse's Trashbin): burgundy double-breasted jacket, white gloves
	pants = 10126117868, -- "Bellhop [-]" (Eclipse's Trashbin): black trousers
	head = 74871478197941, -- "The Friendly Eviscerator - Head" (Roblox): round eyes, wide toothy grin
	mood = 85699644348712, -- its mood animation
	accessories = {
		{ id = 84923485112253, type = "Hat" }, -- "Bellhop Hat" (Farington Industries): burgundy pillbox, gold strap
		{ id = 7611015444, type = "Hair" }, -- "Gray Grandpa Balding Old Man Hair" (DawsonDelRey)
		{ id = 4602807964, type = "Neck" }, -- "Black Bow Tie" (WhoToTrus)
		{ id = 8466492470, type = "Waist" }, -- "Keyring" (Reverse_Polarity)
	},
	-- Slender proportions on the default blocky parts: about 6.6 studs to the top of the head (players 5.2).
	scales = { height = 1.1, width = 0.75, depth = 0.8, head = 1, bodyType = 1, proportion = 1 },
	skin = Color3.fromRGB(186, 196, 178), -- pale ashen grey with a faint green tint
	fallback = {
		head = 13692947484, -- "Stare - Head" (Roblox)
		mood = 13692949813,
		hat = 116778751, -- "Marching Band Cap" (Roblox)
	},
}

return look
