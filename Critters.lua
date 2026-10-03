--[[
=====================================================================================
 Critters  -  World of Warcraft: WRATH OF THE LICH KING  (patch 3.3.5a, build 12340)
=====================================================================================
 !! THIS IS A WotLK 3.3.5 ADDON (Interface: 30300). NOT Retail, NOT Classic Era, NOT Cata.
 !! For people AND AIs editing this file: only use APIs that exist in 3.3.5 / Lua 5.1.

 What it does
   Big animated crit popups (normal crit + the record crit that slides up above the Crit
   Streak), a permanent "best crit" number
   on screen, a Crit Streak counter (crits close to your all-time record in a row), an
   account-wide list of every hero's all-time best crit, and a custom font for the game's
   own combat text.

 Required .toc (the SavedVariables line must stay ACCOUNT-WIDE, not PerCharacter):
   ## Interface: 30300
   ## Title: Critters
   ## SavedVariables: CrittersDB, BigDamDB
   Critters.lua
 (folder name must be Critters; keep BigDamDB in the list once so old settings are imported)

 Saved data layout (all inside the single account-wide table CrittersDB)
   CrittersDB.<settings>                     options (sizes, fonts, colors, minAllTime ...)
   CrittersDB.heroes["Name-Realm"]           one entry per character:
       .name, .class                         (class token, used for class colors)
       .best.dmg / .best.heal                all-time best crit (only crits above minAllTime)
       .grp.dmg  / .grp.heal                 best crit since joining the current group
       each record = { amount, heal, spell, spellId, target, pct, bql, vali }
                                             (bql = made with the Essence of the Blood Queen buff,
                                              vali = heal made with Emerald Vigor / Twisted Nightmares)

 3.3.5 rules this file follows (keep following them)
   * COMBAT_LOG_EVENT_UNFILTERED passes its arguments directly to OnEvent
     (timestamp, subevent, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...).
     There is NO CombatLogGetCurrentEventInfo() in 3.3.5.
   * No C_* namespaces (no C_Timer, C_Map ...), no Texture:SetRotation, no
     FontString:SetWordWrap, no BackdropTemplate. Backdrops use frame:SetBackdrop() directly.
   * Text cannot be rotated, so tilted numbers are built from separate characters.
   * GetNumRaidMembers() / GetNumPartyMembers() (not IsInGroup / GetNumGroupMembers).
   * The game's own combat text font is DAMAGE_TEXT_FONT and only changes after a RELOG.
   * Slash commands: /critters  or  /crit
=====================================================================================
]]

local ADDON = ...
local WHITE = "Interface\\Buttons\\WHITE8X8"
local DEFAULT_FONT = "Fonts\\FRIZQT__.TTF"

-- ========= Look & feel (edit these) =========
local ACCENT              = { 0.95, 0.55, 0.10 }  -- window accent color
local RECORD_COLOR        = { 0.86, 0.32, 0.04 }  -- default record DAMAGE crit color
local RECORD_HEAL_COLOR   = { 0.25, 0.90, 0.40 }  -- default record HEAL crit color
local NORMAL_CRIT_COLOR   = { 1.00, 0.82, 0.15 }  -- default normal DAMAGE crit color
local CRIT_HEAL_COLOR     = { 0.45, 1.00, 0.55 }  -- default normal HEAL crit color
local FADE_TIME           = 1.8                   -- seconds the record takes to fade out

-- Tilt range in degrees. 180 = level, 150 = leans one way, 210 = leans the other way.
local RECORD_TILT_MIN, RECORD_TILT_MAX = 172, 188   -- the record crit above the streak only leans a little
local CRIT_TILT_MIN,   CRIT_TILT_MAX   = 165, 195

-- every number-size slider (normal crit, Crit Streak / record crit, permanent number) runs from
-- SIZE_MIN (slider 1) to SIZE_MAX (slider 10). The numbers are always DRAWN at the one fixed
-- size SIZE_MAX and the slider only sets the frame SCALE (size / SIZE_MAX), so a size change
-- never rebuilds fonts and the numbers stay sharp.
local SIZE_MIN, SIZE_MAX = 20, 30
local REF_SIZE = SIZE_MAX   -- the font size every popup number is really drawn at
local NORMAL_CRIT_SIZE    = 30    -- default normal crit font size
local STREAK_SIZE         = 30    -- default Crit Streak number size (its x1, x2 counter is 0.7 of this)
local NORMAL_CRIT_SPACING = 110   -- distance between normal crit slots (3 columns x 2 rows)
local CRIT_JITTER         = 12    -- how far a normal crit randomly wanders from its slot (pixels)

-- default screen positions (offset from screen center) of the two movable anchors
local CRIT_POS   = { 0, 50 }
local PERM_DMG_POS  = { -450, 150 }  -- default spots of the two permanent numbers (left of center)
local PERM_HEAL_POS = { -450, 90 }
local STREAK_POS = { 420, 120 }     -- default spot of the Crit Streak

local BUILTIN = {
  { name = "Friz Quadrata (default)", path = "Fonts\\FRIZQT__.TTF" },
  { name = "Arial Narrow",            path = "Fonts\\ARIALN.TTF" },
  { name = "Skurri",                  path = "Fonts\\skurri.ttf" },
  { name = "Morpheus",                path = "Fonts\\MORPHEUS.ttf" },
}

local DEFAULTS = {
  damageFont    = DEFAULT_FONT,   -- the GAME's own combat text font (needs a restart)
  recordFont    = DEFAULT_FONT,   -- font of the Crit Streak AND the record crit above it (this addon only)
  critFont      = DEFAULT_FONT,   -- normal crit popup font (this addon only)
  recordEnabled = true,
  recordHold    = 4,              -- seconds the record crit stays above the Crit Streak
  critPop       = true,
  critSize      = 23,             -- normal crit popup size (slider range 20-30)
  healCrits     = true,
  noBQL         = true,     -- new installs: crits made under the Blood Queen buff are not all-time records
  noValithria   = true,     -- new installs: heal crits made under Emerald Vigor / Twisted Nightmares are not all-time records
  critStyle     = "random",
  digitSpacing  = 80,   -- % of each character's natural width (slider shows 1-10 for 20-80)
  uiScale       = 1,    -- options window scale (slider shows 1-10 for 0.90-1.30)
  permMode      = "group",  -- permanent record: "group" / "always" / "never"
  permSize      = 27,       -- size of the permanent record numbers
  permSpacing   = 80,       -- space between the permanent number's digits (slider shows 1-10 for 20-80)
  permFont      = DEFAULT_FONT,
  permDmg       = true,     -- show a permanent number for damage crits
  permHeal      = true,     -- show a permanent number for heal crits
  streakEnabled  = true,      -- Crit Streak on/off
  streakSize     = STREAK_SIZE,
  streakStyle    = "smash",   -- how the streak first appears (same list as the record crit)
  streakHitStyle = "jolt",    -- "pop 2": how the streak pops on every close-to-record crit
}

-- SavedVariables declared in TOC
-- the addon used to be called BigDam: if an old BigDamDB exists (and no new data yet), take it over
if (not CrittersDB or next(CrittersDB) == nil) and type(BigDamDB) == "table" then
  CrittersDB = BigDamDB
end
BigDamDB = nil
CrittersDB = CrittersDB or {}

