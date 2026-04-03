// ============================================================================
// CLI.swift — Command-line interface commands
// Part of ohr — On-device speech-to-text from the command line
// ============================================================================

import Foundation
import OhrCore

// MARK: - File Transcription

/// Transcribe a single audio file and print the result.
func transcribeFileCommand(path: String, language: String?, timestamps: Bool) async throws {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
        throw OhrError.fileNotFound(path)
    }
    guard AudioFormat.isSupported(filename: url.lastPathComponent) else {
        throw OhrError.unsupportedFormat(url.pathExtension)
    }

    let result = try await transcribeFile(url: url, language: language)

    switch outputFormat {
    case .plain:
        if timestamps {
            for segment in result.segments {
                let ts = SubtitleFormatter.formatTimestamp(segment.start, format: .srt)
                print("[\(ts)] \(segment.text)")
            }
        } else {
            print(result.text)
        }
    case .json:
        let response = OhrResponse(
            model: modelName,
            text: result.text,
            segments: result.segments.map {
                TranscriptionSegment(id: $0.id, start: $0.start, end: $0.end, text: $0.text)
            },
            duration: result.duration,
            language: result.language,
            metadata: .init(onDevice: true, version: version)
        )
        print(jsonString(response), terminator: "")
    case .srt:
        print(SubtitleFormatter.formatSRT(segments: result.segments), terminator: "")
    case .vtt:
        print(SubtitleFormatter.formatVTT(segments: result.segments), terminator: "")
    }
}

// MARK: - Stdin Transcription

