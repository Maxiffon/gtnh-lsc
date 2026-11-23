-- monitor.lua v3 — монитор лапотронного суперконденсатора (GTNH, OpenComputers)
-- Экран 2-го или 3-го тира сенсорный: кнопки нажимаются.
-- Клавиши: Q — выход, Tab — обзор/статистика, M — что на графике, 1-4 — период,
--          T — проверить сирену (5 секунд).
-- monitor --dump — вывести сырые данные машины (для отладки).

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local unicode   = require("unicode")
local fs        = require("filesystem")
local ser       = require("serialization")

---------------------------------------------------------------- настройки
local CFG = {
  title     = "ЛАПОТРОННЫЙ СУПЕРКОНДЕНСАТОР", -- шапка
  interval  = 1,                              -- секунд между опросами
  width     = 80,                             -- минимальное разрешение
  height    = 25,
  statsFile = "/home/monitor_stats.dat",      -- суточная статистика
  saveEvery = 300,                            -- сохранять раз в N секунд

  -- СИРЕНА. Уровни: 1 — внимание (короткий писк раз в 15 с), 2 — тревога (сирена)
  alarm = {
    enabled      = true,
    critMinutes  = 30,     -- тревога: устойчивый разряд и до нуля меньше N минут
    warnHours    = 6,      -- внимание: устойчивый разряд и до нуля меньше N часов
    inputDrop    = 0.5,    -- вход за минуту упал ниже этой доли от среднего за час
    minStored    = 0,      -- тревога, если запас ниже N EU (0 = не проверять)
    confirm      = 10,     -- секунд условие должно держаться, чтобы сработать
    clear        = 30,     -- секунд без условия, чтобы тревога снялась
    muteMinutes  = 10,     -- на сколько глушит кнопка «Заглушить»
    sound        = true,   -- пищать встроенным динамиком
    redstone     = "crit", -- редстоун-сигнал: "crit", "warn" или false
    redstoneSide = nil,    -- сторона 0-5 или nil = все стороны
  },
}

local C = {
  bg = 0x0B0F14, panel = 0x111821, border = 0x2D3A4A, grid = 0x223044,
  title = 0x173A63, titleFg = 0xFFFFFF,
  text = 0xE6EDF3, dim = 0x7D8B99, accent = 0x58A6FF,
  good = 0x3FB950, warn = 0xD29922, bad = 0xF85149, out = 0xF0883E,
  barBg = 0x1C2530, btn = 0x22303F, btnFg = 0xC9D1D9, btnOn = 0x1F6FEB, btnOnFg = 0xFFFFFF,
}

---------------------------------------------------------------- аргументы
local dump, addrArg = false, nil
for _, a in ipairs({...}) do
  if a == "--dump" or a == "-d" then dump = true else addrArg = a end
end

