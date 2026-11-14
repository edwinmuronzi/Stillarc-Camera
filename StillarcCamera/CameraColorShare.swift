import Foundation
import CoreImage

nonisolated enum CameraColorShare {
    static func export(style:StyleParams,lut:CubeLUT?,intensity:Float) throws ->URL {
        try Task.checkCancellation()
        let n=33,w=n*n
        var values=[Float]();values.reserveCapacity(n*n*n*4)
        for b in 0..<n {for g in 0..<n {for r in 0..<n {values.append(contentsOf:[Float(r)/Float(n-1),Float(g)/Float(n-1),Float(b)/Float(n-1),1])}}}
        let data=values.withUnsafeBytes {Data($0)}
        let source=CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:n),format:.RGBAf,colorSpace:nil)
        var colour=style;colour.grain=0;colour.halation=0;colour.vignette=0;colour.glow=0;colour.soften=0;colour.sharpen=0;colour.stamp=false
        let image=StyleGrade.grade(source,cube:lut?.data,cubeSize:lut?.size ?? 0,intensity:intensity,style:colour)
        let context=CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull(),.cacheIntermediates:false])
        context.render(image,toBitmap:&values,rowBytes:w*16,bounds:source.extent,format:.RGBAf,colorSpace:nil)
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("StillarcSharedColour-\(UUID())")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var success=false;defer {if !success {try? FileManager.default.removeItem(at:folder)}}
        let url=folder.appendingPathComponent("Stillarc Camera Colour.cube")
        var text="# Stillarc Camera colour-only look. Display-sRGB input/output.\n# Spatial texture, camera exposure, focus and HDR are excluded.\nTITLE \"Stillarc Camera Colour\"\nLUT_3D_SIZE 33\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        let locale=Locale(identifier:"en_US_POSIX")
        for i in stride(from:0,to:values.count,by:4) {
            if i%4096==0 {try Task.checkCancellation()}
            guard (0..<3).allSatisfy({values[i+$0].isFinite}) else {throw CocoaError(.fileWriteUnknown)}
            text+=String(format:"%.9g %.9g %.9g\n",locale:locale,min(1,max(0,values[i])),min(1,max(0,values[i+1])),min(1,max(0,values[i+2])))
        }
        try text.write(to:url,atomically:true,encoding:.utf8);success=true;return url
    }
    static func cubeText(_ package:StillarcLookPackage) throws ->String {
        var text="TITLE \"Stillarc shared colour\"\nLUT_3D_SIZE \(package.dimension)\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
        let values=package.cube.withUnsafeBytes {Array($0.bindMemory(to:Float.self))}
        for i in stride(from:0,to:values.count,by:4) {if i%4096==0 {try Task.checkCancellation()};text+=String(format:"%.9g %.9g %.9g\n",locale:Locale(identifier:"en_US_POSIX"),values[i],values[i+1],values[i+2])}
        return text
    }
    static func exportNative(style:StyleParams,lut:CubeLUT?,intensity:Float) throws ->URL {
        let url=try export(style:style,lut:lut,intensity:intensity);defer {try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}
        guard let parsed=CubeLUT.parse(text:try String(contentsOf:url,encoding:.utf8),name:"Stillarc Camera colour") else {throw StillarcLookPackage.failure("Could not prepare the shared colour.")}
        return try StillarcLookPackage(name:parsed.name,dimension:parsed.size,cube:parsed.data,excluded:["Grain, halation, spatial texture, framing, HDR and camera settings"]).write()
    }

}
