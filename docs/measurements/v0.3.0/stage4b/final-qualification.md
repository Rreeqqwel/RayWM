# Stage 4B-Final qualification — 2026-11-16

**Вердикт: Stage 4B завершён в nested/software scope; можно переходить к
разработке Stage 5. GTK primary selection и Qt nested submenu — PASS.**
Остаётся подтверждённый upstream protocol defect Smithay 0.7.0 при disconnect
источника уже принятого DnD: drop без данных. Это не успешный transfer и не
закрытый дефект. До production qualification необходим upstream cancellation fix
с повторной проверкой; готовность к Stage 5 не означает desktop/release readiness.
Stage 5 в этой работе не реализуется.

База: `7e9c67e66ecda9adc85284a0ab0f02207c371af2`, ветка
`feature/rust-smithay`. Работа и один итоговый коммит остаются локальными,
без push, merge или release. Изменены только Rust adapter/tests и документация.
[Проверка защищённых путей](final/protected-paths.txt) подтверждает неизменность
Zig, build, protocol, config, packaging, scripts и Cargo dependency manifests/lock.
Существовавшие untracked пользовательские файлы не включены в коммит.

## Среда и воспроизведение

[Environment](final/environment.txt): Rust/Cargo 1.99.1, Smithay `=0.7.0`
с неизменным crates.io checksum в Cargo.lock, GTK 4.24.1, Qt Widgets/Wayland
6.12.0, Wayland 1.26.0, wl-clipboard 2.3.0, foot 1.28.0. Существующий Zig
`-Dtest-input` binary служит приватным headless pixman parent 1280×720.
Rust Winit Wayland child: 800×600, software EGL/GLES/llvmpipe; reactive scenario
также проверяет 700×500. Никаких пакетов или новых protocol globals не добавлено.

Команды из корня репозитория:

```sh
python3 rust/tests/nested-smoke.py
python3 rust/tests/nested-smoke.py --stage3
python3 rust/tests/selection-smoke.py
python3 rust/tests/stage4b-smoke.py
# Быстрый повтор только реальных toolkit-сценариев:
python3 rust/tests/stage4b-smoke.py --toolkits-only
```

Полный итоговый Stage 4B run: `/tmp/raywm-stage4b-wlp8_w3g`;
[полный результат](final/stage4b.log). Все сессии имеют собственные mode-0700
runtime directories, очищенное окружение, абсолютный parent socket,
принудительные GDK/QPA Wayland backends и ограниченные ожидания. Указатель
вводится только в приватный parent. GTK/Qt probes — реальные toolkit apps;
Rust protocol clients отдельно проверяют безопасность и framework edge cases.

## GTK 4 primary selection: BLOCKED → PASS

**Первоначальная проблема.** Старый primary-тест запускал DnD target, который
создавал обычный `GtkLabel("DROP-GTK")`: label не был selectable и вообще не
содержал `primary-gtk`. Попытки drag и Ctrl+A не проверяли заявленную семантику.
Отсутствие offer не доказывало отсутствие GTK поддержки протокола. Гипотеза о
необходимости `gtk_primary_selection` global отвергнута.

