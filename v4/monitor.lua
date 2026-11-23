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
