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
        updateStatus("正在啟動 GPS Helper…")

        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()

        startHTTPServer()
    }

    // MARK: - Location

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            updateStatus("定位服務已授權，正在取得 GPS…")
            manager.startUpdatingLocation()

        case .denied:
            updateStatus("定位權限被拒絕")

        case .restricted:
            updateStatus("定位服務受到限制")

        case .notDetermined:
            updateStatus("等待定位權限…")

        @unknown default:
            updateStatus("定位權限狀態未知")
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let loc = locations.last else {
            return
        }

        DispatchQueue.main.async {
            self.latitude = loc.coordinate.latitude
            self.longitude = loc.coordinate.longitude

            self.status = String(
                format: "已取得 iPhone 真實 GPS\n%.7f, %.7f",
                loc.coordinate.latitude,
                loc.coordinate.longitude
            )
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        updateStatus("定位失敗：\(error.localizedDescription)")
    }

    // MARK: - HTTP Server

    private func startHTTPServer() {
        updateStatus("正在啟動 HTTP Server :18181…")

        do {
            let parameters = NWParameters.tcp

            let newListener = try NWListener(
                using: parameters,
                on: 18181
            )

            listener = newListener

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }

                switch state {
                case .setup:
                    self.updateStatus("HTTP Server 設定中…")

                case .waiting(let error):
                    self.updateStatus(
                        "HTTP Server 等待中：\(error.localizedDescription)"
                    )

                case .ready:
                    self.updateStatus(
                        "HTTP Server 已啟動\nLISTENING :18181\n等待 Windows 連線…"
                    )

                case .failed(let error):
                    self.updateStatus(
                        "HTTP Server 啟動失敗：\(error.localizedDescription)"
                    )

                case .cancelled:
                    self.updateStatus("HTTP Server 已停止")

                @unknown default:
                    self.updateStatus("HTTP Server 狀態未知")
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }

                self.updateStatus("收到 Windows TCP 連線")

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }

                    switch state {
                    case .ready:
                        self.updateStatus("TCP 連線已建立\n等待 HTTP Request…")

                    case .failed(let error):
                        self.updateStatus(
                            "TCP 連線失敗：\(error.localizedDescription)"
                        )

                    case .cancelled:
                        self.updateStatus("TCP 連線已關閉")

                    default:
                        break
                    }
                }

                connection.start(
                    queue: .global(qos: .userInitiated)
                )

                self.receiveRequest(
                    connection,
                    buffer: Data()
                )
            }

            newListener.start(
                queue: .global(qos: .userInitiated)
            )

        } catch {
            updateStatus(
                "無法啟動 GPS HTTP Server：\(error.localizedDescription)"
            )
        }
    }

    // MARK: - Receive HTTP Request

    private func receiveRequest(
        _ connection: NWConnection,
        buffer: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8192
        ) { [weak self] data, _, isComplete, error in

            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.updateStatus(
                    "HTTP Receive 失敗：\(error.localizedDescription)"
                )

                connection.cancel()
                return
            }

            var newBuffer = buffer

            if let data, !data.isEmpty {
                newBuffer.append(data)

                self.updateStatus(
                    "已收到 HTTP 資料：\(newBuffer.count) bytes"
                )
            }

            // HTTP Header 結束位置
            let headerEndCRLF = Data([13, 10, 13, 10])
            let headerEndLF = Data([10, 10])

            let hasHeaderEnd =
                newBuffer.range(of: headerEndCRLF) != nil ||
                newBuffer.range(of: headerEndLF) != nil

            if hasHeaderEnd {
                self.handleHTTPRequest(
                    connection,
                    data: newBuffer
                )

                return
            }

            if isComplete {
                self.updateStatus(
                    "HTTP 連線結束，但沒有收到完整 Request"
                )

                connection.cancel()
                return
            }

            // 還沒收到完整 HTTP Header，繼續收
            self.receiveRequest(
                connection,
                buffer: newBuffer
            )
        }
    }

    // MARK: - Handle HTTP

    private func handleHTTPRequest(
        _ connection: NWConnection,
        data: Data
    ) {
        guard let request = String(
            data: data,
            encoding: .utf8
        ) else {
            updateStatus("HTTP Request 不是有效 UTF-8")

            sendHTTPResponse(
                connection,
                statusCode: 400,
                body: #"{"ok":false,"error":"invalid_request_encoding"}"#
            )

            return
        }

        let firstLine =
            request.components(separatedBy: "\r\n").first ??
            request.components(separatedBy: "\n").first ??
            ""

        updateStatus(
            "HTTP Request 已收到\n\(firstLine)"
        )

        let path = parsePath(from: firstLine)

        if path == "/health" {
            sendHTTPResponse(
                connection,
                statusCode: 200,
                body: #"{"ok":true,"service":"iPhoneGPSLocationHelper"}"#
            )

            return
        }

        if path == "/location" || path == "/" {
            let lat = latitude
            let lon = longitude

            if let lat, let lon {
                let body = String(
                    format:
                        #"{"ok":true,"latitude":%.7f,"longitude":%.7f}"#,
                    lat,
                    lon
                )

                updateStatus(
                    String(
                        format:
                            "收到 GPS Request\n準備回傳：%.7f, %.7f",
                        lat,
                        lon
                    )
                )

                sendHTTPResponse(
                    connection,
                    statusCode: 200,
                    body: body
                )

            } else {
                updateStatus(
                    "收到 GPS Request，但目前尚未取得定位"
                )

                sendHTTPResponse(
                    connection,
                    statusCode: 503,
                    body:
                        #"{"ok":false,"error":"location_not_ready"}"#
                )
            }

            return
        }

        sendHTTPResponse(
            connection,
            statusCode: 404,
            body:
                #"{"ok":false,"error":"not_found"}"#
        )
    }

    // MARK: - HTTP Response

    private func sendHTTPResponse(
        _ connection: NWConnection,
        statusCode: Int,
        body: String
    ) {
        let reason: String

        switch statusCode {
        case 200:
            reason = "OK"

        case 400:
            reason = "Bad Request"

        case 404:
            reason = "Not Found"

        case 503:
            reason = "Service Unavailable"

        default:
            reason = "Error"
        }

        let response =
            "HTTP/1.1 \(statusCode) \(reason)\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n" +
            body

        guard let responseData = response.data(using: .utf8) else {
            updateStatus("HTTP Response 編碼失敗")
            connection.cancel()
            return
        }

        updateStatus(
            "正在送出 HTTP Response\n\(statusCode)\n\(body)"
        )

        connection.send(
            content: responseData,
            completion: .contentProcessed { [weak self] error in

                if let error {
                    self?.updateStatus(
                        "HTTP Response 傳送失敗：\(error.localizedDescription)"
                    )

                } else {
                    self?.updateStatus(
                        "HTTP Response 已成功送出\n\(body)"
                    )
                }

                connection.cancel()
            }
        )
    }

    // MARK: - Request Path

    private func parsePath(from firstLine: String) -> String {
        let parts = firstLine.split(separator: " ")

        guard parts.count >= 2 else {
            return "/"
        }

        return String(parts[1])
    }

    // MARK: - UI Status

    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.status = text
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

                if let lat = service.latitude,
                   let lon = service.longitude {

                    Text(
                        String(
                            format: "緯度：%.7f",
                            lat
                        )
                    )

                    Text(
                        String(
                            format: "經度：%.7f",
                            lon
                        )
                    )
                    .font(.headline)

                } else {
                    Text("尚未取得 GPS")
                        .foregroundStyle(.secondary)
                }

                Text(
                    "Windows 透過 USB Tunnel 連到此 Helper 的 18181 服務"
                )
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
