local addonName, addon = ...
addon.cleu = CreateFrame("Frame")
addon.cleu:SetScript("OnEvent",function(self,event,...)
  return addon.ParseCombat(addon,...)
end)
addon.events = CreateFrame("Frame")
addon.OnEvents = function(self,event,...)
  return addon[event] and addon[event](addon,event,...)
end
addon.events:SetScript("OnEvent", addon.OnEvents)
addon.events:RegisterEvent("ADDON_LOADED")
addon.events:RegisterEvent("PLAYER_LOGIN")
addon.events:RegisterEvent("PLAYER_LOGOUT")
addon.pickpocketed = {}
addon.slots = {}

local After, Ticker, IsEventValid = C_Timer.After, C_Timer.NewTicker, C_EventUtils.IsEventValid
local _, ROGUE, PICKPOCKET, INTERVAL = nil, 4, 921, 0.5
local PPTEXTURE = C_Spell.GetSpellTexture(PICKPOCKET)
local MONEY_LABEL = string.format("%sSpoils:",CreateTextureMarkup(PPTEXTURE, 64, 64, 16, 16, 0, 1, 0, 1))
local VENDOR_LABEL = "%s("..CreateTextureMarkup("Interface/CURSOR/Pickup", 32, 32, 16, 16, 0, 1, 0, 1).."%s)"
local GPH_LABEL = string.format("%s%s",CreateTextureMarkup("Interface/Timer/Challenges-Logo", 256, 256, 16, 16, 0.2, 0.8, 0.2, 0.8),"GPH:")
local PICKED_LABEL = string.format("%sPicked:",CreateTextureMarkup(PPTEXTURE, 64, 64, 16, 16, 0, 1, 0, 1))
local ADDON_LABEL = CreateTextureMarkup(132320, 32, 32, 16, 16, 0, 1, 0, 1).."|cffffbe42"..addonName.."|r"..CreateTextureMarkup(133644, 32, 32, 16, 16, 0, 1, 0, 1)

local defaults = {
  money = 0,
  vendor = 0,
  loot = {},
}
local defaultsAccount = {
  pickable = {},
  notpickable = {},
  characters = {},
}

_, addon.playerClassId = UnitClassBase("player")
addon.playerGUID = UnitGUID("player")

local function wrapTuple(...)
  return {...}
end

local function table_count(t)
  local count = 0
  for k,v in pairs(t) do
    count = count + 1
  end
  return count
end

local function getGPH()
  if addon.lastPick and addon.firstPick then
    local now = GetServerTime()
    local sessionDuration = addon.lastPick[1] - addon.firstPick[1]
    local moneyGain = addon.lastPick[2] - addon.firstPick[2]
    local vendorGain = addon.lastPick[3] - addon.firstPick[3]
    local gphCoin, gphAll
    if not sessionDuration or sessionDuration <= 0 then
      return
    end
    if moneyGain > 0 then
      gphCoin = moneyGain*3600/sessionDuration
    end
    if moneyGain > 0 or vendorGain > 0 then
      gphAll = (moneyGain+vendorGain)*3600/sessionDuration
    end
    if now - addon.lastPick[1] < 300 then
      return gphCoin, gphAll
    end
  end
end

