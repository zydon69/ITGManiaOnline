local t = Def.ActorFrame {}

local screen = Var("LoadingScreen")

local function metric_bool(metric_name, default_value)
	if not THEME:HasMetric(screen, metric_name) then
		return default_value
	end

	local value = THEME:GetMetric(screen, metric_name)
	if value == nil then return default_value end

	if type(value) == "boolean" then return value end
	if type(value) == "number" then return value ~= 0 end
	if type(value) == "string" then
		if value == "1" or value == "true" or value == "yes" then return true end
		if value == "0" or value == "false" or value == "no" then return false end
		local lowered = value:lower()
		return lowered == "1" or lowered == "true" or lowered == "yes"
	end

	return default_value
end

local show_header = metric_bool("ShowHeader", true)
local show_footer = metric_bool("ShowFooter", true)

if show_header then
	t[#t+1] = StandardDecorationFromFile("Header", "Header")
end

if show_footer then
	t[#t+1] = StandardDecorationFromFile("Footer", "Footer")
end

return t