/// Transcribe audio piped via stdin.
func transcribeFromStdin(language: String?) async throws {
    // Read all stdin data into a temporary file
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("ohr-stdin-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    var data = Data()
    while let byte = readLine(strippingNewline: false)?.data(using: .utf8) {
        data.append(byte)
    }
    // Also try reading raw bytes
    if data.isEmpty {
        let stdin = FileHandle.standardInput
        data = stdin.readDataToEndOfFile()
    }

    guard !data.isEmpty else {
        printError("No data received from stdin")
        exit(exitUsageError)
    }

    try data.write(to: tempURL)
    try await transcribeFileCommand(path: tempURL.path, language: language, timestamps: false)
}

// MARK: - Microphone Listening

/// Live transcription from the microphone.
func listenMicrophone(language: String?) async throws {
    guard isatty(STDOUT_FILENO) != 0 || outputFormat != .plain else {
        printError("--listen requires an interactive terminal or a non-plain output format")
        exit(exitUsageError)
    }

    printHeader()

    try await streamMicrophone(language: language) { segment in
        switch outputFormat {
        case .plain:
            let ts = SubtitleFormatter.formatTimestamp(segment.start, format: .srt)
            print("[\(ts)] \(segment.text)")
        case .json:
            let seg = TranscriptionSegment(id: segment.id, start: segment.start, end: segment.end, text: segment.text)
            print(jsonString(seg, pretty: false))
        case .srt:
            print("\(segment.id + 1)")
            print("\(SubtitleFormatter.formatTimestamp(segment.start, format: .srt)) --> \(SubtitleFormatter.formatTimestamp(segment.end, format: .srt))")
            print(segment.text)
            print()
        case .vtt:
            print("\(SubtitleFormatter.formatTimestamp(segment.start, format: .vtt)) --> \(SubtitleFormatter.formatTimestamp(segment.end, format: .vtt))")
            print(segment.text)
            print()
        }
    }
}

// MARK: - Headers

/// Print the listen mode header.
func printHeader() {
    guard !quietMode else { return }
    let header = styled("Apple Intelligence", .cyan, .bold)
        + styled(" · on-device speech-to-text · \(appName) v\(version)", .dim)
    let line = styled(String(repeating: "─", count: 56), .dim)
    printStderr(header)
    printStderr(line)
    printStderr(styled("Listening... (press Ctrl+C to stop)", .dim))
    printStderr("")
}

// MARK: - Model Info

/// Print SpeechTranscriber capabilities and supported languages.
func printModelInfo() async {
    let available = isSpeechAvailable()
    let langs = await speechSupportedLocales()

    let tree = [
        "\(styled("ohr", .cyan, .bold)) model info",
        "\(styled("├", .dim)) model:     \(modelName)",
        "\(styled("├", .dim)) available: \(available ? styled("yes", .green) : styled("no", .red))",
        "\(styled("├", .dim)) on-device: \(styled("always", .green))",
        "\(styled("├", .dim)) formats:   \(AudioFormat.allSupported.joined(separator: ", "))",
        "\(styled("├", .dim)) output:    plain, json, srt, vtt",
        "\(styled("└", .dim)) languages: \(langs.prefix(20).joined(separator: ", "))\(langs.count > 20 ? " (\(langs.count) total)" : "")",
    ]
    for line in tree {
        print(line)
    }
}

// MARK: - Release Info

/// Print detailed build information.
func printRelease() {
    let lines = [
        "\(styled("ohr", .cyan, .bold)) v\(version)",
        "",
        "  commit:     \(buildCommit)",
        "  branch:     \(buildBranch)",
        "  built:      \(buildDate)",
        "  swift:      \(buildSwiftVersion)",
        "  os:         \(buildOS)",
        "",
        "  model:      \(modelName)",
        "  on-device:  always (no cloud, no API keys)",
        "  framework:  Speech (SpeechAnalyzer, SpeechTranscriber)",
        "  requires:   macOS 26+, Apple Silicon",
        "",
        "  repo:       https://github.com/Arthur-Ficial/ohr",
    ]
    for line in lines {
        print(line)
    }
}

// MARK: - Usage

/// Print help text.
func printUsage() {
    let usage = """
    \(styled("ohr", .cyan, .bold)) — on-device speech-to-text

    \(styled("USAGE:", .bold))
      ohr <file>                   Transcribe an audio file
      ohr -o srt <file>            Transcribe to SRT subtitles
      ohr -o vtt <file>            Transcribe to VTT subtitles
      ohr -o json <file>           Transcribe to JSON with segments
      ohr --listen                 Live microphone transcription
      ohr --serve                  Start OpenAI-compatible HTTP server
      cat audio.wav | ohr          Transcribe from stdin

    \(styled("OPTIONS:", .bold))
      -o, --output <format>        Output: plain (default), json, srt, vtt
      --json                       Shorthand for -o json
      --srt                        Shorthand for -o srt
      --vtt                        Shorthand for -o vtt
      --timestamps                 Show timestamps in plain text output
      -l, --language <code>        Language code (e.g. en-US, de-DE)
      -q, --quiet                  Suppress headers and chrome
      --no-color                   Disable ANSI colors

    \(styled("SERVER OPTIONS:", .bold))
      --serve                      Start HTTP server
      --port <n>                   Server port (default: 11434, env: OHR_PORT)
      --host <addr>                Bind address (default: 127.0.0.1, env: OHR_HOST)
      --cors                       Enable CORS headers
      --allowed-origins <list>     Comma-separated allowed origins
      --no-origin-check            Disable origin validation
      --token <secret>             Require Bearer token (env: OHR_TOKEN)
      --token-auto                 Generate random token on startup
      --public-health              /health without auth on non-loopback
      --footgun                    Disable all protections (DANGEROUS)
      --max-concurrent <n>         Max concurrent requests (default: 5)
      --debug                      Enable /v1/logs endpoints

    \(styled("INFO:", .bold))
      -h, --help                   Show this help
      -v, --version                Show version
      --release                    Show detailed build info
      --model-info                 Show model capabilities

    \(styled("EXAMPLES:", .bold))
      ohr meeting.m4a                          Transcribe a meeting
      ohr -o srt lecture.wav > lecture.srt      Generate subtitles
      ohr meeting.m4a | apfel "summarize"      Pipe to apfel for summary
      ohr --listen --json                       Live transcription as JSON
      ohr --serve --token mysecret              Serve with auth

    \(styled("SUPPORTED FORMATS:", .bold))
      m4a, wav, mp3, mp4, caf, aiff, flac

    \(styled("ENVIRONMENT:", .bold))
      OHR_PORT        Server port (default: 11434)
      OHR_HOST        Server bind address (default: 127.0.0.1)
      OHR_TOKEN       Bearer token for server auth
      OHR_LANGUAGE    Default language code
      NO_COLOR        Disable ANSI colors (https://no-color.org)

    100% on-device. No cloud. No API keys. Apple Intelligence via SpeechAnalyzer.
    """
    print(usage)
}
