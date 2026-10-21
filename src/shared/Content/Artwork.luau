--!strict
--[[
	Artwork: classic public-domain paintings for the hotel's picture frames (A01, A10).

	Image asset ids (not decal ids) of free Creator Store images, with their aspect (width / height). Frames
	pick a painting whose shape fits; with no artwork listed (or none that fits) a frame shows the procedural
	scene instead. Provenance: docs/CONTENT_OWNERSHIP.md.
]]

export type Painting = { image: number, aspect: number }

local Artwork = {}

-- Checked 2026-10-21: each is an Image asset (resolved from its decal by creator and upload time) whose
-- own thumbnail shows the painting, with no watermark or text.
Artwork.paintings = {
	{ image = 18430235398, aspect = 525 / 700 }, -- Rembrandt, The Storm on the Sea of Galilee (BrotherRaskolnikov)
	{ image = 1409031210, aspect = 535 / 700 }, -- Vigee Le Brun, Marie Antoinette and her Children (Rambo_builder)
	{ image = 72130553645630, aspect = 700 / 523 }, -- moonlit Ottoman coastal capriccio (SparterO9)
	{ image = 111154086863275, aspect = 505 / 700 }, -- ship in a stormy sea (dddu_dddu)
	{ image = 17206697773, aspect = 475 / 700 }, -- portrait of Georgiana Cavendish (mariontje)
	{ image = 1564409880, aspect = 527 / 700 }, -- The Man with the Golden Helmet (Andrew_Alba)
	{ image = 3360739154, aspect = 569 / 700 }, -- Dutch lady with a ruff collar (awsomesstv80415)
	{ image = 130601462587585, aspect = 600 / 700 }, -- Rembrandt Peale, Rubens Peale with a Geranium (rox_llq)
	{ image = 91327321009394, aspect = 700 / 520 }, -- still life with a clock and vases (Verity942)
	{ image = 140408481713108, aspect = 514 / 700 }, -- still life with a gold cup (Verity942)
	{ image = 6683780280, aspect = 700 / 467 }, -- Victorian landscape with a watermill (VIE_nnese)
	{ image = 5687258726, aspect = 623 / 700 }, -- Gainsborough, The Baillie Family (Annie_Sparkling)
	{ image = 16487841857, aspect = 700 / 433 }, -- stormy sea with a rowboat (Thxo_lgs)
	{ image = 230190583, aspect = 575 / 700 }, -- Rembrandt, St Paul in Prison (gordonfreeman564)
} :: { Painting }

-- A painting for a frame of the given aspect: one within 30 % of it when there is one, any otherwise (the
-- frame then takes the painting's shape). Nil only with no artwork at all.
function Artwork.pick(roll: number, aspect: number): Painting?
	local fits: { Painting } = {}
	for _, painting in Artwork.paintings do
		local ratio = painting.aspect / aspect
		if ratio > 0.77 and ratio < 1.3 then
			table.insert(fits, painting)
		end
	end
	if #fits == 0 then
		fits = Artwork.paintings
	end
	if #fits == 0 then
		return nil
	end
	return fits[math.clamp(math.floor(roll * #fits) + 1, 1, #fits)]
end

return Artwork
