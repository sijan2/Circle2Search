// DetectableBarcode.swift
// Circle2Search
//
// Represents a detected barcode/QR code from Vision with position, payload, and content type information
// Matches Android Circle2Search barcode content type handling

import Foundation
import Vision

// MARK: - Barcode Content Type (matching Android's cffj enum)

/// Content type enum matching Android's barcode type classification
enum BarcodeContentType: Int, CaseIterable {
    case unknown = 0
    case text = 1
    case url = 3
    case wifi = 4
    case phone = 6
    case sms = 7
    case contact = 8
    case email = 9
    case location = 10
    case event = 15
    case product = 17
    
    /// SF Symbol icon for this content type
    var icon: String {
        switch self {
        case .url: return "link"
        case .wifi: return "wifi"
        case .phone: return "phone.fill"
        case .sms: return "message.fill"
        case .email: return "envelope.fill"
        case .contact: return "person.crop.circle.fill"
        case .location: return "mappin.circle.fill"
        case .event: return "calendar"
        case .product: return "barcode"
        case .text: return "doc.text"
        case .unknown: return "qrcode"
        }
    }
    
    /// User-facing action label
    var actionLabel: String {
        switch self {
        case .url: return "Open Link"
        case .wifi: return "Join Network"
        case .phone: return "Call"
        case .sms: return "Send Message"
        case .email: return "Send Email"
        case .contact: return "Add Contact"
        case .location: return "Open in Maps"
        case .event: return "Add to Calendar"
        case .product: return "Search Product"
        case .text: return "Copy Text"
        case .unknown: return "Copy"
        }
    }
    
    /// Accent color for this content type
    var accentColor: String {
        switch self {
        case .url: return "blue"
        case .wifi: return "green"
        case .phone: return "green"
        case .sms: return "green"
        case .email: return "blue"
        case .contact: return "orange"
        case .location: return "red"
        case .event: return "purple"
        case .product: return "gray"
        default: return "green"
        }
    }
}

// MARK: - Parsed Payload

/// Structured payload data parsed from barcode content
struct ParsedBarcodePayload: Equatable {
    // WiFi network info (from WIFI:S:ssid;T:type;P:password;;)
    var wifiSSID: String?
    var wifiPassword: String?
    var wifiEncryption: String? // WPA, WEP, nopass
    var wifiHidden: Bool = false
    
    // Contact info (from vCard)
    var contactName: String?
    var contactPhone: String?
    var contactEmail: String?
    var contactOrganization: String?
    
    // Location (from geo:lat,lng)
    var latitude: Double?
    var longitude: Double?
    var locationLabel: String?
    
    // Email (from mailto:)
    var emailAddress: String?
    var emailSubject: String?
    var emailBody: String?
    
    // Phone/SMS
    var phoneNumber: String?
    var smsMessage: String?
    
    // Event (from vEvent)
    var eventTitle: String?
    var eventLocation: String?
    var eventStartDate: Date?
    var eventEndDate: Date?
    
    // URL
    var urlString: String?
}

// MARK: - Detectable Barcode

/// Represents a detected barcode or QR code from Vision
struct DetectableBarcode: Identifiable, Equatable {
    let id = UUID()
    let symbology: VNBarcodeSymbology
    let payloadString: String?
    let payloadData: Data?
    let normalizedRect: CGRect
    var screenRect: CGRect
    
    /// Detected content type (computed from payload)
    var contentType: BarcodeContentType {
        detectContentType()
    }
    
    /// Parsed payload data
    var parsedPayload: ParsedBarcodePayload {
        parsePayload()
    }
    
    /// Whether this is a QR code (standard or micro)
    var isQRCode: Bool {
        symbology == .qr || symbology == .microQR
    }
    
    init(from observation: VNBarcodeObservation, screenSize: CGSize) {
        self.symbology = observation.symbology
        self.payloadString = observation.payloadStringValue
        self.payloadData = observation.barcodeDescriptor != nil ? nil : nil
        self.normalizedRect = observation.boundingBox
        
        // Convert normalized Vision coordinates to screen coordinates
        self.screenRect = CGRect(
            x: observation.boundingBox.origin.x * screenSize.width,
            y: (1 - observation.boundingBox.origin.y - observation.boundingBox.height) * screenSize.height,
            width: observation.boundingBox.width * screenSize.width,
            height: observation.boundingBox.height * screenSize.height
        )
    }
    
    // MARK: - Content Type Detection
    
    private func detectContentType() -> BarcodeContentType {
        guard let payload = payloadString?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .unknown
        }
        
        let uppercased = payload.uppercased()
        
        // WiFi: WIFI:S:ssid;T:WPA;P:password;;
        if uppercased.hasPrefix("WIFI:") {
            return .wifi
        }
        
        // URL
        if uppercased.hasPrefix("HTTP://") || uppercased.hasPrefix("HTTPS://") {
            return .url
        }
        
        // Phone
        if uppercased.hasPrefix("TEL:") {
            return .phone
        }
        
