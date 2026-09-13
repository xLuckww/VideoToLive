# LivePhotoForge — macOS 视频转 Live Photo 工具开发方案

> 交付对象：Claude Code
> 目标平台：macOS 13+（Apple Silicon 优先）
> 技术栈：Swift + SwiftUI + AVFoundation + ImageIO + Photos

---

## 一、产品目标

把任意视频（尤其是 4K 素材）转换成 Apple Live Photo，写入系统「照片」App，并通过 iCloud 同步回 iPhone。

核心差异点：**视频轨真无损**。现有工具大多走重编码路径，4K 素材转完画质掉一档。本工具用 passthrough 模式只重封装容器，原始码流原样搬运。

无时长限制、无次数限制、无内购、无水印、全程离线。

### 明确不做的事

- 不做视频滤镜、调色、特效
- 不做 Live Photo 反向导出（转 GIF/视频）
- 不做 Android Motion Photo 格式兼容
- 不做云端处理

---

## 二、必须先认清的三个物理限制

这三条不是可以优化掉的工程问题，是格式和编码决定的。UI 上要如实告知用户，不要含糊成「无损」两个字。

**1. 封面图无法做到比特级无损。**
Live Photo 的封面必须是 HEIC 或 JPEG。从视频抽帧必然经过「解码 → 重新编码」，只能做到视觉无损（HEIC 质量拉满）。这一半的损失无解。

**2. 裁剪点会吸附到关键帧。**
passthrough 不重编码，就不能从任意帧切开——起点必须落在 I 帧上。所以：
- 默认行为：裁剪点自动吸附到最近的前一个关键帧，保证无损
- 可选行为：用户勾选「精确裁剪」，此时退回重编码路径，并在界面上明确提示画质会有损失

这个取舍要做成显式开关，不要偷偷替用户决定。

**3. 4K Live Photo 存得下，但分享会被二次压缩。**
iPhone 原生 Live Photo 约 1440×1920。4K 存进相册没问题，但发微信朋友圈、小红书时对方服务器会重新压缩。「超清」在本地相册成立，分享出去不保证。

---

## 三、核心用户流程

```
拖入视频
  ↓
自动读取时长 / 分辨率 / 编码格式 → 判定能否 passthrough
  ↓
调整裁剪区间（默认 3 秒，可自由拉长）
  ↓
选择封面帧（自动推荐 / 手动逐帧挑）
  ↓
点击「生成」
  ↓
写入照片图库 → 显示结果与文件体积
```

单个视频从拖入到完成，不超过 5 次点击。

---

## 四、功能需求

### 4.1 导入

- 支持拖拽和文件选择两种方式
- 支持批量拖入多个文件，进入队列
- 支持格式：MP4、MOV、M4V
- 导入后立刻解析并展示：时长、分辨率、帧率、视频编码、音频编码、文件大小
- 解析后判定并显示转换模式徽标：**无损直通** 或 **需重编码**
  - H.264 / HEVC → 无损直通
  - VP9 / AV1 / 其他 MOV 容器不支持的编码 → 需重编码，界面明确标注

### 4.2 裁剪

- 时间轴拖拽选择起止点，实时预览
- 默认选中 3 秒（对齐主流社交平台限制）
- 无硬性上限，但超过 10 秒时提示：「部分平台仅支持 3 秒以内」
- **关键帧标记**：时间轴上用竖线标出所有 I 帧位置，让用户直观看到裁剪点会吸附到哪里
- 起点吸附到最近的前一个关键帧，并在界面显示实际生效的时间点
- 「精确裁剪」开关，开启后走重编码路径，同时高亮警告

### 4.3 封面帧选择（两种模式并存）

**自动模式**
- 在裁剪区间内均匀采样若干帧（建议 20–30 帧）
- 用拉普拉斯方差计算清晰度，选最高的一帧
- 演唱会这类素材抖动严重，清晰度差异明显，这个算法够用
- 自动选完后仍可手动微调

**手动模式**
- 逐帧步进的预览器，支持左右方向键单帧前后移动
- 必须做到帧精确：`AVAssetImageGenerator` 的 `requestedTimeToleranceBefore` 和 `requestedTimeToleranceAfter` 都设为 `.zero`，否则会拿到邻近帧
- 底部缩略图条快速定位
- 显示当前帧的清晰度评分，辅助判断

两种模式用分段控件切换，状态互通。

### 4.4 生成与写入

- 生成前展示预估文件体积
- 进度条按「抽帧 → 编码封面 → 封装视频 → 写入图库」四阶段显示
- 写入成功后：显示实际体积、提供「在照片中显示」按钮
- 写入失败：明确告知失败环节和原因，不要只弹一个「转换失败」

### 4.5 批量处理

- 队列列表，逐个显示状态（等待 / 处理中 / 完成 / 失败）
- 批量模式下封面帧统一走自动选择
- 支持暂停和取消
- 并发数限制在 2–3，避免 4K 素材把内存吃爆

### 4.6 偏好设置

- 封面图格式：HEIC（默认）/ JPEG
- 封面图质量：默认 1.0
- 是否保留音轨（默认保留）
- 默认裁剪时长
- 是否自动打开照片 App

---

## 五、技术关键点

