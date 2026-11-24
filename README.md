# FileSeeker

macOS 上的本地文件搜索工具，纯 Swift + AppKit + SQLite 单文件实现，无第三方依赖、无网络请求。

起因是找不到一个同时满足「图形化多选筛选 + 按 APFS 落盘时间筛选 + 免费」的现成工具，于是自己写了一个。

## 功能

- **文件名搜索**：输入关键字回车查询，后台线程执行，界面不阻塞。
- **图形化筛选**：文件类型下拉、常用扩展名多选（点组名可整组勾选）、大小区间、创建/落盘时间区间、修改时间区间。
- **扩展名分组**：Word 文档（doc/docx/wps）、表格、演示文稿、PDF/文本、图片、视频、音频、压缩包、代码，共 28 个常用格式；面板内可手动补充其他格式。
- **排序**：点表头按文件名/类型/大小/创建时间/修改时间/路径排序。
- **菜单栏常驻**：`LSUIElement` 无 Dock 图标，状态栏放大镜点击显示/隐藏、右键出菜单；支持原生 `SMAppService` 开机自启。
- **自建索引**：扫描家目录或全盘，跳过系统卷；索引存于 `~/Library/Application Support/FileSeeker/index.db`。

## 性能

95.5 万行索引下，关键字查询约 120–135 ms，无关键字浏览最新文件约 28 ms。

优化点：预存小写冗余列 `name_lc` 避免 `COLLATE NOCASE` 逐字符折叠；去掉触发索引误选的 `ORDER BY`，改为 Swift 侧内存排序；查询在后台队列执行，用 searchSeq 丢弃过期结果。

## 构建

需要 macOS 13+ 与 Swift 6（Xcode Command Line Tools 即可，无需完整 Xcode）：

```bash
git clone https://github.com/LeeeeeeHoooo/FileSeeker.git
cd FileSeeker
chmod +x build.sh
./build.sh
```

`build.sh` 会编译 `main.swift`、组装 `.app`、ad-hoc 签名，产物在 `dist/FileSeeker.app`，直接拖进 `/Applications` 即可。

也可以直接编译二进制：

```bash
swiftc -O main.swift -o fileseeker
```

## 自检

内置隐藏自检分支，验证索引、查询、扩展名面板构建与整组勾选，不进入 GUI 事件循环：

```bash
./fileseeker --selftest
```

## 首次使用

启动后点「重建索引」扫描家目录（约 95 万文件需几分钟）；索引完成后按文件名搜索。右键菜单栏图标可开启「开机自启动」。

## 已知限制

- 静态索引：新文件需手动点「重建索引」，不含 FSEvents 实时增量。
- 索引库含完整路径，属本地数据；仓库不包含任何索引文件。
- 全盘扫描需要「完全磁盘访问」权限，家目录扫描一般不需要。
- 窗口关闭后进程常驻菜单栏，这是预期行为。

## 许可

MIT。详见 [LICENSE](LICENSE)。