local function getPreviousSnapshot(field)
  local sorted = {}
  for k,v in pairs(Cutpurse_DB[addon.characterID]) do
    tinsert(k)
  end
  table.sort(sorted)
  if #sorted > 1 then
    return sorted[#sorted-1]
  end
end

-- History holds cumulative snapshots, should only ever increase
local function addToHistory(addition,amount)

  local dateKey = date("%Y-%m-%d",GetServerTime())
  if not addon.characterID then
    addon.characterID = string.format("%s-%s",(UnitNameUnmodified("player")),GetNormalizedRealmName())
  end
  Cutpurse_DB.characters[addon.characterID] = Cutpurse_DB.characters[addon.characterID] or {}
  local characterContainer = Cutpurse_DB.characters[addon.characterID]
  if characterContainer[dateKey] then
    characterContainer[dateKey][addition] = (characterContainer[dateKey][addition] or 0) + amount
  else
    characterContainer[dateKey] = {}
    characterContainer[dateKey][addition] = amount
  end

end

local timeFormatter = CreateFromMixins(SecondsFormatterMixin)
timeFormatter:Init(0,SecondsFormatter.Abbreviation.OneLetter,true,true)
timeFormatter:SetStripIntervalWhitespace(true)

local function formatDelta(delta)
  local timeStr = timeFormatter:Format(delta)
  local coloredCD
  if delta <= 180+30 then -- less than 3.5mins red
    coloredCD = RED_FONT_COLOR:WrapTextInColorCode(timeStr)
  elseif delta <= 480 then -- less than 8mins yellow
    coloredCD = YELLOW_FONT_COLOR:WrapTextInColorCode(timeStr)
  elseif delta <= 600 then -- Less than 10mins green
    coloredCD = GREEN_FONT_COLOR:WrapTextInColorCode(timeStr)
  else
    coloredCD = GRAY_FONT_COLOR:WrapTextInColorCode(_G.UNKNOWN)
  end
  return coloredCD
end

local function getNameplateIcon(nameplate)
  if not nameplate then return end
  if nameplate._icon then return nameplate._icon end
  local icon = CreateFrame("Frame", nil, nameplate)
  icon:SetSize(20,20)
  icon.texture = icon:CreateTexture(nil,"BORDER")
  icon.texture:SetAllPoints(icon)
  icon.texture:SetTexture(PPTEXTURE)
  icon.border = icon:CreateTexture(nil,"ARTWORK")
  --icon.border:SetAllPoints(icon)
  icon.border:SetPoint("TOPLEFT",icon,"TOPLEFT",-2,2)
  icon.border:SetPoint("BOTTOMRIGHT",icon,"BOTTOMRIGHT",2,-2)
  icon.border:SetTexture("Interface/SPELLBOOK/GuildSpellbooktabIconFrame")
  icon.border:Hide()
  icon.cooldown = CreateFrame("Cooldown",nil,icon,"CooldownFrameTemplate")
  icon.cooldown:SetHideCountdownNumbers(false)
  icon.cooldown:SetAllPoints(icon)
  icon:ClearAllPoints()
  icon:SetPoint("TOPRIGHT",nameplate,"BOTTOMLEFT",-5,-5)
  icon:Hide()
  return icon
end

local function updateNameplateIcon(icon,pickpocketTime)
  local now = GetServerTime()
  local delta = now - pickpocketTime
  local pickpocketRearm = pickpocketTime + 420
  if delta > 600 then
    icon.border:Hide()
    icon:Hide()
  else
    local duration = pickpocketRearm - now
    if duration > 0 and duration < 600 then
      icon.cooldown:SetCooldownDuration(duration)
    else
      icon.cooldown:Clear()
    end
    if delta <=180+30 then
      icon.border:SetVertexColor(0.9,0,0,1)
    elseif delta <= 480 then
      icon.border:SetVertexColor(0.9,0.9,0,1)
    elseif delta <= 600 then
      icon.border:SetVertexColor(0,0.9,0,1)
    end
    icon.border:Show()
    icon:Show()
  end
end

local function parseLootSources(slot)
  local sources = wrapTuple(GetLootSourceInfo(slot))
  for i=1,#sources,2 do
    local srcGUID, quantity = sources[i], sources[i+1]
    if addon.pickpocketed[srcGUID] then
      addon.events:RegisterEvent("LOOT_SLOT_CLEARED")
      addon.events:RegisterEvent("LOOT_CLOSED")
      return srcGUID, quantity
    end
  end
end

local function addToSpellTooltip(self,data)
  local self = self or GameTooltip
  local _, spell = self:GetSpell()
  if spell and spell == PICKPOCKET then
    local addition
    if Cutpurse_DBPC.money > 0 then
      addition = GetMoneyString(Cutpurse_DBPC.money)
    end
    if Cutpurse_DBPC.vendor > 0 then
      addition = string.format(VENDOR_LABEL,addition or "",GetMoneyString(Cutpurse_DBPC.vendor))
    end
    if addition then
      self:AddDoubleLine(MONEY_LABEL,addition)
      local gphCoin, gphAll = getGPH()
      if gphCoin or gphAll then
        local strCoin = gphCoin and GetMoneyString(gphCoin).."/H" or ""
        local strAll = gphAll and GetMoneyString(gphAll).."/H" or ""
        self:AddDoubleLine(GPH_LABEL,string.format("%s (%s)",strCoin,strAll))
      end
      self:Show()
    end
  end
end

local function updateTooltipGUIDTimer(self)
  local tooltip = self.tooltip
  local ttipLeft = self.ttipLeft
  if ttipLeft:GetText() ~= PICKED_LABEL then return end
  local ttipRight = self.ttipRight
  local _,unit = tooltip:GetUnit()
  local unitGUID = unit and UnitGUID(unit)
  local pickpocketed = addon.pickpocketed[unitGUID]
  if pickpocketed then
    local delta = GetServerTime()-pickpocketed
    if delta and delta > 0 then
      ttipRight:SetText(formatDelta(delta))
    end
  end
end

local function addToUnitTooltip(self,data)
  local self = self or GameTooltip
  local _, unit = self:GetUnit()
  local unitGUID = unit and UnitGUID(unit)
  if unit and UnitIsDead(unit) then
    if addon.pickpocketed[unitGUID] then
      addon.pickpocketed[unitGUID] = nil
    end
    return
  end
  local pickpocketed = addon.pickpocketed[unitGUID]
  if pickpocketed then
    local delta = GetServerTime()-pickpocketed
    if delta and delta > 0 then
      local newLine = self:NumLines()+1
      self:AddDoubleLine(PICKED_LABEL,formatDelta(delta))
      self:Show()
      local ttPickedLeft = _G[self:GetName().."TextLeft"..newLine]
      local ttPickedRight = _G[self:GetName().."TextRight"..newLine]
      self._ticker = self._ticker or Ticker(1.0, updateTooltipGUIDTimer)
      self._ticker.ttipRight = ttPickedRight
      self._ticker.ttipLeft = ttPickedLeft
      self._ticker.tooltip = self
    end
  end
end

local function processNameplate(nameplate)
  local unitToken = nameplate and nameplate.namePlateUnitToken
  local unitGUID = unitToken and UnitGUID(unitToken)
  local pickpocketTime = unitGUID and addon.pickpocketed[unitGUID]
  if pickpocketTime then
    nameplate._icon = nameplate._icon or getNameplateIcon(nameplate)
    updateNameplateIcon(nameplate._icon,pickpocketTime)
  elseif nameplate._icon then
    nameplate._icon:Hide()
  end
end

local function DoNameplates()
  local nameplates = C_NamePlate.GetNamePlates(false)
  for i=1,#nameplates do
    local nameplate = nameplates[i]
    if nameplate then
      processNameplate(nameplate)
    end
  end
end

function addon:Print(msg,useLabel)
  local chatFrame = SELECTED_CHAT_FRAME or DEFAULT_CHAT_FRAME
  if useLabel then
    msg = string.format("%s: %s",ADDON_LABEL,msg)
  end
  chatFrame:AddMessage(msg)
end

function addon:NAME_PLATE_UNIT_ADDED(_,...)
  local unit = ...
  local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
  if nameplate then
    processNameplate(nameplate)
  end
end

function addon:NAME_PLATE_UNIT_REMOVED(_,...)
  local unit = ...
end

function addon:ADDON_LOADED(_,...)
  if ... == addonName then
    if self.playerClassId ~= 4 then
      After(5,function()
        self:Print("You're not a Rogue Harry!. "..addonName.." Disabled ;)",true)
      end)
      C_AddOns.DisableAddOn(addonName,self.playerGUID)
      return
    end
    After(15,function()
      self:Print("/"..string.lower(addonName).." (for help)",true)
    end)
    Cutpurse_DBPC = Cutpurse_DBPC or CopyTable(defaults)
    for k,v in pairs(defaults) do
      if Cutpurse_DBPC[k] == nil then
        Cutpurse_DBPC[k] = v
      end
    end
    Cutpurse_DB = Cutpurse_DB or CopyTable(defaultsAccount)
    for k,v in pairs(defaultsAccount) do
      if Cutpurse_DB[k] == nil then
        Cutpurse_DB[k] = v
      end
    end
  end
end

function addon:PLAYER_LOGIN(_,...)
  addon.characterID = string.format("%s-%s",(UnitNameUnmodified("player")),GetNormalizedRealmName())
  if IsPlayerSpell(PICKPOCKET) then
    self.cleu:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    self.events:RegisterEvent("LOOT_READY")
    addon.events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    addon.events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    DoNameplates()
    if GameTooltip:HasScript("OnTooltipSetUnit") then
      GameTooltip:HookScript("OnTooltipSetUnit",addToUnitTooltip)
    end
    if GameTooltip:HasScript("OnTooltipSetSpell") then
      GameTooltip:HookScript("OnTooltipSetSpell",addToSpellTooltip)
    end
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
      TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit,addToUnitTooltip)
      TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell,addToSpellTooltip)
    end
  else
    if IsEventValid("LEARNED_SPELL_IN_TAB") then
      self.events:RegisterEvent("LEARNED_SPELL_IN_TAB")
    end
    if IsEventValid("LEARNED_SPELL_IN_SKILL_LINE") then
      self.events:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
    end
    return
  end
