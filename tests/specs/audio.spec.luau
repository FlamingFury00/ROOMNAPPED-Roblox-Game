--[[
	Audio content checks (A06, A10).

	* Every sound the code plays by a literal name exists in AudioIds (a typo would otherwise fail silently).
	* Every cue in tools/content/audio_catalog.json, primary and alternates, is Roblox-owned or from Roblox's
	  licensed partner libraries.
	* Nothing synthesized ships: no synth tones, 8-bit blips, chiptune or electronic beeps, as a primary or
	  as a runtime alternate. Recorded sounds and licensed music only.
]]
local fs = require("@lune/fs")
local serde = require("@lune/serde")

return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect
	local AudioIds = ctx.module("ReplicatedStorage.Shared.Config.AudioIds")

	-- Calls and props that name a sound with a string literal.
	local PATTERNS = {
		'[%.:]sound%(%s*"([%w_]+)"', -- Components.sound("ui_click")
		'^sound%(%s*"([%w_]+)"',
		'[^%w_]sound%(%s*"([%w_]+)"',
		'%.ui%(%s*"([%w_]+)"', -- AudioController.ui("ui_coin")
		'%.play%(%s*"([%w_]+)"', -- AudioController.play("elevator_ding")
		'%.at%(%s*"([%w_]+)"',
		'%.loop%(%s*"([%w_]+)"',
		'playSting%(%s*"([%w_]+)"',
		'setMusic%(%s*"([%w_]+)"',
		'setAmbience%(%s*"([%w_]+)"',
		'sound%s*=%s*"([%w_]+)"', -- Components.button({ sound = "ui_ready" }) and effect tables
	}
	local SYNTHESIZED = { "synth", "8bit", "8-bit", "chiptune", "electronic", "beep" }

	local function luauFiles(dir: string, out: { string })
		for _, name in fs.readDir(dir) do
			local path = dir .. "/" .. name
			if fs.isDir(path) then
				luauFiles(path, out)
			elseif string.sub(name, -5) == ".luau" then
				table.insert(out, path)
			end
		end
		return out
	end

	describe("Audio content (A06/A10)", function()
		it("has every sound the code plays by name", function()
			local missing = {}
			local checked = 0
			for _, path in luauFiles("src", {}) do
				if not string.find(path, "AudioIds.luau", 1, true) then
					local source = fs.readFile(path)
					for _, pattern in PATTERNS do
						for name in string.gmatch(source, pattern) do
							checked += 1
							if AudioIds[name] == nil then
								table.insert(missing, path .. ": " .. name)
							end
						end
					end
				end
			end
			if #missing > 0 then
				error("sounds played by name but missing from AudioIds:\n" .. table.concat(missing, "\n"))
			end
			expect(checked > 20).toBe(true) -- the patterns still find the calls
		end)

		it("ships only Roblox and licensed partner audio, none of it synthesized", function()
			local catalog = serde.decode("json", fs.readFile("tools/content/audio_catalog.json"))
			local problems = {}
			for key, entry in catalog do
				if type(entry) == "table" and entry.id ~= nil then
					local items = { entry }
					for _, alternate in entry.alternates or {} do
						table.insert(items, alternate)
					end
					for _, item in items do
						if item.source ~= "roblox" and item.source ~= "partner" then
							table.insert(
								problems,
								string.format("%s: %s has source %s", key, item.name, tostring(item.source))
							)
						end
						local lower = string.lower(item.name)
						for _, word in SYNTHESIZED do
							if string.find(lower, word, 1, true) then
								table.insert(
									problems,
									string.format("%s: %s sounds synthesized (%s)", key, item.name, word)
								)
							end
						end
					end
					expect(AudioIds[key] ~= nil).toBe(true)
					expect(AudioIds[key].id).toBe(entry.id)
				end
			end
			if #problems > 0 then
				error("audio catalog problems:\n" .. table.concat(problems, "\n"))
			end
		end)
	end)
end
