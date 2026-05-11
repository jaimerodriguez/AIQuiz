import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum ContentExtractor {
    enum ExtractError: LocalizedError {
        case readFailed(URL, Error?)
        case nonText(URL)
        case fetchFailed(URL, Int)
        case empty(URL)

        var errorDescription: String? {
            switch self {
            case .readFailed(let url, let underlying):
                return "Couldn't read \(url.lastPathComponent): \(underlying?.localizedDescription ?? "unknown error")"
            case .nonText(let url):
                return "\(url.lastPathComponent) doesn't appear to be a text file."
            case .fetchFailed(let url, let status):
                return "Couldn't fetch \(url.absoluteString) (HTTP \(status))."
            case .empty(let url):
                return "Couldn't extract any readable text from \(url.absoluteString)."
            }
        }
    }

    /// Read a markdown / plaintext file picked from Files. Caller passes a URL from `.fileImporter`;
    /// security-scoped access is handled here.
    static func loadMarkdown(_ url: URL) async throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExtractError.readFailed(url, error)
        }
        guard let str = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ExtractError.nonText(url)
        }
        return normalise(str)
    }

    /// Fetch a URL, parse its HTML, and return the main article body as plain text.
    /// Uses `NSAttributedString(html:)` for extraction (good enough for most articles).
    @MainActor
    static func fetchAndExtract(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ExtractError.fetchFailed(url, http.statusCode)
        }

        #if canImport(UIKit)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let attr: NSAttributedString
        do {
            attr = try NSAttributedString(data: data, options: options, documentAttributes: nil)
        } catch {
            throw ExtractError.readFailed(url, error)
        }
        let text = normalise(attr.string)
        guard !text.isEmpty else { throw ExtractError.empty(url) }
        return text
        #else
        guard let str = String(data: data, encoding: .utf8) else {
            throw ExtractError.nonText(url)
        }
        return normalise(str)
        #endif
    }

    private static func normalise(_ text: String) -> String {
        // Collapse runs of blank lines to one and trim ends.
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        var lastBlank = false
        for line in lines {
            if line.isEmpty {
                if !lastBlank { result.append("") }
                lastBlank = true
            } else {
                result.append(line)
                lastBlank = false
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
