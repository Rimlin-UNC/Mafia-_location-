/* Веб-клиент «Мафия Offline».
 *
 * Работает поверх ТОГО ЖЕ WebSocket-протокола, что и нативное приложение:
 * ведущий не отличает браузерного игрока от установленного APK.
 *
 * ГЛАВНОЕ ОБ УСТОЙЧИВОСТИ
 * -----------------------
 * Браузер на телефоне — враждебная среда. Экран гаснет, вкладка уходит в фон,
 * система замораживает таймеры и рвёт сокет молча, не вызывая onclose.
 * Игрок возвращается через минуту и видит зависшую страницу.
 *
 * Отсюда четыре механизма:
 *
 * 1. НЕОГРАНИЧЕННОЕ ПЕРЕПОДКЛЮЧЕНИЕ с растущей паузой (0.4с → 8с) и
 *    случайным разбросом. Разброс важен: если Wi-Fi моргнул у всех сразу,
 *    без него 20 телефонов ломятся в сокет в одну миллисекунду и телефон
 *    ведущего захлёбывается. Прежняя версия сдавалась после 3 попыток.
 *
 * 2. СТОРОЖЕВОЙ ТАЙМЕР. Сокет считается живым, только если ответ на ping
 *    пришёл за последние 20 секунд. Молчащее «подключено» — самый частый
 *    и самый обидный сбой: игрок думает, что в игре, а его хода не ждут.
 *
 * 3. ТАЙМЕР ПО ЧАСАМ, А НЕ ПО ТИКАМ. setInterval в фоне останавливается,
 *    и после возврата обратный отсчёт врёт на минуту. Считаем оставшееся
 *    время как «дедлайн минус текущее время».
 *
 * 4. ВОЗВРАТ ПОСЛЕ ФОНА. При visibilitychange сразу проверяем сокет,
 *    шлём resync и, если нужно, переподключаемся, не дожидаясь таймаутов.
 */
'use strict';

const V = 1;                       // версия протокола — должна совпадать с Dart
const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------- состояние
const S = {
  ws: null, playerId: null, name: '', code: '',
  phase: 'waiting', round: 0, paused: false,
  // deadline — момент (в наших часах), когда фаза закончится.
  // time держим только для показа, источник истины — deadline.
  time: 0, deadline: 0,
  isAlive: true, canAct: false, sent: false,
  role: null, roleName: null, roleEmoji: null, roleDesc: null,
  mates: [], targets: [], selected: null,
  disguised: false, revealed: false, awaitingReveal: false,
  lobby: [], log: [], reveal: [],
  attempt: 0, tick: null, manualClose: false,
  joined: false,          // прошли ли регистрацию хоть раз
  lastPongAt: 0,          // когда последний раз слышали хост
  connected: false,
  // Действие, отправленное без подтверждения. Повторяем после реконнекта:
  // иначе выбор, сделанный в момент обрыва, пропадёт и игрок потеряет ход.
  pendingAction: null,
  reclaimShown: false,   // баннер «вы вернулись» показываем один раз за партию
};

/// Русские названия ролей по проводному имени. Нужны там, где сервер
/// присылает только `RoleType.name` (открытая карта выбывшего), а не
/// готовую подпись: без словаря игрок увидел бы «maniac».
const ROLE_RU = {
  mafia: 'Мафия',
  don: 'Дон',
  doctor: 'Доктор',
  commissioner: 'Комиссар',
  prostitute: 'Проститутка',
  maniac: 'Маньяк',
  civilian: 'Мирный житель',
};


// ------------------------------------------------------- синхронизация часов
// Телефоны имеют разные часы (расхождение бывает в десятки секунд), поэтому
// вычисляем смещение относительно ведущего по схеме NTP и берём медиану
// трёх замеров с наименьшим rtt — они сделаны, когда сеть была свободна.
const Clock = {
  samples: [], offset: 0, rtt: 0,
  onPong(sentAt, hostTime) {
    if (!sentAt || !hostTime) return;
    const rtt = Date.now() - sentAt;
    if (rtt < 0 || rtt > 5000) return;
    this.samples.push({ rtt, off: hostTime - (sentAt + rtt / 2) });
    if (this.samples.length > 24) this.samples.shift();
    const best = [...this.samples].sort((a, b) => a.rtt - b.rtt).slice(0, 3);
    this.rtt = best[0].rtt;
    const offs = best.map(s => s.off).sort((a, b) => a - b);
    this.offset = offs[Math.floor(offs.length / 2)];
  },
  // Смещение переживает переподключение: часы за 2 секунды не убежали,
  // а сбросив его, мы бы на первых секундах играли звук вразнобой.
  softReset() { this.samples = this.samples.slice(-4); },
};

