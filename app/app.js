'use strict';

const $ = (id) => document.getElementById(id);

const S = {
  port: null,
  reader: null,
  writer: null,
  readLoopRunning: false,
  closing: false,
  pending: null,
  busy: false,
  scanning: false,
  abort: false,
  devices: [],
  selected: null,
  portLabel: '',
};

const DEFAULTS = {
  baud: '19200',
  parity: 'even',
  stopBits: '1',
  timeout: 120,
  retries: 0,
  scanStart: 1,
  scanEnd: 247,
  scanF3: true,
  scanF4: false,
};

const delay = (ms) => new Promise((r) => setTimeout(r, ms));
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

document.addEventListener('DOMContentLoaded', init);

function init() {
  loadSettings();
  bindEvents();
  initUpdater();

  if (!('serial' in navigator)) {
    $('btnConnect').disabled = true;
    log('err', 'Bu tarayıcıda Web Serial yok. Masaüstü Edge veya Chrome kullanın.');
    updateControls();
    return;
  }
  if (location.protocol === 'file:') {
    log('err', 'Sayfa file:// ile açılmış. Web Serial için start.bat ile localhost üzerinden açın.');
  }

  log('info', 'Hazır. Port seçip bağlanın.');
  updateControls();
}

function bindEvents() {
  $('btnConnect').addEventListener('click', connect);
  $('btnDisconnect').addEventListener('click', disconnect);
  $('btnScan').addEventListener('click', () => startScan());
  $('btnQuick').addEventListener('click', () => {
    $('scanStart').value = 1;
    $('scanEnd').value = 16;
    saveSettings();
    startScan();
  });
  $('btnStop').addEventListener('click', () => {
    S.abort = true;
    log('info', 'Tarama durduruluyor…');
  });
  $('btnReadAll').addEventListener('click', readSelectedDevice);
  $('btnReadReg').addEventListener('click', readRegisterTool);
  $('btnWriteReg').addEventListener('click', writeRegisterTool);
  $('btnClearLog').addEventListener('click', () => { $('log').textContent = ''; });
  $('btnCopyLog').addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText($('log').innerText);
      log('info', 'Günlük panoya kopyalandı.');
    } catch {
      log('err', 'Panoya kopyalanamadı.');
    }
  });

  ['baud', 'parity', 'stopBits', 'timeout', 'retries', 'scanStart', 'scanEnd', 'scanF3', 'scanF4']
    .forEach((id) => $(id).addEventListener('change', saveSettings));

  if ('serial' in navigator) {
    navigator.serial.addEventListener('disconnect', (e) => {
      if (S.port && e.target === S.port) {
        log('err', 'Port bağlantısı koptu.');
        S.closing = true;
        if (S.pending) S.pending.finish(null);
        S.scanning = false;
        S.port = null;
        S.reader = null;
        S.writer = null;
        updateControls();
        setBadge('off');
      }
    });
  }
}

/* ---------------- settings ---------------- */

function loadSettings() {
  let s = DEFAULTS;
  try {
    s = Object.assign({}, DEFAULTS, JSON.parse(localStorage.getItem('fanmodbus.settings') || '{}'));
  } catch { /* ignore */ }

  $('baud').value = String(s.baud);
  $('parity').value = String(s.parity);
  $('stopBits').value = String(s.stopBits);
  $('timeout').value = String(s.timeout);
  $('retries').value = String(s.retries);
  $('scanStart').value = String(s.scanStart);
  $('scanEnd').value = String(s.scanEnd);
  $('scanF3').checked = !!s.scanF3;
  $('scanF4').checked = !!s.scanF4;
}

function saveSettings() {
  const s = {
    baud: $('baud').value,
    parity: $('parity').value,
    stopBits: $('stopBits').value,
    timeout: $('timeout').value,
    retries: $('retries').value,
    scanStart: $('scanStart').value,
    scanEnd: $('scanEnd').value,
    scanF3: $('scanF3').checked,
    scanF4: $('scanF4').checked,
  };
  try { localStorage.setItem('fanmodbus.settings', JSON.stringify(s)); } catch { /* ignore */ }
}

