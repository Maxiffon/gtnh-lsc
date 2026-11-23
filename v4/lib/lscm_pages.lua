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
