import Foundation
import PDFKit
import CryptoKit

let path = CommandLine.arguments.dropFirst().first ?? ""
guard FileManager.default.fileExists(atPath: path) else {
    fputs("fixture missing\n", stderr); exit(1)
}
guard let pdf = PDFDocument(url: URL(fileURLWithPath: path)), pdf.pageCount == 120 else {
    fputs("expected 120 readable pages\n", stderr); exit(1)
}
var hashes = Set<String>()
struct ImageCheck { var gray: Bool; var count = 0 }
for index in 0..<120 {
    let page = pdf.page(at: index)!
    precondition(page.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
    if [0, 59, 119].contains(index) {
    let image = page.thumbnail(of: CGSize(width: 255, height: 330), for: .mediaBox)
    let data = image.tiffRepresentation!
    hashes.insert(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    let ref = page.pageRef!
    var resources: CGPDFDictionaryRef?
    precondition(CGPDFDictionaryGetDictionary(ref.dictionary!, "Resources", &resources))
    var images: CGPDFDictionaryRef?
    precondition(CGPDFDictionaryGetDictionary(resources!, "XObject", &images))
    var check = ImageCheck(gray: index % 2 == 0)
    CGPDFDictionaryApplyFunction(images!, { _, object, context in
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let dict = CGPDFStreamGetDictionary(stream!) else { return }
        var width: CGPDFInteger = 0; var height: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(dict, "Width", &width), CGPDFDictionaryGetInteger(dict, "Height", &height), width == 2550, height == 3300 {
            let check = context!.assumingMemoryBound(to: ImageCheck.self)
            var color: UnsafePointer<CChar>?
            var components: CGPDFInteger = 0
            if CGPDFDictionaryGetName(dict, "ColorSpace", &color) {
                components = String(cString: color!) == "DeviceGray" ? 1 : 3
            } else {
                var array: CGPDFArrayRef?, profile: CGPDFStreamRef?
                precondition(CGPDFDictionaryGetArray(dict, "ColorSpace", &array))
                precondition(CGPDFArrayGetName(array!, 0, &color) && String(cString: color!) == "ICCBased")
                precondition(CGPDFArrayGetStream(array!, 1, &profile))
                precondition(CGPDFDictionaryGetInteger(CGPDFStreamGetDictionary(profile!)!, "N", &components))
            }
            precondition(components == (check.pointee.gray ? 1 : 3), "alternating image color space")
            check.pointee.count += 1
        }
    }, &check)
    precondition(check.count == 1, "expected one 2550×3300 scan image on every page")
}
precondition(hashes.count == 3, "page images must differ")
print("PASS: all 120 raster pages, 300 dpi Letter, alternating grayscale/RGB, distinct first/middle/last content")