/* ---------------- UI ---------------- */

function setBadge(mode) {
  const badge = $('connBadge');
  badge.classList.remove('on', 'busy');
  if (mode === 'on') {
    badge.classList.add('on');
    $('connText').textContent = 'Bağlı';
  } else if (mode === 'busy') {
    badge.classList.add('busy');
    $('connText').textContent = 'Taranıyor…';
  } else {
    $('connText').textContent = 'Bağlı değil';
  }
}

function updateControls() {
  const connected = !!S.port;
  const scanning = S.scanning;

  $('btnConnect').disabled = connected;
  $('btnDisconnect').disabled = !connected || scanning;
  $('btnScan').disabled = !connected || scanning;
  $('btnQuick').disabled = !connected || scanning;
  $('btnStop').disabled = !scanning;
  $('btnReadAll').disabled = !connected || scanning || !S.selected;
  $('btnReadReg').disabled = !connected || scanning || !S.selected;
  $('btnWriteReg').disabled = !connected || scanning || !S.selected;

  if (scanning) setBadge('busy');
  else if (connected) setBadge('on');
  else setBadge('off');
}

function log(kind, msg) {
  const box = $('log');
  const time = new Date().toLocaleTimeString('tr-TR', { hour12: false });
  const line = document.createElement('div');
  line.className = 'logline';

  const t = document.createElement('span');
  t.className = 't';
  t.textContent = time;

  const k = document.createElement('span');
  k.className = 'k ' + kind;
  k.textContent = kind.toUpperCase();

  const m = document.createElement('span');
  m.className = 'm';
  m.textContent = msg;

  line.append(t, k, m);
  box.appendChild(line);
  while (box.children.length > 600) box.removeChild(box.firstChild);
  box.scrollTop = box.scrollHeight;
}

/* ---------------- Modbus ---------------- */

function crc16(bytes) {
  let crc = 0xFFFF;
  for (const b of bytes) {
    crc ^= b;
    for (let i = 0; i < 8; i++) {
      if (crc & 1) crc = (crc >> 1) ^ 0xA001;
      else crc >>= 1;
    }
  }
  return crc & 0xFFFF;
}

function buildReadFrame(id, func, addr, count) {
  const body = [id & 0xFF, func & 0xFF, (addr >> 8) & 0xFF, addr & 0xFF, (count >> 8) & 0xFF, count & 0xFF];
  const c = crc16(body);
  return Uint8Array.from([...body, c & 0xFF, (c >> 8) & 0xFF]);
}

function buildWriteFrame(id, addr, value) {
  const body = [id & 0xFF, 0x06, (addr >> 8) & 0xFF, addr & 0xFF, (value >> 8) & 0xFF, value & 0xFF];
  const c = crc16(body);
  return Uint8Array.from([...body, c & 0xFF, (c >> 8) & 0xFF]);
}

function crcValid(frame) {
  if (frame.length < 5) return false;
  const c = crc16(Array.from(frame.slice(0, frame.length - 2)));
  return frame[frame.length - 2] === (c & 0xFF) && frame[frame.length - 1] === ((c >> 8) & 0xFF);
}

function hex(bytes) {
  return Array.from(bytes || []).map((b) => b.toString(16).toUpperCase().padStart(2, '0')).join(' ');
}

function parseResponse(frame, func) {
  if (!frame || !crcValid(frame)) return { exception: 'CRC', regs: [] };
  if (frame[1] & 0x80) return { exception: frame[2], regs: [] };
  if ((frame[1] & 0x7F) !== func) return { exception: 'FC', regs: [] };
  const count = frame[2];
  const regs = [];
  for (let i = 0; i + 1 < count; i += 2) {
    regs.push((frame[3 + i] << 8) | frame[4 + i]);
  }
  return { exception: null, regs };
}

