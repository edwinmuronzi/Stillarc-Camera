#if DEBUG
import CoreImage
import Foundation

nonisolated enum CameraColourQA {
    static func check(_ value:Bool,_ text:String) throws {if !value {throw NSError(domain:"CameraColourQA",code:1,userInfo:[NSLocalizedDescriptionKey:text])}}
    static func run(_ docs:URL) throws ->Data {
        let context=CIContext(options:[.workingColorSpace:NSNull(),.outputColorSpace:NSNull(),.cacheIntermediates:false])
        func pixel(_ image:CIImage)->[Float] {var p=[Float](repeating:0,count:4);context.render(image,toBitmap:&p,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:nil);return p}
        var style=StyleParams();style.saturation=0.9;style.contrast=1.08;style.warmth=0.12;style.shadowLift=0.03
        let url=try CameraColorShare.export(style:style,lut:nil,intensity:1)
        defer {try? FileManager.default.removeItem(at:url.deletingLastPathComponent())}
        let text=try String(contentsOf:url,encoding:.utf8)
        guard let parsed=CubeLUT.parse(text:text,name:"Camera shared") else {throw CocoaError(.fileReadCorruptFile)}
        let rgb:[Float]=[10.0/32,16.0/32,22.0/32]
        let input=CIImage(color:CIColor(red:Double(rgb[0]),green:Double(rgb[1]),blue:Double(rgb[2]))).cropped(to:CGRect(x:0,y:0,width:1,height:1))
        let expected=pixel(StyleGrade.grade(input,cube:nil,cubeSize:0,intensity:1,style:style))
        let actual=parsed.sample(r:rgb[0],g:rgb[1],b:rgb[2]),channels=[actual.0,actual.1,actual.2]
        try check(zip(channels,expected).allSatisfy {abs($0-$1)<0.004},"Camera colour bake mismatch")
        try text.write(to:docs.appendingPathComponent("camera-shared-qa.cube"),atomically:true,encoding:.utf8)
        let vectors:[String:Any]=["rgb":rgb,"expected":Array(expected.prefix(3))]
        try JSONSerialization.data(withJSONObject:vectors,options:.prettyPrinted).write(to:docs.appendingPathComponent("camera-shared-vectors.json"),options:.atomic)
        let packageURL=try CameraColorShare.exportNative(style:style,lut:nil,intensity:1)
        defer {try? FileManager.default.removeItem(at:packageURL.deletingLastPathComponent())}
        let native=try StillarcLookPackage.read(packageURL),portable=CubeLUT.parse(text:try CameraColorShare.cubeText(native),name:"Native")!
        let portableSample=portable.sample(r:rgb[0],g:rgb[1],b:rgb[2])
        try check(zip([portableSample.0,portableSample.1,portableSample.2],channels).allSatisfy {abs($0-$1)<0.00001},"Native package changed Camera colour")
        try Data(contentsOf:packageURL).write(to:docs.appendingPathComponent("camera-native-qa.stillarclook"),options:.atomic)
        let studioNative=docs.appendingPathComponent("studio-native-qa.stillarclook")
        if FileManager.default.fileExists(atPath:studioNative.path) {let incoming=try StillarcLookPackage.read(studioNative);try check(incoming.payload("studio") != nil,"Studio package lost native payload");_ = try CameraColorShare.cubeText(incoming)}
        var incoming=false
        let studio=docs.appendingPathComponent("studio-shared-qa.cube")
        if FileManager.default.fileExists(atPath:studio.path) {
            guard let lut=CubeLUT.parse(text:try String(contentsOf:studio,encoding:.utf8),name:"Studio shared") else {throw CocoaError(.fileReadCorruptFile)}
            let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:docs.appendingPathComponent("studio-shared-vectors.json"))) as! [String:[Double]]
            let sample=reference["rgb"]!,expected=reference["expected"]!,got=lut.sample(r:Float(sample[0]),g:Float(sample[1]),b:Float(sample[2]))
            try check(zip([got.0,got.1,got.2],expected).allSatisfy {abs(Double($0)-$1)<0.015},"Studio-to-Camera colour mismatch")
            incoming=true
        }
        return try JSONSerialization.data(withJSONObject:["passed":true,"nativePackage":true,"cameraExport":true,"studioImport":incoming,"version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"],options:.prettyPrinted)
    }
    @MainActor static func write() async {
        let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0],report=docs.appendingPathComponent("camera-colour-verification.json")
        do {let data=try await Task.detached(priority:.utility){try run(docs)}.value;try data.write(to:report,options:.atomic)}
        catch {try? JSONSerialization.data(withJSONObject:["passed":false,"error":error.localizedDescription],options:.prettyPrinted).write(to:report,options:.atomic)}
    }
}
#endif
