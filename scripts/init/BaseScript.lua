local function GetSettingsMenu()
	local Windows = getForgottenGUI().guiWindows
	for K in pairs(Windows) do
		print(K, V)
	end
end

--GetSettingsMenu()

local bHappyFamiliesDebugMode = true
local bNoCheck = false

--Time in days
local TimeMultiplier = 1
local TOTAL_PREGNANCY_TIME = 9 * TimeMultiplier
local TOTAL_CHILDHOOD_TIME = 18 * TimeMultiplier
local TOTAL_ADULTHOOD_TIME = 100 * TimeMultiplier

local CHILD_HEALTH_MULT = 0.3 

local TIMEBETWEENPREGNANCIES_MAX = 0.15 * TimeMultiplier
local TIMEBETWEENPREGNANCIES_MIN = 0.5 * TimeMultiplier
local PREGNANCYCHANCE = bNoCheck and 1 or 0.3

local table_insert = table.insert

local HAPPYFAMILIES_FamilyTable_StringToObject = {}
local HAPPYFAMILIES_FamilyTable_ObjectToTable = {}
local ChildrenPerCharacter = {}
local LastPregnancyHunger = {}

local LastGameWorld = nil
local LastPlayerObj = nil
local counter = 0

--Edit these global vals in another file to create translation: e.g.
--MODSTRING_Children = "你没有孩子呀，天啊"
--They will be loaded automatically
MODSTRING_Children = MODSTRING_Children or "Children: "
MODSTRING_NoChildren = MODSTRING_NoChildren or "No Children."
MODSTRING_Father = MODSTRING_Father or "Father: "
MODSTRING_Mother = MODSTRING_Mother or "Mother: "
MODSTRING_ImPregnant = MODSTRING_ImPregnant or  "I think I'm pregnant..."
MODSTRING_FamilyTree = MODSTRING_FamilyTree or "Family Tree of "
MODSTRING_Deceased = MODSTRING_Deceased or " (Dead)"
MODSTRING_Unknown = MODSTRING_Unknown or "Unknown"
MODSTRING_Miscarriage = MODSTRING_Miscarriage or "I lost the baby..."


local math = math
local function math_randomrange(Min, Max)
	return Min + math.random()  * (Max - Min)
end

local function GetCurrentTime()
	return getGameWorld():getTimeStamp_inGameHours():getTotalDays()
end

local FamilyWindow
local FamilyWindow_FatherText
local FamilyWindow_MotherText
local FamilyWindow_ChildrenText

function FamilyWindow_Close()
	if FamilyWindow then
		pcall(function() FamilyWindow:destroy() end)
		FamilyWindow = nil
		FamilyWindow_FatherText = nil
		FamilyWindow_MotherText = nil
		FamilyWindow_ChildrenText = nil
	end
end

local function IsValidCharacter(char)
	if not char then return false end
	local ok, valid = pcall(function()
		if char.handle == nil then return false end
		if char.handle.isValid then
			return char.handle:isValid()
		end
		local id = char.handle:toString()
		return id ~= nil and id ~= ""
	end)
	return ok and valid
end

local function ResetModSessionState()
	HAPPYFAMILIES_FamilyTable_StringToObject = {}
	HAPPYFAMILIES_FamilyTable_ObjectToTable = {}
	ChildrenPerCharacter = {}
	LastPregnancyHunger = {}
	counter = 0
	FamilyWindow_Close()
end

local function CheckAndResetOnReload()
	local ok, world, playerObj = pcall(function()
		return getGameWorld(), (getPlayerInterface() or player)
	end)

	if not ok or not world or not playerObj then
		ResetModSessionState()
		LastGameWorld = nil
		LastPlayerObj = nil
		return false
	end

	if world ~= LastGameWorld or playerObj ~= LastPlayerObj then
		ResetModSessionState()
		LastGameWorld = world
		LastPlayerObj = playerObj
		return false
	end

	return true
end

local function IsThereSpaceInSquad(Character)
	local Platoon = Character:getPlatoon()
	if not Platoon then return false end
	
	--If squad too big
	if (Platoon:getSquadSize() + 1) >= getGlobalConstants().MAX_SQUAD_SIZE then
		return false
	end
	
	local PlayerObj = getPlayerInterface() or player
	if not PlayerObj or not PlayerObj.playerCharacters then return false end
	
	--If faction too big
	if (PlayerObj.playerCharacters:size() + 1) >= getGlobalConstants().MAX_FACTION_SIZE then
		return false
	end
	
	return true
end


local function IsInPlayerFaction(character)
	local PlayerObj = getPlayerInterface() or player
	local faction = PlayerObj:getFaction()
	return character:getFaction():getName() == faction:getName()
end

--Not used
---[[
local function FindFatherID(Child)
	return Child:getAppearanceData().idata.FatherID
end

local function FindMotherID(Child)
	return Child:getAppearanceData().idata.MotherID
end
--]]

local function FindFather(Child)
	local FamilyTable = GetFamilyTable(Child)
	if not FamilyTable then return nil end
	local FatherStringID = FamilyTable.FatherStringID
	if not FatherStringID then return nil end
	local Father = HAPPYFAMILIES_FamilyTable_StringToObject[FatherStringID]
	if IsValidCharacter(Father) then
		return Father
	end
	HAPPYFAMILIES_FamilyTable_StringToObject[FatherStringID] = nil
	return nil
end

local function FindMother(Child)	
	local FamilyTable = GetFamilyTable(Child)
	if not FamilyTable then return nil end
	local MotherStringID = FamilyTable.MotherStringID
	if not MotherStringID then return nil end
	local Mother = HAPPYFAMILIES_FamilyTable_StringToObject[MotherStringID]
	if IsValidCharacter(Mother) then
		return Mother
	end
	HAPPYFAMILIES_FamilyTable_StringToObject[MotherStringID] = nil
	return nil
end


--If mother or father is dead or despawned, use this instead
local function FindMotherName(Child, bAddDeceasedString)
	local Mother = FindMother(Child)
	
	if Mother then
		return Mother:getName()
	else 
		local FamilyTable = GetFamilyTable(Child)
		
		if FamilyTable and FamilyTable.MotherName then
			if bAddDeceasedString then
				return FamilyTable.MotherName .. MODSTRING_Deceased
			else
				return FamilyTable.MotherName
			end		
		end		
		
		return MODSTRING_Unknown
	end
end