function exceptionText(code) {
  const map = {
    1: 'Geçersiz fonksiyon',
    2: 'Geçersiz adres',
    3: 'Geçersiz değer',
    4: 'Cihaz hatası',
    5: 'Onaylandı, işlem sürüyor',
    6: 'Cihaz meşgul',
    11: 'Gateway hedefe ulaşamadı',
  };
  if (code === 'CRC') return 'CRC hatası';
  if (code === 'FC') return 'Fonksiyon uyuşmazlığı';
  return `Exception ${code}${map[code] ? ' · ' + map[code] : ''}`;
}

/* ---------------- updater ---------------- */

const UPDATER = {
  intervalMs: 30 * 60 * 1000,
  checking: false,
  applying: false,
  available: false,
  local: null,
  remote: null,
};

function initUpdater() {
  $('btnUpdate').addEventListener('click', onUpdateButton);

  if (sessionStorage.getItem('fanmodbus.restartRequired') === '1') {
    sessionStorage.removeItem('fanmodbus.restartRequired');
    setUpdaterUI('restart');
  } else {
    setTimeout(() => checkUpdate(false), 1800);
    setInterval(() => checkUpdate(false), UPDATER.intervalMs);
  }

  loadLocalVersion();
}

async function loadLocalVersion() {
  try {
    const res = await fetch('/api/version', { cache: 'no-store' });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || 'Sürüm okunamadı');
    UPDATER.local = data;
    $('versionChip').textContent = 'Sürüm: ' + (data.short || 'bilinmiyor');
  } catch {
    $('versionChip').textContent = 'Sürüm: —';
  }
}

async function checkUpdate(manual) {
  if (UPDATER.checking || UPDATER.applying) return;
  UPDATER.checking = true;
  setUpdaterUI('checking');

  try {
    const res = await fetch('/api/update/check', { cache: 'no-store' });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || ('HTTP ' + res.status));

    UPDATER.local = data.local;
    UPDATER.remote = data.remote;
    UPDATER.available = !!data.available;

    if (data.local && data.local.short) {
      $('versionChip').textContent = 'Sürüm: ' + data.local.short;
    }

    if (data.available) {
      setUpdaterUI('available');
      log('info', `Yeni sürüm mevcut: ${data.remote.short} · ${data.remote.message}`);
    } else {
      setUpdaterUI('current');
      if (manual) log('info', 'Program güncel.');
    }
  } catch (err) {
    setUpdaterUI('error', err.message || String(err));
    if (manual) log('err', 'Güncelleme kontrolü: ' + (err.message || err));
  } finally {
    UPDATER.checking = false;
    const stamp = $('lastCheck');
    if (stamp) {
      stamp.textContent = 'Son kontrol ' + new Date().toLocaleTimeString('tr-TR', { hour12: false });
    }
  }
}

function setUpdaterUI(mode, detail) {
  const strip = $('updateStrip');
  const text = $('updateText');
  const button = $('btnUpdate');

  strip.classList.remove('hasUpdate', 'busy', 'error', 'restart');
  button.classList.remove('primary', 'warn');
  button.classList.add('secondary');

  if (mode === 'checking') {
    strip.classList.add('busy');
    text.textContent = 'Güncellemeler kontrol ediliyor…';
    button.textContent = 'Kontrol ediliyor…';
    button.disabled = true;
    return;
  }

  if (mode === 'available') {
    const r = UPDATER.remote || {};
    strip.classList.add('hasUpdate');
    text.textContent = `Yeni sürüm mevcut: ${r.short || ''}${r.message ? ' · ' + r.message : ''}`;
    button.textContent = 'GÜNCELLE';
    button.disabled = false;
    button.classList.remove('secondary');
    button.classList.add('primary');
    return;
  }

  if (mode === 'current') {
    const local = UPDATER.local || {};
    text.textContent = 'Program güncel' + (local.short ? ' · ' + local.short : '');
    button.textContent = 'Kontrol Et';
    button.disabled = false;
    return;
  }

  if (mode === 'applying') {
    strip.classList.add('busy');
    text.textContent = 'Yeni sürüm indiriliyor ve kuruluyor…';
    button.textContent = 'İNDİRİLİYOR…';
    button.disabled = true;
    return;
  }

  if (mode === 'done') {
    strip.classList.add('hasUpdate');
    text.textContent = 'Güncelleme kuruldu. Sayfa yenileniyor…';
    button.textContent = 'TAMAM';
    button.disabled = true;
    return;
  }

  if (mode === 'restart') {
    strip.classList.add('restart');
    text.textContent = 'Sunucu dosyaları güncellendi. Tam etki için bu pencereyi kapatıp start.bat ile yeniden açın.';
    button.textContent = 'Kontrol Et';
    button.disabled = false;
    return;
  }

  strip.classList.add('error');
  text.textContent = 'Güncelleme hatası: ' + (detail || 'bilinmeyen hata');
  button.textContent = 'Tekrar Dene';
  button.disabled = false;
}

