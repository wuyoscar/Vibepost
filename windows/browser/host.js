(() => {
  const platform = document.documentElement;
  platform.dataset.platform = "windows";
  if (!document.querySelector("#windows-fonts")) {
    const link = document.createElement("link");
    link.id = "windows-fonts";
    link.rel = "stylesheet";
    link.href = "/fonts/fonts.css";
    document.head.appendChild(link);
  }
})();
