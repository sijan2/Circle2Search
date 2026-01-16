// GlassEffectModifier.swift
// Circle2Search
//
// Abstraction layer for Liquid Glass effects (macOS 26+)
// Provides backward compatibility with material fallbacks

import SwiftUI

// MARK: - Glass Effect Style

/// Glass effect style options matching Apple's Liquid Glass API
enum GlassEffectStyle {
    case regular
    case prominent
    case subtle
    
    #if swift(>=6.0)
    @available(macOS 26.0, *)
    var nativeStyle: some ShapeStyle {
        switch self {
        case .regular:
            return .ultraThinMaterial
        case .prominent:
            return .thickMaterial
        case .subtle:
            return .thinMaterial
        }
    }
    #endif
    
    /// Fallback material for pre-macOS 26
    var fallbackMaterial: Material {
        switch self {
        case .regular:
            return .ultraThinMaterial
        case .prominent:
            return .thickMaterial
        case .subtle:
            return .thinMaterial
        }
    }
}

// MARK: - Glass Effect View Modifier

/// A view modifier that applies glass effect with OS version handling
struct GlassEffectModifier: ViewModifier {
    let style: GlassEffectStyle
    let cornerRadius: CGFloat
    let isInteractive: Bool
    
    init(style: GlassEffectStyle = .regular, cornerRadius: CGFloat = 16, isInteractive: Bool = false) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.isInteractive = isInteractive
    }
    
    func body(content: Content) -> some View {
        // When macOS 26 is available, this will use native .glassEffect()
        // For now, use material fallback
        content
            .background(
                style.fallbackMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
    }
}

// MARK: - View Extension

extension View {
    /// Apply a glass effect with automatic OS version handling
    /// - Parameters:
    ///   - style: The glass effect style (.regular, .prominent, .subtle)
    ///   - cornerRadius: Corner radius for the glass shape
    ///   - isInteractive: Whether the element responds to touch/pointer
    /// - Returns: A view with glass effect applied
    func glassBackground(
        style: GlassEffectStyle = .regular,
        cornerRadius: CGFloat = 16,
        isInteractive: Bool = false
    ) -> some View {
        self.modifier(GlassEffectModifier(
            style: style,
            cornerRadius: cornerRadius,
            isInteractive: isInteractive
        ))
    }
}

// MARK: - Glass Button Style

/// Button style that uses glass effect background
struct GlassButtonStyle: ButtonStyle {
    let isProminent: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassBackground(
                style: isProminent ? .prominent : .regular,
                cornerRadius: 12,
                isInteractive: true
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle {
        GlassButtonStyle(isProminent: false)
    }
    
    static var glassProminent: GlassButtonStyle {
        GlassButtonStyle(isProminent: true)
    }
}
