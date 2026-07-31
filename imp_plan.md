# Рефакторинг мультиселекции слоёв

Цель: сократить дифф с `main`, убрав лишнее и сделав реализацию проще, при том же поведении.

## Анализ текущего диффа

Мультиселекция добавила следующие изменения поверх основного диффа ветки:

### 1. `main.dart` — **1 строка**
- `selectedLayers` ValueNotifier (line 531). Чисто, трогать нечего.

### 2. `timeline_panel_frb.dart` — ~170 строк мультиселекции

Текущие мульти-селекшн изменения:

| Что | Строки | Проблема |
|---|---|---|
| `_anchorLayer` поле | 434 | Ок |
| `_deselectAll` метод (+selectedLayers) | 436–454 | Ок |
| `_selectLayer` метод | 456–511 | **55 строк**. Обёрнут в `if (mounted) setState(update) else update()` — можно упростить |
| `_OutlineRow.build` — `Listener + GestureDetector(onTap: (){})` | 3277–3290 | **Вся проблема**: 3 уровня вложенности, Builder → Listener → GestureDetector, когда можно было просто убрать `onTap: widget.onSelect` из существующего GestureDetector и поставить Listener |
| Outline selection check `selectedLayers.value.any(...)` | 3105–3109 | **Дорого**: `Provider.of` на каждый ряд, `.any()` на каждый ряд — O(n²) на список слоёв |
| Lane area selection check + Container(color:) | 4001–4015 | **Дорого**: ещё один `Provider.of` и `.any()` на каждый ряд |
| `_Bar.selected` prop + border accent | 4815–4817 | Ок |
| `layer.precompose` bind uses `selectedLayers` | main.dart:1002–1015 | Ок |

## Предложенные оптимизации

### A. `_selectLayer`: убрать `mounted` guard — **-8 строк**
`_selectLayer` вызывается только из `onPointerDown` и `onTap`, которые срабатывают только когда виджет на экране → всегда `mounted`. Guard появился от ошибки «setState during locked tree», но корневая причина уже исправлена (двойной вызов). Можно безопасно вернуть обычный `=> setState(() { ... })`.

### B. Outline row: Listener остаётся, но проще — **-3 строки**
Сейчас: `Builder → Listener → GestureDetector(onTap: (){}, onSecondaryTapDown: ...)`.
`Builder` не нужен — context GestureDetector'а уже доступен. Останется: `Listener → GestureDetector(onTap: (){}, onSecondaryTapDown: ...)`.

### C. Selection set вместо list — **чище O(1) проверки вместо O(n)**
`selectedLayers` как `ValueNotifier<List<LayerReference>>` проверяется через `.any()` на каждый ряд.
Вместо этого: передавать `Set<BigInt> selectedIds` (как уже передаётся `selected` для одиночного), посчитанный один раз в `build()` панели, и проверять `selectedIds.contains(id)` — O(1).

Это убирает `Provider.of<LumitUiState>(context)` из внутренностей `_Outline` и `_LayerArea`, заменяя его на prop.

### D. Убрать дублирование `selected` vs `selectedIds` проверки
Сейчас в _Outline line ~3105:
```dart
selected: Provider.of<LumitUiState>(context)
    .selectedLayers.value.any(...) ||
    selected?.internallayerId == ...
```
С set'ом это станет просто `selected: selectedIds.contains(layers[i].layer.internallayerId)`.

## Итоговый подсчёт

| До | После | Экономия |
|---|---|---|
| ~170 строк мульти-селекции | ~135 строк | ~35 строк |
| 2× Provider.of + O(n) .any() | 1× Set build + O(1) .contains() | производительность |
| Builder → Listener → GestureDetector | Listener → GestureDetector | читаемость |

## Proposed Changes

### Timeline Panel

#### [MODIFY] [timeline_panel_frb.dart](file:///home/bath/.dev/Lumit/flutter_ui/lib/panels/timeline_panel_frb.dart)

1. `_selectLayer`: вернуть `=> setState(() { ... })` без `mounted` guard
2. `_OutlineRow.build`: убрать `Builder`, оставить `Listener → GestureDetector`
3. Вычислить `selectedIds` в `build()` панели, передать как prop в `_Outline` и `_LayerArea`
4. Заменить `Provider.of<LumitUiState>(context).selectedLayers.value.any(...)` на `selectedIds.contains(id)`
5. Убрать дублирование `selected` параметра — одна проверка через `selectedIds`

## Verification Plan

### Automated Tests
- `./buildartix.sh` — приложение собирается без ошибок

### Manual Verification
- Ctrl+Click на нескольких слоях — все остаются выделены
- Shift+Click — range selection работает
- Click по пустому месту — всё сбрасывается
- Подсветка на всех выделенных слоях (и в outline, и на lane bars)
