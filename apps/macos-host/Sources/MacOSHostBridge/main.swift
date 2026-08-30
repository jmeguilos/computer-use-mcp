import Foundation
import MacOSHostCore

do {
    let configuration = try SocketConfiguration.resolved()
    let proxy = BridgeProxy(configuration: configuration)
    do { try proxy.run() }
    catch {
        proxy.writeDiagnostic("proxy terminated with \(String(describing: type(of: error)))")
        exit(EXIT_FAILURE)
    }
} catch {
    FileHandle.standardError.write(Data("ComputerUseMCPBridge: configuration failed\n".utf8))
    exit(EXIT_FAILURE)
}