end

function addon:PLAYER_LOGOUT(_,...)

end

function addon:LEARNED_SPELL_IN_TAB(event,...)
  local spellID, spellIndex, spellGuildPerk = ...
  if spellID == PICKPOCKET then
    self.events:UnregisterEvent(event)
    self:PLAYER_LOGIN("PLAYER_LOGIN")
  end
end
addon.LEARNED_SPELL_IN_SKILL_LINE = addon.LEARNED_SPELL_IN_TAB

function addon:LOOT_READY(_,...)
  local autoLooting = ...
  local numLoot = GetNumLootItems()
  if numLoot == 0 then return end
  for slot = numLoot,1,-1 do
    local srcGUID, quantity = parseLootSources(slot)
    if srcGUID then
      addon.pickpocketed[srcGUID] = GetServerTime()
      local lootType = GetLootSlotType(slot)
      if lootType == LOOT_SLOT_ITEM then
        self.slots[slot] = {type="item",item=GetLootSlotLink(slot),amount=quantity,source=srcGUID}
      end
      if lootType == LOOT_SLOT_CURRENCY then
        local _,_,_, currency = GetLootSlotInfo(slot)
        self.slots[slot] = {type="currency",currency=currency,amount=quantity,source=srcGUID}
      end
      if lootType == LOOT_SLOT_MONEY then
        self.slots[slot] = {type="money",money="copper",amount=quantity,source=srcGUID}
      end
      -- auto loot regardless setting
      if not (autoLooting or (GetCVarBool("autoLootDefault") ~= IsModifiedClick("AUTOLOOTTOGGLE"))) then
        LootSlot(slot)
        ConfirmLootSlot(slot)
        local dialog = StaticPopup_FindVisible("LOOT_BIND")
        if dialog then _G[dialog:GetName().."Button1"]:Click() end
      end
    end
  end
