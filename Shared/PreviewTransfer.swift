import Compression
import Foundation

enum PreviewTransfer {
    private static let sourceLimit = 384_000
    private static let addressLimit = 48_000

    static func address(for source: String) -> URL? {
        let input = Array(source.utf8)
        guard !input.isEmpty, input.count <= sourceLimit else { return nil }
        var output = [UInt8](repeating: 0, count: addressLimit * 3 / 4)
        let size = compression_encode_buffer(&output, output.count, input, input.count, nil, COMPRESSION_ZLIB)
        guard size > 0 else { return nil }
        let encoded = Data(output.prefix(size)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return URL(string: "aster-markdown://xcode/" + encoded)
    }

    static func source(from url: URL) -> String? {
        guard url.host == "xcode", url.lastPathComponent.count <= addressLimit else { return nil }
        let encoded = url.lastPathComponent.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else { return nil }
        let input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: sourceLimit + 1)
        let size = compression_decode_buffer(&output, output.count, input, input.count, nil, COMPRESSION_ZLIB)
        guard size > 0, size <= sourceLimit else { return nil }
        return String(bytes: output.prefix(size), encoding: .utf8)
    }
}
