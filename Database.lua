local _, ns = ...

local DEFAULTS = {
	enabled = true,
}

function ns.GetDatabase()
	-- We do this in case the database variable is nil, in which
	-- case we set it to an empty map
	ObjectiveScrollDB = ObjectiveScrollDB or {}

	if ObjectiveScrollDB.enabled == nil then
		ObjectiveScrollDB.enabled = DEFAULTS.enabled
	end

	return ObjectiveScrollDB
end

function ns.ResetDatabase()
	local db = ns.GetDatabase()
	db.enabled = DEFAULTS.enabled
end