local function FindFatherName(Child, bAddDeceasedString)
	local Father = FindFather(Child)
	
	if Father then
		return Father:getName()
	else 
		local FamilyTable = GetFamilyTable(Child)
		
		if FamilyTable and FamilyTable.FatherName then
			if bAddDeceasedString then
				return FamilyTable.FatherName .. MODSTRING_Deceased
			else
				return FamilyTable.FatherName
			end		
		end		
		return MODSTRING_Unknown
	end
end

--Update mother and father name so they can be stored if character is despawned or dies
local function UpdateMotherAndFatherName(Child)
	local Father = FindFather(Child)
	local Mother = FindMother(Child)
	
	local AppDataBase = Child:getAppearance()
	
	if Father then
		AppDataBase.appearanceData.sdata.FatherName = Father:getName()
	end
	if Mother then
		AppDataBase.appearanceData.sdata.MotherName = Mother:getName()		
	end
end

local function FindFatherOfCurrentChild(Mother)
	local FamilyTable = GetFamilyTable(Mother)
	if not FamilyTable then return nil end

	if FamilyTable.FatherOfCurrentChildID then
		local Father = HAPPYFAMILIES_FamilyTable_StringToObject[FamilyTable.FatherOfCurrentChildID]
		if IsValidCharacter(Father) then
			return Father
		end
	end

	if IsValidCharacter(FamilyTable.FatherOfCurrentChild) then
		return FamilyTable.FatherOfCurrentChild
	end

	FamilyTable.FatherOfCurrentChild = nil
	return nil
end

local function LerpFloat(A, B, LerpVal)
	return A + (LerpVal * (B - A))
end

function FamilyWindow_SetText(Character)
	if not IsValidCharacter(Character) then return end
	if Character:isAnimal() then return end
	if not FamilyWindow then return end
	
	FamilyWindow:setCaption(MODSTRING_FamilyTree .. Character:getName())
	
	FamilyWindow_FatherText:setCaption(MODSTRING_Father .. FindFatherName(Character, true))
	FamilyWindow_MotherText:setCaption(MODSTRING_Mother .. FindMotherName(Character, true))
	
	local Children = ChildrenPerCharacter_Get(Character)
	local ValidNames = {}
	if Children then
		for i = 1, #Children do
			if IsValidCharacter(Children[i]) then
				table_insert(ValidNames, Children[i]:getName())
			end
		end
	end
	
	local ChildrenString
	if #ValidNames > 0 then
		ChildrenString = MODSTRING_Children .. table.concat(ValidNames, ", ")
	else
		ChildrenString = MODSTRING_NoChildren
	end
	
	FamilyWindow_ChildrenText:setCaption(ChildrenString)
end

local function RecruitCharacter(character)
	local playerObj = getPlayerInterface()
	local playerFaction = playerObj.participant
    local activeSquad = nil
    if playerObj.currentPlatoon then
        activeSquad = playerObj.currentPlatoon.activePlatoon
    end
	character:setFaction(playerFaction, activeSquad)
end

local function OnSelectCharacter(character)
	pcall(function()
		if not CheckAndResetOnReload() then return end
		if not IsValidCharacter(character) then return end
		if character:isAnimal() then return end	
		if not character:isPlayerCharacter() then 
			if false then RecruitCharacter(character) end
			return 
		end
		FamilyWindow_SetText(character)
	end)
end
Events.on("Character::_NV_select", OnSelectCharacter)

local function FamilyWindow_AddTextWidgets(Character)
	FamilyWindow:upLayerItem()
	
	FamilyWindow_FatherText = FamilyWindow:createWidget(
		"TextBox",
		"Kenshi_TextboxPaintedText",
		0, -40, 300, 100,
		0,
		"FatherText"
	)
	
	FamilyWindow_FatherText:setProperty("TextAlign", "Center VCenter")
	
	FamilyWindow_MotherText = FamilyWindow:createWidget(
		"TextBox",
		"Kenshi_TextboxPaintedText",
		300, -40, 300, 100,
		0,
		"MotherText"
	)
	
	FamilyWindow_MotherText:setProperty("TextAlign", "Center VCenter")
	
	FamilyWindow_ChildrenText = FamilyWindow:createWidget(
		"TextBox",
		"Kenshi_TextboxPaintedText",
		0, 40, 600, 50,
		0,
		"ChildrenText"
	)
	FamilyWindow_ChildrenText:setProperty("TextAlign", "Center VCenter")
	
	FamilyWindow_SetText(Character)
end

local function FamilyWindow_OnOpen(input_handler, key_code)
	--33 is F
	if key_code ~= 33 then 
		return 
	end
	
	if FamilyWindow then
		FamilyWindow_Close()
		return 
	end

	if not CheckAndResetOnReload() then return end
	
	local selectedCharacter = getPlayerInterface().selectedCharacter
	if not selectedCharacter then return end
	selectedCharacter = selectedCharacter:getCharacter()
	if not IsValidCharacter(selectedCharacter) then return end
	if not selectedCharacter:isPlayerCharacter() then return end
	if selectedCharacter:isAnimal() then return end

	FamilyWindow = MyGUI.createWindow(
		"Kenshi_WindowCX", 
		0, 0, 600, 150, 
		"ExampleWindow", 
		"Window"
	)
	
	FamilyWindow:registerCallback("eventWindowButtonPressed", function(sender)
		if FamilyWindow then 
			FamilyWindow_Close()
		end
	end)
	
	FamilyWindow_AddTextWidgets(selectedCharacter)
end
	

Events.on("InputHandler::keyDownEvent", FamilyWindow_OnOpen)

local AllStats = {
	"perception",
	"medic",
	"fitness",
	"massCombat",
	"arrowDefence",
	"swimming",
	"thieving",
	"lockpicking",
	"bluff",
	"assassin",
	"survival",
	"tracking",
	"climbing",
	"doctor",
	"engineer",
	"weaponSmith",
	"armourSmith",
	"bowSmith",
	"robotics",
	"science",
	"labouring",
	"farming",
	"cooking",
	"dodging",
	"friendlyFire",
	"katanas",
	"sabres",
	"hackers",
	"blunt",
	"heavyWeapons",
	"unarmed",
	"bows",
	"turrets",
	"polearms",
	"warriorSpirit",
	"derivedSpirit",
	"aggression",
	"goodness",
	"evilness",
	"stealth",
	
	"__meleeAttack",
	"_meleeDefence",
	
	"_strength",
	"_dexterity",
	"_toughness",
	"_athletics"
}

