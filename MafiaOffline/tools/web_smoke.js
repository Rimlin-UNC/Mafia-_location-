#!/usr/bin/env node
/* Дымовой тест веб-клиента игрока (assets/web) без браузера и без хоста.
 *
 * Зачем: `node --check` ловит только синтаксис. Обработчик сообщений в
 * app.js обёрнут в try/catch (один битый пакет не должен ронять игру),
 * поэтому опечатка в имени элемента или поля молча «съедается» — и игрок
 * видит пустой экран. Этот тест загружает настоящие index.html и app.js
 * в jsdom, подменяет WebSocket и проходит партию пакет за пакетом,
 * проверяя, что именно оказалось на экране.
 *
 * Запуск:
 *   npm install --no-save jsdom     (один раз, в любой папке выше tools/)
 *   node tools/web_smoke.js
 * Код возврата 1 — есть провал.
 */
'use strict';

const fs = require('fs');
const path = require('path');

let JSDOM;
try {
  ({ JSDOM } = require('jsdom'));
} catch (e) {
  console.error('Нужен пакет jsdom: npm install --no-save jsdom');
  process.exit(2);
}

const WEB = path.join(__dirname, '..', 'assets', 'web');
const html = fs.readFileSync(path.join(WEB, 'index.html'), 'utf8');
const appJs = fs.readFileSync(path.join(WEB, 'app.js'), 'utf8');

