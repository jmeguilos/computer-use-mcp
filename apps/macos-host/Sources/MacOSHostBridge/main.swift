import Foundation
import MacOSHostCore

do {
    let configuration = try SocketConfiguration.resolved()
    let proxy = BridgeProxy(configuration: configuration)
    do { try proxy.run() }
    catch {
        if let security = error as? LocalSecurityError {
            proxy.writeDiagnostic("proxy terminated: \(security.rawValue)")
        } else if let bridge = error as? BridgeProxyError {
            proxy.writeDiagnostic("proxy terminated: \(bridge.rawValue)")
        } else {
            proxy.writeDiagnostic("proxy terminated with \(String(describing: type(of: error)))")
        }
        exit(EXIT_FAILURE)
    }
} catch {
    FileHandle.standardError.write(Data("ComputerUseMCPBridge: configuration failed\n".utf8))
    exit(EXIT_FAILURE)
}
