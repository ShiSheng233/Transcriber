# 发版 SOP

Transcriber 以 Developer ID 签名 + 公证的 zip 发布在 GitHub Releases，并通过 Homebrew tap（`ShiSheng233/homebrew-tap`）分发：

```sh
brew install --cask shisheng233/tap/transcriber
```

App 不带模型；用户在设置里指定模型目录（默认 `~/Library/Application Support/Transcriber/Models`）。

## 一次性准备

| 项目 | 做法 |
| --- | --- |
| Xcode 账号 | Xcode ▸ Settings ▸ Accounts 登录 Team K43V8XURBW（需 Account Holder / Admin，才能用云端管理的 Developer ID 证书；钥匙串里不需要证书） |
| 公证凭据 | 在终端运行 `xcrun notarytool store-credentials transcriber-notary --apple-id <Apple ID> --team-id K43V8XURBW`，密码填 account.apple.com 生成的 App 专用密码 |
| GitHub CLI | `gh auth login`，对 `ShiSheng233/Transcriber` 有写权限 |
| Tap 仓库 | `git clone git@github.com:ShiSheng233/homebrew-tap.git ../homebrew-tap`（与本仓库同级；其他位置用 `TAP_DIR=...`） |
| 依赖 | `TranscriberKit/Vendor/` 下已有 whisper 与 FFmpeg xcframework（`make whisper-xcframework ffmpeg-xcframeworks`） |

## 每次发版

1. **改版本号**：Xcode ▸ Target ▸ General，`Version`（`MARKETING_VERSION`）改为新版本，`Build`（`CURRENT_PROJECT_VERSION`）加 1。Debug 和 Release 必须一致，`make release` 会检查。
2. **提交**：`git commit -am "Release <version>"`。
3. **构建、签名、公证**：
   ```sh
   make release
   ```
   依次执行：
   | 目标 | 内容 | 产物 |
   | --- | --- | --- |
   | `release-archive` | Release 配置 archive，使用独立的 `build/DerivedData` | `build/Transcriber.xcarchive` |
   | `release-export` | 按 `ExportOptions.plist`（developer-id）导出并以 Developer ID 重签 | `build/export/Transcriber.app` |
   | `release-notarize` | 提交公证并等待，确认状态为 Accepted，staple，Gatekeeper 校验，打最终 zip | `build/Transcriber-<version>.zip` |
   | `release-cask` | 用 `Packaging/transcriber.rb.in` 生成 cask，填入版本和 SHA-256 | `build/transcriber.rb` |

   公证一般几分钟，账号首次提交可能要几十分钟到数小时。`release-notarize` 最多等 2 小时；被拒时会打印 Apple 的日志，指出出问题的文件。
4. **验收**（发布前手动）：
   - `spctl -a -vv build/export/Transcriber.app` 显示 `accepted` / `source=Notarized Developer ID`
   - 解压 `build/Transcriber-<version>.zip` 到别处，双击打开不出现 Gatekeeper 警告，能列出模型、跑一个短文件
5. **发布**：
   ```sh
   make release-publish
   ```
   推送当前提交 → 创建 `v<version>` 的 GitHub Release 并上传 zip（自动生成 release notes）→ 把 cask 复制到 tap 的 `Casks/transcriber.rb`、提交并推送。
6. **确认**：
   ```sh
   brew update
   brew upgrade --cask transcriber   # 或首次安装：brew install --cask shisheng233/tap/transcriber
   brew audit --cask shisheng233/tap/transcriber
   ```

## 只导出 Xcode 里做好的 archive

在 Organizer 里 archive 后，可以跳过 `release-archive`：

```sh
make release-export RELEASE_ARCHIVE="$HOME/Library/Developer/Xcode/Archives/<日期>/Transcriber <时间>.xcarchive"
make release-notarize release-cask
```

## 常见问题

- **Xcode 提示 “Transcriber couldn’t be removed because you don’t have permission”**：命令行 archive 写进了 Xcode 自己的 DerivedData，macOS 不允许 Xcode 删除别的进程构建的 App 包。`make release-archive` 已改用 `build/DerivedData`；遇到旧的残留，在终端 `rm -rf` 报错里的 `ArchiveIntermediates/Transcriber` 目录即可。
- **`spctl` 显示 `Unnotarized Developer ID`**：签名正常，只是还没公证或没 staple，重新跑 `make release-notarize`。
- **发错版本**：删除 GitHub Release 和 tag（`gh release delete v<version> --cleanup-tag`），在 tap 里 revert 对应提交。已经安装的用户需要等下一个版本才会升级。