**Проверка upstream.** GTK 4.24.1
[`gdkprimary-wayland.c`](https://github.com/GNOME/gtk/blob/4.24.1/gdk/wayland/gdkprimary-wayland.c)
создаёт стандартный zwp device в `gdk_wayland_primary_new` и source в
`gdk_wayland_primary_claim`, предлагает MIME и использует последний implicit-grab
serial. Источники и hashes перечислены в [upstream manifest](final/upstream-sources.sha256).
Backend environment не содержит `GDK_WAYLAND_DISABLE`; trace и
`gtk backend=GdkWaylandDisplay version=4.24.1` подтверждают фактический Wayland.

**Исправление.** Отдельная роль GTK probe создаёт штатный `GtkTextView` с
`primary-gtk`. Harness выделяет текст реальным press/motion/release. API
установки clipboard/primary не вызывается; GTK сам выполняет selection claim.
Production primary-selection policy и Smithay forwarding не изменены.

**Наблюдения:** [source trace](final/gtk-primary-primary.log),
[receiver trace](final/gtk-primary-receiver.log),
[краткие события](final/gtk-primary-primary-events.log),
[serial/MIME summary](final/gtk-primary-summary.json).

- GTK видит и binds `zwp_primary_selection_device_manager_v1` v1, создаёт device.
- Keyboard enter предшествует жесту. Источнику доставлены press **579** и release
  **582**; GTK создаёт source, предлагает UTF-8/plain MIME и отправляет
  `set_selection(source,579)`. Serial соответствует реальному press.
- RayWM принимает его в текущем client focus epoch: ни forged/stale serial,
  ни искусственный serial не нужен. Stage 4A сохраняет окно 10 s / 64 serials.
- Независимый `wl-paste -p -n --type text/plain;charset=utf-8` получает offer,
  запрашивает receive через FD; GTK получает source.send с тем же MIME и FD.
- [Payload](final/gtk-primary-payload) равен ровно **11 bytes `primary-gtk`**.
- После disconnect GTK повторный независимый receiver получает отсутствие
  selection, не старые данные; compositor остаётся работоспособен.

Qt primary также PASS: [summary](final/qt-primary-summary.json),
[source](final/qt-primary-primary.log), [receiver](final/qt-primary-receiver.log),
[payload](final/qt-primary-payload) — **10 bytes `primary-qt`**. Qt использует
реально доставленный **release 627**, после press 624. Оба вида input serial
разрешены исходной политикой Stage 4A. Ранний вариант новой assertion ошибочно
требовал press от Qt; он исправлен по wire evidence, без изменения production
serial validation. Промежуточные причины перечислены в [iterations](final/iterations.txt).

## Qt 6 nested submenu: BLOCKED → PASS

**Root cause в RayWM.** В [trace до исправления](final/qt-before-fix.log)
Qt получает правый press 46 и release 47, затем отправляет `xdg_popup.grab(...,46)`.
К этому моменту текущий held implicit grab уже завершён. RayWM проверял только
held pointer / keyboard / существующий nested serial и немедленно отправлял
popup_done. Корневое меню не было нарисовано. Проверка одного факта создания
popup role в старом harness ошибочно пропускала это состояние как context-menu PASS.

[`xdg_popup.grab`](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/1.48/stable/xdg-shell/xdg-shell.xml)
привязывает grab к пользовательскому событию; он не требует, чтобы кнопка
оставалась нажатой до обработки асинхронного запроса. Отказ нарушал обычный
Qt context-menu flow при быстром press/release.

**Production fix.** RayWM хранит только последний действительно доставленный
pointer press как одноразовое право popup invocation: до **5 s**, та же pointer
surface, тот же focused root/client и keyboard focus epoch. Новый press заменяет
право; focus change/host focus loss очищает pointer и keyboard grants;
успешный popup grab потребляет pointer grant. Nested menus используют текущую
Smithay grab chain. Move/resize и DnD по-прежнему требуют held serial.
Никакой второй popup geometry store не создан.

**Harness fix.** Probe логирует QMenu hovered/aboutToShow/aboutToHide,
paint/visible/platform-surface, геометрию и motion. Координаты берутся из
`actionGeometry`/`mapToGlobal`; после enter указатель движется внутри item,
потому что enter сам по себе не является motion. Qt сам запускает submenu timer
и создаёт child/grandchild. Новые hover-проверки ждут наблюдаемые события до
5 s, без произвольного длинного sleep. Цвета меню диагностические; они помогают
проверить реальные пиксели, а не эмулируют popup rendering.

[Полный Qt trace](final/qt-menu-ctx.log), [события](final/qt-menu-ctx-events.log),
[summary](final/qt-menu-summary.json), [реальный screenshot](final/qt-nested-menus.png).

| Menu | Parent-relative configure | Output rect (x,y,w,h) |
|---|---|---|
| root, popup 33 | 251,150,124,54 | 251,150,124,54 |
| child, popup 40 | 122,27,130,54 | 373,177,130,54 |
| grandchild, popup 47 | 128,27,124,29 | 501,204,124,29 |

Все три popup получают по одному configure, ACK и buffered render. Parent XDG
chain: toplevel → root → child → grandchild. Все grab-запросы используют press
**483**, после release 484. Hover MORE-QT открывает child, DEEPER-QT открывает
grandchild, LEAF-QT получает hover и motion. Переход child → grandchild повторён
с проверкой **новых**, а не старых motion events. PNG checker подтверждает
пиксели трёх menu surfaces внутри output. Outside-click `(700,550)` вызывает
по одному aboutToHide и destroy в порядке **47 → 40 → 33**. Это клик внутри
поверхности того же приложения, поэтому Qt закрывает свои меню сам; отсутствие
popup_done в этом конкретном trace корректно. Compositor outside-dismiss
отдельно проверяется Rust/Stage 3 сценариями. Configure-loop/stale popup не обнаружены.

Boundary constraints, pending parent offsets, output shrink, reactive reposition,
ACK/commit и ancestor teardown дополнительно проходят неизменённый reactive
popup scenario; его [лог](final/reactive_popup_constraints_and_lifecycle.log) и
[submitted pixels](final/shot-popup-child.png) сохранены.

## DnD source-disconnect: подтверждённый upstream defect

Статус: **CONFIRMED UPSTREAM LIMITATION; transfer не PASS**.

Прежний Rust disconnect case не принимал offer, поэтому обоснованно проверял
отсутствие drop, но не покрывал спорный accepted path. Новый независимый case
принимает UTF-8 MIME, согласует Copy, дожидается source action, disconnect source,
затем подаёт следующий motion/release. Результат детерминирован в этом run:
**drop=1, leave=1; receive FD EOF; bytes=0**.
[Wire trace](final/final_admission_and_accepted_source_disconnect.log),
[события](final/final_admission_and_accepted_source_disconnect-events.log),
[результат](final/accepted-disconnect.txt).

Фактический путь Smithay 0.7.0:

1. `input/pointer/mod.rs: PointerInternal::with_grab` обнаруживает dead origin
   и вызывает `handler.unset`.
2. `selection/data_device/dnd_grab.rs: PointerGrab::unset` вызывает `self.drop`.
3. `DnDGrab::drop` проверяет accepted MIME / chosen action, но не source.alive;
   при живом target отправляет drop и leave.
4. Receive отдельно проверяет source.alive и не пересылает FD мёртвому source;
   RAII закрывает FD и receiver видит EOF.

[Wayland 1.26 specification](https://gitlab.freedesktop.org/wayland/wayland/-/blob/1.26.0/protocol/wayland.xml)
требует отмены DnD при уничтожении source. Это не просто допустимый successful
drop без содержимого. Qt target в toolkit source-close case действительно может
создать пустой файл: приложение, доверяющее drop/MIME без валидации payload,
способно ошибочно принять результат за успех. Payload assertions не разрешают
считать этот case успешной передачей.

RayWM не владеет offer acceptance/action state. Вызов обычного unset не помогает:
он и есть upstream drop path. Попытка очистить focus через motion после смерти
origin сначала попадает в ту же dead-grab ветку. В dropped callback grab уже
обрабатывается под pointer/seat state; повторный доступ к нему рискует recursive
lock. Безопасного универсального cancellation API в используемом публичном пути
не найдено. Параллельный DnD manager и локальный fork библиотеки не добавлены.

Минимальное направление upstream fix: учитывать живость source при вычислении
validated в drop, переводить offer в inactive при source death и отличать cancel
от успешного button-release unset. Одна проверка source.alive подавит наблюдаемый
ложный drop, но для полной семантики нужен source-destroy cancellation path,
включая destroy source при ещё живом origin. Предложение здесь не применено и
не объявлено протестированным upstream patch. Изменение зависимости требует
нового regression run; characterization assertion намеренно потребует re-audit,
если pinned behavior изменится.

## Production и test changes

Production: `input.rs`, `selection.rs`, `popups.rs`, `state.rs` — ограниченный
pointer popup grant и focus invalidation; DnD admission проверяет владельца
client, точное соответствие origin implicit-focus surface, held button и отсутствие
active DnD/popup/move/resize. Smithay 0.7 сам проверял лишь наличие grab с serial;
знание чужого serial не должно предоставлять право на чужой grab. Замена уже
активного DnD тем же serial могла преждевременно вызвать его drop path и теперь
отклоняется. Source/offer/action/FD manager остаётся Smithay.

Tests: третий opt-in graphical Rust scenario для foreign live serial, wrong
origin, popup after-release, replay/forged/expiry/focus-epoch и accepted disconnect.
В исходный DnD scenario добавлен запрет повторного start_drag. Новый replay case
возвращает pointer focus без нового press; focus-epoch case использует map/close
третьего клиента, также без нового press. Harness восстанавливает output 800×600
после reactive test: прежняя утечка 700×500 делала outside-click вне child window.
GTK drop callback исправлен на предусмотренный GTK gboolean return TRUE.
Missing toolkit dependencies и ненаблюдаемые события завершаются ошибкой;
BLOCKED больше не превращается в общий PASS. Старые assertions не отключены.

## Полная regression matrix

Все команды ниже выполнены заново. Cargo команды запускаются из `rust/`.
[Машиночитаемые exit codes](final/cargo-results.json),
[Stage 2](final/stage2.log), [Stage 3](final/stage3.log),
[Stage 4A](final/stage4a.log), [Stage 4B](final/stage4b.log).

| Команда / сценарий | Результат |
|---|---|
| `cargo fmt --all -- --check` | PASS, exit 0 |
| `cargo check --workspace --locked` | PASS, exit 0 |
| `cargo clippy --workspace --all-targets --locked -- -D warnings` | PASS, exit 0 |
| `cargo test --workspace --locked` | PASS: 7 core + 11 protocol/process |
| `cargo build --workspace --locked` | PASS, exit 0 |
| `cargo check --workspace --no-default-features --locked` | PASS, exit 0 |
| `cargo clippy --workspace --all-targets --no-default-features --locked -- -D warnings` | PASS, exit 0 |
| `cargo test --workspace --no-default-features --locked` | PASS: 7 core + 11 protocol/process |
| `cargo build --workspace --no-default-features --locked` | PASS, exit 0 |
| `tests/docs-sync.sh` из корня | PASS: 54 API names, 28 events, 11 settings, 8 IPC methods, 5 options |
| Stage 2 nested smoke | PASS: pixels/input/resize/unmap/cleanup |
| Stage 3 nested smoke | PASS: floating, focus, grabs, ACK, nested popups; 3 independent Zig clients |
| Stage 4A selection harness | PASS: clipboard/primary, serial policy, MIME/FD/EPIPE/source teardown, foot |
| GTK/Qt clipboard copy/paste | PASS в Stage 4A, реальные payload files |
| Stage 4B DnD/icon harness | PASS: copy/move/ask, switching, icon scale/cleanup, forged/stale, finish, recovery |
| Stage 4B reactive popup harness | PASS: move/output/resize/nesting/reposition/unmap/unACKed destroy |
| Новая admission regression | PASS: foreign/origin/active DnD/replay/expiry/focus epoch |
| GTK → Qt pointer-driven DnD | PASS, точный `gtk-to-qt` |
| Qt → GTK pointer-driven DnD | PASS, точный `qt-to-gtk` |
| Toolkit cancellation/target close/source close | PASS lifecycle; source close не считается transfer |
| GTK primary selection | PASS, UTF-8 FD payload 11 bytes |
| Qt primary selection | PASS, UTF-8 FD payload 10 bytes |
| Qt submenu, два вложенных уровня | PASS: hover/wire/render/motion/grab/teardown |
| Popup и process/socket/lock cleanup | PASS во всех четырёх harness |
| Accepted-source disconnect, upstream semantics | CONFIRMED DEFECT: drop + empty FD, не successful-transfer PASS |

Default Cargo run содержит **6 graphical ignored tests**, и все шесть реально
исполнены четырьмя harness с `--ignored --exact`; новый ignore отражает требование
приватного graphical parent, а не скрывает FAIL. Headless-only оставляет один
существовавший graphical test ignored, DnD Winit tests там не компилируются.
Промежуточные неудачи и их причины не включены в итоговые PASS:
[iterations](final/iterations.txt).

## Целевой security/lifecycle audit Stage 4A/4B

| Путь | Проверка / evidence / остаток |
|---|---|
| Keyboard/data-device focus | Один seat focus; clipboard/primary выводятся из фактического keyboard focus. Focus epochs очищают serial log; новые devices refresh получают текущее offer. Stage 4A PASS. |
| Selection serial | Сохраняются 10 s / 64 события / client identity и upstream keyboard-owner check. GTK press и Qt release проверены по trace; forged/focus-stale отсекаются. |
| Popup grants | Root/client/pointer surface, 5 s, одноразовость, focus/host-loss invalidation. Replay, expiry, foreign/stale и nesting проходят; геометрия остаётся в PopupManager. |
| DnD ownership | Добавлены exact origin/client/held-button проверки; active explicit grabs не заменяются. Чужой известный live serial и неверный origin отвергаются, release остаётся у законного клиента. |
| DnD lifecycle | Target switching/accept/actions/finish находятся в Smithay. Повторные drop/finish и recovery проверены. Source-disconnect exception описан выше и не скрыт. |
| Selection source teardown | Resource destroyed delegation + focus refresh инвалидируют owner/offer; receiver/source disconnect и новые запросы проверены. Второй source registry отсутствует. |
| FD ownership | Borrowed fd передаётся source; owned request fd освобождается после forwarding/отказа. Unknown MIME/early-close/EPIPE и dead-source EOF проверены. Compositor не читает payload синхронно. |
| Drag icon | Render-only handle, не hit-test target; commits/scale/frame callbacks проверены. Drop/cancel/icon destroy/source disconnect убирают icon; повторный drag работает. |
| Popup configure | ACK-gated map, latest pending ancestor offsets, last geometry coalescing, non-reactive blocking. Invalid parents, early buffers и unACKed destroy изолированы по клиенту. |
| Destroy/unmap | Root unmap/destroy dismisses subtree, отменяет операции и repairs focus. Инертные client-owned protocol objects до destroy разрешены и не являются живыми popup targets. |
| Locks/reentrancy | Role geometry/parent traversal выполняются вне вложенных role closures. Icon frames читают уже полученный SurfaceData. DnD dropped callback только очищает local flags/icon, не входит повторно в pointer/seat. |
| Ошибочные запросы / panic | Admission завершается отказом, malformed XDG clients получают protocol errors; следующий клиент остаётся работоспособен. Новых unwrap/expect/unsafe или client-controlled panic не добавлено. Полный аудит всех зависимостей не заявляется. |

В проверенных RayWM путях известных критических lifecycle/security дефектов
после исправлений не обнаружено. Это targeted review плюс executable regressions,
а не доказательство отсутствия всех проблем в Smithay или untrusted-client
production hardening. Существующий общий trust boundary не расширен.

## Ограничения, evidence и Git

Остаются upstream accepted-source-disconnect protocol defect, отсутствие
server-side DnD, полный application/theme matrix, hardware/DRM/input/HiDPI/IME,
sanitizers и production resource budgets. Всё перечисленное за пределами этой
nested/software qualification; неизвестные сценарии не объявлены PASS.

Полные logs, исходники toolkit probes, настоящие PNG, summaries и payloads
сохранены в `final/`. [Source hashes](final/sources.sha256) привязывают evidence к
Rust исходникам; [artifact hashes](final/artifacts.sha256) проверяют архив.
Screenshots получены grim в приватном parent и проверены PNG checker; toolkit
тесты не подменены synthetic protocol clients. Исторический исходный отчёт
сохранён с явной ссылкой на этот Final record.

Итог оформляется одним локальным коммитом
`fix(rust): resolve stage 4b protocol and toolkit regressions` поверх указанной
базы. Его hash сообщается в финальном ответе (не включается в собственное дерево
коммита). Push, merge и release не выполняются.
