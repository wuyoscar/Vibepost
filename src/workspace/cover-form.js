// 检查器「封面」：首页做封面的开关、副标题、底图。封面的标题取标题框（没填时取正文第一行），版式随主题（src/engine/structures.js）。
// 底图从这篇的图片与实况里挑，也可以另选一张只给封面用的图（进这篇的图片里，不插进正文）。
// 这里只管界面；改了什么由 onChange(cover) 告诉应用，应用存进稿子、出图。
(function (root) {
  "use strict";

  const SUBTITLE_LIMIT = 60;

  // 稿子里存的封面设置 → { enabled, subtitle, image }；旧稿子没有这个字段，按不做封面
  function normalize(value) {
    const cover = value && typeof value === "object" ? value : {};
    return Object.freeze({
      enabled: cover.enabled === true,
      subtitle: typeof cover.subtitle === "string" ? Array.from(cover.subtitle).slice(0, SUBTITLE_LIMIT).join("") : "",
      image: typeof cover.image === "string" && cover.image ? cover.image : null,
    });
  }

  // host：
  //   onChange(cover)            用户改了开关、副标题或底图
  //   importImage(file) → id     另选一张图给封面用：读进这篇的图片（不插进正文），返回图片 id，读不出来时为 null
  function create(host) {
    const $ = (selector) => document.querySelector(selector);
    const toggle = $("#coverToggle");
    const fields = $("[data-cover-fields]");
    const subtitle = $("#coverSubtitleInput");
    const choices = $("#coverImages");
    const upload = $("#coverImageInput");
    let cover = normalize(null);
    let images = {};

    function emit(patch) {
      cover = normalize({ ...cover, ...patch });
      paint();
      host.onChange(cover);
    }

    function choice(id, label, image) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "cover-choice";
      button.dataset.coverImage = id ?? "";
      button.setAttribute("aria-label", label);
      button.title = label;
      if (image?.src) {
        const thumb = document.createElement("img");
        thumb.src = image.src;
        thumb.alt = "";
        button.append(thumb);
      } else {
        button.textContent = "无";
      }
      if (image?.kind === "live") button.classList.add("is-live");
      button.addEventListener("click", () => emit({ image: id }));
      return button;
    }

    // 选项上看得见的（哪几张、缩略图、名字、是不是实况）都没变：调版式、裁剪时不重建缩略图
    const sameChoices = (next) => Object.keys(next).length === Object.keys(images).length
      && Object.entries(next).every(([id, image]) => id in images && ["src", "name", "kind"].every((key) => images[id][key] === image[key]));

    // 这篇的图片变了（插入、删除、换了一篇）：重排底图的选项
    function showImages(next) {
      if (choices.children.length && sameChoices(next)) {
        images = next;
        paint();
        return;
      }
      images = next;
      const buttons = [choice(null, "封面不用底图", null)];
      for (const [id, image] of Object.entries(images)) {
        const kind = image.kind === "live" ? "实况" : "图片";
        buttons.push(choice(id, `封面底图：${kind} ${image.name || id}`, image));
      }
      choices.replaceChildren(...buttons);
      paint();
    }

    function paint() {
      toggle.checked = cover.enabled;
      fields.hidden = !cover.enabled;
      if (document.activeElement !== subtitle) subtitle.value = cover.subtitle;
      const current = cover.image && images[cover.image] ? cover.image : "";
      for (const button of choices.children) button.setAttribute("aria-pressed", String(button.dataset.coverImage === current));
    }

    toggle.addEventListener("change", () => emit({ enabled: toggle.checked }));
    subtitle.maxLength = SUBTITLE_LIMIT;
    subtitle.addEventListener("input", () => emit({ subtitle: subtitle.value }));
    upload.addEventListener("change", async () => {
      const [file] = upload.files;
      upload.value = "";
      if (!file) return;
      const id = await host.importImage(file);
      if (id) emit({ image: id });
    });

    return {
      // 换了一篇、API 改了封面：界面跟上（不通知 onChange）
      write(next) {
        cover = normalize(next);
        paint();
      },
      showImages,
    };
  }

  root.MediaCraftCoverForm = { create, normalize, SUBTITLE_LIMIT };
})(globalThis);