local RaceStringIDToName = {
	["17-gamedata.quack"] = "Greenlander",
	["18019-gamedata.base"] = "Scorchlander",
	["5276-chareditor.mod"] = "Shek",
	["2603-gamedata.base"] = "Cannibal",
	["50523-rebirth.mod"] = "CannibalSkav"
}

local function RaceTypeCanReproduce(Character)
	if not Character.myRace or not Character.myRace.data then return nil end
	local RaceName = RaceStringIDToName[Character.myRace.data.stringID]
	if not RaceName then return nil end
	local RaceTemplateName = "HF_Random" .. RaceName
	local RaceTemplate = getGameWorld().gamedata:getDataByName(RaceTemplateName, itemType.CHARACTER)
	return RaceTemplate 
end


local function GetAncestorList(Character, Iterations, OutTable, bDebugMode)
	OutTable = OutTable or {}
	
	if not IsValidCharacter(Character) then return OutTable end
	
	OutTable[Character] = true
	
	local Father = FindFather(Character)
	local Mother = FindMother(Character)	
	
	
	if Iterations > 0 then 
		if Father then GetAncestorList(Father, Iterations - 1, OutTable) end
		if Mother then GetAncestorList(Mother, Iterations - 1, OutTable) end
	end
	
	if bDebugMode and bHappyFamiliesDebugMode then
		local String = Character:getName() .. "'s ancestors: "
		for Ancestor in pairs(OutTable) do
			if IsValidCharacter(Ancestor) then
				String = String .. Ancestor:getName() .. ", "
			end
		end
		
		print(String)
	end
	
	return OutTable
end

g_GetAncestorList = GetAncestorList

local function CoupleCantReproduce(Mother, Father)
	local NextAllowedChildCheck = Mother:getAppearanceData().fdata.NextAllowedChildCheck
	if NextAllowedChildCheck 
	and GetCurrentTime() < NextAllowedChildCheck then
		return "Too soon since I last tried"
	end
	
	if not IsThereSpaceInSquad(Mother) then return "No space in squad" end
	
	if not RaceTypeCanReproduce(Mother) then return "Mother cant reproduce" end
	if not RaceTypeCanReproduce(Father) then return "Father cant reproduce" end
	
	if Mother:getAppearanceData().fdata.ComeOfAgeTime then return "Not adult" end
	if Father:getAppearanceData().fdata.ComeOfAgeTime then return "Not adult" end
	
	if Mother.medical:isReallyHungry() or Father.medical:isReallyHungry() then
		return "Too hungry"
	end
	
	local MotherAncestors = GetAncestorList(Mother, 4, nil, bHappyFamiliesDebugMode)
	local FatherAncestors = GetAncestorList(Father, 4, nil, bHappyFamiliesDebugMode)
	
	for K, V in pairs(MotherAncestors) do
		if FatherAncestors[K] then return "Related" end
	end
	
	return nil
end

local function SelectRaceTemplate(Mother, Father)
	local RaceName = (math.random() > 0.5) and Mother.myRace.data.name or Father.myRace.data.name
	return getGameWorld().gamedata:getDataByName("HF_Random" .. RaceName, itemType.CHARACTER)
end

local ChildSliderValues_Shek = {
	["Height"] = 60,
	["Frame"] = 80,
	["Posture"] = 20,
	["Neck position"] = 30,
	["Leg length"] = 85,
	["Shoulders"] = 90,
	["Chest"] = 90,
	["Breast size"] = 25,
	["Breast height"] = 100,
	["Arm bulk"] = 100,
	["Waist"] = 100,
	["Stomach"] = 90,
	["Hips"] = 75,
	["Legs bulk"] = 90,
	["Legs shape"] = 100,
	["Feet"] = 110,
	
	["Head size"] = 110,
	["Head shape"] = 120,
	["Neck"] = 80,
	["Neck length"] = 90,
	
	["bone_narrow_jaw"] = 0.33,
	["bone_wide_jaw"] = 0,
	["bone_narrow_cheekbones"] = 0,
	["bone_wide_cheekbones"] = 0,
	["bone_up_chin"] = 0.92,
	["bone_down_chin"] = 0,
	["bone_long_nose"] = 0,
	["bone_arch_nose"] = -0.29,
	["bone_high_nose"] = -0.6,
	["bone_tiltup_nose"] = 0.88,
	["bone_tiltdown_nose"] = 0,
	["bone_high_brows"] = 0.13,
	["bone_big_eyes"] = 1,
	["bone_high_eyes"] = -1.04,
	["bone_underbite"] = 0,
	["bone_overbite"] = 0.17,
	["bone_wide_cheeks"] = 0.97,
	["bone_wide_chin"] = -0.26
}

local ChildSliderValues = {
	["Height"] = 70,
	["Frame"] = 80,
	["Posture"] = 20,
	["Neck position"] = 30,
	["Leg length"] = 90,
	["Shoulders"] = 90,
	["Chest"] = 90,
	["Breast size"] = 25,
	["Breast height"] = 100,
	["Arm bulk"] = 70,
	["Waist"] = 100,
	["Stomach"] = 90,
	["Hips"] = 75,
	["Legs bulk"] = 90,
	["Legs shape"] = 100,
	["Feet"] = 110,
	["Head size"] = 90,
	["Head shape"] = 110,
	["Neck"] = 80,
	["Neck length"] = 90,
	
	["narrow_jaw"] = 0.33,
	["wide_jaw"] = 0,
	["narrow_cheekbones"] = 0,
	["wide_cheekbones"] = 0,
	["up_chin"] = 0.92,
	["down_chin"] = 0,
	["long_nose"] = 0,
	["arch_nose"] = -0.29,
	["high_nose"] = -0.6,
	["tiltup_nose"] = 0.88,
	["tiltdown_nose"] = 0,
	["high_brows"] = 0.13,
	["big_eyes"] = 1.1,
	["high_eyes"] = -1.2,
	["underbite"] = 0.5,
	["overbite"] = 0,
	["wide_cheeks"] = 0.97,
	["wide_chin"] = -0.26
}

