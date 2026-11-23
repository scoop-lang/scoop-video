# Scoop Video

`scoop.ui.video` 是用于 macOS 的 Scoop UI 视频组件。它直接采样 AVPlayer 交付的 NV12 IOSurface，在 UI Canvas 上绘制画面和播放控件。支持现有的本地 8-bit SDR、视频范围 BT.709 路径。

## 运行 demo

在 macOS 图形会话中，使用已安装的 Scoop 工具链，从仓库根目录运行。

```sh
scoop run
scoop run --release -- scoop.ui.video/tests/data/video.mp4
```

第一条命令打开带“打开视频…”按钮的窗口。第二条命令直接播放仓库内的一秒测试片，把路径换成自己的本地文件即可。按钮可以更换视频，画面左下角的控件支持暂停、继续和片尾重播。聚焦播放按钮后也可以按空格。文件打开失败时，窗口显示原因，可以重新选择。[Demo 源码](demo/src/main.scoop)

## 在其他 UI 中使用

在消费方的 `Cone.toml` 中添加组件库的相对路径，并在 Scoop 组件的 `render()` 中直接返回一个 `View`。

```toml
[dependencies]
"scoop:scoop.ui.video" = { path = "../scoop-video/scoop.ui.video", version = "0.1.0" }
```

```scoop
import scoop.platform.fs.Path
import scoop.ui.*
import scoop.ui.video.*

class Movie(private val source: Path, scope: ComponentScope) : Component(scope) {
    public override fun render(): View = videoPlayer(source)
}
```

默认自动播放、等比缩放，显示播放按钮和进度条。父组件以同一路径重新渲染会保留播放位置，传入新路径会从新文件的开头播放。卸载组件时自动释放播放器和帧资源。

需要自定义按钮时，在父组件中保留一个 `VideoController`，通过 `videoPlayer(controller)` 挂载。控制器在 UI 线程上使用，同一时刻绑定一个视图。下例让视频初始暂停，并由宿主提供按钮。

```scoop
import scoop.ui.component.*

class CustomMovie(source: Path, scope: ComponentScope) : Component(scope) {
    private val player = VideoController(source, autoPlay = false)

    public override fun render(): View {
        val video = player
        return column {
            button("播放 / 暂停", { video.toggle() })
            item(videoPlayer(video) { showControls = false }) { grow = 1.0 }
        }
    }
}
```

| API | 行为 |
| --- | --- |
| `play()`、`pause()`、`toggle()` | 可以在挂载前设置播放意图。到达片尾后调用 `play()` 会从头重播。 |
| `playbackState`、`progress` | 读取 UI 线程上的当前快照。状态为 `Playing`、`Paused`、`Ended` 或 `Failed`，进度范围为 0 到 1。 |
| `showControls`、`autoFocus` | 控制内置按钮和进度条，或在挂载时为按钮请求键盘焦点。默认显示控件，由宿主决定初始焦点。 |
| `onEnded`、`onError` | 每次播放结束或打开失败时在 UI 线程回调。错误回调收到原因字符串，默认交给宿主的 UI 错误处理。 |

## 工作区与验证

| 成员 | 用途 |
| --- | --- |
| `scoop.ui.video` | 可被其他 Cone 依赖的库。封装原生播放器、双平面生命周期、着色器和 UI 绘制。 |
| `demo` | 工作区默认运行的示例。使用组件库的公开接口、Scoop 按钮和系统文件选择器。 |
| `probes/ui` | 挂载同一组件的 4K60 采集程序，负责固定采集窗口、CSV 和单帧 Metal capture。 |

```sh
scoop build --workspace --release
scoop test --workspace --release
```

组件的窗口测试使用内置的 1 秒 H.264 测试片，覆盖初始暂停、播放控制、片尾重播、切换文件和打开失败回调。

独立 Skia 基线保存在 `probes/skia`。原始 trace 与日志保存在本机的 `artifacts/`，重录步骤和逐帧数据见两份实测记录。[UI 合成](docs/ui-trace.md) · [独立 Skia](docs/skia-trace.md)
