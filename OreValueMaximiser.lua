--[[
	Ore Value Maximiser
	Objective: maximise the FINAL VALUE of ONE individual ore after the upgrader line.

	Sourced from the game's own client scripts:
	  - ReplicatedFirst.Client.Libraries.ItemValues   (BeamGroups / BestProduct / TagsFactor / TimedFactor / MaxMultiplier)
	  - ReplicatedFirst.Client.Libraries.Placement    (PlaceItem entries {CFrame, Name, State}, Pump response shapes)
	  - ReplicatedFirst.Client.Libraries.Data         (GetGroup("Items") owned counts, GetUnsafe("GameStats", ...))
	  - ReplicatedFirst.Client.Libraries.Stats        (GetValue("CashgradeCap") / ("CashgradeLimit"))
	  - ReplicatedFirst.Client.Libraries.Items        (conveyor flow along -ZVector, Upgrade parts with Id attribute)
	  - ReplicatedFirst.Client.Libraries.Items.Special.Sender / .Receiver (group = SpecialTags["Sender"/"Receiver"][1])
	  - ReplicatedFirst.Client.Dependencies.OnTycoonLoad.Base / OnLoad Base (player.ActiveTycoon -> model with child Part "Base")

	Buttons: SCAN INVENTORY / CALCULATE BEST ORDER / BUILD OPTIMISED FACTORY / STOP / STATUS (console F9).
]]

------------------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------------------

local CONFIG = {
	BATCH_SIZE            = 8,      -- PlaceItem entries per Invoke
	MAX_COPIES_PER_ITEM   = 1,      -- copies of the same owned upgrader to place (never more than owned)
	BEAM_WIDTH            = 160,    -- optimiser beam width
	MAX_CANDIDATES        = 48,     -- upgraders prefiltered into the search (best optimistic gain kept)
	MIN_CLEANSE_KEEP      = 4,      -- always keep at least this many cleansers in the candidate pool
	PLACEMENT_TIMEOUT     = 6,      -- seconds to wait for placed models to appear (verification)
	VERIFY_PLACEMENT      = true,   -- confirm placed models appear under tycoon.Items with result Id
	ROW_GAP               = 0,      -- extra cells between items inside a row
	BAND_GAP              = 1,      -- empty cells between rows
	EDGE_MARGIN           = 1,      -- cells kept clear from base edge
	UI_SCALE_MOBILE       = 0.9,
}

local FORBIDDEN_NAME_PATTERNS = {
	"cell furnace", "cellfurnace", "bhop", "b-hop", "vip conveyor", "vipConveyor",
}

-- Effects that damage/destroy ore value; an item applying them is only usable
-- if something later in the sequence removes them.
local DESTRUCTIVE_EFFECTS = {
	Fire = true, Poison = true, Overload = true, Weaken = true,
}

-- Specials whose outcome is chance-of-DESTRUCTION or otherwise cannot be
-- safely simulated -> item excluded from the optimiser (reported in diagnostics).
local RISKY_SPECIALS = {
	["Sacrifice"] = true, ["Marked for Death"] = true, ["Destroy Chance"] = true,
	["Tag Death Chance"] = true, ["Glitch"] = true, ["Cheaty Roulette"] = true,
	["Random Application"] = true, ["Life Link"] = true, ["Ring of Swords"] = true,
	["Effect Affinity"] = true, ["Multiple Effect Affinities"] = true,
}

-- Specials that do not change ore value for our purposes (layout/movement/visual).
local PASSIVE_SPECIALS = {
	["Sender"] = true, ["Receiver"] = true, ["Directional"] = true, ["Gate"] = true,
	["Tag Scanner"] = true, ["Value Scanner"] = true, ["Lap Counter"] = true,
	["Ore Stopper"] = true, ["Scale"] = true, ["Shape"] = true, ["Color"] = true,
	["Material"] = true, ["Turn"] = true, ["Sparkling"] = true, ["Starburst"] = true,
	["Plasma"] = true, ["Freeze"] = true, ["Tailwind"] = true,
	["Initial Velocity"] = true, ["Compression"] = true, ["Shiny Odds"] = true,
	["Golden Goose"] = true, ["Item Grant"] = true, ["Prismatic"] = true,
	["Ore Filter"] = true, ["Tween Ore"] = true, ["Ore Link"] = true,
	["Random Conveyor Speed"] = true, ["Set Item Directional Velocity"] = true,
	["Candy Look"] = true, ["Button"] = true, ["Anvils"] = true, ["Cornered"] = true,
	["Static Specials"] = true, ["Rollback"] = true, ["Duplicate Ore"] = true,
	["Frightened"] = true, ["Ramp"] = true, ["Corrupted"] = true, ["Undead"] = true,
}

------------------------------------------------------------------------------
-- DIAGNOSTICS
------------------------------------------------------------------------------

local Diagnostics = { notes = {}, warnings = {}, errors = {} }

local function note(fmt, ...)
	local msg = "[OreVM] " .. string.format(fmt, ...)
	table.insert(Diagnostics.notes, msg)
	print(msg)
end

local function warnf(fmt, ...)
	local msg = "[OreVM] WARNING: " .. string.format(fmt, ...)
	table.insert(Diagnostics.warnings, msg)
	warn(msg)
end

local function errf(fmt, ...)
	local msg = "[OreVM] ERROR: " .. string.format(fmt, ...)
	table.insert(Diagnostics.errors, msg)
	warn(msg)
end

local LocalPlayer
Diagnostics.stage = "loading"

local function setStage(stage)
	Diagnostics.stage = stage
end

local function copyToClipboard(text)
	local copied = false
	if type(setclipboard) == "function" then
		pcall(function() setclipboard(text) copied = true end)
	end
	if not copied and type(toclipboard) == "function" then
		pcall(function() toclipboard(text) copied = true end)
	end
	if not copied and type(syn) == "table" and type(syn.set_clipboard) == "function" then
		pcall(function() syn.set_clipboard(text) copied = true end)
	end
	return copied
end

