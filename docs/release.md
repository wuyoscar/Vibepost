# 发版

装好的 Vibepost 经「Vibepost › 检查更新…」（启动时每天也自动看一次）从 GitHub 上这个仓库的 Release 找新版本，所以发版要按这里的约定来。实现在 `macos/Sources/MediaCraftShell/Updater.swift`，界面在 `macos/Sources/MediaCraft/main.swift`。

## 步骤

1. 改仓库根目录的 `VERSION`（只写在这里；`build-app.sh` 把它写进 App 的 Info.plist）。
2. 跑全量测试：`macos/run-tests.sh`。
3. 打 DMG：`scripts/make-dmg.sh`（有 Developer ID 时加 `--sign` / `--notarize`，见脚本开头）。得到
   - `dist/Vibepost-<版本>.dmg`
   - `dist/Vibepost-<版本>.dmg.sha256`
4. 提交、打 tag、推送，建 Release 并附上这两个文件：

   ```bash
   gh release create v<版本> dist/Vibepost-<版本>.dmg dist/Vibepost-<版本>.dmg.sha256 --title "Vibepost <版本>" --notes-file 更新说明.md
   ```

## 约定（App 照这些找新版本）

- tag 是 `v<版本>`，版本号按数字段比较（`0.6.0` > `0.5.10`）；只看最新的那个正式 Release（草稿、预发布不算）。
- 附件名必须是 `Vibepost-<版本>.dmg` 与 `Vibepost-<版本>.dmg.sha256`；少了哪个都不装。
- Release 的正文就是 App 里弹窗显示的「更新说明」（前 600 字）。
- 仓库名写在 App 的 Info.plist（`MCUpdateRepository`，`build-app.sh` 写入，默认 `wuyoscar/Vibepost`）。

## 排障

- 更新器与替换脚本都写 `~/Library/Logs/Vibepost/update.log`（检查到的版本、下载、校验、替换脚本每一步与出错原因）；`log show` 查不到 ad-hoc 签名 App 的 os_log，看这个文件。
- 「在后台下载」期间退出 App，这次准备作废（暂存在 `~/Library/Caches/MediaCraft/update/`，下次启动清掉，再检查会重新下载）。

## App 这边怎么做

- **检查**：先不带凭据问 GitHub API（`/repos/<仓库>/releases/latest`）；私有仓库会回 404，这时借本机登录好的 GitHub CLI（在终端的 PATH 里找 `gh`，用 `gh api` 读 Release、`gh release download` 下载）。没有 `gh` 时说清楚要先 `brew install gh`、`gh auth login`。仓库公开以后不需要 `gh`。
- **核对**：DMG 的 SHA-256 与 `.sha256` 一致 → 只读挂载 → 里面的 `Vibepost.app` 包名是 `com.wuyoscar.mediacraft`、版本号与 tag 一致、`codesign --verify --deep --strict` 通过（现在的 App 用了正式签名时，新 App 还要是同一个开发者团队）→ 拷到 `~/Library/Caches/MediaCraft/update/<版本>/` → 卸载。任一不对就不装，旧版不动。
- **安装**：用户点「现在更新」或之后退出 App 时，先让每个窗口存完稿，再起一个独立的小脚本：等 App 进程结束 → 旧 App 挪进废纸篓（`Vibepost <旧版本>.app`）→ 新 App 放到原来的位置 → 失败就把旧的挪回来 →「现在更新」时再打开它。App 所在的位置不能写时不替换，打开 DMG 让用户自己拖。
- 「跳过这个版本」记在用户偏好（`MCUpdateSkippedVersion`），自动检查不再提它，手动检查照样说。Debug 构建不检查。