// -------------------------------------------------------------------- звук
const Sound = {
  ctx: null, cache: {}, enabled: true, ambient: null,
  ambientNode: null, ambientGain: null, muted: false,
  pending: null,   // фон, который не смогли запустить до жеста пользователя

  unlock() {
    try {
      if (!this.ctx) {
        this.ctx = new (window.AudioContext || window.webkitAudioContext)();
      }
      // На iOS контекст засыпает при каждом уходе в фон — будим каждый раз.
      if (this.ctx.state === 'suspended') this.ctx.resume();
      if (this.pending) { const p = this.pending; this.pending = null; this.playAmbient(p); }
    } catch (e) { this.enabled = false; }
  },

  async load(name) {
    if (!this.ctx) return null;
    if (this.cache[name]) return this.cache[name];
    try {
      const r = await fetch('/sounds/' + name, { cache: 'force-cache' });
      const buf = await this.ctx.decodeAudioData(await r.arrayBuffer());
      this.cache[name] = buf;
      return buf;
    } catch (e) { return null; }
  },

  async play(name, vol = 1, when = 0) {
    if (!this.enabled || this.muted || !this.ctx) return;
    const buf = await this.load(name);
    if (!buf) return;
    const src = this.ctx.createBufferSource();
    const g = this.ctx.createGain();
    g.gain.value = vol;
    src.buffer = buf; src.connect(g); g.connect(this.ctx.destination);
    src.start(when > 0 ? this.ctx.currentTime + when / 1000 : 0);
  },

  // Звук в момент, назначенный ведущим: переводим его время в наше.
  scheduleAt(hostPlayAt, name, vol) {
    const delay = (hostPlayAt - Clock.offset) - Date.now();
    if (delay <= 0) { if (delay > -1200) this.play(name, vol); return; }
    this.play(name, vol, delay);
  },

  async playAmbient(name) {
    if (!this.enabled || this.muted) return;
    if (!this.ctx || this.ctx.state === 'suspended') { this.pending = name; return; }
    if (this.ambient === name) return;
    this.stopAmbient();
    const buf = await this.load(name);
    if (!buf) return;
    const src = this.ctx.createBufferSource();
    const g = this.ctx.createGain();
    g.gain.value = 0.3;
    src.buffer = buf; src.loop = true;
    src.connect(g); g.connect(this.ctx.destination);
    src.start();
    this.ambient = name; this.ambientNode = src; this.ambientGain = g;
  },

  stopAmbient() {
    try { if (this.ambientNode) this.ambientNode.stop(); } catch (e) {}
    this.ambient = null; this.ambientNode = null; this.pending = null;
  },

  toggleMute() {
    this.muted = !this.muted;
    localStorage.setItem('mafia_muted', this.muted ? '1' : '0');
    if (this.muted) this.stopAmbient();
    else applyAmbient();
    updateMuteBtn();
    return this.muted;
  },
};

// ------------------------------------------------------- вибрация и экран
// Короткий отклик на нажатие — на телефоне это заметно приятнее, чем
// только визуальное выделение. Там, где вибрации нет, вызов молча игнорируется.
function buzz(ms) {
  try { if (navigator.vibrate) navigator.vibrate(ms); } catch (e) {}
}

// Не давать экрану гаснуть во время партии: иначе игрок каждые 30 секунд
// разблокирует телефон, а браузер успевает заморозить вкладку.
const Screen = {
  lock: null,
  async acquire() {
    try {
      if (!('wakeLock' in navigator) || this.lock) return;
      this.lock = await navigator.wakeLock.request('screen');
      this.lock.addEventListener('release', () => { this.lock = null; });
    } catch (e) {}
  },
  release() {
    try { if (this.lock) this.lock.release(); } catch (e) {}
    this.lock = null;
  },
};

// -------------------------------------------------------------------- экраны
function show(id) {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  $(id).classList.add('active');
}

// ---------------------------------------------------------------- соединение
let pingTimer = null, watchTimer = null, retryTimer = null, lastPing = 0;

// Постоянный идентификатор этого браузера. Нужен, чтобы сервер отличал
// «он открыл игру на втором устройстве» от «кто-то занял его имя».
// Это случайная строка в localStorage, а не отпечаток устройства.
function deviceId() {
  try {
    let id = localStorage.getItem('mafia_device');
    if (!id || id.length < 8) {
      const bytes = new Uint8Array(12);
      crypto.getRandomValues(bytes);
      id = Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
      localStorage.setItem('mafia_device', id);
    }
    return id;
  } catch (e) {
    return '';
  }
}

function connect() {
  if (S.ws && (S.ws.readyState === 0 || S.ws.readyState === 1)) return;
  S.manualClose = false;
  clearTimeout(retryTimer);

  let ws;
  try {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    // __WS__ задаётся только автотестом, где сокет живёт на другом порту.
    // В реальной игре сервер и страница — это один и тот же порт 8088.
    const url = window.__WS__ || `${proto}//${location.host}/ws`;
    ws = new WebSocket(url);
  } catch (e) { scheduleRetry(); return; }

  S.ws = ws;
  setConn(false, 'Подключение…');

  // Сокет может «открываться» бесконечно, если хост исчез из сети.
  // Через 8 секунд считаем попытку неудачной и заходим на новый круг.
  const openGuard = setTimeout(() => {
    if (ws.readyState !== 1) { try { ws.close(); } catch (e) {} }
  }, 8000);

  ws.onopen = () => {
    clearTimeout(openGuard);
    S.attempt = 0;
    S.lastPongAt = Date.now();
    setConn(true);
    // Повторный вход после обрыва — сервер вернёт нас в свой слот
    // по имени (см. reclaim в host_controller.dart).
    send('register', {
      name: S.name, code: S.code, deviceId: deviceId(),
    });
    startPing();
    startWatchdog();
  };

  ws.onmessage = (e) => {
    try { onMessage(JSON.parse(e.data)); } catch (err) {}
  };

  ws.onclose = () => {
    clearTimeout(openGuard);
    setConn(false);
    stopPing();
    if (!S.manualClose) scheduleRetry();
  };

  ws.onerror = () => { /* onclose придёт следом, обработка там */ };
}

function send(type, data) {
  if (!S.ws || S.ws.readyState !== 1) return false;
  try {
    S.ws.send(JSON.stringify({ v: V, ts: Date.now(), type, ...(data || {}) }));
    return true;
  } catch (e) { return false; }
}