end

function addon:LOOT_SLOT_CLEARED(_,...)
  local slot = ...
  local slotdata = self.slots[slot]
  if slotdata then
    local now = GetTime()
    local log_loot = not addon.lastslot or (addon.lastslot ~= slot)
    if not log_loot then
      if not addon.lastcleared or ((now - addon.lastcleared) > INTERVAL) then
        log_loot = true
      end
    end
    addon.lastslot = slot
    addon.lastcleared = now
    if log_loot then
      local lootType,loot,amount,source = slotdata.type, slotdata[slotdata.type], slotdata.amount, slotdata.source
      local now = GetServerTime()
      addon.pickpocketed[source] = now
      DoNameplates()
      if lootType == "money" then
        Cutpurse_DBPC.money = Cutpurse_DBPC.money + amount
        addToHistory("money",amount)
        local lootMsg = GetMoneyString(amount)
        RaidNotice_AddMessage(RaidBossEmoteFrame, lootMsg, ChatTypeInfo.SYSTEM, 4.0)
      end
      if lootType == "item" then
        local itemAsync = Item:CreateFromItemLink(loot)
        itemAsync:ContinueOnItemLoad(function()
          local _, _, _, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(itemAsync:GetItemID())
          Cutpurse_DBPC.vendor = Cutpurse_DBPC.vendor + (sellPrice * (amount or 1))
          addToHistory("vendor", sellPrice * (amount or 1))
          if Cutpurse_DBPC.loot[loot] then
            Cutpurse_DBPC.loot[loot] = Cutpurse_DBPC.loot[loot] + amount
          else
            Cutpurse_DBPC.loot[loot] = amount
          end
          local lootMsg = string.format("%s x%d",itemAsync:GetItemLink(),amount or 1)
          RaidNotice_AddMessage(RaidBossEmoteFrame, lootMsg, ChatTypeInfo.SYSTEM, 4.0)
        end)
      end
      if not addon.firstPick then
        addon.firstPick = {now,Cutpurse_DBPC.money,Cutpurse_DBPC.vendor}
      end
      addon.lastPick = {now,Cutpurse_DBPC.money,Cutpurse_DBPC.vendor}
    end
  end
