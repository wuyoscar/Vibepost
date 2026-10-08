(() => {
  let modules;
  async function library() {
    modules ||= Promise.all([
      import("/__windows/vendor/pdf/pdf.mjs"),
      import("/__windows/vendor/pdf/pdf.worker.mjs"),
    ]).then(([pdf, worker]) => {
      // Use the supported worker module in-process on the custom scheme;
      // browsers do not consistently accept custom-scheme Worker URLs.
      globalThis.pdfjsWorker = worker;
      return pdf;
    });
    return modules;
  }
  window.MediaCraftWindowsPDF = async (blob) => {
    if (blob.size > 50 * 1024 * 1024)
      throw new Error("PDF 超过 50 MB，请分段导入");
    const pdf = await library();
    const task = pdf.getDocument({
      data: new Uint8Array(await blob.arrayBuffer()),
      isEvalSupported: false,
      useSystemFonts: true,
      cMapUrl: "/__windows/vendor/pdf/cmaps/",
      cMapPacked: true,
      standardFontDataUrl: "/__windows/vendor/pdf/standard_fonts/",
      wasmUrl: "/__windows/vendor/pdf/wasm/",
    });
    try {
      const doc = await task.promise;
      if (doc.numPages > 200) throw new Error("PDF 超过 200 页，请分段导入");
      const pages = [];
      for (let i = 1; i <= doc.numPages; i++) {
        const page = await doc.getPage(i);
        const viewport = page.getViewport({ scale: 2 });
        if (viewport.width * viewport.height > 64000000)
          throw new Error("PDF 页面超过 6400 万像素");
        const canvas = document.createElement("canvas");
        canvas.width = Math.ceil(viewport.width);
        canvas.height = Math.ceil(viewport.height);
        await page.render({ canvasContext: canvas.getContext("2d"), viewport })
          .promise;
        const image = await new Promise((resolve, reject) =>
          canvas.toBlob(
            (b) => (b ? resolve(b) : reject(new Error("PDF 页面编码失败"))),
            "image/png",
          ),
        );
        pages.push(image);
        canvas.width = canvas.height = 0;
        page.cleanup();
      }
      return pages;
    } finally {
      await task.destroy();
    }
  };
})();