async function onUpdateButton() {
  if (UPDATER.applying) return;

  if (!UPDATER.available) {
    await checkUpdate(true);
    return;
  }

  const remote = UPDATER.remote || {};
  const ok = confirm(
    `Yeni sürüm indirilip kurulacak:\n\n${remote.short || ''} · ${remote.message || ''}\n\nDevam edilsin mi?`
  );
  if (!ok) return;

  UPDATER.applying = true;
  setUpdaterUI('applying');

  try {
    const res = await fetch('/api/update/apply', {
      method: 'POST',
      headers: { 'X-FanModbus-Update': 'apply' },
      cache: 'no-store',
    });
    const data = await res.json();
    if (!res.ok || !data.ok) throw new Error(data.error || ('HTTP ' + res.status));

    UPDATER.available = false;
    setUpdaterUI('done');
    log('info', `Güncelleme kuruldu: ${data.short || ''}${data.restartRequired ? ' · sunucu yeniden başlatılmalı' : ''}`);

    if (data.restartRequired) {
      sessionStorage.setItem('fanmodbus.restartRequired', '1');
    }
    setTimeout(() => location.reload(), 1500);
  } catch (err) {
    UPDATER.applying = false;
    setUpdaterUI('error', err.message || String(err));
    log('err', 'Güncelleme başarısız: ' + (err.message || err));
  }
}

/* ---------------- serial I/O ---------------- */

async function connect() {
  if (!('serial' in navigator)) return;
  if (S.port) return;

  let port;
  try {
    port = await navigator.serial.requestPort({});
  } catch (err) {
    if (err && err.name === 'NotFoundError') log('info', 'Port seçimi iptal edildi.');
    else log('err', 'Port seçilemedi: ' + (err.message || err));
    return;
  }

  const baud = clamp(parseInt($('baud').value, 10) || 19200, 300, 921600);
  const parity = $('parity').value;
  const stopBits = parseInt($('stopBits').value, 10) === 2 ? 2 : 1;

  try {
    await port.open({ baudRate: baud, dataBits: 8, stopBits, parity, flowControl: 'none', bufferSize: 8192 });
  } catch (err) {
    log('err', `Port açılamadı: ${err.message || err}. EC-Control açık mı?`);
    return;
  }

  S.port = port;
  S.closing = false;
  const info = port.getInfo ? port.getInfo() : {};
  S.portLabel = info.usbVendorId
    ? `USB ${info.usbVendorId.toString(16).toUpperCase().padStart(4, '0')}:${(info.usbProductId || 0).toString(16).toUpperCase().padStart(4, '0')}`
    : 'Seri port';
  $('portName').textContent = S.portLabel;

  log('info', `Bağlandı · ${S.portLabel} · ${baud} ${stopBits === 1 ? '8' + parity[0].toUpperCase() + '1' : '8' + parity[0].toUpperCase() + '2'}`);
  startReadLoop(port);
  updateControls();
  saveSettings();
}

function startReadLoop(port) {
  if (S.readLoopRunning) return;
  S.readLoopRunning = true;

  (async () => {
    while (port.readable && !S.closing) {
      const reader = port.readable.getReader();
      S.reader = reader;
      try {
        while (!S.closing) {
          const { value, done } = await reader.read();
          if (done) break;
          if (value && value.length) onRx(value);
        }
      } catch (err) {
        if (!S.closing) log('err', 'Okuma hatası: ' + (err.message || err));
      } finally {
        try { reader.releaseLock(); } catch { /* ignore */ }
        if (S.reader === reader) S.reader = null;
      }
    }
    S.readLoopRunning = false;
  })();
}

