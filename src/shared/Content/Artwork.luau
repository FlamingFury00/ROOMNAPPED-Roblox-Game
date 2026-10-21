--!strict
--[[
	Artwork: classic public-domain paintings for the hotel's picture frames (A01, A10).

	Image asset ids (not decal ids) of free Creator Store images, with their aspect (width / height). Frames
	pick a painting whose shape fits; with no artwork listed (or none that fits) a frame shows the procedural
	scene instead. Provenance: docs/CONTENT_OWNERSHIP.md.
]]

export type Painting = { image: number, aspect: number }

local Artwork = {}

Artwork.paintings = {} :: { Painting }

-- A painting for a frame of the given aspect (nil when none fits within 30 %).
function Artwork.pick(roll: number, aspect: number): Painting?
	local fits: { Painting } = {}
	for _, painting in Artwork.paintings do
		local ratio = painting.aspect / aspect
		if ratio > 0.77 and ratio < 1.3 then
			table.insert(fits, painting)
		end
	end
	if #fits == 0 then
		return nil
	end
	return fits[math.clamp(math.floor(roll * #fits) + 1, 1, #fits)]
end

return Artwork
