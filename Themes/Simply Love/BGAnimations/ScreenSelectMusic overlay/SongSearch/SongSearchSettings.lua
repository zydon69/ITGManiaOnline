local FilterTable = function(arr, func)
	local new_index = 1
	local size_orig = #arr
	for v in ivalues(arr) do
		if func(v) then
			arr[new_index] = v
			new_index = new_index + 1
		end
	end
	for i = new_index, size_orig do arr[i] = nil end
end

local GetBpmTier = function(bpm)
	return math.floor((bpm + 0.5) / 10) * 10
end

local Trim = function(text)
	return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local NormalizeSearchTerm = function(text)
	text = Trim(text):lower()
	return (#text > 0) and text or nil
end

local PlainContains = function(haystack, needle)
	if not needle then return true end
	return tostring(haystack or ""):lower():find(needle, 1, true) ~= nil
end

local ParseSongSearchInput = function(input)
	local searchText = tostring(input or ""):lower()
	local query = {
		difficulty = nil,
		bpmTier = nil,
		packName = nil,
		songText = nil,
	}

	for match in searchText:gmatch("%[(%d+)]") do
		local value = tonumber(match)
		if value then
			if value <= 35 then
				query.difficulty = value
			else
				query.bpmTier = GetBpmTier(value)
			end
		end
	end

	searchText = Trim(searchText:gsub("%[%d+]", ""))

	local slashIndex = searchText:find("/", 1, true)
	if slashIndex then
		query.packName = NormalizeSearchTerm(searchText:sub(1, slashIndex - 1))
		query.songText = NormalizeSearchTerm(searchText:sub(slashIndex + 1))
	else
		query.songText = NormalizeSearchTerm(searchText)
	end

	return query
end

local SongMatchesText = function(song, term)
	if not term then return true end

	return PlainContains(song:GetDisplayFullTitle(), term)
		or PlainContains(song:GetTranslitFullTitle(), term)
		or PlainContains(song:GetDisplaySubTitle(), term)
		or PlainContains(song:GetTranslitSubTitle(), term)
		or PlainContains(song:GetDisplayArtist(), term)
		or PlainContains(song:GetTranslitArtist(), term)
end

return {
	Question="Search title/subtitle/artist\nUse 'pack/song' to limit by pack, '[12]' for difficulty, '[180]' for BPM",
	InitialAnswer="",
	MaxInputLength=30,
	OnOK=function(input)
		if #input == 0 then return end

		local query = ParseSongSearchInput(input)

		-- If we have no search criteria, then return early.
		if not (query.packName or query.songText or query.difficulty or query.bpmTier) then return end

		-- Start with the complete song list.
		local candidates = SONGMAN:GetAllSongs()
		local stepsType = GAMESTATE:GetCurrentStyle():GetStepsType()

		-- Only add valid candidates if there are steps in the current mode.
		FilterTable(candidates, function(song) return song:HasStepsType(stepsType) end)

		if query.songText then
			FilterTable(candidates, function(song) return SongMatchesText(song, query.songText) end)
		end

		if query.packName then
			FilterTable(candidates, function(song) return PlainContains(song:GetGroupName(), query.packName) end)
		end

		if query.difficulty then
			FilterTable(candidates, function(song)
				local allSteps = song:GetStepsByStepsType(stepsType)
				for steps in ivalues(allSteps) do
					-- Don't consider edits.
					if steps:GetDifficulty() ~= "Difficulty_Edit" then
						if steps:GetMeter() == query.difficulty then
							return true
						end
					end
				end
				return false
			end)
		end

		if query.bpmTier then
			FilterTable(candidates, function(song)
				-- NOTE(teejusb): Not handling split bpms now, sorry.
				local bpms = song:GetDisplayBpms()
				if bpms[2]-bpms[1] == 0 then
					-- If only one BPM, then check to see if it's in the same tier.
					return query.bpmTier == GetBpmTier(bpms[1])
				else
					-- Otherwise check and see if the bpm is in the span of the tier.
					local lowTier = GetBpmTier(bpms[1])
					local highTier = GetBpmTier(bpms[2])
					return lowTier <= query.bpmTier and query.bpmTier <= highTier
				end
			end)
		end

		-- Even if we don't have any results, we want to show that to the player.
		MESSAGEMAN:Broadcast("DisplaySearchResults", {searchText=input, candidates=candidates})
	end,
}
