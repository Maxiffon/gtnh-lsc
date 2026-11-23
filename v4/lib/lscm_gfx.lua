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
