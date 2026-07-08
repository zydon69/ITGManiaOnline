local af = Def.ActorFrame{}
local bg_width = WideScale(287, 292)
local bg_height = 350
local padding = 10
local recommended_bmt
local recommended_string = THEME:GetString("RecommendedOptionExplanations", "Recommended")

local function log_global_offset_child(reason)
	if PREFSMAN and PREFSMAN.LogGlobalOffsetDiagnostics then
		PREFSMAN:LogGlobalOffsetDiagnostics("lua_operator_child_options:" .. tostring(reason))
	end
end

local function RenameActiveGlobalOffsetProfile()
	local top = SCREENMAN:GetTopScreen()
	if not top or top:GetName() ~= "ScreenGraphicsSoundOptions" then return false end
	if type(OpenGlobalOffsetProfileRenameScreen) ~= "function" then
		log_global_offset_child("rename_shortcut_unavailable")
		return false
	end

	local pn = GAMESTATE:GetMasterPlayerNumber()
	local row_index = top:GetCurrentRowIndex(pn)
	local row = top:GetOptionRow(row_index)
	local row_name = row and row:GetName() or "nil"
	log_global_offset_child("start_pressed row_index=" .. tostring(row_index) .. " row=" .. tostring(row_name))
	if row_name ~= "GlobalOffsetProfile" then return false end

	return OpenGlobalOffsetProfileRenameScreen(PREFSMAN:GetGlobalOffsetProfileSelected()) == true
end

local InputHandler = function(event)
	if not event then return false end
	if event.type == "InputEventType_FirstPress" and event.GameButton == "Start" then
		if RenameActiveGlobalOffsetProfile() then return true end
	end
	return false
end

af.OnCommand=function(self)
	local top = SCREENMAN:GetTopScreen()
	local ScreenName = top:GetName()
	if ScreenName == "ScreenMapControllers"
	or ScreenName == "ScreenTestInput" or ScreenName == "ScreenBookkeeping" then
		self:visible(false)
		return
	end

	if ScreenName == "ScreenGraphicsSoundOptions" then
		top:SetInputCallbacksHandleBeforeScreen(true)
		top:AddInputCallback(InputHandler)
		log_global_offset_child("rename_shortcut_enabled")
	end

	self:xy(WideScale(490,683), _screen.cy - 15.5)
end

af.OffCommand=function(self)
	local top = SCREENMAN:GetTopScreen()
	if top and top:GetName() == "ScreenGraphicsSoundOptions" then
		top:RemoveInputCallback(InputHandler)
		top:SetInputCallbacksHandleBeforeScreen(false)
		log_global_offset_child("rename_shortcut_disabled")
	end
end

af.OptionRowChangedMessageCommand=function(self, params)
	local OptionRowName = params.Title:GetParent():GetParent():GetName()
	self:playcommand("Update", {Name=OptionRowName} )
end

af[#af+1] = Def.Quad{
	InitCommand=function(self)
		self:zoomto(bg_width, bg_height)
		self:diffuse(DarkUI() and color("#666666") or color("#333333"))
	end,
}

af[#af+1] = Def.BitmapText{
	Font="Common Normal",
	InitCommand=function(self)
		self:xy(- bg_width/2 + padding, -bg_height/2 + padding)
			:valign(0)
			:halign(0)
			:_wrapwidthpixels(bg_width-padding*2)
	end,
	UpdateCommand=function(self, params)
		self:settext( THEME:GetString("OptionExplanations", params.Name) ):_wrapwidthpixels(bg_width-padding*2)
	end
}

af[#af+1] = Def.ActorFrame{
	Name="Recommended",
	UpdateCommand=function(self, params)
		self:visible( THEME:HasString("RecommendedOptionExplanations", params.Name) and THEME:GetString("RecommendedOptionExplanations", params.Name) ~= "" )
	end,

	Def.BitmapText{
		Font="Common Normal",
		InitCommand=function(self)
			recommended_bmt = self

			self:xy(- bg_width/2 + padding, bg_height/2 - padding)
				:valign(1) -- bottom aligned
				:halign(0) -- left aligned
				:_wrapwidthpixels(bg_width-padding*2)
		end,
		UpdateCommand=function(self, params)
			if THEME:HasString("RecommendedOptionExplanations", params.Name) then
				self:settext( recommended_string .. ": " .. THEME:GetString("RecommendedOptionExplanations", params.Name) )
				self:_wrapwidthpixels(bg_width-padding*2)
			else
				self:settext("")
			end
		end,
	},

	Def.Quad{
		InitCommand=function(self) self:zoomto(bg_width-padding*2, 1):y(-padding) end,
		UpdateCommand=function(self, params)
			self:y( bg_height/2 - padding*2 - recommended_bmt:GetHeight() )
		end
	},
}

return af
