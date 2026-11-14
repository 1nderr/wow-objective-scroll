local _, ns = ...

local DEFAULTS = {
	enabled = true,
	barWidth = 8,
	barColor = { 96 / 255, 96 / 255, 96 / 255 },
}

function ns.GetDatabase()
	-- We do this in case the database variable is nil, in which
	-- case we set it to an empty map
	ObjectiveScrollDB = ObjectiveScrollDB or {}

	if ObjectiveScrollDB.enabled == nil then
		ObjectiveScrollDB.enabled = DEFAULTS.enabled
	end

	if type(ObjectiveScrollDB.barWidth) ~= "number" then
		ObjectiveScrollDB.barWidth = DEFAULTS.barWidth
	end

	if type(ObjectiveScrollDB.barColor) ~= "table" or #ObjectiveScrollDB.barColor < 3 then
		ObjectiveScrollDB.barColor = { unpack(DEFAULTS.barColor) }
	end

	return ObjectiveScrollDB
end

function ns.ResetDatabase()
	local db = ns.GetDatabase()
	db.enabled = DEFAULTS.enabled
	db.barWidth = DEFAULTS.barWidth
	db.barColor = { unpack(DEFAULTS.barColor) }
end
