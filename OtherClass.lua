local _, wt = ...

-- Browse another class's trainer and quest spells, and its weapon skills, in place of your own.
-- These spells get their own info objects instead of going through spellInfoCache: some spells,
-- like Parry, are trained by several classes at different levels, and the cache holds the
-- player's own.

wt.OTHER_CLASS_KEY = "otherClass"
-- class token being browsed, nil while showing the player's own class
wt.viewedClass = nil

local CLASS_ORDER = {"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID"}
local entries = {} -- class token -> category entry, as wt.applyFilter expects
local loading = {}

function wt.browsableClasses()
    local result = {}
    for _, token in ipairs(CLASS_ORDER) do
        local class = wt.ClassData[token]
        if class and class.spellsByLevel then tinsert(result, token) end
    end
    return result
end

function wt.className(token)
    return LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token] or token
end

local function raceInfo(raceId)
    return C_CreatureInfo and C_CreatureInfo.GetRaceInfo and C_CreatureInfo.GetRaceInfo(raceId)
end

-- nil when the race's faction is unknown (custom races), so those are never filtered out
local function raceFaction(raceId)
    local info = C_CreatureInfo and C_CreatureInfo.GetFactionInfo and C_CreatureInfo.GetFactionInfo(raceId)
    return info and info.groupTag
end

local function playerSideRaces(races)
    local result = {}
    for _, race in ipairs(races) do
        local faction = raceFaction(race)
        if faction == nil or faction == wt.playerFaction then tinsert(result, race) end
    end
    return result
end

-- quest spells come from a different quest per race; prefer the player's race, then their faction
local function questVariant(variants)
    local sameFaction
    for _, variant in ipairs(variants) do
        if tContains(variant.races, wt.playerRace) then return variant end
        if not sameFaction and #playerSideRaces(variant.races) > 0 then sameFaction = variant end
    end
    return sameFaction or variants[1]
end

local function collectSpells(token)
    local class = wt.ClassData[token]
    local spells = {}
    for level, spellsAtLevel in pairs(wt.FactionFilter(class.spellsByLevel)) do
        for _, spell in ipairs(spellsAtLevel) do
            local races = spell.races or (spell.race and {spell.race})
            if races then races = playerSideRaces(races) end
            if not races or #races > 0 then
                tinsert(spells, {id = spell.id, level = level, cost = spell.cost, races = races,
                    talent = spell.requiredTalentId ~= nil})
            end
        end
    end
    for id, variants in pairs((wt.QuestSpells or {})[token] or {}) do
        local variant = questVariant(variants)
        if variant then
            tinsert(spells, {id = id, level = variant.level, cost = 0, quest = {
                areas = variant.areas or {variant.area}, quests = variant.quests, level = variant.level,
            }})
        end
    end
    return spells
end

local function makeSpellInfo(spell, resolved)
    local notes = {}
    for _, race in ipairs(spell.races or {}) do
        local info = raceInfo(race)
        if info and info.raceName then tinsert(notes, info.raceName) end
    end
    if spell.talent then tinsert(notes, wt.L.OTHER_CLASS_TALENT) end
    local subText = resolved.subText or ""
    if #notes > 0 then
        subText = (subText ~= "" and subText .. " • " or "") .. table.concat(notes, ", ")
    end
    local formattedSubText = subText ~= "" and format(PARENS_TEMPLATE, subText) or ""
    local formattedFullName = subText ~= "" and format("%s %s", resolved.name, formattedSubText) or resolved.name
    return {
        id = spell.id,
        name = resolved.name,
        subText = subText ~= "" and subText or nil,
        formattedSubText = formattedSubText,
        icon = resolved.icon,
        cost = spell.cost,
        quest = spell.quest,
        tooltipType = "spell",
        tooltipId = spell.id,
        formattedCost = C_CurrencyInfo.GetCoinTextureString(spell.cost),
        level = spell.level,
        formattedLevel = format(wt.L.LEVEL_FORMAT, spell.level),
        levelColor = GetQuestDifficultyColor(spell.level),
        formattedFullName = formattedFullName,
        searchText = strlower(formattedFullName),
        link = resolved.link,
        otherClass = true,
    }
end

-- trainer spells before quest spells of the same level, as in the player's own list
local function byLevelThenName(a, b)
    if a.level ~= b.level then return a.level < b.level end
    if (a.quest == nil) ~= (b.quest == nil) then return b.quest ~= nil end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
