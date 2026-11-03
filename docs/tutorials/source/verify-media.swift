import AppKit
import AVFoundation

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for name in ["lda-app-walkthrough", "lda-codex-walkthrough"] {
    let asset = AVURLAsset(url: base.appendingPathComponent(name + ".mp4"))
    let duration = CMTimeGetSeconds(asset.duration)
    precondition(duration > 60 && duration < 130)
    precondition(asset.metadata.isEmpty, "Unexpected movie metadata")
    let video = asset.tracks(withMediaType: .video)
    let audio = asset.tracks(withMediaType: .audio)
    precondition(video.count == 1 && audio.isEmpty)
    precondition(video[0].naturalSize == CGSize(width: 1920, height: 1080))
    let reader = try AVAssetReader(asset: asset)
    let decoded = AVAssetReaderTrackOutput(track: video[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    reader.add(decoded)
    precondition(reader.startReading())
    var frames = 0
    while decoded.copyNextSampleBuffer() != nil { frames += 1 }
    precondition(reader.status == .completed)
    precondition(abs(Double(frames) / 15 - duration) < 0.2)
    let item = AVPlayerItem(asset:asset)
    let player = AVPlayer(playerItem:item)
    let deadline = Date().addingTimeInterval(10)
    while item.status == .unknown && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
    precondition(item.status == .readyToPlay, "Native player cannot load movie")
    player.play()
    RunLoop.current.run(until:Date().addingTimeInterval(1))
    precondition(player.currentTime().seconds > 0.25, "Native player did not advance")
    player.pause()
    player.replaceCurrentItem(with:nil)
    print("PASS \(name): \(String(format:"%.2f",duration))s, 1920x1080, \(frames) decoded frames, zero audio tracks, native player ready, no movie metadata")
}
