# gtnh-lsc

Монитор лапотронного суперконденсатора (LSC) для **GT: New Horizons** на **OpenComputers**.

Показывает заряд, приток/расход EU, график, суточную статистику, умеет орать сиреной и
дёргать редстоун при низком заряде.

## Установка (одним файлом)

Нужна интернет-карта в компьютере, после установки её можно вынуть.

```lua
wget -f https://raw.githubusercontent.com/Maxiffon/gtnh-lsc/main/install/monitor.lua /home/monitor.lua
monitor
```

Либо через pastebin (если GitHub недоступен из игры):

```lua
pastebin get <ID> /home/monitor.lua
monitor
```

Автозапуск при загрузке: `edit /home/.shrc` и добавить строку `monitor`.

## Установка модульной версии

`install/monitor.lua` — это сборка `v4/monitor.lua` + `v4/lib/*.lua` в один файл
(модули подключаются через `package.preload`). Если хочется держать модули отдельно:

```lua
mkdir /home/lib
wget -f https://raw.githubusercontent.com/Maxiffon/gtnh-lsc/main/v4/monitor.lua          /home/monitor.lua
wget -f https://raw.githubusercontent.com/Maxiffon/gtnh-lsc/main/v4/lib/lscm_core.lua     /home/lib/lscm_core.lua
wget -f https://raw.githubusercontent.com/Maxiffon/gtnh-lsc/main/v4/lib/lscm_stats.lua    /home/lib/lscm_stats.lua
wget -f https://raw.githubusercontent.com/Maxiffon/gtnh-lsc/main/v4/lib/lscm_gfx.lua      /home/lib/lscm_gfx.lua
wget -f https://raw.githubusercontent.com/Maxiffon/gtnh-lsc/main/v4/lib/lscm_fx.lua       /home/lib/lscm_fx.lua
wget -f https://raw.githubusercontent.com/Maxiffon/gtnh-lsc/main/v4/lib/lscm_pages.lua    /home/lib/lscm_pages.lua
wget -f https://raw.githubusercontent.com/Maxiffon/gtnh-lsc/main/v4/lib/lscm_settings.lua /home/lib/lscm_settings.lua
monitor
```

## Железо

- компьютер (T2/T3) с OpenOS;
- GPU T2/T3 и экран, лучше сенсорный (кнопки интерфейса нажимаются);
- клавиатура;
- **адаптер**, приставленный вплотную к контроллеру конденсатора, и кабель до компьютера
  (машина появляется как компонент `gt_machine`);
- опционально: redstone-карта и redstone I/O — для сирены/сигнала.

## Запуск

```
monitor              -- найти конденсатор автоматически
monitor <адрес>      -- конкретная машина (достаточно первых символов адреса)
monitor --dump       -- вывести сырые данные машины и сохранить в /home/lsc_dump.txt
```

Клавиши: `Q` — выход, `Tab` — страница, `M` — что на графике, `1`–`4` — период,
`T` — проверка сирены.

## Структура

```
install/monitor.lua      однофайловая сборка (то, что ставится на компьютер)
tools/build-bundle.ps1   пересборка install/monitor.lua из v4/
v4/monitor.lua           точка входа модульной версии
v4/lib/lscm_*.lua        модули: ядро, статистика, графика, эффекты, страницы, настройки
v4/monitor-onefile.lua   копия сборки для локальной работы
monitor.lua, lsc.lua     старые однофайловые версии
```

## Сборка

```powershell
pwsh -File tools\build-bundle.ps1
```

Скрипт берёт `v4/monitor.lua` и `v4/lib/*.lua`, нормализует переводы строк в LF,
выбирает безопасный уровень длинных скобок и пишет UTF-8 без BOM в `install/monitor.lua`.
