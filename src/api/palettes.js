// App API 的 palettes 一组（src/themes/palettes.js）：配色库、我的配色、色轮的配色规则，以及套用到当前稿子。
// 挂在 window.mediacraft.palettes。
(function (root) {
  "use strict";

  const copy = (palette) => ({ ...palette, colors: { ...palette.colors } });

  // app：见 src/app.js；check：src/api/api.js 里共用的校验（fields、colors、editable、current）
  function palettes(app, check) {
    const library = root.MediaCraftPalettes;
    const mine = library.createCollection(root.MediaCraftDrafts.store);

    async function all() {
      return [...library.LIBRARY.map(copy), ...(await mine.list())];
    }

    // apply 的参数 → 要套用的颜色：配色的 id、五个角色里的几个（同 drafts.update 的 colors），或一串色值（按明暗分给五个角色，
    // 按三色规则推出来的辅助、衬底不给，记为没单独调过）。
    async function colorsOf(target) {
      if (typeof target === "string") {
        const palette = (await all()).find((item) => item.id === target);
        if (!palette) throw new Error(`没有这组配色：${target}`);
        return palette.colors;
      }
      if (Array.isArray(target)) return library.explicitColors(library.fromHexList(target));
      check.colors(target, "palettes.apply：");
      return target;
    }

    // 配色落到这篇上：撤销历史里的一步（⌘Z 撤回；颜色与「单独调过」的标记一起），出图并存盘；色轮的预览随之结束。
    async function apply(colors) {
      check.editable();
      app.setColorPreview(null);
      const { colors: before, tunedColors: tunedBefore } = app.styleForm.read();
      const after = library.complete(colors, { colors: before, tunedColors: tunedBefore });
      if (!library.same(before, after.colors) || tunedBefore.join() !== after.tunedColors.join()) {
        app.editor.edit({
          fields: [
            { field: "colors", before, after: after.colors },
            { field: "tunedColors", before: tunedBefore, after: after.tunedColors },
          ],
        });
      }
      await app.pipeline.now();
      await root.MediaCraftDrafts.flush();
      return check.current();
    }

    return {
      // 内置的按分类在前，我的配色在后
      list: all,
      // 与点配色库里的一格相同：套用到当前稿子，是撤销历史里的一步。
      async apply(target) {
        return apply(await colorsOf(target));
      },
      // 当前稿子的五个颜色存进「我的配色」
      async save(name) {
        if (name !== undefined && typeof name !== "string") throw new TypeError("名字需要是字符串");
        return mine.save(name, app.styleForm.read().colors);
      },
      async remove(id) {
        if (library.LIBRARY.some((item) => item.id === id)) throw new Error("内置的配色不能删");
        await mine.remove(id);
      },
      // 基准色 + 配色规则 → 五个角色与对比度报告（纯函数，不改稿子）
      async harmony(options) {
        return library.harmony(options);
      },
      // 舞台先换成这组颜色看看（不改稿子、不存盘、不进撤销历史）；null 回到稿子自己的配色。换主题、换稿子、套用配色时自动结束。
      async preview(colors) {
        if (colors === null) {
          app.setColorPreview(null);
        } else {
          check.colors(colors, "palettes.preview：");
          app.setColorPreview(library.complete(colors, app.styleForm.read()));
        }
        await app.pipeline.now();
      },
    };
  }

  (root.MediaCraftApi ||= {}).palettes = palettes;
})(window);
