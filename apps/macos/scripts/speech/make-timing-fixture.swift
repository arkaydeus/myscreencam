#!/usr/bin/env swift
// Replaces a recording's microphone track with synthesised speech and writes ground-truth start times for the first
// word of every phrase, for timing benchmarks (docs/speech-integration.md).
//
//   swift scripts/speech/make-timing-fixture.swift <package.mscam> "<text>" [voice-language, default en-US]
//
// The text is split into phrases at punctuation; each phrase is synthesised separately (AVSpeechSynthesizer), its
// real onset measured from the audio, and the phrases are joined with 0.35 s pauses. Speech within a phrase is
// natural connected speech; only phrase-initial words get a ground-truth start (the synthesiser doesn't report
// word markers when writing to buffers). Writes `mic.m4a` and `speech-words.json` ([{"word", "start"}], session
// seconds: the package's microphone stream offset is added).

import AVFoundation
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-timing-fixture.swift <package> <text> [language]\n".utf8))
    exit(2)
}
let package = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)
let text = args[1]
let language = args.count > 2 ? args[2] : "en-US"

let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appending(path: "meta.json"))) as? [String: Any]
let streams = meta?["streams"] as? [String: Any] ?? [:]
let micOffset = (streams["microphone"] as? [String: Any])?["startOffset"] as? Double ?? 0

/// Phrases: split after , . ; : ? ! keeping the punctuation.
var phrases: [String] = []
var current = ""
for c in text {
    current.append(c)
    if ",.;:?!".contains(c) {
        let p = current.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { phrases.append(p) }
        current = ""
    }
}
if !current.trimmingCharacters(in: .whitespaces).isEmpty { phrases.append(current.trimmingCharacters(in: .whitespaces)) }

let synthesizer = AVSpeechSynthesizer()
let voice = AVSpeechSynthesisVoice(language: language)

/// Mono Float32 samples of one phrase.
func synthesise(_ phrase: String) -> (samples: [Float], rate: Double) {
    let utterance = AVSpeechUtterance(string: phrase)
    utterance.voice = voice
    nonisolated(unsafe) var samples: [Float] = []
    nonisolated(unsafe) var rate = 22_050.0
    nonisolated(unsafe) var done = false
    synthesizer.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            done = true
            return
        }
        rate = pcm.format.sampleRate
        let n = Int(pcm.frameLength)
        if let f = pcm.floatChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: f[0], count: n))
        } else if let i = pcm.int16ChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32_768 })
        }
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return (samples, rate)
}

var output: [Float] = []
var sampleRate = 22_050.0
var truth: [[String: Any]] = []
for phrase in phrases {
    let (samples, rate) = synthesise(phrase)
    sampleRate = rate
    // Onset: first 5 ms block whose RMS exceeds 2 % of the phrase's peak.
    let peak = samples.map(abs).max() ?? 0
    let block = Int(rate / 200)
    var onset = 0
    var i = 0
    while i + block <= samples.count {
        let rms = (samples[i..<(i + block)].reduce(0) { $0 + $1 * $1 } / Float(block)).squareRoot()
        if rms > peak * 0.02 {
            onset = i
            break
        }
        i += block
    }
    let first = phrase.split(separator: " ").first.map(String.init) ?? phrase
    truth.append(["word": first, "start": micOffset + Double(output.count + onset) / rate])
    output += samples
    output += [Float](repeating: 0, count: Int(0.35 * rate))
}

let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
let destination = package.appending(path: "mic.m4a")
try? FileManager.default.removeItem(at: destination)
let file = try AVAudioFile(
    forWriting: destination,
    settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1],
    commonFormat: .pcmFormatFloat32, interleaved: false)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(output.count))!
buffer.frameLength = AVAudioFrameCount(output.count)
output.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: output.count) }
try file.write(from: buffer)
file.close()  // finalises the container (a top-level file is never deinitialised)
try JSONSerialization.data(withJSONObject: truth, options: [.prettyPrinted])
    .write(to: package.appending(path: "speech-words.json"))
print("\(phrases.count) phrases, \(String(format: "%.1f", Double(output.count) / sampleRate)) s")
