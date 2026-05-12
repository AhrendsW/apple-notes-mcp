import Foundation

struct MarkdownConverter: Sendable {
    func markdownToHTML(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)

        var html: [String] = []
        var paragraph: [String] = []
        var inCodeBlock = false
        var codeLines: [String] = []
        var listKind: String?
        var inBlockquote = false
        var tableBuffer: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        func flushList() {
            guard let kind = listKind else { return }
            html.append("</\(kind)>")
            listKind = nil
        }

        func flushBlockquote() {
            guard inBlockquote else { return }
            html.append("</blockquote>")
            inBlockquote = false
        }

        func flushTable() {
            guard tableBuffer.count >= 2 else {
                tableBuffer.removeAll()
                return
            }
            let rows = tableBuffer.map { $0.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            guard let header = rows.first, rows.count > 2 else {
                tableBuffer.removeAll()
                return
            }
            html.append("<table><thead><tr>\(header.map { "<th>\(inline($0))</th>" }.joined())</tr></thead><tbody>")
            for row in rows.dropFirst(2) {
                html.append("<tr>\(row.map { "<td>\(inline($0))</td>" }.joined())</tr>")
            }
            html.append("</tbody></table>")
            tableBuffer.removeAll()
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushParagraph()
                flushList()
                flushBlockquote()
                flushTable()
                if inCodeBlock {
                    html.append("<pre><code>\(escapeHTML(codeLines.joined(separator: "\n")))</code></pre>")
                    codeLines.removeAll()
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                flushBlockquote()
                flushTable()
                continue
            }

            if trimmed.contains("|") {
                flushParagraph()
                flushList()
                flushBlockquote()
                tableBuffer.append(trimmed)
                continue
            } else {
                flushTable()
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                if !inBlockquote {
                    html.append("<blockquote>")
                    inBlockquote = true
                }
                let content = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                html.append("<p>\(inline(content))</p>")
                continue
            } else {
                flushBlockquote()
            }

            if let heading = headingHTML(trimmed) {
                flushParagraph()
                flushList()
                html.append(heading)
                continue
            }

            if let item = unorderedListItem(trimmed) {
                flushParagraph()
                if listKind != "ul" {
                    flushList()
                    html.append("<ul>")
                    listKind = "ul"
                }
                html.append("<li>\(inline(item))</li>")
                continue
            }

            if let item = orderedListItem(trimmed) {
                flushParagraph()
                if listKind != "ol" {
                    flushList()
                    html.append("<ol>")
                    listKind = "ol"
                }
                html.append("<li>\(inline(item))</li>")
                continue
            }

            paragraph.append(trimmed)
        }

        if inCodeBlock {
            html.append("<pre><code>\(escapeHTML(codeLines.joined(separator: "\n")))</code></pre>")
        }
        flushParagraph()
        flushList()
        flushBlockquote()
        flushTable()
        return html.joined(separator: "\n")
    }

    func htmlToMarkdown(_ html: String) -> String {
        var text = html
        let replacements: [(String, String)] = [
            ("</h1>", "\n\n"), ("</h2>", "\n\n"), ("</h3>", "\n\n"),
            ("</p>", "\n\n"), ("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"),
            ("</li>", "\n"), ("</blockquote>", "\n\n"), ("</pre>", "\n\n"),
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\"")
        ]
        text = text.replacingOccurrences(of: "<h1>", with: "# ")
        text = text.replacingOccurrences(of: "<h2>", with: "## ")
        text = text.replacingOccurrences(of: "<h3>", with: "### ")
        text = text.replacingOccurrences(of: "<li>", with: "- ")
        text = text.replacingOccurrences(of: "<blockquote>", with: "> ")
        text = text.replacingOccurrences(of: "<pre><code>", with: "```\n")
        text = text.replacingOccurrences(of: "</code></pre>", with: "\n```")
        for (from, to) in replacements {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func headingHTML(_ line: String) -> String? {
        let count = line.prefix { $0 == "#" }.count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        let content = line.dropFirst(count + 1)
        return "<h\(count)>\(inline(String(content)))</h\(count)>"
    }

    private func unorderedListItem(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        return String(line.dropFirst(2))
    }

    private func orderedListItem(_ line: String) -> String? {
        let pattern = #"^\d+\.\s+(.+)$"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(line[range])
        guard let dot = matched.firstIndex(of: ".") else { return nil }
        return String(matched[matched.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
    }

    private func inline(_ text: some StringProtocol) -> String {
        var escaped = escapeHTML(String(text))
        escaped = escaped.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "<code>$1</code>",
            options: .regularExpression
        )
        escaped = escaped.replacingOccurrences(
            of: #"\*\*([^*]+)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        escaped = escaped.replacingOccurrences(
            of: #"\*([^*]+)\*"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )
        escaped = escaped.replacingOccurrences(
            of: #"\[([^\]]+)\]\(([^)]+)\)"#,
            with: #"<a href="$2">$1</a>"#,
            options: .regularExpression
        )
        return escaped
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

