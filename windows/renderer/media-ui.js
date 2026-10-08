// Windows exposes full-card MP4/GIF and LAN transfer through the shared API.
(() => {
  'use strict';
  function install() {
    const mc = window.mediacraft;
    if (!mc?.output?.exportMotion) { setTimeout(install, 80); return; }
    const native = window.MediaCraftNative;
    if (!native?.capabilities?.phoneTransfer) return;
    const send = document.getElementById('sendToIPhoneBtn');
    if (send) { send.querySelector('span').textContent = '发送到手机'; send.title = '同一局域网扫码接收卡片、视频和发布文字'; }
    const dialog = document.getElementById('liveDialog');
    const heading = dialog?.querySelector('h2');
    if (heading) heading.textContent = '动态卡片';
    const container = document.getElementById('exportActions');
    const buttons = ['mp4', 'gif'].map((format) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'pill-button';
      button.dataset.motionExport = format;
      button.textContent = `导出 ${format.toUpperCase()}`;
      button.title = format === 'gif' ? '完整动态卡片，15 fps GIF，宽 864 像素，无声音' : '完整动态卡片，1440 × 1920，30 fps MP4，可带声音';
      button.addEventListener('click', () => { mc.output.exportMotion(format).catch(() => undefined); });
      container.insertBefore(button, send);
      return button;
    });
    const update = async () => {
      const draft = await mc.drafts.current();
      for (const button of buttons) button.hidden = draft.mode !== 'cards';
    };
    mc.on('change', () => { void update(); });
    mc.on('rendered', () => { void update(); });
    void update();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, { once: true });
  else install();
})();
