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
