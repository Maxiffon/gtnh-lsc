-- lscm_core.lua — общая часть монитора LSC: числа, буферы, датчик, настройки, файлы
local unicode   = require("unicode")
local ser       = require("serialization")
local fs        = require("filesystem")
local computer  = require("computer")
local component = require("component")

local L = {}
L.TITLE      = "ЛАПОТРОННЫЙ СУПЕРКОНДЕНСАТОР"
L.CFG_FILE   = "/home/monitor.cfg"
L.STATS_FILE = "/home/monitor_stats.dat"
L.REBALANCE  = 300 -- LSC переливает с беспроводной сетью раз в 6000 тиков = 5 минут

L.len, L.usub = unicode.len, unicode.sub
function L.fit(s, w)
  if w <= 0 then return "" end
  if unicode.len(s) > w then return unicode.sub(s, 1, w) end
  return s
end

---------------------------------------------------------------- цвета и темы
-- 16 ролей = 16 ячеек палитры видеокарты, поэтому цвета на экране точные
L.ROLES = {
  { "bg", "Фон" },          { "bg2", "Фон 2" },          { "panel", "Панели" },
  { "panel2", "Панели 2" }, { "border", "Рамки" },       { "text", "Текст" },
  { "dim", "Подписи" },     { "accent", "Акцент" },      { "good", "Вход и плюс" },
  { "out", "Выход" },       { "bad", "Минус, тревога" }, { "warn", "Внимание" },
  { "star", "Звёзды" },     { "btn", "Кнопки" },         { "barBg", "Пустая полоса" },
  { "title", "Шапка" },
}
L.P = {}
for i, r in ipairs(L.ROLES) do L.P[r[1]] = -i end -- отрицательное число = ячейка палитры i-1

-- тема = цвета + стиль (рамки, шапка, полоса) + фоновая анимация
L.THEMES = {
  { "Космос",  { 0x05060F, 0x0E0B26, 0x0B1022, 0x111A33, 0x2A3A66, 0xE8ECFF, 0x7F8AB8, 0x7AA2FF,
                 0x3DDC97, 0xFF9F43, 0xFF5C7A, 0xFFD166, 0xFFFFFF, 0x1A2547, 0x141C38, 0x1B1446 },
    st = "space", desc = "звёзды, метеоры, мягкие рамки" },
  { "Матрица", { 0x000000, 0x001A00, 0x020A02, 0x041404, 0x0F5F0F, 0xC8FFC8, 0x4FA04F, 0x00FF41,
                 0x00FF41, 0xB4FF00, 0xFF3B3B, 0xE6FF00, 0x7CFF7C, 0x062A06, 0x041E04, 0x032B03 },
    st = "matrix", desc = "цифровой дождь и терминал с курсором" },
  { "Неон",    { 0x050008, 0x14001F, 0x0C0014, 0x16002A, 0x6A1FB0, 0xF5E9FF, 0x9C7FB8, 0x00E5FF,
                 0x39FF14, 0xFF6EC7, 0xFF2E63, 0xFFE600, 0xFFFFFF, 0x24003D, 0x1A0030, 0x2B0050 },
    st = "neon", desc = "двойные рамки, пульс и искры" },
  { "Аврора",  { 0x02100F, 0x0A1F2B, 0x06181C, 0x0B2429, 0x1F5C5A, 0xE6FFF8, 0x7FB3A8, 0x5EEAD4,
                 0x86EFAC, 0xC084FC, 0xFB7185, 0xFDE68A, 0xE0FFFF, 0x0F3A3A, 0x0E2A2C, 0x0B3B3A },
    st = "aurora", desc = "северное сияние и переливы" },
  { "Марс",    { 0x120604, 0x220C06, 0x1A0A06, 0x26100A, 0x6B2A16, 0xFFEDE3, 0xC08A74, 0xFF7A45,
                 0x9BE564, 0xFFB347, 0xFF4D4D, 0xFFD166, 0xFFE8D6, 0x3A160C, 0x2A120A, 0x3D140A },
    st = "mars", desc = "пылевая буря, сигнальные полосы" },
  { "Графит",  { 0x0D1117, 0x161B22, 0x161B22, 0x1C2330, 0x30363D, 0xE6EDF3, 0x8B949E, 0x58A6FF,
                 0x3FB950, 0xF0883E, 0xF85149, 0xD29922, 0xC9D1D9, 0x21262D, 0x21262D, 0x1F2A44 },
    st = "plain", desc = "строго: тонкие рамки и сетка" },
}
function L.themeByName(n) for _, th in ipairs(L.THEMES) do if th[1] == n then return th end end end