function startPing() {
  stopPing();
  const beat = () => {
    lastPing = Date.now();
    send('ping', { playerId: S.playerId, t: lastPing, rtt: Clock.rtt || undefined });
  };
  beat();
  pingTimer = setInterval(beat, 5000);
}

function stopPing() {
  if (pingTimer) clearInterval(pingTimer);
  pingTimer = null;
}

// Сторожевой таймер: сокет может числиться открытым, хотя связи давно нет
// (телефон ушёл из зоны Wi-Fi — TCP узнает об этом через минуты).
// Если хост молчит дольше 20 секунд, рвём соединение сами и переподключаемся.
function startWatchdog() {
  if (watchTimer) clearInterval(watchTimer);
  watchTimer = setInterval(() => {
    if (!S.ws || S.ws.readyState !== 1) return;
    const silence = Date.now() - S.lastPongAt;
    if (silence > 20000) {
      setConn(false, 'Связь потеряна — восстанавливаем…');
      try { S.ws.close(); } catch (e) {}
    } else if (silence > 11000) {
      setConn(false, 'Плохая связь…');
    }
  }, 3000);
}

// Пауза растёт, но не бесконечно, и всегда со случайной добавкой:
// 20 телефонов не должны стучаться в один и тот же миллисекундный слот.
function scheduleRetry() {
  if (S.manualClose) return;
  S.attempt++;
  const base = Math.min(400 * Math.pow(1.6, Math.min(S.attempt, 8)), 8000);
  const wait = Math.round(base + Math.random() * 600);
  setConn(false, `Переподключение через ${Math.ceil(wait / 1000)} с…`);
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connect, wait);
}

function setConn(ok, text) {
  S.connected = ok;
  const dot = $('conn-dot');
  const el = $('conn-text');
  if (dot) dot.className = 'dot' + (ok ? '' : ' off');
  if (el) el.textContent = text || (ok ? 'Подключено' : 'Нет связи');
  const bar = $('conn');
  if (bar) bar.classList.toggle('warn', !ok && S.joined);
}

