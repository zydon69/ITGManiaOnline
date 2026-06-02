local request = SL and SL.Global and SL.Global.EvaluationLazyPaneRequest

if type(request) ~= "table" or not request.PaneIndex then
	return Def.ActorFrame{}
end

local pane_path = request.PanePath or THEME:GetPathB(
	"ScreenEvaluation",
	"common/Panes/Pane" .. tostring(request.PaneIndex) .. "/default.lua"
)

return LoadActor(pane_path, {
	request.Player,
	request.Controller,
	request.ComputedData
})