local FLAT = {
  bgFile = WHITE,
  edgeFile = WHITE,
  tile = false,
  tileSize = 0,
  edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

-- ========= Helpers =========
local function Msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffff8c1aCritters|r: " .. text)
end

local function Round(v, step)
  return math.floor(v / step + 0.5) * step
end

local function Rand(a, b)
  return a + math.random() * (b - a)
end

-- 1234567 -> "1,234,567"
local function FormatNumber(n)
  local s = string.format("%d", math.floor(n + 0.5))
  local rev = string.reverse(s)
  rev = string.gsub(rev, "(%d%d%d)", "%1,")
  s = string.reverse(rev)
  if string.sub(s, 1, 1) == "," then s = string.sub(s, 2) end
  return s
end

-- color for a popup kind ("record"/"crit") and heal/damage
local function GetColor(kind, heal)
  if kind == "perm" then   -- permanent numbers: own color, until picked it follows the record color
    if heal then return CrittersDB.permHealColor or GetColor("record", true) end
    return CrittersDB.permColor or GetColor("record", false)
  elseif kind == "record" then
    -- the record crit above the streak uses the Highest Crits colors (an older saved record color is the fallback)
    if heal then return CrittersDB.permHealColor or CrittersDB.recordHealColor or RECORD_HEAL_COLOR end
    return CrittersDB.permColor or CrittersDB.recordColor or RECORD_COLOR
  else
    if heal then return CrittersDB.critHealColor or CRIT_HEAL_COLOR end
    return CrittersDB.critColor or NORMAL_CRIT_COLOR
  end
end

-- Hidden FontString used to check that a font file really exists
local tester = UIParent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
tester:Hide()

local validCache = {}

local function IsValidFont(path)
  if type(path) ~= "string" then return false end
  local key = string.lower(path)
  local cached = validCache[key]
  if cached ~= nil then return cached end

  local ok = false
  if tester:SetFont(path, 12, "") then
    ok = true
  else
    local cur = tester:GetFont()
    ok = cur ~= nil and string.lower(cur) == key
  end
  validCache[key] = ok
  return ok
end

-- Declared here (not further down) so the popup code can use it too
local debugMode = false

-- One Font object per (font, size, flags). Popup characters get their size through
-- SetFontObject instead of re-calling FontString:SetFont on reused FontStrings, which
-- is what appeared to leave the size stuck.
local fontObjects = {}
local fontObjCount = 0

local function GetFontObject(path, size, flags)
  local key = string.lower(path) .. "|" .. string.format("%d", size) .. "|" .. flags
  local obj = fontObjects[key]
  if not obj then
    fontObjCount = fontObjCount + 1
    obj = CreateFont("CrittersFont" .. fontObjCount)
    obj:SetFont(path, size, flags)
    fontObjects[key] = obj
  end
  return obj
end

local RefreshPerm, PermLand   -- filled in by the permanent record code further down
local StreakSetPlacing        -- filled in by the Crit Streak code further down
local RefreshHeroSheet        -- filled in by the options window (the all-time list)

-- ========= Movable anchors (normal crits, permanent record, Crit Streak) =========
-- (the record crit has no anchor of its own: it is anchored to the Crit Streak)
local anchors = {}
local moveButtons = {}
local permMoving = false   -- the permanent anchors (damage + heal) are moved together

local function PermEnabled(kind)
  if kind == "dmg" then return CrittersDB.permDmg ~= false end
  return CrittersDB.permHeal ~= false
end

local function IsMoving(kind)
  if kind == "perm" then return permMoving end
  return anchors[kind]:IsShown()
end

local ANCHOR_SAMPLE = "12,345,678"
local AnchorDragTick   -- filled in further down (live re-layout while a mover is dragged)

-- Unlock shows a see-through box (with a sample number for the normal crit)
-- that you drag around; Lock hides it again.
local function MakeAnchor(kind, label, dbKey, pos, hasSample)
  local a = CreateFrame("Frame", "CrittersAnchor_" .. kind, UIParent)
  a:SetWidth(120)
  a:SetHeight(40)
  a:SetPoint("CENTER", UIParent, "CENTER", pos[1], pos[2])
  a:SetFrameStrata("DIALOG")
  -- no visible box: this invisible frame covers the number, so you can drag any part of it.
  -- A small square in the middle (like the close button of the options window) marks the spot.
  local handle = CreateFrame("Frame", nil, a)
  handle:SetWidth(14)
  handle:SetHeight(14)
  handle:SetPoint("CENTER", a, "CENTER", 0, 0)
  handle:SetFrameLevel(a:GetFrameLevel() + 5)
  handle:SetBackdrop(FLAT)
  handle:SetBackdropColor(ACCENT[1] * 0.5, ACCENT[2] * 0.5, ACCENT[3] * 0.5, 1)
  handle:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  a.handle = handle
  a:SetMovable(true)
  a:EnableMouse(true)
  a:SetClampedToScreen(true)
  a:RegisterForDrag("LeftButton")
  a:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(label, 1, 1, 1)
    GameTooltip:AddLine("Drag to move, then press Lock", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  a:SetScript("OnLeave", function() GameTooltip:Hide() end)
  a:Hide()

  if hasSample then
    a.sample = a:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    a.sample:SetPoint("CENTER", a, "CENTER", 0, 0)
  end

  a.dbKey = dbKey
  a.kind = kind
  a:SetScript("OnDragStart", function(self)
    self:StartMoving()
    self.lastAlign = nil
    self:SetScript("OnUpdate", function(s) if AnchorDragTick then AnchorDragTick(s) end end)
  end)
  a:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    self:StopMovingOrSizing()
    -- always saved as an offset of the box CENTER from the screen center, so the
    -- popups stay put even when the box changes size
    local cx, cy = self:GetCenter()
    local ux, uy = UIParent:GetCenter()
    if cx and ux then
      CrittersDB[self.dbKey] = { point = "CENTER", relPoint = "CENTER", x = cx - ux, y = cy - uy }
    end
  end)

  anchors[kind] = a
end

MakeAnchor("crit",   "Normal crit position", "critPos", CRIT_POS,   true)
MakeAnchor("permDmg",  "Permanent damage record position", "permDmgPos",  PERM_DMG_POS,  false)
MakeAnchor("permHeal", "Permanent heal record position",   "permHealPos", PERM_HEAL_POS, false)
MakeAnchor("streak", "Crit Streak position", "streakPos", STREAK_POS, false)

-- puts an anchor in the middle of the screen and saves that spot
local function CenterAnchor(key, yOffset)
  local a = anchors[key]
  if not a then return end
  a:ClearAllPoints()
  a:SetPoint("CENTER", UIParent, "CENTER", 0, yOffset or 0)
  CrittersDB[a.dbKey] = { point = "CENTER", relPoint = "CENTER", x = 0, y = yOffset or 0 }
end

-- sizes / colors the sample number inside the normal crit box
-- (the permanent numbers draw their own sample, see FillPerm)
local function PaintAnchor(kind)
  local a = anchors[kind]
  if not a or not a.sample then return end
  local font = CrittersDB.critFont
  if not IsValidFont(font) then font = DEFAULT_FONT end
  local size = CrittersDB.critSize or NORMAL_CRIT_SIZE
  a.sample:SetFontObject(GetFontObject(font, size, "THICKOUTLINE"))
  a.sample:SetText(ANCHOR_SAMPLE)
  local c = GetColor("crit", false)
  a.sample:SetTextColor(c[1], c[2], c[3])
  a:SetWidth(math.max(60, (a.sample:GetStringWidth() or size * 6) + 16))
  a:SetHeight(size * 1.3 + 8)
end

-- the Unlock button turns into Lock (and lights up) while its box is out
local function PaintMoveButton(kind)
  local b = moveButtons[kind]
  if not b then return end
  if IsMoving(kind) then
    b.label:SetText("Lock")
    b:SetBackdropColor(ACCENT[1] * 0.5, ACCENT[2] * 0.5, ACCENT[3] * 0.5, 1)
    b:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  else
    b.label:SetText("Unlock")
    b:SetBackdropColor(0.16, 0.16, 0.19, 1)
    b:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
  end
end

-- shows the damage / heal permanent anchors that are ticked (both when both are ticked)
local function ApplyPermAnchors()
  local any = false
  for _, k in ipairs({ "dmg", "heal" }) do
    local a = anchors[(k == "dmg") and "permDmg" or "permHeal"]
    if permMoving and PermEnabled(k) then
      a:Show()
      any = true
    else
      a:Hide()
    end
  end
  if permMoving and not any then permMoving = false end
  PaintMoveButton("perm")
  -- while the anchors are out the permanent numbers show a sample so you can see their size
  if RefreshPerm then RefreshPerm() end
end

local function SetMoveMode(kind, on)
  if kind == "perm" then
    if on and not PermEnabled("dmg") and not PermEnabled("heal") then
      Msg("tick Damage record and/or Heal record first.")
      return
    end
    permMoving = on and true or false
    ApplyPermAnchors()
    return
  end
  local a = anchors[kind]
  if on then
    PaintAnchor(kind)
    a:Show()
  else
    a:Hide()
  end
  if kind == "streak" and StreakSetPlacing then StreakSetPlacing(on) end   -- shows/hides the sample streak
  PaintMoveButton(kind)
end

-- If the tab a mover belongs to is closed (or the whole options window), the mover locks itself
-- after 5 seconds. Opening the tab again in time keeps it.
do
  local SECTION_OF = { crit = "crit", streak = "streak", perm = "permrec" }
  local closedFor, acc = {}, 0
  local watch = CreateFrame("Frame")
  watch:SetScript("OnUpdate", function(self, el)
    acc = acc + el
    if acc < 0.25 then return end
    local dt = acc
    acc = 0
    local win = CrittersOptions
    local winOpen = win and win:IsShown()
    for kind, key in pairs(SECTION_OF) do
      if anchors[kind == "perm" and "permDmg" or kind] and IsMoving(kind) then
        local tabOpen = winOpen and CrittersDB.sections and CrittersDB.sections[key]
        if tabOpen then
          closedFor[kind] = 0
        else
          closedFor[kind] = (closedFor[kind] or 0) + dt
          if closedFor[kind] >= 5 then
            closedFor[kind] = 0
            SetMoveMode(kind, false)
          end
        end
      else
        closedFor[kind] = 0
      end
    end
  end)
end

-- ========= Effect styles =========
-- WotLK 3.3.5 cannot rotate text, so every number is built from separate characters
-- placed along a leaned baseline (a staircase). That gives the tilt.

local POP_DEFAULTS = {
  popScale = 1, slam = 0.10, under = 1, settle = 0.10,
  shake = 0, rise = 0, fromX = 0, fromY = 0,
  bounce = 0, pulse = 0, pulseRate = 10,
  stagger = 0, digitDrop = 0,
  flash = false, hold = 0.5, fade = 0.5, delay = 0,
}

-- "random" must stay LAST in each list
local RECORD_STYLES = {
  { key = "smash",   name = "Smash", tip = "Starts huge, slams down and shakes.",     popScale = 2.6,  slam = 0.12, under = 0.92, settle = 0.12, shake = 10, flash = true },
  { key = "drop",    name = "Drop-in", tip = "Falls in from above with a bounce.",   popScale = 1.4,  slam = 0.20, under = 0.92, settle = 0.10, shake = 8,  fromY = 140, bounce = 0.07, flash = true },
  { key = "slide",   name = "Slide-in", tip = "Slides in from the left or right.",  popScale = 1.25, slam = 0.18, under = 0.95, settle = 0.10, shake = 6,  fromX = 260, randSide = true, flash = true },
  { key = "bounce",  name = "Bouncy", tip = "Grows from small and bounces.",    popScale = 0.3,  slam = 0.14, under = 1.25, settle = 0.10, bounce = 0.16, flash = true },
  { key = "cascade", name = "Cascade", tip = "The digits drop in one after another.",   popScale = 1.15, slam = 0.12, under = 0.95, settle = 0.10, shake = 4,  stagger = 0.05, digitDrop = 90, flash = true },
  { key = "beat",    name = "Heartbeat", tip = "Slams in, then pulses like a heartbeat.", popScale = 2.0,  slam = 0.12, under = 0.90, settle = 0.12, shake = 6,  pulse = 0.07, pulseRate = 14, flash = true },
  { key = "random",  name = "Random", tip = "A different effect every time." },
}

-- the record crit: slides up out of the Crit Streak (fromY is filled in by ShowRecord)
local RECORD_SLIDE = { popScale = 1.0, slam = 0.30, under = 1.0, settle = 0.08, flash = true }

local CRIT_STYLES = {
  { key = "pop",    name = "Pop", tip = "Pops up and drifts upward.",    popScale = 1.35, slam = 0.08, under = 0.97, settle = 0.10, rise = 25, hold = 0.5,  fade = 0.5 },
  { key = "drop",   name = "Drop", tip = "Drops in from above.",   popScale = 1.1,  slam = 0.14, under = 0.97, settle = 0.08, fromY = 45, rise = 10, hold = 0.5, fade = 0.5 },
  { key = "slide",  name = "Slide", tip = "Slides in from the left or right.",  popScale = 1.1,  slam = 0.14, under = 0.97, settle = 0.08, fromX = 70, randSide = true, rise = 10, hold = 0.5, fade = 0.5 },
  { key = "float",  name = "Float", tip = "Floats slowly upward.",  popScale = 1.0,  slam = 0.06, under = 1.0,  settle = 0.05, rise = 55, hold = 0.35, fade = 0.7 },
  { key = "random", name = "Random", tip = "A different effect every time." },
}

local function PickStyle(list, key)
  local style
  for _, s in ipairs(list) do
    if s.key == key then style = s break end
  end
  if not style then style = list[1] end
  if style.key == "random" then style = list[math.random(#list - 1)] end
  return style
end

local function BuildOpts(style, extra)
  local o = {}
  for k, v in pairs(POP_DEFAULTS) do o[k] = v end
  for k, v in pairs(style) do o[k] = v end
  for k, v in pairs(extra) do o[k] = v end
  if o.randSide and math.random() < 0.5 then o.fromX = -o.fromX end
  return o
end

-- ========= Popups =========
-- SIZE is the REAL font size of every character (SetFont with the chosen size).
-- The popup frame scale is only used for the arrive/bounce/pulse animation.
local pools = { record = {}, crit = {} }
local active = {}

-- ----- number alignment: which edge of the box the number grows from (automatic) -----
-- The fixed edge is where a full-size sample number ("12,345,678", the one the Unlock box
-- shows) begins/ends. A box in the left half of the screen keeps its left edge fixed (the
-- number grows right), one in the right half keeps its right edge fixed (grows left), and
-- one close to the middle stays centered, so big numbers never run off the screen edge.
local AUTO_CENTER_ZONE = 60   -- pixels either side of the screen middle that count as "middle"

local function GetAlign(kind, anchorKey)
  local box = anchors[anchorKey or kind]
  if not box then return "center" end
  local cx = box:GetCenter()
  local ux = UIParent:GetCenter()
  if not cx or not ux then return "center" end
  local dx = cx - ux
  if dx < -AUTO_CENTER_ZONE then return "left" end
  if dx > AUTO_CENTER_ZONE then return "right" end
  return "center"
end

local measurer = UIParent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
measurer:Hide()

local function SampleWidth(fobj, spacing, text)
  text = text or ANCHOR_SAMPLE
  measurer:SetFontObject(fobj)
  local sum = 0
  for i = 1, string.len(text) do
    measurer:SetText(string.sub(text, i, i))
    local w = measurer:GetStringWidth()
    if not w or w < 1 then w = 8 end
    sum = sum + w * (spacing / 100)
  end
  return sum
end

local function NewPop(kind)
  local p = CreateFrame("Frame", nil, UIParent)
  p:SetWidth(10)
  p:SetHeight(10)
  p:SetFrameStrata("LOW")   -- behind the game windows (character, achievements ...)
  p.kind = kind
  p.digits = {}
  p.n = 0
  p.unit = 1
  return p
end

local function SetPopColor(p, r, g, b)
  for i = 1, p.n do p.digits[i]:SetTextColor(r, g, b) end
end

-- builds the number as separate characters laid out along a tilted line
local function SetupPop(p, o)
  -- each kind has its OWN font (not the game's combat text font)
  local font
  if o.kind == "perm" then font = CrittersDB.permFont
  elseif o.kind == "record" or o.kind == "streak" then font = CrittersDB.recordFont
  else font = CrittersDB.critFont end
  if not IsValidFont(font) then font = DEFAULT_FONT end

  local text = o.text
  local n = string.len(text)
  p.n = n
  -- the characters are drawn at a fixed font size (fsize); the wanted size (o.size) is reached
  -- with the frame scale k. p.unit = that scale (times the safety-net fix below).
  local fsize = math.max(1, math.floor((o.fontSize or o.size) + 0.5))
  local k = o.size / fsize
  local fix = 1
  local size = fsize
  local fobj = GetFontObject(font, fsize, "THICKOUTLINE")
  local widths, total = {}, 0
  local spacing
  if o.kind == "perm" then spacing = CrittersDB.permSpacing or 80
  elseif o.kind == "streak" then spacing = CrittersDB.streakSpacing or CrittersDB.recordSpacing or CrittersDB.digitSpacing or 80
  elseif o.kind == "record" then spacing = CrittersDB.streakSpacing or CrittersDB.recordSpacing or CrittersDB.digitSpacing or 80
  else spacing = CrittersDB.critSpacing or CrittersDB.digitSpacing or 80 end
  for i = 1, n do
    local d = p.digits[i]
    if not d then
      d = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      p.digits[i] = d
    end
    d:SetFontObject(fobj)                -- size comes from this exact Font object
    d:SetText(string.sub(text, i, i))
    d:SetAlpha(1)
    d:Show()

    if i == 1 then
      -- Safety net: compare this character with a reference character drawn the same
      -- way at a small size (16). Both are measured in the same frame, so any scale
      -- or hidden-frame effect cancels out. If the client drew ours noticeably
      -- smaller than asked, the popup is scaled up to make up the difference.
      local ref = p.ref
      if not ref then
        ref = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        ref:SetPoint("CENTER", p, "CENTER", 0, 0)
        ref:SetAlpha(0)   -- invisible, only used for measuring
        p.ref = ref
      end
      ref:SetFontObject(GetFontObject(font, 16, "THICKOUTLINE"))
      ref:SetText("0")
      ref:Show()

      local _, usedSize = d:GetFont()
      local hd, hr = d:GetStringHeight(), ref:GetStringHeight()
      local drawn = size
      if hd and hr and hd > 0 and hr > 0 then drawn = 16 * hd / hr end
      if drawn < size * 0.88 then
        fix = math.max(1, math.min(6, size / math.max(drawn, 1)))
      end
      if debugMode then
        Msg(string.format("size asked=%d | font reports=%s | drawn=%.1f | scale fix=%.2f",
          size, tostring(usedSize), drawn, fix))
      end
    end

    local w = d:GetStringWidth()
    if not w or w < 1 then w = size * 0.62 end
    widths[i] = w * (spacing / 100)
    total = total + widths[i]
  end
  for i = n + 1, #p.digits do p.digits[i]:Hide() end
  p.total = total
  p.unit = fix * k

  local rad = math.rad(o.tilt)
  local c, sn = math.cos(rad), math.sin(rad)
  local run = 0
  -- where the first character's left edge sits, relative to the popup center
  local startAt = -total / 2
  local align = o.align or GetAlign(o.kind, o.anchorKey)
  if align ~= "center" then
    local sample = SampleWidth(fobj, spacing)
    if align == "left" then startAt = -sample / 2 else startAt = sample / 2 - total end
  end
  p.startAt = startAt
  for i = 1, n do
    local d = p.digits[i]
    local pos = startAt + run + widths[i] / 2
    d.pos = pos
    d.bx, d.by = pos * c, pos * sn
    run = run + widths[i]
    d:ClearAllPoints()
    d:SetPoint("CENTER", p, "CENTER", d.bx, d.by)
  end
end

-- ----- record popup flying to the permanent spot -----
local FLY_TIME = 0.55

local function CenterOf(a)
  local x, y = a:GetCenter()
  if not x then
    local was = a:IsShown()
    a:Show()
    x, y = a:GetCenter()
    if not was then a:Hide() end
  end
  return x, y
end

-- after its time on screen the record straightens up, shrinks to the permanent size and
-- glides to the permanent anchor, then PermLand plays the replace animation
local function StepFly(p, o, ft)
  local k = ft / FLY_TIME
  if k >= 1 then
    PermLand(o)
    return false
  end
  if not o.flyDX then
    local rx, ry = CenterOf(anchors[o.anchorKey or o.kind])
    local px, py = CenterOf(anchors[(o.permKind == "heal") and "permHeal" or "permDmg"])
    o.flyDX = (rx and px) and (px - rx) or 0
    o.flyDY = (ry and py) and (py - ry) or 0
    o.flyY0 = o.oy + o.rise * (o.hold + o.stagger * p.n)
    o.flyScale = (CrittersDB.permSize or 27) / math.max(1, o.size)
  end
  local e = k * k * (3 - 2 * k)

  local s = math.max(0.05, p.unit * (1 + (o.flyScale - 1) * e))
  p:SetScale(s)
  p:SetAlpha(1)

  local x = o.ox + (o.flyDX - o.ox) * e
  local y = o.flyY0 + (o.flyDY - o.flyY0) * e
  p:ClearAllPoints()
  p:SetPoint("CENTER", anchors[o.anchorKey or o.kind], "CENTER", x / s, y / s)

  -- the lean is gone well before it arrives: the permanent number is always straight
  local ang = math.rad(o.tilt) * (1 - math.min(1, e * 1.6))
  local c, sn = math.cos(ang), math.sin(ang)
  for i = 1, p.n do
    local d = p.digits[i]
    d:SetAlpha(1)
    d.bx, d.by = d.pos * c, d.pos * sn
    d:ClearAllPoints()
    d:SetPoint("CENTER", p, "CENTER", d.bx, d.by)
  end
  return true
end

-- returns false when the popup is finished
local function StepPop(p, elapsed)
  p.t = p.t + elapsed
  local o = p.o
  local t = p.t - o.delay
  if t < 0 then return true end

  -- 1) arrive: start scale -> undershoot/overshoot -> 1
  local scale, alpha = 1, 1
  local arrive = o.slam + o.settle
  if t < o.slam then
    local k = t / o.slam
    scale = o.popScale + (o.under - o.popScale) * (k * k)
    alpha = math.min(1, k * 2)
  elseif t < arrive then
    local k = (t - o.slam) / o.settle
    scale = o.under + (1 - o.under) * k
  else
    local tb = t - arrive
    if o.bounce > 0 then
      scale = 1 + o.bounce * math.exp(-5 * tb) * math.sin(tb * 22)
    end
    if o.pulse > 0 then
      scale = scale * (1 + o.pulse * math.max(0, math.sin(t * o.pulseRate)))
    end
  end

  -- 2) stay, then fade
  local hold = o.hold + o.stagger * p.n
  if o.permData and t > hold then return StepFly(p, o, t - hold) end
  if t > hold then
    local k = (t - hold) / o.fade
    if k >= 1 then return false end
    alpha = alpha * (1 - k)
  end

  scale = scale * p.unit
  if scale < 0.05 then scale = 0.05 end
  p:SetScale(scale)
  p:SetAlpha(alpha)

  -- position: travels in from (fromX, fromY), optional shake and rise
  local a = math.min(1, t / math.max(0.01, o.slam))
  local rem = (1 - a) * (1 - a)
  local x = o.ox + o.fromX * rem
  local y = o.oy + o.fromY * rem + o.rise * t
  if o.shake > 0 and t < 0.35 then
    local sh = o.shake * (1 - t / 0.35)
    x = x + (math.random() * 2 - 1) * sh
    y = y + (math.random() * 2 - 1) * sh
  end
  p:ClearAllPoints()
  p:SetPoint("CENTER", anchors[o.anchorKey or o.kind], "CENTER", x / scale, y / scale)

  -- cascade: characters drop in one after another
  if o.stagger > 0 then
    for i = 1, p.n do
      local d = p.digits[i]
      local ti = t - (i - 1) * o.stagger
      local da = (ti <= 0) and 0 or math.min(1, ti / 0.06)
      local k = math.max(0, math.min(1, ti / 0.18))
      d:SetAlpha(da)
      d:ClearAllPoints()
      d:SetPoint("CENTER", p, "CENTER", d.bx, d.by + (o.digitDrop / p.unit) * (1 - k) * (1 - k))
    end
  end

  -- color: white-hot flash cooling down to the final color
  if o.flash then
    local c = t / 0.30
    local col = o.color
    if c < 1 then
      SetPopColor(p, 1 + (col[1] - 1) * c, 0.95 + (col[2] - 0.95) * c, 0.8 + (col[3] - 0.8) * c)
    elseif not p.flashDone then
      SetPopColor(p, col[1], col[2], col[3])
      p.flashDone = true
    end
  end

  return true
end

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(self, elapsed)
  for i = #active, 1, -1 do
    local p = active[i]
    if not StepPop(p, elapsed) then
      p:Hide()
      table.remove(active, i)
      local pool = pools[p.kind]
      pool[#pool + 1] = p
    end
  end
  if #active == 0 then self:Hide() end
end)

local function SpawnPop(o)
  local pool = pools[o.kind]
  local p = table.remove(pool) or NewPop(o.kind)
  p.t = 0
  p.o = o
  p.flashDone = false
  p:ClearAllPoints()
  p:SetPoint("CENTER", anchors[o.anchorKey or o.kind], "CENTER", o.ox, o.oy)
  p:SetScale(1)     -- recycled popups still carry their last scale; start clean
  p:SetAlpha(0)
  p:Show()          -- shown (but invisible) so text can be measured properly
  SetupPop(p, o)
  p:SetScale(math.max(0.05, o.popScale * p.unit))

  if o.flash then
    SetPopColor(p, 1, 0.95, 0.8)
  else
    SetPopColor(p, o.color[1], o.color[2], o.color[3])
  end

  active[#active + 1] = p
  driver:Show()
end

local function ClearPops(kind)
  for i = #active, 1, -1 do
    local p = active[i]
    if not kind or p.kind == kind then
      p:Hide()
      table.remove(active, i)
      local pool = pools[p.kind]
      pool[#pool + 1] = p
    end
  end
end

-- ========= Permanent record (saved per hero) =========
-- Damage crits and heal crits each have their own permanent number. Every crit above
-- MIN_ALLTIME that beats a hero's all-time best is saved under that hero's name, with the
-- spell, the target and the target's health %. The "group" record is the best crit since
-- you joined your current group. Both are tracked whatever the mode is; the mode (and the
-- Damage/Heal ticks) only decide what is SHOWN and whether the record popup flies there.
local MIN_ALLTIME = 10000   -- default; changeable in the options (CrittersDB.minAllTime)
local function MinAllTime() return CrittersDB.minAllTime or MIN_ALLTIME end
local GROUP_GRACE = 30     -- seconds outside a group before joining another one counts as a NEW group

local PERM_MODES = {
  { key = "group",  name = "In Group", tip = "Your best crit since you joined this group or raid. Joining a new one starts fresh, so you can compare raid vs raid." },
  { key = "always", name = "Always", tip = "Your overall all-time best crit on this hero, ignoring groups and raids. Only crits above your minimum count." },
  { key = "never",  name = "Never", tip = "No permanent number. The record crit just fades above the Crit Streak. Records are still saved." },
}
local PERM_DESC = {
  group  = "Best crit since you joined this group or raid. A new group starts fresh. It stays after you leave until you right-click it.",
  always = "Your overall all-time best crit on this hero, whatever the group (only crits above %s count).",
  never  = "The record crit stays above the Crit Streak and fades. Records are still tracked.",
}

-- small delayed-call helper
local timers = {}
local timerFrame = CreateFrame("Frame")
timerFrame:Hide()
timerFrame:SetScript("OnUpdate", function(self, el)
  for i = #timers, 1, -1 do
    local t = timers[i]
    t.left = t.left - el
    if t.left <= 0 then
      table.remove(timers, i)
      t.fn()
    end
  end
  if #timers == 0 then self:Hide() end
end)
local function After(sec, fn)
  timers[#timers + 1] = { left = sec, fn = fn }
  timerFrame:Show()
end

-- target health % (only searches when a record is actually set)
local function GetTargetPct(guid)
  if not guid then return nil end
  local function check(u)
    if UnitExists(u) and UnitGUID(u) == guid then
      local mx = UnitHealthMax(u)
      if mx and mx > 0 then return math.floor(UnitHealth(u) / mx * 100 + 0.5) end
    end
  end
  local units = { "target", "focus", "mouseover", "targettarget", "pettarget" }
  for _, u in ipairs(units) do
    local r = check(u)
    if r then return r end
  end
  local raid = GetNumRaidMembers()
  if raid > 0 then
    for i = 1, raid do
      local r = check("raid" .. i .. "target")
      if r then return r end
    end
  else
    for i = 1, GetNumPartyMembers() do
      local r = check("party" .. i .. "target")
      if r then return r end
    end
  end
  return nil
end

-- one entry per character ("Name-Realm") inside the account-wide CrittersDB
local function Hero()
  CrittersDB.heroes = CrittersDB.heroes or {}
  local key = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
  local h = CrittersDB.heroes[key]
  if not h then
    h = {}
    CrittersDB.heroes[key] = h
  end
  h.name = UnitName("player")
  local _, classFile = UnitClass("player")
  if classFile then h.class = classFile end   -- for the class colors in the all-time list
  h.best = h.best or {}   -- all-time best crit, per kind ("dmg" / "heal")
  h.grp  = h.grp  or {}   -- best crit since joining the current group, per kind
  -- records saved by the first version (damage and heals shared one record)
  if h.allTime then
    local k = h.allTime.heal and "heal" or "dmg"
    if not h.best[k] then h.best[k] = h.allTime end
    h.allTime = nil
  end
  if h.group then
    local k = h.group.heal and "heal" or "dmg"
    if not h.grp[k] then h.grp[k] = h.group end
    h.group = nil
  end
  return h
end

local function IsGrouped()
  return GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0
end

local function PermMode()
  local m = CrittersDB.permMode
  if m ~= "always" and m ~= "never" then m = "group" end
  return m
end

local alwaysHidden = { dmg = false, heal = false }   -- "Hide" in Always mode lasts until the next all-time record

-- what the permanent number of this kind should show right now (nil = nothing)
local function GetPermData(kind)
  local mode = PermMode()
  if mode == "never" or not PermEnabled(kind) then return nil end
  if CrittersDB.permHidden then return nil end   -- the Hide button: numbers off, records still tracked
  local h = Hero()
  if mode == "always" then
    if alwaysHidden[kind] then return nil end
    return h.best[kind]
  end
  return h.grp[kind]
end

-- ----- the permanent numbers (two frames each, so the old one can be bonked away) -----
local perm = {
  dmg  = { kind = "dmg",  anchorKey = "permDmg",  heal = false, frames = {}, cur = 1 },
  heal = { kind = "heal", anchorKey = "permHeal", heal = true,  frames = {}, cur = 1 },
}
local previewToken = 0

local function PermTipEnter(self)
  local d = self.data
  if not d then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(d.spell or "Melee", 1, 1, 1)
  GameTooltip:AddLine("To " .. (d.target or "Unknown"), 0.8, 0.8, 0.8)
  if d.pct then GameTooltip:AddLine("at " .. d.pct .. "%", 1, 0.82, 0) end
  GameTooltip:Show()
end

local menuFrame
local function ClosePerm(kind)
  local mode = PermMode()
  if mode == "group" then
    Hero().grp[kind] = nil
  elseif mode == "always" then
    alwaysHidden[kind] = true
  end
  RefreshPerm()
end

local function OpenPermMenu(kind)
  if not menuFrame then
    menuFrame = CreateFrame("Frame", "CrittersPermMenu", UIParent, "UIDropDownMenuTemplate")
  end
  local menu = {
    { text = (kind == "heal") and "Permanent heal record" or "Permanent damage record", isTitle = true, notCheckable = true },
    { text = (PermMode() == "always") and "Hide" or "Close", notCheckable = true, func = function() ClosePerm(kind) end },
    { text = "Cancel", notCheckable = true },
  }
  EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
end

local function PermFrame(ps, i)
  local p = ps.frames[i]
  if not p then
    p = NewPop("perm")
    p:EnableMouse(true)
    p:SetScript("OnEnter", PermTipEnter)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p:SetScript("OnMouseUp", function(self, button)
      if button == "RightButton" and self.data then OpenPermMenu(ps.kind) end
    end)
    p:Hide()
    ps.frames[i] = p
  end
  return p
end

-- draws a number into one of the permanent frames (sample = the placement preview).
-- Always straight: the tilt is 0.
local function FillPerm(ps, p, text, data, sample)
  local size = CrittersDB.permSize or 27
  p:SetScale(1)
  p:SetAlpha(0)
  p:Show()
  SetupPop(p, { kind = "perm", anchorKey = ps.anchorKey, text = text, size = size, fontSize = REF_SIZE, tilt = 0 })
  local col = GetColor("perm", ps.heal)
  p.col = col
  SetPopColor(p, col[1], col[2], col[3])
  -- wide enough to cover the digits whichever way the number is anchored (mouse tooltip area)
  local sa = p.startAt or -(p.total or 0) / 2
  local reach = math.max(math.abs(sa), math.abs(sa + (p.total or 0)))
  p:SetWidth(math.max(24, reach * 2 + 12))
  p:SetHeight(REF_SIZE * 1.4)   -- (the frame is scaled down to the wanted size)
  p:ClearAllPoints()
  p:SetPoint("CENTER", anchors[ps.anchorKey], "CENTER", 0, 0)
  p:SetScale(math.max(0.05, p.unit))
  p:SetAlpha(1)
  p.data = data
  p:EnableMouse(not sample)   -- the sample must not block dragging the box on top of it
  if sample then              -- the draggable box wraps the sample number
    local a = anchors[ps.anchorKey]
    a:SetWidth(math.max(60, (p.total or 0) * p.unit + 20))
    a:SetHeight(size * 1.4 + 8)
  end
  p:SetFrameStrata("LOW")   -- behind the game windows (character, achievements ...)
end

-- replace animation: the new number slams in and bonks the old one away
local permAnimFrame = CreateFrame("Frame")
permAnimFrame:Hide()

local function StopPermAnim(ps)
  if ps.anim then
    ps.anim.old:Hide()
    ps.anim = nil
  end
end

local function StepPermAnim(ps, el)
  local a = ps.anim
  a.t = a.t + el
  local t = a.t

  -- new number: settles from its impact size, cooling from white-hot to its color
  local nk = math.min(1, t / 0.14)
  local sc = 1 + (a.fromScale - 1) * (1 - nk) * (1 - nk)
  a.new:SetScale(math.max(0.05, a.new.unit * sc))
  if t < 0.34 then
    local ck, col = t / 0.30, a.new.col
    if ck > 1 then ck = 1 end
    SetPopColor(a.new, 1 + (col[1] - 1) * ck, 0.95 + (col[2] - 0.95) * ck, 0.8 + (col[3] - 0.8) * ck)
  end

  -- old number: ONE bonk (knocked sideways and down), then it shrinks and fades out smoothly
  if a.hadOld then
    local KNOCK, LIFE = 0.16, 0.80
    if t >= LIFE then
      a.old:Hide()
      a.hadOld = false
    else
      local kk = math.min(1, t / KNOCK)
      local ease = 1 - (1 - kk) * (1 - kk) * (1 - kk)
      local drift = t / LIFE
      local os = math.max(0.05, a.old.unit * (1 - 0.35 * ease - 0.25 * drift))
      local x = a.dir * (70 * ease + 40 * drift)
      local y = -(24 * ease) - 50 * drift * drift
      a.old:SetScale(os)
      a.old:ClearAllPoints()
      a.old:SetPoint("CENTER", anchors[ps.anchorKey], "CENTER", x / os, y / os)
      a.old:SetAlpha((1 - drift) * (1 - drift))
    end
  end

  if nk >= 1 and t >= 0.34 and not a.hadOld then
    a.new:SetScale(math.max(0.05, a.new.unit))
    local col = a.new.col
    SetPopColor(a.new, col[1], col[2], col[3])
    ps.anim = nil
  end
end

permAnimFrame:SetScript("OnUpdate", function(self, el)
  local any = false
  for _, ps in pairs(perm) do
    if ps.anim then
      StepPermAnim(ps, el)
      if ps.anim then any = true end
    end
  end
  if not any then self:Hide() end
end)

-- shows what the current mode says should be on screen (or the sample while placing it)
local function RefreshOne(ps, preview)
  StopPermAnim(ps)
  local cur = PermFrame(ps, ps.cur)
  PermFrame(ps, 3 - ps.cur):Hide()
  if anchors[ps.anchorKey]:IsShown() then
    -- Unlock / Lock: the sample is the widest number there can be, so the draggable box is the
    -- number's full footprint. Clamped to the screen, the number can never run off the edge.
    FillPerm(ps, cur, ANCHOR_SAMPLE, nil, true)
    return
  end
  local data = GetPermData(ps.kind)
  if data then
    FillPerm(ps, cur, FormatNumber(data.amount), data, false)
  elseif preview and PermEnabled(ps.kind) then   -- no record on screen: show a test number instead
    FillPerm(ps, cur, "123,456", nil, true)
  else
    cur.data = nil
    cur:Hide()
  end
end

-- while a mover is being dragged: the moment it crosses into another screen zone (left / middle /
-- right) the number is laid out again, live, instead of only after you let go
AnchorDragTick = function(a)
  local key = a.kind
  local al = GetAlign(key, key)
  if al ~= a.lastAlign then
    a.lastAlign = al
    if key == "permDmg" or key == "permHeal" then RefreshPerm() end
  end
end

RefreshPerm = function(preview)
  for _, ps in pairs(perm) do RefreshOne(ps, preview) end
  if preview then   -- take the test number away again after a few seconds
    previewToken = previewToken + 1
    local token = previewToken
    After(4.5, function() if token == previewToken then RefreshPerm() end end)
  end
end

local function PermReplace(kind, data, fromScale)
  local ps = perm[kind]
  if anchors[ps.anchorKey]:IsShown() then return end   -- placing it: the sample stays, it refreshes on Lock
  StopPermAnim(ps)
  local old = PermFrame(ps, ps.cur)
  local hadOld = old:IsShown() and old.data ~= nil
  ps.cur = 3 - ps.cur
  local new = PermFrame(ps, ps.cur)
  FillPerm(ps, new, FormatNumber(data.amount), data, false)
  new:SetScale(math.max(0.05, new.unit * (fromScale or 1.25)))
  SetPopColor(new, 1, 0.95, 0.8)
  old:EnableMouse(false)
  if GameTooltip:IsOwned(old) then GameTooltip:Hide() end
  if not hadOld then old:Hide() end
  ps.anim = {
    t = 0, old = old, new = new, hadOld = hadOld,
    dir = (math.random() < 0.5) and -1 or 1,
    fromScale = fromScale or 1.25,
  }
  permAnimFrame:Show()
end

-- called when a flying record popup reaches its permanent spot
PermLand = function(o)
  local kind = o.permKind or "dmg"
  if anchors[perm[kind].anchorKey]:IsShown() then return end
  if o.permPreview then
    PermReplace(kind, o.permData, 1.25)
    previewToken = previewToken + 1
    local token = previewToken
    After(4.5, function() if token == previewToken then RefreshPerm() end end)
    return
  end
  if GetPermData(kind) ~= o.permData then   -- mode changed or record closed while flying
    RefreshPerm()
    return
  end
  PermReplace(kind, o.permData, 1.25)
end

-- ----- tracking -----
-- Blood Queen Lana'thel (Icecrown Citadel) buff "Essence of the Blood Queen": it greatly
-- boosts damage and healing, so records made with it can be marked or skipped.
local BQL_IDS = { [70867] = true, [70871] = true, [71473] = true, [71525] = true,
                  [71530] = true, [71531] = true, [71532] = true, [71533] = true }
local bqlName
local function HasBloodQueenBuff()
  if not bqlName then bqlName = GetSpellInfo(70871) or GetSpellInfo(70867) or "Essence of the Blood Queen" end
  for i = 1, 40 do
    -- 3.3.5 UnitBuff: name, rank, icon, count, debuffType, duration, expires, caster, stealable, consolidate, spellId
    local name, _, _, _, _, _, _, _, _, _, spellId = UnitBuff("player", i)
    if not name then break end
    if (spellId and BQL_IDS[spellId]) or name == bqlName or name == "Essence of the Blood Queen" then
      return true
    end
  end
  return false
end

-- Valithria Dreamwalker (Icecrown Citadel) healing buffs "Emerald Vigor" and "Twisted Nightmares":
-- they boost your healing, so heal records made with them can be skipped.
local VALI_IDS = { [70873] = true, [71941] = true }
local valiNames
local function HasValithriaBuff()
  if not valiNames then
    valiNames = {}
    for id in pairs(VALI_IDS) do
      local n = GetSpellInfo(id)
      if n then valiNames[n] = true end
    end
    valiNames["Emerald Vigor"] = true
    valiNames["Twisted Nightmares"] = true
    valiNames["Twisted Nightmare"] = true
  end
  for i = 1, 40 do
    local name, _, _, _, _, _, _, _, _, _, spellId = UnitBuff("player", i)
    if not name then break end
    if (spellId and VALI_IDS[spellId]) or valiNames[name] then return true end
  end
  return false
end

-- saves new all-time / group records; returns the new record tables (or nil, nil)
local function TrackCrit(amount, isHeal, spell, target, guid, spellId)
  local kind = isHeal and "heal" or "dmg"
  local h = Hero()
  local bql = HasBloodQueenBuff()
  local vali = isHeal and HasValithriaBuff() or false
  -- with "Disable blood queen dmg buff" ticked, crits made under the buff are not all-time records;
  -- with "Disable Valithria heal buff" ticked, the same goes for heals made under her buffs
  local newAll = amount > MinAllTime() and amount > (h.best[kind] and h.best[kind].amount or 0)
    and not (CrittersDB.noBQL and bql)
    and not (CrittersDB.noValithria and vali)
  local newGroup = IsGrouped() and amount > (h.grp[kind] and h.grp[kind].amount or 0)
  if not (newAll or newGroup) then return nil, nil end

  local pct = GetTargetPct(guid)
  local function make()
    return {
      amount = amount, heal = isHeal and true or false,
      spell = spell or "Melee", spellId = spellId, target = target or "Unknown", pct = pct,
      bql = bql or nil,
      vali = vali or nil,
    }
  end
  local a, g
  if newAll then
    a = make()
    h.best[kind] = a
    alwaysHidden[kind] = false
  end
  if newGroup then
    g = make()
    h.grp[kind] = g
  end
  if a and RefreshHeroSheet then RefreshHeroSheet() end
  -- the health bar often updates a moment after the combat log line, so read it again
  After(0.3, function()
    local p2 = GetTargetPct(guid)
    if p2 then
      if a then a.pct = p2 end
      if g then g.pct = p2 end
      if a and RefreshHeroSheet then RefreshHeroSheet() end
    end
  end)
  return a, g
end

-- a new group starts new group records; leaving keeps the old ones until they are closed
local function UpdateGroupState()
  local h = Hero()
  local now = IsGrouped()
  if now and not h.inGroup then
    local away = h.leftAt and (time() - h.leftAt) or 999999
    h.inGroup = true
    h.leftAt = nil
    if away > GROUP_GRACE and (h.grp.dmg or h.grp.heal) then
      h.grp = {}
      RefreshPerm()
    end
  elseif (not now) and h.inGroup then
    h.inGroup = false
    h.leftAt = time()
  end
end

local function PrintRecords()
  local h = Hero()
  local function line(label, d)
    if not d then
      Msg(label .. ": none yet")
    else
      Msg(string.format("%s: |cffffffff%s|r - %s on %s%s", label, FormatNumber(d.amount),
        d.spell or "Melee", d.target or "?", d.pct and (" at " .. d.pct .. "%") or ""))
    end
  end
  line("all-time damage crit", h.best.dmg)
  line("all-time heal crit", h.best.heal)
  line("group damage crit", h.grp.dmg)
  line("group heal crit", h.grp.heal)
end

-- prints every saved hero (account-wide) - handy to check that the save works
local function PrintHeroes()
  local n = 0
  for key, h in pairs(CrittersDB.heroes or {}) do
    n = n + 1
    local d, hl = h.best and h.best.dmg, h.best and h.best.heal
    Msg(string.format("%s: dmg %s | heal %s", key,
      d and FormatNumber(d.amount) or "-", hl and FormatNumber(hl.amount) or "-"))
  end
  Msg(n .. " hero(es) saved in the account-wide file.")
end

-- chat text for sharing a record, with a real clickable spell link:
-- Thered --60,000-- Critical Damage to "The Lich King" @ 45% By [Pyroblast] with BQL Buff
-- the REAL clickable spell link (not just typed text). Uses the saved spell id.
local function SpellLinkText(d)
  local spell = d.spell or "Melee"
  local link
  if GetSpellLink then
    local ok, res = pcall(GetSpellLink, d.spellId or spell)
    if ok then link = res end
  end
  if not link and d.spellId then
    link = "|cff71d5ff|Hspell:" .. d.spellId .. "|h[" .. spell .. "]|h|r"
  end
  return link or ("[" .. spell .. "]")
end

local function ShareText(name, d)
  local spell = d.spell or "Melee"
  local sp = SpellLinkText(d)
  local txt = name .. " --" .. FormatNumber(d.amount) .. "-- Critical " .. (d.heal and "Heal" or "Damage")
    .. " to \"" .. (d.target or "Unknown") .. "\""
  if d.pct then txt = txt .. " @ " .. d.pct .. "%" end
  txt = txt .. " By " .. sp
  if d.bql then txt = txt .. " with BQL Buff" end
  if d.vali then txt = txt .. " with Valithria Buff" end
  return txt
end

-- Record crit: your best crit of the current fight. It slides up out of the Crit Streak and
-- rests just above it (anchored to the streak, so it moves with it) for "time on screen"
-- seconds, then fades or flies to its permanent spot. A new record replaces it. It uses
-- the streak's number size, digit spacing and font.
local function ShowRecord(amount, heal, permData, preview)
  local streakSize = CrittersDB.streakSize or STREAK_SIZE
  local size = math.max(6, math.floor(streakSize + 0.5))
  local hold = CrittersDB.recordHold or 4
  -- resting height above the streak's center: half the streak box + half the number + a gap
  local rest = (streakSize * 1.4 + 8) / 2 + size * 0.7 + 8

  ClearPops("record")

  SpawnPop(BuildOpts(RECORD_SLIDE, {
    kind = "record",
    anchorKey = "streak",
    align = "center",
    text = FormatNumber(amount),
    size = size, fontSize = REF_SIZE,
    ox = 0,
    oy = rest,
    fromY = -rest,   -- starts at the streak's center and slides up
    tilt = Rand(RECORD_TILT_MIN, RECORD_TILT_MAX) - 180,
    hold = preview and 1.2 or hold, fade = FADE_TIME,
    color = GetColor("record", heal),
    permData = permData, permPreview = preview,
    permKind = heal and "heal" or "dmg",
  }))
end

-- Normal crit: takes the next free slot (3 columns x 2 rows) around its own anchor
local critSlot = 0

local function ShowCrit(amount, heal)
  local busy = 0
  for i = 1, #active do
    if active[i].kind == "crit" then busy = busy + 1 end
  end
  if busy >= 6 then return end

  local size = CrittersDB.critSize or NORMAL_CRIT_SIZE
  local jit  = CRIT_JITTER
  local spacing = math.max(NORMAL_CRIT_SPACING, size * 5)

  critSlot = critSlot % 6 + 1
  local col = (critSlot - 1) % 3 - 1
  local row = math.floor((critSlot - 1) / 3)

  SpawnPop(BuildOpts(PickStyle(CRIT_STYLES, CrittersDB.critStyle), {
    kind = "crit",
    text = FormatNumber(amount),
    size = size, fontSize = REF_SIZE,
    ox = col * spacing + Rand(-jit, jit),
    oy = -row * (size + 20) + Rand(-jit, jit),
    tilt = Rand(CRIT_TILT_MIN, CRIT_TILT_MAX) - 180,
    color = GetColor("crit", heal),
  }))
end

local function TestRecord(heal)
  ClearPops()
  ShowRecord(math.random(1, 100000), heal)
end

-- plays the whole record -> permanent spot -> bonk sequence with a made-up record (nothing is saved)
local function PreviewPerm(heal)
  if IsMoving("perm") then SetMoveMode("perm", false) end
  ClearPops()
  local fake = {
    amount = math.random(1, 100000),
    heal = heal and true or false,
    spell = heal and "Holy Light" or "Pyroblast",
    target = "Training Dummy",
    pct = 50,
  }
  ShowRecord(fake.amount, heal, fake, true)
end

local function TestCrit(heal)
  ShowCrit(math.random(1, 100000), heal)
end

-- clears old normal-crit previews first so the slider shows ONE fresh number
local function PreviewCrit(heal)
  ClearPops("crit")
  TestCrit(heal)
end

-- ========= Crit streak =========
-- Counts your damage and heal crits that are at least STREAK_MIN_PCT of this
-- hero's all-time damage record. It is ONE display: a small counter (x1, x2 ...) at 0.7 of the
-- size of the damage total next to it. The total adds up ALL the damage you deal while the
-- streak runs; only crits of STREAK_MIN_PCT+ pop it and raise the x1, x2 counter. The first close-to-record crit makes it appear (with
-- the chosen "streak effect"); every further one pops it in place ("pop 2") and leans the
-- whole thing a little, like it got hit. After STREAK_TIMEOUT seconds without one it slides
-- down, fades and the streak starts over. The counter goes from white (x1) to red (x20).
local STREAK_MIN_PCT      = 0.30   -- a crit must be at least this part of your all-time record
local STREAK_TIMEOUT      = 5      -- seconds without a close-to-record crit before it ends
local STREAK_FULL_RED_AT  = 20     -- the counter is fully red from this count on
local STREAK_COUNTER_SIZE = 0.7    -- counter size compared to the damage number
local STREAK_LEAVE_TIME   = 0.6    -- seconds the slide down + fade takes
local STREAK_LEAVE_DROP   = 70     -- how far it slides down while fading

-- first appearance: exactly the record crit effects, with their own saved choice
local STREAK_STYLES = {}
for i, st in ipairs(RECORD_STYLES) do
  local c = {}
  for k, v in pairs(st) do c[k] = v end
  STREAK_STYLES[i] = c
end

-- "pop 2": plays in place on every close-to-record crit after the first. "random" stays LAST.
--   kick = scale at the moment of the hit, tilt = extra lean in degrees, push = sideways knock
local STREAK_HIT_STYLES = {
  { key = "punch",  name = "Punch",  tip = "Quick punch: grows and snaps back while leaning like it got hit.", kick = 1.45, time = 0.16, shake = 5, tilt = 9 },
  { key = "slam",   name = "Slam",   tip = "Hard slam from big to a bit too small and back, with a heavy lean.", kick = 1.9, under = 0.93, time = 0.20, shake = 9, tilt = 13 },
  { key = "jolt",   name = "Jolt",   tip = "Knocked sideways and snaps back. It does not grow.", kick = 1.0, push = 36, time = 0.22, shake = 8, tilt = 12 },
  { key = "spring", name = "Spring", tip = "Squashes small, then springs back past full size.", kick = 0.65, spring = true, time = 0.45, shake = 0, tilt = 7 },
  { key = "random", name = "Random", tip = "A different effect every time." },
}

local streak = { count = 0, amount = 0, phase = "idle" }   -- phase: idle / live / leaving / placing

-- color of the big streak number: damage or heal (kind of the latest crit that fed the streak).
-- Until picked they follow the normal damage / heal crit colors. (A field of `streak`, so it
-- needs no extra local variable or upvalue.)
function streak.Color(heal)
  if heal then return CrittersDB.streakHealColor or GetColor("crit", true) end
  return CrittersDB.streakColor or GetColor("crit", false)
end
local StreakBuild   -- defined below (the damage total redraws through it)

local function StreakSizes()
  local size = math.max(6, math.floor((CrittersDB.streakSize or STREAK_SIZE) + 0.5))
  local csize = size * STREAK_COUNTER_SIZE
  return size, csize, size * 0.3   -- amount size, counter size, gap between them (all as wanted on screen)
end

local function PlaceDigits(st, p, centerX, ca, sa, casc, a, idxBase)
  local u = p.unit
  for i = 1, p.n do
    local d = p.digits[i]
    local X = centerX + d.pos * u
    local dy, al = 0, 1
    if casc then   -- cascade effect: the characters drop in one after another
      local ti = casc - (idxBase + i - 1) * a.stagger
      al = (ti <= 0) and 0 or math.min(1, ti / 0.06)
      local kk = math.max(0, math.min(1, ti / 0.18))
      dy = a.digitDrop * (1 - kk) * (1 - kk)
    end
    d:SetAlpha(al)
    d:ClearAllPoints()
    d:SetPoint("CENTER", st.frame, "CENTER", (X * ca) / u, (X * sa + dy) / u)
  end
end

local function StreakUpdate(self, el)
  local st = streak
  local scale, alpha, ox, oy, angle = 1, 1, 0, 0, 0
  local a = st.appear

  -- the damage total grows with every hit; redraw it at most 10 times a second
  if st.dirty and st.phase == "live" and GetTime() - (st.lastBuild or 0) >= 0.1 then
    st.dirty = false
    st.lastBuild = GetTime()
    StreakBuild()
  end

  if not st.placing then
    -- too long without a close-to-record crit: the streak is over
    if st.phase == "live" and GetTime() - (st.last or 0) > STREAK_TIMEOUT then
      st.phase = "leaving"
      st.leaveT = 0
    end

    -- first appearance (one of the record crit effects)
    if st.aT and a then
      st.aT = st.aT + el
      local t = st.aT
      local arrive = a.slam + a.settle
      if t < a.slam then
        local k = t / a.slam
        scale = a.popScale + (a.under - a.popScale) * k * k
        alpha = math.min(1, k * 2)
      elseif t < arrive then
        scale = a.under + (1 - a.under) * ((t - a.slam) / a.settle)
      else
        local tb = t - arrive
        if a.bounce > 0 then scale = 1 + a.bounce * math.exp(-5 * tb) * math.sin(tb * 22) end
        if a.pulse > 0 and tb < 1.2 then scale = scale * (1 + a.pulse * math.max(0, math.sin(t * a.pulseRate))) end
        if tb > 1.2 then st.aT = nil end
      end
      local k2 = math.min(1, t / math.max(0.01, a.slam))
      local rem = (1 - k2) * (1 - k2)
      ox, oy = a.fromX * rem, a.fromY * rem
      if a.shake > 0 and t < 0.35 then
        local sh = a.shake * (1 - t / 0.35)
        ox = ox + (math.random() * 2 - 1) * sh
        oy = oy + (math.random() * 2 - 1) * sh
      end
    end

    -- pop 2: every further close-to-record crit pops it in place and leans it
    local h = st.hitStyle
    if st.hT and h then
      st.hT = st.hT + el
      local t = st.hT
      local hs = 1
      if h.spring then
        if t < 0.8 then hs = 1 + (h.kick - 1) * math.exp(-7 * t) * math.cos(24 * t) end
      elseif t < h.time then
        if h.under then
          local split = h.time * 0.6
          if t < split then
            local kk = t / split
            hs = h.kick + (h.under - h.kick) * kk * kk
          else
            hs = h.under + (1 - h.under) * ((t - split) / (h.time - split))
          end
        else
          local kk = t / h.time
          hs = 1 + (h.kick - 1) * (1 - kk) * (1 - kk)
        end
      end
      scale = scale * hs
      if h.push and t < h.time * 1.5 then
        local kk = t / (h.time * 1.5)
        ox = ox + h.push * st.hitSide * (1 - kk) * (1 - kk)
      end
      if h.shake > 0 and t < 0.25 then
        local sh = h.shake * (1 - t / 0.25)
        ox = ox + (math.random() * 2 - 1) * sh
        oy = oy + (math.random() * 2 - 1) * sh
      end
      -- the lean: starts at the hit angle and settles to a small resting lean
      local kt = math.min(1, t / (h.time * 1.6 + 0.1))
      angle = (st.rest or 0) + st.hitSide * h.tilt * (1 - kt) * (1 - kt)
      if t > 1 then st.hT = nil end
    else
      angle = st.rest or 0
    end

    -- slide down and fade out
    if st.phase == "leaving" then
      st.leaveT = st.leaveT + el
      local k = st.leaveT / STREAK_LEAVE_TIME
      if k >= 1 then
        st.phase = "idle"
        st.count = 0
        self:Hide()
        return
      end
      oy = oy - STREAK_LEAVE_DROP * k * (2 - k)
      alpha = alpha * (1 - k)
    end
  end

  -- which edge stays put (see GetAlign): the whole thing turns and scales around that edge
  local align = GetAlign("streak", "streak")
  local W, sW = st.w or 0, st.sampleW or 0
  local E, leftEdge
  if align == "left" then E, leftEdge = -sW / 2, 0
  elseif align == "right" then E, leftEdge = sW / 2, -W
  else E, leftEdge = 0, -W / 2 end
  local cX = leftEdge + st.cw / 2
  local nX = leftEdge + st.cw + st.gap + st.nw / 2

  local s = math.max(0.05, scale)
  self:SetScale(s)
  self:SetAlpha(alpha)
  self:ClearAllPoints()
  self:SetPoint("CENTER", anchors.streak, "CENTER", (E + ox) / s, oy / s)

  local rad = math.rad(angle)
  local ca, sa = math.cos(rad), math.sin(rad)
  local casc = (a and st.aT and a.stagger > 0 and not st.placing) and st.aT or nil
  PlaceDigits(st, st.cnt, cX, ca, sa, casc, a, 0)
  PlaceDigits(st, st.num, nX, ca, sa, casc, a, st.cnt.n)
end

local function EnsureStreak()
  if streak.frame then return streak end
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetWidth(10)
  f:SetHeight(10)
  f:SetFrameStrata("LOW")   -- behind the game windows (character, achievements ...)
  f:SetAlpha(0)
  f:Hide()
  streak.frame = f
  streak.cnt = NewPop("streak")   -- the x1, x2 ... counter
  streak.num = NewPop("streak")   -- the crit amount
  streak.cnt:SetParent(f)
  streak.num:SetParent(f)
  f:SetScript("OnUpdate", StreakUpdate)
  return streak
end

-- (re)writes the counter and the amount for the current count / amount
StreakBuild = function()
  local st = EnsureStreak()
  local size, csize, gap = StreakSizes()
  st.frame:Show()   -- shown (still invisible) so the text can be measured

  SetupPop(st.cnt, { kind = "streak", text = "x" .. st.count, size = csize, fontSize = REF_SIZE * STREAK_COUNTER_SIZE, tilt = 0, align = "center" })
  SetupPop(st.num, { kind = "streak", text = FormatNumber(st.amount), size = size, fontSize = REF_SIZE, tilt = 0, align = "center" })
  st.cnt:SetScale(math.max(0.05, st.cnt.unit))
  st.num:SetScale(math.max(0.05, st.num.unit))

  -- counter: white at x1, redder and redder up to x20. Amount: its own damage / heal color (Crit Streak options).
  local k = math.min(1, math.max(0, (st.count - 1) / (STREAK_FULL_RED_AT - 1)))
  SetPopColor(st.cnt, 1, 1 - 0.88 * k, 1 - 0.92 * k)
  local c = streak.Color(st.heal)
  SetPopColor(st.num, c[1], c[2], c[3])

  st.cw = (st.cnt.total or 0) * st.cnt.unit
  st.nw = (st.num.total or 0) * st.num.unit
  st.gap = gap
  st.w = st.cw + gap + st.nw

  -- width of a full sample ("x20" + 12,345,678): the fixed edge is measured from it, and the
  -- Unlock box wraps it
  local font = CrittersDB.recordFont
  if not IsValidFont(font) then font = DEFAULT_FONT end
  local sp = CrittersDB.streakSpacing or CrittersDB.recordSpacing or CrittersDB.digitSpacing or 80
  local cref = math.floor(REF_SIZE * STREAK_COUNTER_SIZE + 0.5)
  st.sampleW = SampleWidth(GetFontObject(font, cref, "THICKOUTLINE"), sp, "x" .. STREAK_FULL_RED_AT) * (csize / cref)
    + gap + SampleWidth(GetFontObject(font, REF_SIZE, "THICKOUTLINE"), sp, ANCHOR_SAMPLE) * (size / REF_SIZE)
  anchors.streak:SetWidth(math.max(60, st.sampleW + 20))
  anchors.streak:SetHeight(size * 1.4 + 8)
end

-- every damage hit of yours while a streak is running grows the big number (no pop)
local function StreakAddDamage(amount)
  local st = streak
  if st.phase ~= "live" or st.placing then return end
  st.amount = st.amount + amount
  local now = GetTime()
  if now - (st.lastBuild or 0) >= 0.1 then
    st.lastBuild = now
    st.dirty = false
    StreakBuild()
  else
    st.dirty = true
  end
end

-- a damage crit of 30%+ of your record: starts the streak, or pops it and adds to the x1, x2 counter
local function StreakHit(amount, isHeal)
  local st = EnsureStreak()
  if st.placing then return end
  st.heal = isHeal and true or false   -- decides the color of the big number
  local fresh = (st.phase ~= "live")
  if fresh then st.count, st.amount = 0, amount end   -- the first crit starts the damage total
  st.count = st.count + 1                             -- (later hits were already added by StreakAddDamage)
  st.last = GetTime()
  st.phase = "live"
  st.leaveT = nil

  if fresh then
    st.frame:SetAlpha(0)
    st.appear = BuildOpts(PickStyle(STREAK_STYLES, CrittersDB.streakStyle), {})
    st.aT, st.hT, st.rest = 0, nil, 0
  else
    st.hitStyle = PickStyle(STREAK_HIT_STYLES, CrittersDB.streakHitStyle)
    st.hitSide = (math.random() < 0.5) and -1 or 1
    st.rest = st.hitSide * Rand(3, 6)   -- stays leaning a little until the next hit
    st.hT = 0
  end
  StreakBuild()
  StreakUpdate(st.frame, 0)
end

local function StreakReset()
  local st = streak
  if anchors.streak:IsShown() then SetMoveMode("streak", false) end
  st.count, st.phase, st.aT, st.hT, st.placing = 0, "idle", nil, nil, false
  if st.frame then st.frame:Hide() end
end

-- Unlock shows a steady sample (x20 + a full-size number) inside the draggable box
StreakSetPlacing = function(on)
  local st = EnsureStreak()
  if on then
    st.placing = true
    st.phase = "placing"
    st.count, st.amount = STREAK_FULL_RED_AT, 12345678
    st.aT, st.hT, st.rest = nil, nil, 0
    st.frame:SetAlpha(0)
    StreakBuild()
    StreakUpdate(st.frame, 0)
  else
    st.placing = false
    st.phase = "idle"
    st.count = 0
    st.aT, st.hT = nil, nil
    st.frame:Hide()
  end
end

-- test button: the first press makes the streak appear, presses within 5 seconds pop it
local function StreakTestHit(isHeal)
  local dmg = math.random(1, 100000)
  if streak.phase == "live" then StreakAddDamage(dmg) end   -- like the real hit's damage
  StreakHit(dmg, isHeal)
end

local function StreakTest(isHeal)
  if anchors.streak:IsShown() then SetMoveMode("streak", false) end
  StreakTestHit(isHeal)
end

-- size slider: redraw whatever is on screen (or show a test streak)
-- (previewHeal = true/false shows that kind's color when a sample streak has to be started)
local function StreakRefresh(previewHeal)
  local st = streak
  if st.placing then
    if previewHeal ~= nil then st.heal = previewHeal end
    StreakBuild()
    StreakUpdate(st.frame, 0)
  elseif st.phase == "live" then
    if previewHeal ~= nil then st.heal = previewHeal end
    StreakBuild()
  else
    StreakTest(previewHeal)
  end
end

-- picking a first-appearance effect: start over so you see it
local function StreakPreviewAppear()
  StreakReset()
  StreakTest()
end

-- picking a pop 2 effect: make sure a streak is running, then pop it
local function StreakPreviewHit()
  if anchors.streak:IsShown() then SetMoveMode("streak", false) end
  if streak.phase == "live" then
    StreakTestHit()
  else
    StreakTestHit()
    After(0.7, StreakTestHit)
  end
end

-- ========= Combat tracking =========
local ev = CreateFrame("Frame")
-- the record crit is the best crit of the CURRENT FIGHT only (reset when combat starts / ends)
local dmgRecord, healRecord = 0, 0
local recordTime = 0
local stats = { events = 0, mine = 0, crits = 0 }
local DAMAGE_EVENTS = {
  SPELL_DAMAGE = true,
  RANGE_DAMAGE = true,
  SPELL_PERIODIC_DAMAGE = true,
}
local HEAL_EVENTS = {
  SPELL_HEAL = true,
  SPELL_PERIODIC_HEAL = true,
}

local function OnCombatLog(...)
  -- 3.3.5 args: timestamp, subevent, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...
  stats.events = stats.events + 1
  local _, subevent, srcGUID = ...
  local me = UnitGUID("player")
  if not me or srcGUID ~= me then return end
  stats.mine = stats.mine + 1

  local amount, critical, spellName, spellId
  local isHeal = false
  if subevent == "SWING_DAMAGE" then
    amount, _, _, _, _, _, critical = select(9, ...)
  elseif DAMAGE_EVENTS[subevent] then
    _, _, _, amount, _, _, _, _, _, critical = select(9, ...)
    spellName = select(10, ...)
    spellId = select(9, ...)
  elseif HEAL_EVENTS[subevent] and CrittersDB.healCrits ~= false then
    isHeal = true
    -- spellId(9) spellName(10) school(11) amount(12) overhealing absorbed critical
    -- critical is the LAST argument of the heal event
    amount = select(12, ...)
    spellName = select(10, ...)
    spellId = select(9, ...)
    critical = select(select("#", ...), ...)
    if critical ~= 1 and critical ~= true then critical = nil end
  else
    return
  end

  if debugMode then
    Msg(string.format("%s amount=%s crit=%s args=%d", subevent, tostring(amount), tostring(critical), select("#", ...)))
  end

  -- Crit Streak total: ALL your damage AND healing (crit or not) while a streak is running
  if amount and amount > 0 then StreakAddDamage(amount) end

  if not critical or not amount or amount <= 0 then return end
  stats.crits = stats.crits + 1

  -- records (all-time per hero, and per group) are tracked in EVERY mode
  local dstGUID, dstName = select(6, ...), select(7, ...)
  local permAll, permGroup = TrackCrit(amount, isHeal, spellName, dstName, dstGUID, spellId)

  -- Crit Streak: any damage or heal crit that is close to (or above) this hero's all-time
  -- record of the same kind (heal crits only arrive here when "Track heal crits too" is on)
  if CrittersDB.streakEnabled ~= false then
    local rec = Hero().best[isHeal and "heal" or "dmg"]
    if rec and rec.amount and amount >= rec.amount * STREAK_MIN_PCT then StreakHit(amount, isHeal) end
  end
  local mode = PermMode()
  local kind = isHeal and "heal" or "dmg"
  local permData = (mode == "group" and permGroup) or (mode == "always" and permAll) or nil
  if permData and (not PermEnabled(kind) or CrittersDB.permHidden) then permData = nil end   -- that number is switched off

  local recordOn = CrittersDB.recordEnabled ~= false
  local critOn   = CrittersDB.critPop ~= false

  local best = isHeal and healRecord or dmgRecord
  local spawned = false
  if recordOn and amount > best then
    if isHeal then healRecord = amount else dmgRecord = amount end
    recordTime = GetTime()
    ShowRecord(amount, isHeal, permData)   -- with permData it flies to the permanent spot
    spawned = true
  elseif critOn then
    ShowCrit(amount, isHeal)
  end
  if permData and not spawned then PermReplace(kind, permData, 2.0) end
end

local function ApplyTracking()
  ev:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
  ev:RegisterEvent("PLAYER_REGEN_ENABLED")
  ev:RegisterEvent("PLAYER_REGEN_DISABLED")
  ev:RegisterEvent("PLAYER_ENTERING_WORLD")
  ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
  ev:RegisterEvent("RAID_ROSTER_UPDATE")
end

ev:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_REGEN_ENABLED" then
    dmgRecord, healRecord = 0, 0   -- combat ended: the next fight starts a fresh record
  elseif event == "PLAYER_REGEN_DISABLED" then
    -- combat started: also clears records made out of combat (e.g. a heal on a friend).
    -- Skipped if a record was set a split second ago, so the very first hit still counts.
    if GetTime() - recordTime > 1 then dmgRecord, healRecord = 0, 0 end
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    OnCombatLog(...)
  elseif event == "PLAYER_ENTERING_WORLD" then
    UpdateGroupState()
    RefreshPerm()
  else
    UpdateGroupState()   -- party / raid roster changed
  end
end)

local function PrintStatus()
  Msg(string.format("GUID=%s | combat log events=%d, from you=%d, crits=%d | best dmg=%d heal=%d | popups active=%d",
    tostring(UnitGUID("player")), stats.events, stats.mine, stats.crits, dmgRecord, healRecord, #active))
end

-- ========= Clear this hero's data (with an "are you sure" box) =========
local function ClearHeroData()
  local h = Hero()
  h.best = {}
  h.grp = {}
  alwaysHidden.dmg, alwaysHidden.heal = false, false
  dmgRecord, healRecord = 0, 0
  ClearPops()
  RefreshPerm()
  if RefreshHeroSheet then RefreshHeroSheet() end
  Msg("cleared all saved records of |cffffffff" .. (UnitName("player") or "?") .. "|r. Other heroes are untouched.")
end

StaticPopupDialogs["CRITTERS_CLEAR_HERO"] = {
  text = "Critters: delete ALL saved crit records of %s?\n\nThis cannot be undone. Your other heroes keep their records.",
  button1 = "Yes, clear",
  button2 = "Cancel",
  OnAccept = function() ClearHeroData() end,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
  showAlert = 1,
}

-- ========= Font list (shared by all pickers) =========
local fontList = {}
local warnedNoLSM = false
local warnedHidden = false

local function BuildFontList()
  local list, seen, extras = {}, {}, {}
  local hidden = 0

  local function add(target, name, path)
    if type(path) ~= "string" then return end
    path = string.gsub(path, "/", "\\")
    local key = string.lower(path)
    if seen[key] then return end
    seen[key] = true

    if not IsValidFont(path) then
      hidden = hidden + 1
      return
    end

    target[#target + 1] = { name = name, path = path }
  end

  for _, font in ipairs(BUILTIN) do
    add(list, font.name, font.path)
  end

  local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
  if LSM then
    local ok, hash = pcall(LSM.HashTable, LSM, "font")
    if ok and type(hash) == "table" then
      for name, path in pairs(hash) do
        add(extras, name, path)
      end
    end
  end

  table.sort(extras, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
  for _, font in ipairs(extras) do list[#list + 1] = font end
  return list, LSM ~= nil, hidden
end

-- ========= Options window =========
local WIN_W, WIN_H = 360, 520
local SHEET_ROWS = 7          -- visible rows of the all-time list
local SHEET_HDR = 18          -- height of its column header strip
local ROW_H = 18
local frame
local pickers = {}
local outerWheel   -- set by the window: scrolls the whole options page

-- ----- tooltips: hover any setting for a short explanation -----
local function SetTip(f, title, text)
  if not f or not text then return end
  f.tipTitle, f.tipText = title, text
  if f.tipHooked then return end
  f.tipHooked = true
  f:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.tipTitle, 1, 1, 1)
    GameTooltip:AddLine(self.tipText, 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  f:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- gives a plain text label its own tooltip (invisible frame laid over the text)
local function TipLabel(parent, fs, title, text)
  local h = CreateFrame("Frame", nil, parent)
  h:SetPoint("TOPLEFT", fs, "TOPLEFT", 0, 0)
  h:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 0, 0)
  h:EnableMouse(true)
  SetTip(h, title, text)
end

-- ----- small widget helpers (all stretch with the window width) -----
local function MakeButton(parent, text, w, h)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(w)
  b:SetHeight(h)
  b:SetBackdrop(FLAT)
  b:SetBackdropColor(0.16, 0.16, 0.19, 1)
  b:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
  b.label:SetText(text)
  b:SetScript("OnEnter", function(self) self:SetBackdropColor(0.26, 0.26, 0.31, 1) end)
  b:SetScript("OnLeave", function(self) self:SetBackdropColor(0.16, 0.16, 0.19, 1) end)
  return b
end

local function MakeSlider(parent, label, y, minV, maxV, step, value, fmt, onChange, tip)
  local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
  lbl:SetText(label)
  lbl:SetTextColor(0.75, 0.75, 0.75)

  local val = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  val:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y)

  local s = CreateFrame("Slider", nil, parent)
  s:SetOrientation("HORIZONTAL")
  s:SetHeight(12)
  s:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y - 16)
  s:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y - 16)
  s:EnableMouse(true)
  s:SetBackdrop(FLAT)
  s:SetBackdropColor(0.08, 0.08, 0.1, 1)
  s:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)
  s:SetThumbTexture(WHITE)
  local thumb = s:GetThumbTexture()
  thumb:SetWidth(8)
  thumb:SetHeight(14)
  thumb:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  if value < minV then value = minV end
  if value > maxV then value = maxV end
  s:SetMinMaxValues(minV, maxV)
  s:SetValueStep(step)
  s:SetValue(value)
  val:SetText(string.format(fmt, value))

  s:SetScript("OnValueChanged", function(self, v)
    v = Round(v, step)
    val:SetText(string.format(fmt, v))
    onChange(v)
  end)
  if tip then
    SetTip(s, label, tip)
    TipLabel(parent, lbl, label, tip)
  end
  return s
end

local function MakeCheckbox(parent, label, y, checked, onClick, x, tip)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(16)
  b:SetHeight(16)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x or 14, y)
  b:SetBackdrop(FLAT)
  b:SetBackdropColor(0.08, 0.08, 0.1, 1)
  b:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)

  local mark = b:CreateTexture(nil, "OVERLAY")
  mark:SetTexture(WHITE)
  mark:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  mark:SetPoint("TOPLEFT", b, "TOPLEFT", 4, -4)
  mark:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 4)

  local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  text:SetPoint("LEFT", b, "RIGHT", 8, 0)
  text:SetText(label)

  local state = checked and true or false
  local function paint()
    if state then mark:Show() else mark:Hide() end
  end
  paint()

  b:SetScript("OnClick", function()
    state = not state
    paint()
    onClick(state)
  end)
  if tip then   -- the tooltip (and click) also covers the label text
    local hit = CreateFrame("Button", nil, parent)
    hit:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
    hit:SetPoint("BOTTOMRIGHT", text, "BOTTOMRIGHT", 2, 0)
    hit:SetScript("OnClick", function() b:Click() end)
    SetTip(hit, label, tip)
  end
  return b
end

-- color picker (Blizzard's ColorPickerFrame)
local function OpenColorPicker(current, onChange)
  local r, g, b = current[1], current[2], current[3]
  ColorPickerFrame:Hide()
  ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
  ColorPickerFrame.hasOpacity = false
  ColorPickerFrame.opacityFunc = nil
  ColorPickerFrame.previousValues = { r, g, b }
  ColorPickerFrame.func = function()
    local nr, ng, nb = ColorPickerFrame:GetColorRGB()
    onChange(nr, ng, nb)
  end
  ColorPickerFrame.cancelFunc = function(prev)
    prev = prev or { r, g, b }
    onChange(prev[1], prev[2], prev[3])
  end
  ColorPickerFrame:SetColorRGB(r, g, b)
  ColorPickerFrame:Show()
end

local function MakeSwatch(parent, label, y, getColor, setColor, tip)
  local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  text:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y - 3)
  text:SetText(label)

  local b = MakeButton(parent, "", 60, 18)
  b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y)
  local tex = b:CreateTexture(nil, "ARTWORK")
  tex:SetTexture(WHITE)
  tex:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -3)
  tex:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)

  local function paint()
    local c = getColor()
    tex:SetVertexColor(c[1], c[2], c[3], 1)
  end
  paint()

  b:SetScript("OnClick", function()
    OpenColorPicker(getColor(), function(r, g, bl)
      setColor({ r, g, bl })
      paint()
    end)
  end)
  if tip then
    SetTip(b, label, tip)
    TipLabel(parent, text, label, tip)
  end
  return b
