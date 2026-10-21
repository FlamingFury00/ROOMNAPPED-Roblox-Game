--[[
	Interface smoke tests: the real client bootstrap and every lobby / menu screen run headlessly
	(tests/harness/ClientEnv) against scripted replicated state. Every property the interface sets is
	validated by Lune's reflection database, every remote it sends is checked against its schema, and
	any error - including inside spawned threads and button handlers - fails the test.
]]
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local ClientEnv = require("../harness/ClientEnv")

return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect

	local ME = "1001"

	local function profile()
		return {
			status = "Ready",
			memory = true,
			rooms = { Freezer = true, Fan = true, Laundry = true },
			loadout = { "Freezer", "Fan" },
			skins = {
				owned = {
					freezer_classic = true,
					fan_industrial = true,
					laundry_laundromat = true,
					case_leather = true,
				},
				equipped = {
					Freezer = "freezer_classic",
					Fan = "fan_industrial",
					Laundry = "laundry_laundromat",
					suitcase = "case_leather",
				},
			},
			credits = 500,
			settings = {
				music = 0.55,
				sfx = 0.85,
				ambience = 0.7,
				ui = 0.8,
				reducedMotion = false,
				lowEffects = false,
				hints = true,
				cameraShake = true,
				textScale = 1,
			},
			stats = {
				runs = 0,
				extractions = 1,
				captures = 1,
				keys = 2,
				deploys = 5,
				combos = 1,
				cleared = { M0 = 1 },
				bestTimes = { M0 = 95 },
			},
			tutorialDone = true,
			rewardChoice = {},
			interruptedRunId = "",
		}
	end

	local function snapshot()
		return {
			global = {
				seq = 0,
				data = {
					run = { phase = "Prep", phaseStartedAt = 1000 },
					lobby = { mission = "M1", ready = 0, total = 2, leader = ME },
					players = {
						[ME] = {
							name = "Tester",
							display = "Tester",
							ready = false,
							waiting = false,
							profile = "Ready",
							leader = true,
							device = "keyboard",
							order = 1,
						},
						["2002"] = {
							name = "Friend",
							display = "Best Friend",
							ready = true,
							waiting = false,
							profile = "Loading",
							leader = false,
							device = "touch",
							order = 2,
						},
					},
					roster = {},
				},
			},
			me = {
				seq = 0,
				data = {
					profile = profile(),
					missions = {
						M0 = { kind = "credits", credits = 80, unlocked = true },
						M1 = {
							kind = "skin",
							item = "laundry_royal",
							credits = 20,
							choice = "laundry_royal",
							unlocked = true,
						},
						M2 = {
							kind = "blueprint",
							item = "Freezer",
							credits = 20,
							choice = "freezer_lodge",
							unlocked = true,
						},
						M3 = { kind = "skin", item = "fan_retro", credits = 20, choice = "fan_retro", unlocked = false },
						M4 = { kind = "skin", item = "case_gold", credits = 20, choice = "case_gold", unlocked = false },
						M5 = { kind = "blueprint", item = "Greenhouse", credits = 20, unlocked = false },
						M6 = { kind = "blueprint", item = "Magnet", credits = 20, unlocked = false },
					},
				},
			},
		}
	end

	-- Boot the shipped client bootstrap (init.client.luau) inside the harness. `prepare` runs first, against
	-- the place the client is about to see.
	local function boot(prepare: ((any) -> ())?)
		local client = ClientEnv.new(ctx.placePath)
		client.snapshot = snapshot()
		if prepare then
			prepare(client)
		end
		local script = client.clientRoot
		local env = table.clone(client.loaded.env)
		env.script = script
		env.require = client.loaded.require
		local fn = luau.load(script.Source, { debugName = "Client", environment = env, injectGlobals = true })
		local ok, err = xpcall(fn, function(e: any): string
			local okText, text = pcall(tostring, e)
			return if okText then text else "<unprintable error>"
		end)
		if not ok then
			table.insert(client.errors, tostring(err))
		end
		task.wait(0.05)
		return client
	end

	local function assertClean(client)
		if #client.errors > 0 then
			error("interface errors:\n" .. table.concat(client.errors, "\n----\n"))
		end
	end

	local function textOf(client, name: string): string?
		local inst = client:find(name)
		return if inst then inst.Text else nil
	end

	describe("Lobby and menu interface (U15-U20)", function()
		it("boots the real client bootstrap with the lobby HUD and menu bar", function()
			local client = boot()
			assertClean(client)
			expect(client:find("LobbyHud")).toBeTruthy()
			expect(client:find("MenuBar")).toBeTruthy()
			expect(client:find("PlayButton")).toBeTruthy()
			expect(client:find("Player_" .. ME)).toBeTruthy()
			expect(client:find("Player_2002")).toBeTruthy()
			-- ClientReady went out with a valid device kind.
			expect(#client:sentNamed("ClientReady")).toBe(1)
			-- Every screen registered.
			local UIRoot = client:module("UI.UIRoot")
			for _, name in { "MissionBoard", "Collection", "Settings", "Results", "Feedback", "Debug" } do
				expect(UIRoot.get(name) ~= nil).toBe(true)
			end
		end)

		it("readies up with PLAY and shows the ready state", function()
			local client = boot()
			client:press(client:find("PlayButton"))
			local sent = client:sentNamed("SetReady")
			expect(#sent).toBe(1)
			expect(sent[1].args[1]).toBe(true)
			local players = snapshot().global.data.players
			players[ME].ready = true
			client:patch("global", { "players" }, players)
			client:patch(
				"global",
				{ "lobby" },
				{ mission = "M1", ready = 2, total = 2, leader = ME, countdownEndsAt = 1003 }
			)
			task.wait(0.05)
			expect(client:find("ReadyButton").Visible).toBe(true)
			expect(client:find("PlayButton").Visible).toBe(false)
			-- Heartbeat drives the countdown label.
			client.services.RunService.Heartbeat:Fire(0.1)
			expect(client:find("Countdown").Visible).toBe(true)
			assertClean(client)
		end)

		it("browses every mission on the board and lets the leader choose one", function()
			local client = boot()
			local UIRoot = client:module("UI.UIRoot")
			local MissionBoard = client:module("UI.Screens.MissionBoard")
			UIRoot.open("MissionBoard")
			expect(UIRoot.isOpen("MissionBoard")).toBe(true)
			for _, id in { "M0", "M1", "M2", "M3", "M4", "M5", "M6" } do
				MissionBoard.focus(id)
			end
			MissionBoard.focus("M2")
			local choose = client:find("Choose")
			expect(choose).toBeTruthy()
			client:press(choose)
			local sent = client:sentNamed("SelectMission")
			expect(#sent).toBe(1)
			expect(sent[1].args[1]).toBe("M2")
			-- Pick the bonus skin target for M2.
			local skinButtons = {}
			for _, d in client:find("TargetPicker"):GetDescendants() do
				if d.ClassName == "TextButton" and string.sub(d.Name, 1, 7) == "Target_" then
					table.insert(skinButtons, d)
				end
			end
			expect(#skinButtons).toBeGreaterThan(0)
			client:press(skinButtons[1])
			expect(#client:sentNamed("SelectReward")).toBe(1)
			task.wait(0.45)
			expect(UIRoot.isOpen("MissionBoard")).toBe(false)
			assertClean(client)
		end)

		it("edits the loadout, equips and buys skins in the collection", function()
			local client = boot()
			local UIRoot = client:module("UI.UIRoot")
			UIRoot.open("Collection", "Laundry")
			expect(UIRoot.isOpen("Collection")).toBe(true)
			-- Equip Laundry into slot 2 (detail panel buttons).
			local actions = client:find("Actions")
			local buttons = {}
			for _, d in actions:GetChildren() do
				if d.ClassName == "TextButton" then
					table.insert(buttons, d)
				end
			end
			expect(#buttons).toBe(2)
			client:press(buttons[2])
			local sent = client:sentNamed("SetLoadout")
			expect(#sent).toBe(1)
			expect(sent[1].args[1]).toBe("Freezer")
			expect(sent[1].args[2]).toBe("Laundry")
			-- Equipping Fan into slot 1 swaps the slots.
			client:press(client:find("Room_Fan"))
			local swapButtons = {}
			for _, d in client:find("Actions"):GetChildren() do
				if d.ClassName == "TextButton" then
					table.insert(swapButtons, d)
				end
			end
			client:press(swapButtons[1])
			sent = client:sentNamed("SetLoadout")
			expect(sent[2].args[1]).toBe("Fan")
			expect(sent[2].args[2]).toBe("Freezer")
			-- Skins tab: pick a shop skin and buy it through the confirmation.
			local tabButtons = {}
			for _, d in client:find("Tabs"):GetChildren() do
				if d.ClassName == "TextButton" then
					tabButtons[d.LayoutOrder] = d
				end
			end
			client:press(tabButtons[2])
			client:press(client:find("Skin_freezer_icecream"))
			local buy = nil
			for _, d in client:find("Actions"):GetChildren() do
				if d.ClassName == "TextButton" then
					buy = d
				end
			end
			expect(buy).toBeTruthy()
			client:press(buy)
			expect(UIRoot.isOpen("BuyConfirm")).toBe(true)
			client:press(client:find("BuyConfirm"):FindFirstChild("Confirm", true))
			expect(#client:sentNamed("BuySkin")).toBe(1)
			expect(client:sentNamed("BuySkin")[1].args[1]).toBe("freezer_icecream")
			-- Suitcases tab.
			client:press(tabButtons[3])
			client:press(client:find("Skin_case_leather"))
			-- Profile updates refresh the open screen.
			local p = profile()
			p.credits = 380
			p.skins.owned.freezer_icecream = true
			client:patch("me", { "profile" }, p)
			task.wait(0.05)
			assertClean(client)
		end)

		it("applies settings instantly and saves them", function()
			local client = boot()
			local UIRoot = client:module("UI.UIRoot")
			local SettingsController = client:module("Controllers.SettingsController")
			UIRoot.open("Settings")
			expect(UIRoot.isOpen("Settings")).toBe(true)
			for _, key in { "reducedMotion", "lowEffects", "hints", "cameraShake" } do
				expect(client:find("Toggle_" .. key)).toBeTruthy()
			end
			client:press(client:find("Toggle_reducedMotion"):FindFirstChild("Hit"))
			expect(SettingsController.get().reducedMotion).toBe(true)
			task.wait(1.4)
			local saves = client:sentNamed("SaveSettings")
			expect(#saves).toBe(1)
			expect(saves[1].args[1].reducedMotion).toBe(true)
			-- Menu action toggles the screen.
			UIRoot.close("Settings")
			expect(UIRoot.isOpen("Settings")).toBe(false)
			assertClean(client)
		end)

		it("shows a successful expedition honestly and asks for feedback", function()
			local client = boot()
			local UIRoot = client:module("UI.UIRoot")
			client:patch("global", { "run" }, { phase = "Results", id = "run-1", outcome = "Success", mission = "M2" })
			client:patch("me", { "results" }, {
				runId = "run-1",
				mission = "M2",
				outcome = "Success",
				success = true,
				duration = 412,
				timeLeft = 37,
				keys = 2,
				keysTotal = 3,
				combo = "ice_launch",
				combos = { "ice_bridge", "ice_launch" },
				deploys = 6,
				saving = "Saving",
				tutorial = false,
				plan = {
					blueprint = "Freezer",
					credits = 95,
					duplicate = false,
					firstClear = true,
					challenges = { M2_launch = true },
					lines = {
						{ key = "reward.blueprint", item = "Freezer" },
						{ key = "reward.extraction", amount = 20 },
						{ key = "reward.keys", amount = 20 },
						{ key = "reward.firstClear", amount = 30 },
						{ key = "reward.challenge", amount = 30, item = "M2_launch" },
					},
				},
			})
			task.wait(0.05)
			expect(UIRoot.isOpen("Results")).toBe(true)
			expect(textOf(client, "Headline")).toBe("ROOM STOLEN!")
			-- Saving -> Saved updates in place and never shows Saved early.
			local savingRow = client:find("Saving")
			expect(savingRow.Visible).toBe(true)
			local p = profile()
			p.stats.runs = 1
			client:patch("me", { "profile" }, p)
			client:patch("me", { "results", "saving" }, "Saved")
			task.wait(0.05)
			client:press(client:find("Lobby"))
			local acks = client:sentNamed("ResultsAction")
			expect(#acks).toBe(1)
			expect(acks[1].args[1]).toBe("lobby")
			expect(UIRoot.isOpen("Results")).toBe(false)
			task.wait(0.8)
			expect(UIRoot.isOpen("Feedback")).toBe(true)
			client:press(client:find("Star5"))
			client:press(client:find("Feedback"):FindFirstChild("Send", true))
			local feedback = client:sentNamed("Feedback")
			expect(#feedback).toBe(1)
			expect(feedback[1].args[1]).toBe(5)
			assertClean(client)
		end)

		it("shows a failed expedition without implying any reward", function()
			local client = boot()
			local UIRoot = client:module("UI.UIRoot")
			client:patch(
				"global",
				{ "run" },
				{ phase = "Results", id = "run-2", outcome = "Wiped", cause = "caretaker", mission = "M1" }
			)
			client:patch("me", { "results" }, {
				runId = "run-2",
				mission = "M1",
				outcome = "Wiped",
				cause = "caretaker",
				success = false,
				duration = 300,
				timeLeft = 0,
				keys = 0,
				keysTotal = 2,
				combos = {},
				deploys = 2,
				saving = "Idle",
				tutorial = false,
			})
			task.wait(0.05)
			expect(UIRoot.isOpen("Results")).toBe(true)
			expect(textOf(client, "Headline")).toBe("CAUGHT!")
			-- The reason and a tip instead of a generic line.
			expect(textOf(client, "Subtitle")).toBe("The Caretaker caught the whole squad.")
			expect(client:find("Saving").Visible).toBe(false)
			-- First finished run: the survey is due, but PLAY AGAIN goes straight back in without it.
			local p = profile()
			p.stats.runs = 1
			client:patch("me", { "profile" }, p)
			task.wait(0.05)
			client:press(client:find("Replay"))
			expect(client:sentNamed("ResultsAction")[1].args[1]).toBe("replay")
			task.wait(0.8)
			expect(UIRoot.isOpen("Results")).toBe(false)
			expect(UIRoot.isOpen("Feedback")).toBe(false)
			assertClean(client)
		end)

		it("shows content switched off live as resting and never offers it (S32)", function()
			local client = boot()
			local UIRoot = client:module("UI.UIRoot")
			local MissionBoard = client:module("UI.Screens.MissionBoard")
			client:patch("global", { "flags" }, {
				environment = "studio",
				disabledRooms = { Laundry = true },
				disabledMissions = { M2 = true },
				features = { shop = false },
			})
			task.wait(0.05)
			-- Mission board: M2 is closed for maintenance and cannot be chosen.
			UIRoot.open("MissionBoard")
			MissionBoard.focus("M2")
			expect(textOf(client, "FooterText")).toBe("Closed for maintenance")
			client:press(client:find("Choose"))
			expect(#client:sentNamed("SelectMission")).toBe(0)
			UIRoot.close("MissionBoard")
			-- Collection: Laundry is still owned but resting; its equip buttons do nothing.
			UIRoot.open("Collection", "Laundry")
			local function hasText(root, text: string): boolean
				for _, d in root:GetDescendants() do
					if d.ClassName == "TextLabel" and d.Text == text then
						return true
					end
				end
				return false
			end
			local collection = client:find("Collection")
			expect(hasText(collection, "That room is resting for maintenance")).toBe(true)
			-- (The preview's room model shares the name; the card is the button.)
			local card = nil
			for _, candidate in client:findAll("Room_Laundry") do
				if candidate.ClassName == "TextButton" then
					card = candidate
				end
			end
			expect(card).toBeTruthy()
			expect(hasText(card, "Resting")).toBe(true)
			for _, d in client:find("Actions"):GetChildren() do
				if d.ClassName == "TextButton" then
					client:press(d)
				end
			end
			expect(#client:sentNamed("SetLoadout")).toBe(0)
			-- Back on: the room can be equipped again.
			client:patch("global", { "flags" }, { environment = "studio", disabledRooms = {}, disabledMissions = {} })
			task.wait(0.05)
			expect(hasText(collection, "That room is resting for maintenance")).toBe(false)
			assertClean(client)
		end)

		it("invites friends from the open seat in the squad list (S17)", function()
			local client = boot()
			task.wait(0.05)
			local invite = client:find("Invite")
			expect(invite).toBeTruthy()
			client:press(invite)
			expect(client.invitePrompts).toBe(1)
			-- A full squad has no open seat.
			local players = {}
			for i = 1, 4 do
				players[tostring(1000 + i)] = {
					name = "P" .. i,
					display = "P" .. i,
					order = i,
					profile = "Ready",
					ready = false,
					waiting = false,
				}
			end
			expect(players[ME]).toBeTruthy() -- the local player is one of the four
			client:patch("global", { "players" }, players)
			task.wait(0.05)
			expect(client:find("Invite")).toBe(nil)
			assertClean(client)
		end)

		it("marks rooms unlocked this session as NEW until the player looks at them", function()
			local client = boot()
			local UIRoot = client:module("UI.UIRoot")
			local badge = client:find("Item_suitcase"):FindFirstChild("Badge", true)
			expect(badge).toBeTruthy()
			expect(badge.Visible).toBe(false) -- what the profile loaded with is old news
			-- A run ends with a new blueprint.
			local p = profile()
			p.rooms.Greenhouse = true
			client:patch("me", { "profile" }, p)
			task.wait(0.05)
			expect(badge.Visible).toBe(true)
			expect(badge:FindFirstChild("Count", true).Text).toBe("1")
			UIRoot.open("Collection")
			local card = nil
			for _, candidate in client:findAll("Room_Greenhouse") do
				if candidate.ClassName == "TextButton" then
					card = candidate
				end
			end
			local isNew = false
			for _, d in card:GetDescendants() do
				if d.ClassName == "TextLabel" and d.Text == "NEW" then
					isNew = true
				end
			end
			expect(isNew).toBe(true)
			-- Looking at it clears the mark.
			client:press(card)
			task.wait(0.05)
			expect(badge.Visible).toBe(false)
			assertClean(client)
		end)

		it("hides lobby-only interface during an expedition", function()
			local client = boot()
			client:patch("global", { "roster" }, {
				[ME] = { name = "Tester", display = "Tester", status = "Active", hearts = 3, max = 3, order = 1 },
			})
			client:patch("global", { "run" }, { phase = "Explore", id = "run-3", mission = "M1" })
			task.wait(0.05)
			expect(client:find("LobbyHud").Visible).toBe(false)
			expect(client:find("Item_board").Visible).toBe(false)
			expect(client:find("Item_question").Visible).toBe(true)
			local UIRoot = client:module("UI.UIRoot")
			UIRoot.open("Settings")
			expect(client:find("RunActions").Visible).toBe(true)
			assertClean(client)
		end)

		it("keeps the chat window clear of the HUD: right edge with keys or a pad, Roblox's spot on touch", function()
			local client = boot(function(c)
				roblox.Instance.new("ChatWindowConfiguration").Parent = c.loaded.game:GetService("TextChatService")
			end)
			task.wait(0.05)
			local window =
				client.loaded.game:GetService("TextChatService"):FindFirstChildOfClass("ChatWindowConfiguration")
			expect(window.HorizontalAlignment).toBe(roblox.Enum.HorizontalAlignment.Right)
			expect(window.VerticalAlignment).toBe(roblox.Enum.VerticalAlignment.Center)
			-- ClientEnv stubs Device; its Changed signal stands in for the player picking up another input.
			local Device = client:module("Core.Device")
			Device.Changed:Fire("touch")
			task.wait(0.05)
			expect(window.HorizontalAlignment).toBe(roblox.Enum.HorizontalAlignment.Left)
			expect(window.VerticalAlignment).toBe(roblox.Enum.VerticalAlignment.Top)
			Device.Changed:Fire("gamepad")
			task.wait(0.05)
			expect(window.HorizontalAlignment).toBe(roblox.Enum.HorizontalAlignment.Right)
			assertClean(client)
		end)

		it("gives admins the test tools and shows toasts", function()
			local client = boot()
			client:patch("me", { "admin" }, true)
			task.wait(0.05)
			expect(client:find("Item_bolt").Visible).toBe(true)
			local UIRoot = client:module("UI.UIRoot")
			UIRoot.open("Debug")
			local commands = client:find("Commands")
			local first = nil
			for _, d in commands:GetDescendants() do
				if d.ClassName == "TextButton" and d.Name == "Button" then
					first = d
					break
				end
			end
			client:press(first)
			expect(#client:sentNamed("Debug")).toBe(1)
			client:fire("Toast", "success", "toast.bought", { item = "skin.freezer_icecream" })
			task.wait(0.05)
			expect(client:find("Toast")).toBeTruthy()
			assertClean(client)
		end)
	end)
end
