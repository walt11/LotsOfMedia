import SwiftUI

/// The app's colors: a deep slate ground and slate cards on iPhone, iPad and Apple TV, with
/// the app icon's green for highlights on iPhone and iPad (Apple TV highlights in white). Red (failure) and purple (server converting) keep their meaning.
/// Compiled into the apps and the widget extension so the Live Activity and widget match.
enum AppTheme {
    /// The icon's green (#5CD98C). Labels drawn on it are black.
    static let accent = Color(red: 0.36, green: 0.85, blue: 0.55)
    static let background = Color(red: 0.027, green: 0.035, blue: 0.051)
    static let glass = Color(red: 0.11, green: 0.13, blue: 0.17).opacity(0.72)
    static let muted = Color(red: 0.55, green: 0.59, blue: 0.65)
    static let surface = Color(red: 0.08, green: 0.10, blue: 0.14)
    static let placeholder = Color(red: 0.13, green: 0.15, blue: 0.20)
    /// Shared surface definition: visible edges without heavy card shadows.
    static let border = Color.white.opacity(0.12)
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 14
    /// Distinct from the accent so "converting" never reads as "downloading".
    static let converting = Color(red: 0.66, green: 0.55, blue: 1.0)
}