// ------------------------------------------------------- обработка сообщений
function onMessage(m) {
  S.lastPongAt = Date.now();

  switch (m.type) {
    case 'pong':
      Clock.onPong(m.echo || lastPing, m.hostTime);
      if (!S.connected) setConn(true);
      return;

    case 'sound':
      if (m.asset) Sound.scheduleAt(m.playAt, m.asset.replace('sounds/', ''), m.volume ?? 1);
      return;

    case 'register_ok':
    case 'reclaimed':
      S.playerId = m.id;
      S.joined = true;
      S.attempt = 0;
      if (m.gameName) {
        $('game-title').textContent = m.gameName;
        $('lobby-title').textContent = m.gameName;
      }
      saveSession();
      if (m.type === 'reclaimed') {
        // Хост следом сам пришлёт sync с ролью, фазой и таймером —
        // запрашивать его отдельно нельзя: на resync он отвечает
        // тем же reclaimed, и клиент с сервером зациклятся.
        if (!S.reclaimShown) { banner('Вы вернулись в игру', 'ok'); }
        S.reclaimShown = true;
        // Ход, отправленный в момент обрыва, мог не дойти — повторяем.
        flushPending();
      }
      if (S.phase === 'waiting') show('scr-lobby');
      Screen.acquire();
      renderMe();
      break;

    case 'register_denied': {
      const why = {
        name_taken: 'Это имя уже занято — выберите другое',
        game_full: 'В игре нет свободных мест',
        game_started: 'Игра уже началась, дождитесь следующей партии',
        bad_code: 'Неверный код игры',
        // Старая страница из кэша после обновления игры на телефоне ведущего.
        bad_version: 'Версия страницы устарела. Закройте вкладку, '
          + 'откройте её заново (или обновите) и подключитесь снова.',
      }[m.reason] || 'Не удалось подключиться';

      // Отказ — это ответ хоста, а не сбой связи: перестаём ломиться.
      S.manualClose = true;
      S.joined = false;
      clearTimeout(retryTimer);
      if (S.ws) { try { S.ws.close(); } catch (e) {} }
      // Имя занято — сессия неверна, иначе застрянем в цикле отказов.
      if (m.reason === 'name_taken') localStorage.removeItem('mafia_session');
      if (m.reason === 'bad_version') {
        // Переподключение не поможет: страница сама устарела.
        // Показываем большой экран «обновите», а не форму входа.
        showFatal('Нужно обновить страницу',
          'Ведущий обновил игру, и ваш браузер держит старую версию '
          + 'из кэша. Нажмите «Попробовать снова» — страница '
          + 'перезагрузится и подтянет новую версию.');
        break;
      }
      showJoinError(why);
      show('scr-join');
      break;
    }

    case 'lobby':
      S.lobby = m.players || [];
      $('lobby-count').textContent = `${S.lobby.length}/${m.planned || '?'}`;
      if (m.gameName) $('lobby-title').textContent = m.gameName;
      renderLobby();
      break;

    case 'role_assign':
      // Пакет приходит дважды: при раздаче и по кнопке ведущего
      // «показать роль ещё раз». Во втором случае предупреждение
      // обязательно показываем снова — иначе роль всплывёт поверх стола.
      S.role = m.role; S.roleName = m.roleName;
      S.roleEmoji = m.roleEmoji; S.roleDesc = m.roleDescription;
      S.mates = m.teammates || [];
      S.awaitingReveal = true; S.revealed = false;
      buzz([40, 60, 40]);
      show('scr-reveal');
      break;

    case 'phase':
    case 'sync':
      applyPhase(m);
      break;

    case 'time_update':
      if (typeof m.time === 'number') setDeadline(m.time);
      S.paused = m.paused ?? S.paused;
      renderTimer();
      break;

    case 'night_result': {
      let text = m.text || '';
      // Настройка стола: карта выбывшего открыта — называем роль сразу.
      // Закрытая карта (по умолчанию) не выдаёт ничего: интрига первого круга.
      if (m.revealed) {
        const roles = m.killedNames
          .map((n, i) => [n, m.revealed[m.killed[i]]])
          .filter(([, r]) => r)
          .map(([n, r]) => `${n} — ${ROLE_RU[r] || r}`);
        if (roles.length) text += ` (${roles.join(', ')})`;
      }
      if (text) { banner(text, m.killed && m.killed.length ? 'bad' : 'ok'); addLog(text); }
      if (m.killed && m.killed.length) { flash(); buzz(120); }
      break;
    }

    case 'vote_runoff':
      S.targets = (m.candidates || []).map(c => ({ id: c.id, name: c.name, color: c.color || '#8d93a8' }));
      S.canAct = S.isAlive; S.sent = false; S.selected = null;
      banner('Второй тур голосования', 'info');
      buzz(60);
      render();
      break;

    case 'vote_result': {
      const t = m.eliminatedName
        ? `Голосованием выбыл ${m.eliminatedName}` +
          (m.revealedRole ? ` — ${m.revealedRole}` : '')
        : 'Голосование: никто не выбывает';
      banner(t, 'info'); addLog(t);
      break;
    }

    case 'eliminated':
      S.isAlive = false; S.canAct = false;
      banner(m.reason === 'vote' ? 'Вас выгнали голосованием' : 'Вас убили этой ночью', 'bad');
      flash(); buzz([100, 80, 100]); render();
      break;

    case 'rename':
      if (m.name) {
        S.name = m.name;
        saveSession();
        banner(`Ведущий изменил ваше имя на «${m.name}»`, 'info');
        renderMe();
      }
      break;

    case 'kick':
      S.manualClose = true;
      clearTimeout(retryTimer);
      // Второе устройство/вкладка — не выкидываем сессию, человек
      // просто перешёл на другой телефон.
      if (m.reason !== 'another_device') localStorage.removeItem('mafia_session');
      if (S.ws) { try { S.ws.close(); } catch (e) {} }
      Screen.release();
      if (m.reason === 'another_device') {
        showFatal('Вы открыли игру в другом окне',
          'Эта вкладка больше не активна. Продолжайте в том окне, которое открыли последним.');
      } else {
        showFatal('Ведущий исключил вас из игры',
          'Обратитесь к ведущему, если это ошибка.');
      }
      break;

    case 'game_over':
      S.phase = 'ended';
      Sound.stopAmbient();
      Screen.release();
      localStorage.removeItem('mafia_session');
      $('over-title').textContent = m.title || 'Игра окончена';
      S.reveal = m.reveal || [];
      renderReveal();
      show('scr-over');
      break;

    case 'ack':
      // Хост подтвердил приём — можно забыть про повтор.
      S.pendingAction = null;
      S.sent = true; S.canAct = false;
      render();
      break;
  }
  render();
}

// Повтор действия, отправленного перед самым обрывом.
function flushPending() {
  const p = S.pendingAction;
  if (!p) return;
  // Фаза могла смениться, пока нас не было — тогда ход уже не нужен.
  if (p.phase !== S.phase || p.round !== S.round) { S.pendingAction = null; return; }
  send(p.type, { playerId: S.playerId, targetId: p.targetId });
}

function applyPhase(m) {
  const prevPhase = S.phase;
  S.phase = m.phase || S.phase;
  S.round = m.round ?? S.round;
  if (typeof m.time === 'number') setDeadline(m.time);
  S.paused = m.paused ?? false;
  S.isAlive = m.isAlive ?? S.isAlive;
  S.canAct = m.canAct ?? false;
  S.sent = m.alreadyActed ?? false;
  S.targets = m.targets || [];
  S.selected = null;
  if (m.prompt) $('prompt').textContent = m.prompt;
  if (m.gameName) $('game-title').textContent = m.gameName;

  // sync после переподключения приносит роль заново
  if (m.role) S.role = m.role;
  if (m.roleName) S.roleName = m.roleName;
  if (m.roleEmoji) S.roleEmoji = m.roleEmoji;
  if (m.roleDescription) S.roleDesc = m.roleDescription;
  if (m.teammates && m.teammates.length) S.mates = m.teammates;

  // Проверяем ПОСЛЕ присвоения roleName: на перезагруженной странице роль
  // приходит тем же пакетом, и раньше этой строки S.roleName ещё null.
  if (typeof m.roleAck === 'boolean' && S.roleName && !m.roleAck) {
    // Не подтвердил — значит, экран-предупреждение не пройден.
    // Без этого первая ночь ждала бы игрока вечно.
    S.awaitingReveal = true;
  }

  // Смена фазы отменяет неподтверждённый ход из прошлой.
  if (prevPhase !== S.phase) S.pendingAction = null;

  // Карта закрывается при каждой смене фазы — чтобы не осталась
  // раскрытой на столе после ночного хода.
  if (prevPhase !== S.phase) S.revealed = false;

  applyAmbient();

  // Вибро на старте фазы, где от игрока ждут действия: телефон часто
  // лежит на столе экраном вниз.
  if (prevPhase !== S.phase && S.canAct && S.isAlive) buzz([50, 40, 50]);

  // Перезагрузка страницы до подтверждения роли: экран-предупреждение
  // нужно показать заново, иначе игрок останется на экране входа.
  if (S.awaitingReveal && S.roleName) show('scr-reveal');
  if (S.phase !== 'waiting' && !S.awaitingReveal) show('scr-game');
  startTick();
}