function onRx(chunk) {
  const p = S.pending;
  if (!p) {
    log('rx', 'Beklenmeyen veri: ' + hex(chunk));
    return;
  }

  for (const b of chunk) p.raw.push(b);

  if (p.echo) {
    const tx = p.echo;
    let k = 0;
    while (k < tx.length && k < p.raw.length && p.raw[k] === tx[k]) k++;
    if (k === tx.length) {
      p.raw.splice(0, k);
      p.echo = null;
    } else if (k === p.raw.length) {
      return; // şimdilik yalnızca istek yankısı geldi
    } else {
      p.echo = null;
    }
  }

  if (!p.raw.length) return;
  if (p.raw[0] !== p.expectId) {
    p.raw.length = 0;
    return;
  }
  if (p.raw.length < 3) return;

  const funcByte = p.raw[1];
  const need = (funcByte & 0x80) ? 5 : (3 + p.raw[2] + 2);
  if (p.raw.length < need) return;

  p.finish(Uint8Array.from(p.raw.slice(0, need)));
}

function awaitResponse(expectId, txFrame, timeoutMs) {
  return new Promise((resolve) => {
    const p = {
      raw: [],
      echo: Array.from(txFrame),
      expectId,
      resolved: false,
      timer: null,
      finish: null,
    };
    p.finish = (val) => {
      if (p.resolved) return;
      p.resolved = true;
      clearTimeout(p.timer);
      if (S.pending === p) S.pending = null;
      resolve(val);
    };
    p.timer = setTimeout(() => p.finish(null), timeoutMs);
    S.pending = p;
  });
}

async function writeAndWait(frame, expectId, timeoutMs) {
  if (!S.port || S.closing) return null;
  if (S.pending) S.pending.finish(null);

  const wait = awaitResponse(expectId, frame, timeoutMs);
  try {
    if (!S.writer) S.writer = S.port.writable.getWriter();
    await S.writer.write(frame);
  } catch (err) {
    if (S.pending) S.pending.finish(null);
    throw err;
  }
  return wait;
}

async function requestRead(id, func, addr, count, timeoutMs, retries, logTraffic = false) {
  const frame = buildReadFrame(id, func, addr, count);
  for (let attempt = 0; attempt <= retries; attempt++) {
    if (!S.port || S.closing) return null;
    if (logTraffic) log('tx', `ID ${id} FC${func} @0x${addr.toString(16).toUpperCase().padStart(4, '0')} x${count} · ${hex(frame)}`);
    const resp = await writeAndWait(frame, id, timeoutMs);
    if (resp) {
      if (logTraffic) log('rx', `ID ${id} · ${hex(resp)}`);
      return resp;
    }
    if (logTraffic && attempt === retries) log('err', `ID ${id} FC${func}: yanıt yok`);
    await delay(6);
  }
  return null;
}

async function acquireBus() {
  while (S.busy) await delay(8);
  S.busy = true;
}

function releaseBus() {
  S.busy = false;
}

/* ---------------- scan ---------------- */