L.DEFAULT_OPTS = {
  anim = true, fps = 10, stars = 2, meteors = true, tz = 3,
  sound = true, redstone = "crit", critMinutes = 30, warnHours = 6,
  inputDrop = 50, confirm = 10, clear = 30, muteMinutes = 10,
}

function L.col(name) return L.cfg.colors[-L.P[name]] end -- настоящий RGB роли

function L.defaultCfg()
  local cfg = { colors = {}, opts = {}, theme = L.THEMES[1][1], style = L.THEMES[1].st }
  for i, c in ipairs(L.THEMES[1][2]) do cfg.colors[i] = c end
  for k, v in pairs(L.DEFAULT_OPTS) do cfg.opts[k] = v end
  return cfg
end

function L.loadCfg()
  local cfg = L.defaultCfg()
  local f = io.open(L.CFG_FILE, "r")
  if f then
    local s = f:read("*a"); f:close()
    local ok, t = pcall(ser.unserialize, s or "")
    if ok and type(t) == "table" then
      if type(t.colors) == "table" then
        for i = 1, #L.ROLES do if type(t.colors[i]) == "number" then cfg.colors[i] = t.colors[i] end end
      end
      if type(t.opts) == "table" then
        for k, v in pairs(t.opts) do if type(v) == type(L.DEFAULT_OPTS[k]) then cfg.opts[k] = v end end
      end
      if type(t.theme) == "string" then cfg.theme = t.theme end
      local th = L.themeByName(cfg.theme)
      cfg.style = type(t.style) == "string" and t.style or (th and th.st) or cfg.style
    end
  end
  L.cfg = cfg
end

function L.saveCfg()
  local f = io.open(L.CFG_FILE, "w")
  if f then
    f:write(ser.serialize({ colors = L.cfg.colors, opts = L.cfg.opts, theme = L.cfg.theme, style = L.cfg.style }))
    f:close()
  end
end

---------------------------------------------------------------- числа и время
L.WORDS = { "", "тыс.", "млн", "млрд", "трлн", "квадрлн", "квинтлн", "секстлн", "септлн" }
function L.scale(n)
  local i = 1
  while n >= 1000 and i < #L.WORDS do n = n / 1000; i = i + 1 end
  return n, i
end
function L.num(n, dec)
  if type(n) ~= "number" then return "—" end
  local v, i = L.scale(math.abs(n))
  local s = i == 1 and string.format("%.0f", v) or string.format("%." .. (dec or 2) .. "f %s", v, L.WORDS[i])
  return (n < 0 and "-" or "") .. s
end
function L.signed(n, dec)
  if type(n) ~= "number" then return "—" end
  return (n > 0 and "+" or "") .. L.num(n, dec)
end
function L.pct(f)
  if type(f) ~= "number" then return "—" end
  f = f * 100
  if f >= 1 then return string.format("%.2f %%", f) end
  if f >= 0.01 then return string.format("%.4f %%", f) end
  return string.format("%.7f %%", f)
end

L.TIERS = {
  { "LV", 32 }, { "MV", 128 }, { "HV", 512 }, { "EV", 2048 }, { "IV", 8192 },
  { "LuV", 32768 }, { "ZPM", 131072 }, { "UV", 524288 }, { "UHV", 2097152 },
  { "UEV", 8388608 }, { "UIV", 33554432 }, { "UMV", 134217728 },
  { "UXV", 536870912 }, { "MAX", 2147483648 },
}
function L.amps(r)
  if type(r) ~= "number" then return "" end
  r = math.abs(r)
  if r < 1 then return "" end
  local t = L.TIERS[1]
  for _, x in ipairs(L.TIERS) do if x[2] <= r then t = x end end
  return string.format("%.2f A %s", r / t[2], t[1])
end

function L.dur(s)
  if type(s) ~= "number" or s ~= s or s == math.huge or s < 0 then return "—" end
  s = math.floor(s)
  local d = math.floor(s / 86400); s = s % 86400
  local h = math.floor(s / 3600);  s = s % 3600
  local m = math.floor(s / 60);    s = s % 60
  if d > 365 then return "больше года" end
  if d > 0 then return h > 0 and string.format("%.0f д %.0f ч", d, h) or string.format("%.0f д", d) end
  if h > 0 then return m > 0 and string.format("%.0f ч %.0f мин", h, m) or string.format("%.0f ч", h) end
  if m > 0 then return s > 0 and string.format("%.0f мин %.0f с", m, s) or string.format("%.0f мин", m) end
  return string.format("%.0f с", s)
end

