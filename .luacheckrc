std = "lua51"
max_line_length = false
codes = true
exclude_files = { ".release/", "Libs/" }
unused_args = false -- event handlers receive many arguments they don't need
ignore = {
    "211/_.*", -- unused locals starting with _
    "421",     -- shadowing a local (loop variables like d, n, q)
    "431",     -- shadowing an upvalue
    "432",     -- shadowing an upvalue argument
}

globals = {
    "WorldCodexDB", "ItemsDB", "MobLootDB", "WorldCodexAPI", "WorldCodex_CommunityData",
    "SLASH_WORLDCODEX1", "SLASH_WORLDCODEX2", "SlashCmdList", "UISpecialFrames",
    "BINDING_HEADER_WORLDCODEX", "BINDING_NAME_WORLDCODEX_HOVER",
}

read_globals = {
    -- Lua / WoW Lua extensions
    "bit", "date", "time", "debugprofilestop", "debugstack", "InCombatLockdown", "geterrorhandler", "hooksecurefunc",
    "issecretvalue", "C_Secrets", "C_RestrictedActions", "C_TooltipInfo", "UNKNOWNOBJECT", "UNKNOWN",
    -- frames & UI
    "CreateFrame", "UIParent", "Minimap", "GameTooltip", "GameTooltipTextLeft1", "ItemRefTooltip",
    "ShoppingTooltip1", "ShoppingTooltip2", "WorldMapFrame", "WorldMapButton", "WorldMapDetailFrame",
    "DEFAULT_CHAT_FRAME", "ChatFontNormal", "BackdropTemplateMixin", "ChatEdit_InsertLink", "SetItemRef",
    "Settings", "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory", "TooltipDataProcessor",
    "GetCursorPosition", "PlaySound", "IsShiftKeyDown", "GetCoinTextureString", "ITEM_QUALITY_COLORS",
    "IsAltKeyDown", "GetBindingKey", "HandleModifiedItemClick", "TooltipUtil", "OpenWorldMap", "ToggleWorldMap",
    "GetItemIcon", "CreateFont", "C_XMLUtil", "SetPortraitToTexture", "PanelTemplates_TabResize",
    "PanelTemplates_SelectTab", "PanelTemplates_DeselectTab", "C_Texture", "SPELLBOOK_FONT_COLOR",
    "SetPortraitTextureFromCreatureDisplayID",
    -- game state
    "GetTime", "GetLocale", "GetMoney", "GetItemCount", "GetItemInfo", "GetSpellInfo", "GetNormalizedRealmName", "GetRealmName",
    "UnitReaction", "UnitPlayerControlled", "CheckInteractDistance", "SetPortraitTexture", "UnitFactionGroup",
    "UnitGUID", "UnitName", "UnitCreatureType", "IsInInstance", "GetInstanceInfo", "GetRealZoneText", "UnitLevel", "UnitIsDead", "UnitCanAttack", "UnitThreatSituation", "UnitIsUnit", "UnitIsPlayer", "UnitClassification", "UnitIsTapDenied", "UnitIsTapped", "UnitIsTappedByPlayer",
    "IsInGroup", "IsInRaid", "IsInGuild", "GetNumPartyMembers", "GetNumRaidMembers",
    "CombatLogGetCurrentEventInfo", "GetPlayerFacing", "GetPlayerMapPosition", "GetCurrentMapAreaID", "GetMapNameByID",
    "GetNumLootItems", "GetLootSlotLink", "GetLootSlotInfo", "GetLootSourceInfo", "GetLootSlotType", "CanLootUnit",
    "GOLD_AMOUNT", "SILVER_AMOUNT", "COPPER_AMOUNT", "LOOT_SLOT_MONEY",
    "GetContainerNumSlots", "GetContainerItemID", "GetContainerItemLink",
    "UpdateAddOnMemoryUsage", "GetAddOnMemoryUsage", "GetNumAddOns", "GetAddOnInfo", "IsAddOnLoaded",
    "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE",
    -- quests
    "GetQuestID", "GetTitleText", "GetNumQuestRewards", "GetNumQuestChoices", "GetQuestItemLink", "GetQuestItemInfo",
    "QuestIsDaily", "QuestIsWeekly", "IsQuestFlaggedCompleted", "C_QuestLog",
    "GetNumQuestItems",
    -- item details (Items.lua)
    "GetItemInfoInstant", "GetItemSpell", "GetInventoryItemLink", "GetInventoryItemID", "DAMAGE_TEMPLATE", "DAMAGE_TEMPLATE_WITH_SCHOOL",
    "SINGLE_DAMAGE_TEMPLATE", "DURABILITY_TEMPLATE", "SPEED",
    -- merchants and professions
    "C_MerchantFrame", "GetMerchantNumItems", "GetMerchantItemInfo", "GetMerchantItemLink",
    "GetMerchantItemCostInfo", "GetMerchantItemCostItem",
    "GetTradeSkillLine", "GetNumTradeSkills", "GetTradeSkillInfo", "GetTradeSkillItemLink", "GetTradeSkillRecipeLink",
    "GetTradeSkillNumMade", "GetTradeSkillNumReagents", "GetTradeSkillReagentInfo", "GetTradeSkillReagentItemLink",
    "GetCraftDisplaySkillLine", "GetNumCrafts", "GetCraftInfo", "GetCraftItemLink", "GetCraftRecipeLink",
    "GetCraftNumReagents", "GetCraftReagentInfo", "GetCraftReagentItemLink",
    "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
    -- trainers (Trainers.lua)
    "C_Trainer", "GetNumTrainerServices", "GetTrainerServiceInfo", "GetTrainerServiceCost", "GetTrainerServiceSkillReq",
    "GetTrainerServiceSkillLine", "GetTrainerServiceItemLink", "GetTrainerServiceTypeFilter",
    "SetTrainerServiceTypeFilter", "IsTradeskillTrainer", "UnitClass", "LocalizedClassList",
    "LOCALIZED_CLASS_NAMES_MALE", "LOCALIZED_CLASS_NAMES_FEMALE",
    -- namespaces
    "C_AddOns", "C_AuctionHouse", "C_ChatInfo", "C_Container", "C_CurrencyInfo", "C_EncodingUtil", "C_Item", "C_Map", "C_Spell", "C_SuperTrack", "C_TradeSkillUI", "Enum",
    "CreateVector2D", "UiMapPoint", "BreakUpLargeNumbers",
    -- chat
    "RegisterAddonMessagePrefix", "SendAddonMessage",
    -- optional libraries / addons
    "LibStub", "ChatThrottleLib", "TomTom",
}

files["tests/"] = { std = "+luajit", globals = { "_G", "MobLootDB", "ItemsDB", "WorldCodexDB", "WorldCodex_CommunityData" }, read_globals = { "unpack" }, ignore = { "111", "112", "113", "121", "122", "143" } }
