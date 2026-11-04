import AVFoundation

/// Subtitles from separate .srt, .vtt and .ass files. They're added as extra
/// tracks in a small movie that points at the playing one, so they show up in
/// the subtitle menu next to the built-in tracks and nothing gets copied.
enum ExternalSubtitles {
    static let extensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    /// Files next to the video that start with its name (Movie.srt, Movie.en.srt,
    /// Movie.English.forced.srt), plus the Subs folder some releases come with.
    static func sidecars(for video: URL) -> [URL] {
        let base = video.deletingPathExtension().lastPathComponent
        let dir = video.deletingLastPathComponent()
        var found: [URL] = []
        for (folder, anyName) in [(dir, false), (dir.appendingPathComponent("Subs"), false),
                                  (dir.appendingPathComponent("Subs").appendingPathComponent(base), true)] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            found += files.filter { extensions.contains($0.pathExtension.lowercased()) && (anyName || $0.lastPathComponent.hasPrefix(base)) }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func cues(from url: URL) throws -> [Cue] {
        let text = decode(try Data(contentsOf: url))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        switch url.pathExtension.lowercased() {
        case "ass", "ssa": return ass(lines)
        default: return srt(lines)   // WebVTT cues look the same apart from the header
        }
    }

    /// Old SRTs are often Windows-1252 rather than UTF-8.
    static func decode(_ d: Data) -> String {
        if d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) { return String(data: d, encoding: .utf16) ?? "" }
        if let s = String(data: d, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        return String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
    }

    /// "01:02:03,456", "02:03.456" or ASS's "1:02:03.45", in milliseconds.
    static func ms<S: StringProtocol>(_ s: S) -> Int? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: " ").first?.split(separator: ":") ?? []
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + v
        }
        return Int((total * 1000).rounded())
    }

    static func srt(_ lines: [Substring]) -> [Cue] {
        var cues: [Cue] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard let arrow = line.range(of: "-->"), let start = ms(line[..<arrow.lowerBound]),
                  let end = ms(line[arrow.upperBound...]) else { continue }
            var body: [Substring] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[i])
                i += 1
            }
            let text = StyledText(markup: body.joined(separator: "\n"))
            if !text.isEmpty && end > start { cues.append(Cue(start: start, end: end, text: text)) }
        }
        return cues
    }

    static func ass(_ lines: [Substring]) -> [Cue] {
        var cues: [Cue] = []
        var section = ""
        var fields: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            guard section == "[events]" else { continue }
            if line.hasPrefix("Format:") {
                fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.hasPrefix("Dialogue:"), let s = fields.firstIndex(of: "start"), let e = fields.firstIndex(of: "end"),
                  let t = fields.firstIndex(of: "text") else { continue }
            let values = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
            guard values.count == fields.count, let start = ms(values[s]), let end = ms(values[e]) else { continue }
            let text = StyledText(markup: String(values[t]))
            if !text.isEmpty && end > start { cues.append(Cue(start: start, end: end, text: text)) }
        }
        return cues
    }

    /// The language from what follows the video's name: Movie.en.srt, Movie.English.srt.
    static func language(of file: URL, video: URL) -> String {
        var name = file.deletingPathExtension().lastPathComponent
        let base = video.deletingPathExtension().lastPathComponent
        if name.hasPrefix(base) { name.removeFirst(base.count) }
        let english = Locale(identifier: "en")
        for token in name.split(whereSeparator: { ".-_ ()[]".contains($0) }).reversed() {
            let t = token.lowercased()
            if ["sdh", "cc", "forced", "full"].contains(t) { continue }
            if (2...3).contains(t.count), english.localizedString(forLanguageCode: t) != nil, let code = MovieLanguage.alpha3(t) {
                return code
            }
            if let code = Locale.LanguageCode.isoLanguageCodes.first(where: {
                english.localizedString(forLanguageCode: $0.identifier)?.lowercased() == t
            }), let alpha3 = MovieLanguage.alpha3(code.identifier) {
                return alpha3
            }
        }
        return "und"
    }

    /// A movie with all of `movie`'s tracks plus one subtitle track per file.
    static func attach(_ files: [URL], to movieURL: URL, video: URL, in dir: URL) async throws -> URL {
        let movie = AVMutableMovie(url: movieURL, options: nil)
        let existing = try await movie.load(.tracks)
        let groups = existing.map(\.alternateGroupID)
        let subtitleGroup = existing.first { $0.mediaType == .subtitle || $0.mediaType == .text }?.alternateGroupID
        let group = subtitleGroup ?? (groups.max() ?? 0) + 1

        var added = 0
        for file in files {
            let language = language(of: file, video: video)
            guard let track = Subtitles.track(try cues(from: file), language: language, name: file.lastPathComponent) else { continue }
            let subMovie = dir.appendingPathComponent(UUID().uuidString + ".mov")
            try MovieWriter.write([track], to: subMovie)
            // insertTimeRange checks this without loading it, so it has to be loaded first.
            let sourceMovie = AVMovie(url: subMovie)
            _ = try await sourceMovie.load(.providesPreciseDurationAndTiming)
            guard let source = try await sourceMovie.loadTracks(withMediaType: .subtitle).first,
                  // Copying the source track's settings loses the alternate group on write.
                  let target = movie.addMutableTrack(withMediaType: .subtitle, copySettingsFrom: nil, options: nil) else { continue }
            target.alternateGroupID = group
            try target.insertTimeRange(try await source.load(.timeRange), of: source, at: .zero, copySampleData: false)
            target.isEnabled = false
            target.languageCode = language
            added += 1
        }
        guard added > 0 else { throw MediaError("No subtitles found in \(files.map(\.lastPathComponent).joined(separator: ", "))") }
        let out = dir.appendingPathComponent(UUID().uuidString + ".mov")
        try movie.writeHeader(to: out, fileType: .mov, options: .addMovieHeaderToDestination)
        return out
    }
}
