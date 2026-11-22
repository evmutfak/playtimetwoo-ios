import SwiftUI

struct PlayTarget: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let alt: URL?
    let live: Bool
}

struct BrowseView: View {
    let kind: Kind
    @EnvironmentObject var store: Store
    @State private var cats: [Category] = []
    @State private var cat: Category?
    @State private var items: [Item] = []
    @State private var query = ""
    @State private var loading = false
    @State private var error = ""
    @State private var play: PlayTarget?

    private var shown: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? items : items.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !cats.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(cats) { c in
                                Button(c.name) { select(c) }
                                    .font(.subheadline)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(cat == c ? Color.orange : Color.gray.opacity(0.25))
                                    .foregroundColor(cat == c ? .black : .primary)
                                    .clipShape(Capsule())
                            }
                        }.padding(.horizontal).padding(.vertical, 8)
                    }
                }
                if loading { ProgressView().padding() }
                if !error.isEmpty { Text(error).foregroundColor(.red).padding() }
                List(shown) { item in
                    row(item)
                }
                .listStyle(.plain)
            }
            .navigationTitle(kind == .live ? "Canlı TV" : kind == .movie ? "Filmler" : "Diziler")
            .searchable(text: $query, prompt: "Bu kategoride ara")
        }
        .navigationViewStyle(.stack)
        .task { await loadCats() }
        .fullScreenCover(item: $play) { t in PlayerScreen(target: t) }
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        if kind == .series {
            NavigationLink(destination: SeriesView(item: item)) { cell(item) }
        } else {
            Button { start(item) } label: { cell(item) }.buttonStyle(.plain)
        }
    }

    private func cell(_ item: Item) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.icon.flatMap(URL.init(string:))) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Color.gray.opacity(0.2)
            }
            .frame(width: kind == .live ? 54 : 48, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(item.name).lineLimit(2)
            Spacer()
            Button { store.toggleFav(item.id) } label: {
                Image(systemName: store.favorites.contains(item.id) ? "star.fill" : "star")
                    .foregroundColor(.orange)
            }.buttonStyle(.borderless)
        }
    }

    private func start(_ item: Item) {
        guard let u = item.url else { return }
        play = PlayTarget(title: item.name, url: u, alt: item.altURL, live: item.kind == .live)
    }

    private func loadCats() async {
        guard cats.isEmpty, let api = store.api else { return }
        loading = true; error = ""
        do {
            let c = try await api.categories(kind)
            cats = c
            loading = false
            if let first = c.first { select(first) }
        } catch {
            self.error = error.localizedDescription; loading = false
        }
    }

    private func select(_ c: Category) {
        cat = c; items = []; error = ""
        guard let api = store.api else { return }
        loading = true
        Task {
            do {
                let r = try await api.items(kind, cat: c.id)
                await MainActor.run { if cat == c { items = r; loading = false } }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; loading = false }
            }
        }
    }
}

struct SeriesView: View {
    let item: Item
    @EnvironmentObject var store: Store
    @State private var eps: [Episode] = []
    @State private var loading = true
    @State private var error = ""
    @State private var play: PlayTarget?

    var body: some View {
        List {
            if let i = item.info { Text(i).font(.footnote).foregroundColor(.secondary) }
            if loading { ProgressView() }
            if !error.isEmpty { Text(error).foregroundColor(.red) }
            ForEach(eps) { e in
                Button {
                    if let u = e.url { play = PlayTarget(title: item.name + " · " + e.title, url: u, alt: e.altURL, live: false) }
                } label: {
                    HStack {
                        Text("S\(e.season) B\(e.number)").font(.caption).foregroundColor(.orange).frame(width: 64, alignment: .leading)
                        Text(e.title).lineLimit(2)
                    }
                }.buttonStyle(.plain)
            }
        }
        .navigationTitle(item.name)
        .task {
            guard let api = store.api, let sid = item.seriesId else { return }
            do { eps = try await api.episodes(seriesId: sid); loading = false }
            catch { self.error = error.localizedDescription; loading = false }
        }
        .fullScreenCover(item: $play) { t in PlayerScreen(target: t) }
    }
}
