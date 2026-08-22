import SwiftUI
import CoreLocation
import Network

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var latitude: Double?
    @Published var longitude: Double?
    @Published var status = "等待定位…"

    private let manager = CLLocationManager()
    private var listener: NWListener?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        startHTTPServer()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
            status = "定位服務已授權"
        } else {
            status = "尚未取得定位權限"
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.latitude = loc.coordinate.latitude
            self.longitude = loc.coordinate.longitude
            self.status = "已取得 iPhone 真實 GPS"
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.status = "定位失敗：\(error.localizedDescription)"
        }
    }

    private func startHTTPServer() {
        do {
            let parameters = NWParameters.tcp
            let newListener = try NWListener(using: parameters, on: 18181)
            listener = newListener

            newListener.stateUpdateHandler = { state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self.status = "GPS Helper 已啟動，等待 Windows 讀取"
                    case .failed(let error):
                        self.status = "服務失敗：\(error.localizedDescription)"
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                self.handle(connection)
            }

            newListener.start(queue: .global(qos: .userInitiated))
        } catch {
            status = "無法啟動 GPS 服務：\(error.localizedDescription)"
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            guard data != nil else {
                connection.cancel()
                return
            }

            let lat = self.latitude
            let lon = self.longitude

            let body: String
            if let lat, let lon {
                body = #"{"ok":true,"latitude":\#(lat),"longitude":\#(lon)}"#
            } else {
                body = #"{"ok":false,"error":"location_not_ready"}"#
            }

            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """

            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

@main
struct iPhoneGPSLocationHelperApp: App {
    @StateObject private var service = LocationService()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 18) {
                Text("iPhone GPS Location Helper")
                    .font(.title2)
                    .bold()

                Text(service.status)
                    .multilineTextAlignment(.center)

                if let lat = service.latitude, let lon = service.longitude {
                    Text(String(format: "緯度：%.7f", lat))
                    Text(String(format: "經度：%.7f", lon))
                        .font(.headline)
                } else {
                    Text("尚未取得 GPS")
                        .foregroundStyle(.secondary)
                }

                Text("Windows 透過 USB Tunnel 連到此 Helper 的 18181 服務")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .onAppear {
                service.start()
            }
        }
    }
}
