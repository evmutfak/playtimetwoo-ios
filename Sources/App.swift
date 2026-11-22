import SwiftUI
import AVKit

@main
struct PlayTimeTwooApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Color.orange)
        }
    }
}

/// Kayıtlı hesap ve favoriler
final class Store: ObservableObject {
    @Published var account: Account? {
        didSet { save() }
    }
    @Published var favorites: [String] = UserDefaults.standard.stringArray(forKey: "favs") ?? []

    init() {
        if let d = UserDefaults.standard.data(forKey: "account"), let a = try? JSONDecoder().decode(Account.self, from: d) {
            account = a
        }
    }

    private func save() {
        if let a = account, let d = try? JSONEncoder().encode(a) { UserDefaults.standard.set(d, forKey: "account") }
        else { UserDefaults.standard.removeObject(forKey: "account") }
    }

    var api: Api? { account.map { Api($0) } }

    func toggleFav(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
        UserDefaults.standard.set(favorites, forKey: "favs")
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if store.account == nil { LoginView() } else { MainTabs() }
    }
}

struct MainTabs: View {
    @EnvironmentObject var store: Store
    var body: some View {
        TabView {
            BrowseView(kind: .live).tabItem { Label("Canlı TV", systemImage: "tv") }
            BrowseView(kind: .movie).tabItem { Label("Filmler", systemImage: "film") }
            BrowseView(kind: .series).tabItem { Label("Diziler", systemImage: "rectangle.stack") }
            SettingsView().tabItem { Label("Ayarlar", systemImage: "gearshape") }
        }
    }
}

// MARK: Giriş
struct LoginView: View {
    @EnvironmentObject var store: Store
    @State private var mode = 0
    @State private var server = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var m3u = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Tür", selection: $mode) {
                        Text("Xtream hesabı").tag(0)
                        Text("M3U adresi").tag(1)
                    }.pickerStyle(.segmented)
                }
                if mode == 0 {
                    Section(header: Text("Hesap bilgileri")) {
                        TextField("Sunucu (http://adres:port)", text: $server)
                            .textInputAutocapitalization(.never).disableAutocorrection(true).keyboardType(.URL)
                        TextField("Kullanıcı adı", text: $user)
                            .textInputAutocapitalization(.never).disableAutocorrection(true)
                        SecureField("Şifre", text: $pass)
                    }
                } else {
                    Section(header: Text("M3U")) {
                        TextField("M3U adresi", text: $m3u)
                            .textInputAutocapitalization(.never).disableAutocorrection(true).keyboardType(.URL)
                    }
                }
                if !error.isEmpty { Section { Text(error).foregroundColor(.red) } }
                Section {
                    Button(action: login) {
                        HStack { if busy { ProgressView() }; Text(busy ? "Bağlanıyor…" : "Giriş yap").bold() }
                    }.disabled(busy)
                }
            }
            .navigationTitle("Play Time Twoo")
        }
        .navigationViewStyle(.stack)
    }

    private func login() {
        error = ""
        let acc = mode == 0 ? Account(kind: "xtream", server: server, user: user, pass: pass)
                            : Account(kind: "m3u", m3u: m3u)
        busy = true
        Task {
            do {
                _ = try await Api(acc).login()
                await MainActor.run { store.account = acc; busy = false }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; busy = false }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Hesap")) {
                    Text(store.account?.kind == "m3u" ? (store.account?.m3u ?? "") : (store.account?.server ?? ""))
                        .font(.footnote).foregroundColor(.secondary)
                    Button("Çıkış yap", role: .destructive) { store.account = nil }
                }
                Section(header: Text("Hakkında")) {
                    Text("Play Time Twoo iPhone 1.0.0")
                }
            }.navigationTitle("Ayarlar")
        }.navigationViewStyle(.stack)
    }
}
