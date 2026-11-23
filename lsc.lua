-- lsc.lua — монитор EU в лапотронном суперконденсаторе (GTNH, OpenComputers)
-- Запуск:  lsc            — найти конденсатор автоматически
--          lsc <адрес>    — конкретный gt_machine (можно первые символы адреса)
--          lsc --dump     — вывести всё, что отдаёт машина (для отладки), и выйти
-- Выход: Q (в любой раскладке) или Ctrl+C

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local unicode   = require("unicode")

---------------------------------------------------------------- настройки
local CFG = {
  title    = "ЛАПОТРОННЫЙ СУПЕРКОНДЕНСАТОР", -- шапка экрана
  interval = 1,     -- секунд между опросами
  smooth   = 0.3,   -- сглаживание баланса (0..1, больше = резче реагирует)
  width    = 80,    -- желаемое разрешение (обрежется до максимума экрана)
  height   = 25,
}

local C = {
  bg = 0x0D1117, title = 0x1F4E8C, titleFg = 0xFFFFFF, text = 0xE6EDF3,
  dim = 0x8B949E, good = 0x3FB950, warn = 0xD29922, bad = 0xF85149,
  barBg = 0x30363D, barFg = 0xFFFFFF, graph = 0x58A6FF, graphBg = 0x161B22,
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

-- все числа из строки; разделители разрядов (запятая, пробелы) убираются
local function nums(line)
  local s = clean(line):gsub("\194\160", " "):gsub("\226\128\175", " ")
  s = s:gsub("(%d)[, '](%d)", "%1%2")
  local out = {}
  for n in s:gmatch("%-?%d+%.?%d*[eE]?[%+%-]?%d*") do
    local v = tonumber(n)
    if v then out[#out + 1] = v end
  end
  return out
end

local KEYS = {
  stored = { "used capacity", "stored", "заряд", "накоплен", "использован" },
  cap    = { "total capacity", "max capacity", "ёмкость", "емкость" },
  avgIn  = { "avg eu in", "average eu in", "avg. eu in", "средний вход", "ср. вход" },
  avgOut = { "avg eu out", "average eu out", "avg. eu out", "средний выход", "ср. выход" },
  loss   = { "passive loss", "пассивн", "потери" },
}

local function pick(info, keys)
  for _, l in ipairs(info) do
    local c = unicode.lower(clean(l))
    for _, k in ipairs(keys) do
      if c:find(k, 1, true) then
        local n = nums(l)
        if n[1] then return n[1] end
      end
    end
  end
end

local function readData(m)
  local okI, info = pcall(m.getSensorInformation)
  if not okI or type(info) ~= "table" then info = {} end
  local d = {
    stored = pick(info, KEYS.stored), cap = pick(info, KEYS.cap),
    avgIn = pick(info, KEYS.avgIn), avgOut = pick(info, KEYS.avgOut),
    loss = pick(info, KEYS.loss),
  }
  -- запасной путь, если строки датчика не распознаны
  if not d.stored then local ok, v = pcall(m.getEUStored); if ok then d.stored = tonumber(v) end end
  if not d.cap or d.cap <= 0 then local ok, v = pcall(m.getEUMaxStored); if ok then d.cap = tonumber(v) end end
  return d
end

---------------------------------------------------------------- форматирование
local SUF = { "", "k", "M", "G", "T", "P", "E", "Z", "Y" }
local function si(n)
  if not n then return "—" end
  local neg = n < 0; n = math.abs(n)
  local i = 1
  while n >= 1000 and i < #SUF do n = n / 1000; i = i + 1 end
  local s = i == 1 and string.format("%.0f", n) or string.format("%.2f %s", n, SUF[i])
  return (neg and "-" or "") .. s
end

local TIERS = {
  { "LV", 32 }, { "MV", 128 }, { "HV", 512 }, { "EV", 2048 }, { "IV", 8192 },
  { "LuV", 32768 }, { "ZPM", 131072 }, { "UV", 524288 }, { "UHV", 2097152 },
  { "UEV", 8388608 }, { "UIV", 33554432 }, { "UMV", 134217728 },
  { "UXV", 536870912 }, { "MAX", 2147483648 },
}
local function amps(r)
  r = math.abs(r)
  if r < 1 then return "" end
  local t = TIERS[1]
  for _, x in ipairs(TIERS) do if x[2] <= r then t = x end end
  return string.format("  (%.1f A %s)", r / t[2], t[1])
end

local function dur(s)
  if not s or s ~= s or s == math.huge or s < 0 then return "—" end
  s = math.floor(s)
  local d = math.floor(s / 86400); s = s % 86400
  local h = math.floor(s / 3600);  s = s % 3600
  local m = math.floor(s / 60);    s = s % 60
  if d > 365 then return "больше года" end
  if d > 0 then return string.format("%d д %02d ч %02d мин", d, h, m) end
  if h > 0 then return string.format("%d ч %02d мин", h, m) end
  if m > 0 then return string.format("%d мин %02d с", m, s) end
  return string.format("%d с", s)
end

---------------------------------------------------------------- режим отладки
local machine = pickMachine()

if dump then
  local lines = {}
  local function add(s) lines[#lines + 1] = s; print(s) end
  local ok, name = pcall(machine.getName)
  add("Машина: " .. (ok and tostring(name) or "?") .. "  " .. machine.address)
  for _, f in ipairs({ "getEUStored", "getEUMaxStored", "getEUInputAverage", "getEUOutputAverage" }) do
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
local W, H = math.min(maxW, CFG.width), math.min(maxH, CFG.height)
gpu.setResolution(W, H)

if gpu.getDepth() == 1 then -- монохромный экран
  for k in pairs(C) do C[k] = 0xFFFFFF end
  C.bg, C.barBg, C.graphBg, C.title = 0x000000, 0x000000, 0x000000, 0x000000
end

local KW = 14 -- ширина подписей
local function fit(s, w) if unicode.len(s) > w then return unicode.sub(s, 1, w) end return s end
local function row(y, bg) gpu.setBackground(bg or C.bg); gpu.fill(1, y, W, 1, " ") end
local function put(x, y, s, fg, bg)
  gpu.setBackground(bg or C.bg); gpu.setForeground(fg or C.text); gpu.set(x, y, s)
end
local function center(y, s, fg, bg)
  s = fit(s, W); put(math.floor((W - unicode.len(s)) / 2) + 1, y, s, fg, bg)
end
local function kv(y, k, v, fg)
  if y >= H then return end
  row(y); put(3, y, k, C.dim); put(3 + KW, y, fit(v, W - 3 - KW), fg)
end

local function bar(y0, hgt, frac)
  local bw = W - 4
  local fill = math.max(0, math.min(bw, math.floor(bw * frac + 0.5)))
  local col = frac < 0.2 and C.bad or (frac < 0.5 and C.warn or C.good)
  gpu.setBackground(C.bg); gpu.fill(1, y0, W, hgt, " ")
  gpu.setBackground(C.barBg); gpu.fill(3, y0, bw, hgt, " ")
  if fill > 0 then gpu.setBackground(col); gpu.fill(3, y0, fill, hgt, " ") end
  local txt = string.format(" %.2f %% ", frac * 100)
  local tl = unicode.len(txt)
  local tx, ty = 3 + math.floor((bw - tl) / 2), y0 + math.floor(hgt / 2)
  local split = math.max(0, math.min(tl, 3 + fill - tx))
  gpu.setForeground(C.barFg)
  if split > 0 then gpu.setBackground(col); gpu.set(tx, ty, unicode.sub(txt, 1, split)) end
  if split < tl then gpu.setBackground(C.barBg); gpu.set(tx + split, ty, unicode.sub(txt, split + 1)) end
end

local hist = {}
local GW = W - 4
local function graph(y0, gh)
  local n = #hist
  local lo, hi = math.huge, -math.huge
  for _, v in ipairs(hist) do if v < lo then lo = v end if v > hi then hi = v end end
  if n == 0 then lo, hi = 0, 1 end
  if hi - lo < 1e-6 then lo = math.max(0, lo - 0.0005); hi = math.min(1, hi + 0.0005) end
  if hi - lo < 1e-9 then hi = lo + 1e-6 end
  local lv = {}
  for i = 1, GW do
    local v = hist[n - GW + i]
    lv[i] = v and math.max(1, math.floor((v - lo) / (hi - lo) * gh * 2 + 0.5)) or -1
  end
  gpu.setBackground(C.graphBg); gpu.setForeground(C.graph)
  for r = 0, gh - 1 do
    local base, t = (gh - 1 - r) * 2, {}
    for i = 1, GW do
      local a = lv[i] - base
      t[i] = a >= 2 and "█" or (a == 1 and "▄" or " ")
    end
    gpu.set(3, y0 + r, table.concat(t))
  end
  return lo, hi
end

---------------------------------------------------------------- опрос
local prevS, prevT, rate
local samples = 0

local function sample()
  local d = readData(machine)
  local t = computer.uptime()
  if d.stored and prevS and t > prevT then
    local r = (d.stored - prevS) / ((t - prevT) * 20)
    rate = rate and (rate + (r - rate) * CFG.smooth) or r
  end
  if d.stored then prevS, prevT = d.stored, t end
  -- средние вход/выход из датчика точнее, чем разница заряда
  if d.avgIn and d.avgOut then d.balance = d.avgIn - d.avgOut else d.balance = rate end
  if d.stored and d.cap and d.cap > 0 then
    hist[#hist + 1] = d.stored / d.cap
    while #hist > GW do table.remove(hist, 1) end
  end
  samples = samples + 1
  return d
end

local function draw(d)
  row(1, C.title); center(1, CFG.title, C.titleFg, C.title)
  row(2)
  local frac = (d.stored and d.cap and d.cap > 0) and math.min(1, d.stored / d.cap) or 0
  kv(3, "Заряд", si(d.stored) .. " EU  из  " .. si(d.cap) .. " EU")
  row(4)
  bar(5, 3, frac)
  row(8)
  local b = d.balance
  local bfg = (not b or b == 0) and C.dim or (b > 0 and C.good or C.bad)
  kv(9, "Баланс", b and ((b > 0 and "+" or "") .. si(b) .. " EU/t" .. amps(b)) or "считаю…", bfg)
  kv(10, "Вход, ср.", d.avgIn and (si(d.avgIn) .. " EU/t" .. amps(d.avgIn)) or "—")
  kv(11, "Выход, ср.", d.avgOut and (si(d.avgOut) .. " EU/t" .. amps(d.avgOut)) or "—")
  kv(12, "Потери", d.loss and (si(d.loss) .. " EU/t") or "—")
  if b and b > 0 and d.cap and d.stored then
    kv(13, "До полного", dur((d.cap - d.stored) / (b * 20)), C.good)
  elseif b and b < 0 and d.stored then
    kv(13, "До разрядки", dur(d.stored / (-b * 20)), C.bad)
  else
    kv(13, "Время", "—")
  end
  local gy, gh = 16, H - 17
  if gh >= 3 then
    row(14)
    local lo, hi = graph(gy, gh)
    row(15)
    put(3, 15, fit(string.format("Заряд за %d с:  %.3f%% … %.3f%%",
      math.min(#hist, GW) * CFG.interval, lo * 100, hi * 100), W - 4), C.dim)
  end
  row(H, C.graphBg)
  put(3, H, fit("Q — выход · опрос раз в " .. CFG.interval .. " с · #" .. samples, W - 4), C.dim, C.graphBg)
end

---------------------------------------------------------------- главный цикл
gpu.setBackground(C.bg); gpu.fill(1, 1, W, H, " ")
local ok, err = pcall(function()
  while true do
    draw(sample())
    local e = { event.pull(CFG.interval, "key_down") }
    if e[1] == "key_down" and (e[4] == 16 or e[3] == 113 or e[3] == 81) then break end
  end
end)

gpu.setResolution(oldW, oldH)
gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
require("term").clear()
if not ok and err ~= "interrupted" then io.stderr:write(tostring(err) .. "\n") end
