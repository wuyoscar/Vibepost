// 导入图片与 PDF：先按文件名自然排序（「图2」排在「图10」前面），PDF 交给原生壳每页渲染成一张 PNG。
// 只把文件读成图片素材（名字 + data URL），写进稿子由调用方做。
(() => {
  const collator = new Intl.Collator("zh-Hans-CN", { numeric: true, sensitivity: "base" });
  const IMAGE_EXTENSION = /\.(png|jpe?g|gif|webp|heic|heif|avif|bmp|tiff?)$/i;

  const isPdf = (file) => file.type === "application/pdf" || /\.pdf$/i.test(file.name || "");
  const isImage = (file) => file.type.startsWith("image/") || IMAGE_EXTENSION.test(file.name || "");

  // 拖动的内容里有没有文件（拖文字、拖图片卡片时没有）
  const hasFiles = (transfer) => Array.from(transfer?.types || []).includes("Files");

  function readAsDataUrl(blob) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(reader.error ?? new Error("文件读取失败"));
      reader.readAsDataURL(blob);
    });
  }

  // 浏览器解不开的图（比如损坏的文件）不插进稿子
  async function decodable(blob) {
    try {
      (await createImageBitmap(blob)).close();
      return true;
    } catch {
      return false;
    }
  }

  async function pdfPages(file) {
    const native = window.MediaCraftNative;
    if (!native?.pdfToImages) throw new Error("PDF 要在 Vibepost App 里导入（浏览器里没有 PDF 渲染）");
    const stem = (file.name || "PDF").replace(/\.pdf$/i, "") || "PDF";
    const pages = await native.pdfToImages(file);
    return Promise.all(pages.map(async (page, index) => ({ name: `${stem}-第${index + 1}页.png`, src: await readAsDataUrl(page) })));
  }

  // files → { images: [{ name, src }], problems: [说明] }，images 按文件名排好、PDF 按页序展开
  async function readImages(files) {
    const sorted = Array.from(files).sort((a, b) => collator.compare(a.name || "", b.name || ""));
    const images = [];
    const problems = [];
    for (const file of sorted) {
      try {
        if (isPdf(file)) images.push(...await pdfPages(file));
        else if (!isImage(file)) problems.push(`「${file.name}」不是图片或 PDF`);
        else if (!await decodable(file)) problems.push(`「${file.name}」打不开`);
        else images.push({ name: file.name || "图片.png", src: await readAsDataUrl(file) });
      } catch (error) {
        problems.push(error.message);
      }
    }
    return { images, problems };
  }

  // 图片编号：英文字母、数字、_ 和 -（[[image:编号]] 只认这些字符）。长度固定为 23 个字符，
  // 同一段正文的源码偏移就不随时间变（卡片像素基准里记着落点的源码范围）。
  function newImageId() {
    const random = crypto.randomUUID().replaceAll("-", "").slice(-10);
    return `img_${Date.now().toString(36).padStart(8, "0")}_${random}`;
  }

  window.MediaCraftMedia = window.MediaCraftMedia || {};
  window.MediaCraftMedia.importer = {
    DEFAULT_LAYOUT: Object.freeze({ align: "center", widthPercent: 100 }),
    hasFiles,
    readImages,
    readAsDataUrl,
    newImageId,
  };
})();
