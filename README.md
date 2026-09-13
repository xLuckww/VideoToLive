# LivePhotoForge

macOS 视频转 Apple Live Photo。视频轨走 passthrough，**比特级无损**。

需求与路线图见 [LivePhotoForge-开发方案.md](LivePhotoForge-开发方案.md)。

## 当前进度

- **阶段一（核心管线）** 已完成并验证，见 [docs/阶段一验证报告.md](docs/阶段一验证报告.md)
- **阶段二（最小界面）** 已完成：拖入 → 一键生成 → 写入图库
- **阶段三（裁剪）** 已完成：时间轴选片段、关键帧竖线、时长预设、精确裁剪开关

封面手动逐帧选择、批量队列、偏好设置尚未开始。

## 结构

```
Sources/LivePhotoForgeCore/
  VideoInspector.swift        解析视频，判定「无损直通 / 需重编码」徽标
  KeyframeIndex.swift         关键帧定位，裁剪吸附与时间轴竖线的依据
  LivePhotoVideoWriter.swift  passthrough 重封装 + 两条 Live Photo 元数据（核心）
  CoverFrameExtractor.swift   帧精确抽帧 + HEIC/JPEG 封面 + Maker Note "17"
  SharpnessScorer.swift       拉普拉斯方差，自动挑最清晰的一帧
  PhotoLibraryImporter.swift  PHAssetCreationRequest 配对写入
  LivePhotoForge.swift        全链路编排与阶段进度回调
Sources/lpforge/              命令行测试入口
```

## 构建

```bash
./Scripts/build-app.sh
```

产物 `build/LivePhotoForge.app`，ad-hoc 签名，双击运行。只要命令行工具，不需要完整 Xcode。

只编译核心库与 CLI：

```bash
swift build -c release
```

## 用法

```bash
lpforge inspect <video>                                 # 解析并显示转换模式徽标
lpforge keyframes <video> [--start 秒] [--duration 秒]   # 列出关键帧位置
lpforge convert <video> [选项]                           # 全链路转换
lpforge frames <video> --at 秒 [--count n]               # 验证帧精确步进
lpforge stress <video> [--times n]                      # 连续转换内存测试
lpforge verify <mov> [<封面图>]                          # 回读 Live Photo 元数据
```

`convert` 选项：`--cover 秒|auto`、`--start`、`--duration`、`--out`、
`--format heic|jpeg`、`--quality`、`--no-audio`、`--precise`、`--no-import`。

## 三条必须如实告知用户的限制

1. 封面图无法比特级无损——必须重新编码为 HEIC/JPEG，只能做到视觉无损。
2. 裁剪起点会吸附到前一个关键帧（时间轴上的白色竖线），选区在界面上直接落到吸附后的位置，
   时长保持不变。需要精确到任意帧就开「精确裁剪」，代价是视频轨重新编码、画质有损。
3. 4K 存进相册没问题，但分享到社交平台会被对方服务器二次压缩。
