import SwiftUI

/// 波形可视化视图（保留为公共组件，供外部引用）
struct WaveformView: View {
    let levels: [Float]
    var isLive: Bool = false
    var progress: Double = 0

    var body: some View {
        if isLive {
            LiveWaveformView(levels: levels)
        } else {
            StaticWaveformView(levels: levels, progress: progress)
        }
    }
}
