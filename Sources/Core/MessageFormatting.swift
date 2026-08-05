import Foundation

enum ChatImagePolicy {
    static let maximumEncodedDataURLBytes = 35 * 1_024 * 1_024
    static let maximumDecodedImageBytes = 25 * 1_024 * 1_024

    static func remoteURL(from rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 8_192,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }

    static func isAllowedDataURL(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= maximumEncodedDataURLBytes,
              let comma = value.firstIndex(of: ",") else { return false }
        let metadata = value[..<comma].lowercased()
        return metadata.hasPrefix("data:image/") && metadata.contains(";base64")
    }
}

enum ChatTextSanitizer {
    static func clean(_ input: String) -> String {
        var output = unwrapJSONEncodedStringIfNeeded(input)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Terminal output frequently contains ANSI CSI/OSC sequences. Rendering those bytes as
        // ordinary chat text produces strings such as "[0m" and other apparent mojibake.
        let escapePatterns = [
            "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)",
            "\u{001B}[@-_]"
        ]
        for pattern in escapePatterns {
            output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        output = repairUTF8MojibakeIfNeeded(output)

        let visibleScalars = output.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A:
                return true
            case 0x00...0x1F, 0x7F...0x9F, 0xFEFF, 0xFFFC:
                return false
            default:
                return true
            }
        }
        return String(String.UnicodeScalarView(visibleScalars)).precomposedStringWithCanonicalMapping
    }

    private static func unwrapJSONEncodedStringIfNeeded(_ input: String) -> String {
        guard input.first == "\"", input.last == "\"",
              input.contains(#"\n"#) || input.contains(#"\r"#) ||
              input.contains(#"\t"#) || input.contains(#"\u"#) else {
            return input
        }
        return (try? JSONDecoder().decode(String.self, from: Data(input.utf8))) ?? input
    }

    private static func repairUTF8MojibakeIfNeeded(_ input: String) -> String {
        let originalSuspiciousCount = suspiciousLatin1ScalarCount(in: input)
        guard originalSuspiciousCount >= 2 else { return input }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(input.unicodeScalars.count)
        for scalar in input.unicodeScalars {
            guard scalar.value <= UInt8.max else { return input }
            bytes.append(UInt8(scalar.value))
        }
        guard let repaired = String(data: Data(bytes), encoding: .utf8),
              suspiciousLatin1ScalarCount(in: repaired) < originalSuspiciousCount else {
            return input
        }
        return repaired
    }

    private static func suspiciousLatin1ScalarCount(in text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if (0x0080...0x00FF).contains(scalar.value) { count += 1 }
        }
    }
}

struct MessageTaskItem: Equatable, Sendable {
    let text: String
    let isCompleted: Bool
}

enum MessageBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String)
    case quote(String)
    case bulletedList([String])
    case numberedList([String])
    case taskList([MessageTaskItem])
    case table(headers: [String], rows: [[String]])
    case image(ChatImage)
    case divider
}

