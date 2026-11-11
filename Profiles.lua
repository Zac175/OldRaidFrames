--------------------------------------------------------------------------------
-- OldRaidFrames - profile manager
--
-- Named, account-wide profiles on top of AceDB-3.0: every character picks one
-- (default "Default", so alts inherit your layout the moment they log in),
-- plus copy / reset / delete, export & import strings, and direct in-game
-- profile sending over the addon channel.
--
--   /orf profile                      - profile window
--   /orf profile list                 - list profiles, marking the active one
--   /orf profile set <name>           - switch this character to <name>
--   /orf profile new <name>           - create a fresh (defaults) profile, use it
--   /orf profile copy <name>          - copy <name> over the active profile
--   /orf profile delete <name>        - delete a profile (not the active one)
--   /orf profile reset                - active profile back to defaults
--   /orf profile export               - export string in the profile window
--   /orf profile send <player|raid|party|guild> [profile]
--
-- Shape of the saved variable once profiles exist (AceDB standard):
--   OldRaidFramesDB = { profileKeys = { ["Name - Realm"] = "Default" },
--                       profiles    = { Default = { ...settings... } } }
-- A pre-profile (flat) OldRaidFramesDB is migrated into profiles.Default on
-- first load, so nobody loses their settings.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local P = {}
ns.Profiles = P

local PREFIX      = "OldRF"        -- addon message prefix
local EXPORT_TAG  = "!ORF1!"       -- human-visible marker on export strings
local CHUNK_SIZE  = 200            -- bytes of payload per addon message
local MAX_CHUNKS  = 80             -- refuse anything larger than ~16 KB
local XFER_TTL    = 30             -- seconds before a half-finished send expires

local AceDB, AceSerializer
local dbo                          -- AceDB database object
local panel                        -- profile window
local widgets = {}
local otherIndex = 1               -- selection in the "Other profile" cycler

local function Print(msg)
    if ns.Print then
        ns.Print(msg)
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffFFD100OldRaidFrames:|r " .. tostring(msg))
    end
end

--------------------------------------------------------------------------------
-- table helpers
--------------------------------------------------------------------------------

local function DeepCopy(src)
    local out = {}
    for k, v in pairs(src) do
        if type(v) == "table" then out[k] = DeepCopy(v) else out[k] = v end
    end
    return out
end

