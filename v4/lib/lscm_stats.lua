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