end

local function makeEntry(token, spells)
    sort(spells, byLevelThenName)
    local category = {
        key = wt.OTHER_CLASS_KEY,
        name = format(wt.L.OTHER_CLASS_HEADER, wt.className(token)),
        isHeader = true,
        otherClass = true,
        cost = 0,
        spells = spells,
    }
    category.formattedName = category.name
    local totalCost = 0
    for _, spell in ipairs(spells) do totalCost = totalCost + spell.cost end
    return {category = category, spells = spells, totalCost = totalCost}
end

-- resolves names, ranks and icons, then shows the list if that class is still selected
local function load(token)
    if entries[token] or loading[token] then return end
    loading[token] = true
    local spells, infos = collectSpells(token), {}
    local pending = #spells
    local function finish()
        entries[token] = makeEntry(token, infos)
        loading[token] = nil
        if wt.viewedClass == token then wt:ApplyFilter() end
    end
    if pending == 0 then return finish() end
    for _, spell in ipairs(spells) do
        wt.ResolveSpell(spell.id, function(resolved)
            if resolved and resolved.name then tinsert(infos, makeSpellInfo(spell, resolved)) end
            pending = pending - 1
            if pending == 0 then finish() end
        end)
    end
end

-- the category entry for wt.applyFilter, or nil while the class is still loading
function wt.otherClassEntry(token)
    return entries[token]
end

-- Weapon skills reuse the player's spell info (it only depends on the skill), wrapped so the
-- class's status is "trained at level N" rather than the player's known/ignored state.

wt.OTHER_CLASS_WEAPON_KEY = "otherClassWeapons"

local function byWeaponOrder(a, b)
    local orderA, orderB = a.weaponOrder or 999, b.weaponOrder or 999
    if orderA ~= orderB then return orderA < orderB end
    if a.level ~= b.level then return a.level < b.level end
    return a.id < b.id
end

-- Built on each call: it's a few dozen skills, and their names can finish loading after login.
-- wrapperById: for the grouped views; entry: the category entry for the flat list.
function wt.otherClassWeapons(token)
    local faction = wt.playerFaction
    local wrapperById, listed, totalCost = {}, {}, 0
    for weaponId, weapon in pairs(wt.WeaponSkills or {}) do
        local info = weapon.classes[token] and wt:SpellInfo(weaponId)
        if info then
            local trained = weapon.trainers and weapon.trainers[faction]
            local order = weapon.orderIndex
            local wrapper = setmetatable({
                otherClass = true,
                altTooltipType = "weapon",
                isKnown = false,
                hideLevel = false,
                weaponOrder = order,
                sortOrder = wt.WeaponGrouping and wt.WeaponGrouping.computeSortOrder(order, false) or order,
                levelColor = GetQuestDifficultyColor(info.level),
                -- the grouped views and the flat list word the trainer cities differently
                formattedTrainerZones = trained and weapon[faction .. "GroupedFormattedTrainerZones"] or nil,
            }, {__index = info})
            wrapperById[weaponId] = wrapper
            tinsert(listed, setmetatable({
                trainerZones = trained and weapon[faction .. "TrainerZones"] or nil,
                formattedTrainerZones = trained and weapon[faction .. "FormattedTrainerZones"] or nil,
            }, {__index = wrapper}))
            totalCost = totalCost + (info.cost or 0)
        end
    end
    sort(listed, byWeaponOrder)
    local category = {
        key = wt.OTHER_CLASS_WEAPON_KEY,
        name = format(wt.L.OTHER_CLASS_WEAPONS_TITLE, wt.className(token)),
        isHeader = true,
        otherClass = true,
        cost = 0,
    }
    category.formattedName = category.name
    return {wrapperById = wrapperById, entry = {category = category, spells = listed, totalCost = totalCost}}
end

function wt.IsViewedClass(token)
    return (wt.viewedClass or wt.currentClass) == token
end

function wt.SetViewedClass(token)
    if token == wt.currentClass then token = nil end
    if wt.viewedClass == token then return end
    wt.viewedClass = token
    local frame = wt.MainFrame
    if frame then
        for _, page in ipairs({frame, frame.weaponPage}) do
            if page.scrollFrame then page.scrollFrame:SetVerticalScroll(0) end
        end
        if frame.pagingControls then frame.pagingControls:SetCurrentPage(1) end
    end
    if token then load(token) end
    wt:ApplyFilter()
end