local AllSliderValues = {
	"wide_cheekbones",
	"narrow_cheekbones",
	"big_mouth",
	"wide_mouth",
	"wide_nose",
	"long_nose",
	"arch_nose",
	"high_nose",
	"tiltup_nose",
	"tiltdown_nose",
	"high_brow",
	"low_brow",
	"tiltdown_brow",
	"tiltup_brow",
	"shallow_eyes",
	"narrow_eyes",
	"close_eyes",
	"tiltup_eyes",
	"tiltdown_eyes",
	"high_eyes",
	"big_eyes",
	"overbite",
	"underbite",
	"Head size",
	"Head shape",
	"Neck",
	"Neck width",
	"Neck length",
	"Height",
	"Frame",
	"Posture",
	"Shoulder set",
	"Neck position",
	"Leg length",
	"Shoulders",
	"Arm bulk",
	"Hands",
	"Chest",
	"Stomach",
	"Waist",
	"Hips",
	"Legs bulk",
	"Legs shape",
	"Feet",
	"wide_cheeks",
	"Cheeks",
	"high_brows",
	"low_brows",
	"wide_jaw",
	"narrow_jaw",
	"down_chin",
	"up_chin",
	"wide_chin",
	"Breast size",
	"Breast height",
	"Breast spacing",
	"bone_wide_cheekbones",
	"bone_narrow_cheekbones",
	"bone_big_mouth",
	"bone_wide_mouth",
	"bone_wide_nose",
	"bone_long_nose",
	"bone_arch_nose",
	"bone_high_nose",
	"bone_tiltup_nose",
	"bone_tiltdown_nose",
	"bone_tiltdown_brow",
	"bone_tiltup_brow",
	"bone_high_brow",
	"bone_low_brow",
	"bone_shallow_eyes",
	"bone_narrow_eyes",
	"bone_close_eyes",
	"bone_tiltup_eyes",
	"bone_tiltdown_eyes",
	"bone_high_eyes",
	"bone_overbite",
	"bone_underbite",
	"bone_horns_curved",
	"bone_horns_top_short",
	"bone_horns_bottom_short",
	"bone_horns_thin",
	"bone_horns_thick",
	"bone_horns_body_short",
	"bone_wide_cheeks",
	"bone_high_brows",
	"bone_low_brows",
	"bone_big_eyes",
	"bone_wide_jaw",
	"bone_narrow_jaw",
	"bone_outward_chin",
	"bone_inward_chin",
	"bone_down_chin",
	"bone_up_chin",
	"bone_wide_chin",
	"bone_horns_thick",
	"wide_cheekbones",
	"narrow_cheekbones",
	"wide_cheeks",
	"high_brows",
	"low_brows",
	"wide_jaw",
	"narrow_jaw",
	"underbite",
	"overbite",
	"down_chin",
	"up_chin",
	"wide_chin",
	"outward_chin",
	"inward_chin",
	"Eyes shallowness"
}

local function GetChildSliderValues(Character)
	if Character.myRace.data.name == "Shek" then
		return ChildSliderValues_Shek
	else
		return ChildSliderValues
	end
end

local function RemoveFinalSliderValues(Child)
	local AppDataBase = Child:getAppearance()
	local fdata = AppDataBase.appearanceData.fdata
	
	local SliderValues = GetChildSliderValues(Child)
	
	for k, v in pairs(SliderValues) do
		fdata:remove("WHENADULT_" .. k)
	end
	
	local Anatomy = Child.medical.anatomy
	for k, v in pairs(Anatomy) do
		fdata:remove("WHENADULT_LIMB_" .. k)
		fdata:remove("WHENCHILD_LIMB_" .. k)
	end
	
	AppDataBase.appearanceData.fdata = fdata
end

local function CopyFinalSliderValuesAndSetSliders(Mother, Father, Child)
	local AppDataBase = Child:getAppearance()
	local fdata = AppDataBase.appearanceData.fdata
	
	local ChildAnatomy = Child.medical.anatomy
	local MotherAnatomy = Mother.medical.anatomy
	local FatherAnatomy = Father.medical.anatomy
	
	local HealthWhenAdult
	local HealthNow
	
	for k, v in pairs(ChildAnatomy) do		
		HealthWhenAdult = (MotherAnatomy[k]._maxHealth + FatherAnatomy[k]._maxHealth) / 2
		HealthNow = HealthWhenAdult * CHILD_HEALTH_MULT
		fdata["WHENADULT_LIMB_" .. k] = HealthWhenAdult
		fdata["WHENCHILD_LIMB_" .. k] = HealthNow
		ChildAnatomy[k]._maxHealth = HealthNow
		ChildAnatomy[k].flesh = HealthNow
	end
	
	Child.medical.anatomy = ChildAnatomy
	
	local SliderValues = GetChildSliderValues(Child)
	
	for k, v in pairs(SliderValues) do
		if fdata[k] then
			fdata["WHENADULT_" .. k] = fdata[k]
		end
		fdata[k] = v
	end
	
	AppDataBase.appearanceData.fdata = fdata
end


--return true if still growing
local function GrowCharacter(Character)
	local AppDataBase = Character:getAppearance()
	local fdata = AppDataBase.appearanceData.fdata
	local idata = AppDataBase.appearanceData.idata
	local ComeOfAgeTime = fdata.ComeOfAgeTime or idata.ComeOfAgeTime
	
	if not ComeOfAgeTime then return false end
	
	local RemainingTimeAsChild = ComeOfAgeTime - GetCurrentTime()
	
	local Lerp = 1.0 - (RemainingTimeAsChild / TOTAL_CHILDHOOD_TIME)
	Lerp = math.min(math.max(Lerp, 0.0), 1.0) 
	
	local Anatomy = Character.medical.anatomy
	local MaxHealth
	local FleshRatio
	
	for K, Limb in pairs(Anatomy) do
		FleshRatio = Anatomy[K].flesh / Anatomy[K]._maxHealth
		MaxHealth = LerpFloat(fdata["WHENCHILD_LIMB_" .. K], fdata["WHENADULT_LIMB_" .. K], Lerp)
		Anatomy[K]._maxHealth = MaxHealth
		Anatomy[K].flesh = MaxHealth * FleshRatio
	end
	
	Character.medical.anatomy = Anatomy
	
	local SliderValues = GetChildSliderValues(Character)
	
	local FinalVal
	for k, ChildVal in pairs(SliderValues) do
		FinalVal = fdata["WHENADULT_" .. k]
		
		if FinalVal then		
			fdata[k] = LerpFloat(ChildVal, FinalVal, Lerp)
		end
	end

	AppDataBase.appearanceData.fdata = fdata
	
	if RemainingTimeAsChild <= 0 then
		AppDataBase.appearanceData.idata:remove("ComeOfAgeTime")
		AppDataBase.appearanceData.fdata:remove("ComeOfAgeTime")
		RemoveFinalSliderValues(Character)
	end
	
	AppDataBase.updatedAppearanceData = true
	return true
