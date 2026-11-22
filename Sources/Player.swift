import SwiftUI
import AVKit

/// Tam ekran oynatıcı. Canlı yayında ön bellek hedefi 30 sn; oynatılamazsa yedek adres (HLS) denenir.
struct PlayerScreen: View {
    let target: PlayTarget
    @Environment(\.presentationMode) private var presentation
    @StateObject private var model = PlayerModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoView(player: model.player).ignoresSafeArea()
            if model.waiting {
                VStack(spacing: 10) {
                    ProgressView().scaleEffect(1.4)
                    Text(model.status).font(.footnote).foregroundColor(.white)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { model.stop(); presentation.wrappedValue.dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3.bold())
                    .padding(12).background(.ultraThinMaterial).clipShape(Circle())
            }.padding(.leading, 12).padding(.top, 8)
        }
        .statusBar(hidden: true)
        .onAppear { model.start(target) }
        .onDisappear { model.stop() }
    }
}

final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var waiting = true
    @Published var status = "Bağlanıyor…"
    private var obs: [NSKeyValueObservation] = []
    private var target: PlayTarget?
    private var triedAlt = false

    func start(_ t: PlayTarget) {
        target = t; triedAlt = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        open(t.url, live: t.live)
    }

    private func open(_ url: URL, live: Bool) {
        obs.removeAll()
        let opts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": "VLC/3.0.20 LibVLC/3.0.20"]]
        let asset = AVURLAsset(url: url, options: opts)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = live ? 30 : 15
        player.automaticallyWaitsToMinimizeStalling = true
        player.replaceCurrentItem(with: item)
        waiting = true; status = "Bağlanıyor…"
        obs.append(item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if it.status == .failed { self.failed(it.error) }
            }
        })
        obs.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch p.timeControlStatus {
                case .playing: self.waiting = false
                case .waitingToPlayAtSpecifiedRate: self.waiting = true; self.status = "Ön belleğe alınıyor…"
                default: break
                }
            }
        })
        player.play()
    }

    private func failed(_ err: Error?) {
        if !triedAlt, let t = target, let alt = t.alt {
            triedAlt = true
            status = "Yedek akış deneniyor…"
            open(alt, live: t.live)
        } else {
            waiting = true
            status = "Oynatılamadı: " + (err?.localizedDescription ?? "bilinmeyen hata")
        }
    }

    func stop() {
        obs.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct VideoView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = player
        c.allowsPictureInPicturePlayback = true
        c.entersFullScreenWhenPlaybackBegins = false
        return c
    }
    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {}
}
