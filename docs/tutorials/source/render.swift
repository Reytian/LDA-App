import AppKit
import AVFoundation

// Compose LDA 2.0 window recordings and clearly labeled explanatory cards.
// All captured documents are synthetic. No audio track is created.
struct Scene: Decodable {
    let image: String?
    let crop: [Double]?
    let clip: String?
    let card: String?
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
let width = 1920
let height = 1080
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
struct RecordedFrame: Decodable { let file: String; let at: Double }
var assetRoot = URL(fileURLWithPath: ".")
var clips: [String:[RecordedFrame]] = [:]
var imageCache: [String:NSImage] = [:]
let blue = NSColor(srgbRed:0.25, green:0.32, blue:0.62, alpha:1)
let pale = NSColor(srgbRed:0.91, green:0.94, blue:0.98, alpha:1)
let dark = NSColor(srgbRed:0.13, green:0.17, blue:0.25, alpha:1)
func capturedImage(_ filename:String, crop:[Double]?, in target:NSRect) {
    let image: NSImage
    if let cached=imageCache[filename] { image=cached }
    else { guard let loaded=NSImage(contentsOf:assetRoot.appendingPathComponent(filename)) else { fatalError("Missing capture: \(filename)") }; image=loaded; imageCache[filename]=loaded }
    let c=crop ?? [0,0,image.size.width,image.size.height]
    let source=NSRect(x:c[0],y:image.size.height-c[1]-c[3],width:c[2],height:c[3])
    let scale=min(target.width/source.width,target.height/source.height)
    let rect=NSRect(x:target.midX-source.width*scale/2,y:target.midY-source.height*scale/2,width:source.width*scale,height:source.height*scale)
    image.draw(in:rect,from:source,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
}
func card(_ kind:String, in area:NSRect) {
    let x=area.minX+55, y=area.minY+48, w=area.width-110
    label(kind == "answer" ? "ILLUSTRATIVE AI RESPONSE" : "EXAMPLE / WORKFLOW OVERVIEW",x,y,w,18,blue,true,false,40)
    switch kind {
    case "answer":
        label("Agreement summary",x,y+68,w,42,dark,true)
        label("{COMPANY_1} engages {COMPANY_2} for monthly market research.",x,y+155,w,31,dark,false,true,150)
        label("The initial term is 12 months. The agreement renews for one year unless either party gives at least 30 days of written notice.",x,y+300,w,32,dark,false,false,200)
        label("Placeholders stay exactly as written.",x,y+530,w,28,blue,true)
    case "prompt":
        label("Ask for the work you need",x,y+65,w,43,dark,true)
        box(x,y+170,w,175,pale,16)
        label("$lda Summarize the renewal terms in these documents. Preserve all placeholders.",x+30,y+203,w-60,31,dark,false,true,160)
        label("Choose documents in LDA’s local picker.\nChoose the Matter locally if its name is private.",x,y+410,w,31,dark,false,false,190)
    case "connect":
        label("Complete the connection",x,y+65,w,43,dark,true)
        let rows=["1   Open the saved setup script in Terminal.","2   Restart Codex and check its MCP settings.","3   Ask: Run LDA’s connection check (attest)."]
        for (i,row) in rows.enumerated(){box(x,y+170+CGFloat(i)*125,w,100,pale,14);label(row,x+28,y+198+CGFloat(i)*125,w-56,29,dark,false,false,80)}
    case "local":
        label("Choose and review locally",x,y+65,w,43,dark,true)
        let rows=["Choose the documents on your Mac","Optionally review or add PII protection","Confirm the Matter in LDA"]
        for (i,row) in rows.enumerated(){box(x,y+160+CGFloat(i)*120,w,92,pale,14);label(row,x+28,y+187+CGFloat(i)*120,w-56,31,dark,true,false,75)}
        label("Only the redacted text goes to the AI.",x,y+550,w,29,blue,true)
    case "finish":
        label("Bring the original details back",x,y+65,w,43,dark,true)
        box(x,y+180,w,150,pale,16)
        label("Restore this summary locally and export it.",x+30,y+220,w-60,32,dark,false,true,100)
        label("Review the saved result on your Mac.\nKeep each document with its matching mapping.",x,y+420,w,32,dark,false,false,180)
    default:
        label("Your Mac",x,y+65,w,43,dark,true)
        label("Original documents\nLocal review\nEncrypted mapping\nRestored results",x,y+150,w,34,dark,false,false,250)
        box(x,y+435,w,150,pale,16)
        label("Your AI app receives\nthe reviewed, redacted text.",x+30,y+468,w-60,33,blue,true,false,120)
    }
}
func draw(story: Story, timed: TimedScene, index: Int, time: Double, total: Double) {
    let scene=timed.scene
    box(0,0,1920,1080,NSColor(srgbRed:0.95,green:0.965,blue:0.985,alpha:1),0)
    label("LDA 2.0",52,30,240,31,blue,true,false,55)
    label("FORME LOCALE STUDIO",270,40,600,18,muted,true,false,40)
    label(story.title,52,104,1750,45,dark,true,false,70)
    label(String(format:"%02d",index+1),52,222,285,68,blue,true,false,100)
    label(scene.title,52,342,312,39,dark,true,false,225)
    label(scene.action,52,602,300,25,muted,false,false,210)
    for i in story.scenes.indices { box(52+CGFloat(i)*27,862,19,5,i<=index ? blue : pale,2) }
    let area=NSRect(x:402,y:210,width:1466,height:695)
    box(area.minX,area.minY,area.width,area.height,.white,18)
    if let filename=scene.image {
        var current=filename
        if let clip=scene.clip, let frames=clips[clip], let last=frames.last {
            // Hold the first frame briefly, then preserve captured timing and hold the result.
            let elapsed=max(0,min(time-timed.start-0.9,last.at))
            current=frames.last(where:{$0.at<=elapsed})?.file ?? frames.first!.file
        }
        capturedImage(current,crop:scene.crop,in:area.insetBy(dx:20,dy:20))
    } else {card(scene.card ?? "boundary",in:area)}
    let tag=scene.image == nil ? "EXPLANATORY EXAMPLE" : "LDA 2.0 WINDOW CAPTURE"
    label(tag,404,170,1250,16,blue,true,false,30)
    label("Fictional documents · Silent · English captions",1290,42,578,18,muted,false,false,40)
    let caption=timed.cues.first(where: {time >= $0.start && time < $0.end})?.text ?? scene.captions.last!
    box(38,943,1844,100,dark,14)
    label(caption,66,965,1788,30,.white,false,false,78)
    box(38,1063,1844,4,pale,2)
    box(38,1063,1844*CGFloat(min(time/total,1)),4,blue,2)
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
    assetRoot = input.deletingLastPathComponent().appendingPathComponent("assets")
    clips = try JSONDecoder().decode([String:[RecordedFrame]].self, from: Data(contentsOf: assetRoot.appendingPathComponent("clips.json")))
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
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:2_800_000,AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel,AVVideoMaxKeyFrameIntervalKey:30]
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
        var transcript="# \(story.title)\n\nLDA 2.0 window recordings and explanatory cards. All documents are fictional. AI prompts and answers are illustrative. Silent video with English subtitles. Recorded interactions are edited for pacing; timings are not benchmarks.\n\n"
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