end



local function MixAppearances(M, F, C)
	local FValues_M = M.appearanceData.fdata
	local FValues_F = F.appearanceData.fdata
	local FValues_C = C.appearanceData.fdata
	
	local SkinColour_M = M.appearanceData.vecdata["Skin Tone"]
	local SkinColour_F = F.appearanceData.vecdata["Skin Tone"]
	local SkinColour_C = C.appearanceData.vecdata["Skin Tone"]

	-- 25% probabilidad de heredar el tono exacto de la madre, 25% del padre, 50% mezcla intermedia
	local roll = math.random()
	local LerpVal = (roll < 0.25) and 0.0 or ((roll < 0.50) and 1.0 or math.random())

	SkinColour_C.x = LerpFloat(SkinColour_M.x, SkinColour_F.x, LerpVal)
	SkinColour_C.y = LerpFloat(SkinColour_M.y, SkinColour_F.y, LerpVal)
	SkinColour_C.z = LerpFloat(SkinColour_M.z, SkinColour_F.z, LerpVal)

	C.appearanceData.vecdata["Skin Tone"] = SkinColour_C	
	
	local Value_M, Value_F
	
	for i, SliderKey in ipairs(AllSliderValues) do
		Value_M = FValues_M[SliderKey]
		Value_F = FValues_F[SliderKey]
		if Value_M or Value_F then
			FValues_C[SliderKey] = LerpFloat(
				Value_F or Value_M, 
				Value_M or Value_F, 
				math.random()
			)
		end
	end
	
	C.appearanceData.sdata.beard = ""
	C.appearanceData.fdata = FValues_C
end

local function MixStats(Mother, Father, Child)
	local Mstats = Mother.stats
	local Fstats = Father.stats
	local Cstats = Child.stats
	
	for i, v in ipairs(AllStats) do
		local sum = (Mstats[v] or 0) + (Fstats[v] or 0)
		if v == "_toughness" then
			Cstats[v] = sum / 6.0
		else
			Cstats[v] = sum / 5.0
		end
	end
end

local function SetParentsAndAge(Mother, Father, Child)
	local AppDataBase = Child:getAppearance()
	local idata = AppDataBase.appearanceData.idata
	
	AddFamilyDataToTable(Mother, Father, Child)
	AppDataBase.appearanceData.fdata.ComeOfAgeTime = GetCurrentTime() + TOTAL_CHILDHOOD_TIME
	
	AppDataBase.appearanceData.idata = idata
end

local function SetChildName(Mother, Father, Child, fallbackFatherName)
	local CurrentRandomName = Child:getName()
	local FatherName = Father and Father:getName() or fallbackFatherName
	if not FatherName then return end

	local FatherNameSpaceLocation = string.find(FatherName, " ")
	if FatherNameSpaceLocation then
		local FatherSurname = string.sub(FatherName, FatherNameSpaceLocation + 1, -1)
		Child:setName(CurrentRandomName .. " " .. FatherSurname)		
	end
end

local function FindFatherForBirth(Mother)
	local Father = FindFatherOfCurrentChild(Mother)
	if Father then return Father end

	local sdata = Mother:getAppearance().appearanceData.sdata
	local fatherID = sdata.Preg_FatherID
	local fatherName = sdata.Preg_FatherName

	if fatherID and IsValidCharacter(HAPPYFAMILIES_FamilyTable_StringToObject[fatherID]) then
		return HAPPYFAMILIES_FamilyTable_StringToObject[fatherID]
	end

	local playerObj = getPlayerInterface() or player
	if playerObj then
		local chars = playerObj:getAllPlayerCharacters()
		for _, char in pairs(chars) do
			if IsValidCharacter(char) then
				if fatherID and char.handle:toString() == fatherID then
					return char
				end
			end
		end
		-- Respaldo tras importar partida (donde los handles cambian)
		if fatherName then
			for _, char in pairs(chars) do
				if IsValidCharacter(char) and not char:isFemale() and char:getName() == fatherName then
					return char
				end
			end
		end
	end

	return nil
end

local function MakeChild(Mother, Father, fallbackFatherName, fallbackFatherRace, fallbackChildGenes)
	if not IsThereSpaceInSquad(Mother) then return end
	
	local AppearanceM = Mother:getAppearance()
	local AppearanceF = Father and Father:getAppearance() or AppearanceM
	
	local faction = Mother:getFaction()
	local factory = getRootObjectFactory()
	local squad = Mother:getPlatoon()

	local template
	if Father then
		template = SelectRaceTemplate(Mother, Father)
	else
		local raceName = (math.random() > 0.5)
			and Mother.myRace.data.name
			or (fallbackFatherRace or Mother.myRace.data.name)
		template = getGameWorld().gamedata:getDataByName("HF_Random" .. raceName, itemType.CHARACTER)
	end
	
	local Child = factory:createRandomCharacter(
		faction,
		Mother:getPosition(),
		squad,
		template or Mother:getGameData(),
		nil,
		0.5
	).handle:getCharacter()
	
	SetChildName(Mother, Father, Child, fallbackFatherName)
	
	local AppearanceC = Child:getAppearance()
	MixAppearances(AppearanceM, AppearanceF, AppearanceC)

	-- 1. Generar o restaurar genes híbridos
	local genesStr = ""
	if Father and HF_GenerateGenes then
		genesStr = HF_GenerateGenes(Mother, Father, Child) or ""
	elseif fallbackChildGenes and fallbackChildGenes ~= "" then
		genesStr = fallbackChildGenes
		if HF_SyncCharacter then
			HF_SyncCharacter(Child, false, genesStr)
		end
	end

	if genesStr ~= "" then
		local sdata = AppearanceC.appearanceData.sdata
		sdata.HF_Genes = genesStr
		AppearanceC.appearanceData.sdata = sdata
	end

	-- 2. Aplicar la apariencia base ANTES de escribir edad y sliders de crecimiento
	Child:setAppearanceData(AppearanceC.appearanceData)
	
	-- 3. Escribir familia, edad, sliders de crecimiento y stats
	if Father then
		SetParentsAndAge(Mother, Father, Child)
		CopyFinalSliderValuesAndSetSliders(Mother, Father, Child)
		MixStats(Mother, Father, Child)
	else
		local ChildString = Child.handle:toString()
		local MotherStringID = Mother.handle:toString()
		HAPPYFAMILIES_FamilyTable_StringToObject[ChildString] = Child
		local FamilyTable = GetOrAddFamilyTable(Child)
		FamilyTable.MotherStringID = MotherStringID
		FamilyTable.MotherName = Mother:getName()
		FamilyTable.FatherStringID = nil
		FamilyTable.FatherName = fallbackFatherName or MODSTRING_Unknown
		SaveFamilyDataFromTable(Child)

		local childApp = Child:getAppearance()
		childApp.appearanceData.fdata.ComeOfAgeTime = GetCurrentTime() + TOTAL_CHILDHOOD_TIME

		CopyFinalSliderValuesAndSetSliders(Mother, Mother, Child)
		MixStats(Mother, Mother, Child)
	end

	GrowCharacter(Child)
	return Child
