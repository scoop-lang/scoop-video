# 独立 Skia 基线

在 Apple M4 Pro 上，Scoop 随附的 Skia Ganesh 可以直接采样 AVPlayer 交付的 NV12 IOSurface。9 秒 4K60 素材的 540 个连续源帧各用一个 render pass 写入最终的 BGRA drawable。播放器进程内未观察到视频像素的 CPU 读回、上传、blit 或额外的 BGRA 转换。

## 实测

2026-11-24，Mac mini，Apple M4 Pro（20 核 GPU），macOS 27.2.1（26B131），Xcode/Instruments 27.2（27B52）。验证程序是 AppKit + Objective-C++，链接 `~/.scoop` 中 `0.0.0-dev.20261123` 的 `libscoop_skia.a`，只读使用同一版本的 Skia 头文件。固定的 Skia revision 为 `f326a1e25fc736704063922b9ce76b527b1c5efe`。

输入是 10 秒 H.264 High，3840×2160、60/1 fps、8-bit SDR、BT.709 limited，带 48 kHz AAC 音轨，播放时静音。测量媒体时间为 [0, 9) 秒。解码尺寸和 drawable 都为 3840×2160，窗口大小为 800×450 pt，物理显示器为 2560×1600。[测试视频](../artifacts/source-4k60.mp4)

| 要核对的环节 | 观测 |
| --- | --- |
| 解码器 → AVPlayer | AppleAVD 日志显示 3840×2160 H.264 硬解，输出为 `420v`。独立检测中，CoreMedia 从解码服务 XPC 收到 19 个不同的 NV12 IOSurface，540 帧全部命中这组 ID。 |
| AVPlayer → Metal | 每帧的平面 0 是 3840×2160 的 `R8Unorm`，平面 1 是 1920×1080 的 `RG8Unorm`。两个 `MTLTexture` 的 `iosurface` 均等于 AVPlayer 交付的缓冲，`iosurfacePlane` 分别为 0、1。 |
| Metal → Skia → drawable | 系统 trace 中有 540 个 render encoder。逐帧匹配 encoder ID、command buffer ID 与 IOSurface ID，540/540 都是同一 encoder 读取该帧的 NV12、写入该帧的最终 drawable。3 个 drawable 循环使用。GPU 活动只有 Vertex、Fragment。 |
| YUV → RGB 的位置 | PTS 3.000 秒的单帧捕获中，Skia 生成的片元着色器在纹理槽 0 取 Y、槽 1 取 UV，同一着色器执行有限范围的 YUV 矩阵与颜色空间变换，直接写颜色附件。额外 BGRA render pass、blit 和 compute 均为 0。 |
| 节奏与提交 | 9 秒内提交 540 个连续 PTS。媒体时间 [2, 8) 秒内 360 帧，按开始绘制时的主机时钟测得 60.04 fps。另有 540 个只做 present 的 command buffer，每个含 0 个 encoder。Core Animation 记录了 540 个 present 请求，进程退出前收到 539 个 presented-handler 事件。 |

原始系统录制可用 Instruments 打开，单帧捕获可用 Xcode 打开。逐帧对照表记录了每个 PTS 对应的源、目标和命令编号。[Metal System Trace](../artifacts/playback.trace) · [单帧 GPU capture](../artifacts/frame.gputrace) · [捕获的片元着色器](../artifacts/captured-fragment.metal) · [逐帧对照](../artifacts/encoder-frames.csv) · [解码器日志](../artifacts/decoder.log)

### CPU 是否碰过像素

在另一轮播放中，从进程启动时记录 Core Video、IOSurface、VideoToolbox 的相关入口，以及视频纹理实际类型的两组 Metal `getBytes` 和 `replaceRegion` 方法。对 540 帧得到 1,080 个平面纹理，全部覆盖。视频尺寸的 `CVPixelBufferLockBaseAddress`、两个 CVPixelBuffer 基址入口、`IOSurfaceLock`、`IOSurfaceGetBaseAddress`、Metal 读回和上传、`VTPixelTransferSessionTransferImage` 计数均为 0。独立正对照对合成的视频纹理读写像素并执行一次 VideoToolbox 传输，各组计数器均有命中。[逐项计数](../artifacts/summary.json) · [正对照日志](../artifacts/control.log)