local function DeepFill(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            DeepFill(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

-- imported profiles can come from another player, so they are rebuilt key by
-- key against DEFAULTS: unknown keys dropped, wrong types replaced, enums and
-- numeric ranges validated. Nothing from the wire ever reaches SetPoint or a
-- slider unchecked.
local VALID_ENUM = {
    point = { CENTER = true, TOP = true, BOTTOM = true, LEFT = true, RIGHT = true,
              TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true },
    healthText     = { none = true, percent = true, value = true, lost = true },
    sortMode       = { group = true, name = true },
    buffFilter     = { mine = true, all = true },
    buffNameMode   = { off = true, block = true, only = true },
    debuffNameMode = { off = true, block = true, only = true },
    cdText         = { off = true, small = true, omnicc = true },
}

local VALID_RANGE = {
    x = { -4000, 4000 }, y = { -4000, 4000 },
    width = { 20, 200 }, height = { 20, 200 },
    frameGap = { 0, 20 }, groupGap = { 0, 20 },
    rows = { 1, 8 }, perColumn = { 1, 40 },
    buffSize = { 0, 30 }, debuffSize = { 0, 30 },
    _cfgVersion = { 0, 9999 },
}

local MAX_FILTER_NAMES = 200

local function SanitizeValue(key, value, default)
    local dt = type(default)
    if type(value) ~= dt then return default end
    if dt == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return default
        end
        local r = VALID_RANGE[key]
        if r then
            value = math.floor(value + 0.5)
            if value < r[1] then value = r[1] end
            if value > r[2] then value = r[2] end
        end
        return value
    elseif dt == "string" then
        local enum = VALID_ENUM[key]
        if enum and not enum[value] then return default end
        if #value > 64 then return default end
        return value
    end
    return value
end

local function Sanitize(src, template)
    local out = {}
    for key, default in pairs(template) do
        local value = src[key]
        if type(default) == "table" then
            if type(value) ~= "table" then
                out[key] = DeepCopy(default)
            elseif next(default) == nil then
                -- free-form name list: [lowercased spell name] = true
                local list, n = {}, 0
                for name, flag in pairs(value) do
                    if type(name) == "string" and flag == true
                        and #name > 0 and #name <= 64 and n < MAX_FILTER_NAMES then
                        list[name:lower()] = true
                        n = n + 1
                    end
                end
                out[key] = list
            else
                out[key] = Sanitize(value, default)
            end
        else
            out[key] = SanitizeValue(key, value, default)
        end
    end
    return out
end

local function CleanName(name)
    name = tostring(name or ""):gsub("[%c\t]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #name > 40 then name = name:sub(1, 40) end
    return name
end

--------------------------------------------------------------------------------
-- profile access
--------------------------------------------------------------------------------

function P.Ready()
    return dbo ~= nil
end

function P.Current()
    return dbo and dbo:GetCurrentProfile() or "Default"
end

function P.List()
    if not dbo then return {} end
    local list = dbo:GetProfiles()
    table.sort(list)
    return list
end

function P.Exists(name)
    if not dbo or type(name) ~= "string" then return false end
    if name == P.Current() then return true end
    return rawget(dbo.profiles, name) ~= nil
end

-- a full settings table for a profile (inactive profiles are stored with
-- default values stripped, so fill them back in before handing it out)
function P.GetProfileTable(name)
    if not dbo then return nil end
    if name == P.Current() then return dbo.profile end
    local t = rawget(dbo.profiles, name)
    if not t then return nil end
    local copy = DeepCopy(t)
    DeepFill(copy, ns.DEFAULTS)
    return copy
end

local function AfterProfileChange()
    if not dbo then return end
    ns.SetDB(dbo.profile)
    if ns.MigrateProfile then ns.MigrateProfile(dbo.profile) end
    if ns.ApplyAll then ns.ApplyAll() end
    P.Refresh()
end

function P.SetProfile(name)
    name = CleanName(name)
    if not dbo or name == "" then return false end
    if name == P.Current() then
        Print("already using profile \"" .. name .. "\".")
        return true
    end
    local existed = P.Exists(name)
    local ok, err = pcall(dbo.SetProfile, dbo, name)
    if not ok then
        Print("could not switch profile: " .. tostring(err))
        return false
    end
    Print((existed and "switched to profile \"%s\"." or "created and switched to profile \"%s\".")
        :format(name))
    return true
end

function P.CopyProfile(name)
    name = CleanName(name)
    if not dbo or name == "" then return false end
    if name == P.Current() then
        Print("that is already the active profile.")
        return false
    end
    if not P.Exists(name) then
        Print("no profile named \"" .. name .. "\".")
        return false
    end
    local ok, err = pcall(dbo.CopyProfile, dbo, name)
    if not ok then
        Print("could not copy: " .. tostring(err))
        return false
    end
    Print(("copied \"%s\" into \"%s\"."):format(name, P.Current()))
    return true
end

function P.DeleteProfile(name)
    name = CleanName(name)
    if not dbo or name == "" then return false end
    if name == P.Current() then
        Print("cannot delete the profile you are using — switch away first.")
        return false
    end
    if not P.Exists(name) then
        Print("no profile named \"" .. name .. "\".")
        return false
    end
    local ok, err = pcall(dbo.DeleteProfile, dbo, name, true)
    if not ok then
        Print("could not delete: " .. tostring(err))
        return false
    end
    Print("deleted profile \"" .. name .. "\".")
    P.Refresh()
    return true
end

function P.ResetProfile()
    if not dbo then return false end
    dbo:ResetProfile()
    Print("profile \"" .. P.Current() .. "\" reset to defaults.")
    return true
end

-- write a settings table into a profile, keeping the live table identity when
-- it is the one currently in use
function P.WriteProfile(name, data)
    if not dbo then return false end
    name = CleanName(name)
    if name == "" then return false end
    local clean = Sanitize(data, ns.DEFAULTS)
    if name == P.Current() then
        local prof = dbo.profile
        for k in pairs(prof) do prof[k] = nil end
        for k, v in pairs(clean) do prof[k] = v end
        AfterProfileChange()
    else
        dbo.profiles[name] = clean
        P.Refresh()
    end
    return true
end

local function UniqueName(base, suffix)
    local name = CleanName(base)
    if name == "" then name = "Imported" end
    if not P.Exists(name) then return name end
    if suffix and suffix ~= "" then
        local try = CleanName(name .. " (" .. suffix .. ")")
        if not P.Exists(try) then return try end
        name = try
    end
    for i = 2, 99 do
        local try = CleanName(name .. " " .. i)
        if not P.Exists(try) then return try end
    end
    return name .. " " .. time()
end

--------------------------------------------------------------------------------
-- export / import strings
--------------------------------------------------------------------------------

function P.Export(name)
    if not AceSerializer then return nil, "AceSerializer-3.0 is not loaded" end
    name = CleanName(name ~= nil and name or P.Current())
    local src = P.GetProfileTable(name)
    if not src then return nil, "no profile named \"" .. name .. "\"" end
    local payload = {
        addon   = "OldRaidFrames",
        version = ns.VERSION or "?",
        name    = name,
        data    = Sanitize(src, ns.DEFAULTS),
    }
    local ok, str = pcall(AceSerializer.Serialize, AceSerializer, payload)
    if not ok then return nil, "could not serialize the profile" end
    return EXPORT_TAG .. str
end

-- returns payload table, or nil + error
local function Decode(str)
    if not AceSerializer then return nil, "AceSerializer-3.0 is not loaded" end
    str = tostring(str or ""):gsub("%s+", "")
    if str == "" then return nil, "nothing to import" end
    str = str:gsub("^" .. EXPORT_TAG:gsub("%p", "%%%0"), "")
    local ok, payload = AceSerializer:Deserialize(str)
    if not ok or type(payload) ~= "table" then
        return nil, "that is not a valid OldRaidFrames profile string"
    end
    if payload.addon ~= "OldRaidFrames" or type(payload.data) ~= "table" then
        return nil, "that string is not an OldRaidFrames profile"
    end
    return payload
end

P.Decode = Decode

-- name: optional target profile name; use: switch to it afterwards
function P.Import(str, name, use)
    local payload, err = Decode(str)
    if not payload then
        Print(err)
        return false
    end
    local target = CleanName(name ~= nil and name or payload.name or "Imported")
    if target == "" then target = "Imported" end
    if name == nil then target = UniqueName(target) end
    P.WriteProfile(target, payload.data)
    Print(("imported profile \"%s\"%s."):format(target,
        payload.version and payload.version ~= (ns.VERSION or "?")
            and (" (made with version " .. tostring(payload.version) .. ")") or ""))
    if use and target ~= P.Current() then P.SetProfile(target) end
    P.Refresh()
    return true, target
end

--------------------------------------------------------------------------------
-- in-game sending (addon channel, chunked, receiver confirms)
--------------------------------------------------------------------------------

local comm = CreateFrame("Frame")
local incoming = {}   -- [sender] = { id, name, count, chunks, got, time }
local playerFull

local function RawSend(msg, channel, target)
    if ChatThrottleLib and ChatThrottleLib.SendAddonMessage then
        ChatThrottleLib:SendAddonMessage("BULK", PREFIX, msg, channel, target)
    elseif C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, msg, channel, target)
    elseif SendAddonMessage then
        SendAddonMessage(PREFIX, msg, channel, target)
    end
end

local function Chunk(str, size)
    local out = {}
    for i = 1, #str, size do out[#out + 1] = str:sub(i, i + size - 1) end
    return out
end

-- target: a player name, or "raid" / "party" / "guild"
function P.Send(target, profileName)
    if not dbo then return false end
    target = CleanName(target)
    if target == "" then
        Print("usage: /orf profile send <player | raid | party | guild> [profile]")
        return false
    end
    profileName = CleanName(profileName ~= nil and profileName or P.Current())
    if not P.Exists(profileName) then
        Print("no profile named \"" .. profileName .. "\".")
        return false
    end

    local str, err = P.Export(profileName)
    if not str then
        Print(err)
        return false
    end

    local channel, whisperTo
    local low = target:lower()
    if low == "raid" then
        if not IsInRaid() then Print("you are not in a raid.") return false end
        channel = "RAID"
    elseif low == "party" then
        if not IsInGroup() then Print("you are not in a party.") return false end
        channel = "PARTY"
    elseif low == "guild" then
        if not IsInGuild() then Print("you are not in a guild.") return false end
        channel = "GUILD"
    else
        channel, whisperTo = "WHISPER", target
    end

    local chunks = Chunk(str, CHUNK_SIZE)
    if #chunks > MAX_CHUNKS then
        Print("that profile is too large to send.")
        return false
    end

    local id = tostring(math.random(100000, 999999))
    RawSend(("H\t%s\t%s\t%d"):format(id, profileName, #chunks), channel, whisperTo)
    for i = 1, #chunks do
        RawSend(("D\t%s\t%d\t%s"):format(id, i, chunks[i]), channel, whisperTo)
    end
    RawSend(("E\t%s"):format(id), channel, whisperTo)

    Print(("sent profile \"%s\" to %s. They get a prompt to accept it.")
        :format(profileName, whisperTo or low))
    return true
end

StaticPopupDialogs["OLDRF_PROFILE_OFFER"] = {
    text = "%s",
    button1 = _G.ACCEPT or "Accept",
    button2 = _G.DECLINE or "Decline",
    button3 = "Accept & Use",
    OnAccept = function(self, data)
        if data then P.Import(data.str, UniqueName(data.name, data.sender), false) end
    end,
    OnAlt = function(self, data)
        if data then P.Import(data.str, UniqueName(data.name, data.sender), true) end
    end,
    timeout = 60,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function OfferReceived(sender, name, str)
    -- only ever a prompt: nothing is written until the player clicks Accept
    local payload = Decode(str)
    if not payload then return end
    local shortSender = sender:match("^([^-]+)") or sender
    StaticPopup_Show("OLDRF_PROFILE_OFFER",
        ("|cffFFD100OldRaidFrames|r\n\n%s sent you the raid frame profile \"%s\".\nAccept it?")
            :format(shortSender, CleanName(payload.name or name)),
        nil,
        { str = str, name = payload.name or name, sender = shortSender })
end

local function OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= PREFIX or not msg then return end
    if sender == playerFull or sender == UnitName("player") then return end

    local op, rest = msg:match("^(%a)\t(.*)$")
    if not op then return end
    local now = GetTime()

    -- drop stale transfers
    for who, t in pairs(incoming) do
        if now - t.time > XFER_TTL then incoming[who] = nil end
    end

    if op == "H" then
        local id, name, count = rest:match("^([^\t]+)\t([^\t]*)\t(%d+)$")
        count = tonumber(count)
        if not id or not count or count < 1 or count > MAX_CHUNKS then return end
        incoming[sender] = { id = id, name = CleanName(name), count = count,
                             chunks = {}, got = 0, time = now }
    elseif op == "D" then
        local id, idx, data = rest:match("^([^\t]+)\t(%d+)\t(.*)$")
        local t = incoming[sender]
        idx = tonumber(idx)
        if not t or t.id ~= id or not idx or idx < 1 or idx > t.count then return end
        if t.chunks[idx] == nil then
            t.chunks[idx] = data
            t.got = t.got + 1
        end
        t.time = now
    elseif op == "E" then
        local id = rest:match("^([^\t]+)$")
        local t = incoming[sender]
        incoming[sender] = nil
        if not t or t.id ~= id or t.got ~= t.count then return end
        OfferReceived(sender, t.name, table.concat(t.chunks, "", 1, t.count))
    end
end

comm:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then OnAddonMessage(...) end
end)

function P.InitComm()
    playerFull = (UnitName("player") or "") .. "-" .. ((GetRealmName() or ""):gsub("%s", ""))
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    elseif RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(PREFIX)
    end
    comm:RegisterEvent("CHAT_MSG_ADDON")
end

--------------------------------------------------------------------------------
-- init (called from OldRaidFrames.lua on ADDON_LOADED)
--------------------------------------------------------------------------------

-- returns the active profile table, or nil if AceDB is unavailable
function P.Init()
    AceDB        = LibStub and LibStub("AceDB-3.0", true)
    AceSerializer = LibStub and LibStub("AceSerializer-3.0", true)
    if not AceDB then
        Print("AceDB-3.0 is missing — profiles are disabled for this session.")
        return nil
    end

    -- migrate a pre-profile (flat) saved variable into profiles.Default
    local sv = _G.OldRaidFramesDB
    if type(sv) == "table" and sv.profiles == nil and sv.profileKeys == nil
        and next(sv) ~= nil then
        local old = {}
        for k, v in pairs(sv) do
            old[k] = v
            sv[k] = nil
        end
        sv.profiles = { Default = old }
        P.migrated = true
    end

    dbo = AceDB:New("OldRaidFramesDB", { profile = ns.DEFAULTS }, true)
    P.db = dbo

    local function changed() AfterProfileChange() end
    dbo.RegisterCallback(P, "OnProfileChanged", changed)
    dbo.RegisterCallback(P, "OnProfileCopied", changed)
    dbo.RegisterCallback(P, "OnProfileReset", changed)

    return dbo.profile
end

--------------------------------------------------------------------------------
-- profile window (same hand-built style as the options panel)
--------------------------------------------------------------------------------

local LIST_ROWS = 8

local function MakeOutline(parent, r, g, b, a)
    local t = {}
    local function edge(p1, p2, w, h)
        local tex = parent:CreateTexture(nil, "BORDER")
        tex:SetColorTexture(r, g, b, a)
        tex:SetPoint(p1)
        tex:SetPoint(p2)
        if w then tex:SetWidth(w) end
        if h then tex:SetHeight(h) end
        t[#t + 1] = tex
    end
    edge("TOPLEFT", "TOPRIGHT", nil, 1)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    return t
end

local function OtherProfiles()
    local out = {}
    local cur = P.Current()
    for _, name in ipairs(P.List()) do
        if name ~= cur then out[#out + 1] = name end
    end
    return out
end

local function SelectedOther()
    local list = OtherProfiles()
    if #list == 0 then return nil end
    if otherIndex > #list then otherIndex = 1 end
    return list[otherIndex], list
end

local function BuildPanel()
    if panel then return end

    local p = CreateFrame("Frame", "OldRF_Profiles", UIParent)
    panel = p
    p:SetSize(440, 520)
    p:SetPoint("CENTER", 120, 0)
    p:SetFrameStrata("DIALOG")
    p:SetToplevel(true)          -- clicking it lifts it clear of the options panel
    p:SetMovable(true)
    p:EnableMouse(true)
    p:SetClampedToScreen(true)
    p:SetScript("OnMouseDown", function(self) self:Raise() end)
    p:Hide()

    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    p.bg:SetColorTexture(0.05, 0.05, 0.08, 0.95)
    MakeOutline(p, 0.4, 0.4, 0.4, 1)

    local titleBar = CreateFrame("Button", nil, p)
    titleBar:SetPoint("TOPLEFT")
    titleBar:SetPoint("TOPRIGHT")
    titleBar:SetHeight(24)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnMouseDown", function() p:Raise() end)
    titleBar:SetScript("OnDragStart", function()
        p:Raise()
        p:StartMoving()
    end)
    titleBar:SetScript("OnDragStop", function()
        p:StopMovingOrSizing()
        p.userMoved = true       -- stop auto-parking it beside the options panel
    end)
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("CENTER")
    title:SetText("OldRaidFrames — Profiles")

    local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
    table.insert(UISpecialFrames, "OldRF_Profiles")

    -- active profile / character binding
    widgets.active = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    widgets.active:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -32)
    widgets.charLine = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    widgets.charLine:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -50)

    local listLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    listLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -70)
    listLabel:SetText("Profiles on this account (click to use on this character):")

    -- list rows
    widgets.rows = {}
    for i = 1, LIST_ROWS do
        local b = CreateFrame("Button", nil, p)
        b:SetSize(408, 18)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -88 - (i - 1) * 18)
        b:SetNormalFontObject(GameFontHighlightSmall)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        b:SetText(" ")
        local fs = b:GetFontString()
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", b, "LEFT", 6, 0)
        fs:SetPoint("RIGHT", b, "RIGHT", -6, 0)
        fs:SetJustifyH("LEFT")
        b:SetScript("OnClick", function(self)
            if self.profileName then P.SetProfile(self.profileName) end
        end)
        b:Hide()
        widgets.rows[i] = b
    end

    local pageY = -88 - LIST_ROWS * 18 - 2
    local prev = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    prev:SetSize(60, 18)
    prev:SetPoint("TOPLEFT", p, "TOPLEFT", 16, pageY)
    prev:SetText("< Prev")
    prev:SetScript("OnClick", function()
        widgets.page = math.max(1, (widgets.page or 1) - 1)
        P.Refresh()
    end)
    local next_ = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    next_:SetSize(60, 18)
    next_:SetPoint("TOPLEFT", p, "TOPLEFT", 80, pageY)
    next_:SetText("Next >")
    next_:SetScript("OnClick", function()
        widgets.page = (widgets.page or 1) + 1
        P.Refresh()
    end)
    widgets.pageText = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    widgets.pageText:SetPoint("LEFT", next_, "RIGHT", 8, 0)
    widgets.prev, widgets.next = prev, next_

    -- new profile
    local newY = pageY - 26
    local newLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    newLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 16, newY - 5)
    newLabel:SetText("New profile:")
    local newBox = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    newBox:SetSize(190, 20)
    newBox:SetPoint("TOPLEFT", p, "TOPLEFT", 106, newY)
    newBox:SetAutoFocus(false)
    newBox:SetMaxLetters(40)
    local function CreateNew()
        local name = CleanName(newBox:GetText())
        newBox:SetText("")
        newBox:ClearFocus()
        if name == "" then return end
        if P.Exists(name) then
            Print("a profile named \"" .. name .. "\" already exists — switching to it.")
        end
        P.SetProfile(name)
    end
    newBox:SetScript("OnEnterPressed", CreateNew)
    newBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local createBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    createBtn:SetSize(110, 22)
    createBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 306, newY - 1)
    createBtn:SetText("Create & Use")
    createBtn:SetScript("OnClick", CreateNew)

    -- other-profile selector + copy / delete
    local otherY = newY - 30
    local otherLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    otherLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 16, otherY - 5)
    otherLabel:SetText("Other profile:")
    local cycle = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    cycle:SetSize(190, 22)
    cycle:SetPoint("TOPLEFT", p, "TOPLEFT", 106, otherY)
    cycle:SetScript("OnClick", function()
        local list = OtherProfiles()
        if #list == 0 then return end
        otherIndex = otherIndex % #list + 1
        P.Refresh()
    end)
    widgets.cycle = cycle

    local copyBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    copyBtn:SetSize(60, 22)
    copyBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 306, otherY)
    copyBtn:SetText("Copy")
    copyBtn:SetScript("OnClick", function()
        local name = SelectedOther()
        if name then P.CopyProfile(name) end
    end)
    local delBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    delBtn:SetSize(60, 22)
    delBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 370, otherY)
    delBtn:SetText("Delete")
    delBtn:SetScript("OnClick", function()
        local name = SelectedOther()
        if name then P.DeleteProfile(name) end
    end)

    local resetY = otherY - 28
    local resetBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    resetBtn:SetSize(190, 22)
    resetBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 16, resetY)
    resetBtn:SetText("Reset active profile")
    resetBtn:SetScript("OnClick", function() P.ResetProfile() end)

    local optBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    optBtn:SetSize(190, 22)
    optBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 234, resetY)
    optBtn:SetText("Frame options (/orf)")
    optBtn:SetScript("OnClick", function()
        if ns.ToggleOptionsPanel then ns.ToggleOptionsPanel() end
    end)

    -- transfer string box
    local xferY = resetY - 32
    local xferLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    xferLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 16, xferY)
    xferLabel:SetText("Share string  (Export fills the box; paste one in and press Import)")

    local boxHolder = CreateFrame("Frame", nil, p)
    boxHolder:SetSize(408, 62)
    boxHolder:SetPoint("TOPLEFT", p, "TOPLEFT", 16, xferY - 16)
    local hbg = boxHolder:CreateTexture(nil, "BACKGROUND")
    hbg:SetAllPoints()
    hbg:SetColorTexture(0, 0, 0, 0.6)
    MakeOutline(boxHolder, 0.3, 0.3, 0.3, 1)

    local eb = CreateFrame("EditBox", nil, boxHolder)
    eb:SetPoint("TOPLEFT", 4, -4)
    eb:SetPoint("BOTTOMRIGHT", -4, 4)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(0)
    eb:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    widgets.xfer = eb

    local btnY = xferY - 82
    local exportBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    exportBtn:SetSize(130, 22)
    exportBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 16, btnY)
    exportBtn:SetText("Export active")
    exportBtn:SetScript("OnClick", function()
        local str, err = P.Export(P.Current())
        if not str then
            Print(err)
            return
        end
        eb:SetText(str)
        eb:SetFocus()
        eb:HighlightText()
        Print("export string ready — Ctrl+C to copy it.")
    end)

    local importBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    importBtn:SetSize(130, 22)
    importBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 154, btnY)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function()
        local text = eb:GetText()
        eb:ClearFocus()
        P.Import(text, nil, false)
    end)

    local clearBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    clearBtn:SetSize(130, 22)
    clearBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 292, btnY)
    clearBtn:SetText("Clear box")
    clearBtn:SetScript("OnClick", function()
        eb:SetText("")
        eb:ClearFocus()
    end)

    -- direct send
    local sendY = btnY - 30
    local sendLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sendLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 16, sendY - 5)
    sendLabel:SetText("Send active to:")
    local sendBox = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    sendBox:SetSize(160, 20)
    sendBox:SetPoint("TOPLEFT", p, "TOPLEFT", 122, sendY)
    sendBox:SetAutoFocus(false)
    sendBox:SetMaxLetters(40)
    local function DoSend()
        local who = CleanName(sendBox:GetText())
        sendBox:ClearFocus()
        if who == "" then
            Print("type a character name (or raid / party / guild) first.")
            return
        end
        P.Send(who, P.Current())
    end
    sendBox:SetScript("OnEnterPressed", DoSend)
    sendBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local sendBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    sendBtn:SetSize(80, 22)
    sendBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 292, sendY - 1)
    sendBtn:SetText("Send")
    sendBtn:SetScript("OnClick", DoSend)
    local raidBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    raidBtn:SetSize(50, 22)
    raidBtn:SetPoint("TOPLEFT", p, "TOPLEFT", 374, sendY - 1)
    raidBtn:SetText("Raid")
    raidBtn:SetScript("OnClick", function() P.Send("raid", P.Current()) end)

    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", p, "BOTTOM", 0, 8)
    hint:SetText("They get a prompt before anything is saved  --  /orf profile help")
