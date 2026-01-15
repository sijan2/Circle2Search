//
//  ContentView.swift
//  Circle2Search
//
//  Created by Sijan Mainali on 5/4/25.
//

import SwiftUI
import Carbon

/// ContentView provides a settings interface for the Circle2Search app.
struct ContentView: View {
    @EnvironmentObject private var captureController: CaptureController
    @State private var hotkeyString: String = ""
    @State private var isRecordingHotkey: Bool = false // State to manage recording

    // Keys for UserDefaults (matching HotkeyManager)
    private let keyCodeKey = "hotkeyCode"
    private let modifiersKey = "hotkeyModifiers"

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "circle.dashed.inset.filled")
                .imageScale(.large)
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Circle2Search")
                .font(.largeTitle)
                .fontWeight(.bold)

            Divider()

            Text("Select an area of your screen to capture and analyze.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Test Capture") {
                Task {
                    // Use the correct method name, remove await
                    captureController.startCapture()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(captureController.isCapturing)

            // --- Hotkey Settings ---
            Divider() // Add separator
            Text("Global Hotkey")
                .font(.headline)

            HStack {
                Text("Current Shortcut:")
                Spacer()
                if isRecordingHotkey {
                    // Show the recorder view when recording
                    HotkeyRecorderView(isRecording: $isRecordingHotkey) { keyCode, modifiers in
                        // Callback when a valid hotkey is recorded
                        print("ContentView: Hotkey recorded - Code: \(keyCode), Modifiers: \(modifiers)")
                        // Update the manager (this also saves to UserDefaults and re-registers)
                        HotkeyManager.shared.updateHotkey(keyCode: keyCode, modifiers: modifiers)
                        // Update the displayed string
                        updateHotkeyString()
                        // isRecording is set to false automatically by HotkeyRecorderView on success/escape
                    }
                    .frame(height: 25) // Give the recorder view some height
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Display the formatted hotkey string when not recording
                    HStack {
                        Text("Hotkey: ")
                        Text(hotkeyString)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.gray, lineWidth: 1)
                            )
                        Button("Reset to Default") {
                            // Reset to Command+Shift+S as the standard hotkey
                            let defaultModifiers: UInt32 = UInt32(cmdKey | shiftKey)
                            let defaultKeyCode: UInt32 = 1 // 'S' key
                            
                            // Update in UserDefaults and HotkeyManager
                            HotkeyManager.shared.updateHotkey(keyCode: defaultKeyCode, modifiers: defaultModifiers)
                            
                            // Update our local state
                            updateHotkeyString()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            Button {
                isRecordingHotkey.toggle() // Toggle recording state
            } label: {
                // Change button text based on recording state
                Text(isRecordingHotkey ? "Press New Shortcut..." : "Change Hotkey")
                    .frame(maxWidth: .infinity) // Make button wider
            }
            .buttonStyle(.bordered)
            .tint(isRecordingHotkey ? .orange : .accentColor) // Change color when recording
            // --- End Hotkey Settings ---

            Spacer()

            Text("Access the app from the menu bar")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 350, height: 400) // Restore adjusted frame size
        .onAppear {
            updateHotkeyString() // Load initial hotkey string
        }
    }

    // Helper to load and format the hotkey string from UserDefaults
    private func updateHotkeyString() {
        let keyCode = UInt32(UserDefaults.standard.integer(forKey: keyCodeKey))
        let modifiers = UInt32(UserDefaults.standard.integer(forKey: modifiersKey))
        hotkeyString = formatHotkey(keyCode: keyCode, modifiers: modifiers)
    }

    // Helper function to format Key Code + Modifiers into a String
    private func formatHotkey(keyCode: UInt32?, modifiers: UInt32?) -> String {
        // If not Double Fn, proceed with standard formatting
        guard let keyCode = keyCode, let modifiers = modifiers, keyCode != 0 else {
            return "(Not Set)"
        }

        var modString = ""
        if (modifiers & UInt32(controlKey)) != 0 { modString += "⌃" } // Control
        if (modifiers & UInt32(optionKey)) != 0 { modString += "⌥" } // Option
        if (modifiers & UInt32(shiftKey)) != 0 { modString += "⇧" } // Shift
        if (modifiers & UInt32(cmdKey)) != 0 { modString += "⌘" } // Command

        let maxChars = 4
        var charCode: UniChar = 0
        var actualLength: Int = 0
        var keyTranslateState = UInt32(0)

        let keyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let layoutData = TISGetInputSourceProperty(keyboard, kTISPropertyUnicodeKeyLayoutData)
        guard let data = layoutData else {
            print("Error: Could not get keyboard layout data.")
            return modString + "?"
        }
        // The CFTypeRef needs to be properly cast to CFData
        let dataRef = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
        
        // Now we can safely get the byte pointer
        guard let keyboardLayoutPtr = CFDataGetBytePtr(dataRef) else {
            print("Error: Could not get keyboard layout pointer")
            return modString + "?"
        }
        
        // Create the keyboard layout pointer
        let keyboardLayout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(keyboardLayoutPtr))

        let status = UCKeyTranslate(keyboardLayout,
                                     UInt16(keyCode),
                                     UInt16(kUCKeyActionDown),
                                     (modifiers >> 8) & 0xFF,
                                     UInt32(LMGetKbdType()),
                                     UInt32(kUCKeyTranslateNoDeadKeysMask),
                                     &keyTranslateState,
                                     maxChars,
                                     &actualLength,
                                     &charCode)

        if status != noErr {
            print("Error translating key code: \(status)")
            return modString + "?"
        }

        var keyString = "?"
        if actualLength > 0 && charCode >= 32 && charCode <= 126 {
             keyString = String(format: "%C", charCode).uppercased()
        } else if let specialKey = specialKeyMap[keyCode] {
            keyString = specialKey
        } else {
            keyString = "Keycode \(keyCode)"
        }

        return modString + keyString
    }

    // Map for non-character keys (add more as needed)
    private let specialKeyMap: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "Return", // Enter
        UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Escape): "Esc",
        UInt32(kVK_Delete): "Delete", // Forward delete
        UInt32(kVK_ForwardDelete): "Fwd Del",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "Home",
        UInt32(kVK_End): "End",
        UInt32(kVK_PageUp): "Page Up",
        UInt32(kVK_PageDown): "Page Down",
        UInt32(kVK_Help): "Help",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",	
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
        UInt32(kVK_Function): "Fn", // Add Fn key for display mapping
        // Add more mappings as needed
    ]
}

#Preview {
    ContentView()
        .environmentObject(CaptureController())
}