系统库确实调用了 9,966 次 `IOSurfaceGetBaseAddressOfPlane`。8,804 次来自 AGX 计算 GPU 虚拟地址，1,080 次来自 AVPlayer 的像素缓冲属性兼容性检查，其余 82 次来自纹理创建、XPC 缓冲包装和 drawable 对齐检查。完整调用栈与同一 IOSurface 的逐帧匹配都指向地址和布局处理。观测范围涵盖解码服务交付到应用绘制的公开接口与可见 GPU 命令，驱动内部的物理内存访问不在这两种 trace 的可观测范围内。[调用栈及解码服务 IOSurface ID](../artifacts/audit.log) · [检测轮逐帧记录](../artifacts/audit-frames.csv) · [Apple 对 CPU 像素访问的说明](https://developer.apple.com/documentation/corevideo/cvpixelbufferlockbaseaddress%28_%3A_%3A%29)

## 接入点

`AVPlayerItemVideoOutput` 请求带 IOSurface 且兼容 Metal 的 `420v`，关闭 AVPlayer 自身绘制。显示回调按播放器时钟取新帧。渲染线程通过 `CVMetalTextureCacheCreateTextureFromImage` 创建两个平面视图，用 `GrYUVABackendTextures(kY_UV, k420)` 和 `SkImages::TextureFromYUVATextures` 借用它们，由普通的 `SkCanvas::drawImage` 绘制。原始 `CVPixelBuffer` 和两个 `CVMetalTexture` 一起保留到 Skia 的 release proc。每帧异步提交，退出时统一等待 GPU。[播放器](../probes/skia/main.mm) · [平面导入与绘制](../probes/skia/Renderer.mm) · [Apple 平面映射与生命周期](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage%28_%3A_%3A_%3A_%3A_%3A_%3A_%3A_%3A_%3A%29) · [固定版本的 Skia 接口](https://github.com/google/skia/blob/f326a1e25fc736704063922b9ce76b527b1c5efe/include/gpu/ganesh/SkImageGanesh.h#L243-L260)

这项基线的入口是独立 AppKit 窗口中的 Skia Canvas。后续的 Scoop UI 播放器分别对 Y 和 UV 调用现有的 `GpuDevice.importImage`，由 Canvas 着色器组合两个输入。[UI 实现](../scoop.ui.video/src/planes.scoop) · [Scoop 导入接口](../../scoop/sysroot/src/scoop.graphics/src/native/gpu_device.scoop#L57)

## 复现

需要有 Metal GPU 的 macOS 图形会话、完整 Xcode、Scoop GUI 工具链和匹配的 Skia 头文件。生成素材使用带 libx264 的 FFmpeg。可以用环境变量 `FFMPEG` 指定可执行路径。Makefile 优先使用工具链头文件，本机从相邻的 `../scoop/sysroot/lib/<target>/include/skia` 读取。其他布局可以设置 `SKIA_HEADERS`。

```sh
export PATH="$HOME/.scoop/bin:$PATH"
make all audit
# Run once to generate the input clip.
sh scripts/make-clip.sh

out=$(mktemp -d "$PWD/artifacts/run.XXXXXX")
clip="$PWD/artifacts/source-4k60.mp4"
probe="$PWD/build/nv12-probe"

xcrun xctrace record --no-prompt --template 'Metal System Trace' \
  --output "$out/playback.trace" --time-limit 22s \
  --target-stdout "$out/traced-process.log" \
  --launch -- "$probe" "$clip" "$out/playback-frames.csv"

MTL_CAPTURE_ENABLED=1 "$probe" "$clip" "$out/capture-frames.csv" \
  "$out/frame.gputrace" >"$out/capture.log" 2>&1

DYLD_INSERT_LIBRARIES="$PWD/build/cpu-access.dylib" \
  ./build/audit-control >"$out/control.log" 2>&1
NV12_CPU_STACKS=1 DYLD_INSERT_LIBRARIES="$PWD/build/cpu-access.dylib" \
  "$probe" "$clip" "$out/audit-frames.csv" >"$out/audit.log" 2>&1

python3 scripts/check-trace.py "$out"
```

四个进程依次运行。正常播放的帧率来自系统 trace。单帧捕获会归档 GPU 资源，本机该轮提交了 532 帧。检查脚本从原始 trace 导出数据，在当前 Instruments 版本上核对帧与 GPU 资源，输出 JSON 摘要、CSV 对照表和捕获的 Metal 着色器。视频、完整 trace 和日志保存在本地 `artifacts/`，Git 收录源码与复现说明。
