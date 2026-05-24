import Foundation

final class LocalSharePackageService {
    private static let maxCaptionFileBytes: UInt64 = 10 * 1024 * 1024

    func createPackage(
        videoURL: URL,
        project: RecordingProject,
        destinationDirectory: URL? = nil
    ) throws -> URL {
        let project = project.sanitizedForUse()
        let packageDirectory = try uniquePackageDirectory(
            for: videoURL,
            destinationDirectory: destinationDirectory
        )
        let assetsDirectory = packageDirectory.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assetsDirectory,
            withIntermediateDirectories: true
        )

        let videoName = "video.\(videoURL.pathExtension.isEmpty ? "mp4" : videoURL.pathExtension)"
        let packagedVideoURL = assetsDirectory.appendingPathComponent(videoName)
        try FileManager.default.copyItem(at: videoURL, to: packagedVideoURL)

        let captions = loadCaptions(from: project.captionsFileURL)
        let captionsURL = try writeCaptionsIfNeeded(captions, to: assetsDirectory)
        let shareSettings = (project.sharePageSettings ?? SharePageSettings()).sanitizedForUse()
        let resolvedTitle = shareSettings.resolvedTitleFallback ?? project.title
        let projectDuration = project.duration.seconds
        let safeDuration = projectDuration.isFinite && projectDuration > 0 ? projectDuration : 0
        let metadata = SharePackageMetadata(
            title: resolvedTitle,
            description: shareSettings.description,
            creatorName: shareSettings.creatorName,
            duration: safeDuration,
            generatedAt: Date(),
            videoPath: "assets/\(videoName)",
            captionsPath: captionsURL.map { "assets/\($0.lastPathComponent)" },
            chapters: (project.chapterMarkers ?? []).sorted { $0.time < $1.time },
            titleCards: (project.titleCardSegments ?? []).sorted { $0.startTime < $1.startTime },
            speakerNotes: project.speakerNotes ?? "",
            callToActionLabel: shareSettings.callToActionLabel,
            callToActionURL: shareSettings.validCallToActionURL?.absoluteString ?? "",
            accentHex: hexColor(from: shareSettings.accentColor),
            exportSettings: project.style
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata)
            .write(to: packageDirectory.appendingPathComponent("metadata.json"))

        let html = makeHTML(metadata: metadata)
        try html.write(
            to: packageDirectory.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )

