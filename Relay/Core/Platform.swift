import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    static var relayBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
    static var relaySecondaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
    static var relayFill: Color {
        #if os(macOS)
        Color(nsColor: .quaternaryLabelColor)
        #else
        Color(uiColor: .tertiarySystemFill)
        #endif
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension ToolbarItemPlacement {
    static var relayTrailing: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .topBarTrailing
        #endif
    }
}

extension View {
    @ViewBuilder func relayInlineTitle() -> some View {
        #if os(macOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }
    @ViewBuilder func relayCredentialInput(isURL: Bool = false) -> some View {
        #if os(macOS)
        self.autocorrectionDisabled()
        #else
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
            .keyboardType(isURL ? .URL : .default)
        #endif
    }
    @ViewBuilder func relayDismissKeyboard() -> some View {
        #if os(macOS)
        self
        #else
        self.scrollDismissesKeyboard(.interactively)
        #endif
    }
    @ViewBuilder func relayDetailsPresentation() -> some View {
        #if os(macOS)
        self.frame(minWidth: 480, minHeight: 440)
        #else
        self.presentationDetents([.medium, .large])
        #endif
    }
    @ViewBuilder func relayConnectionSize() -> some View {
        #if os(macOS)
        self.frame(width: 500, height: 640)
        #else
        self
        #endif
    }
}