end

local function ApplyPregnancyDebuffs(Mother, Lerp)
	local fdata = Mother:getAppearance().appearanceData.fdata
	local stats = Mother.stats

	-- Destreza: 0% a 50%
	local baseDex = stats._dexterity + (fdata.Preg_Debuff_Dex or 0)
	local debuffDex = baseDex * (0.50 * Lerp)
	stats._dexterity = math.max(0, baseDex - debuffDex)
	fdata.Preg_Debuff_Dex = debuffDex

	-- Sigilo: 0% a 50%
	local baseStealth = stats.stealth + (fdata.Preg_Debuff_Stealth or 0)
	local debuffStealth = baseStealth * (0.50 * Lerp)
	stats.stealth = math.max(0, baseStealth - debuffStealth)
	fdata.Preg_Debuff_Stealth = debuffStealth

	-- Resistencia (Toughness): 0% a 25%
	local baseTough = stats._toughness + (fdata.Preg_Debuff_Tough or 0)
	local debuffTough = baseTough * (0.25 * Lerp)
	stats._toughness = math.max(0, baseTough - debuffTough)
	fdata.Preg_Debuff_Tough = debuffTough
end

local function ClearPregnancyDebuffs(Mother)
	local AppDataBase = Mother:getAppearance()
	local fdata = AppDataBase.appearanceData.fdata
	local stats = Mother.stats

	if fdata.Preg_Debuff_Dex then
		stats._dexterity = stats._dexterity + fdata.Preg_Debuff_Dex
		fdata:remove("Preg_Debuff_Dex")
	end
	if fdata.Preg_Debuff_Stealth then
		stats.stealth = stats.stealth + fdata.Preg_Debuff_Stealth
		fdata:remove("Preg_Debuff_Stealth")
	end
	if fdata.Preg_Debuff_Tough then
		stats._toughness = stats._toughness + fdata.Preg_Debuff_Tough
		fdata:remove("Preg_Debuff_Tough")
	end

	LastPregnancyHunger[Mother.handle:toString()] = nil
	AppDataBase.appearanceData.fdata = fdata
end

local function IsStomachCriticallyDamaged(Mother)
	local anatomy = Mother.medical.anatomy
	for _, part in pairs(anatomy) do
		if part and part.data and string.lower(part.data.name) == "stomach" then
			if part.flesh < 0 then
				return true
			end
		end
	end
	return false
end

local function ProgressPregnancy(Mother)
	local AppDataBase = Mother:getAppearance()
	local AppData = AppDataBase.appearanceData
	
	if AppData.fdata.NextAllowedChildCheck 
	and AppData.fdata.NextAllowedChildCheck <= GetCurrentTime() then
		AppData.fdata:remove("NextAllowedChildCheck") 
		AppDataBase.appearanceData = AppData
		return
	end
	
	local PregnancyTimeRemaining = AppData.fdata.PregnancyEndTime
	if PregnancyTimeRemaining == nil then
		return false
	end
	
	PregnancyTimeRemaining = PregnancyTimeRemaining - GetCurrentTime()

	-- Pérdida del embarazo si el estómago baja de 0
	if IsStomachCriticallyDamaged(Mother) then
		AppData.fdata.Stomach = AppData.fdata.Stomach_Original
		AppData.fdata:remove("Stomach_Original")
		AppData.fdata:remove("PregnancyEndTime")
		AppData.bdata:remove("bJustSaidImPregnant")
		AppData.sdata:remove("Preg_FatherID")
		AppData.sdata:remove("Preg_FatherName")
		AppData.sdata:remove("Preg_FatherRace")
		AppData.sdata:remove("Preg_ChildGenes")
		AppDataBase.appearanceData = AppData

		local ft = GetOrAddFamilyTable(Mother)
		ft.FatherOfCurrentChild = nil
		ft.FatherOfCurrentChildID = nil
		ClearPregnancyDebuffs(Mother)
		Mother:say(MODSTRING_Miscarriage)
		return true
	end
	
	if PregnancyTimeRemaining <= 0 then 
		if not IsThereSpaceInSquad(Mother) then
			if bHappyFamiliesDebugMode then Mother:say("No space in squad") end
			return true
		end

		local Father = FindFatherForBirth(Mother)
		local savedFatherName = AppData.sdata.Preg_FatherName
		local savedFatherRace = AppData.sdata.Preg_FatherRace
		local savedChildGenes = AppData.sdata.Preg_ChildGenes

		AppData.fdata.Stomach = AppData.fdata.Stomach_Original
		AppData.fdata:remove("Stomach_Original")
		AppData.fdata:remove("PregnancyEndTime")
		AppData.bdata:remove("bJustSaidImPregnant")
		AppData.sdata:remove("Preg_FatherID")
		AppData.sdata:remove("Preg_FatherName")
		AppData.sdata:remove("Preg_FatherRace")
		AppData.sdata:remove("Preg_ChildGenes")
		AppDataBase.appearanceData = AppData

		local ft = GetOrAddFamilyTable(Mother)
		ft.FatherOfCurrentChild = nil
		ft.FatherOfCurrentChildID = nil
		ClearPregnancyDebuffs(Mother)

		MakeChild(Mother, Father, savedFatherName, savedFatherRace, savedChildGenes)
		return true
	else
		if bHappyFamiliesDebugMode then
			Mother:say(string.format("Time remaining: %.2f days (%.1f hrs)", PregnancyTimeRemaining, PregnancyTimeRemaining * 24))
		end
		
		if PregnancyTimeRemaining <= (TOTAL_PREGNANCY_TIME / 3.0) and not AppData.bdata.bJustSaidImPregnant then
			Mother:say(MODSTRING_ImPregnant)
			AppData.bdata.bJustSaidImPregnant = true
		end

		local Lerp = math.min(math.max(1.0 - (PregnancyTimeRemaining / TOTAL_PREGNANCY_TIME), 0.0), 1.0)
		AppData.fdata.Stomach = AppData.fdata.Stomach_Original + (Lerp * 200)

		ApplyPregnancyDebuffs(Mother, Lerp)

		AppDataBase.appearanceData = AppData
		return true
	end
