// DetectedTextData.swift
// Circle2Search
//
// Model for detected data links (URLs, emails, phone numbers) within recognized text
// Uses NSDataDetector for reliable extraction from OCR results

import Foundation
import CoreGraphics

/// Represents detected data links (URLs, emails, phones) within a text region
struct DetectedTextData: Identifiable, Equatable {
    let id = UUID()
    
    /// Normalized bounding box of the text region (Vision coordinates)
    let normalizedRect: CGRect
    
    /// Screen coordinates of the text region
    var screenRect: CGRect
    
    /// The original recognized text
    let sourceText: String
    
    /// Detected URLs in the text
    let urls: [URL]
    
    /// Detected phone numbers
    let phoneNumbers: [String]
    
    /// Detected email addresses
    let emails: [String]
    
    /// Address detections
    let addresses: [String]
    
    /// Whether any data was detected
    var hasData: Bool {
        !urls.isEmpty || !phoneNumbers.isEmpty || !emails.isEmpty || !addresses.isEmpty
    }
    
    /// Primary actionable item (first URL, email, or phone)
    var primaryAction: DetectedDataAction? {
        if let url = urls.first(where: { $0.scheme != "mailto" && $0.scheme != "tel" }) {
            return .url(url)
        }
        if let email = emails.first {
            return .email(email)
        }
        if let phone = phoneNumbers.first {
            return .phone(phone)
        }
        return nil
    }
    
    // MARK: - Equatable
    
    static func == (lhs: DetectedTextData, rhs: DetectedTextData) -> Bool {
        lhs.id == rhs.id && lhs.normalizedRect == rhs.normalizedRect
    }
}

/// Types of actionable data detected in text
enum DetectedDataAction {
    case url(URL)
    case email(String)
    case phone(String)
    case address(String)
    
    var icon: String {
        switch self {
        case .url: return "link"
        case .email: return "envelope.fill"
        case .phone: return "phone.fill"
        case .address: return "mappin.circle.fill"
        }
    }
    
    var label: String {
        switch self {
        case .url(let url):
            return url.host ?? url.absoluteString
        case .email(let email):
            return email
        case .phone(let phone):
            return phone
        case .address(let addr):
            return String(addr.prefix(30)) + (addr.count > 30 ? "..." : "")
        }
    }
}

// MARK: - NSDataDetector Helper

/// Extracts URLs, emails, phones, and addresses from text using NSDataDetector
class TextDataDetector {
    static let shared = TextDataDetector()
    
    private let detector: NSDataDetector?
    
    private init() {
        do {
            let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .address]
            detector = try NSDataDetector(types: types.rawValue)
        } catch {
            log.error("Failed to create NSDataDetector: \(error)")
            detector = nil
        }
    }
    
    /// Extract data from recognized text
    func extractData(from text: String, normalizedRect: CGRect, screenRect: CGRect) -> DetectedTextData? {
        guard let detector = detector else {
            return nil
        }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        
        var urls: [URL] = []
        var phones: [String] = []
        var emails: [String] = []
        var addresses: [String] = []
        
        for match in matches {
            switch match.resultType {
            case .link:
                if let url = match.url {
                    // Separate emails from URLs
                    if url.scheme == "mailto" {
                        let email = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                        emails.append(email)
                    } else if url.scheme == "tel" {
                        let phone = url.absoluteString.replacingOccurrences(of: "tel:", with: "")
                        phones.append(phone)
                    } else {
                        urls.append(url)
                    }
                }
            case .phoneNumber:
                if let phone = match.phoneNumber {
                    phones.append(phone)
                }
            case .address:
                if let components = match.addressComponents {
                    let addr = [
                        components[.street],
                        components[.city],
                        components[.state],
                        components[.zip],
                        components[.country]
                    ].compactMap { $0 }.joined(separator: ", ")
                    if !addr.isEmpty {
                        addresses.append(addr)
                    }
                }
            default:
                break
            }
        }
        
        // Only return if we found something
        guard !urls.isEmpty || !phones.isEmpty || !emails.isEmpty || !addresses.isEmpty else {
            return nil
        }
        
        return DetectedTextData(
            normalizedRect: normalizedRect,
            screenRect: screenRect,
            sourceText: text,
            urls: urls,
            phoneNumbers: phones,
            emails: emails,
            addresses: addresses
        )
    }
    
    /// Extract data from multiple text regions
    func extractDataFromRegions(_ regions: [DetailedTextRegion]) -> [DetectedTextData] {
        var results: [DetectedTextData] = []
        
        for region in regions {
            if let data = extractData(
                from: region.recognizedText.string,
                normalizedRect: region.normalizedRect,
                screenRect: region.screenRect
            ) {
                results.append(data)
            }
        }
        
        return results
    }
}
