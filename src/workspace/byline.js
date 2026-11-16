// 检查器「署名」：名字、账号与头像预览（换头像、裁剪头像的对话框在 src/media/media.js）。
// 署名是全局的，不属于某一篇稿子；名字没填时卡片上用默认名字。
(function (root) {
  "use strict";

  const PREVIEW_SIZE = 160; // 裁剪过的头像预览画成这么大的正方形（显示时再缩小）

  // defaults：默认署名 { name, handle, avatar }；onInput()：用户改了名字、账号或头像
  function create(defaults, onInput) {
    const name = document.querySelector("#displayNameInput");
    const handle = document.querySelector("#handleInput");
    const preview = document.querySelector("#avatarPreview");
    let avatar = { src: defaults.avatar, crop: null };
    let previewTicket = 0;

    // 默认名字是空的（卡片上不写名字）：占位写「你的名字」，看得出这里能填
    name.placeholder = defaults.name || "你的名字";
    for (const input of [name, handle]) input.addEventListener("input", () => onInput());

    // 没裁剪时直接显示原图；裁剪过就把那一块画成正方形。图读不出来时照样显示原图地址。
    async function showAvatar() {
      const ticket = ++previewTicket;
      const { src, crop } = avatar;
      if (!crop) {
        preview.src = src;
        return;
      }
      // 等 load 而不是 decode()：窗口在后台时 decode() 可能一直不回来
      const image = await new Promise((resolve) => {
        const element = new Image();
        element.onload = () => resolve(element);
        element.onerror = () => resolve(null);
        element.src = src;
      });
      if (ticket !== previewTicket) return;
      if (!image) {
        preview.src = src;
        return;
      }
      const canvas = document.createElement("canvas");
      canvas.width = PREVIEW_SIZE;
      canvas.height = PREVIEW_SIZE;
      const context = canvas.getContext("2d");
      context.imageSmoothingQuality = "high";
      context.drawImage(image, crop.x, crop.y, crop.width, crop.height, 0, 0, PREVIEW_SIZE, PREVIEW_SIZE);
      preview.src = canvas.toDataURL("image/png");
    }

    const api = {
      // { name, handle, avatar, avatarCrop }：名字、账号去掉两头空白，名字空着时用默认名字
      read() {
        return {
          name: name.value.trim() || defaults.name,
          handle: handle.value.trim(),
          avatar: avatar.src,
          avatarCrop: avatar.crop ? { ...avatar.crop } : null,
        };
      },
      // 给了哪几项就改哪几项；avatar / avatarCrop 变了就重画预览（返回时已画好）
      async write(profile) {
        if ("name" in profile) name.value = profile.name;
        if ("handle" in profile) handle.value = profile.handle;
        if (!("avatar" in profile) && !("avatarCrop" in profile)) return;
        avatar = {
          src: profile.avatar ?? avatar.src,
          crop: "avatarCrop" in profile ? profile.avatarCrop ?? null : avatar.crop,
        };
        await showAvatar();
      },
      // 头像的读写（换头像、裁剪头像的对话框用，src/media/media.js）：{ src, crop }；换好后同样通知重新出图
      avatar: {
        get() {
          const { avatar: src, avatarCrop: crop } = api.read();
          return { src, crop };
        },
        async set({ src, crop }) {
          await api.write({ ...(src ? { avatar: src } : {}), avatarCrop: crop });
          onInput();
        },
      },
    };
    return api;
  }

  root.MediaCraftByline = { create };
})(globalThis);