end

local function MakePregnant(Mother, Father)
	local AppDataBase = Mother:getAppearance()
	local AppData = AppDataBase.appearanceData
	
	local fdata = AppData.fdata
	local sdata = AppData.sdata
	
	if fdata.PregnancyEndTime then return end
	
	fdata.Stomach_Original = AppData.fdata.Stomach
	fdata.PregnancyEndTime = GetCurrentTime() + TOTAL_PREGNANCY_TIME

	if Father and IsValidCharacter(Father) then
		sdata.Preg_FatherID = Father.handle:toString()
		sdata.Preg_FatherName = Father:getName()
		if Father.myRace and Father.myRace.data then
			sdata.Preg_FatherRace = Father.myRace.data.name
		end
		-- Pre-generar genes en sdata como respaldo si el padre muere o se importa la partida
		if HF_GenerateGenes then
			local preGenes = HF_GenerateGenes(Mother, Father, Mother)
			if preGenes and preGenes ~= "" then
				sdata.Preg_ChildGenes = preGenes
			end
			if HF_SyncCharacter then
				HF_SyncCharacter(Mother, true, sdata.HF_Genes or "NONE")
			end
		end
	end

	AppData.fdata = fdata
	AppData.sdata = sdata
	AppDataBase.appearanceData = AppData
	
	local ft = GetOrAddFamilyTable(Mother)
	ft.FatherOfCurrentChild = nil
	ft.FatherOfCurrentChildID = (Father and IsValidCharacter(Father)) and Father.handle:toString() or nil
end

local function CheckMotherAndFather(Mother, Father)
	if Father == Mother then return end
	if not IsValidCharacter(Father) then return end
	if Father:isFemale() then return end
	
	local bCantReproduce = CoupleCantReproduce(Mother, Father)
	
	if bCantReproduce then 
		if bHappyFamiliesDebugMode then Mother:say(bCantReproduce) end
		return 
	end
			
	if math.random() <= PREGNANCYCHANCE then
		if bHappyFamiliesDebugMode then Mother:say("Pregnancy Succeeded") end
		MakePregnant(Mother, Father)
	else
		if bHappyFamiliesDebugMode then Mother:say("Pregnancy Failed") end
		local AppDataBase = Mother:getAppearance()
		local Time = math_randomrange(
			TIMEBETWEENPREGNANCIES_MIN,
			TIMEBETWEENPREGNANCIES_MAX
		)
		
		AppDataBase.appearanceData.fdata.NextAllowedChildCheck = GetCurrentTime() + Time
	end
end

local function IsBed(Building)
	if not Building then return false end
	return Building:getSpecialFunction() == BuildingFunction.BF_BED
end

local function CheckMother(Character)
	if GrowCharacter(Character) then return end
	if not Character:isFemale() then return end
	
	if ProgressPregnancy(Character) then return end
	
	if Character:isLiterallyUnconciousNotPretending() then return end
	
	local handInsideThis = Character.inWhat
	if not handInsideThis then return end
	local InsideBuilding = handInsideThis:getBuilding()
	
	if InsideBuilding then
		if not IsBed(InsideBuilding) then return end

		local UseableStuff = InsideBuilding:getUseableStuff()
		if not UseableStuff then return end
		
		local handOperators = UseableStuff.currentOperators

		for K in pairs(handOperators) do
			local Father = K and K:getCharacter() or nil
			if IsValidCharacter(Father) then
				CheckMotherAndFather(Character, Father)
			end
		end
	end
end

local function ChildrenPerCharacter_AddToParents(Character)
	local Father = FindFather(Character)
	local Mother = FindMother(Character)
	
	if Father then
		local FatherID = Father.handle:toString()
		
		if not ChildrenPerCharacter[FatherID] then
			ChildrenPerCharacter[FatherID] = {}
		end
		
		table_insert(ChildrenPerCharacter[FatherID], Character)
	end
	
	if Mother then
		local MotherID = Mother.handle:toString()
		
		if not ChildrenPerCharacter[MotherID] then
			ChildrenPerCharacter[MotherID] = {}
		end
		
		table_insert(ChildrenPerCharacter[MotherID], Character)
	end
end

function ChildrenPerCharacter_Get(Character)
	if not IsValidCharacter(Character) then return nil end
	local CharacterID = Character.handle:toString()
	return ChildrenPerCharacter[CharacterID]
end

--Kept for legacy reasons
function GetMother_OLD(Character)
	return GetCharacterFromID_OLD(Character:getAppearanceData().idata.MotherID)
end
function GetFather_OLD(Character)
	return GetCharacterFromID_OLD(Character:getAppearanceData().idata.FatherID)	
end
function GetCharacterFromID_OLD(CharacterInstanceID)
	if not CharacterInstanceID then return end
	
	local Characters = getPlayerInterface():getAllPlayerCharacters()
	for i, Char in pairs(Characters) do
		if IsValidCharacter(Char) and Char:getAppearanceData().idata.CharacterID == CharacterInstanceID then
			return Char
		end
	end
end


local function UpdateCharacters()
	pcall(function()
		if not CheckAndResetOnReload() then return end

		counter = counter + 1

		if counter >= 40 then
			counter = 1
			
			local playerObj = getPlayerInterface() or player
			if not playerObj then return end
			local PlayerCharacters = playerObj:getAllPlayerCharacters()
			if not PlayerCharacters then return end
			
			-- Reconstruir cachés de sesión desde los personajes vivos actuales
			ChildrenPerCharacter = {}
			HAPPYFAMILIES_FamilyTable_StringToObject = {}
			HAPPYFAMILIES_FamilyTable_ObjectToTable = {}

			local LiveCharacters = {}
			for _, Character in pairs(PlayerCharacters) do
				if IsValidCharacter(Character) then
					HAPPYFAMILIES_FamilyTable_StringToObject[Character.handle:toString()] = Character
					table_insert(LiveCharacters, Character)
				end
			end
			
			for _, Character in ipairs(LiveCharacters) do
				if HF_SyncCharacter then
					local appData = Character:getAppearance().appearanceData
					local isPreg = (appData.fdata.PregnancyEndTime ~= nil)
					local genesStr = appData.sdata.HF_Genes or ""
					HF_SyncCharacter(Character, isPreg, genesStr)
				end
				if Character:isHuman() then
					UpdateMotherAndFatherName(Character)
					CheckMother(Character)
					ChildrenPerCharacter_AddToParents(Character)
				end
			end
		end
	end)
