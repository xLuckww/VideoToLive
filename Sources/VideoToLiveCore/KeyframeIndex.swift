import AVFoundation
import CoreMedia
import Foundation

/// passthrough 不重编码，就不能从任意帧切开——起点必须落在 I 帧上。
/// 这里负责找出关键帧位置，供「裁剪点吸附」和阶段三的时间轴竖线标记使用。
public enum KeyframeIndex {

    /// 把给定时间吸附到「最近的前一个关键帧」。
    /// 找不到（比如轨道不支持 sample cursor）时返回 .zero，从头开始最保险。
    public static func snapToPrecedingKeyframe(
        track: AVAssetTrack,
        time: CMTime
    ) async throws -> CMTime {
        if time <= .zero { return .zero }

        if let cursor = track.makeSampleCursor(presentationTimeStamp: time) {
            // 从目标时间往回走，直到踩上一个完整同步帧（I 帧）。
            var guard_ = 0
            while guard_ < 100_000 {
                let info = cursor.currentSampleSyncInfo
                if info.sampleIsFullSync.boolValue, cursor.presentationTimeStamp <= time {
                    return cursor.presentationTimeStamp
                }
                if cursor.stepInDecodeOrder(byCount: -1) == 0 { break }
                guard_ += 1
            }
            return .zero
        }

        // 退路：扫描一遍样本（passthrough 读取，不解码）。
        let times = try await scanKeyframeTimes(track: track, upTo: time)
        return times.last(where: { $0 <= time }) ?? .zero
    }

    /// 列出时间区间内的所有关键帧时间点。阶段三时间轴用它画竖线。
    public static func keyframeTimes(
        track: AVAssetTrack,
        in range: CMTimeRange
    ) async throws -> [CMTime] {
        if let cursor = track.makeSampleCursor(presentationTimeStamp: range.start) {
            var result: [CMTime] = []
            var steps = 0
            repeat {
                let pts = cursor.presentationTimeStamp
                if pts > range.end { break }
                if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue, pts >= range.start {
                    result.append(pts)
                }
                steps += 1
            } while cursor.stepInDecodeOrder(byCount: 1) != 0 && steps < 1_000_000
            return result.sorted { $0 < $1 }
        }
        return try await scanKeyframeTimes(track: track, upTo: range.end)
            .filter { $0 >= range.start && $0 <= range.end }
    }

    /// AVSampleCursor 不可用时的兜底：用 passthrough reader 逐样本读 attachment。
    /// 不解码，但要过一遍 I/O。
    private static func scanKeyframeTimes(track: AVAssetTrack, upTo limit: CMTime) async throws -> [CMTime] {
        guard let asset = track.asset else {
            throw LivePhotoError(.inspect, "轨道已脱离 asset，无法扫描关键帧")
        }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw LivePhotoError(.inspect, "无法创建 AVAssetReader 扫描关键帧", underlying: error) }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LivePhotoError(.inspect, "AVAssetReader 拒绝添加视频输出")
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: limit + CMTime(value: 1, timescale: 1))
        guard reader.startReading() else {
            throw LivePhotoError(.inspect, "AVAssetReader 启动失败", underlying: reader.error)
        }

        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if isSyncSample(sample) {
                times.append(CMSampleBufferGetPresentationTimeStamp(sample))
            }
        }
        reader.cancelReading()
        return times.sorted { $0 < $1 }
    }

    /// 没有 NotSync 标记，或整个 attachments 数组缺失，都视为同步帧。
    static func isSyncSample(_ sample: CMSampleBuffer) -> Bool {
        guard let raw = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let attachments = raw as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }
}