        // SMS
        if uppercased.hasPrefix("SMS:") || uppercased.hasPrefix("SMSTO:") {
            return .sms
        }
        
        // Email
        if uppercased.hasPrefix("MAILTO:") {
            return .email
        }
        
        // Location
        if uppercased.hasPrefix("GEO:") {
            return .location
        }
        
        // vCard Contact
        if uppercased.hasPrefix("BEGIN:VCARD") {
            return .contact
        }
        
        // MECARD Contact
        if uppercased.hasPrefix("MECARD:") {
            return .contact
        }
        
        // vEvent Calendar
        if uppercased.hasPrefix("BEGIN:VEVENT") || uppercased.hasPrefix("BEGIN:VCALENDAR") {
            return .event
        }
        
        // Product barcodes (EAN/UPC typically numeric)
        if isProductBarcode() {
            return .product
        }
        
        // Check if it looks like a URL without scheme
        if looksLikeURL(payload) {
            return .url
        }
        
        // Check if it looks like a phone number
        if looksLikePhoneNumber(payload) {
            return .phone
        }
        
        // Check if it looks like an email
        if looksLikeEmail(payload) {
            return .email
        }
        
        return payload.isEmpty ? .unknown : .text
    }
    
    private func isProductBarcode() -> Bool {
        // Product barcodes are typically EAN-13, EAN-8, UPC-A, UPC-E
        switch symbology {
        case .ean13, .ean8, .upce:
            return true
        default:
            return false
        }
    }
    
    private func looksLikeURL(_ str: String) -> Bool {
        // Pattern: domain.tld or www.domain.tld
        let pattern = #"^(www\.)?[a-zA-Z0-9][-a-zA-Z0-9]*(\.[a-zA-Z]{2,})+(/.*)?$"#
        return str.range(of: pattern, options: .regularExpression) != nil
    }
    
    private func looksLikePhoneNumber(_ str: String) -> Bool {
        // Remove common phone formatting
        let digits = str.filter { $0.isNumber || $0 == "+" }
        return digits.count >= 7 && digits.count <= 15 && (digits.hasPrefix("+") || digits.first?.isNumber == true)
    }
    
    private func looksLikeEmail(_ str: String) -> Bool {
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return str.range(of: pattern, options: .regularExpression) != nil
    }
    
    // MARK: - Payload Parsing
    
    private func parsePayload() -> ParsedBarcodePayload {
        var payload = ParsedBarcodePayload()
        guard let raw = payloadString else { return payload }
        
        switch contentType {
        case .wifi:
            parseWiFi(raw, into: &payload)
        case .url:
            payload.urlString = raw.hasPrefix("http") ? raw : "https://\(raw)"
        case .phone:
            payload.phoneNumber = raw.replacingOccurrences(of: "tel:", with: "", options: .caseInsensitive)
        case .sms:
            parseSMS(raw, into: &payload)
        case .email:
            parseEmail(raw, into: &payload)
        case .location:
            parseGeo(raw, into: &payload)
        case .contact:
            parseContact(raw, into: &payload)
        case .event:
            parseEvent(raw, into: &payload)
        default:
            break
        }
        
        return payload
    }
    
    // MARK: - Parser Helpers
    
    /// Parse WiFi QR: WIFI:S:ssid;T:WPA;P:password;H:true;;
    private func parseWiFi(_ raw: String, into payload: inout ParsedBarcodePayload) {
        let content = raw.replacingOccurrences(of: "WIFI:", with: "", options: .caseInsensitive)
        let parts = content.components(separatedBy: ";")
        
        for part in parts {
            if part.uppercased().hasPrefix("S:") {
                payload.wifiSSID = String(part.dropFirst(2))
            } else if part.uppercased().hasPrefix("T:") {
                payload.wifiEncryption = String(part.dropFirst(2))
            } else if part.uppercased().hasPrefix("P:") {
                payload.wifiPassword = String(part.dropFirst(2))
            } else if part.uppercased().hasPrefix("H:") {
                payload.wifiHidden = part.dropFirst(2).uppercased() == "TRUE"
            }
        }
    }
    
    /// Parse SMS: sms:+1234567890:message or smsto:+1234567890
    private func parseSMS(_ raw: String, into payload: inout ParsedBarcodePayload) {
        var content = raw
        content = content.replacingOccurrences(of: "smsto:", with: "", options: .caseInsensitive)
        content = content.replacingOccurrences(of: "sms:", with: "", options: .caseInsensitive)
        
        if let colonRange = content.range(of: ":") {
            payload.phoneNumber = String(content[..<colonRange.lowerBound])
            payload.smsMessage = String(content[colonRange.upperBound...])
        } else if let questionRange = content.range(of: "?body=") {
            payload.phoneNumber = String(content[..<questionRange.lowerBound])
            payload.smsMessage = String(content[questionRange.upperBound...])
        } else {
            payload.phoneNumber = content
        }
    }
    
    /// Parse mailto: mailto:addr?subject=X&body=Y
    private func parseEmail(_ raw: String, into payload: inout ParsedBarcodePayload) {
        let content = raw.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
        
        if let questionIdx = content.firstIndex(of: "?") {
            payload.emailAddress = String(content[..<questionIdx])
            let params = String(content[content.index(after: questionIdx)...])
            
            for param in params.components(separatedBy: "&") {
                let kv = param.components(separatedBy: "=")
                guard kv.count == 2 else { continue }
                let key = kv[0].lowercased()
                let value = kv[1].removingPercentEncoding ?? kv[1]
                
                if key == "subject" {
                    payload.emailSubject = value
                } else if key == "body" {
                    payload.emailBody = value
                }
            }
        } else {
            payload.emailAddress = content
        }
    }
    
    /// Parse geo: geo:lat,lng or geo:lat,lng?q=label
    private func parseGeo(_ raw: String, into payload: inout ParsedBarcodePayload) {
        var content = raw.replacingOccurrences(of: "geo:", with: "", options: .caseInsensitive)
        
        // Check for query label
        if let queryIdx = content.firstIndex(of: "?") {
            let query = String(content[content.index(after: queryIdx)...])
            content = String(content[..<queryIdx])
            
            if query.lowercased().hasPrefix("q=") {
                payload.locationLabel = String(query.dropFirst(2)).removingPercentEncoding
            }
        }
        
        let coords = content.components(separatedBy: ",")
        if coords.count >= 2 {
            payload.latitude = Double(coords[0])
            payload.longitude = Double(coords[1])
        }
    }
    
    /// Parse vCard or MECARD contact
    private func parseContact(_ raw: String, into payload: inout ParsedBarcodePayload) {
        if raw.uppercased().hasPrefix("MECARD:") {
            // MECARD:N:Name;TEL:123456;EMAIL:test@example.com;;
            let content = raw.replacingOccurrences(of: "MECARD:", with: "", options: .caseInsensitive)
            for part in content.components(separatedBy: ";") {
                if part.uppercased().hasPrefix("N:") {
                    payload.contactName = String(part.dropFirst(2))
                } else if part.uppercased().hasPrefix("TEL:") {
                    payload.contactPhone = String(part.dropFirst(4))
                } else if part.uppercased().hasPrefix("EMAIL:") {
                    payload.contactEmail = String(part.dropFirst(6))
                } else if part.uppercased().hasPrefix("ORG:") {
                    payload.contactOrganization = String(part.dropFirst(4))
                }
            }
        } else {
            // vCard format - basic parsing
            for line in raw.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.uppercased().hasPrefix("FN:") {
                    payload.contactName = String(trimmed.dropFirst(3))
                } else if trimmed.uppercased().hasPrefix("TEL") && trimmed.contains(":") {
                    if let colonIdx = trimmed.lastIndex(of: ":") {
                        payload.contactPhone = String(trimmed[trimmed.index(after: colonIdx)...])
                    }
                } else if trimmed.uppercased().hasPrefix("EMAIL") && trimmed.contains(":") {
                    if let colonIdx = trimmed.lastIndex(of: ":") {
                        payload.contactEmail = String(trimmed[trimmed.index(after: colonIdx)...])
                    }
                } else if trimmed.uppercased().hasPrefix("ORG:") {
                    payload.contactOrganization = String(trimmed.dropFirst(4))
                }
            }
        }
    }
    
    /// Parse vEvent calendar event
    private func parseEvent(_ raw: String, into payload: inout ParsedBarcodePayload) {
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("SUMMARY:") {
                payload.eventTitle = String(trimmed.dropFirst(8))
            } else if trimmed.uppercased().hasPrefix("LOCATION:") {
                payload.eventLocation = String(trimmed.dropFirst(9))
            }
            // Date parsing would require more complex iCal date handling
        }
    }
    
    // MARK: - Symbology Name
    
    var symbologyName: String {
        switch symbology {
        case .qr: return "QR Code"
        case .microQR: return "Micro QR"
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .code128: return "Code 128"
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: return "Code 39"
        case .code93, .code93i: return "Code 93"
        case .dataMatrix: return "Data Matrix"
        case .pdf417, .microPDF417: return "PDF417"
        case .aztec: return "Aztec"
        case .upce: return "UPC-E"
        case .itf14: return "ITF-14"
        case .i2of5, .i2of5Checksum: return "Interleaved 2 of 5"
        case .codabar: return "Codabar"
        case .gs1DataBar, .gs1DataBarExpanded, .gs1DataBarLimited: return "GS1 DataBar"
        default: return "Barcode"
        }
    }
    
    // MARK: - Equatable
    
    static func == (lhs: DetectableBarcode, rhs: DetectableBarcode) -> Bool {
        lhs.id == rhs.id && lhs.normalizedRect == rhs.normalizedRect && lhs.payloadString == rhs.payloadString
    }
}