end

-- two-column grid of choice buttons (radio style). Returns its height.
local function MakeChoiceGrid(parent, y, list, getKey, setKey)
  local btns = {}
  local function paint()
    local cur = getKey()
    for _, b in ipairs(btns) do
      if b.key == cur then
        b:SetBackdropColor(ACCENT[1] * 0.5, ACCENT[2] * 0.5, ACCENT[3] * 0.5, 1)
        b:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
      else
        b:SetBackdropColor(0.16, 0.16, 0.19, 1)
        b:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
      end
    end
  end

  for i, st in ipairs(list) do
    local b = MakeButton(parent, st.name, 110, 18)
    local row = math.floor((i - 1) / 2)
    local col = (i - 1) % 2
    -- both columns hang from the LEFT so resizing the window never moves them
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", 14 + col * 118, y - row * 22)
    b.key = st.key
    b:SetScript("OnLeave", function() paint() end)
    b:SetScript("OnEnter", function(self)
      if self.key ~= getKey() then self:SetBackdropColor(0.26, 0.26, 0.31, 1) end
    end)
    b:SetScript("OnClick", function(self)
      setKey(self.key)
      paint()
    end)
    SetTip(b, st.name, st.tip)
    btns[#btns + 1] = b
  end
  paint()
  return math.ceil(#list / 2) * 22
end

-- row of three buttons: Unlock/Lock, Test dmg, Test heal
local function MakeActionRow(parent, y, kind, testFn, testTip, single)
  local mv = MakeButton(parent, "Unlock", 80, 22)
  mv:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
  mv:SetScript("OnClick", function()
    SetMoveMode(kind, not IsMoving(kind))
  end)
  mv:SetScript("OnEnter", function(self)
    if not IsMoving(kind) then self:SetBackdropColor(0.26, 0.26, 0.31, 1) end
  end)
  mv:SetScript("OnLeave", function() PaintMoveButton(kind) end)
  moveButtons[kind] = mv
  PaintMoveButton(kind)   -- lit while its box is out
  SetTip(mv, "Unlock / Lock", (kind == "perm")
    and "Unlock shows a draggable box for each ticked permanent number. Drag it where you want it, then press Lock."
    or  "Unlock shows a draggable box with a sample number. Drag it where you want it, then press Lock to save the spot.")

  -- small square right of Unlock / Lock: puts the number in the middle of the screen
  local rs = MakeButton(parent, "", 22, 22)
  rs:SetPoint("TOPLEFT", parent, "TOPLEFT", 98, y)
  local rsTex = rs:CreateTexture(nil, "ARTWORK")
  rsTex:SetTexture(WHITE)
  rsTex:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  rsTex:SetWidth(6)
  rsTex:SetHeight(6)
  rsTex:SetPoint("CENTER", rs, "CENTER", 0, 0)
  rs:SetScript("OnClick", function()
    if kind == "perm" then
      CenterAnchor("permDmg", 0)
      CenterAnchor("permHeal", -60)   -- the heal number sits just below so the two do not overlap
      if RefreshPerm then RefreshPerm() end
    else
      CenterAnchor(kind, 0)
    end
  end)
  SetTip(rs, "Reset position", "Puts it back in the center of the screen.")

  local t1 = MakeButton(parent, single and "Test streak" or "Test dmg", 80, 22)
  t1:SetPoint("TOPLEFT", parent, "TOPLEFT", 126, y)
  t1:SetScript("OnClick", function() testFn(false) end)
  SetTip(t1, single and "Test crit streak" or "Test damage", testTip)
  if single then return end   -- the crit streak has no heal version

  local t2 = MakeButton(parent, "Test heal", 80, 22)
  t2:SetPoint("TOPLEFT", parent, "TOPLEFT", 214, y)
  t2:SetScript("OnClick", function() testFn(true) end)
  SetTip(t2, "Test heal", testTip)
end

-- ----- font picker (an independent list + preview, optional own search box) -----
-- R = number of visible rows. Returns the picker; P.height is its body height.
local function MakeFontPicker(parent, getPath, onSelect, inlineSearch, R)
  local P = { shown = {}, offset = 0, filter = "", rows = {} }
  local top = 0
  local scrollbar, preview

  local function Update()
    local current = string.lower(getPath() or DEFAULT_FONT)
    for i = 1, R do
      local row = P.rows[i]
      local font = P.shown[P.offset + i]
      if font then
        row.font = font
        row.text:SetText(font.name)
        if string.lower(font.path) == current then
          row.bg:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.35)
          row.text:SetTextColor(1, 1, 1)
        else
          row.bg:SetVertexColor(0, 0, 0, 0)
          row.text:SetTextColor(0.8, 0.8, 0.8)
        end
        row:Show()
      else
        row.font = nil
        row:Hide()
      end
    end
  end
  P.Update = Update

  function P.SetPreview(path)
    if not preview then return end
    if preview:SetFont(path, 18, "OUTLINE") then
      preview:SetText("1,234,567")
      preview:SetTextColor(1, 1, 1)
    else
      preview:SetFont(DEFAULT_FONT, 12, "")
      preview:SetText("font file not found")
      preview:SetTextColor(1, 0.3, 0.3)
    end
  end

  function P.Rebuild()
    for i = #P.shown, 1, -1 do P.shown[i] = nil end
    local q = string.lower(P.filter)
    for _, font in ipairs(fontList) do
      if q == "" or string.find(string.lower(font.name), q, 1, true) then
        P.shown[#P.shown + 1] = font
      end
    end
    local maxOffset = math.max(0, #P.shown - R)
    scrollbar:SetMinMaxValues(0, maxOffset)
    scrollbar:SetValue(0)
    P.offset = 0
    if maxOffset > 0 then scrollbar:Show() else scrollbar:Hide() end
    Update()
  end

  function P.SetFilter(text)
    P.filter = text or ""
    P.Rebuild()
  end

  function P.ScrollToCurrent()
    local current = string.lower(getPath() or DEFAULT_FONT)
    for i, font in ipairs(P.shown) do
      if string.lower(font.path) == current then
        scrollbar:SetValue(math.max(0, math.min(#P.shown - R, i - 3)))
        return
      end
    end
  end

  if inlineSearch then
    local search = CreateFrame("EditBox", nil, parent)
    search:SetFontObject(GameFontHighlightSmall)
    search:SetHeight(20)
    search:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, 0)
    search:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, 0)
    search:SetBackdrop(FLAT)
    search:SetBackdropColor(0.08, 0.08, 0.1, 1)
    search:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)
    search:SetTextInsets(6, 6, 0, 0)
    search:SetAutoFocus(false)
    search:SetMaxLetters(40)

    local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", search, "LEFT", 6, 0)
    hint:SetText("Search fonts...")

    search:SetScript("OnTextChanged", function(self)
      local txt = self:GetText() or ""
      if txt == "" and not self:HasFocus() then hint:Show() else hint:Hide() end
      P.SetFilter(txt)
    end)
    search:SetScript("OnEditFocusGained", function() hint:Hide() end)
    search:SetScript("OnEditFocusLost", function(self)
      if (self:GetText() or "") == "" then hint:Show() end
    end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    SetTip(search, "Search fonts", "Type part of a font name to filter this list.")
    top = 24
  end

  local list = CreateFrame("Frame", nil, parent)
  list:SetHeight(R * ROW_H)
  list:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, -top)
  list:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -26, -top)
  list:EnableMouseWheel(true)
  local listBg = list:CreateTexture(nil, "BACKGROUND")
  listBg:SetAllPoints(list)
  listBg:SetTexture(WHITE)
  listBg:SetVertexColor(0.09, 0.09, 0.11, 1)

  scrollbar = CreateFrame("Slider", nil, parent)
  scrollbar:SetOrientation("VERTICAL")
  scrollbar:SetWidth(8)
  scrollbar:SetHeight(R * ROW_H)
  scrollbar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, -top)
  scrollbar:EnableMouse(true)
  scrollbar:SetBackdrop(FLAT)
  scrollbar:SetBackdropColor(0.09, 0.09, 0.11, 1)
  scrollbar:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)
  scrollbar:SetThumbTexture(WHITE)
  local sthumb = scrollbar:GetThumbTexture()
  sthumb:SetWidth(8)
  sthumb:SetHeight(26)
  sthumb:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  scrollbar:SetMinMaxValues(0, 0)
  scrollbar:SetValueStep(1)
  scrollbar:SetValue(0)
  scrollbar:SetScript("OnValueChanged", function(self, value)
    P.offset = math.floor(value + 0.5)
    Update()
  end)

  list:SetScript("OnMouseWheel", function(self, delta)
    if scrollbar:IsShown() then
      scrollbar:SetValue(scrollbar:GetValue() - delta * 2)
    elseif outerWheel then
      outerWheel(delta) -- short list: let the whole page scroll instead
    end
  end)

  preview = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  preview:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, -(top + R * ROW_H + 6))
  preview:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, -(top + R * ROW_H + 6))
  preview:SetJustifyH("CENTER")
  preview:SetHeight(24)
  preview.noScale = true

  for i = 1, R do
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, -(i - 1) * ROW_H)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    row.bg:SetTexture(WHITE)
    row.bg:SetVertexColor(0, 0, 0, 0)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetTexture(WHITE)
    hl:SetVertexColor(1, 1, 1, 0.08)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.text:SetHeight(ROW_H)
    row.text:SetJustifyH("LEFT")

    row:SetScript("OnClick", function(self)
      if not self.font then return end
      if not IsValidFont(self.font.path) then
        Msg("can't load |cffffffff" .. self.font.name .. "|r. Check that the file exists in the Fonts folder.")
        return
      end
      onSelect(self.font)
      Update()
      P.SetPreview(self.font.path)
    end)
    row:SetScript("OnEnter", function(self)
      if self.font then P.SetPreview(self.font.path) end
    end)
    row:SetScript("OnLeave", function()
      P.SetPreview(getPath() or DEFAULT_FONT)
    end)

    P.rows[i] = row
  end

  P.height = top + R * ROW_H + 34
  P.getPath = getPath
  pickers[#pickers + 1] = P
  return P
end

-- sliders show 1-10, the real value is stored in the saved variables
local function ToLevel(v, lo, hi)
  local l = math.floor((v - lo) / (hi - lo) * 9 + 1.5)
  return math.max(1, math.min(10, l))
end
local function FromLevel(l, lo, hi)
  return math.floor(lo + (l - 1) * (hi - lo) / 9 + 0.5)
end

-- Options window size: slider 1-10 scales the WHOLE window (text, buttons, everything) like a
-- picture. 1 = a bit smaller than normal, 3 = normal (100%), 10 = bigger but not too big.
local UI_SCALES = { 0.90, 0.95, 1.00, 1.04, 1.09, 1.13, 1.17, 1.22, 1.26, 1.30 }
local function UiLevelToScale(l) return UI_SCALES[math.max(1, math.min(10, l))] end
local function UiScaleToLevel(sc)
  local best, bd = 3, 99
  for l = 1, 10 do
    local d = math.abs(UI_SCALES[l] - sc)
    if d < bd then best, bd = l, d end
  end
  return best
end

-- scales the options window, keeping its top-left corner where it is
local function ApplyUIScale(f)
  local scale = CrittersDB.uiScale or 1
  local left, top, eff0 = f:GetLeft(), f:GetTop(), f:GetEffectiveScale()
  f:SetScale(scale)
  if left and top then
    local eff1 = f:GetEffectiveScale()
    local x, y = left * eff0 / eff1, top * eff0 / eff1
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    CrittersDB.winPos = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = x, y = y }
  end