---------------------------------------------------------------- поиск машины
local function pickMachine()
  if addrArg then
    local full = component.get(addrArg)
    if not full then error("Нет компонента с адресом " .. addrArg, 0) end
    return component.proxy(full)
  end
  local list = {}
  for a in component.list("gt_machine") do
    local p = component.proxy(a)
    local ok, name = pcall(p.getName)
    list[#list + 1] = { p = p, name = ok and tostring(name) or "?", addr = a }
  end
  if #list == 0 then
    error("gt_machine не найден. Поставьте адаптер вплотную к контроллеру конденсатора.", 0)
  end
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

---------------------------------------------------------------- разбор данных
local function clean(s) return (tostring(s):gsub("§.", "")) end

-- целое число из NumberFormat: "54,520,000" / "54 520 000" / "54.520.000"
local function int(s)
  if not s then return nil end
  s = clean(s)
  local neg = s:match("^%s*%-") ~= nil
  local dg = s:gsub("%D", "")
  if dg == "" then return nil end
  local v = tonumber(dg)
  return neg and -v or v
end

-- строки датчика LSC приходят как "ключ\\аргумент\\аргумент"
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
    local p = splitEnc(clean(raw))
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

-- запасной разбор для старых версий, где строки обычным текстом
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
        local c = unicode.lower(clean(l))
        for _, k in ipairs(keys) do
          if c:find(k, 1, true) then
            local s = clean(l):gsub("(%d)[ ,'](%d)", "%1%2")
            d[f] = tonumber(s:match("%-?%d+%.?%d*"))
            break
          end
        end
      end
    end
  end
  return d
end

local function readData(m)
  local okI, info = pcall(m.getSensorInformation)
  if not okI or type(info) ~= "table" then info = {} end
  local d = parseEncoded(info) or parsePlain(info)
  if not d.stored then local ok, v = pcall(m.getEUStored); if ok then d.stored = tonumber(v) end end
  if not d.cap or d.cap <= 0 then local ok, v = pcall(m.getEUMaxStored); if ok then d.cap = tonumber(v) end end
  local ok, w = pcall(m.isWorkAllowed); if ok then d.on = w end
  return d
end

---------------------------------------------------------------- форматирование
local WORDS = { "", "тыс.", "млн", "млрд", "трлн", "квадрлн", "квинтлн", "секстлн", "септлн" }
local function scale(n)
  local i = 1
  while n >= 1000 and i < #WORDS do n = n / 1000; i = i + 1 end
  return n, i
end
local function num(n, dec)
  if not n then return "—" end
  local v, i = scale(math.abs(n))
  local s = i == 1 and string.format("%.0f", v) or string.format("%." .. (dec or 2) .. "f %s", v, WORDS[i])
  return (n < 0 and "-" or "") .. s
end
local function signed(n, dec)
  if not n then return "—" end
  return (n > 0 and "+" or "") .. num(n, dec)
end

local TIERS = {
  { "LV", 32 }, { "MV", 128 }, { "HV", 512 }, { "EV", 2048 }, { "IV", 8192 },
  { "LuV", 32768 }, { "ZPM", 131072 }, { "UV", 524288 }, { "UHV", 2097152 },
  { "UEV", 8388608 }, { "UIV", 33554432 }, { "UMV", 134217728 },
  { "UXV", 536870912 }, { "MAX", 2147483648 },
}
local function amps(r)
  if not r then return "" end
  r = math.abs(r)
  if r < 1 then return "" end
  local t = TIERS[1]
  for _, x in ipairs(TIERS) do if x[2] <= r then t = x end end
  return string.format("%.2f A %s", r / t[2], t[1])
end

local function dur(s)
  if not s or s ~= s or s == math.huge or s < 0 then return "—" end
  s = math.floor(s)
  local d = math.floor(s / 86400); s = s % 86400
  local h = math.floor(s / 3600);  s = s % 3600
  local m = math.floor(s / 60);    s = s % 60
  if d > 365 then return "больше года" end
  if d > 0 then return string.format("%.0f д %.0f ч", d, h) end
  if h > 0 then return string.format("%.0f ч %.0f мин", h, m) end
  if m > 0 then return string.format("%.0f мин %.0f с", m, s) end
  return string.format("%.0f с", s)
end

local function pct(f)
  if not f then return "—" end
  f = f * 100
  if f >= 1 then return string.format("%.2f %%", f) end
  if f >= 0.01 then return string.format("%.4f %%", f) end
  return string.format("%.7f %%", f)
end

---------------------------------------------------------------- режим отладки
local machine = pickMachine()

if dump then
  local lines = {}
  local function add(s) lines[#lines + 1] = s; print(s) end
  local ok, name = pcall(machine.getName)
  add("Машина: " .. (ok and tostring(name) or "?") .. "  " .. machine.address)
  for _, f in ipairs({ "getEUStored", "getEUMaxStored", "getEUInputAverage", "getEUOutputAverage", "isWorkAllowed" }) do
    if machine[f] then
      local okv, v = pcall(machine[f])
      add(string.format("%s = %s", f, okv and tostring(v) or ("ошибка: " .. tostring(v))))
    end
  end
  local okI, info = pcall(machine.getSensorInformation)
  add("getSensorInformation:")
  if okI and type(info) == "table" then
    for i, l in ipairs(info) do add(string.format("[%d] %s", i, clean(l))) end
  else
    add("  недоступно: " .. tostring(info))
  end
  local fh = io.open("/home/lsc_dump.txt", "w")
  if fh then fh:write(table.concat(lines, "\n")); fh:close(); print("Сохранено в /home/lsc_dump.txt") end
  return
end

---------------------------------------------------------------- экран
local gpu = component.gpu
local oldW, oldH = gpu.getResolution()
local maxW, maxH = gpu.maxResolution()
if maxW < 60 or maxH < 20 then
  error("Нужны видеокарта и экран 2-го тира или выше (сейчас максимум " .. maxW .. "x" .. maxH .. ")", 0)
end
-- разрешение под пропорции экрана, чтобы не было пустых полей
local function chooseRes()
  local okS, aw, ah = pcall(component.invoke, gpu.getScreen(), "getAspectRatio")
  if not okS or not aw or not ah then return math.min(maxW, CFG.width), math.min(maxH, CFG.height) end
  local ratio = 2 * (aw - 0.25) / (ah - 0.25)
  local w, h = CFG.width, math.floor(CFG.width / ratio + 0.5)
  if h < CFG.height then h = CFG.height; w = math.floor(h * ratio + 0.5) end
  if w > maxW then w = maxW; h = math.floor(w / ratio + 0.5) end
  if h > maxH then h = maxH; w = math.floor(h * ratio + 0.5) end
  return math.max(60, math.min(w, maxW)), math.max(20, math.min(h, maxH))
end
local W, H = chooseRes()
gpu.setResolution(W, H)

-- рисуем в видеобуфер и копируем на экран целиком: без мерцания
local buf
if gpu.allocateBuffer then
  local okB, b = pcall(gpu.allocateBuffer, W, H)
  if okB and type(b) == "number" and b > 0 then buf = b end
end

local len = unicode.len
local function fit(s, w) if w <= 0 then return "" end if len(s) > w then return unicode.sub(s, 1, w) end return s end
local function rect(x, y, w, h, c) if w > 0 and h > 0 then gpu.setBackground(c); gpu.fill(x, y, w, h, " ") end end
local function text(x, y, s, f, b)
  if b then gpu.setBackground(b) end
  gpu.setForeground(f or C.text); gpu.set(x, y, s)
end
local function rtext(xr, y, s, f, b) text(xr - len(s) + 1, y, s, f, b) end

local function box(x, y, w, h, title)
  rect(x, y, w, h, C.panel)
  gpu.setForeground(C.border)
  gpu.set(x, y, "╭" .. string.rep("─", w - 2) .. "╮")
  gpu.set(x, y + h - 1, "╰" .. string.rep("─", w - 2) .. "╯")
  if h > 2 then
    gpu.set(x, y + 1, string.rep("│", h - 2), true)
    gpu.set(x + w - 1, y + 1, string.rep("│", h - 2), true)
  end
  if title then text(x + 2, y, fit(" " .. title .. " ", w - 4), C.dim, C.panel) end
end

local function mix(a, b, t)
  t = math.max(0, math.min(1, t))
  local function ch(c, s) return math.floor(c / s) % 256 end
  local r = ch(a, 65536) + (ch(b, 65536) - ch(a, 65536)) * t
  local g = ch(a, 256) + (ch(b, 256) - ch(a, 256)) * t
  local bl = ch(a, 1) + (ch(b, 1) - ch(a, 1)) * t
  return math.floor(r) * 65536 + math.floor(g) * 256 + math.floor(bl)
end
local function grad(t)
  if t < 0.5 then return mix(C.bad, C.warn, t * 2) end
  return mix(C.warn, C.good, (t - 0.5) * 2)
end

-- крупные цифры 3x5
local FONT = {
  ["0"] = { "███", "█ █", "█ █", "█ █", "███" }, ["1"] = { " █ ", "██ ", " █ ", " █ ", "███" },
  ["2"] = { "███", "  █", "███", "█  ", "███" }, ["3"] = { "███", "  █", "███", "  █", "███" },
  ["4"] = { "█ █", "█ █", "███", "  █", "  █" }, ["5"] = { "███", "█  ", "███", "  █", "███" },
  ["6"] = { "███", "█  ", "███", "█ █", "███" }, ["7"] = { "███", "  █", "  █", "  █", "  █" },
  ["8"] = { "███", "█ █", "███", "█ █", "███" }, ["9"] = { "███", "█ █", "███", "  █", "███" },
  ["."] = { " ", " ", " ", " ", "█" },            ["-"] = { "   ", "   ", "███", "   ", "   " },
}
local function bigWidth(s)
  local w = 0
  for i = 1, #s do local g = FONT[s:sub(i, i)]; if g then w = w + len(g[1]) + 1 end end
  return math.max(0, w - 1)
end
local function bigText(x, y, s, color, b)
  gpu.setBackground(b); gpu.setForeground(color)
  for i = 1, #s do
    local g = FONT[s:sub(i, i)]
    if g then
      for r = 1, 5 do gpu.set(x, y + r - 1, g[r]) end
      x = x + len(g[1]) + 1
    end
  end
end
-- крупное число + слово ("54.52" + "трлн"), чтобы влезло в maxw
local function bigNumber(x, y, maxw, v, color, b)
  if not v then text(x, y + 2, "нет данных", C.dim, b); return end
  local n, i = scale(math.abs(v))
  local word, s = WORDS[i]
  for _, f in ipairs({ "%.2f", "%.1f", "%.0f" }) do
    s = (v < 0 and "-" or "") .. string.format(f, n)
    if bigWidth(s) + 1 + len(word) <= maxw then break end
  end
  local total = bigWidth(s) + (word ~= "" and 1 + len(word) or 0)
  local x0 = x + math.max(0, math.floor((maxw - total) / 2))
  bigText(x0, y, s, color, b)
  if word ~= "" then text(x0 + bigWidth(s) + 1, y + 4, word, color, b) end
end

local buttons = {}
local function button(x, y, label, active, action)
  local s = " " .. label .. " "
  text(x, y, s, active and C.btnOnFg or C.btnFg, active and C.btnOn or C.btn)
  buttons[#buttons + 1] = { x1 = x, x2 = x + len(s) - 1, y = y, action = action }
  return x + len(s)
end

local function bar(x, y, w, h, frac, color)
  rect(x, y, w, h, C.barBg)
  local filled = math.max(0, math.min(w, math.floor(w * frac + 0.5)))
  if color then rect(x, y, filled, h, color); return end
  local seg = math.max(1, math.floor(w / 20))
  local i = 0
  while i < filled do
    local n = math.min(seg, filled - i)
    rect(x + i, y, n, h, grad((i + n / 2) / w))
    i = i + n
  end
end

local function log10(v) return math.log(v, 10) end

---------------------------------------------------------------- время и статистика
-- настоящее время берём из даты изменения файла один раз при запуске
local function realNow()
  local p = "/home/.monitor_clock"
  local f = io.open(p, "w"); if not f then return nil end
  f:write("."); f:close()
  local t = fs.lastModified(p)
  if type(t) ~= "number" then return nil end
  if t > 1e12 then return t / 1000 end
  if t > 1e9 then return t end
end
local clk0, up0 = realNow(), computer.uptime()
local function now() return clk0 and (clk0 + computer.uptime() - up0) or computer.uptime() end

local SEC_MAX = 3600
local sec = { i = {}, o = {}, n = {} }  -- по секундам за последний час
local minutes = {}                       -- по минутам за сутки: {t, i, o, n, s, smin}

local function push(arr, v)
  arr[#arr + 1] = v
  while #arr > SEC_MAX do table.remove(arr, 1) end
end

local function loadStats()
  if not clk0 then return end
  local f = io.open(CFG.statsFile, "r"); if not f then return end
  local s = f:read("*a"); f:close()
  local ok, t = pcall(ser.unserialize, s)
  if ok and type(t) == "table" and type(t.minutes) == "table" then
    local lim = now() - 86400
    for _, r in ipairs(t.minutes) do
      if type(r) == "table" and type(r.t) == "number" and r.t >= lim then minutes[#minutes + 1] = r end
    end
  end
end

local function saveStats()
  if not clk0 then return end
  local f = io.open(CFG.statsFile, "w"); if not f then return end
  f:write(ser.serialize({ v = 3, minutes = minutes })); f:close()
end

local function meanLast(arr, n)
  local s, c = 0, 0
  for j = #arr, math.max(1, #arr - n + 1), -1 do
    local v = arr[j]
    if type(v) == "number" then s = s + v; c = c + 1 end
  end
  return c > 0 and s / c or nil
end

local function meanDay(f)
  local s, c = 0, 0
  for _, r in ipairs(minutes) do
    local v = r[f]
    if type(v) == "number" then s = s + v; c = c + 1 end
  end
  return c > 0 and s / c or nil, c
end

---------------------------------------------------------------- опрос
local prevS, prevT
local acc = { t0 = computer.uptime() }
local lastSave = computer.uptime()
local samples = 0

local function accAdd(f, v)
  if v then acc[f] = (acc[f] or 0) + v; acc[f .. "#"] = (acc[f .. "#"] or 0) + 1 end
end
local function accAvg(f)
  local c = acc[f .. "#"]
  return c and acc[f] / c or nil
end

local function sample()
  local d = readData(machine)
  local t = computer.uptime()
  local dnet
  if d.stored and prevS and t > prevT then dnet = (d.stored - prevS) / ((t - prevT) * 20) end
  if d.stored then prevS, prevT = d.stored, t end
  -- баланс: вход − выход − потери; если датчик их не дал — по изменению запаса
  if d.inS and d.outS then d.net = d.inS - d.outS - (d.loss or 0) else d.net = dnet end
  push(sec.i, d.inS or false); push(sec.o, d.outS or false); push(sec.n, d.net or false)
  accAdd("i", d.inS); accAdd("o", d.outS); accAdd("n", d.net)
  if d.stored then acc.smin = math.min(acc.smin or math.huge, d.stored) end
  if t - acc.t0 >= 60 then
    minutes[#minutes + 1] = { t = now(), i = accAvg("i"), o = accAvg("o"), n = accAvg("n"), s = d.stored, smin = acc.smin }
    local lim = now() - 86400
    while minutes[1] and (minutes[1].t < lim or #minutes > 1440) do table.remove(minutes, 1) end
    acc = { t0 = t }
  end
  if t - lastSave >= CFG.saveEvery then saveStats(); lastSave = t end
  samples = samples + 1
  return d
end

local function stats(d)
  local A = {}
  local loss = d.loss or 0
  local function bal(i, o, fb) if i and o then return i - o - loss end return fb end
  A.i1, A.o1, A.n1 = meanLast(sec.i, 60), meanLast(sec.o, 60), meanLast(sec.n, 60)
  A.i5  = d.in5 or meanLast(sec.i, 300);   A.o5  = d.out5 or meanLast(sec.o, 300)
  A.i60 = d.in1h or meanLast(sec.i, 3600); A.o60 = d.out1h or meanLast(sec.o, 3600)
  A.n5  = bal(A.i5, A.o5, meanLast(sec.n, 300))
  A.n60 = bal(A.i60, A.o60, meanLast(sec.n, 3600))
  A.iD = meanDay("i"); A.oD = meanDay("o")
  local nD, cov = meanDay("n"); A.nD, A.cov = nD, cov
  A.peak, A.sMin, A.sFirst = nil, nil, nil
  for _, r in ipairs(minutes) do
    if type(r.o) == "number" and (not A.peak or r.o > A.peak) then A.peak = r.o end
    if type(r.smin) == "number" and (not A.sMin or r.smin < A.sMin) then A.sMin = r.smin end
    if not A.sFirst and type(r.s) == "number" then A.sFirst = r.s end
  end
  return A
end

---------------------------------------------------------------- сирена
local AC = CFG.alarm
local AL = { level = 0, cand = 0, since = 0, lowSince = nil, why = {},
             muteUntil = 0, mutedLevel = 0, test = 0, lastBeep = 0, rs = nil }
local rsDev = component.isAvailable("redstone") and component.redstone or nil

-- уровень тревоги по совокупности факторов
local function evalAlarm(d, A)
  local why, lvl = {}, 0
  local function add(l, s) if l > lvl then lvl = l end; why[#why + 1] = s end
  local n1, n5 = A.n1, A.n5
  local drain = n1 and n1 < 0 and (n5 == nil or n5 < 0)          -- минус и за 1, и за 5 минут
  local tte = (drain and d.stored) and d.stored / (-n1 * 20) or nil -- секунд до нуля
  local drop = A.i1 and A.i60 and A.i60 > 0 and A.i1 < A.i60 * AC.inputDrop
  if drain and tte and tte < AC.critMinutes * 60 then
    add(2, "разрядится через " .. dur(tte))
  elseif drain and drop and tte and tte < AC.warnHours * 3600 then
    add(2, "упал вход и идёт разряд, ноль через " .. dur(tte))
  elseif drain and tte and tte < AC.warnHours * 3600 then
    add(1, "разряд, ноль через " .. dur(tte))
  end
  if AC.minStored > 0 and d.stored and d.stored < AC.minStored then
    add(2, "запас ниже " .. num(AC.minStored) .. " EU")
  end
  if drop and lvl < 2 then
    add(1, string.format("вход упал до %.0f%% от среднего за час", A.i1 / A.i60 * 100))
  end
  if d.maint == false then add(1, "нужен ремонт") end
  if d.on == false then add(1, "конденсатор выключен") end
  return lvl, why
end

local function setRedstone(v)
  if not rsDev or AL.rs == v then return end
  AL.rs = v
  for s = 0, 5 do
    if AC.redstoneSide == nil or AC.redstoneSide == s then pcall(rsDev.setOutput, s, v) end
  end
end

local function muted() return computer.uptime() < AL.muteUntil and AL.level <= AL.mutedLevel end

local function updateAlarm(d, A)
  if not AC.enabled then return end
  local t = computer.uptime()
  local lvl, why = evalAlarm(d, A)
  -- задержка на срабатывание и на снятие, чтобы короткие скачки не дёргали сирену
  if lvl > AL.level then
    if AL.cand ~= lvl then AL.cand, AL.since = lvl, t end
    if t - AL.since >= AC.confirm then AL.level, AL.lowSince = lvl, nil end
  elseif lvl < AL.level then
    AL.cand = lvl
    AL.lowSince = AL.lowSince or t
    if t - AL.lowSince >= AC.clear then AL.level, AL.lowSince = lvl, nil end
  else
    AL.cand, AL.lowSince = lvl, nil
  end
  AL.why = why
  if AL.level > AL.mutedLevel then AL.muteUntil = 0 end -- стало хуже — звук снова включается

  local testing = t < AL.test
  local lv = testing and 2 or AL.level
  local quiet = muted() and not testing
  if AC.sound and lv > 0 and not quiet then
    if lv >= 2 then
      computer.beep(1400, 0.15); computer.beep(900, 0.15)
    elseif t - AL.lastBeep >= 15 then
      computer.beep(700, 0.1); AL.lastBeep = t
    end
  end
  local want = (AC.redstone == "crit" and lv >= 2) or (AC.redstone == "warn" and lv >= 1)
  setRedstone((want and not quiet) and 15 or 0)
end

---------------------------------------------------------------- график
local GL = 11 -- ширина подписей шкалы слева

local function series(arr, shown, gw)
  local n, out = #arr, {}
  local start, bucket = n - shown, shown / gw
  for i = 1, gw do
    local a = math.floor((i - 1) * bucket) + 1 + start
    local b = math.max(a, math.floor(i * bucket) + start)
    local s, c = 0, 0
    for j = math.max(1, a), math.min(n, b) do
      local v = arr[j]
      if type(v) == "number" then s = s + v; c = c + 1 end
    end
    out[i] = c > 0 and s / c or false
  end
  return out
end

-- столбики от нуля; слева подписи (макс, 0, мин); строка нуля подсвечена
local function plot(x, y, w, h, vals, colP, colN)
  rect(x, y, w, h, C.panel)
  local px, pw = x + GL, w - GL
  local dlo, dhi = math.huge, -math.huge
  for i = 1, pw do
    local v = vals[i]
    if v then if v < dlo then dlo = v end; if v > dhi then dhi = v end end
  end
  if dlo == math.huge then
    text(px + math.floor((pw - 10) / 2), y + math.floor(h / 2), "нет данных", C.dim, C.panel)
    return
  end
  local lo, hi = math.min(dlo, 0), math.max(dhi, 0)
  if hi - lo < 1e-9 then hi = lo + 1 end
  local H2 = h * 2
  local z = (0 - lo) / (hi - lo) * H2
  local r0 = math.max(0, math.min(h - 1, h - 1 - math.floor(z / 2)))
  for r = 0, h - 1 do
    local base, t = (h - 1 - r) * 2, {}
    for i = 1, pw do
      local v, ch = vals[i], " "
      if v then
        local lv = (v - lo) / (hi - lo) * H2
        local a, b = math.min(z, lv), math.max(z, lv)
        local low = a <= base + 0.5 and base + 0.5 <= b
        local up = a <= base + 1.5 and base + 1.5 <= b
        ch = (low and up) and "█" or (up and "▀" or (low and "▄" or " "))
      end
      t[i] = ch
    end
    gpu.setBackground(r == r0 and C.grid or C.panel)
    gpu.setForeground((base + 1 >= z) and colP or colN)
    gpu.set(px, y + r, table.concat(t))
  end
  local function lab(r, s) rtext(x + GL - 2, y + r, fit(s, GL - 2), C.dim, C.panel) end
  if hi > 0 and r0 ~= 0 then lab(0, num(hi, 1)) end
  if lo < 0 and r0 ~= h - 1 then lab(h - 1, num(lo, 1)) end
  lab(r0, "0")
end

---------------------------------------------------------------- страницы
local state = { page = "main", mode = "n", period = 600, running = true }
local MODES = { { "n", "Баланс" }, { "i", "Вход" }, { "o", "Выход" } }
local PERIODS = { { 60, "1 мин" }, { 600, "10 мин" }, { 3600, "1 ч" }, { 86400, "24 ч" } }

local function drawHeader(d)
  rect(1, 1, W, 1, C.title)
  text(3, 1, fit(CFG.title, W - 30), C.titleFg, C.title)
  local xr = W - 1
  if d.on ~= nil then
    local s = d.on and "● РАБОТАЕТ" or "● ОТКЛЮЧЁН"
    rtext(xr, 1, s, d.on and C.good or C.bad, C.title); xr = xr - len(s) - 2
  end
  if d.maint == false then rtext(xr, 1, "▲ НУЖЕН РЕМОНТ", C.warn, C.title) end

  -- строка тревоги под шапкой, мигает
  local testing = computer.uptime() < AL.test
  local lv = testing and 2 or AL.level
  if lv > 0 then
    local blink = samples % 2 == 0
    local bgc = lv >= 2 and (blink and C.bad or 0x6E1B1B) or (blink and C.warn or 0x5C4511)
    local s = (lv >= 2 and " ▲ ТРЕВОГА: " or " ▲ ВНИМАНИЕ: ")
    s = s .. (testing and "проверка сирены" or (#AL.why > 0 and table.concat(AL.why, " · ") or "условие снимается…"))
    if muted() and not testing then
      s = s .. string.format("  [звук выкл. ещё %.0f мин]", math.ceil((AL.muteUntil - computer.uptime()) / 60))
    end
    rect(1, 2, W, 1, bgc)
    text(1, 2, fit(s, W), 0xFFFFFF, bgc)
  end
end

local function drawFooter()
  local x = button(2, H, "Выход", false, function() state.running = false end) + 1
  x = button(x, H, "Обзор", state.page == "main", function() state.page = "main" end) + 1
  x = button(x, H, "Статистика", state.page == "stats", function() state.page = "stats" end) + 1
  if AL.level > 0 or computer.uptime() < AL.test then
    if muted() then
      button(x, H, "Включить звук", false, function() AL.muteUntil = 0 end)
    else
      button(x, H, "Заглушить", true, function()
        AL.muteUntil = computer.uptime() + AC.muteMinutes * 60
        AL.mutedLevel = AL.level
        AL.test = 0
      end)
    end
  end
  rtext(W - 1, H, "опрос " .. CFG.interval .. " с · #" .. samples, C.dim, C.bg)
end

local function drawMain(d, A)
  local frac = (d.stored and d.cap and d.cap > 0) and math.min(1, d.stored / d.cap) or 0

  -- запас крупно
  box(2, 3, 30, 7, "ЗАПАС, EU")
  bigNumber(4, 4, 26, d.stored, frac >= 0.05 and grad(frac) or C.accent, C.panel)

  -- сведения
  local ix, iw = 33, W - 33
  box(ix, 3, iw, 7, "ЁМКОСТЬ")
  local lx, vx = ix + 2, ix + 18
  local vw = ix + iw - 2 - vx
  local function line(y, k, v, col)
    text(lx, y, k, C.dim, C.panel); text(vx, y, fit(v, vw), col or C.text, C.panel)
  end
  line(4, "Накоплено", num(d.stored) .. " EU")
  line(5, "Ёмкость", num(d.cap) .. " EU")
  line(6, "Заполнено", (d.cap and d.cap > 0 and d.stored) and pct(d.stored / d.cap) or "—")
  local oDay, oLab = A.oD, "Расход, сутки"
  if not oDay then oDay, oLab = A.o60, "Расход, 1 ч" end
  line(7, oLab, oDay and (num(oDay) .. " EU/t") or "—", C.out)
  local b = A.n1 or d.net
  if b and b > 0 and d.cap and d.stored then
    line(8, "До полного", dur((d.cap - d.stored) / (b * 20)), C.good)
  elseif b and b < 0 and d.stored then
    line(8, "До разрядки", dur(d.stored / (-b * 20)), C.bad)
  else
    line(8, "Время", "—", C.dim)
  end

  -- полоса: обычная, а если заполнено < 5 % — логарифмическая
  local bx, bw = 3, W - 4
  local function mark(pos, s)
    local px = bx + math.floor((bw - 1) * pos) - math.floor(len(s) / 2)
    px = math.max(bx, math.min(bx + bw - len(s), px))
    text(px, 12, s, C.dim, C.bg)
  end
  if frac >= 0.05 or not (d.cap and d.cap > 1 and d.stored) then
    bar(bx, 10, bw, 2, frac)
    for _, p in ipairs({ 0, 25, 50, 75, 100 }) do mark(p / 100, p .. "%") end
  else
    local lmax = log10(d.cap)
    local lmin = math.max(0, math.floor(lmax) - 12)
    local pos = math.max(0, math.min(1, (log10(math.max(d.stored, 1)) - lmin) / (lmax - lmin)))
    bar(bx, 10, bw, 2, pos, C.accent)
    for k = 2, #WORDS - 1 do
      local e = 3 * k
      if e >= lmin and e <= lmax then mark((e - lmin) / (lmax - lmin), "1 " .. WORDS[k + 1]) end
    end
    rtext(bx + bw - 1, 10, " логарифмическая шкала ", C.text, C.barBg)
  end

  -- карточки за последнюю минуту
  local cw = math.floor((W - 4) / 3)
  local function card(x, title, value, sub, col)
    box(x, 13, cw, 4, title)
    text(x + 2, 14, fit(value, cw - 4), col or C.text, C.panel)
    text(x + 2, 15, fit(sub or "", cw - 4), C.dim, C.panel)
  end
  local bcol = (not b or b == 0) and C.dim or (b > 0 and C.good or C.bad)
  card(2, "БАЛАНС, 1 МИН", b and (signed(b) .. " EU/t") or "считаю…", amps(b), bcol)
  card(3 + cw, "ВХОД, 1 МИН", A.i1 and (num(A.i1) .. " EU/t") or "нет данных",
    A.i60 and ("за 1 ч: " .. num(A.i60)) or "", C.good)
  card(4 + 2 * cw, "ВЫХОД, 1 МИН", A.o1 and (num(A.o1) .. " EU/t") or "нет данных",
    A.o60 and ("за 1 ч: " .. num(A.o60)) or "", C.out)

  -- график
  local gy, gh = 17, H - 17
  box(2, gy, W - 2, gh)
  local x = 4
  for _, m in ipairs(MODES) do
    x = button(x, gy, m[2], state.mode == m[1], function() state.mode = m[1] end) + 1
  end
  local rx = W - 2
  for i = #PERIODS, 1, -1 do
    local p = PERIODS[i]
    rx = rx - (len(p[2]) + 2)
    button(rx, gy, p[2], state.period == p[1], function() state.period = p[1] end)
    rx = rx - 1
  end

  local pw, ph = W - 4, gh - 2
  local arr, shown
  if state.period <= SEC_MAX then
    arr, shown = sec[state.mode], math.floor(state.period / CFG.interval)
  else
    arr, shown = {}, 1440
    for k, r in ipairs(minutes) do arr[k] = r[state.mode] or false end
  end
  local vals = series(arr, shown, pw - GL)
  local colP = state.mode == "o" and C.out or C.good
  local colN = state.mode == "n" and C.bad or colP
  plot(3, gy + 1, pw, ph, vals, colP, colN)

  -- ось времени и сколько данных уже собрано
  local by, name = gy + gh - 1, ""
  for _, p in ipairs(PERIODS) do if p[1] == state.period then name = p[2] end end
  local unit = " EU/t "
  text(4, by, unit, C.dim, C.panel)
  text(3 + GL, by, " -" .. name .. " ", C.dim, C.panel)
  rtext(W - 3, by, " сейчас ", C.dim, C.panel)
  local have = math.min(#arr, shown)
  if have < shown then
    local got = state.period <= SEC_MAX and dur(have * CFG.interval) or dur(have * 60)
    local s = " собрано " .. got .. " из " .. name .. " "
    text(3 + GL + math.floor((pw - GL - len(s)) / 2), by, s, C.warn, C.panel)
  end
end

local function drawStats(d, A)
  -- таблица средних
  box(2, 3, W - 2, 6, "СРЕДНИЕ ЗНАЧЕНИЯ, EU/t")
  local lw = 10
  local cw = math.floor((W - 6 - lw) / 4)
  local cols = { "1 мин", "5 мин", "1 час", "24 часа" }
  for k, s in ipairs(cols) do text(4 + lw + (k - 1) * cw, 4, s, C.dim, C.panel) end
  local rows = {
    { "Вход",   { A.i1, A.i5, A.i60, A.iD }, C.good, false },
    { "Выход",  { A.o1, A.o5, A.o60, A.oD }, C.out, false },
    { "Баланс", { A.n1, A.n5, A.n60, A.nD }, nil, true },
  }
  for r, row in ipairs(rows) do
    local y = 4 + r
    text(4, y, row[1], C.dim, C.panel)
    for k = 1, 4 do
      local v = row[2][k]
      local col = row[3] or ((v or 0) >= 0 and C.good or C.bad)
      local s = v and (row[4] and signed(v) or num(v)) or "—"
      text(4 + lw + (k - 1) * cw, y, fit(s, cw - 1), v and col or C.dim, C.panel)
    end
  end

  -- потребление завода
  local oDay, per = A.oD, A.cov and A.cov > 0 and ("за " .. dur(A.cov * 60)) or ""
  if not oDay then oDay, per = A.o60, "за 1 час (сутки ещё не собраны)" end
  box(2, 10, W - 2, 7, "ПОТРЕБЛЕНИЕ ЗАВОДА — СРЕДНИЙ ВЫХОД " .. per)
  local half = math.floor((W - 2) / 2)
  bigNumber(4, 11, half - 4, oDay, C.out, C.panel)
  local rx = 2 + half
  local function kv(y, k, v, col)
    text(rx, y, k, C.dim, C.panel); text(rx + 18, y, fit(v, W - rx - 20), col or C.text, C.panel)
  end
  kv(11, "Единиц", oDay and (num(oDay) .. " EU/t") or "—", C.out)
  kv(12, "Это примерно", amps(oDay) ~= "" and amps(oDay) or "—")
  kv(13, "Пик за минуту", A.peak and (num(A.peak) .. " EU/t") or "—")
  kv(14, "Мин. запас", A.sMin and (num(A.sMin) .. " EU") or "—")
  kv(15, "Потери LSC", d.loss and (num(d.loss) .. " EU/t") or "—")

  -- итоги за сутки
  box(2, 17, W - 2, H - 17, "ИТОГО ЗА СОБРАННЫЙ ПЕРИОД")
  local secs = (A.cov or 0) * 60
  local y = 18
  local function row(k, v, col)
    if y > H - 2 then return end
    text(4, y, k, C.dim, C.panel); text(26, y, fit(v, W - 28), col or C.text, C.panel); y = y + 1
  end
  row("Собрано данных", secs > 0 and (dur(secs) .. " (сохраняется на диск)") or "меньше минуты")
  row("Принято", A.iD and (num(A.iD * 20 * secs) .. " EU") or "—", C.good)
  row("Отдано", A.oD and (num(A.oD * 20 * secs) .. " EU") or "—", C.out)
  local dS = (A.sFirst and d.stored) and (d.stored - A.sFirst) or nil
  row("Изменение запаса", dS and (signed(dS) .. " EU") or "—", dS and (dS >= 0 and C.good or C.bad) or C.dim)
  if d.maint ~= nil then
    row("Обслуживание", d.maint and "в порядке" or "нужен ремонт", d.maint and C.good or C.bad)
  end
  if d.wireless ~= nil then
    row("Беспроводной режим", d.wireless and ("включён · " .. num(d.wEU) .. " EU в сети") or "выключен")
  end
end

local function draw(d, A)
  buttons = {}
  rect(1, 1, W, H, C.bg)
  drawHeader(d)
  if state.page == "main" then drawMain(d, A) else drawStats(d, A) end
  drawFooter()
end

local function redraw(d, A)
  if not d or not A then return end
  if buf then gpu.setActiveBuffer(buf) end
  draw(d, A)
  if buf then gpu.setActiveBuffer(0); gpu.bitblt(0, 1, 1, W, H, buf, 1, 1) end
end

---------------------------------------------------------------- главный цикл
loadStats()
local last, lastA
local nextT = computer.uptime()
local ok, err = pcall(function()
  while state.running do
    local t = computer.uptime()
    if t >= nextT then
      last = sample(); lastA = stats(last)
      updateAlarm(last, lastA)
      nextT = t + CFG.interval
      redraw(last, lastA)
    end
    local e = { event.pull(math.max(0.05, nextT - computer.uptime())) }
    if e[1] == "touch" then
      local tx, ty = math.floor(e[3]), math.floor(e[4])
      for _, bt in ipairs(buttons) do
        if ty == bt.y and tx >= bt.x1 and tx <= bt.x2 then
          bt.action()
          if state.running then redraw(last, lastA) end
          break
        end
      end
    elseif e[1] == "key_down" then
      local code = e[4]
      if code == 16 then state.running = false                                       -- Q
      elseif code == 15 then state.page = state.page == "main" and "stats" or "main" -- Tab
      elseif code == 50 then                                                         -- M
        for k, m in ipairs(MODES) do
          if m[1] == state.mode then state.mode = MODES[k % #MODES + 1][1]; break end
        end
      elseif code >= 2 and code <= 5 then state.period = PERIODS[code - 1][1]       -- 1-4
      elseif code == 20 then AL.test = computer.uptime() + 5; AL.muteUntil = 0 end  -- T: тест
      if state.running then redraw(last, lastA) end
    end
  end
end)

saveStats()
AL.rs = nil; setRedstone(0)
if buf then pcall(gpu.setActiveBuffer, 0); pcall(gpu.freeBuffer, buf) end
gpu.setResolution(oldW, oldH)
gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
require("term").clear()
if not ok and err ~= "interrupted" then io.stderr:write(tostring(err) .. "\n") end
