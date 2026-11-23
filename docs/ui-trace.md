# Scoop UI 的 Metal 采集

在仓库根目录运行采集工具。它以独立窗口挂载工作区的 `videoPlayer` 组件。也可以传入本地视频路径。本次验证使用带 BT.709 标记的 8-bit SDR、视频范围 NV12，支持居中或左侧色度采样。窗口保持视频宽高比，左下角的按钮和空格键可以暂停、继续，在片尾可以重播。普通播放保留音轨，采集模式静音。

```sh
make ui
./build/scoop-video-ui artifacts/source-4k60.mp4
```

构建使用 `~/.scoop` 的 `0.0.0-dev.20261123` 预编译库。每当 AVPlayer 交付新帧，bridge 从 `CVMetalTextureCache` 取得属于 UI 设备的两个 Metal 纹理，检查原始 IOSurface、平面索引、尺寸和像素格式。两个纹理共享一个 native owner，它保持 `CVPixelBuffer` 与两个 `CVMetalTexture` 存活到 Skia 的 release 回调。[原生平面与所有权](../scoop.ui.video/native/planes.m) · [AVPlayer 时钟与帧交付](../scoop.ui.video/native/player.m)

Scoop 组件直接使用 `UiHost.attach → Element.scene → SceneContext.draw`。它从这块 Canvas 取得 `GpuDevice`，分别用 `R8` 和 `Rg8` 导入 Y、UV，把两个图像着色器绑定到 SkSL，按有限范围 BT.709 还原 RGB，并输出到 sRGB 目标。第二个 UI 绘制块叠加按钮和进度条。AVPlayer 的时间观察器只在有新帧或播放状态改变时通知 UI，暂停时保留最后的 shader。[UI 场景](../scoop.ui.video/src/view.scoop) · [双平面导入与着色器](../scoop.ui.video/src/planes.scoop)

## 组件拆分后的 4K60 复测

工作区的采集程序通过公开的 `videoPlayer(source)` 挂载组件，测量同一段 H.264 的前 9 秒。源和最终 drawable 都是 3840×2160。系统录制中，539 个不同的源帧对应 539 个 render encoder，每一个都读取该帧的 NV12 IOSurface 并写入它的 present drawable，GPU 通道只有 Vertex 和 Fragment。媒体时间 2.200 秒的源帧未提交，[2, 8) 秒内提交 359 帧，实测 59.87 fps。[Metal System Trace](../artifacts/workspace-ui/playback.trace) · [逐帧核对](../artifacts/workspace-ui/encoder-frames.csv)

媒体时间 3.000 秒的单帧捕获含 Y、UV 双纹理采样和控件着色器。独立 CPU 检测覆盖 540 帧、1,080 个平面视图，视频像素读回和上传接口计数均为 0。额外 BGRA 转换 pass 为 0。唯一的 blit 仍是首个视频帧之前的 48 KiB 矩形索引缓冲。[单帧捕获](../artifacts/workspace-ui/frame.gputrace) · [采样着色器](../artifacts/workspace-ui/captured-fragment.metal) · [计数摘要](../artifacts/workspace-ui/summary.json) · [CPU 调用栈](../artifacts/workspace-ui/audit.log)

## 拆分前的 4K60 实测

以下数据来自拆分工作区前的提交 `ba18c11`。2026-11-24 在 Apple M4 Pro、macOS 27.2.1、Xcode/Instruments 27.2 上采集。输入是 10 秒的 H.264 High、3840×2160、60/1 fps 测试片，测量媒体时间为前 9 秒。AppleAVD 日志记录了 AVC 硬解和 `420v` 输出。采集模式使用固定大小的普通 Scoop 窗口，按屏幕缩放申请 3840×2160 backing。系统 trace 独立确认源和最终 drawable 都是 3840×2160。物理显示器为 2560×1600。[素材](../artifacts/source-4k60.mp4) · [解码器日志](../artifacts/ui/decoder.log)

