#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Records a screen view every time this view appears.
    ///
    /// ```swift
    /// TimerView()
    ///     .atriyaScreen("Timer")
    /// ```
    public func atriyaScreen(_ name: String, properties: [String: AtriyaValue]? = nil) -> some View {
        onAppear { Atriya.screen(name, properties: properties) }
    }
}
#endif
