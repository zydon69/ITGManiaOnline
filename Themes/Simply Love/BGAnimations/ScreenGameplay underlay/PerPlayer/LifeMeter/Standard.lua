local player = ...

local w = 136
local h = 18
local _y = 20
local side_margin = 4
local show_swoosh = SL[ToEnumShortString(player)].ActiveModifiers.LifeMeterSwoosh == true
local style = GAMESTATE:GetCurrentStyle()
local style_type = style and style:GetStyleType()
local style_type_name = style_type and ToEnumShortString(style_type) or ""
local is_shared_sides = style_type_name == "TwoPlayersSharedSides"

local function resolve_lifebar_x(player_number)
	local notefield_x = GetNotefieldX(player_number)
	local panel_width = GetNotefieldWidth() or w
	if IsUsingOnlineGameplayColumns and IsUsingOnlineGameplayColumns() then
		panel_width = GetOnlineGameplayPanelWidth and GetOnlineGameplayPanelWidth("side") or panel_width
	elseif is_shared_sides then
		local metric = player_number == PLAYER_1 and "PlayerP1TwoPlayersTwoSidesX" or "PlayerP2TwoPlayersTwoSidesX"
		notefield_x = THEME:GetMetric("ScreenGameplay", metric)
		panel_width = 256
	end
	if player_number == PLAYER_1 then
		return (notefield_x - panel_width / 2) + side_margin + w / 2
	else
		return (notefield_x + panel_width / 2) - side_margin - w / 2
	end
end

local _x = resolve_lifebar_x(player)

-- get SongPosition specific to this player so that
-- split BPMs are handled if there are any
local songposition = GAMESTATE:GetPlayerState(player):GetSongPosition()
local swoosh, velocity

local Update = function(self)
	if not swoosh then return end
	velocity = -(songposition:GetCurBPS() * 0.5)
	if songposition:GetFreeze() or songposition:GetDelay() then velocity = 0 end
	swoosh:texcoordvelocity(velocity,0)
end

local meter = Def.ActorFrame{

	InitCommand=function(self)
		self:y(_y):SetUpdateFunction(Update):visible(false)
		Trace("ROUTINE_LAYOUT LifeMeterStandard"
			.. " player=" .. tostring(ToEnumShortString(player))
			.. " style_type=" .. tostring(style_type_name)
			.. " shared=" .. tostring(is_shared_sides)
			.. " x=" .. tostring(_x)
			.. " y=" .. tostring(_y)
			.. " w=" .. tostring(w)
			.. " h=" .. tostring(h))
	end,
	OnCommand=function(self) self:visible(true) end,

	-- frame
	Def.Quad{ InitCommand=function(self) self:x(_x):zoomto(w+4, h+4) end },
	Def.Quad{ InitCommand=function(self) self:x(_x):zoomto(w, h):diffuse(0,0,0,1) end },

	-- the Quad that changes width/color depending on current Life
	Def.Quad{
		Name="MeterFill",
		InitCommand=function(self) self:zoomto(0,h):diffuse(PlayerColor(player,true)):horizalign(left) end,
		OnCommand=function(self) self:x( _x - w/2 ) end,

		-- check whether the player's LifeMeter is "Hot"
		-- in LifeMeterBar.cpp, the engine says a LifeMeter is Hot if the current
		-- LifePercentage is greater than or equal to the HOT_VALUE, which is
		-- defined in Metrics.ini under [LifeMeterBar] like HotValue=1.0
		HealthStateChangedMessageCommand=function(self,params)
			if params.PlayerNumber == player then
				if params.HealthState == 'HealthState_Hot' then
					self:diffuse(1,1,1,1)
				else
					-- ~~man's~~ lifebar's not hot
					self:diffuse( PlayerColor(player,true) )
				end
			end
		end,

		-- when the engine broadcasts that the player's LifeMeter value has changed
		-- change the width of this MeterFill Quad to accommodate
		LifeChangedMessageCommand=function(self,params)
			if params.Player == player then
				local life = params.LifeMeter:GetLife() * w
				self:finishtweening()
				self:bouncebegin(0.1):zoomx( life )
			end
		end,
	},

	-- a simple scrolling gradient texture applied on top of MeterFill
	LoadActor("swoosh.png")..{
		Name="MeterSwoosh",
		InitCommand=function(self)
			swoosh = self
			if not show_swoosh then
				self:visible(false)
				return
			end

			self:zoomto(w,h)
				 :diffusealpha(0.2)
				 :horizalign( left )
		end,
		OnCommand=function(self)
			self:x(_x - w/2)
			self:customtexturerect(0,0,1,1)
			--texcoordvelocity is handled by the Update function below
		end,
		HealthStateChangedMessageCommand=function(self,params)
			if not show_swoosh then return end
			if(params.PlayerNumber == player) then
				if(params.HealthState == 'HealthState_Hot') then
					self:diffusealpha(1)
				else
					self:diffusealpha(0.2)
				end
			end
		end,

		-- life-changing
		-- adjective
		--  /ˈlaɪfˌtʃeɪn.dʒɪŋ/
		-- having an effect that is strong enough to change someone's life
		-- synonyms: compelling, life-altering, puissant, blazing
		LifeChangedMessageCommand=function(self,params)
			if not show_swoosh then return end
			if params.Player == player then
				local life = params.LifeMeter:GetLife() * w
				self:finishtweening()
				self:bouncebegin(0.1):zoomto( life, h )
			end
		end
	}
}

return meter

-- copyright 2008-2012 AJ Kelly/freem.
-- do not use this code in your own themes without my permission.