-- короткая запись для подписей графика: «-898 млн», «1.07 млрд»
L.SHORT = { "", "тыс", "млн", "млрд", "трлн", "квдр", "квнт", "скст", "сптл" }
function L.short(n)
  if type(n) ~= "number" then return "—" end
  local v, i = L.scale(math.abs(n))
  local s = string.format(v >= 100 and "%.0f" or (v >= 10 and "%.1f" or "%.2f"), v)
  if i > 1 then s = s .. " " .. L.SHORT[i] end
  return (n < 0 and "-" or "") .. s
end

function L.mmss(s)
  if type(s) ~= "number" then return "—" end
  s = math.max(0, math.floor(s))
  return string.format("%.0f:%02.0f", math.floor(s / 60), s % 60)
end

-- настоящее время: дата изменения файла, один раз при запуске
local function realNow()
  local p = "/home/.monitor_clock"
  local f = io.open(p, "w"); if not f then return nil end
  f:write("."); f:close()
  local t = fs.lastModified(p)
  if type(t) ~= "number" then return nil end
  if t > 1e12 then return t / 1000 end
  if t > 1e9 then return t end
end
L.clk0, L.up0 = realNow(), computer.uptime()
function L.now() return L.clk0 and (L.clk0 + computer.uptime() - L.up0) or computer.uptime() end
function L.clock(tz)
  if not L.clk0 then return nil end
  local s = math.floor(L.now() + (tz or 0) * 3600) % 86400
  return string.format("%02.0f:%02.0f", math.floor(s / 3600), math.floor(s % 3600 / 60))
end

---------------------------------------------------------------- кольцевой буфер
local Ring = {}
Ring.__index = Ring
function L.ring(cap) return setmetatable({ cap = cap, n = 0, head = 0, d = {} }, Ring) end
function Ring:push(v)
  self.head = self.head % self.cap + 1
  self.d[self.head] = v
  if self.n < self.cap then self.n = self.n + 1 end
end
function Ring:last(age) return self.d[(self.head - 1 - age) % self.cap + 1] end -- 0 = самое новое
function Ring:get(k) return self.d[(self.head - self.n + k - 1) % self.cap + 1] end -- 1 = самое старое
function Ring:mean(m)
  m = math.min(m or self.n, self.n)
  local s, c = 0, 0
  for age = 0, m - 1 do
    local v = self.d[(self.head - 1 - age) % self.cap + 1]
    if type(v) == "number" then s = s + v; c = c + 1 end
  end
  return c > 0 and s / c or nil
end
function Ring:clear() self.n, self.head, self.d = 0, 0, {} end

---------------------------------------------------------------- датчик LSC
function L.clean(s) return (tostring(s):gsub("§.", "")) end

-- целое из NumberFormat: "54,520,000" / "54 520 000" / "54.520.000"
local function int(s)
  if not s then return nil end
  s = L.clean(s)
  local neg = s:match("^%s*%-") ~= nil
  local dg = s:gsub("%D", "")
  if dg == "" then return nil end
  local v = tonumber(dg) * 1.0
  return neg and -v or v
end