end

-- ========= Share window: pick where to send a record =========
local shareFrame

local function OpenShare(text, label)
  if not shareFrame then
    local f = CreateFrame("Frame", "CrittersShare", UIParent)
    f:SetWidth(230)
    f:SetHeight(118)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetBackdrop(FLAT)
    f:SetBackdropColor(0.06, 0.06, 0.08, 0.97)
    f:SetBackdropBorderColor(0.2, 0.2, 0.25, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "CrittersShare")   -- Esc closes it

    local bar = f:CreateTexture(nil, "ARTWORK")
    bar:SetTexture(WHITE)
    bar:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    bar:SetHeight(2)
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    f.title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -10)
    f.title:SetJustifyH("LEFT")
    f.title:SetHeight(14)

    local close = MakeButton(f, "x", 18, 18)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() f:Hide() end)

    local function Done(msg)
      Msg(msg)
      f:Hide()
    end

    local function ChannelBtn(text, col, y, channel, canSend)
      local b = MakeButton(f, text, 100, 22)
      b:SetPoint("TOPLEFT", f, "TOPLEFT", col == 1 and 12 or 118, y)
      b:SetScript("OnClick", function()
        if canSend and not canSend() then
          Msg("you are not in a " .. string.lower(text) .. ".")
          return
        end
        SendChatMessage(f.text, channel)
        Done("sent to " .. string.lower(text) .. ".")
      end)
      b.canSend = canSend
      return b
    end

    -- Whisper: shows a name bar; Enter (or Send) whispers the link to that player
    local nameRow = CreateFrame("Frame", nil, f)
    nameRow:SetHeight(24)
    nameRow:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -116)
    nameRow:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -116)
    nameRow:Hide()

    local box = CreateFrame("EditBox", nil, nameRow)
    box:SetFontObject(GameFontHighlightSmall)
    box:SetHeight(22)
    box:SetPoint("TOPLEFT", nameRow, "TOPLEFT", 0, 0)
    box:SetPoint("TOPRIGHT", nameRow, "TOPRIGHT", -56, 0)
    box:SetBackdrop(FLAT)
    box:SetBackdropColor(0.20, 0.20, 0.25, 1)
    box:SetBackdropBorderColor(0.50, 0.50, 0.58, 1)
    box:SetTextInsets(6, 6, 0, 0)
    box:SetAutoFocus(false)
    box:SetMaxLetters(24)

    local function SendWhisper()
      local name = string.gsub(box:GetText() or "", "%s", "")
      if name == "" then
        Msg("type a player name first.")
        return
      end
      SendChatMessage(f.text, "WHISPER", nil, name)
      Done("whispered to " .. name .. ".")
    end
    box:SetScript("OnEnterPressed", SendWhisper)
    box:SetScript("OnEscapePressed", function() f:Hide() end)

    local send = MakeButton(nameRow, "Send", 50, 22)
    send:SetPoint("TOPRIGHT", nameRow, "TOPRIGHT", 0, 0)
    send:SetScript("OnClick", SendWhisper)

    local wb = MakeButton(f, "Whisper", 100, 22)
    wb:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -34)
    wb:SetScript("OnClick", function()
      f:SetHeight(148)
      nameRow:Show()
      if (box:GetText() or "") == "" and UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
        box:SetText(UnitName("target") or "")
      end
      box:SetFocus()
    end)

    ChannelBtn("Say",   2, -34, "SAY")
    ChannelBtn("Yell",  1, -62, "YELL")
    f.party = ChannelBtn("Party", 2, -62, "PARTY", function() return GetNumPartyMembers() > 0 end)
    f.raid  = ChannelBtn("Raid",  1, -90, "RAID",  function() return GetNumRaidMembers() > 0 end)

    f.nameRow, f.box = nameRow, box
    f:SetScript("OnShow", function(self)
      -- Party / Raid look dimmed when you are not in one
      self.party:SetAlpha(GetNumPartyMembers() > 0 and 1 or 0.4)
      self.raid:SetAlpha(GetNumRaidMembers() > 0 and 1 or 0.4)
    end)
    shareFrame = f
  end

  local f = shareFrame
  f.text = text
  f.title:SetText("Share: " .. (label or "record"))
  f.nameRow:Hide()
  f.box:ClearFocus()
  f:SetHeight(118)
  f:Show()