const results = [];
function check(name, cond) {
  results.push([name, !!cond]);
  console.log(`  ${cond ? 'OK  ' : 'FAIL'}  ${name}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Новая страница с подменённым сокетом. */
function openPage() {
  // Скрипт вырезаем из разметки и выполняем сами: jsdom не умеет
  // загружать /app.js с несуществующего сервера.
  const dom = new JSDOM(html.replace('<script src="/app.js"></script>', ''), {
    url: 'http://192.168.43.1:8088/?g=482913',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
  });
  const w = dom.window;
  const page = { dom, w, sent: [], buzz: [], errors: [], sock: null };

  class FakeSocket {
    constructor(url) {
      this.url = url; this.readyState = 0; page.sock = this;
      setTimeout(() => { this.readyState = 1; if (this.onopen) this.onopen(); }, 0);
    }
    send(raw) { page.sent.push(JSON.parse(raw)); }
    close() { this.readyState = 3; if (this.onclose) this.onclose(); }
  }
  w.WebSocket = FakeSocket;
  w.navigator.vibrate = (p) => { page.buzz.push(p); return true; };
  w.addEventListener('error', (e) => page.errors.push(String(e.message || e)));

  // Обработчик пакетов глотает исключения — перехватываем их здесь,
  // иначе тест не отличит «пакет обработан» от «пакет уронил рендер».
  const patched = appJs.replace(
    'try { onMessage(JSON.parse(e.data)); } catch (err) {}',
    'try { onMessage(JSON.parse(e.data)); } catch (err) { window.__ERR__.push(String(err && err.stack || err)); }');
  if (patched === appJs) throw new Error('не найден обработчик onmessage — обновите тест');
  w.__ERR__ = page.errors;
  w.eval(patched);

  page.$ = (id) => w.document.getElementById(id);
  page.text = (id) => (page.$(id).textContent || '').replace(/\s+/g, ' ').trim();
  page.visible = (id) => {
    for (let el = page.$(id); el && el.classList; el = el.parentElement) {
      if (el.classList.contains('hidden')) return false;
      if (el.classList.contains('screen') && !el.classList.contains('active')) return false;
    }
    return true;
  };
  page.push = (type, data) => {
    page.sock.onmessage({ data: JSON.stringify({ v: 1, ts: Date.now(), type, ...(data || {}) }) });
  };
  page.click = (id) => page.$(id).click();
  page.close = () => { try { w.close(); } catch (e) {} };
  return page;
}

const PLAYERS = [
  { id: 'p0', name: 'Аня', color: '#FF5733', isAlive: true, isConnected: true },
  { id: 'p1', name: 'Борис', color: '#3357FF', isAlive: true, isConnected: true },
  { id: 'p2', name: 'Вика', color: '#33FF57', isAlive: true, isConnected: true },
  { id: 'p3', name: 'Глеб', color: '#FFD733', isAlive: true, isConnected: true },
];
const RULES = { openCards: false, introNight: true, lastWord: true, lastWordSeconds: 30, privateCheck: true };

async function join(page, name) {
  page.$('in-name').value = name;
  page.click('btn-join');
  await sleep(20);
  page.push('register_ok', { id: 'p0', color: '#FF5733', gameName: 'Тестовая партия' });
  page.push('lobby', { gameName: 'Тестовая партия', planned: 4, players: PLAYERS, rules: RULES });
}

async function dealRole(page, role, roleName) {
  page.push('role_assign', { role, roleName, roleEmoji: '🎭', roleDescription: '', teammates: [] });
  page.click('btn-reveal');
  await sleep(5);
}

(async () => {
  // ------------------------------------------------------------ вход и лобби
  console.log('Вход и лобби');
  let p = openPage();
  check('код партии подставлен из ссылки', p.$('in-code').value === '482913');
  await join(p, 'Аня');
  check('регистрация отправлена хосту', p.sent.some((m) => m.type === 'register' && m.name === 'Аня'));
  check('показано лобби', p.visible('scr-lobby'));
  check('игроки в списке лобби', p.text('lobby-list').includes('Борис'));
  check('в лобби счётчика живых ещё нет', !p.visible('table-line'));

  console.log('\nПравила (FR-9.4, UX-7)');
  p.click('btn-rules-lobby');
  check('шторка правил открывается из лобби', p.visible('sheet'));
  const rules = p.text('sheet-body');
  check('показаны правила этого стола', rules.includes('ПРАВИЛА ЭТОГО СТОЛА'));
  check('ночь знакомства названа', rules.includes('знакомство'));
  check('последнее слово названо с длительностью', rules.includes('30 секунд'));
  check('названа ничья', rules.includes('Ничья'));
  check('условие победы мафии — равенство, а не «остался один»',
    rules.includes('столько же') && !rules.includes('не больше одного'));
  p.click('sheet-close');
  check('шторка закрывается', !p.visible('sheet'));

  // ------------------------------------------------------- ночь знакомства
  console.log('\nНочь знакомства (FR-9.1) и счётчик живых (UX-6)');
  await dealRole(p, 'commissioner', 'Комиссар');
  check('после подтверждения роли — экран игры', p.visible('scr-game'));
  check('подтверждение роли ушло хосту', p.sent.some((m) => m.type === 'role_ack'));
  p.buzz.length = 0;
  p.push('phase', {
    phase: 'night', round: 1, time: 45, paused: false, isAlive: true, canAct: true,
    prompt: 'Кого проверить?', alive: 4, total: 4, intro: true, lastWord: null,
    targets: PLAYERS.slice(1).map(({ id, name, color }) => ({ id, name, color })),
  });
  check('заголовок фазы — «Ночь знакомства»', p.text('phase-name').startsWith('Ночь знакомства'));
  check('счётчик «Живых: 4 из 4»', p.visible('table-line') && p.text('table-count') === 'Живых: 4 из 4');
  check('вибро на смене фазы', p.buzz.length === 1);
  check('комиссару показаны цели', p.visible('action-area') && p.$('targets').children.length === 3);
  p.$('targets').children[0].click();
  p.click('btn-send');
  check('ход ушёл хосту', p.sent.some((m) => m.type === 'night_action' && m.targetId === 'p1'));
  p.push('ack', { accepted: true });
  check('комиссару сказано, где искать ответ', p.text('idle-sub').includes('Моя роль'));

  // --------------------------------------------------- результат проверки
  console.log('\nРезультат проверки — только в «Моя роль» (FR-9.3)');
  p.push('night_result', { round: 1, killed: [], killedNames: [], text: 'Это была ночь знакомства: все живы.' });
  p.push('check_result', { round: 1, name: 'Борис', isMafia: true });
  p.push('phase', {
    phase: 'day', round: 1, time: 180, paused: false, isAlive: true, canAct: false,
    prompt: 'Обсуждайте', alive: 4, total: 4, intro: false, lastWord: null, targets: [],
  });
  const gameScreen = p.text('game-body');
  check('на игровом экране результата проверки НЕТ',
    !gameScreen.includes('МАФИЯ') && !/Борис\s*—/.test(gameScreen));
  check('баннер — только общий текст ночи', p.text('banner').includes('знакомства'));
  check('днём заголовок — обычный «День 1»', p.text('phase-name') === 'День 1');
  p.click('btn-myrole');
  let sheet = p.text('sheet-body');
  check('в «Моя роль» есть блок проверок', sheet.includes('ВАШИ ПРОВЕРКИ'));
  check('проверка показана с результатом', sheet.includes('Ночь 1: Борис') && sheet.includes('МАФИЯ'));
  check('памятка: город должен убрать и маньяка', sheet.includes('ни маньяка'));
  p.click('sheet-close');

  // Маскировка: шторка изображает мирного — проверок в ней быть не должно.
  p.push('phase', {
    phase: 'night', round: 2, time: 60, paused: false, isAlive: true, canAct: false,
    prompt: 'Спите', alive: 4, total: 4, intro: false, lastWord: null, targets: [],
  });
  p.click('btn-disguise');
  p.click('btn-myrole');
  sheet = p.text('sheet-body');
  check('при маскировке проверки скрыты', !sheet.includes('ВАШИ ПРОВЕРКИ') && !sheet.includes('Борис'));
  p.click('sheet-close');
  p.click('btn-disguise');

  // sync после перезагрузки страницы приносит проверки заново.
  p.push('sync', {
    phase: 'day', round: 2, time: 100, paused: false, isAlive: true, canAct: false,
    alreadyActed: false, role: 'commissioner', roleName: 'Комиссар', roleEmoji: '🕵',
    roleAck: true, gameName: 'Тестовая партия', alive: 3, total: 4, intro: false,
    lastWord: null, targets: [], prompt: 'Обсуждайте',
    checks: [{ round: 1, name: 'Борис', isMafia: true }, { round: 2, name: 'Вика', isMafia: false }],
  });
  p.click('btn-myrole');
  sheet = p.text('sheet-body');
  check('после sync видны обе проверки', sheet.includes('Ночь 2: Вика') && sheet.includes('не мафия'));
  p.click('sheet-close');
  check('счётчик обновился из sync', p.text('table-count') === 'Живых: 3 из 4');

  // ----------------------------------------------------------- список стола
  console.log('\nСписок стола (UX-6)');
  p.push('lobby', {
    gameName: 'Тестовая партия', planned: 4, rules: RULES,
    players: PLAYERS.map((x) => (x.id === 'p3' ? { ...x, isAlive: false } : x)),
  });
  p.click('table-line');
  check('шторка стола открывается', p.visible('sheet') && p.text('sheet-body').includes('живых 3 из 4'));
  const deadRows = p.$('sheet-body').querySelectorAll('.p.dead');
  check('выбывший помечен', deadRows.length === 1 && deadRows[0].textContent.includes('Глеб'));
  check('ролей в списке стола нет', !/Комиссар|Мафия|Доктор/.test(p.text('sheet-body')));
  p.click('sheet-close');

  // -------------------------------------------------------- последнее слово
  console.log('\nПоследнее слово (FR-9.2)');
  p.buzz.length = 0;
  p.push('vote_result', { eliminated: 'p2', eliminatedName: 'Вика', tie: false });
  p.push('phase', {
    phase: 'day', round: 2, time: 30, paused: false, isAlive: true, canAct: false,
    prompt: 'Последнее слово: Вика', alive: 2, total: 4, intro: false,
    lastWord: { id: 'p2', name: 'Вика' }, targets: [],
  });
  check('заголовок — «Последнее слово»', p.text('phase-name') === 'Последнее слово');
  check('названо, кто говорит', p.text('idle-sub').includes('Вика'));
  check('голосовать и ходить нельзя', !p.visible('action-area') && !p.visible('game-foot'));
  check('вибро на начале последнего слова', p.buzz.length === 1);
  check('таймер показывает 30 секунд', p.text('phase-timer') === '00:30');
  p.push('phase', {
    phase: 'night', round: 3, time: 60, paused: false, isAlive: true, canAct: false,
    prompt: 'Спите', alive: 2, total: 4, intro: false, lastWord: null, targets: [],
  });
  check('после слова — обычная «Ночь 3»', p.text('phase-name') === 'Ночь 3');
  check('обычная ночь не названа знакомством', !p.text('idle-sub').includes('знакомств'));

  // Выбывший говорит сам.
  p.push('eliminated', { reason: 'vote', round: 3 });
  p.push('phase', {
    phase: 'day', round: 3, time: 30, paused: false, isAlive: false, canAct: false,
    prompt: 'Ваше последнее слово', alive: 1, total: 4, intro: false,
    lastWord: { id: 'p0', name: 'Аня' }, targets: [],
  });
  check('выбывшему: «Ваше последнее слово»', p.visible('dead-area') && p.text('dead-title') === 'Ваше последнее слово');
  p.push('phase', {
    phase: 'night', round: 4, time: 60, paused: false, isAlive: false, canAct: false,
    prompt: 'Вы выбыли из игры', alive: 1, total: 4, intro: false, lastWord: null, targets: [],
  });
  check('после слова — обычный экран выбывшего', p.text('dead-title') === 'Вы выбыли из игры');

  // ------------------------------------------------------------------ финал
  p.push('game_over', {
    winner: 'nobody', title: 'Ничья — в городе не осталось никого',
    reveal: [{ name: 'Аня', role: 'Комиссар', emoji: '🕵', isAlive: false }],
  });
  check('итоговый экран показан', p.visible('scr-over') && p.text('over-title').includes('Ничья'));
  check('ошибок JavaScript нет (партия комиссара)', p.errors.length === 0);
  if (p.errors.length) console.log(p.errors.slice(0, 3).join('\n'));
  p.close();

  // -------------------------------------------- мафия в ночь знакомства
  console.log('\nМафия в ночь знакомства: экран как у мирного');
  const screens = {};
  for (const [role, roleName] of [['mafia', 'Мафия'], ['civilian', 'Мирный житель']]) {
    const q = openPage();
    await join(q, 'Аня');
    await dealRole(q, role, roleName);
    q.push('phase', {
      phase: 'night', round: 1, time: 45, paused: false, isAlive: true, canAct: false,
      prompt: 'Спите', alive: 4, total: 4, intro: true, lastWord: null, targets: [],
    });
    screens[role] = [q.text('phase-name'), q.text('idle-text'), q.text('idle-sub'),
      q.text('table-count'), q.visible('action-area')].join(' | ');
    if (role === 'mafia') {
      check('у мафии нет списка целей', !q.visible('action-area'));
      check('сказано, что никто не погибает', q.text('idle-sub').includes('никто не погибает'));
    }
    check(`ошибок JavaScript нет (${roleName})`, q.errors.length === 0);
    q.close();
  }
  check('текст на экране мафии и мирного совпадает', screens.mafia === screens.civilian);

  // ----------------------------------------------- ведущий старой версии
  console.log('\nСовместимость: ведущий на 1.1.x (без новых полей)');
  const o = openPage();
  await join(o, 'Аня');
  o.push('lobby', { gameName: 'Старая партия', planned: 4, players: PLAYERS });
  await dealRole(o, 'civilian', 'Мирный житель');
  o.push('phase', {
    phase: 'night', round: 1, time: 45, paused: false, isAlive: true, canAct: false,
    prompt: 'Спите', targets: [],
  });
  check('заголовок — обычная «Ночь 1»', o.text('phase-name') === 'Ночь 1');
  o.push('phase', {
    phase: 'day', round: 1, time: 120, paused: false, isAlive: true, canAct: false,
    prompt: 'Обсуждайте', targets: [],
  });
  check('день отрисован', o.text('phase-name') === 'День 1' && o.text('idle-text') === 'Обсуждайте');
  check('ошибок JavaScript нет (старый ведущий)', o.errors.length === 0);
  if (o.errors.length) console.log(o.errors.slice(0, 3).join('\n'));
  o.close();

  // ------------------------------------------------------------------ итог
  const bad = results.filter(([, ok]) => !ok);
  console.log('\n' + '='.repeat(56));
  console.log(`${results.length - bad.length} passed, ${bad.length} failed`);
  for (const [name] of bad) console.log('  ✗', name);
  process.exit(bad.length ? 1 : 0);
})().catch((e) => {
  console.error('Тест упал:', e && e.stack || e);
  process.exit(1);
});