end

function addon:LOOT_CLOSED(_,...)
  wipe(self.slots)
  self.events:UnregisterEvent("LOOT_SLOT_CLEARED")
end

function addon:UI_ERROR_MESSAGE(_,...)
  local msgID, msgSTR = ...
  if msgID == LE_GAME_ERR_ALREADY_PICKPOCKETED then
    local lastGUID = addon.previousGUID
    if lastGUID then
      local currentTime = addon.pickpocketed[lastGUID]
      local previousTime = addon.previousTime
      if currentTime > previousTime then
        addon.pickpocketed[lastGUID] = previousTime
      end
      addon.previousGUID = nil
      addon.previousTime = nil
    end
    self.events:UnregisterEvent("UI_ERROR_MESSAGE")
  end
end

function addon:ParseCombat(...)
  local timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, arg12, arg13, arg14, arg15, arg16, arg17, arg18, arg19, arg20, arg21, arg22, arg23, arg24  = CombatLogGetCurrentEventInfo()
  if addon.playerGUID ~= sourceGUID then return end
  local spellID = arg12
  if subevent == "SPELL_CAST_FAILED" and spellID == PICKPOCKET then
    local failType = arg15
    if failType == _G.SPELL_FAILED_TARGET_NO_POCKETS then
      local testUnit = UnitExists("target") and "target" or UnitExists("mouseover") and "mouseover" or false
      local testGUID = testUnit and UnitGUID(testUnit)
      if testGUID then
        local guidType,_,serverID,instanceID,zoneUID,ID,spawnUID = string.split("-",testGUID)
        local npcID, npcName = tonumber(ID), UnitName(testUnit)
        if not Cutpurse_DB[npcID] then -- trust pickable as it always has a destGUID
          Cutpurse_DB.notpickable[npcID] = npcName or _G.UNKNOWN
        end
      end
    end
  end
  if not destGUID then return end
  local guidType,_,serverID,instanceID,zoneUID,ID,spawnUID = string.split("-",destGUID)
  local npcID = tonumber(ID)
  if subevent == "UNIT_DIED" then
    if addon.pickpocketed[destGUID] then
      addon.pickpocketed[destGUID] = nil
    end
  end
  if subevent ~= "SPELL_CAST_SUCCESS" then return end
  if spellID ~= PICKPOCKET then return end
  if npcID then
    Cutpurse_DB.pickable[npcID] = destName or _G.UNKNOWN
  end
  self.events:RegisterEvent("UI_ERROR_MESSAGE")
  addon.previousTime = addon.pickpocketed[destGUID]
  if addon.previousTime then
    addon.previousGUID = destGUID
  else
    addon.previousGUID = nil
  end
  addon.pickpocketed[destGUID] = GetServerTime()
