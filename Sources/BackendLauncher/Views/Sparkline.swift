import Charts
import SwiftUI

/// Mini-grafico degli ultimi campioni (CPU%, latenza health…) da affiancare alle pill
/// della card: linea + area sfumata, assi nascosti, scala Y auto sul massimo.
struct Sparkline: View {
    let values: [Double]
    var color: Color = .teal

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { sample in
            LineMark(x: .value("t", sample.offset), y: .value("v", sample.element))
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            AreaMark(x: .value("t", sample.offset), y: .value("v", sample.element))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), .clear],
                                                startPoint: .top, endPoint: .bottom))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        // Y da 0 al massimo osservato (minimo 1 per non dividere per zero su serie piatte a 0).
        .chartYScale(domain: 0...max(values.max() ?? 1, 1))
        .frame(width: 56, height: 20)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
