import Accelerate
import CoreGraphics
import Foundation

/// 拉普拉斯方差——图像越清晰，二阶梯度的方差越大。
/// 演唱会这类抖动素材帧间差异明显，这个算法够用（方案 4.3）。
public enum SharpnessScorer {

    public static func laplacianVariance(of image: CGImage) -> Double {
        guard let gray = grayscaleBytes(of: image) else { return 0 }
        let (pixels, width, height) = gray
        guard width > 2, height > 2 else { return 0 }

        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0

        pixels.withUnsafeBufferPointer { buffer in
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let center = Double(buffer[y * width + x])
                    let laplacian =
                        Double(buffer[(y - 1) * width + x]) +
                        Double(buffer[(y + 1) * width + x]) +
                        Double(buffer[y * width + (x - 1)]) +
                        Double(buffer[y * width + (x + 1)]) -
                        4 * center
                    sum += laplacian
                    sumSquares += laplacian * laplacian
                    count += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, sumSquares / count - mean * mean)
    }

    private static func grayscaleBytes(of image: CGImage) -> ([UInt8], Int, Int)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
              ),
              let data = context.data
        else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pointer = data.bindMemory(to: UInt8.self, capacity: width * height)
        return (Array(UnsafeBufferPointer(start: pointer, count: width * height)), width, height)
    }
}
