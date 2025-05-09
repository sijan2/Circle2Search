import Vision
import AppKit // For NSPasteboard
import CoreImage // For CIImage

// Handles local text/barcode recognition
class VisionService {
    static let shared = VisionService()
    private init() {}

    /// Performs text recognition on a given CIImage.
    /// - Parameters:
    ///   - ciImage: The image to analyze.
    ///   - completion: A handler called with the recognized text (String) or nil if none found/error.
    func recognizeText(in ciImage: CIImage, completion: @escaping (String?) -> Void) {
        let request = VNRecognizeTextRequest { (request, error) in
            if let error = error {
                print("Error recognizing text: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation], !observations.isEmpty else {
                print("No text observations found.")
                completion(nil)
                return
            }

            let recognizedStrings = observations.compactMap { observation in
                // Return the top candidate string for each observation.
                observation.topCandidates(1).first?.string
            }

            let combinedText = recognizedStrings.joined(separator: "\n")
            print("Recognized Text:\n---\n\(combinedText)\n---")
            completion(combinedText)
        }

        // Configure the request
        request.recognitionLevel = .accurate // Or .fast
        request.usesLanguageCorrection = true

        // Create a request handler
        // Use explicit orientation matching screen capture if necessary, often .up is fine
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])

        // Perform the request asynchronously
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                print("Failed to perform text recognition request: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }

    // TODO: Implement barcode/QR code detection
}
