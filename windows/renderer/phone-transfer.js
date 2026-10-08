// Main-world UI only. The isolated preload owns all native calls.
(() => {
  'use strict';
  let current = null;
  const element = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  async function close() {
    const item = current;
    if (!item) return;
    current = null;
    clearInterval(item.timer);
    item.overlay.remove();
    item.focus?.focus();
    try { await item.stop?.(); } catch { /* Window shutdown also stops its server. */ }
  }

  function open(result, { stop } = {}) {
    void close();
    const focus = document.activeElement;
    const overlay = element('div', 'phone-transfer-overlay');
    const panel = element('section', 'phone-transfer-panel');
    panel.setAttribute('role', 'dialog');
    panel.setAttribute('aria-modal', 'true');
    panel.setAttribute('aria-labelledby', 'phoneTransferTitle');
    const title = element('h2', '', '手机扫码接收');
    title.id = 'phoneTransferTitle';
    const instructions = element('p', '', '电脑和手机连接同一 Wi-Fi，保持此窗口打开，使用手机浏览器扫描二维码。');
    const image = element('img', 'phone-transfer-qr');
    image.alt = '手机传输链接二维码';
    image.src = result.qrcode;
    const address = element('input', 'phone-transfer-address');
    address.readOnly = true;
    address.value = result.url;
    address.setAttribute('aria-label', '手机传输地址');
    address.addEventListener('focus', () => address.select());
    const status = element('p', 'phone-transfer-status');
    status.setAttribute('role', 'status');
    const notes = element('p', 'phone-transfer-help', '下载由手机浏览器处理。保存到相册请在手机上使用分享或保存；ZIP 通常进入「文件」或「下载」。文字复制失败时，可在手机页面长按选中文字。');
    const alternatives = element('details', 'phone-transfer-alternatives');
    alternatives.append(element('summary', '', '扫码打不开：查看其他网络地址'));
    for (const url of result.addresses || []) {
      const line = element('p');
      const field = element('input', 'phone-transfer-address');
      field.readOnly = true;
      field.value = url;
      field.setAttribute('aria-label', url.includes('127.0.0.1') ? '本机验证地址' : '备用网络地址');
      field.addEventListener('focus', () => field.select());
      line.append(field);
      if (url.includes('127.0.0.1')) line.append(element('small', '', '仅供本机验证，手机不能使用这个地址'));
      alternatives.append(line);
    }
    alternatives.append(element('p', '', '请关闭手机 VPN，尝试备用局域网地址；Windows 防火墙首次提示时允许专用网络。'));
    const actions = element('div', 'phone-transfer-actions');
    const copy = element('button', 'pill-button', '复制链接');
    copy.type = 'button';
    copy.addEventListener('click', async () => {
      try { await window.MediaCraftNative.copyText(result.url); status.textContent = '链接已复制'; }
      catch { address.focus(); address.select(); status.textContent = '链接已选中，请按 Ctrl+C 复制'; }
    });
    const done = element('button', 'primary-button', '关闭并停止传输');
    done.type = 'button';
    done.addEventListener('click', () => void close());
    actions.append(copy, done);
    panel.append(title, instructions, image, address, status, notes, alternatives, actions);
    overlay.append(panel);
    overlay.addEventListener('click', (event) => { if (event.target === overlay) void close(); });
    overlay.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); void close(); }
      if (event.key !== 'Tab') return;
      const controls = [...panel.querySelectorAll('button,input,summary')].filter((node) => node.getClientRects().length && !node.disabled);
      const first = controls[0];
      const last = controls.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    });
    document.body.append(overlay);
    const expires = Date.parse(result.expiresAt);
    const item = { overlay, focus, stop, timer: null };
    current = item;
    const tick = () => {
      if (current !== item) return;
      const remaining = Math.max(0, Math.ceil((expires - Date.now()) / 1000));
      status.textContent = `链接 ${Math.floor(remaining / 60)} 分 ${remaining % 60} 秒后失效；关闭窗口立即停止传输`;
      if (!remaining) void close();
    };
    item.timer = setInterval(tick, 1000);
    tick();
    done.focus();
    return { close };
  }

  window.addEventListener('beforeunload', () => { void close(); });
  window.MediaCraftPhoneTransfer = { open, close };
})();
