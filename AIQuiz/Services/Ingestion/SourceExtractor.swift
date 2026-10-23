import Foundation
import PDFKit
import Vision
import UIKit
import AIQuizCore

/// Turns a source into text (SPEC §6, F-21). All work runs off the main actor and checks
/// for cancellation between pages and images.
protocol SourceExtracting: Sendable {
    /// A web page, reduced to its article. A link to a PDF is read as a PDF.
    func article(from url: URL) async throws -> ExtractedArticle
    /// Text from every page; pages without a text layer are read with OCR. `progress` is 0…1.
    func pdfText(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String
    /// OCR over photos or scanned pages, in order.
    func imageText(_ files: [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> String
}

enum SourceExtractionError: LocalizedError {
    case http(Int)
    case notReadable(String)
    case noText(String)

    var errorDescription: String? {
        switch self {
        case .http(let status): return "The page couldn't be fetched (HTTP \(status)). Paste the text instead."
        case .notReadable(let name): return "\(name) couldn't be opened."
        case .noText(let name): return "No readable text was found in \(name)."
        }
    }
}

struct LiveSourceExtractor: SourceExtracting {
    func article(from url: URL) async throws -> ExtractedArticle {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(ReaderModeExtractor.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/pdf;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if let status = http?.statusCode, !(200...299).contains(status) {
            throw SourceExtractionError.http(status)
        }
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")
        if contentType?.lowercased().contains("application/pdf") == true || url.pathExtension.lowercased() == "pdf" {
            let text = try await Self.pdfText(.data(data), name: url.lastPathComponent, progress: { _ in })
            return ExtractedArticle(title: url.deletingPathExtension().lastPathComponent, text: text)
        }
        return try await Task.detached(priority: .userInitiated) {
            let html = ReaderModeExtractor.decode(data, contentType: contentType)
            return try ReaderModeExtractor.extract(html: html)
        }.value
    }

    func pdfText(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try await Self.pdfText(.file(url), name: url.lastPathComponent, progress: progress)
    }

    func imageText(_ files: [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            var pages: [String] = []
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                guard let image = UIImage(contentsOfFile: file.path)?.cgImage else { continue }
                let text = try Self.recognise(image)
                if !text.isEmpty { pages.append(text) }
                progress(Double(index + 1) / Double(max(1, files.count)))
            }
            guard !pages.isEmpty else { throw SourceExtractionError.noText("the photos") }
            return pages.joined(separator: "\n\n")
        }.value
    }

    private enum PDFInput: Sendable {
        case data(Data)
        case file(URL)
    }

    /// PDFKit text per page; a page with almost no text is rendered and read with Vision.
    /// The document is opened inside the background task, since PDFDocument isn't Sendable.
    private static func pdfText(_ input: PDFInput, name: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let opened: PDFDocument?
            switch input {
            case .data(let data): opened = PDFDocument(data: data)
            case .file(let url): opened = PDFDocument(url: url)
            }
            guard let pdf = opened, pdf.pageCount > 0 else { throw SourceExtractionError.notReadable(name) }
            let count = pdf.pageCount
            var pages: [String] = []
            for index in 0..<count {
                try Task.checkCancellation()
                guard let page = pdf.page(at: index) else { continue }
                var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count < 20 {
                    let bounds = page.bounds(for: .mediaBox)
                    let scale = 2000 / max(bounds.width, bounds.height, 1)
                    let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                    if let cg = image.cgImage { text = try recognise(cg) }
                }
                if !text.isEmpty { pages.append(text) }
                progress(Double(index + 1) / Double(count))
            }
            guard !pages.isEmpty else { throw SourceExtractionError.noText(name) }
            return pages.joined(separator: "\n\n")
        }.value
    }

    private static func recognise(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

/// UI-test mode: deterministic text, no network (PLAN §1.5). A host of `fail.example` fails
/// like a paywalled page.
struct FakeSourceExtractor: SourceExtracting {
    func article(from url: URL) async throws -> ExtractedArticle {
        try await Task.sleep(for: .milliseconds(200))
        if url.host == "fail.example" { throw ReaderModeExtractor.Failure.tooShort(40) }
        return ExtractedArticle(title: "Fixture article from \(url.host ?? "the web")", text: "# Fixture article\n\nThis article came from \(url.absoluteString). It explains how the fake extractor works in UI tests.")
    }

    func pdfText(at url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        progress(1)
        return "Fixture PDF text from \(url.lastPathComponent)."
    }

    func imageText(_ files: [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        progress(1)
        return "Fixture scanned text from \(files.count) page(s)."
    }
}