enum MessageBlockParser {
    static func parse(_ rawText: String) -> [MessageBlock] {
        let text = ChatTextSanitizer.clean(rawText)
        guard !text.isEmpty else { return [] }

        let lines = text.components(separatedBy: "\n")
        var blocks: [MessageBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = codeFence(in: trimmed) {
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, text: codeLines.joined(separator: "\n")))
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if let heading = heading(in: trimmed) {
                appendTextAndImages(heading.text, fallback: .heading(level: heading.level, text: heading.text), to: &blocks)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               looksLikeTableRow(line),
               isTableSeparator(lines[index + 1]) {
                let headers = tableCells(line)
                index += 2
                var rows: [[String]] = []
                while index < lines.count, looksLikeTableRow(lines[index]), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if let task = taskItem(in: line) {
                var items = [task]
                index += 1
                while index < lines.count, let next = taskItem(in: lines[index]) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.taskList(items))
                continue
            }

            if let bullet = bulletedItem(in: line) {
                var items = [bullet]
                index += 1
                while index < lines.count, let next = bulletedItem(in: lines[index]), taskItem(in: lines[index]) == nil {
                    items.append(next)
                    index += 1
                }
                blocks.append(.bulletedList(items))
                continue
            }

            if let numbered = numberedItem(in: line) {
                var items = [numbered]
                index += 1
                while index < lines.count, let next = numberedItem(in: lines[index]) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            if let quote = quotedText(in: line) {
                var quoteLines = [quote]
                index += 1
                while index < lines.count, let next = quotedText(in: lines[index]) {
                    quoteLines.append(next)
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count, !startsNewBlock(lines: lines, at: index) {
                paragraphLines.append(lines[index])
                index += 1
            }
            appendTextAndImages(paragraphLines.joined(separator: "\n"), fallback: nil, to: &blocks)
        }

        return blocks
    }

    private static func startsNewBlock(lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if codeFence(in: trimmed) != nil || isDivider(trimmed) || heading(in: trimmed) != nil ||
            taskItem(in: line) != nil || bulletedItem(in: line) != nil ||
            numberedItem(in: line) != nil || quotedText(in: line) != nil {
            return true
        }
        return index + 1 < lines.count && looksLikeTableRow(line) && isTableSeparator(lines[index + 1])
    }

    private static func codeFence(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix { $0 == "#" }
        guard (1...6).contains(prefix.count), line.dropFirst(prefix.count).first == " " else { return nil }
        return (prefix.count, String(line.dropFirst(prefix.count + 1)))
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func taskItem(in line: String) -> MessageTaskItem? {
        let pattern = #"^\s*[-*+]\s+\[([ xX])\]\s+(.+)$"#
        guard let match = firstMatch(pattern, in: line), match.count == 3 else { return nil }
        return MessageTaskItem(text: match[2], isCompleted: match[1].lowercased() == "x")
    }

    private static func bulletedItem(in line: String) -> String? {
        let match = firstMatch(#"^\s*[-*+]\s+(.+)$"#, in: line)
        return match?.count == 2 ? match?[1] : nil
    }

    private static func numberedItem(in line: String) -> String? {
        let match = firstMatch(#"^\s*\d+[.)]\s+(.+)$"#, in: line)
        return match?.count == 2 ? match?[1] : nil
    }

    private static func quotedText(in line: String) -> String? {
        let match = firstMatch(#"^\s*>\s?(.*)$"#, in: line)
        return match?.count == 2 ? match?[1] : nil
    }

    private static func looksLikeTableRow(_ line: String) -> Bool {
        tableCells(line).count >= 2
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { firstMatch(#"^:?-{3,}:?$"#, in: $0.trimmingCharacters(in: .whitespaces)) != nil }
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func appendTextAndImages(_ text: String, fallback: MessageBlock?, to blocks: inout [MessageBlock]) {
        let pattern = #"!\[([^\]]*)\]\(([^)\n]+)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            blocks.append(fallback ?? .paragraph(text))
            return
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else {
            if let image = bareImage(in: text) {
                blocks.append(.image(image))
            } else {
                blocks.append(fallback ?? .paragraph(text))
            }
            return
        }

        var cursor = text.startIndex
        var appendedImage = false
        for match in matches {
            guard let wholeRange = Range(match.range(at: 0), in: text),
                  let altRange = Range(match.range(at: 1), in: text),
                  let targetRange = Range(match.range(at: 2), in: text) else { continue }
            let target = markdownDestination(String(text[targetRange]))
            guard let image = markdownImage(id: "markdown-image-\(match.range.location)", target: target, altText: String(text[altRange])) else { continue }
            let before = String(text[cursor..<wholeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { blocks.append(.paragraph(before)) }
            blocks.append(.image(image))
            appendedImage = true
            cursor = wholeRange.upperBound
        }
        guard appendedImage else {
            if let image = bareImage(in: text) {
                blocks.append(.image(image))
            } else {
                blocks.append(fallback ?? .paragraph(text))
            }
            return
        }
        let remainder = String(text[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { blocks.append(.paragraph(remainder)) }
    }

    private static func markdownDestination(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), let closing = value.firstIndex(of: ">") {
            return String(value[value.index(after: value.startIndex)..<closing])
        }
        if let titleRange = value.range(of: #"\s+[\"']"#, options: .regularExpression) {
            value = String(value[..<titleRange.lowerBound])
        }
        return value
    }

    private static func markdownImage(id: String, target: String, altText: String) -> ChatImage? {
        if ChatImagePolicy.isAllowedDataURL(target) {
            return ChatImage(id: id, source: .dataURL(target), altText: altText.isEmpty ? "图片" : altText)
        }
        guard let url = ChatImagePolicy.remoteURL(from: target) else {
            return nil
        }
        return ChatImage(id: id, source: .remoteURL(url.absoluteString), altText: altText.isEmpty ? "图片" : altText)
    }

    private static func bareImage(in text: String) -> ChatImage? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("<"), candidate.hasSuffix(">") {
            candidate.removeFirst()
            candidate.removeLast()
        }
        guard !candidate.contains(where: { $0.isWhitespace }),
              let url = ChatImagePolicy.remoteURL(from: candidate) else { return nil }
        let supportedExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"]
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let filename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return ChatImage(
            id: "bare-image-\(candidate.hashValue)",
            source: .remoteURL(url.absoluteString),
            altText: filename.isEmpty ? "图片" : filename
        )
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}
