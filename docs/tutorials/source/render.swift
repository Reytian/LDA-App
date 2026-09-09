import AppKit
import AVFoundation

// Render an original illustrated tutorial from a text-only storyboard.
// No display capture, user preferences, account data or network access is used.
struct Scene: Decodable {
    let kind: String
    let title: String
    let action: String
    let captions: [String]
}
struct Story: Decodable {
    let id: String
    let title: String
    let subtitle: String
    let scenes: [Scene]
}
struct Cue {
    let start: Double
    let end: Double
    let text: String
}
struct TimedScene {
    let scene: Scene
    let start: Double
    let end: Double
    let cues: [Cue]
}
enum RenderError: Error { case failed(String) }
let width = 1600
let height = 900
let fps: Int32 = 15
let ink = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.22, alpha: 1)
let teal = NSColor(srgbRed: 0.12, green: 0.40, blue: 0.38, alpha: 1)
let mint = NSColor(srgbRed: 0.87, green: 0.94, blue: 0.90, alpha: 1)
let cream = NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)
let muted = NSColor(srgbRed: 0.38, green: 0.44, blue: 0.44, alpha: 1)

func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: NSColor, _ radius: CGFloat = 16) {
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x:x,y:y,width:w,height:h), xRadius:radius,yRadius:radius).fill()
}
func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ size: CGFloat = 24,
           _ color: NSColor = ink, _ bold: Bool = false, _ mono: Bool = false, _ maxHeight: CGFloat = 160) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize:size,weight:bold ? .semibold : .regular)
        : NSFont.systemFont(ofSize:size,weight:bold ? .semibold : .regular)
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 6
    (text as NSString).draw(in:NSRect(x:x,y:y,width:w,height:maxHeight), withAttributes:[
        .font:font,.foregroundColor:color,.paragraphStyle:style
    ])
}
func pill(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, active: Bool = true) {
    box(x,y,w,48,active ? teal : mint,10)
    label(text,x+18,y+10,w-30,20,active ? .white : teal,true)
}
func line(_ text: String, y: CGFloat, highlighted: Bool = false, x: CGFloat = 536, w: CGFloat = 906) {
    if highlighted { box(x-14,y-7,w,48,mint,7) }
    label(text,x,y,w-22,24,ink,false,true,50)
}
func window(_ title: String) {
    box(466,190,1080,524,.white,20)
    box(466,190,1080,54,NSColor(srgbRed:0.90,green:0.93,blue:0.92,alpha:1),20)
    box(466,218,1080,26,NSColor(srgbRed:0.90,green:0.93,blue:0.92,alpha:1),0)
    for (i,c) in [NSColor.systemRed,NSColor.systemYellow,NSColor.systemGreen].enumerated() {
        box(487+CGFloat(i)*22,211,12,12,c,6)
    }
    label(title,580,203,900,20,ink,true)
}
func document(redacted: Bool, reviewed: Bool = false) {
    label("SERVICE AGREEMENT",536,278,850,20,muted,true)
    line(redacted ? "Client: {COMPANY_1}" : "Client: Cedar Example Studio",y:335,highlighted:reviewed)
    line(redacted ? "Contact: {PERSON_1}" : "Contact: Morgan Example",y:397,highlighted:reviewed)
    line(redacted ? "Email: {EMAIL_1}" : "Email: morgan@example.com",y:459,highlighted:reviewed)
    line("Renewal: annual; 30 days' notice to cancel.",y:535)
}
func cursor(_ x: CGFloat, _ y: CGFloat, _ progress: Double) {
    let r = CGFloat(18 + 7 * sin(progress * Double.pi * 2))
    teal.withAlphaComponent(0.16).setFill()
    NSBezierPath(ovalIn:NSRect(x:x-r,y:y-r,width:2*r,height:2*r)).fill()
    let path=NSBezierPath()
    path.move(to:NSPoint(x:x,y:y)); path.line(to:NSPoint(x:x+3,y:y+30))
    path.line(to:NSPoint(x:x+10,y:y+22)); path.line(to:NSPoint(x:x+18,y:y+33))
    path.line(to:NSPoint(x:x+24,y:y+29)); path.line(to:NSPoint(x:x+17,y:y+19))
    path.line(to:NSPoint(x:x+29,y:y+17)); path.close()
    ink.setFill(); path.fill(); NSColor.white.setStroke(); path.lineWidth=2; path.stroke()
}
func draw(story: Story, timed: TimedScene, index: Int, time: Double, total: Double) {
    let s=timed.scene
    let progress=(time-timed.start)/(timed.end-timed.start)
    box(0,0,1600,900,cream,0)
    label("LDA",54,32,150,32,teal,true)
    label("FORME LOCALE STUDIO",146,42,470,17,muted,true)
    box(919,32,627,40,mint,20)
    label("ILLUSTRATED WALKTHROUGH  ·  FICTIONAL DATA",940,42,590,16,teal,true)
    label(story.title,54,109,1470,43,ink,true)
    label(String(format:"%02d",index+1),54,200,350,74,teal,true)
    label(s.title,54,304,370,35,ink,true,false,180)
    label(s.action,54,505,354,23,muted,false,false,160)
    for i in story.scenes.indices {
        box(54+CGFloat(i)*49,678,36,5,i<=index ? teal : NSColor.lightGray,2)
    }
    var point = NSPoint(x:1400,y:635)
    switch s.kind {
    case "model":
        window("LDA  /  Detection setup")
        label("Choose a local detection model",526,279,950,30,ink,true)
        box(526,344,954,108,mint,14)
        label("Detection model",550,366,890,26,teal,true)
        label("Download or import a compatible model for this Mac.",550,407,860,21,muted)
        label("Patterns only",550,485,850,25,ink,true)
        label("Limited coverage: emails, dates, numbers and similar patterns.",550,527,850,21,muted)
        pill("Continue",1270,626,196)
    case "import":
        window("LDA  /  Anonymize")
        document(redacted:false)
        pill("Scan for PII",1220,626,246)
    case "review", "localreview":
        window(s.kind == "review" ? "LDA  /  Review findings" : "LDA  /  Local PII review")
        document(redacted:false,reviewed:true)
        pill("Add protection",526,626,246,active:false)
        pill(s.kind == "review" ? "Safe Preview" : "Continue",1220,626,246)
    case "export":
        window("LDA  /  Safe Preview")
        document(redacted:true,reviewed:true)
        pill("Export for AI",1220,626,246)
    case "cloud":
        window("AI app  /  Redacted document only")
        box(526,282,954,106,mint,14)
        label("Summarize the renewal terms. Preserve placeholders.",552,312,900,25,teal,true)
        line("{COMPANY_1} renews annually.",y:441)
        line("Give 30 days' notice to cancel.",y:497)
        pill("Save AI result",1220,626,246)
    case "restore":
        window("LDA  /  Restore")
        label("Edited document + matching local mapping",526,280,960,28,ink,true)
        box(526,350,954,208,mint,14)
        label("Cedar Example Studio renews annually.",552,387,900,28,teal,true)
        label("Give 30 days' notice to cancel.",552,444,900,26)
        label("Review restored values before saving.",552,495,900,22,muted)
        pill("Save",1270,626,196)
    case "setup":
        window("LDA Settings  /  MCP Setup")
        label("Connect LDA to your AI app",526,278,940,31,ink,true)
        box(526,342,954,69,mint,12)
        label("AI app                                      Codex",548,361,900,25,teal,true)
        label("MCP helper is ready",548,445,900,25)
        label("Save the script, run it locally, then restart Codex.",548,501,900,23,muted)
        pill("Save Setup Script",1160,612,306)
    case "command":
        window("Codex  /  New task")
        label("Start with the LDA skill",526,278,900,30,ink,true)
        box(526,344,954,118,mint,14)
        label("/LDA",551,367,850,29,teal,true,true)
        label("LDA   Choose documents locally and work with redacted text",551,414,875,22)
        box(526,500,954,94,cream,14)
        let prompt="/LDA Summarize the renewal terms."
        let count=min(prompt.count,Int(progress*Double(prompt.count)*2)+4)
        label(String(prompt.prefix(count)),550,528,900,28,ink,false,true)
        label("Codex skill reference: $lda",550,630,890,22,muted,false,true)
        point=NSPoint(x:760,y:424)
    case "picker":
        window("LDA  /  Choose local documents")
        label("Choose a file on your Mac",526,279,920,31,ink,true)
        box(526,349,954,70,mint,12)
        label("Fictional-Service-Agreement.docx",550,370,900,26,teal,true)
        box(532,478,28,28,teal,6)
        label("✓",536,475,35,26,.white,true)
        label("Review and add PII protection",578,476,860,25)
        label("Next: confirm the Matter locally in LDA.",532,547,900,22,muted)
        pill("Choose",1270,626,196)
    case "answer":
        window("Codex  /  Redacted answer")
        label("LDA prepared the reviewed document",526,279,945,29,teal,true)
        box(526,347,954,206,cream,14)
        label("Renewal summary",554,370,895,27,ink,true)
        line("{COMPANY_1} renews annually.",y:431,x:554,w:896)
        line("Give 30 days' notice to cancel.",y:487,x:554,w:896)
        label("Check the answer and any detection-coverage warnings.",548,612,900,22,muted)
        point=NSPoint(x:1300,y:540)
    case "codexrestore":
        window("Codex + LDA  /  Restore locally")
        box(526,279,954,102,mint,14)
        label("Restore this summary locally and export it.",552,311,900,26,teal,true)
        label("LDA",550,432,900,25,ink,true)
        label("Restoration complete. Local export saved.",550,481,900,27)
        label("Open and review the saved result on your Mac.",550,545,900,22,muted)
        pill("Local output",1220,626,246,active:false)
    default:
        window(s.kind == "recap" ? "LDA  /  Ready to begin" : "LDA in Codex  /  Ready to begin")
        let rows = s.kind == "recap" ? ["1   Add and scan a local document","2   Review and export the redacted version","3   Restore using the matching local mapping"]
            : ["1   Invoke /LDA and give your instruction","2   Choose documents and review locally","3   Work with the redacted answer"]
        for (i,row) in rows.enumerated() {
            box(526,285+CGFloat(i)*104,954,78,i == 1 ? mint : cream,14)
            label(row,550,308+CGFloat(i)*104,900,24,ink,true)
        }
        label("Keep originals, mappings and passwords local.",550,633,900,24,teal,true)
    }
    if !s.kind.hasSuffix("recap") { cursor(point.x,point.y,progress) }
    let caption=timed.cues.first(where: { time >= $0.start && time < $0.end })?.text ?? s.captions.last!
    box(38,747,1524,114,ink,16)
    label(caption,72,769,1456,27,.white,false,false,91)
    box(38,879,1524,5,mint,2)
    box(38,879,1524*CGFloat(min(time/total,1)),5,teal,2)
}

