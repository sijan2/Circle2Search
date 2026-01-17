// BarcodeIntentHandler.swift
// Circle2Search
//
// macOS-native intent handlers for different barcode/QR code types
// Provides better UX with native integrations

import Foundation
import AppKit
import Contacts
import EventKit

/// Handles macOS-native intents for different barcode types
class BarcodeIntentHandler {
    static let shared = BarcodeIntentHandler()
    
    private let contactStore = CNContactStore()
    private let eventStore = EKEventStore()
    
    private init() {}
    
    // MARK: - URL Intent
    
    /// Opens URL in default browser
    func openURL(_ urlString: String, completion: @escaping (Bool) -> Void) {
        // Ensure URL has a scheme
        var finalURL = urlString
        if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
            finalURL = "https://\(urlString)"
        }
        
        guard let url = URL(string: finalURL) else {
            log.error("Invalid URL: \(urlString)")
            completion(false)
            return
        }
        
        NSWorkspace.shared.open(url)
        log.info("Opened URL: \(finalURL)")
        completion(true)
    }
    
    // MARK: - WiFi Intent
    
    /// Copies WiFi password and optionally attempts to join network
    func handleWiFi(ssid: String, password: String?, encryption: String?, hidden: Bool = false, completion: @escaping (Bool, String) -> Void) {
        // Always copy password if available
        if let pass = password, !pass.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pass, forType: .string)
            log.info("WiFi password copied for network: \(ssid)")
        }
        
        // Build message based on what we have
        let message: String
        if let pass = password, !pass.isEmpty {
            message = "Password for \"\(ssid)\" copied!\nOpen WiFi settings to join."
        } else {
            message = "Network: \(ssid)\nOpen WiFi settings to join."
        }
        
        completion(true, message)
    }
    
    /// Opens WiFi System Preferences
    func openWiFiSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.network?Wi-Fi") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Phone Intent
    
    /// Initiates FaceTime audio call
    func callPhone(_ number: String, completion: @escaping (Bool) -> Void) {
        // Clean the number
        let cleaned = number
            .replacingOccurrences(of: "tel:", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        
        // On macOS, use FaceTime Audio for calls
        if let url = URL(string: "facetime-audio:\(cleaned)") {
            NSWorkspace.shared.open(url)
            log.info("Initiating FaceTime Audio call to: \(cleaned)")
            completion(true)
        } else {
            // Fallback to tel: which may open other apps
            if let url = URL(string: "tel:\(cleaned)") {
                NSWorkspace.shared.open(url)
                completion(true)
            } else {
                completion(false)
            }
        }
    }
    
    // MARK: - SMS Intent
    
    /// Opens Messages app with pre-filled recipient and message
    func sendSMS(to number: String, message: String?, completion: @escaping (Bool) -> Void) {
        let cleaned = number.replacingOccurrences(of: "sms:", with: "", options: .caseInsensitive)
        
        var urlString = "sms:\(cleaned)"
        if let msg = message, !msg.isEmpty {
            let encoded = msg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? msg
            urlString += "&body=\(encoded)"
        }
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            log.info("Opening Messages for: \(cleaned)")
            completion(true)
        } else {
            completion(false)
        }
    }
    
    // MARK: - Email Intent
    
    /// Opens Mail app with pre-filled email
    func sendEmail(to address: String, subject: String?, body: String?, completion: @escaping (Bool) -> Void) {
        var urlString = "mailto:\(address)"
        var params: [String] = []
        
        if let subj = subject, !subj.isEmpty {
            params.append("subject=\(subj.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subj)")
        }
        if let bod = body, !bod.isEmpty {
            params.append("body=\(bod.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bod)")
        }
        
        if !params.isEmpty {
            urlString += "?" + params.joined(separator: "&")
        }
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            log.info("Opening Mail for: \(address)")
            completion(true)
        } else {
            completion(false)
        }
    }
    
    // MARK: - Contact Intent
    
    /// Adds contact to Contacts app
    func addContact(name: String?, phone: String?, email: String?, organization: String?, completion: @escaping (Bool, String) -> Void) {
        // Request access
        contactStore.requestAccess(for: .contacts) { [weak self] granted, error in
            guard granted, let self = self else {
                DispatchQueue.main.async {
                    // Fallback: copy contact info
                    var info: [String] = []
                    if let n = name { info.append(n) }
                    if let p = phone { info.append(p) }
                    if let e = email { info.append(e) }
                    if let o = organization { info.append(o) }
                    
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.joined(separator: "\n"), forType: .string)
                    completion(false, "Contact info copied (permission denied)")
                }
                return
            }
            
            // Create contact
            let contact = CNMutableContact()
            
            // Parse name
            if let fullName = name {
                let parts = fullName.components(separatedBy: " ")
                if parts.count >= 2 {
                    contact.givenName = parts[0]
                    contact.familyName = parts.dropFirst().joined(separator: " ")
                } else {
                    contact.givenName = fullName
                }
            }
            
            // Phone
            if let phoneNumber = phone {
                contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phoneNumber))]
            }
            
            // Email
            if let emailAddress = email {
                contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: emailAddress as NSString)]
            }
            
            // Organization
            if let org = organization {
                contact.organizationName = org
            }
            
            // Save
            let saveRequest = CNSaveRequest()
            saveRequest.add(contact, toContainerWithIdentifier: nil)
            
            do {
                try self.contactStore.execute(saveRequest)
                DispatchQueue.main.async {
                    log.info("Contact saved: \(name ?? "Unknown")")
                    completion(true, "Contact \"\(name ?? "")\" added!")
                }
            } catch {
                DispatchQueue.main.async {
                    log.error("Failed to save contact: \(error)")
                    // Fallback: copy info
                    var info: [String] = []
                    if let n = name { info.append(n) }
                    if let p = phone { info.append(p) }
                    if let e = email { info.append(e) }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.joined(separator: "\n"), forType: .string)
                    completion(false, "Contact copied (save failed)")
                }
            }
        }
    }
    
    // MARK: - Calendar Event Intent
    
    /// Adds event to Calendar app
    func addCalendarEvent(title: String?, location: String?, startDate: Date?, endDate: Date?, completion: @escaping (Bool, String) -> Void) {
        eventStore.requestAccess(to: .event) { [weak self] granted, error in
            guard granted, let self = self else {
                DispatchQueue.main.async {
                    // Fallback: copy event info
                    var info: [String] = []
                    if let t = title { info.append("Event: \(t)") }
                    if let l = location { info.append("Location: \(l)") }
                    
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.joined(separator: "\n"), forType: .string)
                    completion(false, "Event info copied (permission denied)")
                }
                return
            }
            
            // Create event
            let event = EKEvent(eventStore: self.eventStore)
            event.title = title ?? "Untitled Event"
            event.location = location
            event.startDate = startDate ?? Date()
            event.endDate = endDate ?? Date().addingTimeInterval(3600) // 1 hour default
            event.calendar = self.eventStore.defaultCalendarForNewEvents
            
            do {
                try self.eventStore.save(event, span: .thisEvent)
                DispatchQueue.main.async {
                    log.info("Event saved: \(title ?? "Untitled")")
                    completion(true, "Event \"\(title ?? "")\" added to Calendar!")
                }
            } catch {
                DispatchQueue.main.async {
                    log.error("Failed to save event: \(error)")
                    var info: [String] = []
                    if let t = title { info.append(t) }
                    if let l = location { info.append(l) }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.joined(separator: "\n"), forType: .string)
                    completion(false, "Event copied (save failed)")
                }
            }
        }
    }
    
    // MARK: - Location Intent
    
    /// Opens location in Apple Maps
    func openLocation(latitude: Double, longitude: Double, label: String?, completion: @escaping (Bool) -> Void) {
        var urlString = "maps://?ll=\(latitude),\(longitude)"
        if let lbl = label {
            urlString += "&q=\(lbl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? lbl)"
        }
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
            log.info("Opening Maps at: \(latitude), \(longitude)")
            completion(true)
        } else {
            // Fallback: Google Maps in browser
            let googleURL = "https://www.google.com/maps?q=\(latitude),\(longitude)"
            if let url = URL(string: googleURL) {
                NSWorkspace.shared.open(url)
                completion(true)
            } else {
                completion(false)
            }
        }
    }
    
    // MARK: - Product Intent
    
    /// Searches for product barcode
    func searchProduct(_ code: String, completion: @escaping (Bool) -> Void) {
        let searchURL = "https://www.google.com/search?q=\(code)"
        if let url = URL(string: searchURL) {
            NSWorkspace.shared.open(url)
            log.info("Searching for product: \(code)")
            completion(true)
        } else {
            completion(false)
        }
    }
    
    // MARK: - Generic Search
    
    /// Google search for any text
    func searchGoogle(_ query: String, completion: @escaping (Bool) -> Void) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = "https://www.google.com/search?q=\(encoded)"
        if let url = URL(string: searchURL) {
            NSWorkspace.shared.open(url)
            completion(true)
        } else {
            completion(false)
        }
    }
}