-- строки датчика приходят как "ключ\\аргумент\\аргумент"
local function splitEnc(l)
  local parts = {}
  for p in (l .. "\\\\"):gmatch("(.-)\\\\") do parts[#parts + 1] = p end
  return parts
end

local PFX = "kekztech.infodata.lapotronic_super_capacitor."
local FIELD = {
  ["eu_stored"] = "stored", ["total_capacity"] = "cap", ["passive_loss"] = "loss",
  ["avg_eu_in.sec"] = "inS", ["avg_eu_out.sec"] = "outS",
  ["avg_eu_in.min5"] = "in5", ["avg_eu_out.min5"] = "out5",
  ["avg_eu_in.hour1"] = "in1h", ["avg_eu_out.hour1"] = "out1h",
  ["wireless_eu"] = "wEU",
}

local function parseEncoded(info)
  local d, found = {}, false
  for _, raw in ipairs(info) do
    local p = splitEnc(L.clean(raw))
    local key = p[1] or ""
    if key:sub(1, #PFX) == PFX then
      found = true
      local k = key:sub(#PFX + 1)
      local f = FIELD[k]
      if f then
        local v = int(p[2])
        -- у запаса и ёмкости по две строки (число и короткая запись): берём большее
        if v and (d[f] == nil or math.abs(v) > math.abs(d[f])) then d[f] = v end
      elseif k == "wireless_mode.enabled" then d.wireless = true
      elseif k == "wireless_mode.disabled" then d.wireless = false end
    elseif key:find("maintenance_status.ok", 1, true) then d.maint = true
    elseif key:find("maintenance_status.bad", 1, true) then d.maint = false end
  end
  return found and d or nil
end

-- запасной разбор для версий, где строки обычным текстом
local PLAIN = {
  stored = { "used capacity", "stored", "заряд", "накоплен" },
  cap    = { "total capacity", "max capacity", "ёмкость", "емкость" },
  inS    = { "avg eu in", "average eu in", "средний вход" },
  outS   = { "avg eu out", "average eu out", "средний выход" },
  loss   = { "passive loss", "пассивн", "потери" },
}
local function parsePlain(info)
  local d = {}
  for f, keys in pairs(PLAIN) do
    for _, l in ipairs(info) do
      if d[f] == nil then
        local c = unicode.lower(L.clean(l))
        for _, k in ipairs(keys) do
          if c:find(k, 1, true) then
            local s = L.clean(l):gsub("(%d)[ ,'](%d)", "%1%2")
            d[f] = tonumber(s:match("%-?%d+%.?%d*"))
            break
          end
        end
      end
    end
  end
  return d
end

function L.readData(m)
  local okI, info = pcall(m.getSensorInformation)
  if not okI or type(info) ~= "table" then info = {} end
  local d = parseEncoded(info) or parsePlain(info)
  if not d.stored then local ok, v = pcall(m.getEUStored); if ok then d.stored = tonumber(v) end end
  if not d.cap or d.cap <= 0 then local ok, v = pcall(m.getEUMaxStored); if ok then d.cap = tonumber(v) end end
  -- «работает/выключен» меняется редко, а вызов занимает целый тик: проверяем раз в 5 с
  local up = computer.uptime()
  if not L.onT or up - L.onT >= 5 then
    local ok, w = pcall(m.isWorkAllowed)
    L.onT, L.onV = up, ok and w or nil
  end
  d.on = L.onV
  return d
end

function L.pickMachine(addr)
  if addr then
    local full = component.get(addr)
    if not full then error("Нет компонента с адресом " .. addr, 0) end
    return component.proxy(full)
  end
  local list = {}
  for a in component.list("gt_machine") do
    local p = component.proxy(a)
    local ok, name = pcall(p.getName)
    list[#list + 1] = { p = p, name = ok and tostring(name) or "?", addr = a }
  end
  if #list == 0 then error("gt_machine не найден. Поставьте адаптер вплотную к контроллеру конденсатора.", 0) end
  for _, m in ipairs(list) do
    local n = m.name:lower()
    if n:find("capacitor") or n:find("lapotron") then return m.p end
  end
  if #list > 1 then
    io.write("Конденсатор не опознан по имени, беру первую машину. Найдены:\n")
    for _, m in ipairs(list) do io.write("  " .. m.addr:sub(1, 8) .. "  " .. m.name .. "\n") end
    os.sleep(2)
  end
  return list[1].p
end

function L.dump(m)
  local lines = {}
  local function add(s) lines[#lines + 1] = s; print(s) end
  local ok, name = pcall(m.getName)
  add("Машина: " .. (ok and tostring(name) or "?") .. "  " .. tostring(m.address))
  for _, f in ipairs({ "getEUStored", "getEUMaxStored", "isWorkAllowed" }) do
    if m[f] then
      local okv, v = pcall(m[f])
      add(string.format("%s = %s", f, okv and tostring(v) or ("ошибка: " .. tostring(v))))
    end
  end
  local okI, info = pcall(m.getSensorInformation)
  add("getSensorInformation:")
  if okI and type(info) == "table" then
    for i, l in ipairs(info) do add(string.format("[%d] %s", i, L.clean(l))) end
  else
    add("  недоступно: " .. tostring(info))
  end
  local fh = io.open("/home/lsc_dump.txt", "w")
  if fh then fh:write(table.concat(lines, "\n")); fh:close(); print("Сохранено в /home/lsc_dump.txt") end
end

---------------------------------------------------------------- файл статистики
function L.fnum(v) return type(v) == "number" and string.format("%.15g", v) or "-" end
function L.appendLine(s)
  local f = io.open(L.STATS_FILE, "a")
  if f then f:write(s .. "\n"); f:close() end
end
function L.readLines()
  local out = {}
  local f = io.open(L.STATS_FILE, "r")
  if not f then return out end
  local s = f:read("*a") or ""; f:close()
  for line in s:gmatch("[^\n]+") do out[#out + 1] = line end
  return out
end
function L.writeLines(lines)
  local f = io.open(L.STATS_FILE, "w")
  if not f then return end
  for _, l in ipairs(lines) do f:write(l .. "\n") end
  f:close()
end

return L
