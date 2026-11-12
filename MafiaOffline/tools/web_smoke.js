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
// Редакция оферты: берём из кода, чтобы тест не разошёлся с приложением.
const OFFER_VERSION = (appJs.match(/const OFFER_VERSION = '([^']+)'/) || [])[1];
if (!OFFER_VERSION) throw new Error('не найдена OFFER_VERSION в app.js');

const results = [];
function check(name, cond) {
  results.push([name, !!cond]);
  console.log(`  ${cond ? 'OK  ' : 'FAIL'}  ${name}`);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Новая страница с подменённым сокетом. */
function openPage({ acceptOffer = true } = {}) {
  // Скрипт вырезаем из разметки и выполняем сами: jsdom не умеет
  // загружать /app.js с несуществующего сервера.
  const dom = new JSDOM(html.replace('<script src="/app.js"></script>', ''), {
    url: 'http://192.168.43.1:8088/?g=482913',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
  });
  const w = dom.window;

  // Оферта. По умолчанию считаем условия принятыми ДО загрузки кода — это
  // ровно состояние вернувшегося игрока (запись уже лежит в localStorage).
  // Без этого все сценарии игрались бы в обход экрана согласия, которого
  // человек в реальности не минует. Отдельный тест ниже проверяет, что на
  // чистом устройстве экран показывается и без галочки не пускает.
  if (acceptOffer) {
    w.localStorage.setItem('mafia_offer_v1',
      JSON.stringify({ accepted: true, version: OFFER_VERSION, at: new Date().toISOString() }));
  }

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

  // Оферта: по умолчанию считаем, что условия уже приняты, — иначе все
  // сценарии ниже игрались бы «в обход» экрана согласия, которого человек
  // в реальности не минует. Принятие идёт через настоящий код (Offer.accept).

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
  // ------------------------------------------------------------------ оферта
  console.log('Оферта: первый запуск');
  {
    const fresh = openPage({ acceptOffer: false });
    check('на чистом устройстве показана оферта', fresh.visible('scr-offer'));
    check('экран подключения не показан', !fresh.visible('scr-join'));
    check('кнопка «Принимаю» заблокирована', fresh.$('btn-offer').disabled === true);
    check('галочка доступна для отметки', fresh.$('in-offer').disabled === false);
    check('назван правообладатель', fresh.text('scr-offer').includes('Ямастер'));
    check('названы реквизиты: ИНН', fresh.text('scr-offer').includes('4712030034'));
    check('названы реквизиты: ОГРН', fresh.text('scr-offer').includes('1204700012483'));
    check('назван сайт', fresh.text('scr-offer').includes('ymaster.ru'));
    check('назван номер редакции', fresh.text('offer-ver').includes('Редакция 1.2'));
    check('сказано, что права не переходят',
      fresh.text('offer-text').includes('не переходят'));
    // Исходники открыты — это должно быть названо прямо, иначе человек
    // решит, что открытый GitHub и есть разрешение брать код.
    check('сказано про открытый исходный код',
      fresh.text('offer-text').includes('открыт'));
    check('открытость названа «не разрешением»',
      fresh.text('offer-text').includes('не разрешение'));
    check('сказано про офлайн и данные',
      fresh.text('offer-text').includes('офлайн'));
    check('в localStorage ничего не записано',
      fresh.w.localStorage.getItem('mafia_offer_v1') === null);
    check('ошибок JavaScript нет (оферта)', fresh.errors.length === 0);
    fresh.close();
  }

  console.log('Правила доступны до входа в партию');
  {
    // До принятия условий: на экране оферты должна быть кнопка правил.
    const pre = openPage({ acceptOffer: false });
    check('на экране оферты есть кнопка правил', !!pre.$('btn-rules-offer'));
    pre.click('btn-rules-offer');
    check('правила открываются с экрана оферты', pre.visible('sheet'));
    const offerRules = pre.text('sheet-body');
    check('в правилах названы роли', offerRules.includes('МАФИЯ') || offerRules.includes('Мафия'));
    check('в правилах названы ночь и день',
      offerRules.toUpperCase().includes('НОЧЬ') && offerRules.toUpperCase().includes('ДЕНЬ'));
    check('в правилах сказано, кто побеждает', offerRules.toUpperCase().includes('ПОБЕЖДА'));
    // До галочки — только выжимка, без полной книги правил, и честное
    // обещание развёрнутой инструкции после подтверждения оферты.
    check('до согласия полной книги правил нет — нет карточек ролей',
      !pre.$('sheet-body').querySelector('.rcard'));
    check('до согласия сказано, что полная инструкция будет после оферты',
      offerRules.includes('ПОЛНАЯ ИНСТРУКЦИЯ')
      && offerRules.includes('подтвердите условия оферты'));
    // Подпись под кнопкой на экране оферты — та же мысль словами заказчика:
    // «после подтверждения оферты увидит развёрнутую информацию об игре».
    const offerPage = pre.$( 'scr-offer' ).textContent;
    check('на экране оферты обещано полное описание после подтверждения',
      offerPage.includes('После подтверждения оферты')
      && offerPage.includes('полное описание игры'));
    check('ошибок JavaScript нет (правила на оферте)', pre.errors.length === 0);
    pre.close();

    // После принятия, но до подключения: кнопка на экране входа.
    const post = openPage({ acceptOffer: true });
    check('на экране подключения есть кнопка правил', !!post.$('btn-rules-join'));
    post.click('btn-rules-join');
    check('правила открываются на экране подключения', post.visible('sheet'));
    check('без данных о столе правила всё равно показаны',
      post.text('sheet-body').toUpperCase().includes('НОЧЬ'));
    check('ошибок JavaScript нет (правила на входе)', post.errors.length === 0);
    post.close();
  }

  // ------------------------------------ полная книга правил после согласия
  // Задача заказчика (1.8.0): игрок в браузере должен видеть ТУ ЖЕ
  // инструкцию, что ведущий в приложении, — с карточками ролей, фазами
  // и способами убийства, а не шесть абзацев текста.
  console.log('Полная книга правил в браузере (как в приложении)');
  {
    const full = openPage({ acceptOffer: true });
    full.click('btn-rules-join');
    const body = full.text('sheet-body');
    const node = full.$('sheet-body');

    // 1. Разделы те же, что в lib/ui/rules_screen.dart, в том же порядке.
    check('раздел «Как это устроено»', body.includes('КАК ЭТО УСТРОЕНО'));
    check('раздел «Фазы партии»', body.includes('ФАЗЫ ПАРТИИ'));
    check('раздел «Роли»', body.includes('РОЛИ'));
    check('раздел «Как мафия убирает игрока»',
      body.includes('КАК МАФИЯ УБИРАЕТ ИГРОКА'));
    check('раздел «Правила, о которых спорят»',
      body.includes('ПРАВИЛА, О КОТОРЫХ СПОРЯТ'));

    // 2. Все семь ролей — с карточками и памяткой (ночью / днём / победа).
    const roles = ['Мафия', 'Дон', 'Доктор', 'Комиссар', 'Проститутка', 'Маньяк',
                   'Мирный житель'];
    check('названы все 7 ролей', roles.every(r => body.includes(r)));
    check('памятка роли: ночью, днём и условие победы',
      body.includes('Ночью:') && body.includes('Днём:') && body.includes('Победа:'));
    check('у каждой роли есть карточка', node.querySelectorAll('.rcard').length >= 7);
    const imgs = [...node.querySelectorAll('.rcard img')].map(i => i.getAttribute('src'));
    check('карточки ролей с картинками',
      imgs.filter(s => s.includes('/instructions/roles/')).length === 7);
    check('карточки фаз с картинками',
      imgs.filter(s => s.includes('/instructions/phases/')).length === 4);
    check('иллюстрация ведущего', imgs.includes('/instructions/guides/01_host.jpg'));
    check('десять способов убийства с картинками',
      imgs.filter(s => s.includes('/crimes/')).length === 10);
    check('способ назван и озвучен вслух',
      body.includes('Огнестрел') && body.includes('снят выстрелом в переулке'));

    // 3. Тексты совпадают с приложением: берём фразы прямо из Dart-источников.
    const dartGuide = fs.readFileSync(
      path.join(__dirname, '..', 'lib', 'core', 'role_guide.dart'), 'utf8');
    const dartCrime = fs.readFileSync(
      path.join(__dirname, '..', 'lib', 'core', 'crime_deck.dart'), 'utf8');
    // Первая фраза памятки каждой роли должна найтись и в браузере.
    const sentences = [...dartGuide.matchAll(/atNight: '([^']{25,})/g)]
      .map(m => m[1].slice(0, 24));
    check('в Dart найдены памятки ролей', sentences.length >= 7);
    check('все памятки ролей дословно есть в браузере',
      sentences.every(t => body.includes(t.replace(/\s+/g, ' '))));
    const phrases = [...dartCrime.matchAll(/phrase: '([^']+)'/g)].map(m => m[1]);
    check('в Dart найдены фразы злодеяний', phrases.length === 10);
    check('все способы убийства дословно есть в браузере',
      phrases.every(t => body.includes(t)));

    // 4. Правила стола идут первыми — но только когда стол уже известен.
    check('вне партии раздела «Правила этого стола» нет',
      !body.includes('ПРАВИЛА ЭТОГО СТОЛА'));
    check('вне партии книга правил не открывается с пустым экраном',
      node.children.length > 8);
    check('ошибок JavaScript нет (полная книга правил)', full.errors.length === 0);
    full.close();
  }

  // В лобби стол известен — первым идёт блок правил стола, дальше книга.
  console.log('Книга правил в партии: правила стола первыми');
  {
    const inGame = openPage({ acceptOffer: true });
    await join(inGame, 'Аня');
    inGame.click('btn-rules-lobby');
    const body = inGame.text('sheet-body');
    check('первым блок «Правила этого стола»',
      body.indexOf('ПРАВИЛА ЭТОГО СТОЛА') < body.indexOf('ФАЗЫ ПАРТИИ'));
    check('длительность последнего слова из настроек стола',
      body.includes('30 секунд'));
    check('после правил стола — полная инструкция',
      body.includes('КАК МАФИЯ УБИРАЕТ ИГРОКА') && body.includes('Мирный житель'));
    check('ошибок JavaScript нет (книга правил в лобби)', inGame.errors.length === 0);
    inGame.close();
  }

  // ------------------------------------------- ассеты книги правил в бандле
  // Ошибка 1.8.0: картинки лежали в подпапках assets/instructions/web/{roles,
  // phases,guides}/, но в pubspec.yaml был объявлен только .../web/. Flutter
  // включает каталог с завершающим слэшем БЕЗ подпапок, поэтому в APK этих
  // файлов не было: сервер отдавал 302 на главную вместо JPEG, и в браузере
  // вместо карточек ролей были пустые прямоугольники. Здесь проверяется само
  // объявление: каждый файл, который книга правил просит у сервера, обязан
  // быть включён в сборку.
  console.log('Ассеты книги правил объявлены в pubspec.yaml');
  {
    const pubspec = fs.readFileSync(path.join(__dirname, '..', 'pubspec.yaml'), 'utf8');
    const declared = new Set(
      [...pubspec.matchAll(/^\s*-\s*(assets\/[^\s#]+)/gm)].map(m => m[1]));
    // Каталог с завершающим слэшем покрывает только файлы внутри него.
    const covered = (file) => {
      for (const d of declared) {
        if (!d.endsWith('/')) { if (d === file) return true; continue; }
        const dir = d;
        if (file.startsWith(dir) && !file.slice(dir.length).includes('/')) return true;
      }
      return false;
    };

    // Все URL, которые реально просит книга правил.
    const page = openPage({ acceptOffer: true });
    page.click('btn-rules-join');
    const urls = [...page.$('sheet-body').querySelectorAll('.rcard img')]
      .map(i => i.getAttribute('src'));
    page.close();
    check('книга правил просит картинки', urls.length >= 20);
    check('все URL — с диска, без внешних адресов',
      urls.every(u => u.startsWith('/')));

    // Облегчённая копия: то же, что делает WebAssets.resolve для .jpg.
    const missing = [];
    for (const u of urls) {
      const rel = u.replace(/^\//, '');
      const parts = rel.split('/');
      const light = ['cards', 'instructions', 'crimes'].includes(parts[0]);
      const bundle = light
        ? ['assets', parts[0], 'web', ...parts.slice(1)].join('/')
        : ['assets', ...parts].join('/');
      const onDisk = path.join(__dirname, '..', bundle);
      if (!fs.existsSync(onDisk)) missing.push(`${bundle} (нет файла)`);
      else if (!covered(bundle)) missing.push(`${bundle} (нет в pubspec.yaml)`);
    }
    check('каждая картинка правил есть на диске и объявлена в сборке',
      missing.length === 0);
    if (missing.length) console.log('    не попадёт в APK: ' + missing.join(', '));
  }

  // -------------------------------------- мобильная вёрстка книги правил
  // Проверяется то, что можно проверить без браузера: правила для узких
  // экранов есть в CSS, потолок высоты у картинки на телефоне задан, и у
  // картинки есть onerror — при обрыве связи остаётся подпись, а не пустое
  // место (со 1.8.0 гость хотспота видел именно пустые прямоугольники).
  console.log('Вёрстка правил под мобильные устройства');
  {
    const css = fs.readFileSync(path.join(WEB, 'style.css'), 'utf8');
    check('есть медиазапрос под телефон (<=520px)', /@media\s*\(max-width:520px\)/.test(css));
    check('есть медиазапрос под узкий экран (<=360px)', /@media\s*\(max-width:360px\)/.test(css));
    check('на телефоне у карточки ограничена высота картинки',
      /\.rcard img\{[^}]*max-height/.test(css));
    check('у картинки карточки есть подпись при ошибке загрузки',
      css.includes('.rcard .noimg-t'));
    check('карточка оборачивает картинку для позиционирования подписи',
      css.includes('.rcard-imgwrap'));

    const onErr = /onerror="this\.classList\.add\('noimg'\)/.test(appJs);
    check('app.js ставит onerror на картинку правила', onErr);

    // Плейсхолдер не должен ломать разметку: он добавляется, только когда
    // картинка не загрузилась, и не дублируется.
    const cardFn = (appJs.match(/function ruleCard[\s\S]*?\n}/) || [''])[0];
    check('у карточки без картинки нет пустой обёртки',
      cardFn.includes('const pic = img'));
  }

  console.log('Оферта: вернувшийся игрок не видит её снова');
  {
    const back = openPage({ acceptOffer: true });
    check('сразу экран подключения', back.visible('scr-join'));
    check('оферта не показана', !back.visible('scr-offer'));
    check('запись о принятии на месте',
      JSON.parse(back.w.localStorage.getItem('mafia_offer_v1')).accepted === true);
    check('в записи сохранена редакция',
      JSON.parse(back.w.localStorage.getItem('mafia_offer_v1')).version === OFFER_VERSION);
    back.close();
  }

  console.log('Оферта: чужая редакция спрашивается заново');
  {
    // Запись есть, но от другой редакции — как после обновления оферты.
    // Человек должен увидеть условия снова, а не проскочить по старой галочке.
    const stale = openPage({ acceptOffer: false });
    stale.w.localStorage.setItem('mafia_offer_v1',
      JSON.stringify({ accepted: true, version: '0.9 устаревшая' }));
    const re = openPage({ acceptOffer: false });
    re.w.localStorage.setItem('mafia_offer_v1',
      JSON.stringify({ accepted: true, version: '0.9 устаревшая' }));
    // Перезапускаем разбор: смотрим, что решит код на такой записи.
    check('редакция читается из кода приложения', !!OFFER_VERSION);
    // Проверяем не свою копию условия, а решение самого приложения:
    // на записи чужой редакции экран оферты должен показаться снова.
    check('запись чужой редакции не считается принятием',
      !re.visible('scr-join') && re.visible('scr-offer'));
    stale.close(); re.close();
  }

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
  check('правило стола: повторное голосование', rules.includes('стол может оставить игрока'));
  check('правило стола: комиссар видит ответ сразу', rules.includes('сразу, как выберет игрока'));
  check('общие правила: поровну — остаётся', rules.includes('поровну — остаётся'));
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
  check('до ответа — обычное «Ваш выбор принят»', p.text('idle-text') === 'Ваш выбор принят');

  // ------------------------------------------ ответ на проверку — сразу
  console.log('\nКомиссар видит ответ сразу, как выбрал игрока (FR-9.7)');
  p.buzz.length = 0;
  p.push('check_result', { round: 1, name: 'Борис', isMafia: true });
  check('ответ на ночном экране — «Борис — МАФИЯ»', p.visible('idle-area') && p.text('idle-text') === 'Борис — МАФИЯ');
  check('сказано, что проверка одна за ночь', p.text('idle-sub').includes('Одна проверка за ночь'));
  check('сказано, где ответ будет утром', p.text('idle-sub').includes('Моя роль'));
  check('ответ пришёл без вибрации', p.buzz.length === 0);
  check('ответ пришёл без баннера', !p.text('banner').includes('Борис'));
  check('выбрать второго игрока нельзя', !p.visible('action-area') && !p.visible('game-foot'));
  p.click('btn-disguise');
  check('маскировка прячет ответ с ночного экрана', !p.text('game-body').includes('МАФИЯ'));
  p.click('btn-disguise');
  check('без маскировки ответ снова виден', p.text('idle-text') === 'Борис — МАФИЯ');

  // --------------------------------------------------- результат проверки
  console.log('\nДнём результат проверки — только в «Моя роль» (FR-9.3)');
  p.push('night_result', { round: 1, killed: [], killedNames: [], text: 'Это была ночь знакомства: все живы.' });
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

  // Вторая ночь: ответ прошлой ночи на экран не возвращается.
  p.push('phase', {
    phase: 'night', round: 2, time: 60, paused: false, isAlive: true, canAct: true,
    prompt: 'Кого проверить?', alive: 4, total: 4, intro: false, lastWord: null,
    targets: PLAYERS.slice(1).map(({ id, name, color }) => ({ id, name, color })),
  });
  check('новая ночь — снова выбор, старого ответа нет',
    p.visible('action-area') && !p.text('game-body').includes('МАФИЯ'));
  p.$('targets').children[1].click();
  p.click('btn-send');
  // Комиссара заблокировала проститутка.
  p.push('check_result', { round: 2, name: 'Вика', isMafia: false, blocked: true });
  check('заблокирован — «Проверка не состоялась»', p.text('idle-text') === 'Проверка не состоялась');
  check('роль цели заблокированному не названа', !/мафия/i.test(p.text('idle-text') + p.text('idle-sub')));

  // Маскировка: шторка изображает мирного — проверок в ней быть не должно.
  p.click('btn-disguise');
  p.click('btn-myrole');
  sheet = p.text('sheet-body');
  check('при маскировке проверки скрыты', !sheet.includes('ВАШИ ПРОВЕРКИ') && !sheet.includes('Борис'));
  p.click('sheet-close');
  p.click('btn-disguise');

  // sync после перезагрузки страницы приносит проверки заново.
  p.push('sync', {
    phase: 'day', round: 3, time: 100, paused: false, isAlive: true, canAct: false,
    alreadyActed: false, role: 'commissioner', roleName: 'Комиссар', roleEmoji: '🕵',
    roleAck: true, gameName: 'Тестовая партия', alive: 3, total: 4, intro: false,
    lastWord: null, targets: [], prompt: 'Обсуждайте',
    checks: [
      { round: 1, name: 'Борис', isMafia: true },
      { round: 2, name: 'Вика', isMafia: false, blocked: true },
      { round: 3, name: 'Вика', isMafia: false },
    ],
  });
  p.click('btn-myrole');
  sheet = p.text('sheet-body');
  check('после sync видны все проверки', sheet.includes('Ночь 3: Вика') && sheet.includes('не мафия'));
  check('сорванная проверка помечена', sheet.includes('Ночь 2: вас заблокировали') && sheet.includes('не состоялась'));
  p.click('sheet-close');

  // Перезагрузка страницы посреди ночи: ответ этой ночи возвращается из sync.
  p.push('sync', {
    phase: 'night', round: 4, time: 40, paused: false, isAlive: true, canAct: false,
    alreadyActed: true, role: 'commissioner', roleName: 'Комиссар', roleEmoji: '🕵',
    roleAck: true, gameName: 'Тестовая партия', alive: 3, total: 4, intro: false,
    lastWord: null, targets: [], prompt: 'Кого проверить?',
    checks: [{ round: 1, name: 'Борис', isMafia: true }, { round: 4, name: 'Глеб', isMafia: false }],
  });
  check('после перезагрузки ночью ответ на месте', p.text('idle-text') === 'Глеб — не мафия');
  p.push('phase', {
    phase: 'day', round: 4, time: 100, paused: false, isAlive: true, canAct: false,
    prompt: 'Обсуждайте', alive: 3, total: 4, intro: false, lastWord: null, targets: [],
  });
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
  // Стол выбрал Вику, но она ещё не выбыла: живых по-прежнему трое.
  p.push('phase', {
    phase: 'day', round: 4, time: 30, paused: false, isAlive: true, canAct: false,
    prompt: 'Последнее слово: Вика', alive: 3, total: 4, intro: false,
    lastWord: { id: 'p2', name: 'Вика' }, targets: [],
  });
  check('заголовок — «Последнее слово»', p.text('phase-name') === 'Последнее слово');
  check('названо, кто говорит', p.text('idle-sub').includes('Вика'));
  check('сказано, что дальше — повторное голосование', p.text('idle-sub').includes('повторное голосование'));
  check('говорящий ещё в игре: счётчик не изменился', p.text('table-count') === 'Живых: 3 из 4');
  check('голосовать и ходить нельзя', !p.visible('action-area') && !p.visible('game-foot'));
  check('вибро на начале последнего слова', p.buzz.length === 1);
  check('таймер показывает 30 секунд', p.text('phase-timer') === '00:30');

  // ------------------------------------------------- повторное голосование
  console.log('\nПовторное голосование: выгнать или оставить (FR-9.8)');
  const verdictPhase = (id, name, extra) => ({
    phase: 'voting', round: 4, time: 30, paused: false, isAlive: true, canAct: true,
    prompt: `Выгнать ${name} или оставить?`, alive: 3, total: 4, intro: false,
    lastWord: null, verdict: { id, name }, targets: [{ id, name, color: '#33FF57' }],
    ...(extra || {}),
  });
  p.sent.length = 0;
  p.push('phase', verdictPhase('p2', 'Вика'));
  check('заголовок — «Повторное голосование»', p.text('phase-name') === 'Повторное голосование');
  check('вибро на начале повторного голосования', p.buzz.length === 2);
  check('вопрос назван по имени', p.text('prompt').includes('Вика'));
  check('список кандидатов скрыт — вопрос один', !p.visible('targets'));
  check('правило подсчёта на экране', p.visible('verdict-note') && p.text('verdict-note').includes('Поровну — остаётся'));
  check('кнопка «Выгнать: Вика» активна', p.text('btn-send') === 'Выгнать: Вика' && !p.$('btn-send').disabled);
  check('кнопка «Оставить в игре»', p.text('btn-skip') === 'Оставить в игре');
  p.click('btn-skip');
  check('«оставить» — голос без кандидата', p.sent.some((m) => m.type === 'vote' && m.targetId === null));
  check('второй раз проголосовать нельзя', !p.visible('game-foot'));
  p.push('vote_result', { eliminated: null, tie: false, pardonedName: 'Вика' });
  check('стол передумал — «Вика остаётся в игре»', p.text('banner').includes('Вика остаётся в игре'));
  p.push('phase', {
    phase: 'night', round: 5, time: 60, paused: false, isAlive: true, canAct: false,
    prompt: 'Спите', alive: 3, total: 4, intro: false, lastWord: null, targets: [],
  });
  check('после помилования — обычная «Ночь 5»', p.text('phase-name') === 'Ночь 5');
  check('обычная ночь не названа знакомством', !p.text('idle-sub').includes('знакомств'));
  check('помилованная жива: счётчик прежний', p.text('table-count') === 'Живых: 3 из 4');

  // Голос «выгнать» — обычный голос за единственного кандидата.
  p.sent.length = 0;
  p.push('phase', verdictPhase('p1', 'Борис', { round: 5 }));
  p.click('btn-send');
  check('«выгнать» — голос за обвиняемого', p.sent.some((m) => m.type === 'vote' && m.targetId === 'p1'));
  p.push('vote_result', { eliminated: 'p1', eliminatedName: 'Борис', tie: false });
  check('итог — «выбыл Борис»', p.text('banner').includes('выбыл Борис'));

  // После повторного голосования обычное выглядит как раньше.
  p.push('phase', {
    phase: 'voting', round: 6, time: 60, paused: false, isAlive: true, canAct: true,
    prompt: 'Кого отправляем из города?', alive: 2, total: 4, intro: false, lastWord: null,
    targets: [{ id: 'p2', name: 'Вика', color: '#33FF57' }],
  });
  check('обычное голосование: список снова виден',
    p.visible('targets') && !p.visible('verdict-note') && p.$('targets').children.length === 1);
  check('обычное голосование: кнопки прежние',
    p.text('btn-send') === 'Проголосовать' && p.$('btn-send').disabled && p.text('btn-skip') === 'Воздержаться');

  // Стол выбрал меня: я говорю, а потом жду решения.
  p.push('phase', {
    phase: 'day', round: 6, time: 30, paused: false, isAlive: true, canAct: false,
    prompt: 'Ваше последнее слово', alive: 2, total: 4, intro: false,
    lastWord: { id: 'p0', name: 'Аня' }, targets: [],
  });
  check('говорящему: «Ваше последнее слово»', p.visible('idle-area') && p.text('idle-text') === 'Ваше последнее слово');
  check('говорящий не на экране выбывшего', !p.visible('dead-area'));
  check('говорящему сказано, что он ещё в игре', p.text('idle-sub').includes('Вы ещё в игре'));
  p.push('phase', verdictPhase('p0', 'Аня', {
    round: 6, canAct: false, targets: [], prompt: 'Стол решает вашу судьбу',
  }));
  check('обвиняемый не голосует', !p.visible('action-area') && !p.visible('game-foot'));
  check('обвиняемому: «Стол решает вашу судьбу»', p.text('idle-text') === 'Стол решает вашу судьбу');
  check('обвиняемому названо правило', p.text('idle-sub').includes('вы остаётесь в игре'));
  p.push('vote_result', { eliminated: 'p0', eliminatedName: 'Аня', tie: false });
  p.push('eliminated', { reason: 'vote', round: 6 });
  p.push('phase', {
    phase: 'night', round: 7, time: 60, paused: false, isAlive: false, canAct: false,
    prompt: 'Вы выбыли из игры', alive: 1, total: 4, intro: false, lastWord: null, targets: [],
  });
  check('стол не поверил — обычный экран выбывшего', p.visible('dead-area') && p.text('dead-title') === 'Вы выбыли из игры');

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
