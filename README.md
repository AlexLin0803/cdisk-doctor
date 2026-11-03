# CDiskDoctor · C 盘空间医生

> 纯 PowerShell 实现的 Windows 磁盘空间诊断 / 清理 / 迁移工具。无依赖、不联网、不上传任何数据。

C 盘满了怎么办？大多数人只知道"清临时文件"，但真实占空间的往往是 **AppData 里的应用数据**（微信、飞书、剪映、WPS 动辄几个 GB）。
CDiskDoctor 做三件事：

1. **看清** —— 扫描整个 C 盘，告诉你空间到底去哪了
2. **清掉** —— 按白名单清理确定的垃圾，被占用的自动跳过
3. **搬走** —— 把大目录迁到其他盘，原地留软链接，程序照常运行

---

## 快速开始

```
1. 下载本仓库（Code → Download ZIP，或 git clone）
2. 解压到任意目录
3. 右键 Run.cmd → 以管理员身份运行
4. 选 1 生成报告（只读），看清之后再选 3 清理
```

不想用菜单，也可以直接跑：

```powershell
# 分析并生成 HTML 报告（纯只读）
powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode Analyze -OpenReport

# 预览可清理空间（不删任何文件）
powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode Clean -DryRun

# 执行安全清理
powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode Clean -Apply
```

---

## 它清什么、不清什么

### 会清理（白名单）

| 类别 | 内容 | 风险 |
|---|---|---|
| TempUser / TempWindows | 用户与系统临时文件 | 安全 |
| CrashDump | 崩溃转储、WER 错误报告 | 安全 |
| WinLogs | Windows 日志、CBS 日志 | 安全 |
| UpdateCache | Windows 更新下载缓存 | 安全 |
| ThumbCache / IconCache | 缩略图、图标缓存（自动重建） | 安全 |
| UpdaterFiles | 各软件下载完没删的安装包 | 安全 |
| EdgeCache / ChromeCache | 浏览器缓存 | 安全 |
| RecycleBin | 回收站 | **清空后不可恢复** |
| AppCache | 剪映/飞书/WPS/微信等应用缓存 | 需确认 |
| DevCache | npm / pnpm / pip / uv 缓存 | 需确认 |
| Prefetch | 预读取数据 | 需确认 |
| SearchIndex | Windows 搜索索引 | 需确认 |

### 绝不触碰

- 桌面、文档、下载、图片、视频、音乐
- `C:\Windows`、`C:\Program Files`、`C:\ProgramData` 下的程序文件
- 任何不在白名单里的路径

清理时还会**跳过最近 2 天内修改的文件**，避免删掉正在使用的临时文件。

---

## 迁移大目录（核心能力）

AppData 里的大目录可以整体搬到 D/E 盘，原位置留一个 **junction（目录联接）**。
程序仍然按原路径读写，完全无感，但空间实实在在省下来了。

### 第一步：分析哪些能搬

```powershell
powershell -ExecutionPolicy Bypass -File src\Classify.ps1 -MinMB 200 -OpenReport
```

输出四类：

| 分类 | 含义 | 处理方式 |
|---|---|---|
| A 可直接搬 | 独立个人文件 | 直接移动 |
| B 应用数据 | AppData 下的大目录 | 迁移 + 软链接 |
| C 程序本体 | Program Files | 卸载后重装到大盘 |
| D 散落文件 | 下载/安装包残留 | 删除或搬走 |

### 第二步：执行迁移

```powershell
# 单个目录（预览，不执行）
powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode Migrate `
  -Path "C:\Users\你的用户名\AppData\Roaming\SomeApp" -Target "D:\MovedData"

# 确认后加 -Apply 执行
powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode Migrate `
  -Path "C:\Users\你的用户名\AppData\Roaming\SomeApp" -Target "D:\MovedData" -Apply

# 批量迁移
powershell -ExecutionPolicy Bypass -File src\Migrate-All.ps1 `
  -Target "D:\MovedData" -Apply `
  -Paths "C:\Users\你的用户名\AppData\Roaming\AppA,C:\Users\你的用户名\AppData\Roaming\AppB"

# 回滚
powershell -ExecutionPolicy Bypass -File src\Migrate-All.ps1 -Rollback "C:\Users\你的用户名\AppData\Roaming\SomeApp" -Apply
```

迁移流程是 `复制 → 校验文件数 → 重命名源 → 建 junction → 校验 → 删源`。
**任何一步失败都会清理残留并保留源目录**，不会产生半迁移状态。

---

## ⚠️ 迁移前必须关闭程序（注意后台进程）

这是实际使用中最容易踩的坑。关掉主窗口**不等于**关掉了程序，很多软件有常驻后台进程：

| 软件 | 需要结束的进程 |
|---|---|
| WPS | `wps.exe`、`wpscloudsvr.exe` |
| 微信 | `Weixin.exe`、`WeChatAppEx.exe` |
| 飞书 | `Feishu.exe` |
| 剪映 | `JianyingPro.exe`、`JianyingProTray.exe`、`VEDetector.exe` |
| QQ 音乐 | `QQMusic.exe`、`WeChatAppEx.exe`（QQ音乐也带小程序运行时） |
| 夸克网盘 | `quark_cloud_drive.exe` |

迁移器遇到占用会**跳过并保留原目录**，不会损坏数据。关掉进程后重跑即可。

---

## 环境要求

- Windows 10 / 11（x64）
- Windows PowerShell 5.1（系统自带，无需安装）
- 管理员权限（清理系统目录、建 junction 需要）

---

## 常见问题

**Q: 双击 .ps1 没反应 / 提示禁止运行脚本？**
A: Windows 默认禁止运行脚本。请用 `Run.cmd` 入口，或显式加 `-ExecutionPolicy Bypass`。

**Q: 杀毒软件报警？**
A: 任何"批量删除文件"的脚本都可能被启发式引擎误报。本工具全部源码公开，可以逐行审查；建议先跑 `-DryRun` 预览。

**Q: 清理会不会误删我的文件？**
A: 清理只走内置白名单，且排除最近 2 天修改的文件。迁移全程有校验和回滚。**但回收站清空不可恢复**，执行前请确认。

**Q: 迁移后程序还能正常用吗？**
A: 能。junction 对程序完全透明。想还原就用 `-Rollback`。

**Q: 支持 ARM64 / Windows Server 吗？**
A: 未测试。脚本本身不依赖架构，但路径规则可能需要调整。

---

## 修改脚本后务必注意

本项目的 `.ps1` 全部要求 **UTF-8 with BOM**。
Windows PowerShell 5.1 在读取无 BOM 的 UTF-8 文件时会按 GBK 解析，**中文注释会把下一行代码吞进注释里**，导致莫名其妙的语法错误。

编辑后请执行：

```powershell
powershell -ExecutionPolicy Bypass -File tools\Fix-Bom.ps1 -Files .\src\CDiskDoctor.ps1
```

CI 会自动检查 BOM 和语法。

---

## 免责声明

本工具会**删除文件和移动目录**，属于高风险操作。

- 使用前请自行备份重要数据
- 建议先运行 `-Mode Analyze` 和 `-Mode Clean -DryRun` 确认影响范围
- 作者不对任何数据丢失承担责任
- 在生产环境 / 公司电脑上使用前请先评估

## 许可证

[MIT](LICENSE)