end

local function BuildWindow()
  local f = CreateFrame("Frame", "CrittersOptions", UIParent)
  f:Hide()
  f:SetScale(CrittersDB.uiScale or 1)   -- the whole window scales (see ApplyUIScale)
  f:SetWidth(CrittersDB.winW or WIN_W)
  f:SetHeight(CrittersDB.winH or WIN_H)
  f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 200, -100)
  local wp = CrittersDB.winPos
  if type(wp) == "table" and wp.point then
    f:ClearAllPoints()
    f:SetPoint(wp.point, UIParent, wp.relPoint or wp.point, wp.x or 0, wp.y or 0)
  end
  f:SetFrameStrata("DIALOG")
  f:SetBackdrop(FLAT)
  f:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
  f:SetBackdropBorderColor(0.2, 0.2, 0.25, 1)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetResizable(true)
  f:SetMinResize(280, 260)
  f:SetMaxResize(560, 900)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    CrittersDB.winPos = { point = point, relPoint = relPoint, x = x, y = y }
  end)
  tinsert(UISpecialFrames, "CrittersOptions") -- close with Esc

  CrittersDB.sections = CrittersDB.sections or {}

  local bar = f:CreateTexture(nil, "ARTWORK")
  bar:SetTexture(WHITE)
  bar:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  bar:SetHeight(2)
  bar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
  title:SetText("Critters")

  local close = MakeButton(f, "x", 18, 18)
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
  close:SetScript("OnClick", function() f:Hide() end)

  -- ----- scrolling page that holds all sections -----
  local sf = CreateFrame("ScrollFrame", nil, f)
  sf:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -62)
  sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 22)
  sf:EnableMouseWheel(true)

  local content = CreateFrame("Frame", nil, sf)
  content:SetWidth((CrittersDB.winW or WIN_W) - 20)
  content:SetHeight(400)
  sf:SetScrollChild(content)

  local sbar = CreateFrame("Slider", nil, f)
  sbar:SetOrientation("VERTICAL")
  sbar:SetWidth(8)
  sbar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -64)
  sbar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 24)
  sbar:EnableMouse(true)
  sbar:SetBackdrop(FLAT)
  sbar:SetBackdropColor(0.09, 0.09, 0.11, 1)
  sbar:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)
  sbar:SetThumbTexture(WHITE)
  local pthumb = sbar:GetThumbTexture()
  pthumb:SetWidth(8)
  pthumb:SetHeight(30)
  pthumb:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
  sbar:SetMinMaxValues(0, 0)
  sbar:SetValueStep(1)
  sbar:SetValue(0)
  sbar:SetScript("OnValueChanged", function(self, value)
    sf:SetVerticalScroll(value)
  end)

  local function UpdateScroll()
    local maxScroll = math.max(0, content:GetHeight() - sf:GetHeight())
    sbar:SetMinMaxValues(0, maxScroll)
    if sbar:GetValue() > maxScroll then sbar:SetValue(maxScroll) end
    if maxScroll > 0 then sbar:Show() else sbar:Hide() end
  end

  outerWheel = function(delta)
    sbar:SetValue(sbar:GetValue() - delta * 36)
  end
  sf:SetScript("OnMouseWheel", function(self, delta) outerWheel(delta) end)

  sf:SetScript("OnSizeChanged", function(self, w, h)
    content:SetWidth(w)
    UpdateScroll()
  end)

  -- ----- collapsible sections (with optional smaller sub-sections) -----
  local sections = {}
  local gameSec, gamePicker
  local note, sheet

  local function Relayout()
    local y = 4
    for _, s in ipairs(sections) do
      s.header:ClearAllPoints()
      s.header:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -y)
      s.header:SetPoint("TOPRIGHT", content, "TOPRIGHT", -14, -y)
      s.update()
      y = y + 22
      if s.open then
        -- body height = own options + its sub-sections underneath
        local bh = s.height
        for _, c in ipairs(s.children) do
          c.header:ClearAllPoints()
          c.header:SetPoint("TOPLEFT", s.body, "TOPLEFT", 24, -bh)
          c.header:SetPoint("TOPRIGHT", s.body, "TOPRIGHT", -24, -bh)
          c.update()
          bh = bh + 20
          if c.open then
            c.body:ClearAllPoints()
            c.body:SetPoint("TOPLEFT", s.body, "TOPLEFT", 10, -bh)
            c.body:SetPoint("TOPRIGHT", s.body, "TOPRIGHT", -10, -bh)
            c.body:Show()
            bh = bh + c.height + 4
          else
            c.body:Hide()
          end
        end
        s.body:SetHeight(bh)
        s.body:ClearAllPoints()
        s.body:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        s.body:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
        s.body:Show()
        y = y + bh + 4
      else
        s.body:Hide()
      end
    end
    y = y + 6
    -- the always-open all-time list sits right under General
    if sheet then
      sheet:ClearAllPoints()
      sheet:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -y)
      sheet:SetPoint("TOPRIGHT", content, "TOPRIGHT", -14, -y)
      y = y + SHEET_HDR + SHEET_ROWS * ROW_H + 12 + 8
    end
    note:ClearAllPoints()
    note:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -y)
    note:SetPoint("TOPRIGHT", content, "TOPRIGHT", -14, -y)
    y = y + 26
    content:SetHeight(y)
    UpdateScroll()
  end

  local function AddSection(key, titleText, height, tip)
    local s = { key = key, height = height, children = {} }
    s.open = CrittersDB.sections[key] and true or false
    for _, o in ipairs(sections) do   -- old saves may have several open: first one wins
      if s.open and o.open then s.open = false end
    end

    local h = MakeButton(content, "", 100, 20)
    s.header = h   -- (the name stays centered, like MakeButton puts it)
    SetTip(h, titleText, tip)
    s.update = function()
      h.label:SetText(titleText)
    end

    s.body = CreateFrame("Frame", nil, content)
    s.body:SetHeight(height)

    -- accordion: opening one parent tab closes all the others
    h:SetScript("OnClick", function()
      local opening = not s.open
      for _, o in ipairs(sections) do
        o.open = false
        CrittersDB.sections[o.key] = false
      end
      s.open = opening
      CrittersDB.sections[key] = opening
      Relayout()
    end)

    sections[#sections + 1] = s
    return s
  end

  -- a smaller, indented tab that lives inside its parent section's body
  local function AddSubSection(parent, key, titleText, height, tip)
    local c = { key = key, height = height }
    c.open = CrittersDB.sections[key] and true or false

    local h = MakeButton(parent.body, "", 100, 16)
    h:SetBackdropColor(0.12, 0.12, 0.15, 1)
    h:SetScript("OnLeave", function(self) self:SetBackdropColor(0.12, 0.12, 0.15, 1) end)
    h.label:SetTextColor(0.8, 0.8, 0.8)
    c.header = h
    SetTip(h, titleText, tip)
    c.update = function()
      h.label:SetText(titleText)
    end

    c.body = CreateFrame("Frame", nil, parent.body)
    c.body:SetHeight(height)

    h:SetScript("OnClick", function()
      c.open = not c.open
      CrittersDB.sections[key] = c.open
      Relayout()
    end)

    parent.children[#parent.children + 1] = c
    return c
  end

  -- ----- top search box: filters the GAME font list and opens that section -----
  local search = CreateFrame("EditBox", nil, f)
  search:SetFontObject(GameFontHighlightSmall)
  search:SetHeight(20)
  search:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -36)
  search:SetPoint("TOPRIGHT", f, "TOPRIGHT", -34, -36)
  search:SetBackdrop(FLAT)
  search:SetBackdropColor(0.08, 0.08, 0.1, 1)
  search:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)
  search:SetTextInsets(6, 6, 0, 0)
  search:SetAutoFocus(false)
  search:SetMaxLetters(40)

  local hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("LEFT", search, "LEFT", 6, 0)
  hint:SetText("Search game combat text fonts...")

  search:SetScript("OnTextChanged", function(self)
    local txt = self:GetText() or ""
    if txt == "" and not self:HasFocus() then hint:Show() else hint:Hide() end
    if txt ~= "" and gameSec and not gameSec.open then
      for _, o in ipairs(sections) do
        o.open = false
        CrittersDB.sections[o.key] = false
      end
      gameSec.open = true
      CrittersDB.sections.gamefont = true
      Relayout()
    end
    if gamePicker then gamePicker.SetFilter(txt) end
  end)
  search:SetScript("OnEditFocusGained", function() hint:Hide() end)
  search:SetScript("OnEditFocusLost", function(self)
    if (self:GetText() or "") == "" then hint:Show() end
  end)
  search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  SetTip(search, "Search fonts", "Type part of a font name to filter the game combat text fonts. This opens the Game combat text font tab.")

  -- ================= Section: Game combat text font =================
  gameSec = AddSection("gamefont", "Game combat text font", 6 * ROW_H + 34,
    "Font of the game's own floating combat text. Needs a full log out and back in to apply.")
  gamePicker = MakeFontPicker(gameSec.body,
    function() return CrittersDB.damageFont end,
    function(font)
      CrittersDB.damageFont = font.path
      DAMAGE_TEXT_FONT = font.path
      Msg(font.name .. " selected for the GAME's combat text. Log out and back in to see it (/reload is not enough). Popups have their own fonts.")
    end,
    false, 6)

  -- ================= Section: Effects =================
  local fx = AddSection("effects", "Pop-up effects", 290,
    "Pick the animation style for normal crits and the Crit Streak. The record crit always slides up out of the streak.")
  do
    local b = fx.body

    local y2 = 0
    local l2 = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l2:SetPoint("TOPLEFT", b, "TOPLEFT", 14, y2)
    l2:SetText("Normal crit effect")
    l2:SetTextColor(0.75, 0.75, 0.75)

    local h2 = MakeChoiceGrid(b, y2 - 16, CRIT_STYLES,
      function() return CrittersDB.critStyle end,
      function(k) CrittersDB.critStyle = k; PreviewCrit(false) end)

    local y3 = y2 - 16 - h2 - 6
    local l3 = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l3:SetPoint("TOPLEFT", b, "TOPLEFT", 14, y3)
    l3:SetText("Crit streak effect (first crit)")
    l3:SetTextColor(0.75, 0.75, 0.75)

    local h3 = MakeChoiceGrid(b, y3 - 16, STREAK_STYLES,
      function() return CrittersDB.streakStyle end,
      function(k) CrittersDB.streakStyle = k; StreakPreviewAppear() end)

    local y4 = y3 - 16 - h3 - 6
    local l4 = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l4:SetPoint("TOPLEFT", b, "TOPLEFT", 14, y4)
    l4:SetText("Crit streak pop 2 (every crit after)")
    l4:SetTextColor(0.75, 0.75, 0.75)

    MakeChoiceGrid(b, y4 - 16, STREAK_HIT_STYLES,
      function() return CrittersDB.streakHitStyle end,
      function(k) CrittersDB.streakHitStyle = k; StreakPreviewHit() end)
  end

  -- height of a font picker body with its own search box and 5 visible rows
  local PICKER_H = 24 + 5 * ROW_H + 34

  -- ================= Section: Normal crit =================
  local crit = AddSection("crit", "Normal crit", 178,
    "Smaller popups for every ordinary crit: on/off, size, spacing, colors and a test button.")
  do
    local b = crit.body

    MakeCheckbox(b, "Show normal crit popups", 0, CrittersDB.critPop ~= false,
      function(v) CrittersDB.critPop = v end)

    MakeSlider(b, "Size", -26, 1, 10, 1, ToLevel(CrittersDB.critSize or NORMAL_CRIT_SIZE, SIZE_MIN, SIZE_MAX), "%d",
      function(l)
        local v = FromLevel(l, SIZE_MIN, SIZE_MAX)
        if CrittersDB.critSize ~= v then
          CrittersDB.critSize = v
          PaintAnchor("crit")
          PreviewCrit(false)
        end
      end, "How big normal crit numbers are. Higher = bigger.")

    MakeSlider(b, "Space between digits", -62, 1, 10, 1, ToLevel(CrittersDB.critSpacing or CrittersDB.digitSpacing or 80, 20, 80), "%d",
      function(l)
        local v = FromLevel(l, 20, 80)
        if CrittersDB.critSpacing ~= v then
          CrittersDB.critSpacing = v
          PreviewCrit(false)
        end
      end, "Gap between the digits of normal crit numbers. Lower = tighter.")

    MakeSwatch(b, "Damage color", -96,
      function() return GetColor("crit", false) end,
      function(c) CrittersDB.critColor = c; PaintAnchor("crit") end, "Color of normal damage crit numbers.")

    MakeSwatch(b, "Heal color", -120,
      function() return GetColor("crit", true) end,
      function(c) CrittersDB.critHealColor = c end, "Color of normal heal crit numbers.")

    MakeActionRow(b, -148, "crit", PreviewCrit, "Shows a sample normal crit with your current settings.")
  end

  local critFont = AddSubSection(crit, "critfont", "Normal crit font", PICKER_H,
    "Font used for normal crit popups.")
  MakeFontPicker(critFont.body,
    function() return CrittersDB.critFont end,
    function(font)
      CrittersDB.critFont = font.path
      PaintAnchor("crit")
      PreviewCrit(false)
    end,
    true, 5)

  -- ================= Section: Crit Streak (and the record crit above it) =================
  local streakSec = AddSection("streak", "Crit Streak", 320,
    "The crit streak counter and your best crit of the fight (the record crit) that slides up above it: sizes, time on screen, colors, position and test buttons. Animations are in Pop-up effects.")
  do
    local b = streakSec.body

    MakeCheckbox(b, "Show crit streak", 0, CrittersDB.streakEnabled ~= false,
      function(v)
        CrittersDB.streakEnabled = v
        if not v then StreakReset() end
      end, nil, "Turns the Crit Streak on or off.")

    MakeSlider(b, "Size", -26, 1, 10, 1, ToLevel(CrittersDB.streakSize or STREAK_SIZE, SIZE_MIN, SIZE_MAX), "%d",
      function(l)
        local v = FromLevel(l, SIZE_MIN, SIZE_MAX)
        if CrittersDB.streakSize ~= v then
          CrittersDB.streakSize = v
          StreakRefresh()
        end
      end, "How big the streak damage total is. The x1, x2 counter next to it is 70% of this size. The record crit above it uses the same size.")

    MakeSlider(b, "Space between digits", -62, 1, 10, 1,
      ToLevel(CrittersDB.streakSpacing or CrittersDB.recordSpacing or CrittersDB.digitSpacing or 80, 20, 80), "%d",
      function(l)
        local v = FromLevel(l, 20, 80)
        if CrittersDB.streakSpacing ~= v then
          CrittersDB.streakSpacing = v
          StreakRefresh()
        end
      end, "Gap between the digits of the crit streak and the record crit above it. Lower = tighter.")

    MakeCheckbox(b, "Show record crit above the streak", -98, CrittersDB.recordEnabled ~= false,
      function(v)
        CrittersDB.recordEnabled = v
        if not v then ClearPops("record") end
      end, nil, "Shows your best crit of the current fight sliding up above the Crit Streak. While off, a record hit shows as a normal crit. The permanent numbers are not affected.")

    MakeSlider(b, "Record crits per combat time on screen", -124, 1, 10, 0.5, CrittersDB.recordHold or 4, "%.1fs",
      function(v) CrittersDB.recordHold = v end,
      "How many seconds your best crit of the current combat stays above the Crit Streak before it fades or flies to its permanent spot. A new best crit in the same fight replaces it and restarts this timer.")

    MakeSwatch(b, "Streak damage color", -160,
      function() return streak.Color(false) end,
      function(c) CrittersDB.streakColor = c; StreakRefresh(false) end,
      "Color of the big streak number while your latest streak crit is a damage crit. Until you pick one it uses the normal damage crit color.")

    MakeSwatch(b, "Streak heal color", -184,
      function() return streak.Color(true) end,
      function(c) CrittersDB.streakHealColor = c; StreakRefresh(true) end,
      "Color of the big streak number while your latest streak crit is a heal crit. Until you pick one it uses the normal heal crit color.")

    MakeActionRow(b, -214, "streak", function() StreakTest() end,
      "Shows a streak. Press it again within 5 seconds to see the pop of the next crit.", true)

    local tr = MakeButton(b, "Test record", 90, 22)
    tr:SetPoint("TOPLEFT", b, "TOPLEFT", 214, -214)
    tr:SetScript("OnClick", function()
      if anchors.streak:IsShown() then SetMoveMode("streak", false) end
      if streak.phase ~= "live" then StreakHit(math.random(1, 100000)) end
      TestRecord(false)
    end)
    SetTip(tr, "Test record crit", "Shows a streak and a sample record crit sliding up above it, with your current settings.")

    local info = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    info:SetPoint("TOPLEFT", b, "TOPLEFT", 14, -246)
    info:SetPoint("TOPRIGHT", b, "TOPRIGHT", -14, -246)
    info:SetJustifyH("LEFT")
    info:SetText(string.format("A crit of %d%% or more of this hero's all-time record starts the streak. The big number is all the damage you deal while it runs; every further crit like that pops it and raises the x1, x2 counter. Ends after %d seconds without one. The record crit sits above the streak and moves with it.",
      STREAK_MIN_PCT * 100, STREAK_TIMEOUT))
  end

  local streakFont = AddSubSection(streakSec, "streakfont", "Fonts", PICKER_H,
    "Font used by the Crit Streak and the record crit above it.")
  MakeFontPicker(streakFont.body,
    function() return CrittersDB.recordFont end,
    function(font)
      CrittersDB.recordFont = font.path
      StreakRefresh()
      TestRecord(false)
      RefreshPerm()
    end,
    true, 5)

  -- ================= Section: Permanent crit record =================
  local permSec = AddSection("permrec", "Highest Crits", 376,
    "The permanent best-crit numbers on screen: when they show, their size, spacing, colors and position.")
  do
    local b = permSec.body

    local l1 = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l1:SetPoint("TOPLEFT", b, "TOPLEFT", 14, 0)
    l1:SetText("Where the record crit ends up")
    l1:SetTextColor(0.75, 0.75, 0.75)

    local desc = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    desc:SetPoint("TOPLEFT", b, "TOPLEFT", 14, -66)
    desc:SetPoint("TOPRIGHT", b, "TOPRIGHT", -14, -66)
    desc:SetHeight(36)
    desc:SetJustifyH("LEFT")
    desc:SetJustifyV("TOP")
    local function paintDesc()
      local d = PERM_DESC[PermMode()] or ""
      if PermMode() == "always" then d = string.format(d, FormatNumber(MinAllTime())) end
      desc:SetText(d)
    end
    paintDesc()

    MakeChoiceGrid(b, -16, PERM_MODES,
      function() return PermMode() end,
      function(k)
        CrittersDB.permMode = k
        paintDesc()
        RefreshPerm()
      end)

    -- which permanent numbers you want (Unlock shows the box of every ticked one)
    MakeCheckbox(b, "Damage record", -108, PermEnabled("dmg"),
      function(v)
        CrittersDB.permDmg = v
        ApplyPermAnchors()
      end, nil, "Show the permanent damage number. Use Unlock to place it.")
    MakeCheckbox(b, "Heal record", -108, PermEnabled("heal"),
      function(v)
        CrittersDB.permHeal = v
        ApplyPermAnchors()
      end, 150, "Show the permanent heal number. Use Unlock to place it.")

    MakeSlider(b, "Number size", -132, 1, 10, 1, ToLevel(CrittersDB.permSize or 27, SIZE_MIN, SIZE_MAX), "%d",
      function(l)
        local v = FromLevel(l, SIZE_MIN, SIZE_MAX)
        if CrittersDB.permSize ~= v then
          CrittersDB.permSize = v
          RefreshPerm()
        end
      end, "How big the permanent number is.")

    MakeSlider(b, "Space between digits", -166, 1, 10, 1, ToLevel(CrittersDB.permSpacing or 80, 20, 80), "%d",
      function(l)
        local v = FromLevel(l, 20, 80)
        if CrittersDB.permSpacing ~= v then
          CrittersDB.permSpacing = v
          RefreshPerm()
        end
      end, "Gap between the digits of the permanent number. Lower = tighter.")

    -- Unlock/Lock shows a draggable box (around a sample number) for each ticked number;
    -- Test dmg / Test heal play the replace animation with a made-up record
    MakeSwatch(b, "Damage color", -200,
      function() return GetColor("perm", false) end,
      function(c) CrittersDB.permColor = c; RefreshPerm() end,
      "Color of the permanent damage number and of the record damage crit above the Crit Streak.")

    MakeSwatch(b, "Heal color", -224,
      function() return GetColor("perm", true) end,
      function(c) CrittersDB.permHealColor = c; RefreshPerm() end,
      "Color of the permanent heal number and of the record heal crit above the Crit Streak.")

    MakeActionRow(b, -252, "perm", PreviewPerm, "Plays a made-up record flying to its permanent spot. Nothing is saved.")

    -- smallest crit that can become an all-time record (type a number, press Enter)
    local ml = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ml:SetPoint("TOPLEFT", b, "TOPLEFT", 14, -285)
    ml:SetText("All-time record needs a crit above")
    ml:SetTextColor(0.75, 0.75, 0.75)

    local box = CreateFrame("EditBox", nil, b)
    box:SetFontObject(GameFontHighlightSmall)
    box:SetWidth(84)
    box:SetHeight(20)
    box:SetPoint("TOPRIGHT", b, "TOPRIGHT", -14, -282)
    box:SetBackdrop(FLAT)
    box:SetBackdropColor(0.20, 0.20, 0.25, 1)          -- a bit lighter than the window: it is editable
    box:SetBackdropBorderColor(0.50, 0.50, 0.58, 1)
    box:SetTextInsets(6, 6, 0, 0)
    box:SetJustifyH("RIGHT")
    box:SetAutoFocus(false)
    box:SetMaxLetters(11)
    box:SetText(FormatNumber(MinAllTime()))

    local function commit()
      local digits = (string.gsub(box:GetText() or "", "%D", ""))
      local n = tonumber(digits) or MinAllTime()
      if n > 999999999 then n = 999999999 end
      CrittersDB.minAllTime = n
      box:SetText(FormatNumber(n))
      paintDesc()
    end
    box:SetScript("OnEditFocusGained", function(self)
      self:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
      self:SetText(tostring(MinAllTime()))
      self:HighlightText()
    end)
    box:SetScript("OnEditFocusLost", function(self)
      self:SetBackdropBorderColor(0.50, 0.50, 0.58, 1)
      commit()
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self)
      self:SetText(tostring(MinAllTime()))
      self:ClearFocus()
    end)
    SetTip(box, "Minimum all-time crit", "Only crits above this number can become your all-time record. Type a number and press Enter.")
    TipLabel(b, ml, "Minimum all-time crit", "Only crits above this number can become your all-time record. Type a number and press Enter.")

    -- Show / Hide the permanent numbers on screen (records keep being tracked while hidden)
    local vis = MakeButton(b, "", 120, 22)
    vis:SetPoint("TOPLEFT", b, "TOPLEFT", 14, -310)
    local function PaintVis()
      if CrittersDB.permHidden then
        vis.label:SetText("Show numbers")
        vis:SetBackdropColor(ACCENT[1] * 0.5, ACCENT[2] * 0.5, ACCENT[3] * 0.5, 1)
        vis:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
      else
        vis.label:SetText("Hide numbers")
        vis:SetBackdropColor(0.16, 0.16, 0.19, 1)
        vis:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
      end
    end
    PaintVis()
    vis:SetScript("OnLeave", function() PaintVis() end)
    vis:SetScript("OnClick", function()
      CrittersDB.permHidden = not CrittersDB.permHidden
      alwaysHidden.dmg, alwaysHidden.heal = false, false
      PaintVis()
      RefreshPerm()
    end)
    SetTip(vis, "Hide / Show numbers", "Hides or shows the permanent numbers on screen. Records are still saved. Does not affect the record crit popup.")

    local hint = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", b, "TOPLEFT", 14, -342)
    hint:SetPoint("TOPRIGHT", b, "TOPRIGHT", -14, -342)
    hint:SetHeight(26)
    hint:SetJustifyH("LEFT")
    hint:SetJustifyV("TOP")
    hint:SetText("Hover the number for spell, target and health %. Right-click it to close.")
  end

  local permFont = AddSubSection(permSec, "permfont", "Font", PICKER_H,
    "Font used for the permanent best-crit numbers.")
  MakeFontPicker(permFont.body,
    function() return CrittersDB.permFont end,
    function(font)
      CrittersDB.permFont = font.path
      RefreshPerm(true)   -- true = also show a test number for a few seconds if no record is on screen
    end,
    true, 5)

  -- ================= Section: General =================
  local gen = AddSection("general", "General", 156,
    "General options: heal crits, options window size and the Blood Queen / Valithria buff rules and the minimap icon.")
  do
    local b = gen.body

    MakeCheckbox(b, "Track heal crits too", 0, CrittersDB.healCrits ~= false,
      function(v) CrittersDB.healCrits = v end, nil, "Also pop up and record your healing crits, not just damage crits.")

    -- The window is only rescaled when the mouse button is RELEASED. Rescaling while the
    -- thumb is being dragged moves the slider under the cursor, which made it jump back and
    -- stick at 1.
    local pendingScale
    local sizeSlider = MakeSlider(b, "Options window size", -26, 1, 10, 1, UiScaleToLevel(CrittersDB.uiScale or 1), "%d",
      function(l)
        pendingScale = UiLevelToScale(l)
      end, "Scales the whole options window (text, buttons, everything). 1 is a bit smaller than normal, 3 is normal, 10 is the biggest.")
    sizeSlider:SetScript("OnMouseUp", function()
      if pendingScale and CrittersDB.uiScale ~= pendingScale then
        CrittersDB.uiScale = pendingScale
        ApplyUIScale(f)
      end
      pendingScale = nil
    end)

    MakeCheckbox(b, "Disable blood queen dmg buff", -62, CrittersDB.noBQL and true or false,
      function(v) CrittersDB.noBQL = v end, nil,
      "Blood Queen Lana'thel's buff (Essence of the Blood Queen) greatly boosts your damage and healing. While you have it, your crits are NOT saved as all-time records. Untick it to save them anyway; they are then marked \"with BQL Buff\" in the list.")

    MakeCheckbox(b, "Disable Valithria heal buff", -86, CrittersDB.noValithria and true or false,
      function(v) CrittersDB.noValithria = v end, nil,
      "Valithria Dreamwalker's buffs (Emerald Vigor, Twisted Nightmares) boost your healing. While you have one, your heal crits are NOT saved as all-time heal records. Untick it to save them anyway; they are then marked \"with Valithria Buff\".")

    -- (talks to the button through its global frame name, so this window needs no extra upvalue)
    MakeCheckbox(b, "Hide Minimap icon", -110, CrittersDB.minimapHide and true or false,
      function(v)
        CrittersDB.minimapHide = v and true or false
        local mb = CrittersMinimapButton
        if mb then
          if CrittersDB.minimapHide then mb:Hide() else mb:Show() end
        end
      end, nil, "Hides the Critters button on the minimap. Untick it to show it again. You can always open the options with /critters.")

    -- optional hero-specific "clear data" button (hidden unless this box is ticked)
    local clearBtn = MakeButton(b, "Clear this hero's data", 160, 22)
    clearBtn:SetPoint("TOPLEFT", b, "TOPLEFT", 14, -160)
    clearBtn.label:SetTextColor(1, 0.45, 0.45)
    clearBtn:SetScript("OnClick", function()
      StaticPopup_Show("CRITTERS_CLEAR_HERO", UnitName("player") or "this hero")
    end)
    SetTip(clearBtn, "Clear this hero's data", "Deletes the saved records of the hero you are playing (asks you to confirm). Other heroes are not touched.")

    local function PaintClear()
      if CrittersDB.showClear then
        clearBtn:Show()
        gen.height = 190
      else
        clearBtn:Hide()
        gen.height = 156
      end
    end
    PaintClear()

    MakeCheckbox(b, "Show clear data button (this hero)", -134, CrittersDB.showClear and true or false,
      function(v)
        CrittersDB.showClear = v
        PaintClear()
        Relayout()
      end, nil, "Shows a button that deletes the saved records of the hero you are playing. It asks you to confirm first.")
  end

  -- ================= Always-open sheet: all-time crits of every hero =================
  do
    local HDR = SHEET_HDR
    local DEFAULT_COLS = { 0.22, 0.17, 0.34, 0.27 }   -- Name | Damage | Info | Spell
    local TITLES = { "Name", "Damage", "Info", "Spell" }
    local cols = {}
    do   -- saved column widths (fractions), or the defaults
      local sc = CrittersDB.sheetCols
      local ok = type(sc) == "table"
      if ok then
        for c = 1, 4 do
          if type(sc[c]) ~= "number" or sc[c] < 0.05 then ok = false end
        end
      end
      local src = ok and sc or DEFAULT_COLS
      local sum = src[1] + src[2] + src[3] + src[4]
      for c = 1, 4 do cols[c] = src[c] / sum end
    end
    local sheetData, sheetOffset = {}, 0
    local bar, sheetWheel, PaintSheet, LayoutSheet
    local HOLD = 0.5   -- seconds to hold the mouse on a row before its full-text tooltip shows

    sheet = CreateFrame("Frame", nil, content)
    sheet:SetHeight(HDR + 12 + SHEET_ROWS * ROW_H)
    sheet:SetBackdrop(FLAT)
    sheet:SetBackdropColor(0.16, 0.16, 0.19, 1)          -- same gray as the bars
    sheet:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)

    local hbg = sheet:CreateTexture(nil, "BACKGROUND")
    hbg:SetTexture(WHITE)
    hbg:SetVertexColor(0.11, 0.11, 0.14, 1)
    hbg:SetPoint("TOPLEFT", sheet, "TOPLEFT", 1, -1)
    hbg:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -1, -1)
    hbg:SetHeight(HDR)

    local empty = sheet:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("CENTER", sheet, "CENTER", 0, -HDR / 2)
    empty:SetText("No all-time crits saved yet.")

    -- column titles
    local titles = {}
    for c = 1, 4 do
      local t = sheet:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      t:SetHeight(HDR - 1)
      t:SetJustifyH("LEFT")
      t:SetJustifyV("MIDDLE")
      t:SetText(TITLES[c])
      titles[c] = t
    end

    -- the text cells
    local rows = {}
    for i = 1, SHEET_ROWS do
      local r = {}
      for c = 1, 4 do
        local fs = sheet:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetHeight(ROW_H)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("MIDDLE")
        r[c] = fs
      end
      rows[i] = r
    end

    local function SheetW()
      local w = (sheet:GetWidth() or 300) - 28   -- left padding + room for the scrollbar
      if w < 120 then w = 120 end
      return w
    end

    -- hover a row for half a second: full text in a tooltip (cells can be cut short)
    local function RowUpdate(self, el)
      self.hold = self.hold + el
      if self.hold < HOLD then return end
      self:SetScript("OnUpdate", nil)
      local e = sheetData[sheetOffset + self.idx]
      if not e then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      local col = e.color or { r = 0.8, g = 0.8, b = 0.8 }
      GameTooltip:AddLine(e.name, col.r, col.g, col.b)
      GameTooltip:AddLine(FormatNumber(e.d.amount) .. (e.heal and " heal crit" or " damage crit"), 1, 1, 1)
      GameTooltip:AddLine((e.heal and "Healed " or "Hit to ") .. (e.d.target or "Unknown"), 1, 1, 1, true)
      GameTooltip:AddLine("with " .. (e.d.spell or "Melee"), 1, 1, 1, true)
      if e.d.bql then GameTooltip:AddLine("with BQL Buff (Essence of the Blood Queen)", 1, 0.4, 0.4, true) end
      if e.d.vali then GameTooltip:AddLine("with Valithria Buff (Emerald Vigor / Twisted Nightmares)", 1, 0.4, 0.4, true) end
      GameTooltip:AddLine("|cffffffffLink with|r |cff33ff33Shift+L Click|r", 1, 1, 1)
      if e.d.pct then GameTooltip:AddLine("Target was at " .. e.d.pct .. "% health", 1, 0.82, 0) end
      GameTooltip:Show()
    end

    local hits = {}
    for i = 1, SHEET_ROWS do
      local hit = CreateFrame("Button", nil, sheet)
      hit:SetHeight(ROW_H)
      hit:EnableMouseWheel(true)
      hit.idx = i
      local hl = hit:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints(hit)
      hl:SetTexture(WHITE)
      hl:SetVertexColor(1, 1, 1, 0.06)
      hit:SetScript("OnEnter", function(self)
        self.hold = 0
        self:SetScript("OnUpdate", RowUpdate)
      end)
      hit:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
      end)
      hit:SetScript("OnMouseWheel", function(self, delta) sheetWheel(delta) end)
      -- Shift + left click: put this record in your chat box so you can share it
      hit:SetScript("OnClick", function(self, button)
        if button ~= "LeftButton" or not IsShiftKeyDown() then return end
        local e = sheetData[sheetOffset + self.idx]
        if not e then return end
        OpenShare(ShareText(e.name, e.d), e.name .. "  " .. FormatNumber(e.d.amount))
      end)
      hits[i] = hit
    end

    -- draggable dividers in the header: drag to change the column widths
    local handles = {}
    for c = 1, 3 do
      local h = CreateFrame("Frame", nil, sheet)
      h:SetWidth(8)
      h:SetHeight(HDR)
      h:EnableMouse(true)
      h.idx = c
      local line = h:CreateTexture(nil, "OVERLAY")
      line:SetTexture(WHITE)
      line:SetWidth(1)
      line:SetPoint("TOP", h, "TOP", 0, -3)
      line:SetPoint("BOTTOM", h, "BOTTOM", 0, 3)
      line:SetVertexColor(0.45, 0.45, 0.52, 1)

      local function DragUpdate(self)
        local x = GetCursorPosition() / sheet:GetEffectiveScale()
        local rel = (x - sheet:GetLeft() - 8) / SheetW()
        local before = 0
        for k = 1, self.idx - 1 do before = before + cols[k] end
        local after = before + cols[self.idx] + cols[self.idx + 1]
        if rel < before + 0.08 then rel = before + 0.08 end
        if rel > after - 0.08 then rel = after - 0.08 end
        cols[self.idx] = rel - before
        cols[self.idx + 1] = after - rel
        LayoutSheet()
      end
      h:SetScript("OnEnter", function() line:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 1) end)
      h:SetScript("OnLeave", function(self)
        if not self.drag then line:SetVertexColor(0.45, 0.45, 0.52, 1) end
      end)
      h:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
          self.drag = true
          self:SetScript("OnUpdate", DragUpdate)
        end
      end)
      h:SetScript("OnMouseUp", function(self)
        self.drag = false
        self:SetScript("OnUpdate", nil)
        line:SetVertexColor(0.45, 0.45, 0.52, 1)
        CrittersDB.sheetCols = { cols[1], cols[2], cols[3], cols[4] }
      end)
      SetTip(h, "Resize columns", "Drag left or right to change the column widths. They are remembered.")
      handles[c] = h
    end

    LayoutSheet = function()
      local w = SheetW()
      local x = 8
      for c = 1, 4 do
        local cw = w * cols[c]
        titles[c]:ClearAllPoints()
        titles[c]:SetPoint("TOPLEFT", sheet, "TOPLEFT", x, -1)
        titles[c]:SetWidth(cw - 8)
        for i = 1, SHEET_ROWS do
          local fs = rows[i][c]
          fs:ClearAllPoints()
          fs:SetPoint("TOPLEFT", sheet, "TOPLEFT", x, -(HDR + 4 + (i - 1) * ROW_H))
          fs:SetWidth(cw - 6)
        end
        x = x + cw
        if c < 4 then
          handles[c]:ClearAllPoints()
          handles[c]:SetPoint("TOPLEFT", sheet, "TOPLEFT", x - 5, -1)
        end
      end
      for i = 1, SHEET_ROWS do
        local hit = hits[i]
        local y = -(HDR + 4 + (i - 1) * ROW_H)
        hit:ClearAllPoints()
        hit:SetPoint("TOPLEFT", sheet, "TOPLEFT", 3, y)
        hit:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -18, y)
      end
    end
    sheet:SetScript("OnSizeChanged", function() LayoutSheet() end)

    bar = CreateFrame("Slider", nil, sheet)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(8)
    bar:SetHeight(SHEET_ROWS * ROW_H)
    bar:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", -5, -(HDR + 4))
    bar:EnableMouse(true)
    bar:SetBackdrop(FLAT)
    bar:SetBackdropColor(0.09, 0.09, 0.11, 1)
    bar:SetBackdropBorderColor(0.25, 0.25, 0.3, 1)
    bar:SetThumbTexture(WHITE)
    local bt = bar:GetThumbTexture()
    bt:SetWidth(8)
    bt:SetHeight(22)
    bt:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    bar:Hide()
    bar:SetScript("OnValueChanged", function(self, v)
      sheetOffset = math.floor(v + 0.5)
      PaintSheet()
    end)

    sheetWheel = function(delta)
      if bar:IsShown() then
        bar:SetValue(bar:GetValue() - delta)
      elseif outerWheel then
        outerWheel(delta)
      end
    end
    sheet:EnableMouseWheel(true)
    sheet:SetScript("OnMouseWheel", function(self, delta) sheetWheel(delta) end)

    -- every hero's all-time best (damage and heal), biggest first
    local function Collect()
      local list = {}
      for key, h in pairs(CrittersDB.heroes or {}) do
        local name = h.name or string.match(key, "^([^-]+)") or key
        local color = h.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[h.class]
        for _, kind in ipairs({ "dmg", "heal" }) do
          local d = h.best and h.best[kind]
          if d and d.amount then
            list[#list + 1] = { name = name, color = color, d = d, heal = (kind == "heal") }
          end
        end
      end
      table.sort(list, function(a, b)
        if a.d.amount ~= b.d.amount then return a.d.amount > b.d.amount end
        return a.name < b.name
      end)
      return list
    end

    PaintSheet = function()
      if #sheetData == 0 then empty:Show() else empty:Hide() end
      for i = 1, SHEET_ROWS do
        local r = rows[i]
        local e = sheetData[sheetOffset + i]
        if e then
          local col = e.color or { r = 0.8, g = 0.8, b = 0.8 }
          r[1]:SetText(e.name)
          r[1]:SetTextColor(col.r, col.g, col.b)
          r[2]:SetText(FormatNumber(e.d.amount))
          r[3]:SetText((e.heal and "Healed " or "Hit to ") .. (e.d.target or "Unknown"))
          r[4]:SetText((e.d.spell or "Melee") .. (e.d.bql and " with BQL Buff" or "") .. (e.d.vali and " with Valithria Buff" or ""))
          for c = 2, 4 do r[c]:SetTextColor(1, 1, 1) end   -- info text is white
          hits[i]:Show()
        else
          for c = 1, 4 do r[c]:SetText("") end
          hits[i]:Hide()
        end
      end
    end

    RefreshHeroSheet = function()
      sheetData = Collect()
      local maxOff = math.max(0, #sheetData - SHEET_ROWS)
      if sheetOffset > maxOff then sheetOffset = maxOff end
      bar:SetMinMaxValues(0, maxOff)
      bar:SetValue(sheetOffset)
      if maxOff > 0 then bar:Show() else bar:Hide() end
      LayoutSheet()
      PaintSheet()
    end
    RefreshHeroSheet()
  end

  -- footer note
  note = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetHeight(14)
  note:SetJustifyH("LEFT")
  note:SetJustifyV("TOP")
  note:SetText("Game combat text needs a relog.")

  -- ----- resize grip (bottom right) -----
  local grip = CreateFrame("Button", nil, f)
  grip:SetWidth(16)
  grip:SetHeight(16)
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  local gripTex = grip:CreateTexture(nil, "OVERLAY")
  gripTex:SetTexture(WHITE)
  gripTex:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.8)
  gripTex:SetWidth(8)
  gripTex:SetHeight(8)
  gripTex:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -2, 2)
  grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    CrittersDB.winW = math.floor(f:GetWidth() + 0.5)
    CrittersDB.winH = math.floor(f:GetHeight() + 0.5)
  end)

  f.Relayout = Relayout
  Relayout()
  return f