local function buildReport()
	local parts = {
		"=== OreValueMaximiser diagnostic report ===",
		"stage: " .. tostring(Diagnostics.stage),
	}
	pcall(function() parts[#parts + 1] = "place: " .. tostring(game.PlaceId) end)
	pcall(function()
		if type(identifyexecutor) == "function" then
			parts[#parts + 1] = "executor: " .. tostring(identifyexecutor())
		end
	end)
	pcall(function()
		if LocalPlayer then
			parts[#parts + 1] = "player: " .. LocalPlayer.Name
		end
	end)
	parts[#parts + 1] = "-- notes (" .. #Diagnostics.notes .. ") --"
	for _, m in ipairs(Diagnostics.notes) do parts[#parts + 1] = m end
	parts[#parts + 1] = "-- warnings (" .. #Diagnostics.warnings .. ") --"
	for _, m in ipairs(Diagnostics.warnings) do parts[#parts + 1] = m end
	parts[#parts + 1] = "-- errors (" .. #Diagnostics.errors .. ") --"
	for _, m in ipairs(Diagnostics.errors) do parts[#parts + 1] = m end
	return table.concat(parts, "\n")
end

local function copyReport()
	local report = buildReport()
	if copyToClipboard(report) then
		print("[OreVM] diagnostic report copied to clipboard (" .. #report .. " chars) - paste it back to the developer")
	else
		pcall(function()
			writefile("OreVM_report.txt", report)
			print("[OreVM] clipboard unavailable - report saved to workspace file OreVM_report.txt")
		end)
		warn("[OreVM] clipboard unavailable - report printed below:\n" .. report)
	end
end

------------------------------------------------------------------------------
-- BIG NUMBER (log10-domain, sign aware; values can exceed double range)
-- representation: { sign = -1|0|1, l = log10(|value|) }  (l = -inf when zero)
------------------------------------------------------------------------------

local BigNum = {}
BigNum.__index = BigNum

local NEG_INF = -math.huge

function BigNum.zero() return setmetatable({ sign = 0, l = NEG_INF }, BigNum) end
function BigNum.one() return setmetatable({ sign = 1, l = 0 }, BigNum) end

function BigNum.fromLog10(l, sign)
	sign = sign or 1
	if l ~= l or l == math.huge then
		return setmetatable({ sign = sign, l = l }, BigNum)
	end
	if l == NEG_INF then return BigNum.zero() end
	return setmetatable({ sign = sign, l = l }, BigNum)
end

function BigNum.fromNumber(x)
	if x == 0 then return BigNum.zero() end
	local sign = x < 0 and -1 or 1
	local l = math.log10(math.abs(x))
	return setmetatable({ sign = sign, l = l }, BigNum)
end

function BigNum.isBig(v) return type(v) == "table" and getmetatable(v) == BigNum end

function BigNum.coerce(v)
	if BigNum.isBig(v) then return v end
	if typeof(v) == "number" then return BigNum.fromNumber(v) end
	return nil
end

function BigNum.__add(a, b)
	a, b = BigNum.coerce(a), BigNum.coerce(b)
	if not a or not b then return nil end
	if a.sign == 0 then return b end
	if b.sign == 0 then return a end
	if a.sign == b.sign then
		local hi, lo = math.max(a.l, b.l), math.min(a.l, b.l)
		local l = hi + math.log10(1 + 10 ^ (lo - hi))
		return BigNum.fromLog10(l, a.sign)
	end
	local hi, lo = a, b
	if b.l > a.l then hi, lo = b, a end
	local diff = lo.l - hi.l
	if diff == 0 then return BigNum.zero() end
	local l = hi.l + math.log10(1 - 10 ^ diff)
	return BigNum.fromLog10(l, hi.sign)
end

function BigNum.__sub(a, b)
	b = BigNum.coerce(b)
	if not b then return nil end
	return a + setmetatable({ sign = -b.sign, l = b.l }, BigNum)
end

function BigNum.__mul(a, b)
	a, b = BigNum.coerce(a), BigNum.coerce(b)
	if not a or not b then return nil end
	if a.sign == 0 or b.sign == 0 then return BigNum.zero() end
	local l = a.l + b.l
	if l ~= l then return BigNum.fromLog10(l, a.sign * b.sign) end
	return BigNum.fromLog10(l, a.sign * b.sign)
end

function BigNum.__lt(a, b)
	a, b = BigNum.coerce(a), BigNum.coerce(b)
	if not a or not b then return false end
	if a.sign ~= b.sign then return a.sign < b.sign end
	if a.sign == 0 then return false end
	if a.sign > 0 then return a.l < b.l end
	return a.l > b.l
end

function BigNum.__le(a, b) return not (b < a) end
function BigNum.__eq(a, b)
	a, b = BigNum.coerce(a), BigNum.coerce(b)
	if not a or not b then return false end
	return a.sign == b.sign and a.l == b.l
end

function BigNum:max(o) o = BigNum.coerce(o); if o and (o > self) or (not o) then return o or self end; return self end
function BigNum:min(o) o = BigNum.coerce(o); if o and (o < self) then return o end; return self end

function BigNum:log10()
	if self.sign < 0 then return nil end
	return self.l
end

function BigNum:toNumber()
	if self.sign == 0 then return 0 end
	local v = 10 ^ self.l
	if v ~= v then return self.sign > 0 and math.huge or -math.huge end
	return self.sign * v
end

function BigNum:toString()
	if self.sign == 0 then return "0" end
	local signStr = self.sign < 0 and "-" or ""
	if self.l < 15 then
		local v = self:toNumber()
		return signStr .. string.format("%.0f", v)
	end
	local exp = math.floor(self.l)
	local mant = 10 ^ (self.l - exp)
	return signStr .. string.format("%.2fe%d", mant, exp)
end

-- Parses def values that may be numbers, "$1,234", "1.5e21" or WingPoint strings.
local function parseValue(v, wingPoint)
	if typeof(v) == "number" then return BigNum.fromNumber(v) end
	if typeof(v) ~= "string" then return nil end
	local s = v:gsub("[$,%s]", "")
	local n = tonumber(s)
	if n then return BigNum.fromNumber(n) end
	if wingPoint then
		local ok, res = pcall(function() return wingPoint.convert(v) end)
		if ok and res then
			local ok2, l = pcall(function() return res:log10() end)
			if ok2 and typeof(l) == "number" then
				return BigNum.fromLog10(l)
			end
		end
	end
	return nil
end

------------------------------------------------------------------------------
-- ENVIRONMENT BOOTSTRAP (guarded; every dependency checked, never bare-errored)
------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")

LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	errf("Players.LocalPlayer missing - script must run client-side.")
	copyReport()
	return
end

local function getChild(parent, name, what)
	if not parent then
		warnf("cannot look up %s: parent missing", what or name)
		return nil
	end
	local c = parent:FindFirstChild(name)
	if not c then
		warnf("missing object: %s (child %q of %s)", what or name, name, parent:GetFullName())
	end
	return c
end

local function safeRequire(mod, what)
	if not mod then return nil end
	local ok, res = pcall(require, mod)
	if not ok then
		warnf("require(%s) failed: %s", what or mod.Name, tostring(res))
		return nil
	end
	return res
end

local rfClient = getChild(ReplicatedFirst, "Client", "ReplicatedFirst.Client")
local rfLibs = rfClient and getChild(rfClient, "Libraries", "ReplicatedFirst.Client.Libraries")
local rsLibs = getChild(ReplicatedStorage, "Libraries", "ReplicatedStorage.Libraries")

local Modules = {}

Modules.Data = safeRequire(rfLibs and getChild(rfLibs, "Data", "Data library"), "Data")
if not Modules.Data and type(shared) == "table" then
	Modules.Data = shared.DataLibrary
end
Modules.Items = safeRequire(rsLibs and getChild(rsLibs, "Items", "Items library"), "Items")
Modules.Communicator = safeRequire(rsLibs and getChild(rsLibs, "Communicator", "Communicator"), "Communicator")
Modules.Stats = safeRequire(rfLibs and getChild(rfLibs, "Stats", "Stats library"), "Stats")
Modules.WingPoint = safeRequire(rsLibs and getChild(rsLibs, "WingPoint", "WingPoint"), "WingPoint")
Modules.Halloween = safeRequire(rsLibs and getChild(rsLibs, "Halloween", "Halloween"), "Halloween")
setStage("modules loaded")

local function missingModules()
	local missing = {}
	for _, name in ipairs({ "Data", "Items", "Communicator" }) do
		if not Modules[name] then table.insert(missing, name) end
	end
	return missing
end

local function getItemMap()
	if not Modules.Items then return nil end
	local ok, map = pcall(function() return Modules.Items.GetItemMap() end)
	if not ok or typeof(map) ~= "table" then
		warnf("Items:GetItemMap() unavailable: %s", tostring(map))
		return nil
	end
	return map
end

local function gameStat(group, key)
	if not Modules.Data then return nil end
	local ok, v = pcall(function() return Modules.Data:GetUnsafe(group, key) end)
	if not ok then return nil end
	return v
end

local function statValue(key)
	if not Modules.Stats then return nil end
	local ok, v = pcall(function() return Modules.Stats.GetValue(key) end)
	if not ok then return nil end
	return v
end

------------------------------------------------------------------------------
-- BEAM GROUPS (exact replication of ItemValues.BeamGroups)
-- def.Tag / Tag2..TagN group entries; entry = {Value, Operator, Limit, CashLimit, Tags}
-- Group 1 uses the item-level SpecialTags; groups 2..N use SpecialTagsN.
------------------------------------------------------------------------------

local function getBeamGroups(def)
	local groups = {}
	local keys = {}
	local byKey = {}
	local count = def.UpgraderCount or 1
	for i = 1, count do
		local suffix = (i == 1) and "" or tostring(i)
		local tag = def["Tag" .. suffix]
		if tag == nil then tag = def.Tag or "" end
		if not byKey[tag] then
			byKey[tag] = {}
			table.insert(keys, tag)
		end
		local entry = {
			Value = def["Value" .. suffix] ~= nil and def["Value" .. suffix] or def.Value,
			Operator = def["Operator" .. suffix] ~= nil and def["Operator" .. suffix] or def.Operator,
			Limit = def["Limit" .. suffix] ~= nil and def["Limit" .. suffix] or (def.Limit or 1),
			CashLimit = def["IsCashLimit" .. suffix] ~= nil and def["IsCashLimit" .. suffix] or def.IsCashLimit,
			Tags = (i > 1) and def["SpecialTags" .. i] or nil,
		}
		table.insert(byKey[tag], entry)
	end
	for _, k in ipairs(keys) do
		table.insert(groups, byKey[k])
	end
	return groups
end

------------------------------------------------------------------------------
-- ORE STATE
-- tags:    {[itemName] = hitCount}    ("upgrade tags": which items upgraded the
--                                     ore and how many times - what Tag
--                                     Reactions read; variants count too)
-- effects: {[effectName] = true}      (active timed/permanent effects)
-- immune:  {[effectName] = true}      (Effect Immunity)
-- attrs:   {[attributeName] = number} (Base Upgrade / Random Base Upgrade)
------------------------------------------------------------------------------

local function newOreState()
	return {
		value = BigNum.zero(),
		tags = {},
		effects = {},
		immune = {},
		attrs = {},
	}
end

local function cloneState(s)
	local c = {
		value = s.value,
		tags = {},
		effects = {},
		immune = {},
		attrs = {},
	}
	for k, v in pairs(s.tags) do c.tags[k] = v end
	for k, v in pairs(s.effects) do c.effects[k] = v end
	for k, v in pairs(s.immune) do c.immune[k] = v end
	for k, v in pairs(s.attrs) do c.attrs[k] = v end
	return c
end

------------------------------------------------------------------------------
-- SPECIAL TAG EVALUATION
-- Mirrors ItemValues.TagsFactor (v_u_171) with real ore-state gating, plus the
-- state MUTATIONS the specials cause (effects set/cleansed, immunities, attrs).
-- Returns factor (BigNum) or nil when the special makes the item uncomputable
-- (Effect Affinity / Multiple Effect Affinities / Random Base Upgrade -1 etc).
-- opts.applyMutations: mutate `ore` (item-level call). Beam-entry calls use a
-- throwaway clone so entry evaluation never double-applies mutations.
------------------------------------------------------------------------------

local TIMED_EFFECTS = { Weaken = true, Empower = true, Poison = true, Growth = true }

-- Exact replication of ItemValues.TimedFactor: best factor over the timeline.
local function timedFactor(list)
	local points = { 0 }
	for _, e in ipairs(list) do
		local start = e[3] or 0
		table.insert(points, start)
		table.insert(points, start + (e[2] or 0))
	end
	local best = 1
	for _, t in ipairs(points) do
		local f = 1
		for _, e in ipairs(list) do
			local dur = e[2] or 0
			local start = e[3] or 0
			local ramp
			if dur > 0 then
				ramp = math.clamp((t - start) / dur, 0, 1)
			else
				ramp = start <= t and 1 or 0
			end
			f = f * (e[1] or 1) ^ ramp
		end
		best = math.max(best, f)
	end
	return best
end

-- Halloween-scaled formulas (guarded; default 1 if module unavailable).
local function halloweenMost(kind)
	if not Modules.Halloween then return 1 end
	local ok, v = pcall(function()
		if kind == "Knock" then
			return Modules.Halloween.TrickOrTreat.Prizes
		end
		return Modules.Halloween.FlawlessRuns
	end)
	if not ok or typeof(v) ~= "table" then return 1 end
	return v
end

local FORMULAS = {
	["Random Multiplier"] = function(a, b) return math.max(a or 1, b or 1) end,
	["Ramping Multiplier Until Upgrade"] = function(a) return a or 1 end,
	["Delayed Multiply"] = function(a) return a or 1 end,
	["Item Age Reaction"] = function(a) return a or 1 end,
	["Ramping Multiplier"] = function(a) return a or 1 end,
	["Effect Reaction"] = function(a) return a or 1 end,
	["Delayed Fortification"] = function(a) return a or 1 end,
	["Anvils"] = function(a) return a or 1 end,
	["Density Reaction"] = function(a) return a or 1 end,
	["Time Reaction"] = function(a) return a or 1 end,
	["Collection Reaction"] = function(a) return a or 1 end,
	["Sacrifice"] = function(a) return a or 1 end,
	["Button"] = function(a) return a or 1 end,
	["Marked for Death"] = function(a) return a or 1 end,
	["Overflow"] = function(a) return a or 1 end,
	["Dedicated"] = function(a) return a or 1 end,
	["Robux Scaling"] = function() return 1.5 end,
	["Gift Scaling"] = function() return 4 end,
	["Shadowflame"] = function(a, _, b)
		local reinc = tonumber(gameStat("GameStats", "Reincarnation")) or 0
		local pre = tonumber(gameStat("GameStats", "PreAlphaReincarnations")) or 0
		return 1 + (reinc ^ 0.8333333333333334 + (b or 2) * pre) / 100 * (a or 1)
	end,
	["Stepped Upgrades"] = function(a, b, c)
		local f = 1
		for i = 0, (c or 0) - 1 do
			f = f * math.max((a or 1) + (b or 0) * i, 1)
		end
		return f
	end,
	["Attribute Process Reaction"] = function(a) return a or 1 end,
	["Overload"] = function(a) return a or 1 end,
	["Hungry Pyre"] = function(a, b) return (a or 1) ^ (b or 1) end,
	["Base Upgrade"] = function(a, _, attr)
		if not attr then return a or 1 end
		local best = 1
		for _, def in pairs(getItemMap() or {}) do
			local st = def.SpecialTags
			if typeof(st) == "table" and typeof(st[attr]) == "table" and typeof(st[attr][1]) == "number" then
				best = math.max(best, st[attr][1])
			end
		end
		return (a or 1) * best
	end,
	["Random Base Upgrade"] = function(a, _, n)
		n = n or 1
		if n == -1 then return nil end
		return (a or 1) ^ n
	end,
	["Soul Toll"] = function(a) return a or 1 end,
	["Cornered"] = function(a) return a or 1 end,
	["Tag Reaction"] = function(a) return a or 1 end,
	["Cauldron Brew"] = function(a, b) return (a or 1) * (b or 1) + 1 end,
	["Knock Scaling"] = function(k)
		local prizes = halloweenMost("Knock")
		local p = typeof(prizes) == "table" and prizes[k]
		return (p and p.Most) or 1
	end,
	["Flawless Scaling"] = function()
		local runs = halloweenMost("Flawless")
		return (typeof(runs) == "table" and runs.Most) or 1
	end,
	["Fright"] = function(_, _, c) return c or 1 end,
	["Blood Consumption"] = function(a) return a or 1 end,
	["Static Shock"] = function(_, b, c) return (b or 1) ^ (c or 1) end,
	["Tag Count Reaction"] = function(a, b, c, d)
		c = c or 1
		return b / (b - (d or 0)) * (a - c) + c
	end,
}
FORMULAS["Effect Tag Count Reaction"] = FORMULAS["Tag Count Reaction"]

local MULTIPLE_REACTIONS = {
	["Multiple Effect Reactions"] = true,
}

-- Evaluates one special-tags table against ore state. Returns BigNum factor or nil.
local function evalSpecials(def, specialTags, ore, opts)
	opts = opts or {}
	if typeof(specialTags) ~= "table" then return BigNum.one() end
	local factor = BigNum.one()
	local timed = {}
	for key, args in pairs(specialTags) do
		if typeof(args) == "table" then
			local name = string.gsub(key, "<%d+>$", "")
			if RISKY_SPECIALS[name] then
				return nil
			end
			if MULTIPLE_REACTIONS[name] then
				for _, entry in ipairs(args) do
					if typeof(entry) == "table" and typeof(entry[1]) == "number" then
						factor = factor * BigNum.fromNumber(math.max(entry[1], 1))
					end
				end
			elseif name == "Chance" then
				local best = 1
				for _, entry in ipairs(args) do
					if typeof(entry) == "table" and entry[2] == "Multiply"
						and typeof(entry[3]) == "table" and typeof(entry[3][1]) == "number" then
						best = math.max(best, entry[3][1])
					end
				end
				factor = factor * BigNum.fromNumber(math.max(best, 1))
			elseif name == "Tag Reaction" then
				local target = typeof(args[2]) == "string" and args[2] or nil
				local minCount = args[3] or 1
				local have = 0
				if target then
					have = ore.tags[target] or ore.tags[(target:gsub("_", " "))] or 0
				end
				if have >= minCount then
					factor = factor * BigNum.fromNumber(math.max(args[1] or 1, 1))
				end
			elseif name == "Multiple Tag Reactions" then
				for _, entry in ipairs(args) do
					if typeof(entry) == "table" and typeof(entry[1]) == "number" then
						local target = typeof(entry[2]) == "string" and entry[2] or nil
						local minCount = entry[3] or 1
						local have = 0
						if target then
							have = ore.tags[target] or ore.tags[(target:gsub("_", " "))] or 0
						end
						if have >= minCount then
							factor = factor * BigNum.fromNumber(math.max(entry[1], 1))
						end
					end
				end
			elseif name == "Effect Reaction" then
				local effectName = args[2]
				local have = (typeof(effectName) == "string") and ore.effects[effectName] or nil
				if have then
					factor = factor * BigNum.fromNumber(math.max(args[1] or 1, 1))
				end
			elseif name == "Multiple Effect Reactions" then
				-- handled above
			elseif name == "Base Upgrade" then
				local attr = args[3]
				local mult = 1
				if typeof(attr) == "string" then
					mult = ore.attrs[attr] or 1
				end
				factor = factor * BigNum.fromNumber(math.max((args[1] or 1) * mult, 1))
			elseif name == "Random Base Upgrade" then
				local n = args[3] or 1
				if n == -1 then return nil end
				factor = factor * BigNum.fromNumber(math.max((args[1] or 1) ^ n, 1))
			elseif name == "Blood Consumption" then
				local consumed = false
				for _, e in ipairs({ "Fire", "Poison", "Overload", "Weaken" }) do
					if ore.effects[e] then
						consumed = true
						if opts.applyMutations then ore.effects[e] = nil end
					end
				end
				if consumed then
					factor = factor * BigNum.fromNumber(math.max(args[1] or 1, 1))
				end
			elseif name == "Cleanse" then
				if opts.applyMutations then
					for e in pairs(ore.effects) do ore.effects[e] = nil end
				end
			elseif name == "Effect Immunity" then
				if opts.applyMutations and typeof(args[2]) == "string" then
					ore.immune[args[2]] = true
					ore.effects[args[2]] = nil
				end
			elseif name == "Multiple Effect Immunities" then
				if opts.applyMutations then
					for _, e in ipairs(args) do
						if typeof(e) == "string" then
							ore.immune[e] = true
							ore.effects[e] = nil
						end
					end
				end
			elseif name == "Fire" or name == "Poison" or name == "Overload" or name == "Weaken" then
				if opts.applyMutations and not ore.immune[name] then
					ore.effects[name] = true
				end
			elseif name == "Empower" or name == "Growth" then
				table.insert(timed, args)
			elseif TIMED_EFFECTS[name] then
				table.insert(timed, args)
			elseif name == "Luminium" then
				factor = factor * BigNum.fromNumber(math.max(args[1] or 1, 1))
				if opts.applyMutations and typeof(args[2]) == "string" then
					ore.attrs[args[2]] = math.max(ore.attrs[args[2]] or 0, args[3] or 1)
				end
			elseif name == "Item Age Reaction" then
				-- Best case: ore is already fully aged (documented approximation).
				factor = factor * BigNum.fromNumber(math.max(args[1] or 1, 1))
			elseif name == "Collection Reaction" then
				-- Best case: assumes 100% collection (documented approximation).
				factor = factor * BigNum.fromNumber(math.max(args[1] or 1, 1))
			elseif FORMULAS[name] then
				local ok, res = pcall(FORMULAS[name], table.unpack(args))
				if not ok or res == nil then return nil end
				factor = factor * BigNum.fromNumber(math.max(res, 1))
			elseif PASSIVE_SPECIALS[name] then
				-- layout / movement / visual only
			else
				if not opts.silentUnknown then
					warnf("unknown SpecialTag %q on %s - ignored (reported, not invented)", name, def.Name or "?")
				end
			end
		end
	end
	if #timed > 0 then
		local tf = timedFactor(timed)
		factor = factor * BigNum.fromNumber(math.max(tf, 1))
	end
	return factor
end

------------------------------------------------------------------------------
-- ITEM SIMULATION
-- Simulates ONE pass of one ore through one upgrader, using the real beam
-- group structure. Per ItemValues.MaxMultiplier the global SpecialTags factor
-- and the per-entry SpecialTagsN factor multiply EVERY applied beam entry;
-- mutations (effects/cleanse/immunity/attrs) are applied once per item.
-- Cash-limited entries only apply while the ore value is below the cash cap
-- (ItemValues.MinimumValue = IsCashLimit - Stats CashgradeCap).
-- Returns new ore state, or nil if the item cannot be simulated.
------------------------------------------------------------------------------

local function cashCap()
	local cap = statValue("CashgradeCap")
	if typeof(cap) == "number" and cap > 0 then return cap end
	return 0
end

local function minimumValueFor(def)
	local cl = def.IsCashLimit
	if not cl then return nil end
	-- UseLimit: when IsCashLimit is truthy the cap value is `Limit` unless
	-- IsCashLimit is itself a (big-number) table holding the cap.
	local big
	if typeof(cl) == "table" then
		big = parseValue(cl, Modules.WingPoint)
	else
		big = parseValue(def.Limit, Modules.WingPoint)
	end
	if not big then return nil end
	local cap = cashCap()
	if cap > 0 then
		local capBig = BigNum.fromNumber(cap)
		if capBig < big then big = big - capBig end
	end
	return big
end

local function shinyMultiplierFor(def)
	if not (Modules.Items and Modules.Items.CalculateShinyMultiplier) then return 1 end
	local ok, m = pcall(function() return Modules.Items.CalculateShinyMultiplier(LocalPlayer, def.Name) end)
	if ok and typeof(m) == "number" then return m end
	return 1
end

local function simulateItem(def, oreIn)
	local groups = getBeamGroups(def)
	local shiny = shinyMultiplierFor(def)

	local ore = cloneState(oreIn)

	local globalFactor = evalSpecials(def, def.SpecialTags, ore, { applyMutations = true })
	if not globalFactor then return nil end

	local minVal = minimumValueFor(def)
	local anyApplied = false

	for _, group in ipairs(groups) do
		local maxLimit = 0
		local hasCash = false
		for _, e in ipairs(group) do
			if e.CashLimit then hasCash = true else maxLimit = math.max(maxLimit, e.Limit or 1) end
		end
		-- upgrade tag for this item is recorded once per pass (variants count too)
		local cap
		if hasCash then
			cap = #group
		else
			cap = math.min(#group, maxLimit)
		end
		local applied = 0
		for _, entry in ipairs(group) do
			if applied >= cap then break end
			if minVal and not (ore.value < minVal) then
				break
			end
			local entryFactor = BigNum.one()
			if entry.Tags then
				local probe = cloneState(ore)
				local f = evalSpecials(def, entry.Tags, probe, { applyMutations = false, silentUnknown = true })
				if not f then return nil end
				entryFactor = f
			end
			local beamFactor = globalFactor * entryFactor
			local val = parseValue(entry.Value, Modules.WingPoint)
			if not val then return nil end
			if entry.Operator == 1 then
				if val:log10() ~= 0 then
					val = val * BigNum.fromNumber(shiny)
				end
				ore.value = ore.value * (val * beamFactor)
			else
				ore.value = ore.value + (val * beamFactor)
			end
			applied = applied + 1
			anyApplied = true
		end
	end

	if anyApplied then
		ore.tags[def.Name] = (ore.tags[def.Name] or 0) + 1
		ore.tags[(def.Name:gsub("_", " "))] = (ore.tags[(def.Name:gsub("_", " "))] or 0) + 1
	end

	return ore, anyApplied
end

-- Optimistic per-item gain in log10 (ignores ore state: force-evaluates all
-- specials as if active). Used only for pruning/ranking, never for final math.
local function optimisticGain(def)
	local groups = getBeamGroups(def)
	local shiny = shinyMultiplierFor(def)
	local probeOre = newOreState()
	probeOre.value = BigNum.one()

	local globalFactor = evalSpecials(def, def.SpecialTags, probeOre, { applyMutations = false, silentUnknown = true })
	if not globalFactor then return nil end

	local total = BigNum.one()
	for _, group in ipairs(groups) do
		local entries = {}
		local hasCash = false
		local maxLimit = 0
		for _, e in ipairs(group) do
			if e.CashLimit then
				hasCash = true
			else
				maxLimit = math.max(maxLimit, e.Limit or 1)
			end
			local f
			if e.Tags then
				f = evalSpecials(def, e.Tags, probeOre, { applyMutations = false, silentUnknown = true })
				if not f then return nil end
			else
				f = BigNum.one()
			end
			local val = parseValue(e.Value, Modules.WingPoint)
			if not val then return nil end
			if e.Operator == 1 then
				if val:log10() ~= 0 then val = val * BigNum.fromNumber(shiny) end
				table.insert(entries, val * globalFactor * f)
			else
				table.insert(entries, globalFactor * f)
			end
		end
		table.sort(entries, function(a, b) return b < a end)
		local cap = hasCash and #entries or math.min(#entries, maxLimit)
		for i = 1, cap do
			total = total * entries[i]
		end
	end
	return total:log10()
end

------------------------------------------------------------------------------
-- INVENTORY SCAN
-- Owned counts from Data:GetGroup("Items"); placed counts from tycoon.Items
-- children (server truth, mirrors Inventory.GetLeft). Only genuine Upgraders
-- plus Sender/Receiver teleporters. Never purchases/sells/withdraws.
------------------------------------------------------------------------------

local function nameIsForbidden(name)
	local lower = string.lower(name)
	for _, pat in ipairs(FORBIDDEN_NAME_PATTERNS) do
		if string.find(lower, pat, 1, true) then return true end
	end
	return false
end

local function getOwnedCounts()
	if not Modules.Data then return nil end
	local ok, group = pcall(function() return Modules.Data:GetGroup("Items") end)
	if not ok or typeof(group) ~= "table" then
		warnf("Data:GetGroup(\"Items\") unavailable: %s", tostring(group))
		return nil
	end
	return group
end

local function getPlacedCounts(tycoon)
	local counts = {}
	local items = tycoon and tycoon:FindFirstChild("Items")
	if not items then return counts end
	for _, child in items:GetChildren() do
		if child:IsA("Model") or child:IsA("BasePart") then
			counts[child.Name] = (counts[child.Name] or 0) + 1
		end
	end
	return counts
end

local function itemIsTeleporter(def)
	local st = def.SpecialTags
	if typeof(st) ~= "table" then return false end
	return (typeof(st.Sender) == "table") or (typeof(st.Receiver) == "table")
end

-- A pure teleporter has Sender/Receiver tags and no upgrade beams; an item
-- with real beams is treated as an upgrader even if it also teleports.
local function teleporterOnly(def)
	if not itemIsTeleporter(def) then return false end
	return not (def.Tag or (def.UpgraderCount and def.UpgraderCount > 1))
end

local function hasRiskySpecials(def)
	if typeof(def.SpecialTags) == "table" then
		for key in pairs(def.SpecialTags) do
			local n = string.gsub(key, "<%d+>$", "")
			if RISKY_SPECIALS[n] then return true end
		end
	end
	for i = 2, def.UpgraderCount or 1 do
		local st = def["SpecialTags" .. i]
		if typeof(st) == "table" then
			for key in pairs(st) do
				local n = string.gsub(key, "<%d+>$", "")
				if RISKY_SPECIALS[n] then return true end
			end
		end
	end
	return false
end

local function cleansesEffect(def)
	if typeof(def.SpecialTags) ~= "table" then return false end
	for key in pairs(def.SpecialTags) do
		local n = string.gsub(key, "<%d+>$", "")
		if n == "Cleanse" or n == "Blood Consumption" or n == "Multiple Effect Immunities" then
			return true
		end
	end
	return false
end

local function scanInventory()
	local itemMap = getItemMap()
	if not itemMap then
		return nil, "Items library unavailable - cannot read item definitions."
	end
	local owned = getOwnedCounts()
	if not owned then
		return nil, "Inventory data unavailable (Data:GetGroup(\"Items\") failed)."
	end
	local tycoon = LocalPlayer:FindFirstChild("ActiveTycoon")
	tycoon = tycoon and tycoon.Value
	local placed = tycoon and getPlacedCounts(tycoon) or {}

	local available = {}   -- usable upgraders / teleporters
	local excluded = {}    -- {name = reason}
	local teleporters = {}

	for name, count in pairs(owned) do
		local def = itemMap[name]
		if typeof(count) == "number" and count > 0 and def then
			local left = count - (placed[name] or 0)
			if left <= 0 then
				excluded[name] = "all owned copies already placed"
			elseif teleporterOnly(def) then
				table.insert(teleporters, { name = name, def = def, left = left })
			elseif def.Type ~= "Upgrader" then
				excluded[name] = "type " .. tostring(def.Type) .. " (not an upgrader)"
			elseif nameIsForbidden(name) then
				excluded[name] = "blacklisted item"
			elseif hasRiskySpecials(def) then
				excluded[name] = "unreliable/destructive special (cannot be simulated safely)"
			elseif not optimisticGain(def) then
				excluded[name] = "specials cannot be simulated from client source"
			else
				table.insert(available, {
					name = name,
					def = def,
					left = math.min(left, CONFIG.MAX_COPIES_PER_ITEM),
				})
			end
		end
	end

	table.sort(available, function(a, b) return a.name < b.name end)
	table.sort(teleporters, function(a, b) return a.name < b.name end)
	return { available = available, teleporters = teleporters, excluded = excluded }, nil
end

-- Start value for cash-limit gating: best owned dropper's base value.
local function estimateStartValue(itemMap, owned)
	if not itemMap then
		warnf("no item map - assuming $1 start value (cash-limited upgraders may be mis-gated)")
		return BigNum.one()
	end
	local best
	for name, count in pairs(owned or {}) do
		local def = itemMap[name]
		if typeof(count) == "number" and count > 0 and def and def.Type == "Dropper" and def.Value ~= nil then
			local v = parseValue(def.Value, Modules.WingPoint)
			if v and (not best or v > best) then best = v end
		end
	end
	if not best then
		warnf("no owned dropper found for start value - assuming $1 (cash-limited upgraders may be mis-gated)")
		return BigNum.one()
	end
	return best
end

------------------------------------------------------------------------------
-- OPTIMISER
-- Beam search over orderings of the owned upgraders. State = ore value/tags/
-- effects after each step. A step is legal only if:
--   * the item is still "available" (per-copy usage tracked),
--   * destructive effects it applies can be cleansed LATER by an owned item
--     that is not already used up,
--   * the item itself is simulatable on the current ore state.
-- The best COMPLETE sequence (no pending destructive effects at the end) is
-- kept; ties broken by fewer items. Final sequence is re-simulated exactly.
------------------------------------------------------------------------------

local function canClearLater(appliedEffects, remainingCleansers)
	for _, e in ipairs(appliedEffects) do
		local cleared = false
		for _, c in ipairs(remainingCleansers) do
			if c > 0 then
				cleared = true
				break
			end
		end
		if not cleared then return false end
	end
	return true
end

local function runOptimiser(pool, startValue)
	startValue = startValue or BigNum.one()
	local n = #pool
	if n == 0 then
		return { order = {}, value = startValue, gainLog10 = 0 }
	end

	-- Preselect candidates by optimistic gain (log10), keep cleansers.
	local scored = {}
	for idx, entry in ipairs(pool) do
		local gain = optimisticGain(entry.def)
		table.insert(scored, { idx = idx, entry = entry, gain = gain or -math.huge })
	end
	table.sort(scored, function(a, b) return a.gain > b.gain end)
	local chosen, cleanserCount = {}, 0
	for _, s in ipairs(scored) do
		if #chosen < CONFIG.MAX_CANDIDATES then
			table.insert(chosen, s)
			if cleansesEffect(s.entry.def) then cleanserCount = cleanserCount + 1 end
		end
	end
	if cleanserCount < CONFIG.MIN_CLEANSE_KEEP then
		for _, s in ipairs(scored) do
			if #chosen >= CONFIG.MAX_CANDIDATES then break end
			local isCleanser = cleansesEffect(s.entry.def)
			local already = false
			for _, c in ipairs(chosen) do
				if c.idx == s.idx then
					already = true
					break
				end
			end
			if isCleanser and not already then
				table.insert(chosen, s)
				cleanserCount = cleanserCount + 1
			end
		end
	end

	local start = {
		ore = newOreState(),
		used = {},
		pending = {},     -- destructive effects awaiting cleanse
		log10 = startValue:log10() or 0,
		order = {},
	}
	start.ore.value = startValue

	local best = nil
	local beam = { start }

	local function consider(node)
		if #node.pending == 0 then
			if not best or node.log10 > best.log10 + 1e-9
				or (math.abs(node.log10 - best.log10) <= 1e-9 and #node.order < #best.order) then
				best = {
					order = table.clone(node.order),
					log10 = node.log10,
					ore = node.ore,
				}
			end
		end
	end

	consider(start)

	for depth = 1, math.min(n, CONFIG.MAX_CANDIDATES) do
		local nextBeam = {}
		for _, node in ipairs(beam) do
			for ci, s in ipairs(chosen) do
				local usedCount = node.used[s.idx] or 0
				if usedCount < s.entry.left then
					local newOre, applied = simulateItem(s.entry.def, node.ore)
					if newOre and applied then
						local newPending = {}
						for e in pairs(newOre.effects) do
							if DESTRUCTIVE_EFFECTS[e] then
								table.insert(newPending, e)
							end
						end
						local legal = true
						if #newPending > 0 then
							local remaining = {}
							for cj, s2 in ipairs(chosen) do
								if cj ~= ci then
									local rem = s2.entry.left - ((node.used[s2.idx] or 0) + (cj == ci and 1 or 0))
									if rem > 0 and cleansesEffect(s2.entry.def) then
										table.insert(remaining, rem)
									end
								end
							end
							if not canClearLater(newPending, remaining) then legal = false end
						end
						if legal then
							local newUsed = table.clone(node.used)
							newUsed[s.idx] = usedCount + 1
							local newOrder = table.clone(node.order)
							table.insert(newOrder, s.entry.name)
							local nl = newOre.value:log10()
							if nl then
								local child = {
									ore = newOre,
									used = newUsed,
									pending = newPending,
									log10 = nl,
									order = newOrder,
								}
								consider(child)
								table.insert(nextBeam, child)
							end
						end
					end
				end
			end
		end
		if #nextBeam == 0 then break end
		table.sort(nextBeam, function(a, b)
			if a.log10 ~= b.log10 then return a.log10 > b.log10 end
			return #a.order < #b.order
		end)
		while #nextBeam > CONFIG.BEAM_WIDTH do
			table.remove(nextBeam)
		end
		beam = nextBeam
	end

	if not best then
		return nil, "no valid complete upgrader sequence found (destructive effects could not be cleansed, or nothing was simulatable)."
	end

	local finalOre = newOreState()
	finalOre.value = startValue
	for _, name in ipairs(best.order) do
		for _, s in ipairs(chosen) do
			if s.entry.name == name then
				local o = simulateItem(s.entry.def, finalOre)
				if o then finalOre = o end
				break
			end
		end
	end

	return {
		order = best.order,
		value = finalOre.value,
		gainLog10 = (finalOre.value:log10() or 0) - (startValue:log10() or 0),
	}
end

------------------------------------------------------------------------------
-- BASE DETECTION (real ActiveTycoon system)
-- player.ActiveTycoon (ObjectValue) -> base MODEL in workspace.Game.Bases;
-- that model contains a BasePart named "Base" (the floor plate itself) and an
-- "Items" folder. Verified in OnTycoonLoad.Inventory (Placement.plane(v.Base,
-- v.Items)) and Base.fetchClosestBase (children of workspace.Game.Bases with
-- a "Base" child + Owner ObjectValue).
------------------------------------------------------------------------------

local function detectBase()
	local missing = {}
	local marker = LocalPlayer:FindFirstChild("ActiveTycoon")
	if not marker then
		table.insert(missing, "Player.ActiveTycoon (ObjectValue)")
		return nil, missing
	end
	local tycoon = marker.Value
	if not tycoon then
		table.insert(missing, "Player.ActiveTycoon.Value (no active tycoon set yet - wait for base load)")
		return nil, missing
	end
	if not tycoon.Parent then
		table.insert(missing, "ActiveTycoon.Value (" .. tycoon.Name .. ") is not parented (destroyed?)")
		return nil, missing
	end
	local basePart = tycoon:FindFirstChild("Base")
	if not basePart or not basePart:IsA("BasePart") then
		table.insert(missing, tycoon:GetFullName() .. ".Base (BasePart floor plate)")
		local fallback
		for _, d in tycoon:GetDescendants() do
			if d:IsA("BasePart") and d.Name == "Base" then
				fallback = d
				break
			end
		end
		if fallback then
			warnf("tycoon has no direct 'Base' child; using descendant Base at %s", fallback:GetFullName())
			basePart = fallback
		else
			return nil, missing
		end
	end
	local itemsFolder = tycoon:FindFirstChild("Items")
	if not itemsFolder then
		table.insert(missing, tycoon:GetFullName() .. ".Items (folder of placed items)")
		return nil, missing
	end
	return {
		tycoon = tycoon,
		basePart = basePart,
		items = itemsFolder,
	}, nil
end

------------------------------------------------------------------------------
-- LAYOUT PLANNER (pure 2D grid maths on the base plane)
-- Grid = 3 studs (Placement grid); valid item centres satisfy local % 3 == 0.
-- Conveyor flow = model -ZVector (Items.UpdateConveyors), so for flow +X the
-- placement yaw is -pi/2 and for flow +Z it is pi.
------------------------------------------------------------------------------

local GRID = 3
local FLOW_PLUS_X_YAW = -math.pi / 2
local FLOW_PLUS_Z_YAW = math.pi

local function snap(x)
	return math.floor(x / GRID + 0.5) * GRID
end

-- Snaps UP to the grid (used for edges/cursors so items never drift into
-- occupied space or off the base).
local function snapUp(x)
	return math.ceil(x / GRID - 1e-9) * GRID
end

local function detectGridOffset(basePart, itemsFolder)
	local counts = { [0] = 0, [1] = 0 }
	for _, child in itemsFolder:GetChildren() do
		local hitbox = child:FindFirstChild("Hitbox")
		if hitbox and hitbox:IsA("BasePart") then
			local localPos = basePart.CFrame:PointToObjectSpace(hitbox.Position)
			local off = math.abs(localPos.X % GRID)
			if off < 0.75 then
				counts[0] = counts[0] + 1
			elseif math.abs(off - 1.5) < 0.75 then
				counts[1] = counts[1] + 1
			end
		end
	end
	if counts[1] > counts[0] and counts[1] > 0 then return 1.5 end
	return 0
end

local function aabbOfPart(basePart, part)
	local cf, size = part.CFrame, part.Size
	local corners = {
		cf * Vector3.new(size.X / 2, 0, size.Z / 2),
		cf * Vector3.new(size.X / 2, 0, -size.Z / 2),
		cf * Vector3.new(-size.X / 2, 0, size.Z / 2),
		cf * Vector3.new(-size.X / 2, 0, -size.Z / 2),
	}
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, c in ipairs(corners) do
		local lp = basePart.CFrame:PointToObjectSpace(c)
		minX = math.min(minX, lp.X); maxX = math.max(maxX, lp.X)
		minZ = math.min(minZ, lp.Z); maxZ = math.max(maxZ, lp.Z)
	end
	return minX, maxX, minZ, maxZ
end

local function overlaps(ax0, ax1, az0, az1, bx0, bx1, bz0, bz1)
	return ax0 < bx1 and bx0 < ax1 and az0 < bz1 and bz0 < az1
end

-- Collect occupied rectangles (plane-local) from existing items' Hitbox parts.
local function collectOccupied(basePart, itemsFolder)
	local rects = {}
	for _, child in itemsFolder:GetChildren() do
		local hitbox = child:FindFirstChild("Hitbox")
		if hitbox and hitbox:IsA("BasePart") then
			local x0, x1, z0, z1 = aabbOfPart(basePart, hitbox)
			table.insert(rects, { x0 = x0, x1 = x1, z0 = z0, z1 = z1 })
		end
	end
	return rects
end

-- Plans rows of the ordered upgraders across the base.
-- items: ordered array of {name, def}. Returns plan or nil + reason.
-- plan = { rows = { {items = {...}, z = cellsAcross, ...} }, notes = {...},
--          fitCount, leftover, usesTeleporters, flowAxis }
local function planLayout(basePart, itemsFolder, orderedItems, teleporters)
	local notes = {}
	local baseSize = basePart.Size
	local alongMax, acrossMax = baseSize.X, baseSize.Z
	local flip = false
	if baseSize.Z > baseSize.X then
		alongMax, acrossMax = baseSize.Z, baseSize.X
		flip = true
	end
	local flowAxis = flip and "Z" or "X"
	local yaw = flip and FLOW_PLUS_Z_YAW or FLOW_PLUS_X_YAW
	local offset = detectGridOffset(basePart, itemsFolder)
	local margin = CONFIG.EDGE_MARGIN * GRID

	local minX = -alongMax / 2 + margin
	local maxX = alongMax / 2 - margin
	local minZ = -acrossMax / 2 + margin
	local maxZ = acrossMax / 2 - margin

	local occupied = collectOccupied(basePart, itemsFolder)

	local function rectFree(x0, x1, z0, z1)
		if x0 < minX or x1 > maxX or z0 < minZ or z1 > maxZ then return false end
		for _, r in ipairs(occupied) do
			if overlaps(x0, x1, z0, z1, r.x0, r.x1, r.z0, r.z1) then return false end
		end
		return true
	end

	local function extentOf(it)
		local size = it.def.Size
		local along = math.max(size.X, 1)
		local across = math.max(size.Z, 1)
		if flip then
			along, across = across, along
		end
		return along, across
	end

	local rows = {}
	local remaining = {}
	for _, it in ipairs(orderedItems) do table.insert(remaining, it) end

	local bandBottom = minZ
	local fitCount = 0

	while #remaining > 0 do
		local rowBuilt = false
		local zTry = snapUp(bandBottom + CONFIG.BAND_GAP * GRID + offset)
		while zTry <= maxZ and not rowBuilt do
			local trial = {}
			local maxHalfAcross = 0
			local cursorX = snapUp(minX + offset) -- left edge of the next item
			local trialRemaining = {}
			for _, it in ipairs(remaining) do table.insert(trialRemaining, it) end
			local i = 1
			while i <= #trialRemaining do
				local it = trialRemaining[i]
				local along, across = extentOf(it)
				local x0 = cursorX
				local x1 = cursorX + along
				local z0 = zTry - across / 2
				local z1 = zTry + across / 2
				if x1 > maxX or z1 > maxZ then
					break
				end
				if rectFree(x0, x1, z0, z1) then
					table.insert(trial, {
						name = it.name,
						def = it.def,
						cx = x0 + along / 2,
						cz = zTry,
						halfAlong = along / 2,
						halfAcross = across / 2,
					})
					maxHalfAcross = math.max(maxHalfAcross, across / 2)
					cursorX = snapUp(x1 + CONFIG.ROW_GAP * GRID)
					table.remove(trialRemaining, i)
				else
					break
				end
			end
			if #trial > 0 then
				table.insert(rows, { items = trial, z = zTry, width = maxHalfAcross * 2 })
				fitCount = fitCount + #trial
				remaining = trialRemaining
				bandBottom = zTry + maxHalfAcross
				rowBuilt = true
			else
				zTry = zTry + GRID
			end
		end
		if not rowBuilt then
			table.insert(notes, "no space for the next " .. tostring(#remaining) .. " item(s): base full or items blocked")
			break
		end
	end

	local usesTeleporters = #rows > 1
	local tpPairs = {}
	if usesTeleporters and teleporters then
		local senders, receivers = {}, {}
		for _, tp in ipairs(teleporters) do
			local st = tp.def.SpecialTags
			if typeof(st) == "table" then
				if typeof(st.Sender) == "table" then
					table.insert(senders, tp)
				elseif typeof(st.Receiver) == "table" then
					table.insert(receivers, tp)
				end
			end
		end
		for _, snd in ipairs(senders) do
			local grp = snd.def.SpecialTags.Sender[1]
			for _, rcv in ipairs(receivers) do
				local rgrp = rcv.def.SpecialTags.Receiver[1]
				if grp == rgrp and snd.left > 0 and rcv.left > 0 then
					table.insert(tpPairs, { sender = snd, receiver = rcv })
					snd.left = snd.left - 1
					rcv.left = rcv.left - 1
					break
				end
			end
		end
		-- Sender at the END of row k teleports ore to a Receiver at the START
		-- of row k+1 (Sender.Groups / Receiver.Groups are keyed by SpecialTags[1]).
		local linked = 0
		for k, pair in ipairs(tpPairs) do
			local fromRow = rows[k]
			local toRow = rows[k + 1]
			if not fromRow or not toRow then break end
			local lastCell = fromRow.items[#fromRow.items]
			local firstCell = toRow.items[1]
			local sAlong, sAcross = extentOf(pair.sender)
			local rAlong, rAcross = extentOf(pair.receiver)
			local sCenter = snap(lastCell.cx + lastCell.halfAlong + 1.5 + sAlong / 2)
			local rCenter = snap(firstCell.cx - firstCell.halfAlong - 1.5 - rAlong / 2)
			local sOk = rectFree(sCenter - sAlong / 2, sCenter + sAlong / 2, fromRow.z - sAcross / 2, fromRow.z + sAcross / 2)
			local rOk = rCenter - rAlong / 2 >= minX
				and rectFree(rCenter - rAlong / 2, rCenter + rAlong / 2, toRow.z - rAcross / 2, toRow.z + rAcross / 2)
			if sOk and rOk then
				pair.senderCell = { name = pair.sender.name, def = pair.sender.def, cx = sCenter, cz = fromRow.z }
				pair.receiverCell = { name = pair.receiver.name, def = pair.receiver.def, cx = rCenter, cz = toRow.z }
				linked = linked + 1
			else
				table.insert(notes, "teleporter pair " .. tostring(k) .. " had no free space and was skipped")
			end
		end
		if linked == 0 then
			table.insert(notes, "no matching Sender/Receiver teleporter pair owned or placeable - rows are NOT conveyor-connected")
			usesTeleporters = false
			tpPairs = {}
		end
	end

	return {
		rows = rows,
		notes = notes,
		fitCount = fitCount,
		leftover = #remaining,
		usesTeleporters = usesTeleporters,
		tpPairs = tpPairs,
		flowAxis = flowAxis,
		yaw = yaw,
		gridOffset = offset,
	}, nil
end

-- World CFrame for a planned cell (mirror of Placement.RelativeToReal math).
local function worldCFrame(basePart, def, cx, cz, yaw)
	local itemY = (def.Size and def.Size.Y) or 4
	return basePart.CFrame
		* CFrame.new(cx, basePart.Size.Y / 2 + itemY / 2, cz)
		* CFrame.Angles(0, yaw, 0)
end

------------------------------------------------------------------------------
-- PLACEMENT EXECUTOR
-- Uses the real flow: Communicator.listenerFunction("PlaceItem"):Invoke(entries)
-- with entries {CFrame = world CFrame, Name = itemName, State = nil}.
-- Response shapes (Placement.Pump):
--   multi/mixed batch: pcall returns (true, a, b, perEntry) with perEntry[i] =
--     {Id = string, Bought = bool}; Bought == true means the server PURCHASED
--     the copy (inventory violation -> abort).
--   single batch: (true, idList, boughtNamesList).
-- Bought == true is ALWAYS treated as an error: this script must only ever
-- place items the player already owns.
------------------------------------------------------------------------------

local BuildState = {
	stopRequested = false,
	building = false,
	placed = 0,
	rejected = 0,
	lastRejectReason = nil,
}

local function normaliseResults(ok, r1, r2, r3, entryCount)
	if not ok then
		return nil, tostring(r1)
	end
	if typeof(r3) == "table" then
		local results = {}
		for i = 1, entryCount do
			local e = r3[i]
			if typeof(e) == "table" then
				table.insert(results, { id = e.Id, bought = e.Bought == true, ok = true })
			else
				table.insert(results, { id = nil, bought = false, ok = false, reason = "no per-entry result" })
			end
		end
		return results, nil
	elseif type(r1) == "table" then
		local boughtNames = {}
		if typeof(r2) == "table" then
			for _, nm in ipairs(r2) do boughtNames[nm] = true end
		end
		local results = {}
		for i = 1, entryCount do
			local id = (typeof(r1) == "table") and r1[i] or nil
			if id then
				table.insert(results, { id = id, bought = false, ok = true })
			else
				table.insert(results, { id = nil, bought = false, ok = false, reason = "no result entry" })
			end
		end
		if next(boughtNames) then
			for _, res in ipairs(results) do
				res.bought = true
			end
			return results, "server reported purchases for this batch"
		end
		return results, nil
	end
	return nil, "unrecognised PlaceItem response shape"
end

local function placeBatch(entries)
	local communicator = Modules.Communicator
	if not communicator or not communicator.listenerFunction then
		return nil, "Communicator library unavailable - cannot place items."
	end
	local ok, invokeObj = pcall(function() return communicator.listenerFunction("PlaceItem") end)
	if not ok or not invokeObj then
		return nil, "Communicator.listenerFunction(\"PlaceItem\") unavailable."
	end
	local callOk, a, b, c = pcall(function() return invokeObj:Invoke(entries) end)
	return normaliseResults(callOk, a, b, c, #entries)
end

-- Confirms placed models actually appear under tycoon.Items with matching Id
-- attributes (server confirmation, not assumption).
local function verifyPlacedModels(tycoon, expectedIds, timeout)
	if not CONFIG.VERIFY_PLACEMENT then return true end
	local items = tycoon:FindFirstChild("Items")
	if not items then return false end
	local remaining = {}
	for _, id in ipairs(expectedIds) do
		if id then remaining[id] = true end
	end
	if next(remaining) == nil then return true end
	local deadline = os.clock() + (timeout or CONFIG.PLACEMENT_TIMEOUT)
	while os.clock() < deadline do
		for _, child in items:GetChildren() do
			local id = child:GetAttribute("Id")
			if id and remaining[id] then
				remaining[id] = nil
			end
		end
		if next(remaining) == nil then return true end
		task.wait(0.1)
	end
	for id in pairs(remaining) do
		warnf("placed model with Id %s did not appear under %s.Items", tostring(id), tycoon.Name)
	end
	return false
end

local function buildFactory(baseInfo, plan, onProgress)
	BuildState.building = true
	BuildState.stopRequested = false
	BuildState.placed = 0
	BuildState.rejected = 0
	BuildState.lastRejectReason = nil

	local tycoon = baseInfo.tycoon
	local basePart = baseInfo.basePart
	local yaw = plan.yaw

	local queue = {}
	for _, row in ipairs(plan.rows) do
		for _, cell in ipairs(row.items) do
			table.insert(queue, cell)
		end
	end
	if plan.usesTeleporters then
		for _, pair in ipairs(plan.tpPairs) do
			if pair.receiverCell then table.insert(queue, pair.receiverCell) end
			if pair.senderCell then table.insert(queue, pair.senderCell) end
		end
	end

	local batch = {}
	local function flush()
		if #batch == 0 then return true end
		local entries = {}
		for _, cell in ipairs(batch) do
			table.insert(entries, {
				Name = cell.name,
				CFrame = worldCFrame(basePart, cell.def, cell.cx, cell.cz, yaw),
				State = nil,
			})
		end
		local results, normErr = placeBatch(entries)
		if not results then
			errf("PlaceItem invoke failed: %s", tostring(normErr))
			BuildState.lastRejectReason = "PlaceItem failed: " .. tostring(normErr)
			BuildState.building = false
			return false
		end
		local confirmedIds = {}
		local bought = false
		for i, res in ipairs(results) do
			local cell = batch[i]
			if res.bought then
				bought = true
				BuildState.rejected = BuildState.rejected + 1
				BuildState.lastRejectReason = ("server PURCHASED a copy of %s (inventory violation) - build aborted"):format(cell.name)
				errf("%s", BuildState.lastRejectReason)
			elseif res.ok then
				BuildState.placed = BuildState.placed + 1
				table.insert(confirmedIds, res.id)
			else
				BuildState.rejected = BuildState.rejected + 1
				BuildState.lastRejectReason = ("%s rejected: %s"):format(cell.name, res.reason or "unknown")
				warnf("%s", BuildState.lastRejectReason)
			end
		end
		if #confirmedIds > 0 then
			verifyPlacedModels(tycoon, confirmedIds)
		end
		if onProgress then onProgress() end
		if bought then
			BuildState.building = false
			return false
		end
		batch = {}
		return true
	end

	for _, cell in ipairs(queue) do
		if BuildState.stopRequested then
			note("build stopped by user after %d placed, %d rejected", BuildState.placed, BuildState.rejected)
			flush()
			BuildState.building = false
			return true, "stopped"
		end
		table.insert(batch, cell)
		if #batch >= CONFIG.BATCH_SIZE then
			if not flush() then return false, BuildState.lastRejectReason end
		end
	end
	if not flush() then return false, BuildState.lastRejectReason end

	BuildState.building = false
	return true, nil
end

------------------------------------------------------------------------------
-- GUI (mobile + desktop friendly)
------------------------------------------------------------------------------

local UI = {}
local connectButtons

local function make(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	inst.Parent = parent
	return inst
end

local function guiParentCandidates()
	local candidates = {}
	pcall(function()
		table.insert(candidates, LocalPlayer:WaitForChild("PlayerGui"))
	end)
	if type(gethui) == "function" then
		pcall(function()
			local h = gethui()
			if h then table.insert(candidates, h) end
		end)
	end
	pcall(function()
		table.insert(candidates, game:GetService("CoreGui"))
	end)
	return candidates
end

local function buildGuiIn(parent)
	setStage("building gui in " .. tostring(parent))
	local old = nil
	pcall(function()
		old = parent:FindFirstChild("OreValueMaximiserGui")
	end)
	if old then old:Destroy() end

	local gui = make("ScreenGui", {
		Name = "OreValueMaximiserGui",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, parent)
	gui.DisplayOrder = 999999
	gui.Enabled = true

	local isMobile = false
	pcall(function()
		isMobile = game:GetService("UserInputService").TouchEnabled
			and not game:GetService("UserInputService").MouseEnabled
	end)
	local scale = isMobile and CONFIG.UI_SCALE_MOBILE or 1

	local panel = make("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(320 * scale, 430 * scale),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		BackgroundColor3 = Color3.fromRGB(24, 26, 34),
		BorderSizePixel = 0,
		Active = true,
		Parent = gui,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 10) }, panel)
	make("UIStroke", { Color = Color3.fromRGB(90, 200, 250), Thickness = 2 }, panel)

	local title = make("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 34 * scale),
		BackgroundTransparency = 1,
		Text = "ORE VALUE MAXIMISER",
		TextColor3 = Color3.fromRGB(120, 220, 255),
		Font = Enum.Font.GothamBold,
		TextSize = 17 * scale,
		Parent = panel,
	})

	local status = make("TextLabel", {
		Name = "Status",
		Size = UDim2.new(1, -16, 0, 44 * scale),
		Position = UDim2.new(0, 8, 0, 36 * scale),
		BackgroundTransparency = 1,
		Text = "Idle. Press SCAN INVENTORY.",
		TextColor3 = Color3.fromRGB(230, 230, 230),
		Font = Enum.Font.Gotham,
		TextSize = 13 * scale,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = panel,
	})

	local stats = make("TextLabel", {
		Name = "Stats",
		Size = UDim2.new(1, -16, 0, 92 * scale),
		Position = UDim2.new(0, 8, 0, 82 * scale),
		BackgroundTransparency = 1,
		Text = "-",
		TextColor3 = Color3.fromRGB(180, 255, 190),
		Font = Enum.Font.Code,
		TextSize = 12 * scale,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = panel,
	})

	local buttons = {}
	local labels = { "SCAN INVENTORY", "CALCULATE BEST ORDER", "BUILD OPTIMISED FACTORY", "STOP" }
	for i, label in ipairs(labels) do
		local btn = make("TextButton", {
			Name = label,
			Size = UDim2.new(1, -16, 0, 46 * scale),
			Position = UDim2.new(0, 8, 0, (178 + (i - 1) * 52) * scale),
			BackgroundColor3 = i == 4 and Color3.fromRGB(150, 50, 50) or Color3.fromRGB(40, 90, 160),
			Text = label,
			TextColor3 = Color3.fromRGB(255, 255, 255),
			Font = Enum.Font.GothamBold,
			TextSize = 16 * scale,
			AutoButtonColor = true,
			Parent = panel,
		})
		make("UICorner", { CornerRadius = UDim.new(0, 8) }, btn)
		buttons[i] = btn
	end

	-- drag (mouse + touch)
	do
		local dragging, dragStart, startPos = false, nil, nil
		local function inputBegan(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = panel.Position
			end
		end
		title.InputBegan:Connect(inputBegan)
		panel.InputBegan:Connect(function(input)
			if input.Position.Y - panel.AbsolutePosition.Y < 40 then
				inputBegan(input)
			end
		end)
		local uis = game:GetService("UserInputService")
		uis.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = input.Position - dragStart
				panel.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
			end
		end)
		uis.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
	end

	UI.gui = gui
	UI.status = status
	UI.stats = stats
	UI.buttons = buttons
	return gui
end

local function buildGui()
	local lastErr
	for _, parent in ipairs(guiParentCandidates()) do
		local ok, gui = pcall(buildGuiIn, parent)
		if ok and gui and gui.Parent == parent then
			setStage("gui built in " .. parent:GetFullName())
			note("GUI parented to %s", parent:GetFullName())
			task.delay(3, function()
				if not gui.Parent then
					warn("[OreVM] GUI was removed from " .. parent:GetFullName() .. " - rebuilding")
					pcall(buildGui)
					if connectButtons then pcall(connectButtons) end
				end
			end)
			return gui
		end
		if not ok then lastErr = gui end
		pcall(function()
			if gui then gui:Destroy() end
		end)
	end
	errf("could not create the GUI in any container (last error: %s). If you are in Roblox Studio, run this while PLAYING, not in edit mode.", tostring(lastErr))
	copyReport()
	return nil
end

local function setStatus(text, isError)
	if UI.status then
		UI.status.Text = text
		UI.status.TextColor3 = isError and Color3.fromRGB(255, 120, 120) or Color3.fromRGB(230, 230, 230)
	end
	if isError then
		warn("[OreVM] " .. text)
	end
end

local function setStats(text)
	if UI.stats then
		UI.stats.Text = text
	end
end

local function setButtonsEnabled(enabled)
	if UI.buttons then
		for i, btn in ipairs(UI.buttons) do
			btn.Active = enabled
			btn.AutoButtonColor = enabled
		end
	end
end

local function fmtMult(gainLog10)
	if not gainLog10 then return "?" end
	if gainLog10 < 6 then
		return string.format("x%.0f", 10 ^ gainLog10)
	end
	return string.format("10^%.2f", gainLog10)
end

------------------------------------------------------------------------------
-- BUTTON LOGIC / MAIN FLOW
------------------------------------------------------------------------------

local Session = {
	scan = nil,
	plan = nil,
	result = nil,
	startValue = nil,
}

local function missingModulesMessage()
	local missing = missingModules()
	if #missing > 0 then
		return "Missing required libraries: " .. table.concat(missing, ", ") .. ". Open your base fully and retry."
	end
	return nil
end

local function doScan()
	local missing = missingModulesMessage()
	if missing then
		setStatus(missing, true)
		return
	end
	setStatus("Scanning inventory...")
	setButtonsEnabled(false)
	local scan, scanErr = scanInventory()
	setButtonsEnabled(true)
	if not scan then
		setStatus("Scan failed: " .. tostring(scanErr), true)
		return
	end
	Session.scan = scan
	local lines = {
		("Available upgraders: %d"):format(#scan.available),
		("Teleporters owned: %d"):format(#scan.teleporters),
	}
	local excl = 0
	for _ in pairs(scan.excluded) do excl = excl + 1 end
	lines[3] = ("Excluded: %d (see console F9 for reasons)"):format(excl)
	setStatus("Scan complete. Press CALCULATE BEST ORDER.")
	setStats(table.concat(lines, "\n"))
	note("=== SCAN RESULTS ===")
	for _, e in ipairs(scan.available) do
		note("  upgrader: %s (x%d available)", e.name, e.left)
	end
	for _, tp in ipairs(scan.teleporters) do
		note("  teleporter: %s (x%d)", tp.name, tp.left)
	end
	for name, reason in pairs(scan.excluded) do
		warnf("  excluded: %s - %s", name, reason)
	end
end

local function doCalculate()
	if not Session.scan then
		setStatus("Scan first (SCAN INVENTORY).", true)
		return
	end
	setStatus("Calculating best order (beam search)...")
	setButtonsEnabled(false)
	task.wait()
	local itemMap = getItemMap()
	local owned = getOwnedCounts()
	Session.startValue = estimateStartValue(itemMap, owned)
	note("start value assumed: %s (best owned dropper)", Session.startValue:toString())

	local ok, result = pcall(runOptimiser, Session.scan.available, Session.startValue)
	setButtonsEnabled(true)
	if not ok then
		setStatus("Optimiser error: " .. tostring(result), true)
		return
	end
	if not result then
		setStatus("No valid sequence found.", true)
		return
	end
	Session.result = result
	local orderText = #result.order > 0 and table.concat(result.order, " -> ") or "(none)"
	note("=== BEST ORDER (%d items, est. multiplier %s) ===", #result.order, fmtMult(result.gainLog10))
	note("  %s", orderText)
	setStatus(("Best order found: %s"):format(fmtMult(result.gainLog10)))
	setStats(table.concat({
		("Available upgraders: %d"):format(#Session.scan.available),
		("Selected: %d"):format(#result.order),
		("Estimated multiplier: %s"):format(fmtMult(result.gainLog10)),
	}, "\n"))
end

local function doBuild()
	if not Session.result then
		setStatus("Calculate the order first (CALCULATE BEST ORDER).", true)
		return
	end
	local missing = missingModulesMessage()
	if missing then
		setStatus(missing, true)
		return
	end
	setStatus("Detecting base...")
	local baseInfo, missingObjs = detectBase()
	if not baseInfo then
		setStatus("Base detection failed.", true)
		errf("Base detection failed. Missing objects:")
		for _, m in ipairs(missingObjs) do
			errf("  - %s", m)
		end
		setStats("Base detection failed:\n" .. table.concat(missingObjs, "\n"))
		return
	end
	note("base found: %s (floor part %s, size %s)", baseInfo.tycoon:GetFullName(), baseInfo.basePart.Name, tostring(baseInfo.basePart.Size))

	setStatus("Planning layout...")
	local byName = {}
	for _, e in ipairs(Session.scan.available) do byName[e.name] = e end
	local ordered = {}
	for _, name in ipairs(Session.result.order) do
		local e = byName[name]
		if e then table.insert(ordered, e) end
	end
	local plan, planErr = planLayout(baseInfo.basePart, baseInfo.items, ordered, Session.scan.teleporters)
	if planErr then
		setStatus("Layout planning failed: " .. tostring(planErr), true)
		return
	end
	if #plan.rows == 0 then
		setStatus("No space found for any upgrader (base full or blocked).", true)
		return
	end

	Session.plan = plan
	for _, n in ipairs(plan.notes) do
		note("layout note: %s", n)
	end
	note("layout: %d row(s), %d item(s) fit, %d did not fit, teleporter link: %s",
		#plan.rows, plan.fitCount, plan.leftover, tostring(plan.usesTeleporters))

	if plan.leftover > 0 then
		note("%d item(s) of the optimal sequence did not fit and were NOT placed", plan.leftover)
	end

	setStatus("Building factory...")
	setButtonsEnabled(false)
	local okResult, buildErr
	local done = false
	task.spawn(function()
		okResult, buildErr = buildFactory(baseInfo, plan, function()
			setStats(table.concat({
				("Rows: %d"):format(#plan.rows),
				("Placed: %d"):format(BuildState.placed),
				("Rejected: %d"):format(BuildState.rejected),
			}, "\n"))
		end)
		done = true
	end)
	while not done do
		if BuildState.stopRequested then
			BuildState.stopRequested = true
		end
		task.wait(0.05)
	end
	setButtonsEnabled(true)
	if okResult then
		if buildErr == "stopped" then
			setStatus(("Build stopped. Placed: %d, rejected: %d."):format(BuildState.placed, BuildState.rejected), true)
		else
			setStatus(("Build complete. Placed: %d, rejected: %d."):format(BuildState.placed, BuildState.rejected))
		end
	else
		setStatus("Build aborted: " .. tostring(buildErr), true)
	end
end

local function doStop()
	BuildState.stopRequested = true
	setStatus("STOP requested - finishing current batch then halting.")
end

local function bootstrap()
	local missing = missingModules()
	local guiOk, guiErr = pcall(buildGui)
	if not guiOk then
		errf("buildGui failed: %s", tostring(guiErr))
	end
	connectButtons = function()
		if UI.buttons then
			UI.buttons[1].Activated:Connect(doScan)
			UI.buttons[2].Activated:Connect(doCalculate)
			UI.buttons[3].Activated:Connect(doBuild)
			UI.buttons[4].Activated:Connect(doStop)
		end
	end
	if #missing > 0 then
		setStatus("Missing libraries: " .. table.concat(missing, ", ") .. ". Press SCAN INVENTORY once your base loads.", true)
	end
	connectButtons()
	setStage("ready - waiting for SCAN INVENTORY")
	note("loaded. Waiting for SCAN INVENTORY.")
end

------------------------------------------------------------------------------
-- EXPOSED INTERNALS (for testing / debugging in the console)
------------------------------------------------------------------------------

local API = {
	CONFIG = CONFIG,
	Diagnostics = Diagnostics,
	BuildState = BuildState,
	Session = Session,
	Modules = Modules,
	BigNum = BigNum,
	parseValue = parseValue,
	getBeamGroups = getBeamGroups,
	newOreState = newOreState,
	cloneState = cloneState,
	evalSpecials = evalSpecials,
	simulateItem = simulateItem,
	optimisticGain = optimisticGain,
	scanInventory = scanInventory,
	estimateStartValue = estimateStartValue,
	runOptimiser = runOptimiser,
	detectBase = detectBase,
	planLayout = planLayout,
	worldCFrame = worldCFrame,
	normaliseResults = normaliseResults,
	placeBatch = placeBatch,
	buildFactory = buildFactory,
	getOwnedCounts = getOwnedCounts,
	getPlacedCounts = getPlacedCounts,
	nameIsForbidden = nameIsForbidden,
	hasRiskySpecials = hasRiskySpecials,
	cleansesEffect = cleansesEffect,
	fmtMult = fmtMult,
	setStatus = setStatus,
	setStats = setStats,
	copyReport = copyReport,
	buildReport = buildReport,
}
-- Some environments freeze _G; fall back to shared so the API is reachable.
local exportOk = pcall(function()
	_G.OreValueMaximiser = API
end)
if not exportOk and typeof(shared) == "table" then
	pcall(function()
		shared.OreValueMaximiser = API
	end)
end


pcall(function()
	game:GetService("UserInputService").InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.F8 then
			copyReport()
		end
	end)
end)

if RunService:IsRunning() then
	bootstrap()
else
	note("environment not running - internals exposed at _G.OreValueMaximiser (GUI not built)")
end
