# LivePhotoForge

把视频转成 Apple Live Photo 的 macOS 应用。**视频轨不重新编码，输出码流与源片段逐字节一致。**

转好的实况照片会直接写入「照片」App，并通过 iCloud 同步到 iPhone。无时长限制、无次数限制、无水印，全程离线处理。

## 为什么做这个

大多数视频转实况工具都会重新编码视频，4K 素材转完画质会明显下降。LivePhotoForge 只重新封装容器，把原始 H.264 / HEVC 码流原样搬进 Live Photo 所需的 MOV 文件。

这不是一句宣传语，可以用 ffmpeg 自己验证：

```bash
ffmpeg -v error -ss 10 -t 5 -i 源视频.mov -map 0:v:0 -c copy -f md5 -
ffmpeg -v error -i 输出.mov -map 0:v:0 -c copy -f md5 -
```

两行输出的 MD5 相同。

## 功能

- **拖入即用**：支持 MP4、MOV、M4V，打开后显示分辨率、帧率、编码，并标出「无损直通」或「需重编码」
- **选片段**：拖动时间轴选区、拖两端调整长度，或直接输入起点、终点时间
- **时长预设**：1.5 秒、3 秒、5 秒、10 秒
- **关键帧辅助**：刻度尺标出所有关键帧，可以一键跳到上一个或下一个关键帧
- **预览**：画面跟随起点或终点，可以只播放选中的片段
- **自动选封面**：在片段里挑出最清晰的一帧作为静态封面
- **精确裁剪**：需要从任意帧切开时可以开启，代价是视频轨会重新编码
- **写入照片图库**：分阶段显示进度，完成后可以一键在「照片」中查看；失败时会说明是哪一步出了问题

## 使用前需要知道的三点

1. **封面图不是比特级无损。** Live Photo 的封面必须是 HEIC 或 JPEG，从视频抽帧必然要重新编码。默认使用最高质量 HEIC，视觉上无损。
2. **片段起点会吸附到关键帧。** 不重新编码时只能从关键帧切开，所以松开选区后起点会对齐到前一个关键帧，时长保持不变。确实需要精确到某一帧，就开启「精确裁剪」。
3. **4K 实况分享出去会被压缩。** 存在本地相册里没问题，但发到微信、小红书等平台时，对方服务器会重新压缩。

## 系统要求

- macOS 13 或更高版本，推荐 Apple Silicon
- Swift 6 工具链。只需要安装 Command Line Tools，不需要完整 Xcode

```bash
xcode-select --install
```

## 构建与运行

```bash
git clone https://github.com/xLuckww/LivePhotoForge.git
cd LivePhotoForge
./Scripts/build-app.sh
open build/LivePhotoForge.app
```

构建脚本会编译程序，把它组装成 `.app`，并做 ad-hoc 签名。首次写入照片图库时，系统会请求权限，允许即可。

## 使用步骤

1. 把视频拖进窗口，或者点击「选择视频」
2. 在底部时间轴上选择片段，或者在右侧栏选择时长
3. 点击播放按钮，确认片段内容
4. 点击右上角「生成 Live Photo」
5. 生成完成后，点击「在照片中显示」

## 命令行工具

项目还包含一个命令行工具 `lpforge`，适合批量处理和验证结果。

```bash
swift build -c release
.build/release/lpforge convert 视频.mov --start 0:11 --duration 5
```

| 命令 | 用途 |
|---|---|
| `inspect <视频>` | 查看视频信息和转换模式 |
| `keyframes <视频>` | 列出关键帧位置 |
| `convert <视频> [选项]` | 转换并写入照片图库 |
| `verify <mov> [封面]` | 检查输出文件里的 Live Photo 元数据 |
| `frames <视频> --at <秒>` | 连续抽帧，验证帧定位是否精确 |
| `stress <视频>` | 连续转换多次，观察内存占用 |
| `timecode` | 运行时间码解析自测 |

`convert` 常用选项：

| 选项 | 说明 |
|---|---|
| `--start` | 起点，支持 `12.5` 或 `1:02.5` 写法 |
| `--duration` | 时长，默认 3 秒 |
| `--cover` | 封面时间点，或使用 `auto` 自动挑选 |
| `--format` | 封面格式，`heic` 或 `jpeg` |
| `--precise` | 精确裁剪，会重新编码视频轨 |
| `--no-audio` | 不保留音轨 |
| `--no-import` | 只生成文件，不写入照片图库 |
| `--out` | 输出目录 |

## 工作原理

Live Photo 由一张静态图和一段 MOV 视频组成，系统通过同一个 UUID 把两者识别为一组：

1. 静态图的 Apple Maker Note 键 `17` 中写入 UUID
2. MOV 的 `com.apple.quicktime.content.identifier` 元数据写入同一个 UUID
3. MOV 额外包含一条 `com.apple.quicktime.still-image-time` 定时元数据轨，标记封面在视频中的位置

视频部分使用 `AVAssetReader` 和 `AVAssetWriter`，两端的 `outputSettings` 都设为 `nil`，因此只搬运样本，不解码也不重新编码。这里没有使用 `AVAssetExportSession`，因为它无法写入自定义的定时元数据轨。

最后通过 `PHAssetCreationRequest` 把图片和视频作为同一个资产写入图库，并检查结果是否包含 `.photoLive`。

## 项目结构

```
Sources/
├── LivePhotoForgeCore/        核心库，不依赖界面
│   ├── VideoInspector         解析视频，判断能否无损直通
│   ├── KeyframeIndex          查找关键帧，计算片段吸附位置
│   ├── CoverFrameExtractor    精确抽帧，写入带 Maker Note 的封面
│   ├── SharpnessScorer        用拉普拉斯方差评估清晰度
│   ├── LivePhotoVideoWriter   无损封装视频并写入 Live Photo 元数据
│   ├── PhotoLibraryImporter   写入照片图库
│   ├── LivePhotoForge         串联整个转换流程
│   └── Timecode 等            基础类型和工具
├── LivePhotoForgeApp/         SwiftUI 界面
│   ├── AppModel               界面状态和交互逻辑
│   ├── ContentView            窗口布局、顶栏、空状态
│   ├── PreviewMonitor         预览画布、进度和结果浮层
│   ├── InspectorSidebar       右侧栏
│   ├── TimelineDock           底部时间轴
│   └── Theme                  颜色和控件样式
└── lpforge/                   命令行工具
```

更完整的技术方案见 [LivePhotoForge-开发方案.md](LivePhotoForge-开发方案.md)，验证数据见 [docs/阶段一验证报告.md](docs/阶段一验证报告.md)。

## 开发状态

已完成：

- [x] 无损封装和 Live Photo 元数据写入
- [x] 写入照片图库并检查识别结果
- [x] 时间轴选片段、关键帧吸附、精确裁剪
- [x] 视频预览和自动选封面

计划中：

- [ ] 手动逐帧选择封面
- [ ] 批量队列
- [ ] 偏好设置，例如封面格式、是否保留音轨、默认时长
