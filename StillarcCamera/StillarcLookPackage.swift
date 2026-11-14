import Foundation
import CryptoKit

/// Shared by Camera and Studio. Native creative instructions stay opaque to
/// the companion and are used only while bound to the same portable colour.
final class StillarcLookPackage:Codable,Equatable,@unchecked Sendable {
    struct Native:Codable,Equatable,Sendable {
        let version:Int
        let colourSHA256:String
        let data:Data
    }
    let format:String
    let schema:Int
    let name:String
    let encoding:String
    let dimension:Int
    let cube:Data
    let colourSHA256:String
    let native:[String:Native]
    let excluded:[String]
    private let fingerprint:String
    static let maximumBytes=67_108_864
    private enum CodingKeys:String,CodingKey {case format,schema,name,encoding,dimension,cube,colourSHA256,native,excluded}
    static func hash(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
    static func failure(_ message:String)->NSError {NSError(domain:"StillarcLook",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
    init(name:String,dimension:Int,cube:Data,native:[String:Native]=[:],excluded:[String]=[]) throws {
        let clean=String(name.unicodeScalars.filter {!CharacterSet.controlCharacters.contains($0)}.map(String.init).joined().trimmingCharacters(in:.whitespacesAndNewlines).prefix(100))
        guard !clean.isEmpty,[17,33,65].contains(dimension),cube.count==dimension*dimension*dimension*16,native.count<=2,native.keys.allSatisfy({$0=="studio" || $0=="camera"}),native.values.allSatisfy({$0.version==1 && $0.data.count<=33_554_432 && $0.colourSHA256.count==64}),native.values.reduce(0,{$0+$1.data.count})<=50_331_648,excluded.count<=32,excluded.allSatisfy({$0.utf8.count<=200}) else {throw Self.failure("This shared look is invalid or exceeds its size budget.")}
        let valid=cube.withUnsafeBytes { (bytes:UnsafeRawBufferPointer) -> Bool in
            for i in stride(from:0,to:bytes.count,by:4) {let value=bytes.loadUnaligned(fromByteOffset:i,as:Float.self);if !value.isFinite || value<0 || value>1 || (i%16==12 && value != 1) {return false}}
            return true
        }
        guard valid else {throw Self.failure("Shared colour must contain finite display-sRGB values and opaque LUT entries.")}
        self.format="StillarcLook";self.schema=1;self.name=clean;self.encoding="display-sRGB-rgba32f-le";self.dimension=dimension;self.cube=cube;self.colourSHA256=Self.hash(cube);self.native=native;self.excluded=excluded
        let keys=native.keys.sorted().map {$0+":"+native[$0]!.colourSHA256+":"+Self.hash(native[$0]!.data)}.joined(separator:"|")
        fingerprint=Self.hash(Data((clean+colourSHA256+keys+excluded.joined(separator:"|")).utf8))
    }
    required convenience init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        guard try c.decode(String.self,forKey:.format)=="StillarcLook",try c.decode(Int.self,forKey:.schema)==1,try c.decode(String.self,forKey:.encoding)=="display-sRGB-rgba32f-le" else {throw Self.failure("Update Stillarc to open this shared-look format.")}
        try self.init(name:c.decode(String.self,forKey:.name),dimension:c.decode(Int.self,forKey:.dimension),cube:c.decode(Data.self,forKey:.cube),native:c.decode([String:Native].self,forKey:.native),excluded:c.decode([String].self,forKey:.excluded))
        guard try c.decode(String.self,forKey:.colourSHA256)==colourSHA256 else {throw Self.failure("The shared colour data failed its integrity check.")}
    }
    static func ==(a:StillarcLookPackage,b:StillarcLookPackage)->Bool {a === b || a.fingerprint==b.fingerprint}
    func payload(_ app:String)->Data? {guard let value=native[app],value.version==1,value.colourSHA256==colourSHA256 else {return nil};return value.data}
    static func read(_ url:URL) throws ->StillarcLookPackage {
        let secured=url.startAccessingSecurityScopedResource();defer {if secured {url.stopAccessingSecurityScopedResource()}}
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)<=maximumBytes else {throw failure("Choose a shared look under 64 MB.")}
        return try JSONDecoder().decode(Self.self,from:Data(contentsOf:url,options:.mappedIfSafe))
    }
    func write() throws ->URL {
        try Task.checkCancellation();let data=try JSONEncoder().encode(self)
        guard data.count<=Self.maximumBytes else {throw Self.failure("This native shared look is too large to package.")}
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("StillarcLook-\(UUID())");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let url=folder.appendingPathComponent("Stillarc Look.stillarclook")
        do {try data.write(to:url,options:.atomic);return url} catch {try? FileManager.default.removeItem(at:folder);throw error}
    }
}