func timestamp(_ seconds: Double) -> String {
    let ms=Int((seconds*1000).rounded())
    return String(format:"%02d:%02d:%02d.%03d",ms/3600000,ms/60000%60,ms/1000%60,ms%1000)
}
func run() throws {
    guard CommandLine.arguments.count == 3 else { throw RenderError.failed("Usage: render storyboards.json output-directory") }
    let input=URL(fileURLWithPath:CommandLine.arguments[1])
    let out=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    let stories=try JSONDecoder().decode([Story].self,from:Data(contentsOf:input))
    for story in stories {
        var timeline:[TimedScene]=[]
        var clock=0.0
        for scene in story.scenes {
            let start=clock
            var cues:[Cue]=[]
            for caption in scene.captions {
                // Allow at least four seconds per subtitle, with extra time for longer text.
                let duration = max(4.0, Double(caption.split(whereSeparator: { $0.isWhitespace }).count) / 2.6 + 0.8)
                let end = clock + duration
                cues.append(Cue(start: clock, end: end, text: caption)); clock = end
            }
            timeline.append(TimedScene(scene:scene,start:start,end:clock,cues:cues))
        }
        let silent=out.appendingPathComponent(story.id+".mp4")
        let writer=try AVAssetWriter(outputURL:silent,fileType:.mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput=AVAssetWriterInput(mediaType:.video,outputSettings:[
            AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:1_100_000,AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel,AVVideoMaxKeyFrameIntervalKey:30]
        ])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:videoInput,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
            kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true
        ])
        guard writer.canAdd(videoInput) else { throw RenderError.failed("Cannot add video input") }
        writer.add(videoInput)
        guard writer.startWriting() else { throw writer.error ?? RenderError.failed("Cannot start writer") }
        writer.startSession(atSourceTime:.zero)
        let frames=Int(ceil(clock*Double(fps)))
        for frame in 0..<frames {
            try autoreleasepool {
                while !videoInput.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error ?? RenderError.failed("Video encoding failed") }
                    Thread.sleep(forTimeInterval:0.003)
                }
                var pixel:CVPixelBuffer?
                guard let pool=adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel) == kCVReturnSuccess,
                      let pixel else { throw RenderError.failed("Cannot allocate frame") }
                CVPixelBufferLockBaseAddress(pixel,[])
                defer { CVPixelBufferUnlockBaseAddress(pixel,[]) }
                guard let cg=CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:width,height:height,bitsPerComponent:8,
                    bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw RenderError.failed("Cannot draw frame") }
                cg.translateBy(x:0,y:CGFloat(height)); cg.scaleBy(x:1,y:-1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
                let time=Double(frame)/Double(fps)
                let index=timeline.firstIndex(where: {time < $0.end}) ?? timeline.count-1
                draw(story:story,timed:timeline[index],index:index,time:time,total:clock)
                NSGraphicsContext.restoreGraphicsState()
                if frame == 0 || (index > 0 && time-Double(1)/Double(fps) < timeline[index].start) {
                    guard let image=cg.makeImage() else { throw RenderError.failed("Poster creation failed") }
                    let bitmap=NSBitmapImageRep(cgImage:image)
                    guard let png=bitmap.representation(using:.png,properties:[:]) else { throw RenderError.failed("PNG encoding failed") }
                    try png.write(to:out.appendingPathComponent("\(story.id)-scene-\(index+1).png"))
                    if frame == 0 { try png.write(to:out.appendingPathComponent(story.id+".png")) }
                }
                guard adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(frame),timescale:fps)) else {
                    throw writer.error ?? RenderError.failed("Cannot append frame")
                }
            }
        }
        videoInput.markAsFinished()
        let finished=DispatchSemaphore(value:0)
        writer.finishWriting { finished.signal() }; finished.wait()
        guard writer.status == .completed else { throw writer.error ?? RenderError.failed("Video finalization failed") }
        var vtt="WEBVTT\n\n"
        var transcript="# \(story.title)\n\nIllustrated walkthrough. All data is fictional. Silent video with English subtitles.\n\n"
        for item in timeline {
            transcript += "## \(timestamp(item.start))  \(item.scene.title)\n\n"
            for cue in item.cues {
                vtt += "\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n\n"
                transcript += cue.text+"\n\n"
            }
        }
        try (vtt.trimmingCharacters(in: .newlines) + "\n").write(to:out.appendingPathComponent(story.id+".vtt"),atomically:true,encoding:.utf8)
        try (transcript.trimmingCharacters(in: .newlines) + "\n").write(to:out.appendingPathComponent(story.id+".md"),atomically:true,encoding:.utf8)
        print("RENDERED \(story.id): \(String(format:"%.2f",clock)) seconds, \(frames) frames, \(timeline.flatMap(\.cues).count) captions")
        fflush(stdout)
    }
}
do { try run() } catch {
    fputs("Tutorial rendering failed: \(error)\n",stderr)
    exit(1)
}