function applyAmbient() {
  const amb = { night: 'night_ambient.wav', day: 'day_ambient.wav',
                voting: 'vote_ambient.wav' }[S.phase];
  if (amb) Sound.playAmbient(amb); else Sound.stopAmbient();
}

// ------------------------------------------------------------------- таймер
// Считаем от дедлайна, а не «минус секунда на каждый тик»: в фоне
// setInterval замирает, и тиковый счётчик после возврата врёт на минуту.
function setDeadline(secondsLeft) {
  S.time = Math.max(0, secondsLeft | 0);
  S.deadline = Date.now() + S.time * 1000;
}

function currentLeft() {
  if (S.paused) return S.time;
  return Math.max(0, Math.round((S.deadline - Date.now()) / 1000));
}

function startTick() {
  if (S.tick) clearInterval(S.tick);
  S.tick = setInterval(() => {
    if (S.phase === 'ended') return;
    const left = currentLeft();
    if (left !== S.time) { S.time = left; renderTimer(); }
  }, 500);
}

function renderTimer() {
  const s = Math.max(0, S.paused ? S.time : currentLeft());
  const el = $('phase-timer');
  el.textContent =
    String(Math.floor(s / 60)).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0');
  // Последние 10 секунд подсвечиваем — иначе люди не успевают.
  el.classList.toggle('urgent', s <= 10 && s > 0 && !S.paused && S.canAct);
  $('phase-bar').classList.toggle('paused', !!S.paused);
}

// ---------------------------------------------------------------- отрисовка
const PHASES = {
  waiting: ['⏳', 'Ожидание', 'night'],
  // Роли розданы, ночь ещё не началась. Отдельная фаза нужна и клиенту:
  // показывать «Ночь» раньше времени — значит путать стол.
  rolesCheck: ['🎴', 'Раздача ролей', 'day'],
  night:   ['🌙', 'Ночь',      'night'],
  day:     ['☀️', 'День',      'day'],
  voting:  ['🗳',  'Голосование', 'voting'],
  ended:   ['🏁', 'Финал',     'day'],
};

function render() {
  const [ico, nm, cls] = PHASES[S.phase] || PHASES.waiting;
  $('phase-ico').textContent = ico;
  $('phase-name').textContent = nm + (S.round ? ' ' + S.round : '') +
    (S.paused ? ' · пауза' : '');
  $('phase-bar').className = 'phase ' + cls + (S.paused ? ' paused' : '');
  renderTimer();

  const dead = !S.isAlive;
  const acting = S.canAct && S.targets.length && !S.sent && !dead;

  // Пока игрок выбирает цель, большая карта уступает место компактной
  // полосе: иначе список целей уезжает за нижний край экрана.
  const bigCard = !dead && S.phase === 'night' && !!S.roleName && !acting;
  const strip = !dead && acting && !!S.roleName;

  $('dead-area').classList.toggle('hidden', !dead);
  $('card-area').classList.toggle('hidden', !bigCard);
  $('role-strip').classList.toggle('hidden', !strip);
  if (strip) renderStrip();
  $('action-area').classList.toggle('hidden', !acting);
  $('idle-area').classList.toggle('hidden', acting || dead);
  $('game-foot').classList.toggle('hidden', !acting);
  $('btn-myrole').classList.toggle('hidden', !S.roleName);

  if (dead) {
    $('dead-role').textContent = `Ваша роль: ${S.roleEmoji || ''} ${S.roleName || '—'}`;
    renderLog();
  } else if (acting) {
    renderTargets();
    $('btn-send').disabled = !S.selected;
    $('btn-send').textContent = S.phase === 'voting' ? 'Проголосовать' : 'Отправить выбор';
    $('btn-skip').textContent = S.phase === 'voting' ? 'Воздержаться' : 'Пропустить ход';
  } else {
    renderIdle();
  }
  if (!$('card-area').classList.contains('hidden')) renderCard();
}

function renderIdle() {
  const night = S.phase === 'night';
  if (S.sent) {
    $('idle-emoji').textContent = '✅';
    $('idle-text').textContent = 'Ваш выбор принят';
    $('idle-sub').textContent = 'Ожидайте следующей фазы';
  } else if (S.phase === 'waiting') {
    $('idle-emoji').textContent = '⏳';
    $('idle-text').textContent = 'Ожидание';
    $('idle-sub').textContent = 'Ведущий скоро начнёт партию.';
  } else if (S.phase === 'rolesCheck') {
    $('idle-emoji').textContent = '🎴';
    $('idle-text').textContent = 'Роли розданы';
    $('idle-sub').textContent =
      'Ночь начнётся, когда все прочитают свою роль.';
  } else if (night) {
    $('idle-emoji').textContent = '😴';
    $('idle-text').textContent = 'Спите';
    $('idle-sub').textContent = 'Город засыпает. Ваша роль сейчас не действует.';
  } else {
    $('idle-emoji').textContent = '💬';
    $('idle-text').textContent = 'Обсуждайте';
    $('idle-sub').textContent = 'Говорите вслух. Скоро голосование.';
  }
}