end

local handlerId = Events.on("GameWorld::charsUpdate", UpdateCharacters)


function GetFamilyTable(Character)
	if not IsValidCharacter(Character) then return nil end
	
	local CharacterStringID = Character.handle:toString()
	local FamilyTable = HAPPYFAMILIES_FamilyTable_ObjectToTable[CharacterStringID]
	
	if not FamilyTable then
		FamilyTable = LoadAllFamilyDataFromString_Character(Character)
		HAPPYFAMILIES_FamilyTable_ObjectToTable[CharacterStringID] = FamilyTable
		HAPPYFAMILIES_FamilyTable_StringToObject[CharacterStringID] = Character
	end
	
	return FamilyTable
end

function GetOrAddFamilyTable(Character)
	if not IsValidCharacter(Character) then return nil end
	local CharacterStringID = Character.handle:toString()
	local FamilyTable = HAPPYFAMILIES_FamilyTable_ObjectToTable[CharacterStringID]
	
	if not FamilyTable then
		FamilyTable = LoadAllFamilyDataFromString_Character(Character)
		HAPPYFAMILIES_FamilyTable_ObjectToTable[CharacterStringID] = FamilyTable
	end
	
	if not FamilyTable then
		FamilyTable = {}
		HAPPYFAMILIES_FamilyTable_ObjectToTable[CharacterStringID] = FamilyTable
	end
	
	HAPPYFAMILIES_FamilyTable_StringToObject[CharacterStringID] = Character
	return FamilyTable
end


local function GetSaveFilePath(bTemp)
	local Singleton = SaveManager.getSingleton()
	local FileName 
	if bTemp then 
		FileName = "\\HappyFamilies_FamilyData_TEMP.txt"
	else
		FileName = "\\HappyFamilies_FamilyData.txt"
	end
	return Singleton:getSavePath() .. Singleton.name .. FileName
end

function AddFamilyDataToTable(Mother, Father, Child)
	local ChildString = Child.handle:toString()
	local MotherStringID = Mother.handle:toString()
	local FatherStringID = Father.handle:toString()
	
	HAPPYFAMILIES_FamilyTable_StringToObject[ChildString] = Child
	local FamilyTable = GetOrAddFamilyTable(Child)
	
	FamilyTable.MotherStringID = MotherStringID
	FamilyTable.MotherName = Mother:getName()
	
	FamilyTable.FatherStringID = FatherStringID
	FamilyTable.FatherName = Father:getName()
	
	SaveFamilyDataFromTable(Child)
end

function SaveFamilyDataFromTable(Character)
	local FamilyTable = GetFamilyTable(Character)
	if not FamilyTable then return Character.handle:toString() end
	
	local StringList = {
		Character.handle:toString(), --1
		FamilyTable.MotherName or "no", --2
		FamilyTable.MotherStringID or "no", --3
		FamilyTable.FatherName or "no", --4 
		FamilyTable.FatherStringID or "no" --5
	}
			
	local CurrentFather = FindFatherOfCurrentChild(Character)
	if CurrentFather then
		table_insert(StringList, CurrentFather.handle:toString())
	elseif FamilyTable.FatherOfCurrentChildID then
		table_insert(StringList, FamilyTable.FatherOfCurrentChildID)
	end
	
	local SerialisedString = table.concat(StringList, ";")
	Character:getAppearance().appearanceData.sdata.FamilyTable = SerialisedString
	print(SerialisedString)
	return SerialisedString
end

local function _Verify(String)
	if String == "no" then
		return nil
	else
		return String
	end
end

function LoadAllFamilyDataFromString_Character(Character)
	local SingleDataString = Character:getAppearance().appearanceData.sdata.FamilyTable
	return SingleDataString and LoadAllFamilyDataFromString_Single(SingleDataString)
end

function LoadAllFamilyDataFromString_Single(SingleDataString)
	local ThisCharacterStringTable = {}
	
	for Entry in string.gmatch(SingleDataString, "[^;]+") do
		table_insert(ThisCharacterStringTable, Entry)
	end
	
	local Table = {}
	
	if #ThisCharacterStringTable >= 5 then
		Table.MotherName = _Verify(ThisCharacterStringTable[2])
		Table.MotherStringID = _Verify(ThisCharacterStringTable[3])
		Table.FatherName = _Verify(ThisCharacterStringTable[4])
		Table.FatherStringID = _Verify(ThisCharacterStringTable[5])
		
		if ThisCharacterStringTable[6] then
			Table.FatherOfCurrentChildID = ThisCharacterStringTable[6]
			Table.FatherOfCurrentChild = nil
		end
		
		return Table
	end
	
	return nil
end

function LoadAllFamilyDataFromString(DataStrings)
	HAPPYFAMILIES_FamilyTable_StringToObject = {}
	
	local Characters = getPlayerInterface():getAllPlayerCharacters()
	for i, Char in pairs(Characters) do
		if IsValidCharacter(Char) then
			HAPPYFAMILIES_FamilyTable_StringToObject[Char.handle:toString()] = Char
			GetOrAddFamilyTable(Char)
		end
	end

	for i, Strings in pairs(DataStrings) do
		LoadAllFamilyDataFromString_Single(Strings)
	end	
end


local function LoadFamilyData(Player, GameData)
	local SaveFilePath = GetSaveFilePath()
	local File = io.open(SaveFilePath, "w")
	
	if not File then
        return nil
    end
	
    local Strings = {}

    for Line in File:lines() do
        table_insert(Strings, Line)
    end
	
	File:close()
	LoadAllFamilyDataFromString(Strings)
end

local function SaveFamilyData(Player, GameData)
	local SaveFilePath = GetSaveFilePath()
	local File = io.open(SaveFilePath, "w")
	
    if not File then
        return false
    end
	
	local Characters = getPlayerInterface():getAllPlayerCharacters()
	local StringPerChar
	
	for i, Char in pairs(Characters) do
		if IsValidCharacter(Char) then
			local ok, res = pcall(SaveFamilyDataFromTable, Char)
			if ok and res then
				File:write(res, "\n")
			end
		end
    end

    File:close()
    return true
end