end

function P.Refresh()
    if not panel or not panel:IsShown() then return end

    local cur = P.Current()
    widgets.active:SetText("Active profile: |cffFFD100" .. cur .. "|r")
    widgets.charLine:SetText(("This character (%s - %s) uses it; other characters keep their own choice.")
        :format(UnitName("player") or "?", GetRealmName() or "?"))

    local list = P.List()
    local pages = math.max(1, math.ceil(#list / LIST_ROWS))
    widgets.page = math.min(math.max(1, widgets.page or 1), pages)
    local offset = (widgets.page - 1) * LIST_ROWS

    for i = 1, LIST_ROWS do
        local row = widgets.rows[i]
        local name = list[offset + i]
        if name then
            row.profileName = name
            local users = 0
            if dbo and dbo.sv and dbo.sv.profileKeys then
                for _, key in pairs(dbo.sv.profileKeys) do
                    if key == name then users = users + 1 end
                end
            end
            local tag = (users > 0) and ("  |cff808080(" .. users .. " character"
                .. (users == 1 and "" or "s") .. ")|r") or ""
            if name == cur then
                row:SetText("|cffFFD100> " .. name .. "|r" .. tag)
            else
                row:SetText("   " .. name .. tag)
            end
            row:Show()
        else
            row.profileName = nil
            row:Hide()
        end
    end

    widgets.prev:SetShown(pages > 1)
    widgets.next:SetShown(pages > 1)
    widgets.pageText:SetText(pages > 1 and ("page " .. widgets.page .. " / " .. pages) or "")

    local other = SelectedOther()
    widgets.cycle:SetText(other or "(no other profile)")
    if other then widgets.cycle:Enable() else widgets.cycle:Disable() end
end

-- park the window beside the options panel (or centred if that is closed) so
-- the two never sit on top of each other, unless the player has dragged it
local function PlacePanel()
    if panel.userMoved then return end
    local opts = ns.OptionsPanel and ns.OptionsPanel()
    panel:ClearAllPoints()
    if opts and opts:IsShown() then
        -- to its right if there is room on screen, otherwise to its left
        local screenRight = UIParent:GetRight()
        local optsRight   = opts:GetRight()
        if screenRight and optsRight
            and (screenRight - optsRight) < (panel:GetWidth() + 12) then
            panel:SetPoint("TOPRIGHT", opts, "TOPLEFT", -8, 0)
        else
            panel:SetPoint("TOPLEFT", opts, "TOPRIGHT", 8, 0)
        end
    else
        panel:SetPoint("CENTER")
    end
end

local function ShowPanel()
    BuildPanel()
    PlacePanel()
    panel:Show()
    panel:Raise()
    P.Refresh()
end

function P.Toggle()
    if not dbo then
        Print("profiles are unavailable (AceDB-3.0 did not load).")
        return
    end
    BuildPanel()
    if panel:IsShown() then
        panel:Hide()
    else
        ShowPanel()
    end
end

--------------------------------------------------------------------------------
-- slash handling: "/orf profile <...>" (raw, un-lowercased, so profile names
-- keep their capitalisation)
--------------------------------------------------------------------------------

function P.Slash(rest)
    rest = tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local sub, arg = rest:match("^(%S*)%s*(.-)$")
    local low = (sub or ""):lower()

    if low == "" then
        P.Toggle()
        return
    end

    if not dbo then
        Print("profiles are unavailable (AceDB-3.0 did not load).")
        return
    end

    if low == "list" then
        local cur = P.Current()
        Print("profiles:")
        for _, name in ipairs(P.List()) do
            Print((name == cur and "  |cffFFD100> %s|r (active)" or "    %s"):format(name))
        end
    elseif low == "set" or low == "use" or low == "switch" then
        if arg == "" then Print("usage: /orf profile set <name>") else P.SetProfile(arg) end
    elseif low == "new" or low == "create" then
        if arg == "" then
            Print("usage: /orf profile new <name>")
        elseif P.Exists(arg) then
            Print("a profile named \"" .. arg .. "\" already exists.")
        else
            P.SetProfile(arg)
        end
    elseif low == "copy" then
        if arg == "" then Print("usage: /orf profile copy <name>") else P.CopyProfile(arg) end
    elseif low == "delete" or low == "del" then
        if arg == "" then Print("usage: /orf profile delete <name>") else P.DeleteProfile(arg) end
    elseif low == "reset" then
        P.ResetProfile()
    elseif low == "export" then
        local str, err = P.Export(arg ~= "" and arg or nil)
        if not str then
            Print(err)
        else
            ShowPanel()
            widgets.xfer:SetText(str)
            widgets.xfer:SetFocus()
            widgets.xfer:HighlightText()
            Print("export string ready in the profile window — Ctrl+C to copy it.")
        end
    elseif low == "import" then
        ShowPanel()
        widgets.xfer:SetText("")
        widgets.xfer:SetFocus()
        Print("paste the string into the box in the profile window, then press Import.")
    elseif low == "send" then
        local who, which = arg:match("^(%S*)%s*(.-)$")
        P.Send(who, which ~= "" and which or nil)
    else
        Print("profile commands:")
        Print("  /orf profile                 - open the profile window")
        Print("  /orf profile list            - list profiles")
        Print("  /orf profile set <name>      - use <name> on this character")
        Print("  /orf profile new <name>      - fresh profile from defaults, and use it")
        Print("  /orf profile copy <name>     - copy <name> over the active profile")
        Print("  /orf profile delete <name>   - delete a profile")
        Print("  /orf profile reset           - active profile back to defaults")
        Print("  /orf profile export|import   - share strings (profile window)")
        Print("  /orf profile send <player|raid|party|guild> [profile]")
    end
end
