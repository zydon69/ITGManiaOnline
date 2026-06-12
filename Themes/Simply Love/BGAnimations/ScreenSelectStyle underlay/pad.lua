local color_used, color_unused, padNum, style = unpack(...)

color_used   = color_used   or {1, 1, 1, 1.0}
color_unused = color_unused or (DarkUI() and {0.25,0.25,0.25,1} or {1, 1, 1, 0.3})
padNum = padNum or 1
style  = style  or (GAMESTATE:GetCurrentStyle() and GAMESTATE:GetCurrentStyle():GetName())


local zoom = SL_WideScale(0.435, 0.525)
local game = GAMESTATE:GetCurrentGame():GetName()
local panel_spacing = 64
local panel_size = 58
local panel_radius = 7
local panel_corner_segments = 5

local init_panel = function(self, col, row, z)
	self:zoom(z)
	self:x(z * panel_spacing * (col-1))
	self:y(z * panel_spacing * (row-2))
	return self
end

local vertex_cache = {}

local color_key = function(color)
	return table.concat(color, ",")
end

local rounded_panel_vertices = function(color)
	local key = color_key(color)
	if vertex_cache[key] then return vertex_cache[key] end

	local h = panel_size / 2
	local r = math.min(panel_radius, h)
	local inset = h - r
	local verts = { {{0, 0, 0}, color} }
	local first_perimeter_vert = nil

	local corners = {
		{ inset, -inset, -90,   0 },
		{ inset,  inset,   0,  90 },
		{-inset,  inset,  90, 180 },
		{-inset, -inset, 180, 270 },
	}

	for corner in ivalues(corners) do
		local cx, cy, start_angle, end_angle = unpack(corner)
		for i=0,panel_corner_segments do
			local t = i / panel_corner_segments
			local angle = math.rad(start_angle + ((end_angle - start_angle) * t))
			local vertex = {{ cx + math.cos(angle) * r, cy + math.sin(angle) * r, 0 }, color}
			if not first_perimeter_vert then first_perimeter_vert = vertex end
			verts[#verts+1] = vertex
		end
	end

	verts[#verts+1] = first_perimeter_vert
	vertex_cache[key] = verts
	return verts
end

local layouts = {
	dance    = { false, true,  false, true,  false, true,  false, true,  false },
	pump     = { true,  false, true,  false, true,  false, true,  false, true  },
	techno   = { true,  true,  true,  true,  false, true,  true,  true,  true  },
	solo     = { true,  true,  true,  true,  false, true,  false, true,  false },
	threepanel = { true, false, true, false, false, false, false, true, false },
	inactive = { false, false, false, false, false, false, false, false, false }
}

-- -----------------------------------------------------------------------

local pad = Def.ActorFrame{}

for row=0,2 do
	for col=0,2 do
		local panel_index = row*3+col+1

		local panel_af = Def.ActorFrame{}
		panel_af.InitCommand=function(self)  end
		panel_af.SetCommand=function(self, params)
			local layout = layouts[game] or layouts.dance

			if game=="dance" and style=="solo" then
				layout = layouts.solo
			elseif game=="dance" and style=="threepanel" then
				layout = layouts.threepanel
			end

			if  params and params.Player
			and not GAMESTATE:IsHumanPlayer(params.Player)
			and style ~= "double"
			then
				layout = layouts.inactive
			end

			self:GetParent():playcommand("Reassess", layout)
		end

		panel_af[#panel_af+1] = Def.ActorMultiVertex{
			InitCommand=function(self)
				self:SetDrawState({Mode="DrawMode_Fan"})
				init_panel(self, col, row, zoom)
			end,
			ReassessCommand=function(self, layout)
				local color = color_unused
				if layout[panel_index] then
					color = color_used
				end
				local verts = rounded_panel_vertices(color)
				self:SetNumVertices(#verts):SetVertices(verts)
			end
		}

		pad[#pad+1] = panel_af
	end
end

-- -----------------------------------------------------------------------
-- https://www.youtube.com/watch?v=PKx_ihQ7mrY&lc=UgxXSurH391nm907OEh4AaABAg
if IsSpooky() then
	pad[#pad+1] = LoadActor("./ExtraSpooky.lua", {game, style, padNum, zoom, init_panel})
end
-- -----------------------------------------------------------------------

return pad