function renderTargets() {
  // Плотная сетка при большом столе: на маленьком экране иначе видно
  // всего две строки из двадцати.
  $('targets').classList.toggle('dense', S.targets.length > 6);
  $('targets').innerHTML = S.targets.map(t => `
    <div class="p ${S.selected === t.id ? 'sel' : ''}" data-id="${esc(t.id)}">
      <div class="av" style="background:${esc(t.color || '#8d93a8')}">${esc((t.name || '?')[0])}</div>
      <div class="nm">${esc(t.name)}</div>
      <span class="pick">✓</span>
    </div>`).join('');
  $('targets').querySelectorAll('.p').forEach(el => {
    el.onclick = () => {
      S.selected = S.selected === el.dataset.id ? null : el.dataset.id;
      Sound.play('tap.ogg', 0.4);
      buzz(15);
      render();
    };
  });
}

// Компактная полоса роли: миниатюра карты + название в одну строку.
function renderStrip() {
  const dis = S.disguised;
  $('rs-img').src = dis ? '/cards/civilian.jpg' : `/cards/${S.role || 'civilian'}.jpg`;
  $('rs-emoji').textContent = dis ? '👤' : (S.roleEmoji || '');
  $('rs-name').textContent = dis ? 'Мирный житель' : (S.roleName || '');
  $('rs-mates').textContent = (!dis && S.mates.length)
    ? 'с вами: ' + S.mates.map(t => t.isDon ? `${t.name} 🎩` : t.name).join(', ')
    : (dis ? 'маскировка включена' : '');
}

function renderCard() {
  const dis = S.disguised;
  $('role-img').src = dis ? '/cards/civilian.jpg' : `/cards/${S.role || 'civilian'}.jpg`;
  $('role-emoji').textContent = dis ? '👤' : (S.roleEmoji || '');
  $('role-name').textContent = dis ? 'Мирный житель' : (S.roleName || '');
  $('role-mates').textContent = (!dis && S.mates.length)
    ? 'Союзники: ' + S.mates.map(t => t.isDon ? `${t.name} 🎩` : t.name).join(', ')
    : '';
  $('rc-back').classList.toggle('hidden', S.revealed);
  $('rc-disguise').classList.toggle('hidden', !dis || !S.revealed);
  $('role-card').classList.toggle('disguised', dis);
  $('btn-disguise').textContent = dis
    ? '🛡️ Маскировка включена — нажмите, чтобы выключить'
    : '🛡️ Скрыть настоящую роль';
}

function renderLobby() {
  $('lobby-list').innerHTML = S.lobby.map(p => `
    <div class="p ${p.isAlive === false ? 'dead' : ''}">
      <div class="av" style="background:${esc(p.color || '#8d93a8')}">${esc((p.name || '?')[0])}</div>
      <div class="nm">${esc(p.name)}
        <span class="sub">${p.name === S.name ? 'это вы' : (p.isConnected === false ? 'нет связи' : 'подключён')}</span></div>
      <span class="dot ${p.isConnected === false ? 'off' : ''}"></span>
    </div>`).join('');
}

function renderMe() {
  $('me-badge').innerHTML =
    `<span>👤</span><div><b>Вы: ${esc(S.name)}</b>
     <span class="sub dim">Изменить имя может только ведущий</span></div>`;
}

function renderReveal() {
  $('reveal-list').innerHTML = S.reveal.map(r => `
    <div class="p ${r.isAlive ? '' : 'dead'}">
      <div class="av" style="background:#2b2f40;color:#fff">${r.emoji || '?'}</div>
      <div class="nm">${esc(r.name)}<span class="sub">${esc(r.role || '')}</span></div>
      <span class="dim tiny">${r.isAlive ? 'выжил' : 'выбыл'}</span>
    </div>`).join('');
}

function renderLog() {
  $('log').innerHTML = S.log.length
    ? S.log.map(l => `<div>${esc(l)}</div>`).join('')
    : '<div class="dim">Пока пусто</div>';
}

function addLog(t) { S.log.unshift(t); if (S.log.length > 40) S.log.pop(); renderLog(); }

let bannerTimer = null;
function banner(text, kind) {
  const el = $('banner');
  el.textContent = text;
  el.className = 'alert ' + (kind || 'info');
  if (bannerTimer) clearTimeout(bannerTimer);
  bannerTimer = setTimeout(() => el.classList.add('hidden'), 9000);
}

function flash() {
  const d = document.createElement('div');
  d.className = 'flash';
  document.body.appendChild(d);
  setTimeout(() => d.remove(), 700);
}

function showFatal(title, sub) {
  $('fatal-title').textContent = title;
  $('fatal-sub').textContent = sub || '';
  show('scr-fatal');
}

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function saveSession() {
  try {
    localStorage.setItem('mafia_session',
      JSON.stringify({ code: S.code, name: S.name, at: Date.now() }));
  } catch (e) {}
}