async function startScan() {
  if (!S.port || S.scanning) return;

  let start = clamp(parseInt($('scanStart').value, 10) || 1, 1, 247);
  let end = clamp(parseInt($('scanEnd').value, 10) || 247, 1, 247);
  if (start > end) [start, end] = [end, start];

  const funcs = [];
  if ($('scanF3').checked) funcs.push(3);
  if ($('scanF4').checked) funcs.push(4);
  if (!funcs.length) {
    log('err', 'En az bir fonksiyon (3 veya 4) seçin.');
    return;
  }

  saveSettings();
  await acquireBus();

  S.scanning = true;
  S.abort = false;
  S.devices = [];
  S.selected = null;
  renderDevices();
  clearDetail();
  updateControls();

  const timeout = clamp(parseInt($('timeout').value, 10) || 150, 40, 2000);
  const retries = clamp(parseInt($('retries').value, 10) || 0, 0, 5);
  const total = end - start + 1;
  const t0 = performance.now();
  let done = 0;

  log('info', `Tarama başladı · adres ${start}–${end} · FC${funcs.join('/FC')} · ${timeout} ms · ${retries} tekrar`);

  try {
    for (let id = start; id <= end; id++) {
      if (S.abort || !S.port || S.closing) break;

      let hit = null;
      for (const f of funcs) {
        const resp = await requestRead(id, f, 0, 8, timeout, retries);
        if (resp) {
          const parsed = parseResponse(resp, f);
          if (!hit || (hit.exception && !parsed.exception)) {
            hit = { id, func: f, resp, parsed };
          }
          if (!parsed.exception) break;
        }
        if (S.abort || !S.port || S.closing) break;
      }

      if (hit) {
        const dev = {
          id: hit.id,
          func: hit.func,
          hex: hex(hit.resp),
          bytes: hit.resp,
          exception: hit.parsed.exception,
          regs: hit.parsed.regs,
        };
        S.devices.push(dev);
        renderDevices();
        log('rx', `CİHAZ ID ${dev.id} · FC${dev.func} · ${dev.hex}` +
          (dev.exception ? ` · ${exceptionText(dev.exception)}` : ''));
      }

      done++;
      if (done % 3 === 0 || id === end || hit) updateScanProgress(done, total, t0);
      await delay(4);
    }
  } catch (err) {
    log('err', 'Tarama hatası: ' + (err.message || err));
  } finally {
    S.scanning = false;
    releaseBus();
    updateControls();
    updateScanProgress(done, total, t0, true);
    log('info', `Tarama bitti · ${done}/${total} adres · ${S.devices.length} cihaz`);
    if (S.devices.length) selectDevice(S.devices[0]);
  }
}

function updateScanProgress(done, total, t0, finished = false) {
  const pct = total ? Math.round((done / total) * 100) : 0;
  $('scanBar').style.width = pct + '%';

  const elapsed = (performance.now() - t0) / 1000;
  if (finished) {
    $('scanInfo').textContent = `Tarama bitti · ${done}/${total} · ${elapsed.toFixed(1)} sn`;
  } else {
    const per = done > 0 ? elapsed / done : 0;
    const remain = Math.max(0, Math.round((total - done) * per));
    $('scanInfo').textContent = `Taranıyor ${done}/${total} · kalan ~${remain} sn`;
  }

  $('scanStatePill').textContent = finished ? 'Bitti' : (done >= total ? 'Bitti' : 'Taranıyor');
  $('scanFound').textContent = S.devices.length ? `${S.devices.length} cihaz bulundu` : '';
}

function renderDevices() {
  const tbody = $('devTable').querySelector('tbody');
  tbody.textContent = '';
  $('devEmpty').hidden = S.devices.length > 0;

  S.devices.forEach((dev, i) => {
    const tr = document.createElement('tr');
    if (S.selected && S.selected.id === dev.id) tr.classList.add('selected');
    tr.addEventListener('click', () => selectDevice(dev));

    const n = document.createElement('td');
    n.textContent = String(i + 1);

    const addr = document.createElement('td');
    addr.innerHTML = '';
    const strong = document.createElement('strong');
    strong.textContent = String(dev.id);
    addr.appendChild(strong);

    const resp = document.createElement('td');
    const badge = document.createElement('span');
    badge.className = 'badge ' + (dev.exception ? 'ex' : 'ok');
    badge.textContent = dev.exception ? exceptionText(dev.exception) : `FC${dev.func} yanıt`;
    resp.appendChild(badge);

    const raw = document.createElement('td');
    raw.className = 'mono';
    raw.textContent = dev.hex;
    raw.title = dev.hex;

    tr.append(n, addr, resp, raw);
    tbody.appendChild(tr);
  });
}

/* ---------------- device detail ---------------- */