end

local addonNameU, addonNameL = addonName:upper(), addonName:lower()
SlashCmdList[addonNameU] = function(msg, input)
  local option = {}
  msg = (msg or ""):trim()
  msg = msg:lower()
  for token in msg:gmatch("(%S+)") do
    tinsert(option,token)
  end
  if (not msg) or (msg == "") or (msg == "?") then
    addon:Print("Commands",true)
    addon:Print("/"..addonNameL.." wipe||reset")
    addon:Print("    resets all data")
    addon:Print("/"..addonNameL.." report")
    addon:Print("    prints a spoils report")
    addon:Print("/"..addonNameL.." pick")
    addon:Print("    prints a list of pickable NPCs")
    addon:Print("/"..addonNameL.." nopick")
    addon:Print("    prints a list of NPCs without pockets")
    return
  end
  local cmd = option[1]
  if cmd == "report" then
    if table_count(Cutpurse_DBPC.loot) > 0 then
      addon:Print("Items",true)
      for item,amount in pairs(Cutpurse_DBPC.loot) do
        addon:Print(string.format("%s x %d",item,amount))
      end
    end
    if Cutpurse_DBPC.money > 0 then
      addon:Print("Coin",true)
      addon:Print(string.format("%s: %s",MONEY,GetMoneyString(Cutpurse_DBPC.money)))
    end
    if Cutpurse_DBPC.vendor > 0 then
      addon:Print("Vendor value",true)
      addon:Print(string.format(VENDOR_LABEL,MERCHANT,GetMoneyString(Cutpurse_DBPC.vendor)))
    end
  end
  if cmd == "reset" or cmd == "wipe" then
    Cutpurse_DBPC.loot = wipe(Cutpurse_DBPC.loot)
    Cutpurse_DBPC.money = 0
    Cutpurse_DBPC.vendor = 0
    addon:Print("All character data reset",true)
  end
  if cmd == "resetall" or cmd == "wipeall" then

  end
  if cmd == "pick" or cmd == "pockets" then
    addon:Print("Pickable NPCs (learned):",true)
    for k,v in pairs(Cutpurse_DB.pickable) do
      addon:Print(string.format("    %d %q",k,v))
    end
  end
  if cmd == "nopick" or cmd == "nopockets" then
    addon:Print("Not pickable NPCs (learned):",true)
    for k,v in pairs(Cutpurse_DB.notpickable) do
      addon:Print(string.format("    %d %q",k,v))
    end
  end
end
_G["SLASH_"..addonNameU.."1"] = "/"..addonNameL

--[[TODO
0  Maybe rename the addon to `Cutpurse`
1. Option to scrolling message or alert loot
2. Option to add last pickpocket time to mob tooltip/nameplate (maybe icon too?)
3. Option to add short summary to Pick Pocket Spell Tooltip (just session/total, maybe g/hour)
4. Detail Frame with breakdown of spoils
 - money / hour: counted from first pickpocket to last
 - daily
 - lifetime
5. Learn from pickpocketing by npcid to show indicator for pickpocket-able mobs
6. Compute GPH
]]