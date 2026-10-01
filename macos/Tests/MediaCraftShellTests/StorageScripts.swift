/// 测试直接读写本机存储用的页面脚本，布局以 docs/storage.md 为准。
/// 只用来检查「存下来的样子」、或在 App 启动前准备数据（这版之前存下的稿子、上千篇稿子）；平时一律走 App API 与界面。
enum StorageScripts {
    /// `readStore(名, 键?)`：读新存储里的一条或整个表。只在 App 已经启动后用（库不存在时会建出空库）。
    static let read = """
        window.idbRequest = (request) => new Promise((resolve, reject) => {
          request.onsuccess = () => resolve(request.result);
          request.onerror = () => reject(request.error);
        });
        window.readStore = async (name, key) => {
          const db = await idbRequest(indexedDB.open("mediacraft"));
          try {
            const store = db.transaction(name).objectStore(name);
            return await idbRequest(key === undefined ? store.getAll() : store.get(key));
          } finally {
            db.close();
          }
        };
        window.writeStore = async (name, records) => {
          const db = await idbRequest(indexedDB.open("mediacraft"));
          try {
            const tx = db.transaction(name, "readwrite");
            records.forEach((record) => tx.objectStore(name).put(record));
            await new Promise((resolve, reject) => { tx.oncomplete = resolve; tx.onerror = () => reject(tx.error); });
          } finally {
            db.close();
          }
        };
        window.databaseNames = async () => (await indexedDB.databases()).map((db) => db.name);
    """

    /// `seedStore({ drafts, meta })`：App 启动前按 docs/storage.md 建好新存储并写入。
    static let seed = read + """
        window.seedStore = async ({ drafts = [], meta = [] }) => {
          const open = indexedDB.open("mediacraft", 1);
          open.onupgradeneeded = () => {
            const db = open.result;
            db.createObjectStore("drafts", { keyPath: "id" });
            db.createObjectStore("media", { keyPath: "key" }).createIndex("draftId", "draftId");
            db.createObjectStore("meta", { keyPath: "key" });
          };
          const db = await idbRequest(open);
          const tx = db.transaction(["drafts", "meta"], "readwrite");
          drafts.forEach((record) => tx.objectStore("drafts").put(record));
          meta.forEach((record) => tx.objectStore("meta").put(record));
          await new Promise((resolve, reject) => { tx.oncomplete = resolve; tx.onerror = () => reject(tx.error); });
          db.close();
        };
    """
}