end

-- fill every font picker with the font list and show the current choice
local function RefreshPickers()
  for _, P in ipairs(pickers) do
    P.Rebuild()
    P.SetPreview(P.getPath() or DEFAULT_FONT)
    P.ScrollToCurrent()
  end
end

local function ToggleWindow()
  if not frame then
    local list, hasLSM, hidden = BuildFontList()
    fontList = list
    frame = BuildWindow()
    RefreshPickers()

    if not hasLSM and not warnedNoLSM then
      warnedNoLSM = true
      Msg("LibSharedMedia not found, so only the built-in fonts are listed. Install SharedMedia for more.")
    end
    if hidden > 0 and not warnedHidden then
      warnedHidden = true
      Msg(hidden .. " font(s) were hidden because their files could not be loaded.")
    end
  end

  if frame:IsShown() then
    frame:Hide()
  else
    frame:Show()
    frame.Relayout()
    if RefreshHeroSheet then RefreshHeroSheet() end
  end
end

-- ========= Interface -> AddOns panel =========
do
  local panel = CreateFrame("Frame", "CrittersInterfacePanel", UIParent)
  panel.name = "Critters"

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
  title:SetText("Critters")

  local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  desc:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
  desc:SetJustifyH("LEFT")
  desc:SetText("Big animated crit popups, permanent best-crit numbers and an account-wide list of every hero's best crit.\n\nSlash commands: |cffffffff/critters|r or |cffffffff/crit|r")

  local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  btn:SetWidth(180)
  btn:SetHeight(24)
  btn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -20)
  btn:SetText("Open Critters options")
  btn:SetScript("OnClick", function()
    HideUIPanel(InterfaceOptionsFrame)
    HideUIPanel(GameMenuFrame)
    if not (frame and frame:IsShown()) then ToggleWindow() end
  end)

  InterfaceOptions_AddCategory(panel)
