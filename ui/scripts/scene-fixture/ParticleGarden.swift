import AppKit
import Metal
import MetalKit

final class ParticleView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState!
    private var start = CACurrentMediaTime()
    private var mouse = SIMD2<Float>(-2, -2)
    private var tracking: NSTrackingArea?

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        delegate = self
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 position [[position]]; float2 uv; };
        vertex VOut vertexMain(uint id [[vertex_id]]) {
          float2 p[6] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
          VOut o; o.position=float4(p[id],0,1); o.uv=p[id]*0.5+0.5; return o;
        }
        fragment float4 fragmentMain(VOut in [[stage_in]], constant float &t [[buffer(0)]], constant float2 &mouse [[buffer(1)]]) {
          float2 p=(in.uv-0.5)*float2(1.0, 0.58);
          float glow=0.0;
          for(int i=0;i<36;i++){ float fi=float(i); float a=fi*2.399+t*(0.12+fi*0.001); float r=0.12+0.78*fract(fi*0.618); float2 q=float2(cos(a),sin(a))*r; float d=length(p-q); glow+=0.013/(d*d+0.001); }
          float m=length(p-mouse); glow+=0.08/(m*m+0.01);
          float3 col=float3(0.025,0.04,0.13)+glow*float3(0.12,0.62,1.0);
          return float4(clamp(col,0.0,1.0),1.0);
        }
        """
        let library = try! device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
    }
    required init(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }
    override func mouseMoved(with event: NSEvent) { record(event) }
    override func mouseDragged(with event: NSEvent) { record(event) }
    override func mouseDown(with event: NSEvent) { record(event) }
    private func record(_ e: NSEvent) { let p=convert(e.locationInWindow, from:nil); mouse=SIMD2(Float(p.x/bounds.width*2-1),Float(p.y/bounds.height*2-1)) }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        var t = Float(CACurrentMediaTime() - start)
        var m = mouse
        encoder.setFragmentBytes(&t, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&m, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

let app=NSApplication.shared
app.setActivationPolicy(.accessory)
for screen in NSScreen.screens {
    let window=NSWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false,screen:screen)
    window.level=NSWindow.Level(rawValue:-2147483610)
    window.isOpaque=true; window.backgroundColor=NSColor(red:0.025,green:0.04,blue:0.13,alpha:1)
    window.ignoresMouseEvents=CommandLine.arguments.contains("--interactive") == false
    window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
    window.contentView=ParticleView(); window.orderFrontRegardless()
}
app.run()
