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