// ------------------------------------------------------------ справка ролей
const GUIDE = {
  mafia: { goal: 'Вы в команде мафии. Ночью устраняете горожан, днём не выдаёте себя.',
    night: 'Просыпаетесь с командой и выбираете жертву. При расхождении решает голос дона.',
    day: 'Обсуждаете наравне со всеми. Отводите подозрения от своих.',
    win: 'Мафия побеждает, когда против неё остаётся не больше одного игрока.',
    tips: ['Не защищайте союзника слишком рьяно.', 'Иногда полезно проголосовать против своего.'] },
  don: { goal: 'Вы глава мафии. Ведёте команду и решаете, кого устранить.',
    night: 'Ваш голос решающий: если команда не сошлась, жертвой станет ваш выбор.',
    day: 'Играете как горожанин. Комиссар видит вас как мирного.',
    win: 'Мафия побеждает, когда против неё остаётся не больше одного игрока.',
    tips: ['Проверка покажет вас мирным — этим можно давить в споре.', 'Берегите себя.'] },
  doctor: { goal: 'Вы за город. Спасаете тех, на кого нацелились убийцы.',
    night: 'Выбираете игрока — он переживёт ночь. Нельзя лечить одного дважды подряд.',
    day: 'Обсуждаете и голосуете как обычный житель.',
    win: 'Город побеждает, когда мафии не осталось.',
    tips: ['Удачное спасение — сильная улика.', 'Не раскрывайтесь рано.'] },
  commissioner: { goal: 'Вы за город. По ночам вычисляете мафию.',
    night: 'Проверяете игрока. Важно: дон выглядит как мирный житель.',
    day: 'Донесите информацию до города, не выдав себя слишком рано.',
    win: 'Город побеждает, когда мафии не осталось.',
    tips: ['Раскрывшись, вы погибнете следующей ночью.', 'Чистая проверка тоже ценна.'] },
  prostitute: { goal: 'Вы за город. Мешаете другим совершать ночные ходы.',
    night: 'Выбранный игрок пропускает ход. Заблокируете мафию — убийства не будет.',
    day: 'Обсуждаете и голосуете как обычный житель.',
    win: 'Город побеждает, когда мафии не осталось.',
    tips: ['Блокировка применяется раньше всех действий.', 'Осторожно с доктором и комиссаром.'] },
  maniac: { goal: 'Вы мирный житель с тёмной тайной: по ночам вы убиваете. '
      + 'Но победить можете только вместе с городом.',
    night: 'Убиваете независимо от мафии. За ночь может погибнуть двое.',
    day: 'Обсуждаете и голосуете как обычный житель.',
    win: 'Город побеждает, когда не осталось мафии. Вы побеждаете вместе с ним.',
    tips: ['Убивая горожан, вы ослабляете свою же сторону — бейте с умом.',
           'Идеальная цель — тот, кого подозреваете в мафии.'] },
  civilian: { goal: 'Вы мирный житель. Ночных способностей нет — только голос и логика.',
    night: 'Спите. Экран останется пустым до рассвета — это нормально.',
    day: 'Ваше главное оружие. Слушайте, спорьте, ищите противоречия.',
    win: 'Город побеждает, когда мафии не осталось.',
    tips: ['Следите, кто кого защищает.', 'Не молчите: пассивных выводят первыми.'] },
};

function openSheet() {
  const dis = S.disguised;
  const g = GUIDE[dis ? 'civilian' : (S.role || 'civilian')] || GUIDE.civilian;
  const img = dis ? '/cards/civilian.jpg' : `/cards/${S.role || 'civilian'}.jpg`;
  const nm = dis ? 'Мирный житель' : (S.roleName || '');
  const em = dis ? '👤' : (S.roleEmoji || '');

  $('sheet-body').innerHTML = `
    <div class="rolecard" style="max-height:36vh;margin-bottom:12px">
      <img src="${img}" alt=""><div class="rc-shade"></div>
      <div class="rc-text"><div class="rc-name">${em} ${esc(nm)}</div></div>
      ${dis ? '<div class="rc-badge">🛡️ Маскировка — показан мирный</div>' : ''}
    </div>
    <div class="blk goal"><h4>ВАША ЗАДАЧА</h4><p>${esc(g.goal)}</p></div>
    <div class="blk night"><h4>НОЧЬЮ</h4><p>${esc(g.night)}</p></div>
    <div class="blk day"><h4>ДНЁМ</h4><p>${esc(g.day)}</p></div>
    <div class="blk win"><h4>КОГДА ВЫ ПОБЕЖДАЕТЕ</h4><p>${esc(g.win)}</p></div>
    ${g.tips ? `<div class="blk"><h4>СОВЕТЫ</h4><ul>${
      g.tips.map(t => `<li>${esc(t)}</li>`).join('')}</ul></div>` : ''}
    ${(!dis && S.mates.length) ? `<div class="blk team"><h4>ВАША КОМАНДА</h4><p>${
      S.mates.map(t => esc(t.isDon ? t.name + ' 🎩 (дон)' : t.name)).join('<br>')}</p></div>` : ''}`;
  $('sheet').classList.remove('hidden');
}

function updateMuteBtn() {
  const b = $('btn-mute');
  if (b) b.textContent = Sound.muted ? '🔇' : '🔊';
}

// ------------------------------------------------------------------ события
$('btn-join').onclick = () => {
  Sound.unlock();
  const code = $('in-code').value.trim();
  const name = $('in-name').value.trim();
  if (!/^\d{6}$/.test(code)) return showJoinError('Код должен состоять из 6 цифр');
  if (name.length < 2) return showJoinError('Введите имя (хотя бы 2 буквы)');
  S.code = code; S.name = name;
  S.attempt = 0;
  $('join-error').classList.add('hidden');
  $('join-status').classList.remove('hidden');
  $('join-status').textContent = 'Подключаемся…';
  $('btn-join').disabled = true;
  connect();
  setTimeout(() => { $('btn-join').disabled = false; }, 3000);
};