function selectDevice(dev) {
  S.selected = dev;
  renderDevices();
  $('detailEmpty').hidden = true;
  $('detailBody').hidden = false;
  $('detailPill').textContent = `Adres ${dev.id} · FC${dev.func}`;
  updateControls();

  const wrap = $('detailRegs');
  wrap.textContent = '';
  if (dev.exception) {
    const p = document.createElement('div');
    p.className = 'empty';
    p.textContent = `Cihaz yanıt verdi ancak veri okunamadı: ${exceptionText(dev.exception)}. “Registerları Oku” ile FC4 deneyin.`;
    wrap.appendChild(p);
  } else {
    wrap.appendChild(regBlock(`FC${dev.func} · 0x0000–`, dev.regs));
  }
}

function clearDetail() {
  S.selected = null;
  $('detailEmpty').hidden = false;
  $('detailBody').hidden = true;
  $('detailPill').textContent = '—';
  $('detailRegs').textContent = '';
  $('rwResult').textContent = '';
  updateControls();
}

function regBlock(title, regs, startAddr = 0) {
  const block = document.createElement('div');
  block.className = 'regBlock';

  const h = document.createElement('h4');
  h.textContent = title;
  block.appendChild(h);

  const table = document.createElement('table');
  const thead = document.createElement('thead');
  thead.innerHTML = '<tr><th>Adres</th><th>Hex</th><th>UInt16</th><th>Int16</th></tr>';
  table.appendChild(thead);

  const tbody = document.createElement('tbody');
  regs.forEach((v, i) => {
    const addr = startAddr + i;
    const tr = document.createElement('tr');
    const tdA = document.createElement('td');
    tdA.className = 'addr';
    tdA.textContent = '0x' + addr.toString(16).toUpperCase().padStart(4, '0');
    const tdH = document.createElement('td');
    tdH.className = 'hex';
    tdH.textContent = '0x' + v.toString(16).toUpperCase().padStart(4, '0');
    const tdU = document.createElement('td');
    tdU.textContent = String(v);
    const tdI = document.createElement('td');
    tdI.textContent = String(v > 32767 ? v - 65536 : v);
    tr.append(tdA, tdH, tdU, tdI);
    tbody.appendChild(tr);
  });
  table.appendChild(tbody);
  block.appendChild(table);
  return block;
}

async function readSelectedDevice() {
  if (!S.port || !S.selected || S.scanning) return;
  const dev = S.selected;
  const wrap = $('detailRegs');
  wrap.textContent = '';
  const timeout = Math.max(300, parseInt($('timeout').value, 10) || 150);

  await acquireBus();
  try {
    for (const func of [3, 4]) {
      log('tx', `ID ${dev.id} FC${func} @0x0000 x16`);
      const resp = await requestRead(dev.id, func, 0, 16, timeout, 1, false);
      if (!resp) {
        const block = document.createElement('div');
        block.className = 'regBlock';
        block.innerHTML = `<h4>FC${func} · 0x0000–0x000F</h4><div class="empty">Yanıt yok</div>`;
        wrap.appendChild(block);
        log('err', `ID ${dev.id} FC${func}: yanıt yok`);
        continue;
      }
      const parsed = parseResponse(resp, func);
      log('rx', `ID ${dev.id} FC${func} · ${hex(resp)}`);
      if (parsed.exception) {
        const block = document.createElement('div');
        block.className = 'regBlock';
        block.innerHTML = '';
        const h = document.createElement('h4');
        h.textContent = `FC${func} · 0x0000–0x000F`;
        const e = document.createElement('div');
        e.className = 'empty';
        e.textContent = exceptionText(parsed.exception);
        block.append(h, e);
        wrap.appendChild(block);
      } else {
        wrap.appendChild(regBlock(`FC${func} · 0x0000–0x000F`, parsed.regs));
      }
    }
  } finally {
    releaseBus();
  }
}

/* ---------------- register tool ---------------- */

function parseNumber(text) {
  const t = String(text).trim();
  if (/^0x/i.test(t)) return parseInt(t, 16);
  return parseInt(t, 10);
}

