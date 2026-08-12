import SwiftUI

struct SFSymbolPickerView: View {
    var onPick: (String) -> Void

    @State private var query = ""
    @State private var selectedCategory = SFSymbolCatalog.categories[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a Symbol").font(.system(size: 12, weight: .semibold))

            TextField("Search symbols", text: $query)
                .textFieldStyle(.roundedBorder)

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                categoryPicker
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 6) {
                    ForEach(displayedSymbols, id: \.self) { symbol in
                        Button {
                            onPick(symbol)
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.bordered)
                        .orbitTooltip(symbol)
                    }
                }
            }
            .frame(height: 240)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SFSymbolCatalog.categories, id: \.name) { category in
                    Button(category.name) { selectedCategory = category }
                        .buttonStyle(.bordered)
                        .tint(selectedCategory.name == category.name ? .accentColor : .secondary)
                        .controlSize(.small)
                }
            }
        }
    }

    private var displayedSymbols: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return selectedCategory.symbols }
        return SFSymbolCatalog.categories
            .flatMap(\.symbols)
            .filter { $0.contains(trimmed) }
    }
}

enum SFSymbolCatalog {
    struct Category {
        var name: String
        var symbols: [String]
    }

    static let categories: [Category] = [
        Category(name: "General", symbols: [
            "circle.grid.2x2", "star", "star.fill", "flag", "flag.fill",
            "bookmark", "bookmark.fill", "bell", "bell.fill", "tag", "tag.fill",
            "gearshape", "gearshape.fill", "checkmark.circle", "checkmark.circle.fill",
            "xmark.circle", "questionmark.circle", "exclamationmark.circle", "circle.hexagongrid",
        ]),
        Category(name: "Work", symbols: [
            "briefcase", "briefcase.fill", "chart.bar", "chart.line.uptrend.xyaxis",
            "doc.text", "doc.text.fill", "folder", "folder.fill", "calendar",
            "checklist", "list.bullet.clipboard", "person.crop.circle", "person.2",
            "envelope", "envelope.fill", "printer", "building.2", "building.2.fill",
            "lightbulb", "lightbulb.fill", "wrench.and.screwdriver", "hammer",
        ]),
        Category(name: "Learning", symbols: [
            "book", "book.fill", "books.vertical", "graduationcap", "graduationcap.fill",
            "pencil", "pencil.tip", "highlighter", "text.book.closed", "brain",
            "brain.head.profile", "puzzlepiece", "puzzlepiece.fill",
        ]),
        Category(name: "Nature", symbols: [
            "leaf", "leaf.fill", "tree", "camera.macro", "sun.max", "sun.max.fill",
            "moon", "moon.fill", "cloud", "cloud.rain", "snowflake", "flame",
            "flame.fill", "drop", "drop.fill", "wind",
            "pawprint", "pawprint.fill", "ant", "ladybug",
        ]),
        Category(name: "Food", symbols: [
            "cup.and.saucer", "cup.and.saucer.fill", "mug", "mug.fill", "fork.knife",
            "wineglass", "wineglass.fill", "carrot", "carrot.fill", "birthday.cake",
            "birthday.cake.fill", "takeoutbag.and.cup.and.straw",
        ]),
        Category(name: "Travel", symbols: [
            "airplane", "airplane.departure", "car", "car.fill", "bicycle",
            "bus", "tram", "ferry", "map", "map.fill", "mappin", "mappin.and.ellipse",
            "globe", "globe.americas", "house", "house.fill", "building.columns",
            "beach.umbrella", "beach.umbrella.fill", "mountain.2", "mountain.2.fill",
            "suitcase", "suitcase.fill",
        ]),
        Category(name: "Play", symbols: [
            "gamecontroller", "gamecontroller.fill", "music.note", "music.note.list",
            "headphones", "paintpalette", "paintpalette.fill", "camera",
            "camera.fill", "film", "photo", "photo.on.rectangle", "theatermasks",
            "sportscourt", "figure.walk", "figure.run", "dumbbell", "dumbbell.fill",
            "cart", "cart.fill",
        ]),
        Category(name: "Tech", symbols: [
            "desktopcomputer", "laptopcomputer", "keyboard", "terminal",
            "terminal.fill", "chevron.left.forwardslash.chevron.right",
            "cpu", "memorychip", "network", "wifi", "antenna.radiowaves.left.and.right",
            "bolt", "bolt.fill", "bolt.circle", "server.rack", "externaldrive",
            "shippingbox", "shippingbox.fill",
        ]),
        Category(name: "Symbols", symbols: [
            "heart", "heart.fill", "heart.circle", "circle.fill", "square.fill",
            "triangle.fill", "diamond.fill", "hexagon.fill", "seal.fill",
            "shield", "shield.fill", "lock", "lock.fill", "key", "key.fill",
            "eye", "eye.fill", "eyeglasses", "infinity", "atom",
        ]),
    ]
}