// Enter в поле имени = нажатие кнопки: на телефоне так быстрее.
$('in-name').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') $('btn-join').click();
});

function showJoinError(t) {
  $('join-error').textContent = t;
  $('join-error').classList.remove('hidden');
  $('join-status').classList.add('hidden');
  $('btn-join').disabled = false;
}

$('btn-reveal').onclick = () => {
  S.awaitingReveal = false; S.revealed = true;
  Sound.unlock();
  Sound.play('reveal_card.ogg', 0.7);
  send('role_ack', { playerId: S.playerId });
  show('scr-game');
  render();
};

$('role-card').onclick = () => {
  S.revealed = !S.revealed;
  Sound.play(S.revealed ? 'reveal_card.ogg' : 'hide_card.ogg', 0.6);
  buzz(15);
  renderCard();
};

$('btn-disguise').onclick = () => {
  S.disguised = !S.disguised;
  Sound.play('tap.ogg', 0.4);
  renderCard();
};

function submitChoice(targetId) {
  const type = S.phase === 'voting' ? 'vote' : 'night_action';
  // Запоминаем до отправки: если сокет оборвётся, повторим после возврата.
  S.pendingAction = { type, targetId, phase: S.phase, round: S.round };
  const ok = send(type, { playerId: S.playerId, targetId });
  S.sent = true; S.canAct = false;
  buzz(30);
  if (!ok) banner('Нет связи — выбор отправится, как только она вернётся', 'warn');
  render();
}

$('btn-send').onclick = () => { if (S.selected) submitChoice(S.selected); };
$('btn-skip').onclick = () => submitChoice(null);

$('btn-myrole').onclick = openSheet;
// Кнопка на компактной полосе открывает ту же шторку с крупной картой.
$('rs-expand').onclick = openSheet;
$('sheet-close').onclick = () => $('sheet').classList.add('hidden');
$('sheet').onclick = (e) => { if (e.target.id === 'sheet') $('sheet').classList.add('hidden'); };
$('btn-again').onclick = () => location.reload();
$('btn-fatal-again').onclick = () => location.reload();

const muteBtn = $('btn-mute');
if (muteBtn) muteBtn.onclick = () => { Sound.unlock(); Sound.toggleMute(); };

// Строку состояния можно нажать, чтобы переподключиться немедленно.
$('conn').onclick = () => {
  if (S.connected) return;
  S.attempt = 0;
  clearTimeout(retryTimer);
  connect();
};

// Разблокировка звука: браузеры не дают играть без жеста пользователя.
// Не once — на iOS контекст засыпает повторно, будим при каждом касании.
document.body.addEventListener('touchstart', () => Sound.unlock(), { passive: true });
document.body.addEventListener('click', () => Sound.unlock());

// Вернулись во вкладку — сверяем состояние с ведущим.
// Это самый частый сценарий: игрок свернул браузер, экран погас,
// система заморозила вкладку и, возможно, тихо убила сокет.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  Sound.unlock();
  Screen.acquire();
  if (S.ws && S.ws.readyState === 1) {
    send('resync_request', { playerId: S.playerId, name: S.name });
    // Ждём ответа: если хост молчит 4 секунды, значит сокет мёртв.
    const mark = S.lastPongAt;
    setTimeout(() => {
      if (S.lastPongAt === mark && S.ws) { try { S.ws.close(); } catch (e) {} }
    }, 4000);
  } else if (S.joined) {
    S.attempt = 0;
    connect();
  }
  renderTimer();
});

// Событие возврата из bfcache (Safari кладёт туда всю страницу целиком).
window.addEventListener('pageshow', (e) => {
  if (e.persisted && S.joined) { S.attempt = 0; connect(); }
});

// Сеть вернулась — не ждём следующего шага лесенки.
window.addEventListener('online', () => {
  if (S.joined && (!S.ws || S.ws.readyState !== 1)) { S.attempt = 0; connect(); }
});

// ------------------------------------------------------------------- запуск
(function init() {
  // Код игры: сначала из ссылки (?g=482913), затем из подстановки сервера.
  const boot = window.__MAFIA__ || {};
  const fromUrl = new URLSearchParams(location.search).get('g');
  if (fromUrl && /^\d{6}$/.test(fromUrl)) boot.code = fromUrl;
  if (boot.code) {
    $('in-code').value = boot.code;
    S.code = boot.code;
    // Код уже известен — прячем поле, чтобы не пугать лишним вводом.
    $('code-row').classList.add('filled');
    setTimeout(() => $('in-name').focus(), 300);
  }

  try {
    Sound.muted = localStorage.getItem('mafia_muted') === '1';
    updateMuteBtn();
  } catch (e) {}

  // Возврат в свою партию после закрытия вкладки.
  try {
    const saved = JSON.parse(localStorage.getItem('mafia_session') || 'null');
    if (saved && Date.now() - saved.at < 6 * 3600 * 1000) {
      $('in-name').value = saved.name;
      if (!boot.code || saved.code === boot.code) {
        $('join-status').classList.remove('hidden');
        $('join-status').textContent = `Возвращаемся в игру как «${saved.name}»…`;
        S.code = saved.code; S.name = saved.name;
        setTimeout(connect, 400);
      }
    }
  } catch (e) {}

  show('scr-join');
  render();

  // Service worker: страница переживёт короткий обрыв Wi-Fi, а звуки
  // и карты не будут качаться заново при каждой перезагрузке.
  // Регистрируем после отрисовки — он не должен задерживать вход в игру.
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js').catch(() => {});
    });
  }
})();