这几处是最容易做错、且做错了就达不成核心目标的地方，实现时重点核对。

### 5.1 Live Photo 的配对机制

Live Photo = 一张静态图 + 一段 MOV，靠三样东西绑定：

1. 静态图的 Apple Maker Note 中写入 asset identifier（UUID 字符串）
2. MOV 的 QuickTime 元数据 `com.apple.quicktime.content.identifier` 写入**同一个** UUID
3. MOV 中额外带一条定时元数据轨 `com.apple.quicktime.still-image-time`，标记封面帧对应的时间点

第 3 条经常被遗漏。缺了它，照片 App 可能仍然识别为 Live Photo，但长按播放时的静止画面位置不对。

静态图那一侧用 `CGImageDestination` 写入 `kCGImagePropertyMakerAppleDictionary`，UUID 放在键 `"17"` 下。

### 5.2 无损直通怎么实现

这是整个工具的立身之本，务必走这条路径：

- `AVAssetReader` 读取源视频轨，`AVAssetReaderTrackOutput` 的 `outputSettings` 传 **nil**
- `AVAssetWriter` 输出 `.mov`，`AVAssetWriterInput` 的 `outputSettings` 也传 **nil**
- 两端都为 nil 时走 passthrough，样本原样搬运，不解码不重编码
- 音轨同理

**不要用 `AVAssetExportSession`。** 它即便用 passthrough preset 也不给你写入自定义元数据轨的口子，这正是现有工具（包括 makelive）退回重编码的原因。

定时元数据轨用 `AVAssetWriterInputMetadataAdaptor` 单独追加。

### 5.3 写入照片图库

用 `PHAssetCreationRequest`：

```
addResource(with: .photo, fileURL: 封面图路径, options: nil)
addResource(with: .pairedVideo, fileURL: MOV路径, options: nil)
```

两个资源的 UUID 必须一致，否则 Photos 会拆成两个独立资产。

Info.plist 需要 `NSPhotoLibraryAddUsageDescription`。

### 5.4 内存控制

4K 素材逐帧抽样时容易堆积。抽帧用 `AVAssetImageGenerator` 的异步批量接口，处理完及时释放 CGImage。批量队列的并发数设上限。

---

## 六、验收标准

1. 一段 4K HEVC 视频转换后，用 `exiftool` 检查输出 MOV，视频轨的编码参数、分辨率、比特率与源文件完全一致
2. 输出的 MOV 文件体积约等于源文件对应片段的体积（允许容器开销带来的小幅差异）
3. 写入照片图库后，资产的 `mediaSubtypes` 包含 `.photoLive`
4. 在 iPhone 上长按能正常播放，且静止画面就是用户选定的那一帧
5. 手动模式下方向键步进，每按一次画面确实变化一帧，不跳帧不重复
6. 连续转换 20 个 4K 视频，内存占用不持续增长
7. 转换 30 秒以上的长视频不报错

---

## 七、开发阶段拆分

建议按这个顺序推进，每阶段可独立验证。

**阶段一：核心管线（无界面）**
先写一个命令行可调用的核心库，跑通「视频 → Live Photo → 写入图库」全链路。这一步验证 5.1 和 5.2 两个技术关键点，是整个项目风险最高的部分，必须先打通再往下走。

**阶段二：最小界面**
拖入、固定 3 秒、自动选封面、一键生成。跑通单文件闭环。

**阶段三：裁剪与封面选择**
时间轴、关键帧标记、手动逐帧选择器。

**阶段四：批量与偏好设置**

**阶段五：错误处理与体验打磨**

---

## 八、给 Claude Code 的起步提示词

```
请为我开发一个 macOS 应用 LivePhotoForge，把视频转换成 Apple Live Photo。
完整需求见附带的方案文档，请先通读。

从阶段一开始：先实现核心管线，不做界面。

这一阶段的唯一目标是跑通并验证：
1. 用 AVAssetReader + AVAssetWriter 的 passthrough 模式（两端 outputSettings 均为 nil）
   把源视频重封装为 MOV，全程不重编码
2. 给 MOV 写入 com.apple.quicktime.content.identifier 元数据
3. 给 MOV 追加 com.apple.quicktime.still-image-time 定时元数据轨
4. 抽取指定时间点的帧，编码为 HEIC，并写入 Apple Maker Note 键 "17"
5. 通过 PHAssetCreationRequest 配对写入照片图库

写一个命令行入口方便测试，接受视频路径和封面时间点两个参数。

完成后请用 exiftool 验证输出 MOV 的视频轨参数与源文件一致，
并确认写入的资产 mediaSubtypes 包含 .photoLive。
把验证结果告诉我再进入下一阶段。
```

---

## 九、风险提示

**最大的技术风险在 5.2**。AVFoundation 的 passthrough 配合自定义元数据轨，是个文档不太充分的组合，第一次可能需要几轮调试。如果反复卡住，可以先用重编码路径打通全链路验证其他环节，再回头攻这一块——但不要因为重编码「能跑通」就放弃无损，那样这个工具就没有存在价值了。

**次要风险是封面帧的帧精确抽取**。`AVAssetImageGenerator` 默认有时间容差，容易拿到邻近帧，手动模式下会表现为「按了方向键画面没变」。容差必须显式设为 `.zero`。
