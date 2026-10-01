/// 读一张 HTML 卡片上画了什么：每段字与每张图在卡片上的位置（逻辑坐标 864 × 1152）、字号字体与颜色。
/// 舞台上的卡片是按比例缩小的，按页面框换算回逻辑坐标；没挂在页面上的卡片（render.offscreen 的）临时挂到屏幕外原大量。
enum CardDomProbe {
    static let script = """
        window.cardDom = (host) => {
          let shelf = null;
          if (!host.isConnected) {
            shelf = document.createElement("div");
            Object.assign(shelf.style, { position: "fixed", left: "-40000px", top: "0", width: "864px", height: "1152px" });
            Object.assign(host.style, { width: "864px", height: "1152px" });
            shelf.append(host);
            document.body.append(shelf);
          }
          try {
            const page = host.shadowRoot.querySelector(".mc-page");
            const frame = page.getBoundingClientRect();
            const scale = frame.width / 864;
            // 换算回逻辑坐标，取到 0.01（缩放带来的误差不算）
            const round = (value) => Math.round(value * 100) / 100;
            const box = (element) => {
              const rect = element.getBoundingClientRect();
              return {
                left: round((rect.left - frame.left) / scale),
                top: round((rect.top - frame.top) / scale),
                width: round(rect.width / scale),
                height: round(rect.height / scale),
              };
            };
            const hex = (color) => "#" + (color.match(/\\d+(\\.\\d+)?/g) ?? []).slice(0, 3)
              .map((value) => Math.round(Number(value)).toString(16).padStart(2, "0")).join("");
            const texts = [];
            const images = [];
            for (const element of page.querySelectorAll("*")) {
              const style = getComputedStyle(element);
              if (style.display === "none" || style.visibility === "hidden") continue;
              if (element.tagName === "IMG") {
                const { left, top, width, height } = box(element);
                images.push({ kind: "image", src: element.getAttribute("src") ?? "", args: [left, top, width, height] });
                continue;
              }
              const own = [...element.childNodes].filter((node) => node.nodeType === 3).map((node) => node.textContent).join("").trim();
              if (!own) continue;
              const { left, top, width, height } = box(element);
              texts.push({
                kind: "text",
                tag: element.tagName.toLowerCase(),
                block: element.closest("p, h1, h2, h3, h4, li, blockquote, td, th")?.tagName.toLowerCase() ?? "",
                text: element.textContent.trim(),
                x: left, y: top + height / 2, left, top, right: left + width, bottom: top + height,
                size: Number.parseFloat(style.fontSize),
                font: `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`,
                color: hex(style.color),
              });
            }
            return [...texts, ...images];
          } finally {
            if (shelf) {
              host.remove();
              host.style.removeProperty("width");
              host.style.removeProperty("height");
              shelf.remove();
            }
          }
        };
        // 舞台上的每张卡片（从第 1 页起）
        window.stageCards = () => [...document.querySelectorAll("#stageCards .card-frame > .mc-card-host")];
    """
}
