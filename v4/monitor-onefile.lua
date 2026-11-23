-- monitor.lua v4 — монитор лапотронного суперконденсатора (GTNH, OpenComputers)
-- ОДНОФАЙЛОВАЯ СБОРКА: модули lscm_* встроены через package.preload.
-- Установка: положить как /home/monitor.lua и запустить: monitor
--   monitor <адрес>   — конкретный gt_machine
--   monitor --dump    — сырые данные машины в /home/lsc_dump.txt
-- Клавиши: Q выход, Tab страница, M график, 1-4 период, T сирена
-- Собрано из v4: monitor.lua + lib/lscm_{core,stats,gfx,fx,pages,settings}.lua

local __BUNDLE = {
  ["lscm_core"] = [===[
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
]===],
  ["lscm_stats"] = [===[
-- lscm_stats.lua — опрос, фильтр переливов с беспроводной сетью, история, средние, сирена
local L = require("lscm_core")
local component = require("component")
local computer  = require("computer")

-- i вход, o выход, n баланс LSC, w сеть (без переливов), t итого (LSC + сеть)
local KEYS = { "i", "o", "n", "w", "t" }
local CNT  = { i = "#i", o = "#o", n = "#n", w = "#w", t = "#t" }

---------------------------------------------------------------- история
function L.statsInit()
  local up = computer.uptime()
  local X = { S = {}, T = {}, F = {}, clean = {}, samples = 0, polluteUntil = 0,
              evT = L.ring(300), evA = L.ring(300), evS = L.ring(300), evF = L.ring(300), startNow = L.now(),
              a10 = { t0 = up }, a5 = { t0 = up }, lastCompact = up }
  for _, k in ipairs(KEYS) do
    X.S[k] = L.ring(600) -- по секундам, 10 минут
    X.T[k] = L.ring(360) -- по 10 секунд, 1 час
    X.F[k] = L.ring(288) -- по 5 минут, сутки
  end
  X.F.time, X.F.s = L.ring(288), L.ring(288)
  L.st = X
  L.loadHistory()
end

function L.loadHistory()
  local X = L.st
  if not L.clk0 then return end -- без настоящего времени историю не склеить
  local lim, keep = L.now() - 86400, {}
  for _, line in ipairs(L.readLines()) do
    local f = {}
    for w in line:gmatch("%S+") do f[#f + 1] = w end
    local tm = tonumber(f[2])
    if tm and tm >= lim then
      if f[1] == "B" then
        X.F.time:push(tm)
        for j, k in ipairs(KEYS) do X.F[k]:push(tonumber(f[2 + j]) or false) end
        X.F.s:push(tonumber(f[3 + #KEYS]) or false)
        keep[#keep + 1] = line
      elseif f[1] == "T" and tonumber(f[3]) then
        X.evT:push(tm); X.evA:push(tonumber(f[3])); X.evS:push(tonumber(f[4]) or false); X.evF:push(f[5] == "F")
        X.lastTr, X.lastAmt, X.lastFail = tm, tonumber(f[3]), f[5] == "F"
        X.target = tonumber(f[4]) or X.target
        keep[#keep + 1] = line
      end
    end
  end
  L.writeLines(keep)
end

function L.compactHistory()
  local X = L.st
  if not X or not L.clk0 then return end
  local lines = {}
  for k = 1, X.F.time.n do
    local p = { "B", L.fnum(X.F.time:get(k)) }
    for _, key in ipairs(KEYS) do p[#p + 1] = L.fnum(X.F[key]:get(k)) end
    p[#p + 1] = L.fnum(X.F.s:get(k))
    lines[#lines + 1] = table.concat(p, " ")
  end
  for k = 1, X.evT.n do
    lines[#lines + 1] = "T " .. L.fnum(X.evT:get(k)) .. " " .. L.fnum(X.evA:get(k)) .. " " .. L.fnum(X.evS:get(k))
      .. (X.evF:get(k) and " F" or "")
  end
  L.writeLines(lines)
end

function L.resetHistory()
  local X = L.st
  for _, g in ipairs({ X.S, X.T, X.F }) do for _, r in pairs(g) do r:clear() end end
  X.evT:clear(); X.evA:clear(); X.evS:clear(); X.evF:clear()
  X.lastTr, X.lastAmt, X.target, X.lastFail = nil, nil, nil, nil
  L.writeLines({})
end

---------------------------------------------------------------- переливы
-- a > 0 — в сеть, a < 0 — из сети; failed — сеть не отдала (запас не изменился)
function L.onTransfer(a, stored, failed, when)
  local X, now = L.st, when or L.now()
  local target = failed and (stored - a) or stored
  X.lastTr, X.lastAmt, X.target, X.lastFail = now, a, target, failed or false
  X.evT:push(now); X.evA:push(a); X.evS:push(target); X.evF:push(failed or false)
  if L.clk0 then
    L.appendLine("T " .. L.fnum(now) .. " " .. L.fnum(a) .. " " .. L.fnum(target) .. (failed and " F" or ""))
  end
end

local function accAdd(a, c)
  for _, k in ipairs(KEYS) do
    local v = c[k]
    if type(v) == "number" then a[k] = (a[k] or 0) + v; a[CNT[k]] = (a[CNT[k]] or 0) + 1 end
  end
end
local function accAvg(a, k)
  local n = a[CNT[k]]
  return n and a[k] / n or false
end

---------------------------------------------------------------- опрос раз в секунду
function L.sample(m)
  local X = L.st
  local d = L.readData(m)
  local up = computer.uptime()
  local ticks = X.prevT and (up - X.prevT) * 20 or nil
  if ticks and ticks <= 0 then ticks = nil end
  local c = X.clean

  -- Перелив: раз в 5 минут LSC сбрасывает излишек в сеть или берёт недостачу.
  -- Запас при этом прыгает сильнее, чем могли дать вход и выход за секунду,
  -- а в сети меняется на ту же величину с обратным знаком.
  if d.stored and X.prevS and ticks and d.wireless ~= false and X.samples >= 3 then
    local R = d.stored - X.prevS - (c.n or 0) * ticks
    local gross = math.abs(c.i or 0) + math.abs(c.o or 0) + math.abs(c.n or 0)
    if math.abs(R) > math.max(gross * ticks * 3, 1e7) then
      local ok = true
      if d.wEU and X.prevW then ok = math.abs(d.wEU - X.prevW + R) < 0.25 * math.abs(R) end
      if ok then
        X.polluteUntil = up + 5.2 -- средние LSC за 5 секунд «испорчены» переливом
        X.lastJumpUp, X.prov = up, nil
        L.onTransfer(-R, d.stored)
      end
    end
  end

  -- Неудачный перелив: в сети не хватило EU, запас не изменился, но LSC всё равно
  -- записал всю сумму во вход (или выход) за один тик — среднее за 5 с взлетает.
  -- При резком скачке сначала придерживаем значения, через 5,3 с проверяем:
  -- вернулось назад — это был перелив; осталось высоким — вход и правда вырос.
  local pv = X.prov
  if pv and up >= pv.up0 + 5.3 then
    X.prov = nil
    local spikeIn = pv.di >= pv.dout
    local back = d.inS and d.outS and
      ((spikeIn and d.inS - pv.bi < pv.di * 0.5) or (not spikeIn and d.outS - pv.bo < pv.dout * 0.5))
    if back and d.wireless then
      L.onTransfer(spikeIn and -pv.di * 100 or pv.dout * 100, d.stored or 0, true, L.now() - (up - pv.up0))
    end
  end
  if not X.prov and X.samples >= 3 and c.i and c.o and d.inS and d.outS and d.wireless ~= false
     and up - (X.lastJumpUp or -1e9) > 6 then
    local thr = math.max((math.abs(c.i) + math.abs(c.o)) * 5, 1e8)
    local di, dout = d.inS - c.i, d.outS - c.o
    if di > thr or dout > thr then
      X.prov = { up0 = up, di = di, dout = dout, bi = c.i, bo = c.o }
      X.polluteUntil = math.max(X.polluteUntil, up + 5.3)
    end
  end
  -- мелкий перелив по запасу не заметен, но он идёт строго раз в 5 минут:
  -- около ожидаемого момента тоже держим прошлые значения
  if d.wireless and X.lastTr and up >= X.polluteUntil then
    local ph = (L.now() - X.lastTr) % L.REBALANCE
    if ph >= L.REBALANCE - 1.1 or ph <= 0.1 then X.polluteUntil = up + 6.5 end
  end

  -- чистые значения; пока средние испорчены переливом — держим прошлые
  if up >= X.polluteUntil then
    local ci, co, cn, cw = d.inS, d.outS, nil, nil
    if ci and co then cn = ci - co - (d.loss or 0)
    elseif d.stored and X.prevS and ticks then cn = (d.stored - X.prevS) / ticks end
    if d.wEU and X.prevW and ticks then cw = (d.wEU - X.prevW) / ticks end
    c.i, c.o, c.n, c.w = ci, co, cn, cw
    c.t = cn and (cn + ((d.wireless and cw) or 0)) or nil
  end
  d.polluted = up < X.polluteUntil

  for _, k in ipairs(KEYS) do X.S[k]:push(c[k] or false) end
  accAdd(X.a10, c); accAdd(X.a5, c)
  if up - X.a10.t0 >= 10 then
    for _, k in ipairs(KEYS) do X.T[k]:push(accAvg(X.a10, k)) end
    X.a10 = { t0 = up }
  end
  if up - X.a5.t0 >= 300 then
    local now = L.now()
    local p = { "B", L.fnum(now) }
    X.F.time:push(now)
    for _, k in ipairs(KEYS) do
      local v = accAvg(X.a5, k)
      X.F[k]:push(v); p[#p + 1] = L.fnum(v)
    end
    X.F.s:push(d.stored or false); p[#p + 1] = L.fnum(d.stored)
    if L.clk0 then L.appendLine(table.concat(p, " ")) end
    X.a5 = { t0 = up }
  end
  if up - X.lastCompact >= 6 * 3600 then L.compactHistory(); X.lastCompact = up end

  if d.stored then X.prevS = d.stored end
  if d.wEU then X.prevW = d.wEU end
  X.prevT = up
  X.samples = X.samples + 1
  return d
end

---------------------------------------------------------------- средние
function L.stats(d)
  local X, A = L.st, {}
  local now = L.now()
  -- час: свежие 10-секундные записи + 5-минутные с диска за время до запуска
  local function hourMean(k)
    local T = X.T[k]
    local tm, tdur = T:mean(), T.n * 10
    if tdur >= 3600 then return tm end
    local s, c = 0, 0
    for j = 1, X.F[k].n do
      local ft = X.F.time:get(j)
      if ft >= now - 3600 and ft <= X.startNow then
        local v = X.F[k]:get(j)
        if type(v) == "number" then s = s + v; c = c + 1 end
      end
    end
    if c == 0 then return tm end
    if not tm then return s / c end
    local fdur = math.min(c * 300, 3600 - tdur)
    return (tm * tdur + s / c * fdur) / (tdur + fdur)
  end
  for _, k in ipairs(KEYS) do
    A[k .. "1"] = X.S[k]:mean(60)
    A[k .. "5"] = X.S[k]:mean(300)
    A[k .. "60"] = hourMean(k) or A[k .. "5"]
    A[k .. "D"] = X.F[k].n > 0 and X.F[k]:mean() or nil
  end
  -- без беспроводного режима точнее средние самого LSC
  if d.wireless == false then
    local loss = d.loss or 0
    if d.in5 and d.out5 then A.i5, A.o5 = d.in5, d.out5; A.n5 = d.in5 - d.out5 - loss; A.t5 = A.n5 end
    if d.in1h and d.out1h then A.i60, A.o60 = d.in1h, d.out1h; A.n60 = d.in1h - d.out1h - loss; A.t60 = A.n60 end
  end
  A.wl = d.wireless == true
  A.cov = X.F.time.n * 300
  A.reserve = (d.stored or 0) + ((A.wl and d.wEU) or 0)
  for k = 1, X.F.o.n do
    local v = X.F.o:get(k)
    if type(v) == "number" and (not A.peak or v > A.peak) then A.peak = v end
  end
  for k = 1, X.F.s.n do
    local v = X.F.s:get(k)
    if type(v) == "number" then
      if not A.sMin or v < A.sMin then A.sMin = v end
      A.sFirst = A.sFirst or v
    end
  end
  A.trPush, A.trPull, A.trCount, A.trFailN = 0, 0, 0, 0
  for k = 1, X.evT.n do
    if now - X.evT:get(k) <= 86400 then
      local a = X.evA:get(k)
      A.trCount = A.trCount + 1
      if X.evF:get(k) then A.trFailN = A.trFailN + 1
      elseif a > 0 then A.trPush = A.trPush + a else A.trPull = A.trPull - a end
    end
  end
  if X.lastTr then
    local since = now - X.lastTr
    A.trAgo, A.trLast, A.trFail = since, X.lastAmt, X.lastFail
    A.trNext = L.REBALANCE - since % L.REBALANCE
  end
  A.target = X.target
  return A
end

---------------------------------------------------------------- сирена
L.al = { level = 0, cand = 0, since = 0, why = {}, muteUntil = 0, mutedLevel = 0, test = 0, lastBeep = 0, shown = 0 }
local rsDev

function L.alarmInit() rsDev = component.isAvailable("redstone") and component.redstone or nil end

function L.setRedstone(v)
  local al = L.al
  if not rsDev or al.rs == v then return end
  al.rs = v
  for s = 0, 5 do pcall(rsDev.setOutput, s, v) end
end

function L.muted()
  local al = L.al
  return computer.uptime() < al.muteUntil and al.level <= al.mutedLevel
end
function L.mute()
  local al = L.al
  al.muteUntil = computer.uptime() + L.cfg.opts.muteMinutes * 60
  al.mutedLevel, al.test = al.level, 0
end
function L.unmute() L.al.muteUntil = 0 end
function L.testSiren() L.al.test = computer.uptime() + 5; L.al.muteUntil = 0 end

-- уровень по совокупности факторов: 0 — норма, 1 — внимание, 2 — тревога
function L.evalAlarm(d, A)
  local o, why, lvl = L.cfg.opts, {}, 0
  local function add(l, s) if l > lvl then lvl = l end; why[#why + 1] = s end
  local f1, f5 = A.t1, A.t5
  local drain = f1 and f1 < 0 and (f5 == nil or f5 < 0)            -- минус и за 1, и за 5 минут
  local tte = (drain and A.reserve > 0) and A.reserve / (-f1 * 20) or nil
  local drop = A.i1 and A.i60 and A.i60 > 0 and A.i1 < A.i60 * o.inputDrop / 100
  if drain and tte and tte < o.critMinutes * 60 then
    add(2, "энергия кончится через " .. L.dur(tte))
  elseif drain and drop and tte and tte < o.warnHours * 3600 then
    add(2, "упал вход и идёт разряд, ноль через " .. L.dur(tte))
  elseif drain and tte and tte < o.warnHours * 3600 then
    add(1, "разряд, ноль через " .. L.dur(tte))
  end
  if drop and lvl < 2 then add(1, string.format("вход упал до %.0f%% от среднего за час", A.i1 / A.i60 * 100)) end
  if d.maint == false then add(1, "нужен ремонт") end
  if d.on == false then add(1, "конденсатор выключен") end
  return lvl, why
end

function L.updateAlarm(d, A)
  local o, al, t = L.cfg.opts, L.al, computer.uptime()
  local lvl, why = L.evalAlarm(d, A)
  -- задержка на срабатывание и на снятие: короткие скачки не дёргают сирену
  if lvl > al.level then
    if al.cand ~= lvl then al.cand, al.since = lvl, t end
    if t - al.since >= o.confirm then al.level, al.lowSince = lvl, nil end
  elseif lvl < al.level then
    al.cand = lvl
    al.lowSince = al.lowSince or t
    if t - al.lowSince >= o.clear then al.level, al.lowSince = lvl, nil end
  else
    al.cand, al.lowSince = lvl, nil
  end
  al.why = why
  if al.level > al.mutedLevel then al.muteUntil = 0 end -- стало хуже — звук снова включается

  local testing = t < al.test
  local lv = testing and 2 or al.level
  al.shown, al.testing = lv, testing
  local quiet = L.muted() and not testing
  if o.sound and lv > 0 and not quiet then
    if lv >= 2 then
      computer.beep(1400, 0.12); computer.beep(900, 0.12)
    elseif t - al.lastBeep >= 15 then
      computer.beep(700, 0.08); al.lastBeep = t
    end
  end
  local want = (o.redstone == "crit" and lv >= 2) or (o.redstone == "warn" and lv >= 1)
  L.setRedstone((want and not quiet) and 15 or 0)
end

return L
]===],
  ["lscm_gfx"] = [===[
-- lscm_gfx.lua — экранный буфер, палитра, рисование, анимации
local L = require("lscm_core")
local component = require("component")
local computer  = require("computer")
local gpu = component.gpu
local P, len = L.P, L.len
local W, H, N = 0, 0, 0
local CH, FG, BG = {}, {}, {}
L.FB = { ch = CH, fg = FG, bg = BG } -- для фоновых анимаций
local UTF = "[\1-\127\194-\244][\128-\191]*"
L.hits = {}

---------------------------------------------------------------- экран и палитра
local function chooseRes(maxW, maxH)
  local okS, aw, ah = pcall(component.invoke, gpu.getScreen(), "getAspectRatio")
  if not okS or not aw or not ah then return math.min(maxW, 80), math.min(maxH, 25) end
  local ratio = 2 * (aw - 0.25) / (ah - 0.25) -- символ вдвое выше, чем шире
  local w, h = 80, math.floor(80 / ratio + 0.5)
  if h < 25 then h = 25; w = math.floor(h * ratio + 0.5) end
  if w > maxW then w = maxW; h = math.floor(w / ratio + 0.5) end
  if h > maxH then h = maxH; w = math.floor(h * ratio + 0.5) end
  return math.max(60, math.min(w, maxW)), math.max(20, math.min(h, maxH))
end

function L.applyPalette()
  local cols = L.cfg.colors
  local function set() for i = 1, #L.ROLES do pcall(gpu.setPaletteColor, i - 1, cols[i]) end end
  if L.buf then pcall(gpu.setActiveBuffer, 0) end
  set()
  if L.buf then pcall(gpu.setActiveBuffer, L.buf); set(); pcall(gpu.setActiveBuffer, 0) end
end

function L.gfxInit()
  local maxW, maxH = gpu.maxResolution()
  if maxW < 60 or maxH < 20 then
    error("Нужны видеокарта и экран 2-го тира или выше (сейчас максимум " .. maxW .. "x" .. maxH .. ")", 0)
  end
  L.oldW, L.oldH = gpu.getResolution()
  W, H = chooseRes(maxW, maxH)
  gpu.setResolution(W, H)
  L.W, L.H, N = W, H, W * H
  L.oldPal = {}
  for i = 0, 15 do local ok, c = pcall(gpu.getPaletteColor, i); if ok then L.oldPal[i] = c end end
  -- видеобуфер не нужен: на экран уходят только изменившиеся клетки
  L.applyPalette()
  for i = 1, N do CH[i] = " "; FG[i] = P.text; BG[i] = P.bg end
end

function L.gfxDone()
  if L.buf then pcall(gpu.setActiveBuffer, 0); pcall(gpu.freeBuffer, L.buf); L.buf = nil end
  for i = 0, 15 do if L.oldPal[i] then pcall(gpu.setPaletteColor, i, L.oldPal[i]) end end
  gpu.setResolution(L.oldW, L.oldH)
  gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
end

---------------------------------------------------------------- рисование в буфер
-- LK: в какой кадр в клетку писали текст — фоновая анимация такие клетки не трогает
local LK, frame = {}, 0
L.FB.lk = LK
function L.frameNo() return frame end
function L.clear(bg) frame = frame + 1; for i = 1, N do CH[i] = " "; BG[i] = bg end end

function L.put(x, y, s, fg, bg) -- bg = nil: фон под текстом не меняется
  if y < 1 or y > H then return x end
  local base, i = (y - 1) * W, 0
  for ch in s:gmatch(UTF) do
    local xx = x + i
    if xx >= 1 and xx <= W then
      local k = base + xx
      CH[k] = ch; LK[k] = frame
      if fg then FG[k] = fg end
      if bg then BG[k] = bg end
    end
    i = i + 1
  end
  return x + i
end

function L.putIfEmpty(x, y, ch, fg)
  if x < 1 or x > W or y < 1 or y > H then return end
  local k = (y - 1) * W + x
  if CH[k] == " " then CH[k] = ch; FG[k] = fg end
end

function L.fill(x, y, w, h, bg, ch, fg)
  ch = ch or " "
  for yy = math.max(1, y), math.min(H, y + h - 1) do
    local base = (yy - 1) * W
    for xx = math.max(1, x), math.min(W, x + w - 1) do
      local k = base + xx
      CH[k] = ch
      if bg then BG[k] = bg end
      if fg then FG[k] = fg end
    end
  end
end

-- стиль темы: рамки, скобки заголовков и кнопок, значок, символ крупных цифр, шапка, полоса
L.STYLES = {
  space  = { box = { "╭", "╮", "╰", "╯", "─", "│" }, tl = "┤", tr = "├", bl = " ", br = " ",
             icon = "◆", big = "█", head = "shine",  bar = "space" },
  matrix = { box = { "┌", "┐", "└", "┘", "─", "│" }, tl = "[", tr = "]", bl = "[", br = "]",
             icon = ">", big = "▓", head = "cursor", bar = "matrix" },
  neon   = { box = { "╔", "╗", "╚", "╝", "═", "║" }, tl = "╡", tr = "╞", bl = " ", br = " ",
             icon = "▶", big = "█", head = "glow",   bar = "neon" },
  aurora = { box = { "╭", "╮", "╰", "╯", "─", "│" }, tl = "(", tr = ")", bl = " ", br = " ",
             icon = "≈", big = "█", head = "aurora", bar = "aurora" },
  mars   = { box = { "┏", "┓", "┗", "┛", "━", "┃" }, tl = "┫", tr = "┣", bl = " ", br = " ",
             icon = "▲", big = "█", head = "hazard", bar = "mars" },
  plain  = { box = { "┌", "┐", "└", "┘", "─", "│" }, tl = " ", tr = " ", bl = " ", br = " ",
             icon = "■", big = "█", head = "none",   bar = "plain" },
}
function L.style() return L.STYLES[L.cfg.style] or L.STYLES.space end

function L.boxStyled(S, x, y, w, h, title, bg, bc, tc)
  local b = S.box
  L.fill(x, y, w, h, bg)
  L.put(x, y, b[1] .. string.rep(b[5], w - 2) .. b[2], bc, bg)
  L.put(x, y + h - 1, b[3] .. string.rep(b[5], w - 2) .. b[4], bc, bg)
  for yy = y + 1, y + h - 2 do L.put(x, yy, b[6], bc, bg); L.put(x + w - 1, yy, b[6], bc, bg) end
  if title then
    local s = L.fit(title, w - 6)
    L.put(x + 1, y, S.tl, bc, bg)
    L.put(x + 2, y, " " .. s .. " ", tc, bg)
    L.put(x + 4 + len(s), y, S.tr, bc, bg)
  end
end

function L.box(x, y, w, h, title, o)
  L.boxStyled(L.style(), x, y, w, h, title, (o and o.bg) or P.panel, (o and o.border) or P.border,
    (o and o.title) or P.accent)
end

-- бегущая строка: если текст не влезает в w, он плавно прокручивается (пауза 2 с в начале)
function L.mq(s, w)
  local n = len(s)
  if w <= 0 or n <= w then return L.fit(s, w) end
  local gap = "   ·   "
  local total = n + len(gap)
  local speed, pause = 4, 2
  local ph = (L.t or 0) % (total / speed + pause)
  local off = ph < pause and 0 or math.floor((ph - pause) * speed)
  return L.usub(s .. gap .. s, off + 1, off + w)
end

function L.hit(x1, y1, x2, y2, fn) L.hits[#L.hits + 1] = { x1, y1, x2, y2, fn } end

-- стили: on — выбранная, off — обычная, danger — красная
function L.button(x, y, label, style, fn)
  local fg, bg, S = P.text, P.btn, L.style()
  if style == "on" then fg, bg = P.bg, P.accent
  elseif style == "danger" then fg, bg = P.star, P.bad end
  local x2 = L.put(x, y, S.bl .. label .. S.br, fg, bg) - 1
  L.hit(x, y, x2, y, fn)
  return x2 + 1
end

function L.dim() -- «затемнить» всё под окном
  for i = 1, N do BG[i] = P.bg; if CH[i] ~= " " then FG[i] = P.border end end
end

local run = {}
local function setB(c) if c < 0 then gpu.setBackground(-c - 1, true) else gpu.setBackground(c) end end
local function setF(c) if c < 0 then gpu.setForeground(-c - 1, true) else gpu.setForeground(c) end end

-- то, что уже стоит на экране: перерисовываются только изменившиеся клетки
local PCH, PFG, PBG, lastFull = {}, {}, {}, -1e9
function L.invalidate() PCH, PFG, PBG = {}, {}, {} end
local function same(i)
  local c = CH[i]
  return c == PCH[i] and BG[i] == PBG[i] and (c == " " or FG[i] == PFG[i])
end

function L.flush()
  local now = computer.uptime()
  if now - lastFull > 60 then L.invalidate(); lastFull = now end -- раз в минуту — полностью
  local curB, curF
  for y = 1, H do
    local base, x = (y - 1) * W, 1
    while x <= W do
      local i = base + x
      if same(i) then
        x = x + 1
      else
        -- кусок одного цвета от первой изменившейся клетки до последней изменившейся
        local b, ch = BG[i], CH[i]
        local f = ch ~= " " and FG[i] or nil
        local n, k, lastCh = 1, x + 1, x
        run[1] = ch
        while k <= W do
          local j = base + k
          if BG[j] ~= b then break end
          local c2 = CH[j]
          if c2 ~= " " then
            local f2 = FG[j]
            if f == nil then f = f2 elseif f2 ~= f then break end
          end
          n = n + 1; run[n] = c2
          if not same(j) then lastCh = k end
          k = k + 1
        end
        if b ~= curB then setB(b); curB = b end
        if f and f ~= curF then setF(f); curF = f end
        gpu.set(x, y, table.concat(run, "", 1, lastCh - x + 1))
        for q = base + x, base + lastCh do PCH[q], PBG[q], PFG[q] = CH[q], BG[q], FG[q] end
        x = lastCh + 1
      end
    end
  end
end

---------------------------------------------------------------- цвета
function L.mix(a, b, t)
  t = math.max(0, math.min(1, t))
  local function ch(c, s) return math.floor(c / s) % 256 end
  local r = ch(a, 65536) + (ch(b, 65536) - ch(a, 65536)) * t
  local g = ch(a, 256) + (ch(b, 256) - ch(a, 256)) * t
  local bl = ch(a, 1) + (ch(b, 1) - ch(a, 1)) * t
  return math.floor(r) * 65536 + math.floor(g) * 256 + math.floor(bl)
end
function L.grad(t) -- красный → жёлтый → зелёный из цветов темы
  if t < 0.5 then return L.mix(L.col("bad"), L.col("warn"), t * 2) end
  return L.mix(L.col("warn"), L.col("good"), (t - 0.5) * 2)
end
function L.hsv2rgb(h, s, v)
  local hh = (h % 1) * 6
  local i, f = math.floor(hh), hh - math.floor(hh)
  local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  local r, g, b
  if i == 0 then r, g, b = v, t, p elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v else r, g, b = v, p, q end
  return math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 + math.floor(b * 255 + 0.5)
end
function L.rgb2hsv(c)
  local r, g, b = math.floor(c / 65536) % 256 / 255, math.floor(c / 256) % 256 / 255, c % 256 / 255
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d, h = mx - mn, 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
    h = h / 6
  end
  return h, mx > 0 and d / mx or 0, mx
end

---------------------------------------------------------------- крупные цифры
local FONT = {
  ["0"] = { "███", "█ █", "█ █", "█ █", "███" }, ["1"] = { " █ ", "██ ", " █ ", " █ ", "███" },
  ["2"] = { "███", "  █", "███", "█  ", "███" }, ["3"] = { "███", "  █", "███", "  █", "███" },
  ["4"] = { "█ █", "█ █", "███", "  █", "  █" }, ["5"] = { "███", "█  ", "███", "  █", "███" },
  ["6"] = { "███", "█  ", "███", "█ █", "███" }, ["7"] = { "███", "  █", "  █", "  █", "  █" },
  ["8"] = { "███", "█ █", "███", "█ █", "███" }, ["9"] = { "███", "█ █", "███", "  █", "███" },
  ["."] = { " ", " ", " ", " ", "█" },            ["-"] = { "   ", "   ", "███", "   ", "   " },
}
function L.bigWidth(s)
  local w = 0
  for i = 1, #s do local g = FONT[s:sub(i, i)]; if g then w = w + len(g[1]) + 1 end end
  return math.max(0, w - 1)
end
function L.bigText(x, y, s, col, bg)
  local big = L.style().big
  for i = 1, #s do
    local g = FONT[s:sub(i, i)]
    if g then
      for r = 1, 5 do L.put(x, y + r - 1, big == "█" and g[r] or (g[r]:gsub("█", big)), col, bg) end
      x = x + len(g[1]) + 1
    end
  end
end
-- крупное число + слово («58.02» + «трлн»); возвращает x и ширину для блика
function L.bigNumber(x, y, maxw, v, col, bg)
  if type(v) ~= "number" then L.put(x, y + 2, "нет данных", P.dim, bg); return end
  local n, i = L.scale(math.abs(v))
  local word, s = L.WORDS[i], nil
  for _, f in ipairs({ "%.2f", "%.1f", "%.0f" }) do
    s = (v < 0 and "-" or "") .. string.format(f, n)
    if L.bigWidth(s) + 1 + len(word) <= maxw then break end
  end
  local total = L.bigWidth(s) + (word ~= "" and 1 + len(word) or 0)
  local x0 = x + math.max(0, math.floor((maxw - total) / 2))
  L.bigText(x0, y, s, col, bg)
  if word ~= "" then L.put(x0 + L.bigWidth(s) + 1, y + 4, word, col, bg) end
  return x0, total
end

---------------------------------------------------------------- мини-график и большой график
local SPK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
function L.spark(x, y, w, ring, col, bg)
  local lo, hi = math.huge, -math.huge
  for age = 0, math.min(w, ring.n) - 1 do
    local v = ring:last(age)
    if type(v) == "number" then if v < lo then lo = v end; if v > hi then hi = v end end
  end
  if lo == math.huge then return end
  if hi - lo < 1e-9 then hi = lo + 1 end
  for age = 0, math.min(w, ring.n) - 1 do
    local v = ring:last(age)
    if type(v) == "number" then L.put(x + w - 1 - age, y, SPK[math.floor((v - lo) / (hi - lo) * 7 + 0.5) + 1], col, bg) end
  end
end

-- последние shown значений кольца → cols столбцов (старые слева)
function L.series(ring, shown, cols)
  local out, bucket = {}, shown / cols
  for i = 1, cols do
    local a = math.floor((i - 1) * bucket) + 1
    local b = math.max(a, math.floor(i * bucket))
    local s, c = 0, 0
    for j = a, b do
      local age = shown - j
      if age < ring.n then
        local v = ring:last(age)
        if type(v) == "number" then s = s + v; c = c + 1 end
      end
    end
    out[i] = c > 0 and s / c or false
  end
  return out
end

L.GL = 12 -- ширина подписей шкалы слева
function L.plot(x, y, w, h, vals, colP, colN)
  L.fill(x, y, w, h, P.panel)
  local px, pw = x + L.GL, w - L.GL
  local lo, hi = math.huge, -math.huge
  for i = 1, pw do local v = vals[i]; if v then if v < lo then lo = v end; if v > hi then hi = v end end end
  if lo == math.huge then
    L.put(px + math.floor((pw - 10) / 2), y + math.floor(h / 2), "нет данных", P.dim)
    return
  end
  lo, hi = math.min(lo, 0), math.max(hi, 0)
  if hi - lo < 1e-9 then hi = lo + 1 end
  local H2 = h * 2
  local z = -lo / (hi - lo) * H2
  local r0 = math.max(0, math.min(h - 1, h - 1 - math.floor(z / 2)))
  for r = 0, h - 1 do
    local base, yy = (h - 1 - r) * 2, y + r
    local rowBg = r == r0 and P.panel2 or P.panel
    local col = (base + 1 >= z) and colP or colN
    for i = 1, pw do
      local v, ch = vals[i], " "
      if v then
        local lv = (v - lo) / (hi - lo) * H2
        local a, b = math.min(z, lv), math.max(z, lv)
        local low = a <= base + 0.5 and base + 0.5 <= b
        local up = a <= base + 1.5 and base + 1.5 <= b
        ch = (low and up) and "█" or (up and "▀" or (low and "▄" or " "))
      end
      local k = (yy - 1) * W + px + i - 1
      CH[k] = ch; FG[k] = col; BG[k] = rowBg
    end
  end
  local function lab(r, s) s = L.fit(s, L.GL - 2); L.put(x + L.GL - 1 - len(s), y + r, s, P.dim) end
  if hi > 0 and r0 ~= 0 then lab(0, L.short(hi)) end
  if lo < 0 and r0 ~= h - 1 then lab(h - 1, L.short(lo)) end
  lab(r0, "0")
  return lo, hi, px, pw
end

---------------------------------------------------------------- анимации
local stars, met = {}, nil
function L.initStars()
  stars = {}
  local dens = ({ 0, 0.025, 0.05, 0.09 })[(L.cfg.opts.stars or 2) + 1] or 0.05
  for i = 1, math.floor(W * H * dens) do
    stars[i] = { math.random(1, W), math.random(1, H), math.random(), 0.15 + math.random() * 0.6 }
  end
end

function L.drawStars(t) -- мерцают только там, где их не закрыли панели
  local anim = L.cfg.opts.anim
  for _, s in ipairs(stars) do
    local b = anim and (math.sin((t * s[4] + s[3]) * 6.283) + 1) / 2 or s[3]
    local ch, col
    if b > 0.93 then ch, col = "*", P.star
    elseif b > 0.78 then ch, col = "+", P.star
    elseif b > 0.55 then ch, col = "•", P.dim
    elseif b > 0.3 then ch, col = "·", P.dim
    else ch, col = "·", P.border end
    local k = (s[2] - 1) * W + s[1]
    CH[k] = ch; FG[k] = col
  end
end

local metT
function L.drawMeteor(rows, t) -- падающая звезда; скорость в клетках/с, не зависит от FPS
  local o = L.cfg.opts
  local dt = math.min(0.5, t - (metT or t)); metT = t
  if not (o.anim and o.meteors) then met = nil; return end
  if not met then
    if math.random() < 0.06 * dt then -- в среднем раз в ~15 секунд
      local dir = math.random() < 0.5 and 1 or -1
      met = { x = dir > 0 and -2 or W + 2, y = rows[math.random(#rows)], dx = dir * (22 + math.random() * 18) }
    end
    return
  end
  met.x = met.x + met.dx * dt
  local hx, step = math.floor(met.x), met.dx > 0 and -1 or 1
  local trail = { P.star, P.star, P.text, P.accent, P.dim, P.dim, P.border, P.border }
  for k = 0, #trail - 1 do
    local x = hx + k * step
    if x >= 1 and x <= W then
      local i = (met.y - 1) * W + x
      CH[i] = k == 0 and "●" or (k < 3 and "━" or "─"); FG[i] = trail[k + 1]
    end
  end
  if hx < -10 or hx > W + 10 then met = nil end
end

function L.shine(x, y, w, h, t, period, col) -- блик пробегает по тексту раз в period секунд
  if not L.cfg.opts.anim then return end
  local ph = t % period
  if ph > 1.2 then return end
  local p = math.floor(x - 4 + ph / 1.2 * (w + 8))
  for yy = y, y + h - 1 do
    local a = p + (yy - y)
    for xx = math.max(x, a), math.min(x + w - 1, a + 2) do
      local i = (yy - 1) * W + xx
      if CH[i] ~= " " then FG[i] = col end
    end
  end
end

---------------------------------------------------------------- всплывающие окна
function L.toast(msg, col)
  L.toastMsg, L.toastCol, L.toastUntil = msg, col or P.good, computer.uptime() + 2.5
end
function L.drawToast()
  if not L.toastMsg or computer.uptime() > L.toastUntil then return end
  local s = " " .. L.toastMsg .. " "
  local w = len(s) + 2
  L.box(W - w, H - 4, w, 3, nil, { border = L.toastCol })
  L.put(W - w + 1, H - 3, s, L.toastCol, P.panel)
end

-- окно подтверждения: md = { title, text = {...}, buttons = {{подпись, стиль, функция}}, danger }
function L.drawModal(md)
  L.hits = {}
  L.dim()
  local w = math.max(40, len(md.title) + 10)
  for _, line in ipairs(md.text) do w = math.max(w, len(line) + 6) end
  local h = #md.text + 6
  local x, y = math.floor((W - w) / 2) + 1, math.floor((H - h) / 2) + 1
  local c = md.danger and P.bad or P.accent
  L.box(x, y, w, h, md.title, { border = c, title = c })
  for k, line in ipairs(md.text) do L.put(x + 3, y + 1 + k, line, P.text, P.panel) end
  local bx = x + w - 3
  for k = #md.buttons, 1, -1 do
    local b = md.buttons[k]
    bx = bx - (len(b[1]) + 2) + 1
    L.button(bx, y + h - 2, b[1], b[2], function() L.ui.modal = nil; b[3]() end)
    bx = bx - 3
  end
end

return L
]===],
  ["lscm_fx"] = [===[
-- lscm_fx.lua — фоновые анимации под каждую тему (рисуются только в свободных клетках фона)
local L = require("lscm_core")
local component = require("component")
local gpu = component.gpu
local P = L.P

L.DEFAULT_OPTS.fx = L.DEFAULT_OPTS.fx or "auto"
L.FX = { { "auto", "По теме" }, { "space", "Космос" }, { "rain", "Код" }, { "neon", "Неон" },
         { "aurora", "Сияние" }, { "dust", "Буря" }, { "grid", "Сетка" }, { "none", "Нет" } }
local BY_THEME = { ["Космос"] = "space", ["Неон"] = "neon", ["Аврора"] = "aurora",
                   ["Марс"] = "dust", ["Матрица"] = "rain", ["Графит"] = "grid" }

function L.fxName()
  local f = L.cfg.opts.fx or "auto"
  if f == "auto" then f = BY_THEME[L.cfg.theme] or "space" end
  return f
end

local st, lastT = {}, nil
local function dens() return ({ 0, 0.5, 1, 1.8 })[(L.cfg.opts.stars or 2) + 1] or 1 end

-- одна ячейка палитры (и на экране, и в видеобуфере)
function L.setPal(role, c)
  local idx = -P[role] - 1
  if L.buf then pcall(gpu.setActiveBuffer, 0) end
  pcall(gpu.setPaletteColor, idx, c)
  if L.buf then pcall(gpu.setActiveBuffer, L.buf); pcall(gpu.setPaletteColor, idx, c); pcall(gpu.setActiveBuffer, 0) end
end

local function newDrop(H)
  return { y = -math.random(0, H), sp = 6 + math.random() * 10, len = math.random(4, 12), on = math.random() < 0.45 * dens() }
end

local function init(name)
  local W, H = L.W, L.H
  if st.name == "neon" and name ~= "neon" then L.applyPalette() end -- вернуть рамкам обычный цвет
  st = { name = name, key = name .. ":" .. tostring(L.cfg.opts.stars) }
  if name == "rain" then
    st.cols = {}
    for x = 1, W do st.cols[x] = newDrop(H); st.cols[x].y = -math.random(0, H * 2) end
  elseif name == "dust" then
    st.p = {}
    for i = 1, math.floor(W * H * 0.03 * dens()) do
      st.p[i] = { x = math.random() * W, y = math.random(1, H), vx = 8 + math.random() * 14, ph = math.random() * 6.28 }
    end
  end
end

local CHARS = "0123456789ABCDEF<>=+*#$%&@"

function L.drawFx(t)
  local name = L.fxName()
  if st.key ~= name .. ":" .. tostring(L.cfg.opts.stars) then init(name) end
  local dt = math.min(0.5, t - (lastT or t)); lastT = t
  if not L.cfg.opts.anim or name == "space" or name == "none" then return end
  local W, H, FB, bgc = L.W, L.H, L.FB, P.bg
  local ch, fg, bg, lk, fr = FB.ch, FB.fg, FB.bg, FB.lk, L.frameNo()
  local function free(i) return bg[i] == bgc and ch[i] == " " and lk[i] ~= fr end

  if name == "rain" then -- цифровой дождь
    for x = 1, W do
      local c = st.cols[x]
      c.y = c.y + c.sp * dt
      if c.y - c.len > H then st.cols[x] = newDrop(H); c = st.cols[x] end
      if c.on then
        local hy = math.floor(c.y)
        for k = 0, c.len - 1 do
          local y = hy - k
          if y >= 1 and y <= H then
            local i = (y - 1) * W + x
            if free(i) then
              local n = (x * 31 + y * 17 + math.floor(t * (k == 0 and 12 or 3))) % #CHARS + 1
              ch[i] = CHARS:sub(n, n)
              fg[i] = k == 0 and P.star or (k < 3 and P.good or (k < c.len - 2 and P.dim or P.border))
            end
          end
        end
      end
    end

  elseif name == "neon" then -- пульс рамок, строка развёртки, искры
    local k = (math.sin(t * 2.2) + 1) / 2
    L.setPal("border", L.mix(L.col("border"), L.col("accent"), 0.15 + 0.55 * k))
    local y1 = math.floor(t * 8) % (H + 12) + 1
    for d = 0, 2 do
      local y = y1 - d
      if y >= 1 and y <= H then
        for x = 1, W do
          local i = (y - 1) * W + x
          if free(i) then ch[i] = d == 0 and "━" or "─"; fg[i] = d == 0 and P.accent or P.border end
        end
      end
    end
    local slot = math.floor(t * 3)
    for n = 1, math.floor(8 * dens()) do
      local s = (slot * 9301 + n * 49297) % 233280
      local i = s % (W * H) + 1
      if free(i) then ch[i] = (s % 3 == 0) and "*" or "+"; fg[i] = (s % 2 == 0) and P.out or P.accent end
    end

  elseif name == "aurora" then -- северное сияние
    local g, a, o = L.col("good"), L.col("accent"), L.col("out")
    local thr = 0.75 - 0.15 * dens()
    for y = 1, H do
      local band = math.sin(y * 0.35 + t * 0.6)
      for x = 1, W do
        local i = (y - 1) * W + x
        if free(i) then
          local v = (math.sin(x * 0.11 + t * 0.9 + band * 1.5) + 1) / 2 * (0.65 + 0.35 * math.sin(t * 0.4 + x * 0.03))
          if v > thr then
            ch[i] = v > thr + 0.2 and "▒" or "░"
            local m = (math.sin(x * 0.05 - t * 0.35 + y * 0.1) + 1) / 2
            fg[i] = m < 0.5 and L.mix(g, a, m * 2) or L.mix(a, o, (m - 0.5) * 2)
          end
        end
      end
    end

  elseif name == "dust" then -- пылевая буря с порывами
    if not st.gustT or t > st.gustT then st.gustT = t + 12 + math.random() * 15; st.gustUntil = t + 3 end
    local gust = t < (st.gustUntil or 0) and 2.5 or 1
    for _, p in ipairs(st.p) do
      p.x = p.x + p.vx * gust * dt
      if p.x > W + 1 then p.x = 0; p.y = math.random(1, H) end
      local x, y = math.floor(p.x), math.floor(p.y + math.sin(t * 2 + p.ph) * 0.6 + 0.5)
      if x >= 1 and x <= W and y >= 1 and y <= H then
        local i = (y - 1) * W + x
        if free(i) then
          ch[i] = gust > 1 and "─" or (p.vx > 16 and "∙" or "·")
          fg[i] = p.vx > 18 and P.warn or (p.vx > 12 and P.out or P.dim)
        end
      end
    end

  elseif name == "grid" then -- точечная сетка и световая волна
    for y = 2, H, 2 do
      for x = 2, W, 4 do
        local i = (y - 1) * W + x
        if free(i) then
          local v = math.sin((x + y * 2) * 0.12 - t * 1.6)
          ch[i] = v > 0.85 and "+" or "·"
          fg[i] = v > 0.85 and P.accent or (v > 0.4 and P.dim or P.border)
        end
      end
    end
  end
end

return L
]===],
  ["lscm_pages"] = [===[
-- lscm_pages.lua — шапка, подвал, «Обзор», «Статистика», управление
local L = require("lscm_core")
local computer = require("computer")
local P, len = L.P, L.len

local MODES = { { "t", "Баланс" }, { "i", "Вход" }, { "o", "Выход" } }
local PERIODS = { { 60, "1 мин" }, { 600, "10 мин" }, { 3600, "1 ч" }, { 86400, "24 ч" } }
local PAGES = { { "main", "Обзор" }, { "stats", "Статистика" }, { "set", "Настройки" } }
L.MODES, L.PERIODS = MODES, PERIODS

local function periodName(p) for _, x in ipairs(PERIODS) do if x[1] == p then return x[2] end end return "" end

---------------------------------------------------------------- шапка, тревога, подвал
function L.drawHeader(d, t)
  local W, S, anim = L.W, L.style(), L.cfg.opts.anim
  L.fill(1, 1, W, 1, P.title)
  if S.head == "aurora" and anim then -- шапка переливается сиянием
    local g, a, o, tb = L.col("good"), L.col("accent"), L.col("out"), L.col("title")
    for x = 1, W do
      local m = (math.sin(x * 0.09 - t * 0.7) + 1) / 2
      local c = m < 0.5 and L.mix(g, a, m * 2) or L.mix(a, o, (m - 0.5) * 2)
      L.FB.bg[x] = L.mix(tb, c, 0.2 + 0.25 * (math.sin(x * 0.05 + t * 0.4) + 1) / 2)
    end
  end
  local xr = W - 1
  local function chip(s, col, dot)
    local x0 = xr - len(s) + 1
    L.put(x0, 1, s, col)
    if dot then L.put(x0, 1, "●", dot) end
    xr = x0 - 3
  end
  local clock = L.clock(L.cfg.opts.tz)
  if clock then chip(clock, P.text) end
  if d.on ~= nil then
    local pulse = (not anim) or math.sin(t * 4) > -0.3
    chip(d.on and "● РАБОТАЕТ" or "● ОТКЛЮЧЁН", d.on and P.good or P.bad, d.on and (pulse and P.good or P.border) or P.bad)
  end
  if d.wireless then chip("≋ СЕТЬ", P.accent) end
  if d.maint == false then chip("▲ РЕМОНТ", P.warn) end

  local x = 2
  if S.head == "hazard" then -- сигнальные полосы
    local off = anim and math.floor(t * 3) % 2 or 0
    for k = 0, 3 do L.put(x + k, 1, (k + off) % 2 == 0 and "▚" or "▞", P.warn) end
    x = x + 5
  end
  L.put(x, 1, S.icon, P.accent)
  local tx, title = x + 2, L.TITLE
  if S.head == "cursor" then
    title = title:gsub(" ", "_") .. (((not anim) or math.floor(t * 2) % 2 == 0) and "█" or " ")
  end
  title = L.fit(title, xr - tx)
  local tcol = P.text
  if S.head == "glow" and anim then tcol = math.sin(t * 3) > 0.2 and P.accent or P.text end
  L.put(tx, 1, title, tcol)
  if S.head == "shine" then L.shine(tx, 1, len(title), 1, t, 8, P.star) end
end

function L.drawBanner(t)
  local al, W, H = L.al, L.W, L.H
  local lv = al.shown or 0
  if lv == 0 then return end
  local blink = (not L.cfg.opts.anim) or math.floor(t * 2) % 2 == 0
  local main = lv >= 2 and P.bad or P.warn
  local bg, fg = blink and main or P.bg2, blink and P.bg or main
  L.fill(1, 2, W, 1, bg)
  local s = (lv >= 2 and " ▲ ТРЕВОГА: " or " ▲ ВНИМАНИЕ: ")
  s = s .. (al.testing and "проверка сирены" or (#al.why > 0 and table.concat(al.why, " · ") or "условие снимается…"))
  if L.muted() and not al.testing then
    s = s .. string.format("  [звук выкл. ещё %.0f мин]", math.ceil((al.muteUntil - computer.uptime()) / 60))
  end
  local label = L.muted() and "Включить звук" or "Заглушить"
  local bx = W - len(label) - 2
  L.put(1, 2, L.mq(s, bx - 2), fg, bg)
  L.button(bx, 2, label, "off", function() if L.muted() then L.unmute() else L.mute() end end)
  if lv >= 2 and blink then -- красная рамка по краям экрана
    for y = 2, H - 1 do L.put(1, y, "▌", P.bad); L.put(W, y, "▐", P.bad) end
  end
end

function L.drawFooter()
  local W, H, ui = L.W, L.H, L.ui
  L.fill(1, H, W, 1, P.title)
  local x = 2
  for _, p in ipairs(PAGES) do
    x = L.button(x, H, p[2], ui.page == p[1] and "on" or "off", function() ui.page = p[1] end) + 1
  end
  local ex = "× ВЫХОД"
  local exX = W - len(ex) - 2
  L.button(exX, H, ex, "danger", function() L.askExit() end)
  local free, total = computer.freeMemory(), computer.totalMemory()
  local info = string.format("ОЗУ %.0f%% · %d к/с · #%d", (1 - free / total) * 100, L.fpsReal or 0, L.st.samples)
  if exX - len(info) - 3 > x then L.put(exX - len(info) - 3, H, info, P.dim, P.title) end
end

function L.askResetStats()
  L.ui.modal = { title = "СБРОС СТАТИСТИКИ", danger = true, default = 1,
    text = { "Удалить всю собранную историю?", "Средние за час и сутки начнут считаться заново." },
    buttons = { { "Отмена", "off", function() end },
                { "Удалить", "danger", function() L.resetHistory(); L.toast("Статистика очищена") end } } }
end

function L.askExit()
  L.ui.modal = {
    title = "ВЫХОД", danger = true, default = 2,
    text = { "Закрыть монитор?", "Статистика сохранится, сирена выключится." },
    buttons = { { "Отмена", "off", function() end }, { "× Выйти", "danger", function() L.ui.running = false end } },
  }
end

---------------------------------------------------------------- «Обзор»
function L.drawMain(d, A, t)
  local W, H, ui, X = L.W, L.H, L.ui, L.st
  local frac = (d.stored and d.cap and d.cap > 0) and math.min(1, d.stored / d.cap) or 0

  -- запас крупно, с бликом; в беспроводном режиме — вся энергия: LSC + сеть
  local total = d.stored
  if A.wl and d.wEU then total = (d.stored or 0) + d.wEU end
  L.box(2, 3, 30, 7, A.wl and "ЗАПАС: LSC + СЕТЬ, EU" or "ЗАПАС, EU")
  local x0, bw = L.bigNumber(4, 4, 26, total, frac >= 0.05 and L.grad(frac) or P.accent, P.panel)
  if x0 then L.shine(x0, 4, bw, 5, t, 6, P.star) end

  -- сведения
  local ix, iw = 33, W - 33
  L.box(ix, 3, iw, 7, A.wl and "ЗАПАС И СЕТЬ" or "ЁМКОСТЬ")
  local y, vx, vw = 4, ix + 17, iw - 19
  local function line(k, v, col)
    L.put(ix + 2, y, k, P.dim, P.panel); L.put(vx, y, L.mq(v, vw), col or P.text, P.panel); y = y + 1
  end
  line(A.wl and "В LSC" or "Накоплено", L.num(d.stored) .. " EU")
  if A.wl then
    line("В сети", d.wEU and (L.num(d.wEU) .. " EU") or "нет данных от LSC", d.wEU and P.accent or P.warn)
  else
    line("Ёмкость", L.num(d.cap) .. " EU")
    line("Заполнено", (d.cap and d.cap > 0 and d.stored) and L.pct(d.stored / d.cap) or "—")
  end
  local oDay, oLab = A.oD, "Расход, сутки"
  if not oDay then oDay, oLab = A.o60, "Расход, 1 ч" end
  line(oLab, oDay and (L.num(oDay) .. " EU/t") or "—", P.out)
  if A.wl then
    if A.trNext and A.trFail then
      line("Перелив через", L.mmss(A.trNext) .. " · не проходит: в сети мало EU", P.warn)
    elseif A.trNext then
      local a = A.trLast or 0
      line("Перелив через", L.mmss(A.trNext) .. (a >= 0 and " · был в сеть " or " · был из сети ") .. L.num(math.abs(a)), P.accent)
    else
      line("Перелив", "жду первый (раз в 5 мин)", P.dim)
    end
  end
  local f = A.t1
  if f and f < 0 then line("Хватит на", L.dur(A.reserve / (-f * 20)), P.bad)
  elseif f and f > 0 and not A.wl and d.cap and d.stored then line("До полного", L.dur((d.cap - d.stored) / (f * 20)), P.good)
  elseif f and f > 0 and A.target and d.stored and d.stored < A.target then
    line("До цели LSC", L.dur((A.target - d.stored) / (f * 20)) .. " до " .. L.num(A.target) ..
      ", дальше излишки пойдут в сеть", P.good)
  elseif f and f > 0 then line("Баланс", "в плюсе, излишки уходят в сеть", P.good)
  else line("Время", "—", P.dim) end

  -- полоса: обычная, а при заполнении меньше 5 % — логарифмическая
  local bx, bw2 = 3, W - 4
  local pos, logScale, marks = frac, false, {}
  if frac < 0.05 and d.cap and d.cap > 1 and d.stored and d.stored > 0 then
    logScale = true
    local lmax = math.log(d.cap, 10)
    local lmin = math.max(0, math.floor(lmax) - 12)
    pos = math.max(0, math.min(1, (math.log(math.max(d.stored, 1), 10) - lmin) / (lmax - lmin)))
    for k = 2, #L.WORDS - 1 do
      local e = 3 * k
      if e >= lmin and e <= lmax then marks[#marks + 1] = { (e - lmin) / (lmax - lmin), "1 " .. L.WORDS[k + 1] } end
    end
  else
    for _, p in ipairs({ 0, 25, 50, 75, 100 }) do marks[#marks + 1] = { p / 100, p .. "%" } end
  end
  L.fill(bx, 10, bw2, 2, P.barBg)
  local filled = math.floor(bw2 * pos + 0.5)
  local S, anim = L.style(), L.cfg.opts.anim
  local dir = (f or 0) > 0 and 1 or ((f or 0) < 0 and -1 or 0)
  local off = anim and math.floor(t * (4 + math.min(8, math.log(math.abs(f or 0) + 1, 10) / 2))) or 0
  if not logScale then -- обычная шкала: цвет по уровню заряда
    local seg, i = math.max(1, math.floor(bw2 / 20)), 0
    while i < filled do
      local n = math.min(seg, filled - i)
      L.fill(bx + i, 10, n, 2, L.grad((i + n / 2) / bw2)); i = i + n
    end
  elseif S.bar == "matrix" then -- мерцающие цифры
    L.fill(bx, 10, filled, 2, P.panel2)
    for c = 0, filled - 1 do
      for r = 0, 1 do
        local n = (c * 7 + r * 13 + math.floor(t * 4)) % 10
        L.put(bx + c, 10 + r, tostring(n), (c + r + math.floor(t * 6)) % 5 == 0 and P.star or P.good)
      end
    end
  elseif S.bar == "neon" or S.bar == "aurora" then -- градиент темы
    local a, b, c3 = L.col("out"), L.col("accent"), L.col("good")
    for c = 0, filled - 1 do
      local k = c / math.max(1, bw2 - 1)
      local col = S.bar == "neon" and L.mix(a, b, k)
        or (k < 0.5 and L.mix(c3, b, k * 2) or L.mix(b, a, (k - 0.5) * 2))
      L.fill(bx + c, 10, 1, 2, col)
    end
  elseif S.bar == "mars" then -- сигнальная лента, бежит по направлению потока
    for c = 0, filled - 1 do
      for r = 0, 1 do
        L.fill(bx + c, 10 + r, 1, 1, (c + r - dir * off) % 4 < 2 and P.warn or P.out)
      end
    end
  else
    L.fill(bx, 10, filled, 2, P.accent)
  end
  -- частицы: вправо — зарядка, влево — разрядка
  local pch = ({ space = { "›", "‹" }, neon = { "»", "«" }, aurora = { "~", "~" } })[S.bar]
  if (not logScale) then pch = pch or { "›", "‹" } end
  if anim and pch and dir ~= 0 and filled > 2 then
    for c = 0, filled - 1 do
      if (c - dir * off) % 9 == 0 then
        local p = dir > 0 and pch[1] or pch[2]
        L.put(bx + c, 10, p, P.star); L.put(bx + c, 11, p, P.star)
      end
    end
  end
  if logScale then local s = " логарифмическая шкала "; L.put(bx + bw2 - len(s), 10, s, P.text, P.barBg) end
  for _, m in ipairs(marks) do
    local px = math.max(bx, math.min(bx + bw2 - len(m[2]), bx + math.floor((bw2 - 1) * m[1]) - math.floor(len(m[2]) / 2)))
    L.put(px, 12, m[2], P.dim)
  end

  -- карточки за минуту с мини-графиками
  local cw = math.floor((W - 4) / 3)
  local function card(x, title, v, col, ring, scol, amps)
    L.box(x, 13, cw, 4, title)
    L.put(x + 2, 14, L.mq(v, cw - 4), col, P.panel)
    L.spark(x + 2, 15, cw - 4, ring, scol or col, P.panel)
    if amps ~= "" then L.put(x + 2, 16, " " .. L.fit(amps, cw - 6) .. " ", P.dim, P.panel) end
  end
  local bcol = (not f or f == 0) and P.dim or (f > 0 and P.good or P.bad)
  card(2, "БАЛАНС · 1 МИН", f and (L.signed(f) .. " EU/t") or "считаю…", bcol, X.S.t, P.accent, L.amps(f))
  card(3 + cw, "ВХОД · 1 МИН", A.i1 and (L.num(A.i1) .. " EU/t") or "нет данных", P.good, X.S.i, nil, L.amps(A.i1))
  card(4 + 2 * cw, "ВЫХОД · 1 МИН", A.o1 and (L.num(A.o1) .. " EU/t") or "нет данных", P.out, X.S.o, nil, L.amps(A.o1))

  -- большой график
  local gy, gh = 17, H - 17
  L.box(2, gy, W - 2, gh)
  local x = 4
  for _, m in ipairs(MODES) do
    x = L.button(x, gy, m[2], ui.mode == m[1] and "on" or "off", function() ui.mode = m[1] end) + 1
  end
  local rx = W - 3
  for i = #PERIODS, 1, -1 do
    local p = PERIODS[i]
    local b0 = rx - (len(p[2]) + 2) + 1
    L.button(b0, gy, p[2], ui.period == p[1] and "on" or "off", function() ui.period = p[1] end)
    rx = b0 - 2
  end
  if A.wl and ui.period <= 3600 and rx - x > 12 then L.put(x + 1, gy, " ┆ перелив ", P.accent, P.panel) end

  local ring, shown, step
  if ui.period <= 600 then ring, shown, step = X.S[ui.mode], ui.period, 1
  elseif ui.period <= 3600 then ring, shown, step = X.T[ui.mode], 360, 10
  else ring, shown, step = X.F[ui.mode], 288, 300 end
  local pw, ph = W - 4, gh - 2
  local vals = L.series(ring, shown, pw - L.GL)
  local colP = ui.mode == "o" and P.out or P.good
  local _, _, px, ppw = L.plot(3, gy + 1, pw, ph, vals, colP, ui.mode == "t" and P.bad or colP)
  if px and ui.period <= 3600 then -- отметки переливов
    local now = L.now()
    for k = 1, X.evT.n do
      local age = now - X.evT:get(k)
      if age >= 0 and age < ui.period then
        local cx = px + ppw - 1 - math.floor(age / ui.period * ppw)
        for yy = gy + 1, gy + ph do L.putIfEmpty(cx, yy, "┆", P.accent) end
      end
    end
  end
  local by, name = gy + gh - 1, periodName(ui.period)
  L.put(4, by, " EU/t ", P.dim, P.panel)
  L.put(3 + L.GL, by, " -" .. name .. " ", P.dim, P.panel)
  L.put(W - 11, by, " сейчас ", P.dim, P.panel)
  local have = math.min(ring.n, shown)
  if have < shown then
    local s = " собрано " .. L.dur(have * step) .. " из " .. name .. " "
    L.put(3 + L.GL + math.floor((pw - L.GL - len(s)) / 2), by, s, P.warn, P.panel)
  end
end

---------------------------------------------------------------- «Статистика»
function L.drawStats(d, A, t)
  local W, H = L.W, L.H
  local rows = { { "Вход", "i", P.good }, { "Выход", "o", P.out }, { "Баланс LSC", "n" } }
  if A.wl then rows[4] = { "Сеть", "w" }; rows[5] = { "Итого", "t" } end
  L.box(2, 3, W - 2, 8, A.wl and "СРЕДНИЕ, EU/t · без переливов" or "СРЕДНИЕ ЗНАЧЕНИЯ, EU/t")
  L.button(W - 15, 3, "× Сбросить", "danger", function() L.askResetStats() end)
  local lw = 14
  local cw = math.floor((W - 6 - lw) / 4)
  local heads, suf = { "1 мин", "5 мин", "1 час", "24 часа" }, { "1", "5", "60", "D" }
  for k = 1, 4 do L.put(4 + lw + (k - 1) * cw, 4, heads[k], P.dim, P.panel) end
  for r, row in ipairs(rows) do
    local y = 4 + r
    L.put(4, y, row[1], P.text, P.panel)
    for k = 1, 4 do
      local v = A[row[2] .. suf[k]]
      local isNum = type(v) == "number"
      local col = row[3] or ((isNum and v < 0) and P.bad or P.good)
      local s = isNum and (row[3] and L.num(v) or L.signed(v)) or "—"
      L.put(4 + lw + (k - 1) * cw, y, L.fit(s, cw - 1), isNum and col or P.dim, P.panel)
    end
  end

  local oDay, per = A.oD, "за " .. L.dur(A.cov)
  if not oDay then oDay, per = A.o60, "за 1 час (сутки ещё набираются)" end
  L.box(2, 11, W - 2, 7, "ПОТРЕБЛЕНИЕ ЗАВОДА · СРЕДНИЙ ВЫХОД " .. per)
  local half = math.floor((W - 2) / 2)
  local x0, bw = L.bigNumber(4, 12, half - 4, oDay, P.out, P.panel)
  if x0 then L.shine(x0, 12, bw, 5, t, 7, P.star) end
  local kx = 2 + half
  local function kv(y, k, v, c)
    L.put(kx, y, k, P.dim, P.panel); L.put(kx + 14, y, L.mq(v, W - kx - 16), c or P.text, P.panel)
  end
  kv(12, "В амперах", L.amps(oDay) ~= "" and ("≈ " .. L.amps(oDay)) or "—", P.out)
  kv(13, "Пик (5 мин)", A.peak and (L.num(A.peak) .. " EU/t") or "—")
  kv(14, "Мин. запас", A.sMin and (L.num(A.sMin) .. " EU") or "—")
  kv(15, "Потери LSC", d.loss and (L.num(d.loss) .. " EU/t") or "—")
  kv(16, "Собрано", A.cov > 0 and (L.dur(A.cov) .. ", на диске") or "меньше 5 минут")

  local bh, lwid = H - 18, math.floor((W - 3) / 2)
  local function lines(x, w, lw, list)
    local y = 19
    for _, l in ipairs(list) do
      if y <= 18 + bh - 2 then
        L.put(x, y, l[1], P.dim, P.panel); L.put(x + lw, y, L.mq(l[2], w - lw - 2), l[3] or P.text, P.panel)
      end
      y = y + 1
    end
  end
  L.box(2, 18, lwid, bh, "ПЕРЕЛИВЫ С СЕТЬЮ · РАЗ В 5 МИН")
  if A.wl then
    lines(4, lwid - 2, 11, {
      { "Держит", A.target and ("≈ " .. L.num(A.target) .. " EU") or "жду перелива" },
      { "Следующий", (A.trNext and ("через " .. L.mmss(A.trNext)) or "жду") .. " · за сутки " .. A.trCount ..
        (A.trFailN > 0 and (", не прошло " .. A.trFailN) or ""), P.accent },
      { "Последний", A.trLast and (A.trFail
          and ("НЕ ПРОШЁЛ: нужно " .. L.num(math.abs(A.trLast)) .. " из сети, а в сети меньше")
          or ((A.trLast >= 0 and "в сеть " or "из сети ") .. L.num(math.abs(A.trLast)))) or "—",
        A.trFail and P.warn or P.text },
      { "В сеть", L.num(A.trPush) .. " EU за сутки", P.good },
      { "Из сети", L.num(A.trPull) .. " EU за сутки", A.trPull > 0 and P.warn or P.text },
    })
  else
    lines(4, lwid - 2, 11, { { "Режим", "беспроводной выключен" }, { "", "переливов нет" } })
  end
  local rx2 = 3 + lwid
  L.box(rx2, 18, W - 1 - rx2, bh, "ИТОГО ЗА СОБРАННОЕ ВРЕМЯ")
  local dS = (A.sFirst and d.stored) and (d.stored - A.sFirst) or nil
  lines(rx2 + 2, W - 3 - rx2, 18, {
    { "Принято", A.iD and (L.num(A.iD * 20 * A.cov) .. " EU") or "—", P.good },
    { "Отдано", A.oD and (L.num(A.oD * 20 * A.cov) .. " EU") or "—", P.out },
    { "Изменение запаса", dS and (L.signed(dS) .. " EU") or "—", dS and (dS >= 0 and P.good or P.bad) or P.dim },
    { "Ремонт", d.maint == nil and "—" or (d.maint and "не нужен" or "НУЖЕН"), d.maint == false and P.bad or P.good },
  })
end

---------------------------------------------------------------- кадр и управление
function L.render(d, A, t)
  local ui = L.ui
  L.t = t
  -- счётчик настоящих кадров в секунду
  L.fpsN = (L.fpsN or 0) + 1
  if not L.fpsT or t - L.fpsT >= 1 then
    if L.fpsT then L.fpsReal = math.floor(L.fpsN / (t - L.fpsT) + 0.5) end
    L.fpsT, L.fpsN = t, 0
  end
  L.hits = {}
  L.clear(P.bg)
  local fx = L.fxName()
  if fx == "space" then L.drawStars(t); L.drawMeteor({ 2, 12 }, t) end
  if d and A then
    if ui.page == "main" then L.drawMain(d, A, t)
    elseif ui.page == "stats" then L.drawStats(d, A, t)
    else L.drawSettings(d, A, t) end
    L.drawHeader(d, t)
    L.drawBanner(t)
  else
    L.put(math.floor(L.W / 2) - 13, math.floor(L.H / 2), "Подключаюсь к конденсатору…", P.text)
  end
  L.drawFooter()
  L.drawFx(t) -- фон темы рисуется в свободных клетках
  L.drawToast()
  if ui.modal then L.drawModal(ui.modal) end
  L.flush()
end

function L.onTouch(x, y)
  local hs = L.hits
  for k = #hs, 1, -1 do
    local h = hs[k]
    if x >= h[1] and x <= h[3] and y >= h[2] and y <= h[4] then h[5](x, y); return end
  end
end

function L.onKey(code)
  local ui = L.ui
  if ui.modal then
    if code == 1 then ui.modal = nil                                    -- Esc
    elseif code == 28 then                                              -- Enter
      local b = ui.modal.buttons[ui.modal.default or 1]
      ui.modal = nil; b[3]()
    end
    return
  end
  if code == 16 then L.askExit()                                        -- Q
  elseif code == 15 then                                                -- Tab
    for k, p in ipairs(PAGES) do if p[1] == ui.page then ui.page = PAGES[k % #PAGES + 1][1]; break end end
  elseif code == 50 then                                                -- M
    for k, m in ipairs(MODES) do if m[1] == ui.mode then ui.mode = MODES[k % #MODES + 1][1]; break end end
  elseif code >= 2 and code <= 5 then ui.period = PERIODS[code - 1][1]  -- 1-4
  elseif code == 20 then L.testSiren() end                              -- T
end

return L
]===],
  ["lscm_settings"] = [===[
-- lscm_settings.lua — страница «Настройки»: темы, редактор цветов, параметры
local L = require("lscm_core")
local computer = require("computer")
local P, len = L.P, L.len

local QUICK = { 0x000000, 0x0B1022, 0x1B1446, 0x2A3A66, 0x7F8AB8, 0xE8ECFF, 0xFFFFFF, 0x7AA2FF,
                0x00E5FF, 0x3DDC97, 0x39FF14, 0xFFD166, 0xFF9F43, 0xFF5C7A, 0xFF6EC7, 0xC084FC }

local function changed() L.cfgDirty = computer.uptime() end

local function setColor(idx, c)
  c = math.max(0, math.min(0xFFFFFF, math.floor(c)))
  L.cfg.colors[idx] = c
  L.applyPalette()
  changed()
end

-- тема целиком: цвета + стиль + фон «по теме»
local function setTheme(th)
  for i, c in ipairs(th[2]) do L.cfg.colors[i] = c end
  L.cfg.theme, L.cfg.style = th[1], th.st
  L.cfg.opts.fx = "auto"
  L.applyPalette(); changed()
  L.toast("Тема «" .. th[1] .. "»", P.accent)
end

local function wrap(s, w)
  local lines, cur = {}, ""
  for word in s:gmatch("%S+") do
    if cur == "" then cur = word
    elseif len(cur) + 1 + len(word) <= w then cur = cur .. " " .. word
    else lines[#lines + 1] = cur; cur = word end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  return lines
end

---------------------------------------------------------------- темы
local function drawThemes(t)
  local W, H = L.W, L.H
  local cols = 3
  local cw, chh = math.floor((W - 2) / cols), math.floor((H - 4) / 2)
  for i, th in ipairs(L.THEMES) do
    local x, y = 2 + ((i - 1) % cols) * cw, 4 + math.floor((i - 1) / cols) * chh
    local w, h, c = cw - 1, chh, th[2]
    local S = L.STYLES[th.st] or L.STYLES.space
    local sel = L.cfg.theme == th[1]
    -- карточка рисуется цветами и рамками самой темы
    L.boxStyled(S, x, y, w, h, th[1] .. (sel and " ✓" or ""), c[1], sel and c[8] or c[5], c[8])
    local px, pw = x + 2, w - 4
    L.fill(px, y + 2, pw, 4, c[3])
    L.put(px + 1, y + 2, S.icon .. " ЗАПАС", c[7], c[3])
    L.put(px + pw - 2, y + 2, "●", c[9], c[3])
    L.put(px + 1, y + 3, "58.02 трлн", c[8], c[3])
    local bw, fillN = pw - 2, math.floor((pw - 2) * 0.65)
    for k = 0, bw - 1 do
      local bg, ch, fg = c[15], " ", c[6]
      if k < fillN then
        local f = k / math.max(1, bw - 1)
        if S.bar == "matrix" then bg, ch, fg = c[4], tostring((k * 7 + math.floor(t * 4)) % 10), c[9]
        elseif S.bar == "neon" then bg = L.mix(c[10], c[8], f)
        elseif S.bar == "aurora" then bg = f < 0.5 and L.mix(c[9], c[8], f * 2) or L.mix(c[8], c[10], (f - 0.5) * 2)
        elseif S.bar == "mars" then bg = (k + math.floor(t * 3)) % 4 < 2 and c[12] or c[10]
        else bg = c[8] end
      end
      L.put(px + 1 + k, y + 4, ch, fg, bg)
    end
    L.put(px + 1, y + 5, L.fit("▁▂▃▅▆▇▆▅▃▂▃▅▇█▆▄▂▁▂▄▆", pw - 2), c[9], c[3])
    for k, line in ipairs(wrap(th.desc, w - 4)) do
      if y + 6 + k < y + h - 1 then L.put(x + 2, y + 6 + k, line, k == 1 and c[6] or c[7], c[1]) end
    end
    L.hit(x, y, x + w - 1, y + h - 1, function() setTheme(th) end)
  end
end

---------------------------------------------------------------- цвета
local function drawColors()
  local ui, W, H = L.ui, L.W, L.H
  ui.role = ui.role or 1

  L.box(2, 4, 24, H - 4, "ЭЛЕМЕНТЫ")
  for i, r in ipairs(L.ROLES) do
    local y = 4 + i
    if y < H - 1 then
      local sel = i == ui.role
      local bg = sel and P.btn or P.panel
      L.fill(3, y, 22, 1, bg)
      L.put(4, y, "██", -i, bg)
      L.put(7, y, L.fit(r[2], 16), sel and P.text or P.dim, bg)
      if sel then L.put(24, y, "◀", P.accent, bg) end
      L.hit(3, y, 24, y, function() ui.role = i end)
    end
  end

  local idx = ui.role
  local c = L.cfg.colors[idx]
  local rx, rw = 27, W - 27
  L.box(rx, 4, rw, H - 4, "ЦВЕТ: " .. L.ROLES[idx][2])
  local ix = rx + 2
  local sx = ix + 13
  local sw = rx + rw - 3 - sx + 1
  L.fill(ix, 5, 9, 2, -idx)
  L.put(ix + 11, 5, string.format("#%06X", c), P.text, P.panel)
  L.put(ix + 11, 6, string.format("R %d   G %d   B %d", math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256), P.dim, P.panel)

  local h, s, v = L.rgb2hsv(c)
  local function strip(y, label, colorAt, cur, pick)
    L.put(ix, y, label, P.dim, P.panel)
    for k = 0, sw - 1 do L.put(sx + k, y, " ", nil, colorAt(k / (sw - 1))) end
    L.put(sx + math.floor(cur * (sw - 1) + 0.5), y + 1, "▲", P.text, P.panel)
    L.hit(sx, y, sx + sw - 1, y + 1, function(x) pick(math.max(0, math.min(1, (x - sx) / (sw - 1)))) end)
  end
  -- у серых и почти чёрных цветов оттенок не виден: подставляем насыщенность и яркость
  local s2, v2 = s < 0.05 and 0.6 or s, v < 0.05 and 0.6 or v
  strip(8, "Оттенок", function(f) return L.hsv2rgb(f, 1, 1) end, h,
    function(f) setColor(idx, L.hsv2rgb(f, s2, v2)) end)
  strip(10, "Насыщенность", function(f) return L.hsv2rgb(h, f, math.max(v, 0.35)) end, s,
    function(f) setColor(idx, L.hsv2rgb(h, f, v)) end)
  strip(12, "Яркость", function(f) return L.hsv2rgb(h, s, f) end, v,
    function(f) setColor(idx, L.hsv2rgb(h, s, f)) end)

  L.put(ix, 14, "Точно", P.dim, P.panel)
  local bx = sx
  for _, cp in ipairs({ { "R", 65536 }, { "G", 256 }, { "B", 1 } }) do
    local val = math.floor(c / cp[2]) % 256
    L.put(bx, 14, cp[1], P.dim, P.panel)
    bx = L.button(bx + 2, 14, "−", "off", function() setColor(idx, c - cp[2] * math.min(8, val)) end)
    bx = L.button(bx, 14, "+", "off", function() setColor(idx, c + cp[2] * math.min(8, 255 - val)) end) + 2
  end

  L.put(ix, 16, "Быстрые", P.dim, P.panel)
  for k, qc in ipairs(QUICK) do
    local qx = sx + (k - 1) * 2
    if qx + 1 <= rx + rw - 3 then
      L.put(qx, 16, "  ", nil, qc)
      L.hit(qx, 16, qx + 1, 16, function() setColor(idx, qc) end)
    end
  end

  local th = L.themeByName(L.cfg.theme)
  if th then
    L.button(sx, 18, "Вернуть цвета темы «" .. th[1] .. "»", "off", function()
      for i, cc in ipairs(th[2]) do L.cfg.colors[i] = cc end
      L.applyPalette(); changed(); L.toast("Цвета темы восстановлены")
    end)
  end

  if H - 3 > 19 then
    local y = H - 3
    L.put(ix, y, "Пример", P.dim, P.panel)
    local px = sx
    for _, smp in ipairs({ { "текст", P.text }, { "подпись", P.dim }, { "+вход", P.good },
                           { "выход", P.out }, { "−минус", P.bad }, { "внимание", P.warn }, { "акцент", P.accent } }) do
      if px + len(smp[1]) <= rx + rw - 3 then px = L.put(px, y, smp[1], smp[2], P.panel) + 1 end
    end
  end
end

---------------------------------------------------------------- параметры
local function drawOpts()
  local W, H, o = L.W, L.H, L.cfg.opts
  L.box(2, 4, W - 2, H - 4, "ПАРАМЕТРЫ")
  local cx, y, last = 36, 5, H - 4 -- последняя строка для настроек; ниже — кнопки
  local function head(s) if y <= last then L.put(4, y, s, P.accent, P.panel) end; y = y + 1 end
  local function seg(label, choices, cur, set)
    if y > last then return end
    L.put(4, y, label, P.text, P.panel)
    local x = cx
    for _, ch in ipairs(choices) do
      if x + len(ch[2]) + 2 > W - 3 then x, y = cx, y + 1 end
      x = L.button(x, y, ch[2], cur == ch[1] and "on" or "off", function() set(ch[1]); changed() end) + 1
    end
    y = y + 1
  end
  local function step(label, value, dec, inc)
    if y > last then return end
    L.put(4, y, label, P.text, P.panel)
    local x = L.button(cx, y, "−", "off", function() dec(); changed() end)
    L.put(x + 1, y, value, P.accent, P.panel)
    L.button(x + 2 + len(value), y, "+", "off", function() inc(); changed() end)
    y = y + 1
  end
  local onoff = { { true, "Вкл" }, { false, "Выкл" } }

  head("ЭКРАН")
  seg("Анимация", onoff, o.anim, function(v) o.anim = v end)
  seg("Кадров в секунду", { { 5, "5" }, { 10, "10" }, { 20, "20 (максимум)" } }, o.fps, function(v) o.fps = v end)
  seg("Фон", L.FX, o.fx, function(v) o.fx = v end)
  seg("Плотность фона", { { 0, "Нет" }, { 1, "Мало" }, { 2, "Средне" }, { 3, "Много" } }, o.stars,
    function(v) o.stars = v; L.initStars() end)
  seg("Метеоры (космос)", onoff, o.meteors, function(v) o.meteors = v end)
  step("Часовой пояс", string.format("UTC%+d", o.tz),
    function() o.tz = math.max(-12, o.tz - 1) end, function() o.tz = math.min(14, o.tz + 1) end)
  if last - y >= 7 then y = y + 1 end
  head("СИРЕНА")
  seg("Звук", onoff, o.sound, function(v) o.sound = v end)
  seg("Редстоун-сигнал", { { "off", "Выкл" }, { "crit", "При тревоге" }, { "warn", "При внимании" } }, o.redstone,
    function(v) o.redstone = v end)
  step("Тревога: запаса меньше чем на", o.critMinutes .. " мин",
    function() o.critMinutes = math.max(5, o.critMinutes - 5) end, function() o.critMinutes = math.min(240, o.critMinutes + 5) end)
  step("Внимание: запаса меньше чем на", o.warnHours .. " ч",
    function() o.warnHours = math.max(1, o.warnHours - 1) end, function() o.warnHours = math.min(72, o.warnHours + 1) end)
  step("Внимание: вход упал ниже", o.inputDrop .. " %",
    function() o.inputDrop = math.max(10, o.inputDrop - 10) end, function() o.inputDrop = math.min(90, o.inputDrop + 10) end)
  step("Задержка срабатывания", o.confirm .. " с",
    function() o.confirm = math.max(0, o.confirm - 5) end, function() o.confirm = math.min(60, o.confirm + 5) end)

  -- кнопки действий всегда в нижней строке окна
  local by = H - 2
  local x = L.button(4, by, "Проверить сирену", "off", function() L.testSiren() end) + 2
  x = L.button(x, by, "Сбросить статистику", "danger", function() L.askResetStats() end) + 2
  L.button(x, by, "Всё по умолчанию", "off", function()
    L.ui.modal = { title = "СБРОС НАСТРОЕК", default = 1,
      text = { "Вернуть тему, цвета и параметры по умолчанию?" },
      buttons = { { "Отмена", "off", function() end },
                  { "Сбросить", "on", function()
                      L.cfg = L.defaultCfg(); L.applyPalette(); L.initStars(); changed()
                      L.toast("Настройки сброшены")
                    end } } }
  end)
end

---------------------------------------------------------------- страница
function L.drawSettings(d, A, t)
  local ui, W = L.ui, L.W
  ui.stab = ui.stab or "themes"
  local x = 2
  for _, tb in ipairs({ { "themes", "Темы" }, { "colors", "Цвета" }, { "opts", "Параметры" } }) do
    x = L.button(x, 3, tb[2], ui.stab == tb[1] and "on" or "off", function() ui.stab = tb[1] end) + 1
  end
  local hint = "изменения сохраняются сами"
  L.put(W - 1 - len(hint), 3, hint, P.dim)
  if ui.stab == "themes" then drawThemes(t)
  elseif ui.stab == "colors" then drawColors()
  else drawOpts() end
end

return L
]===],
}

for __name, __src in pairs(__BUNDLE) do
  package.preload[__name] = assert(load(__src), __name)
end
__BUNDLE = nil

-- monitor.lua v4 — монитор лапотронного суперконденсатора (GTNH, OpenComputers)
-- Файлы: /home/monitor.lua и /home/lib/lscm_core.lua, lscm_stats.lua, lscm_gfx.lua,
--        lscm_fx.lua, lscm_pages.lua, lscm_settings.lua
-- Запуск: monitor            — найти конденсатор автоматически
--         monitor <адрес>    — конкретный gt_machine
--         monitor --dump     — вывести сырые данные машины и выйти
-- Клавиши: Q — выход, Tab — страница, M — что на графике, 1-4 — период, T — проверка сирены

if not package.path:find("/home/lib/", 1, true) then package.path = "/home/lib/?.lua;" .. package.path end
local MODS = { "lscm_core", "lscm_stats", "lscm_gfx", "lscm_fx", "lscm_pages", "lscm_settings" }
for _, n in ipairs(MODS) do package.loaded[n] = nil end -- всегда свежие файлы

local L = require("lscm_core")
for k = 2, #MODS do require(MODS[k]) end
local computer = require("computer")
local event    = require("event")

local dump, addr = false, nil
for _, a in ipairs({ ... }) do if a == "--dump" or a == "-d" then dump = true else addr = a end end

L.loadCfg()
do -- компьютер просыпается только на тиках (20 в секунду): возможны 20, 10, 5 кадров
  local f = L.cfg.opts.fps
  L.cfg.opts.fps = f >= 15 and 20 or (f >= 7 and 10 or 5)
end
local machine = L.pickMachine(addr)
if dump then L.dump(machine); return end

L.statsInit()
L.alarmInit()
L.gfxInit()
L.initStars()
L.ui = { page = "main", mode = "t", period = 600, running = true, role = 1 }

local d, A
local nextData, nextFrame = computer.uptime(), computer.uptime()
local ok, err = pcall(function()
  while L.ui.running do
    local t = computer.uptime()
    if t >= nextData then -- данные раз в секунду
      d = L.sample(machine)
      A = L.stats(d)
      L.updateAlarm(d, A)
      nextData = t + 0.99 -- чуть меньше секунды, чтобы попадать ровно в 20-й тик
      if not L.cfg.opts.anim then nextFrame = t end -- с анимацией данные попадут в ближайший кадр
    end
    local o = L.cfg.opts
    if L.dirty or t >= nextFrame then -- кадры анимации чаще
      L.render(d, A, t)
      -- пауза в целых тиках минус запас, иначе округление съест лишний тик
      local ticks = math.max(1, math.floor(20 / o.fps + 0.5))
      nextFrame = t + (o.anim and ticks * 0.05 - 0.01 or 0.99)
      L.dirty = false
    end
    if L.cfgDirty and t - L.cfgDirty > 1.5 then L.saveCfg(); L.cfgDirty = nil end
    local e = { event.pull(math.max(0.02, math.min(nextData, nextFrame) - computer.uptime())) }
    if e[1] == "touch" then
      L.onTouch(math.floor(e[3]), math.floor(e[4])); L.dirty = true
    elseif e[1] == "key_down" then
      L.onKey(e[4]); L.dirty = true
    end
  end
end)

pcall(L.compactHistory)
L.al.rs = nil; pcall(L.setRedstone, 0)
if L.cfgDirty then pcall(L.saveCfg) end
L.gfxDone()
require("term").clear()
for _, n in ipairs(MODS) do package.loaded[n] = nil end
if not ok and err ~= "interrupted" then io.stderr:write(tostring(err) .. "\n") end