| 核对项 | 观测 |
| --- | --- |
| UI 提交与资源身份 | 539 个连续视频 PTS，从 1/60 秒到 539/60 秒。539 个 render encoder 均读取 AVPlayer 交付的 NV12 IOSurface，写入该帧 Core Animation 收到 present 请求的 drawable。19 个源 surface 和 3 个 drawable 循环使用。 |
| 转换与 UI 合成 | 539 个视频帧各有一个 render pass，GPU 通道只有 Vertex、Fragment。PTS 3.000 秒的捕获有两个片元程序。视频程序从槽 0 采样 3840×2160 的 Y，从槽 1 采样 1920×1080 的 UV，在写最终 BGRA 颜色附件前完成范围、矩阵和传递函数转换。按钮和进度条使用普通的 UI 颜色程序。没有视频中间 BGRA 纹理、转换 pass 或逐视频帧 blit。 |
| 启动开销 | 视频到来前，UI 提交了两帧，合计三个 render encoder，均只写各自要呈现的 drawable。另有一个 blit，在 GPU 表归到 Compute 通道，访问的 IOSurface 数为零。独立 API 观测记录了 49,152 字节 buffer-to-buffer 拷贝，调用栈为 `FillRectOpImpl → QuadPerEdgeAA → GrResourceProvider::createPatternedIndexBuffer → GrMtlBuffer::onUpdateData`，用于 Skia 的矩形索引缓冲。 |
| CPU 像素路径 | 独立运行的 540 帧、1,080 个平面纹理全部纳入检测。每个视频源 IOSurface 都来自解码服务 XPC 的同一组 19 个 ID。CVPixelBuffer 锁定及基址调用、IOSurface 锁定、Metal `getBytes` / `replaceRegion`、VideoToolbox 像素传输计数均为 0。另一个进程显式读写纹理与传输图像时，这些操作均被检测到。 |
| 地址查询 | 观测到 14,311 次平面基址查询，调用栈分布在 AGX 的 GPU 虚拟地址计算、纹理创建、AVPlayer 的格式兼容性检查和解码器 XPC 包装。另外 6 次整面基址查询对应 3 个 BGRA drawable 的创建和对齐检查。源 NV12 的整面基址查询为 0。 |
| 帧率口径 | 系统录制启动时跳过 PTS 0，后续 539 个视频帧连续。稳态 [2, 8) 秒内 360 帧，按应用开始绘制时刻计为 59.97 fps。含启动 UI 帧在内，共有 541 个 present 请求。关闭时 Surface 的回调记录中有 537 次带实际呈现时间、3 次无时间值。 |

原始录制可分别用 Instruments 和 Xcode 打开。CSV 每行保留源 PTS、读写 IOSurface、render encoder、render 和 present 命令编号。[Metal System Trace](../artifacts/ui/playback.trace) · [单帧 GPU 捕获](../artifacts/ui/frame.gputrace) · [逐帧核对表](../artifacts/ui/encoder-frames.csv) · [视频 MSL](../artifacts/ui/captured-fragment.metal) · [控件 MSL](../artifacts/ui/captured-controls.metal)

像素搬运结论适用于该解码输出、播放器进程内可观测的 CPU 接口、Scoop UI 与 Metal 命令。驱动内部的物理内存事务超出这些工具的观测范围。[计数摘要](../artifacts/ui/summary.json) · [CPU 及启动 blit 调用栈](../artifacts/ui/audit.log) · [正对照](../artifacts/ui/control.log) · [Surface 呈现回调](../artifacts/ui/process.log)

## 重录

在仓库根目录执行。若是新克隆，先以带 libx264 的 FFmpeg 运行 `sh scripts/make-clip.sh` 生成素材。四次运行依次完成，系统录制使用正常播放器，CPU 观测和 GPU 抓帧使用独立进程。

```sh
make ui audit build/blit-audit.dylib
clip="$PWD/artifacts/source-4k60.mp4"
app="$PWD/build/scoop-video-ui"
out=$(mktemp -d "$PWD/artifacts/ui-run.XXXXXX")

xcrun xctrace record --no-prompt --template 'Metal System Trace' \
  --output "$out/playback.trace" --time-limit 24s \
  --target-stdout "$out/process.log" --env SCOOP_SURFACE_FPS=1 \
  --launch -- "$app" "$clip" "$out/playback-frames.csv"

MTL_CAPTURE_ENABLED=1 "$app" "$clip" "$out/capture-frames.csv" \
  "$out/frame.gputrace" >"$out/capture.log" 2>&1

DYLD_INSERT_LIBRARIES="$PWD/build/cpu-access.dylib" \
  ./build/audit-control >"$out/control.log" 2>&1
NV12_CPU_STACKS=1 DYLD_INSERT_LIBRARIES="$PWD/build/cpu-access.dylib:$PWD/build/blit-audit.dylib" \
  "$app" "$clip" "$out/audit-frames.csv" >"$out/audit.log" 2>&1

python3 scripts/check-trace.py "$out"
```
