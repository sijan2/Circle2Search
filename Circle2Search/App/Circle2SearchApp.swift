//
//  Circle2SearchApp.swift
//  Circle2Search
//
//  Created by Sijan Mainali on 5/4/25.
//

import SwiftUI
import AppKit // For NSPasteboard
import Combine // Add Combine import

@main
struct Circle2SearchApp: App {
    // --- State Variables --- //
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settingsWindow: NSWindow?     // Keep for Settings window reference if needed

    var body: some Scene {
        // --- Menu Bar Item --- //
        MenuBarExtra("Circle2Search", systemImage: "record.circle") {
            Button("Capture Screen") {
                print("MenuBar: Posting menuTriggerCapture notification.")
                NotificationCenter.default.post(name: .menuTriggerCapture, object: nil)
            }
            SettingsLink {
                 Text("Settings...")
            }
            Divider()
            Button("Quit") {
                 // Ensure capture session stops if running
                 NSApplication.shared.terminate(nil)
            }
        }

        // --- Settings Window (Standard SwiftUI Way) --- //
        Settings {
            // ContentView for settings
            ContentView()
                .background(WindowAccessor(window: $settingsWindow)) // Use WindowAccessor for the standard Settings NSWindow
        }
        
        // --- NO OVERLAY WINDOW SCENE DECLARED HERE --- 
        // The overlay is created and managed entirely by the 
        // AppDelegate -> CaptureController -> OverlayManager
    }
}

// Helper View to get NSWindow reference (For standard SwiftUI Windows like Settings)
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow? // Expects standard NSWindow

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window 
            print("WindowAccessor: Standard window reference obtained: \(self.window != nil)")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
