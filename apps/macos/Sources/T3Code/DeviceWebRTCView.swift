import AppKit
import WebKit

@MainActor
private final class DeviceWebRTCBridge: NSObject, WKScriptMessageHandler {
    weak var owner: DeviceWebRTCView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.frameInfo.isMainFrame { owner?.receive(message.body) }
    }
}

@MainActor
final class DeviceWebRTCView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private var access: DeviceMediaAccess?
    private var sessionID: String?
    private var settings = "{}"
    private var navigation: WKNavigation?
    private var negotiation: Task<Void, Never>?
    var onFrame: ((CGSize) -> Void)?
    var onFailure: ((String) -> Void)?
    var onExpiredClose: ((DeviceTarget, String) async -> Void)?

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let bridge = DeviceWebRTCBridge()
        configuration.userContentController.add(bridge, name: "deviceTransport")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        bridge.owner = self
        webView.navigationDelegate = self
        webView.setAccessibilityElement(false)
        fill(webView, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start(access: DeviceMediaAccess, settings: Wire) {
        stop()
        self.access = access
        sessionID = UUID().uuidString.lowercased()
        var config: Payload = [:]
        if settings["iceServers"] != .null { config["iceServers"] = settings["iceServers"] }
        if settings["iceTransportPolicy"] != .null { config["iceTransportPolicy"] = settings["iceTransportPolicy"] }
        self.settings = (try? JSONEncoder().encode(config)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        navigation = webView.loadHTMLString(Self.document, baseURL: URL(string: "https://localhost/"))
    }

    func stop() {
        let offered = negotiation != nil
        negotiation?.cancel()
        negotiation = nil
        let current = sessionID
        sessionID = nil
        navigation = nil
        let access = access
        self.access = nil
        webView.evaluateJavaScript("stopDevicePeer()")
        webView.stopLoading()
        if offered, let current, let access {
            Task { [onExpiredClose] in
                do {
                    _ = try await access.json(.close, body: ["sessionId": .string(current)])
                } catch DeviceMediaFailure.http(let status) where status == 401 || status == 403 {
                    await onExpiredClose?(access.target, current)
                } catch {}
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === self.navigation, let sessionID else { return }
        Task { [weak self] in
            guard let self, self.sessionID == sessionID else { return }
            do {
                _ = try await webView.callAsyncJavaScript("await startDevicePeer(JSON.parse(config), id)",
                    arguments: ["config": settings, "id": sessionID], in: nil, contentWorld: .page)
            } catch {
                if self.sessionID == sessionID { onFailure?("The device’s WebRTC stream could not start.") }
            }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if sessionID != nil { onFailure?("The device’s WebRTC playback stopped.") }
    }

    fileprivate func receive(_ raw: Any) {
        guard let message = raw as? [String: Any], let id = message["id"] as? String, id == sessionID else { return }
        switch message["kind"] as? String {
        case "offer":
            guard negotiation == nil, let access, let sdp = message["sdp"] as? String, sdp.utf8.count <= 1_048_576 else { return }
            negotiation = Task { [weak self] in
                do {
                    let answer = try await access.json(.offer, body: [
                        "type": .string("offer"), "sdp": .string(sdp), "sessionId": .string(id), "codec": .string("h264"),
                    ])
                    guard let self, self.sessionID == id, !Task.isCancelled else { return }
                    guard answer["type"].string == "answer", let sdp = answer["sdp"].string,
                          sdp.utf8.count <= 1_048_576 else { throw ClientError.invalidResponse }
                    _ = try await webView.callAsyncJavaScript("await answerDevicePeer(id, sdp)",
                        arguments: ["id": id, "sdp": sdp], in: nil, contentWorld: .page)
                } catch {
                    if let self, self.sessionID == id, !Task.isCancelled {
                        onFailure?("The device host could not negotiate WebRTC playback.")
                    }
                }
            }
        case "frame":
            guard let width = message["width"] as? Int, let height = message["height"] as? Int,
                  (1...7_680).contains(width), (1...7_680).contains(height) else { return }
            onFrame?(CGSize(width: width, height: height))
        case "error": onFailure?("The device’s WebRTC stream disconnected.")
        default: break
        }
    }

    private static let document = #"""
    <!doctype html>
    <meta charset="utf-8">
    <style>
      html, body { background: black; margin: 0; width: 100%; height: 100%; overflow: hidden; }
      video { width: 100%; height: 100%; object-fit: contain; }
    </style>
    <video autoplay muted playsinline></video>
    <script>
    const video = document.querySelector("video");
    let connection, session;
    const notify = (kind, details = {}) => window.webkit.messageHandlers.deviceTransport.postMessage({ kind, id: session, ...details });
    function stopDevicePeer() {
      session = null;
      if (connection) connection.close();
      connection = null;
      video.srcObject = null;
    }
    function notifyFrame() {
      if (session && video.videoWidth > 0 && video.videoHeight > 0) {
        notify("frame", { width: video.videoWidth, height: video.videoHeight });
      }
    }
    video.onloadeddata = notifyFrame;
    video.onresize = notifyFrame;
    async function startDevicePeer(config, id) {
      stopDevicePeer();
      session = id;
      const peer = connection = new RTCPeerConnection(config);
      peer.addTransceiver("video", { direction: "recvonly" });
      peer.ontrack = ({ track }) => {
        if (connection !== peer) return;
        video.srcObject = new MediaStream([track]);
        video.play().catch(() => notify("error"));
      };
      peer.onconnectionstatechange = () => {
        if (connection === peer && peer.connectionState === "failed") notify("error");
      };
      await peer.setLocalDescription(await peer.createOffer());
      if (peer.iceGatheringState !== "complete") {
        await new Promise(resolve => {
          const finish = () => {
            clearTimeout(timer);
            peer.removeEventListener("icegatheringstatechange", changed);
            resolve();
          };
          const changed = () => { if (peer.iceGatheringState === "complete") finish(); };
          const timer = setTimeout(finish, 4000);
          peer.addEventListener("icegatheringstatechange", changed);
        });
      }
      if (connection === peer) notify("offer", { sdp: peer.localDescription.sdp });
    }
    async function answerDevicePeer(id, sdp) {
      if (session === id && connection) await connection.setRemoteDescription({ type: "answer", sdp });
    }
    </script>
    """#
}