async function readRegisterTool() {
  if (!S.port || !S.selected || S.scanning) return;
  const func = parseInt($('rwFunc').value, 10);
  const addr = parseNumber($('rwAddr').value);
  const count = clamp(parseNumber($('rwCount').value) || 1, 1, 125);
  if (!Number.isFinite(addr) || addr < 0 || addr > 65535) {
    $('rwResult').textContent = 'Geçersiz adres.';
    return;
  }

  await acquireBus();
  try {
    const resp = await requestRead(S.selected.id, func, addr, count, Math.max(300, parseInt($('timeout').value, 10) || 150), 1, true);
    if (!resp) {
      $('rwResult').textContent = 'Yanıt yok.';
      return;
    }
    const parsed = parseResponse(resp, func);
    if (parsed.exception) {
      $('rwResult').textContent = exceptionText(parsed.exception);
      return;
    }
    const lines = parsed.regs.map((v, i) => {
      const a = '0x' + (addr + i).toString(16).toUpperCase().padStart(4, '0');
      return `${a} = 0x${v.toString(16).toUpperCase().padStart(4, '0')} · ${v} · int16 ${v > 32767 ? v - 65536 : v}`;
    });
    $('rwResult').textContent = lines.join('\n');
  } finally {
    releaseBus();
  }
}

async function writeRegisterTool() {
  if (!S.port || !S.selected || S.scanning) return;
  const id = S.selected.id;
  const addr = parseNumber($('rwAddr').value);
  const value = parseNumber($('rwValue').value);
  if (!Number.isFinite(addr) || addr < 0 || addr > 65535) {
    $('rwResult').textContent = 'Geçersiz adres.';
    return;
  }
  if (!Number.isFinite(value) || value < 0 || value > 65535) {
    $('rwResult').textContent = 'Değer 0–65535 arasında olmalı.';
    return;
  }

  const ok = confirm(
    `ID ${id} · register 0x${addr.toString(16).toUpperCase().padStart(4, '0')} → ${value} (0x${value.toString(16).toUpperCase().padStart(4, '0')})\n\n` +
    'Bu işlem fan yapılandırmasını kalıcı olarak değiştirebilir. Devam edilsin mi?'
  );
  if (!ok) return;

  await acquireBus();
  try {
    const frame = buildWriteFrame(id, addr, value);
    log('tx', `ID ${id} FC6 @0x${addr.toString(16).toUpperCase().padStart(4, '0')} = ${value} · ${hex(frame)}`);
    const resp = await writeAndWait(frame, id, Math.max(300, parseInt($('timeout').value, 10) || 150));
    if (!resp) {
      $('rwResult').textContent = 'Yanıt yok.';
      log('err', `ID ${id} FC6: yanıt yok`);
      return;
    }
    log('rx', `ID ${id} · ${hex(resp)}`);
    if (!crcValid(resp)) {
      $('rwResult').textContent = 'CRC hatası: ' + hex(resp);
      return;
    }
    if (resp[1] & 0x80) {
      $('rwResult').textContent = exceptionText(resp[2]);
      return;
    }
    $('rwResult').textContent = 'Yazma onaylandı: ' + hex(resp);
  } catch (err) {
    $('rwResult').textContent = 'Yazma hatası: ' + (err.message || err);
    log('err', 'Yazma hatası: ' + (err.message || err));
  } finally {
    releaseBus();
  }
}

/* ---------------- disconnect ---------------- */

async function disconnect() {
  if (!S.port) return;
  S.closing = true;
  S.abort = true;
  if (S.pending) S.pending.finish(null);

  try { if (S.reader) await S.reader.cancel(); } catch { /* ignore */ }
  await delay(60);
  try { if (S.writer) { S.writer.releaseLock(); S.writer = null; } } catch { /* ignore */ }
  try { await S.port.close(); } catch (err) { log('err', 'Port kapatma: ' + (err.message || err)); }

  S.port = null;
  S.reader = null;
  S.readLoopRunning = false;
  S.scanning = false;
  $('portName').textContent = 'COM portu seçilmedi';
  updateControls();
  log('info', 'Bağlantı kesildi.');
}