end

-- ========= Minimap button =========
-- Put your icon in  Interface\AddOns\Critters\  and name it icon.tga (or change the path below).
-- WotLK needs .tga (32-bit, uncompressed) or .blp, with width/height 32, 64 or 128.
local MINIMAP_ICON   = "Interface\\AddOns\\Critters\\icon"   -- no extension needed
local MINIMAP_BORDER = true    -- gold ring around the icon like other addons; false = icon only

local minimapBtn

local function PlaceMinimapButton()
  if not minimapBtn then return end
  local a = math.rad(CrittersDB.minimapAngle or 215)
  minimapBtn:ClearAllPoints()
  minimapBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
end

local function UpdateMinimapButton()
  if not minimapBtn then return end
  if CrittersDB.minimapHide then minimapBtn:Hide() else minimapBtn:Show() end
end

local function CreateMinimapButton()
  if minimapBtn then return end
  local b = CreateFrame("Button", "CrittersMinimapButton", Minimap)
  minimapBtn = b
  b:SetWidth(31)
  b:SetHeight(31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture(MINIMAP_ICON)
  if MINIMAP_BORDER then
    icon:SetWidth(20); icon:SetHeight(20)
    icon:SetPoint("TOPLEFT", b, "TOPLEFT", 6, -5)
    local ring = b:CreateTexture(nil, "OVERLAY")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetWidth(53); ring:SetHeight(53)
    ring:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  else
    icon:SetAllPoints(b)
  end

  b:SetScript("OnClick", function() ToggleWindow() end)

  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local px, py = GetCursorPosition()
      local sc = Minimap:GetEffectiveScale()
      CrittersDB.minimapAngle = math.deg(math.atan2(py / sc - my, px / sc - mx))
      PlaceMinimapButton()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Critters", 1, 1, 1)
    GameTooltip:AddLine("Click: open options", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  PlaceMinimapButton()
  UpdateMinimapButton()
end

-- ========= Slash commands =========
SLASH_CRITTERS1 = "/critters"
SLASH_CRITTERS2 = "/crit"
SlashCmdList["CRITTERS"] = function(msg)
  local cmd = string.lower(string.match(msg or "", "^%s*(%S*)") or "")

  if cmd == "" or cmd == "options" or cmd == "config" then
    ToggleWindow()
  elseif cmd == "test" then
    TestRecord(false)
  elseif cmd == "testheal" then
    TestRecord(true)
  elseif cmd == "crit" then
    PreviewCrit(false)
  elseif cmd == "streak" then
    StreakTest()
  elseif cmd == "reset" then
    dmgRecord, healRecord = 0, 0
    Msg("records reset. The next crit will count as a new record.")
  elseif cmd == "debug" then
    debugMode = not debugMode
    Msg("debug " .. (debugMode and "ON" or "OFF"))
  elseif cmd == "status" then
    PrintStatus()
  elseif cmd == "records" then
    PrintRecords()
  elseif cmd == "heroes" then
    PrintHeroes()
  elseif cmd == "minimap" then
    CrittersDB.minimapHide = not CrittersDB.minimapHide
    UpdateMinimapButton()
    Msg("minimap button " .. (CrittersDB.minimapHide and "hidden" or "shown"))
  else
    Msg("commands: |cffffffff/critters|r (options), test, testheal, crit, streak, records, heroes, minimap, reset, debug, status")
  end
end

-- ========= Startup =========
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
  if name ~= ADDON then return end
  self:UnregisterEvent("ADDON_LOADED")

  CrittersDB = CrittersDB or {}
  -- (the Blood Queen and Valithria rules are ticked by default for everyone: DEFAULTS below fills
  -- them in whenever they were never set. A box someone unticked is saved as false and stays off.)
  for k, v in pairs(DEFAULTS) do
    if CrittersDB[k] == nil then CrittersDB[k] = v end
  end

  -- pull older saved values into the ranges the sliders now use
  CrittersDB.critSize     = math.max(SIZE_MIN, math.min(SIZE_MAX, CrittersDB.critSize or NORMAL_CRIT_SIZE))
  CrittersDB.digitSpacing = math.max(20, math.min(80, CrittersDB.digitSpacing or 80))
  CrittersDB.uiScale      = UiLevelToScale(UiScaleToLevel(CrittersDB.uiScale or 1))   -- snap to a slider step
  CrittersDB.permSize     = math.max(SIZE_MIN, math.min(SIZE_MAX, CrittersDB.permSize or 27))
  CrittersDB.streakSize   = math.max(SIZE_MIN, math.min(SIZE_MAX, CrittersDB.streakSize or STREAK_SIZE))
  CrittersDB.permSpacing  = math.max(20, math.min(80, CrittersDB.permSpacing or 80))
  if not IsValidFont(CrittersDB.permFont) then CrittersDB.permFont = DEFAULT_FONT end
  -- the first version had a single permanent anchor: keep its position for the damage number
  if CrittersDB.permPos and not CrittersDB.permDmgPos then CrittersDB.permDmgPos = CrittersDB.permPos end
  if CrittersDB.permMode ~= "always" and CrittersDB.permMode ~= "never" then CrittersDB.permMode = "group" end
  CrittersDB.minAllTime = math.max(0, math.min(999999999, tonumber(CrittersDB.minAllTime) or MIN_ALLTIME))
  CrittersDB.heroes = CrittersDB.heroes or {}   -- per-character records live inside the account-wide file

  if IsValidFont(CrittersDB.damageFont) then
    DAMAGE_TEXT_FONT = CrittersDB.damageFont
  end

  -- restore saved anchor positions
  for _, a in pairs(anchors) do
    local pos = CrittersDB[a.dbKey]
    if type(pos) == "table" and pos.point then
      a:ClearAllPoints()
      a:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    end
  end

  CreateMinimapButton()
  ApplyTracking()
  Msg("loaded. Type |cffffffff/critters|r for options.")
end)
