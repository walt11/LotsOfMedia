import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isConnected = true
    private(set) var isExpensive = false
    private(set) var usesWiFi = true
    /// Incremented whenever the active interface changes (e.g. Wi-Fi → cellular),
    /// which usually means server addresses need to be re-resolved.
    private(set) var pathGeneration = 0

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var listeners: [(Bool) -> Void] = []
    @ObservationIgnored private var lastSignature = ""

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.update(path) }
        }
        monitor.start(queue: DispatchQueue(label: "net.jwalter.LotsOfMedia.network"))
    }

    private func update(_ path: NWPath) {
        let connected = path.status == .satisfied
        let signature = "\(connected)-\(path.usesInterfaceType(.wifi))-\(path.usesInterfaceType(.cellular))-\(path.usesInterfaceType(.wiredEthernet))"
        let changed = signature != lastSignature
        lastSignature = signature
        isConnected = connected
        isExpensive = path.isExpensive
        usesWiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
        if changed {
            pathGeneration += 1
            listeners.forEach { $0(connected) }
        }
    }

    /// Called on every interface change with the new connectivity state.
    func onChange(_ handler: @escaping (Bool) -> Void) { listeners.append(handler) }
}