        return packageDirectory.appendingPathComponent("index.html")
    }

    private func uniquePackageDirectory(
        for videoURL: URL,
        destinationDirectory: URL?
    ) throws -> URL {
        let baseDirectory = destinationDirectory ?? videoURL.deletingLastPathComponent()
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        var candidate = baseDirectory.appendingPathComponent("\(baseName)-share", isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = baseDirectory.appendingPathComponent("\(baseName)-share-\(index)", isDirectory: true)
            index += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private func loadCaptions(from url: URL?) -> [CaptionSegment] {
        guard let url,
              FileManager.default.fileExists(atPath: url.path),
              captionFileIsLoadable(url),
              let data = try? Data(contentsOf: url),
              let captions = try? JSONDecoder().decode([CaptionSegment].self, from: data) else {
            return []
        }
        return captions
            .compactMap(sanitizedCaption)
            .sorted { $0.start < $1.start }
    }

    private func captionFileIsLoadable(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return false
        }
        return fileSize.uint64Value <= Self.maxCaptionFileBytes
    }

    private func sanitizedCaption(_ caption: CaptionSegment) -> CaptionSegment? {
        guard caption.start.isFinite, caption.end.isFinite else { return nil }
        let start = max(0, min(caption.start, 24 * 60 * 60))
        let end = max(start + 0.05, min(caption.end, 24 * 60 * 60))
        let text = sanitizedVTTCueText(caption.text)
        guard !text.isEmpty else { return nil }
        return CaptionSegment(id: caption.id, start: start, end: end, text: text)
    }

    private func writeCaptionsIfNeeded(_ captions: [CaptionSegment], to directory: URL) throws -> URL? {
        guard !captions.isEmpty else { return nil }
        let url = directory.appendingPathComponent("captions.vtt")
        let body = captions.enumerated().map { index, caption in
            [
                String(index + 1),
                "\(vttTime(caption.start)) --> \(vttTime(caption.end))",
                sanitizedVTTCueText(caption.text)
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")
        try ("WEBVTT\n\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeHTML(metadata: SharePackageMetadata) -> String {
        let chaptersJSON = jsonString(for: metadata.chapters.map {
            ShareChapter(time: $0.time, title: $0.title)
        })
        let notes = htmlEscape(metadata.speakerNotes)
            .replacingOccurrences(of: "\n", with: "<br>")
        let captionTrack = metadata.captionsPath.map {
            "<track label=\"Captions\" kind=\"subtitles\" srclang=\"en\" src=\"\(htmlEscape($0))\" default>"
        } ?? ""
        let description = htmlEscape(metadata.description)
        let creator = htmlEscape(metadata.creatorName)
        let cta = callToActionHTML(metadata)

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(htmlEscape(metadata.title))</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", sans-serif; --accent: \(metadata.accentHex); }
            body { margin: 0; background: #08080a; color: #f4f4f5; }
            main { width: min(1120px, calc(100vw - 32px)); margin: 32px auto; display: grid; gap: 18px; }
            .player { background: linear-gradient(135deg, color-mix(in srgb, var(--accent) 22%, #17171c), #0e0f13); border: 1px solid #292a31; border-radius: 18px; padding: clamp(12px, 2vw, 22px); box-shadow: 0 26px 70px rgba(0,0,0,.48); }
            video { width: 100%; display: block; border-radius: 14px; background: #000; }
            .meta { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; }
            .title { display: grid; gap: 8px; }
            h1 { font-size: clamp(24px, 4vw, 42px); margin: 0; letter-spacing: 0; }
            p { line-height: 1.55; }
            .grid { display: grid; grid-template-columns: minmax(0, 1fr) 360px; gap: 18px; align-items: start; }
            section { background: #141418; border: 1px solid #292a31; border-radius: 14px; padding: 16px; }
            h2 { font-size: 14px; margin: 0 0 12px; color: #b8bbc7; text-transform: uppercase; letter-spacing: .08em; }
            button, input, textarea { font: inherit; }
            button, .cta { border: 0; border-radius: 10px; background: var(--accent); color: white; padding: 8px 11px; cursor: pointer; text-decoration: none; display: inline-flex; align-items: center; justify-content: center; }
            .chapter { width: 100%; display: flex; justify-content: space-between; gap: 12px; margin: 6px 0; background: #202127; text-align: left; }
            .reaction { background: #23242a; margin-right: 6px; }
            .muted { color: #9ca3af; font-size: 13px; }
            textarea { width: 100%; min-height: 74px; resize: vertical; box-sizing: border-box; border: 1px solid #333640; border-radius: 10px; background: #0f1014; color: #f4f4f5; padding: 10px; }
            .comment { border-top: 1px solid #2b2d35; padding: 10px 0 0; margin-top: 10px; color: #e5e7eb; }
            @media (max-width: 860px) { .grid { grid-template-columns: 1fr; } main { margin-top: 18px; } }
          </style>
        </head>
        <body>
          <main>
            <div class="meta">
              <div class="title">
                <h1>\(htmlEscape(metadata.title))</h1>
                \(creator.isEmpty ? "" : "<span class=\"muted\">By \(creator)</span>")
                \(description.isEmpty ? "" : "<p class=\"muted\">\(description)</p>")
              </div>
              <div>
                \(cta)
                <span class="muted" id="views"></span>
              </div>
            </div>
            <div class="player">
              <video id="video" controls playsinline preload="metadata" src="\(htmlEscape(metadata.videoPath))">
                \(captionTrack)
              </video>
            </div>
            <div class="grid">
              <section>
                <h2>Chapters</h2>
                <div id="chapters"></div>
                <h2 style="margin-top:18px">Story Cards</h2>
                <div id="cards"></div>
                <h2 style="margin-top:18px">Notes</h2>
                <p class="muted">\(notes.isEmpty ? "No speaker notes saved." : notes)</p>
              </section>
              <section>
                <h2>Reactions</h2>
                <div>
                  <button class="reaction" data-reaction="like">Like</button>
                  <button class="reaction" data-reaction="helpful">Helpful</button>
                  <button class="reaction" data-reaction="question">Question</button>
                </div>
                <div id="reactions"></div>
                <h2 style="margin-top:18px">Comments</h2>
                <textarea id="commentText" placeholder="Add a local comment"></textarea>
                <p><button id="saveComment">Save comment</button></p>
                <div id="comments"></div>
              </section>
            </div>
          </main>
          <script>
            const chapters = \(chaptersJSON);
            const cards = \(jsonString(for: metadata.titleCards.map { ShareTitleCard(startTime: $0.startTime, endTime: $0.endTime, title: $0.title, subtitle: $0.subtitle, kind: $0.kind.label) }));
            const video = document.getElementById('video');
            const storageKey = 'focusframe-share:' + location.pathname;
            const state = JSON.parse(localStorage.getItem(storageKey) || '{"views":0,"comments":[],"reactions":[]}');
            state.comments = Array.isArray(state.comments) ? state.comments : [];
            state.reactions = Array.isArray(state.reactions) ? state.reactions : [];
            state.views += 1;
            localStorage.setItem(storageKey, JSON.stringify(state));
            document.getElementById('views').textContent = state.views + ' local view' + (state.views === 1 ? '' : 's');
            const chapterList = document.getElementById('chapters');
            chapters.forEach(chapter => {
              const button = document.createElement('button');
              button.className = 'chapter';
              button.innerHTML = '<span>' + escapeHTML(chapter.title) + '</span><span>' + formatTime(chapter.time) + '</span>';
              button.onclick = () => { video.currentTime = chapter.time; video.play(); };
              chapterList.appendChild(button);
            });
            if (!chapters.length) chapterList.innerHTML = '<p class="muted">No chapters saved.</p>';
            const cardList = document.getElementById('cards');
            cards.forEach(card => {
              const button = document.createElement('button');
              button.className = 'chapter';
              button.innerHTML = '<span>' + escapeHTML(card.kind + ': ' + card.title) + '</span><span>' + formatTime(card.startTime) + '</span>';
              button.onclick = () => { video.currentTime = card.startTime; video.play(); };
              cardList.appendChild(button);
            });
            if (!cards.length) cardList.innerHTML = '<p class="muted">No story cards saved.</p>';
            function renderComments() {
              document.getElementById('comments').innerHTML = state.comments.map(raw => {
                const comment = typeof raw === 'string' ? { time: 0, text: raw } : raw;
                return '<div class="comment"><button class="reaction" onclick="jumpTo(' + Number(comment.time || 0) + ')">' + formatTime(Number(comment.time || 0)) + '</button> ' + escapeHTML(comment.text || '') + '</div>';
              }).join('');
            }
            function renderReactions() {
              document.getElementById('reactions').innerHTML = state.reactions.map(reaction => '<div class="comment"><button class="reaction" onclick="jumpTo(' + Number(reaction.time || 0) + ')">' + formatTime(Number(reaction.time || 0)) + '</button> ' + escapeHTML(reaction.type || '') + '</div>').join('');
            }
            document.getElementById('saveComment').onclick = () => {
              const input = document.getElementById('commentText');
              const text = input.value.trim();
              if (!text) return;
              state.comments.push({ time: video.currentTime || 0, text });
              input.value = '';
              localStorage.setItem(storageKey, JSON.stringify(state));
              renderComments();
            };
            document.querySelectorAll('.reaction').forEach(button => {
              button.onclick = () => {
                state.reactions.push({ time: video.currentTime || 0, type: button.dataset.reaction });
                localStorage.setItem(storageKey, JSON.stringify(state));
                renderReactions();
              };
            });
            function jumpTo(time) { video.currentTime = time; video.play(); }
            function formatTime(value) {
              const minutes = Math.floor(value / 60);
              const seconds = Math.floor(value % 60).toString().padStart(2, '0');
              return minutes + ':' + seconds;
            }
            function escapeHTML(value) {
              return value.replace(/[&<>"']/g, match => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[match]));
            }
            renderComments();
            renderReactions();
          </script>
        </body>
        </html>
        """
    }

    private func jsonString<T: Encodable>(for value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private func sanitizedVTTCueText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "-->", with: "- ->")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func vttTime(_ seconds: Double) -> String {
        let safeSeconds = seconds.isFinite ? min(max(0, seconds), 24 * 60 * 60) : 0
        let totalMilliseconds = max(0, Int((safeSeconds * 1000).rounded()))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let secs = (totalMilliseconds % 60_000) / 1000
        let millis = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }

    private func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func callToActionHTML(_ metadata: SharePackageMetadata) -> String {
        let label = metadata.callToActionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = metadata.callToActionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !url.isEmpty else { return "" }
        return "<a class=\"cta\" href=\"\(htmlEscape(url))\" target=\"_blank\" rel=\"noopener noreferrer\">\(htmlEscape(label))</a>"
    }

    private func hexColor(from color: CodableColor) -> String {
        let color = color.sanitized()
        let r = Int(max(0, min(color.r, 1)) * 255)
        let g = Int(max(0, min(color.g, 1)) * 255)
        let b = Int(max(0, min(color.b, 1)) * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private struct SharePackageMetadata: Encodable {
    let title: String
    let description: String
    let creatorName: String
    let duration: Double
    let generatedAt: Date
    let videoPath: String
    let captionsPath: String?
    let chapters: [ChapterMarker]
    let titleCards: [TitleCardSegment]
    let speakerNotes: String
    let callToActionLabel: String
    let callToActionURL: String
    let accentHex: String
    let exportSettings: StylePreset
}

private struct ShareChapter: Encodable {
    let time: Double
    let title: String
}

private struct ShareTitleCard: Encodable {
    let startTime: Double
    let endTime: Double
    let title: String
    let subtitle: String
    let kind: String
}
