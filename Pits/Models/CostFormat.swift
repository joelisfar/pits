import Foundation

/// Single source of truth for how costs are rendered in the UI. Always two
/// decimal places, leading dollar sign — keeps rows, headers, and status bar
/// visually consistent.
enum CostFormat {
    static func string(from v: Double) -> String {
        String(format: "$%.2f", v)
    }
}
