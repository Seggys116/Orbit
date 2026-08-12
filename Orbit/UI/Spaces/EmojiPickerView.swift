import SwiftUI

struct EmojiPickerView: View {
    var onPick: (String) -> Void

    @State private var query = ""
    @State private var selectedCategory = EmojiCatalog.categories[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose an Emoji").font(.system(size: 12, weight: .semibold))

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                categoryPicker
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 4) {
                    ForEach(displayedEmoji, id: \.self) { emoji in
                        Button {
                            onPick(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 20))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 220)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(EmojiCatalog.categories, id: \.name) { category in
                    Button(category.name) { selectedCategory = category }
                        .buttonStyle(.bordered)
                        .tint(selectedCategory.name == category.name ? .accentColor : .secondary)
                        .controlSize(.small)
                }
            }
        }
    }

    private var displayedEmoji: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return selectedCategory.emoji }
        return EmojiCatalog.categories
            .flatMap(\.entries)
            .filter { $0.keywords.contains { $0.contains(trimmed) } }
            .map(\.emoji)
    }
}

enum EmojiCatalog {
    struct Entry {
        var emoji: String
        var keywords: [String]
    }

    struct Category {
        var name: String
        var entries: [Entry]
        var emoji: [String] { entries.map(\.emoji) }
    }

    static let categories: [Category] = [
        Category(name: "Smileys", entries: [
            Entry(emoji: "😀", keywords: ["smile", "happy", "grin"]),
            Entry(emoji: "😄", keywords: ["smile", "happy", "joy"]),
            Entry(emoji: "😁", keywords: ["grin", "smile"]),
            Entry(emoji: "😆", keywords: ["laugh", "happy"]),
            Entry(emoji: "😅", keywords: ["sweat", "laugh"]),
            Entry(emoji: "🤣", keywords: ["rofl", "laugh"]),
            Entry(emoji: "😂", keywords: ["joy", "laugh", "cry"]),
            Entry(emoji: "🙂", keywords: ["smile", "slight"]),
            Entry(emoji: "😉", keywords: ["wink"]),
            Entry(emoji: "😊", keywords: ["blush", "smile"]),
            Entry(emoji: "😇", keywords: ["angel", "halo"]),
            Entry(emoji: "😍", keywords: ["love", "heart", "eyes"]),
            Entry(emoji: "🥰", keywords: ["love", "hearts"]),
            Entry(emoji: "😘", keywords: ["kiss"]),
            Entry(emoji: "😎", keywords: ["cool", "sunglasses"]),
            Entry(emoji: "🤓", keywords: ["nerd", "glasses"]),
            Entry(emoji: "🧐", keywords: ["monocle", "curious"]),
            Entry(emoji: "🤔", keywords: ["think", "hmm"]),
            Entry(emoji: "😴", keywords: ["sleep", "tired"]),
            Entry(emoji: "🥳", keywords: ["party", "celebrate"]),
            Entry(emoji: "😢", keywords: ["cry", "sad"]),
            Entry(emoji: "😭", keywords: ["cry", "sob"]),
            Entry(emoji: "😡", keywords: ["angry", "mad"]),
            Entry(emoji: "🤯", keywords: ["mind", "blown", "shock"]),
            Entry(emoji: "👻", keywords: ["ghost", "spooky"]),
            Entry(emoji: "🤖", keywords: ["robot", "bot"]),
            Entry(emoji: "🙈", keywords: ["monkey", "see no evil"]),
        ]),
        Category(name: "Work", entries: [
            Entry(emoji: "💼", keywords: ["work", "briefcase", "office", "business"]),
            Entry(emoji: "📈", keywords: ["chart", "growth", "stocks", "work"]),
            Entry(emoji: "📊", keywords: ["chart", "bar", "data", "work"]),
            Entry(emoji: "🧾", keywords: ["receipt", "finance", "work"]),
            Entry(emoji: "🗂️", keywords: ["files", "organize", "work"]),
            Entry(emoji: "📅", keywords: ["calendar", "schedule", "work"]),
            Entry(emoji: "✅", keywords: ["check", "done", "task"]),
            Entry(emoji: "🧠", keywords: ["brain", "idea", "think"]),
            Entry(emoji: "💡", keywords: ["idea", "bulb", "light"]),
            Entry(emoji: "🛠️", keywords: ["tools", "build", "fix"]),
            Entry(emoji: "🧑‍💻", keywords: ["code", "developer", "work"]),
            Entry(emoji: "📚", keywords: ["books", "study", "school"]),
            Entry(emoji: "🎓", keywords: ["graduation", "school", "study"]),
            Entry(emoji: "✉️", keywords: ["mail", "email", "work"]),
        ]),
        Category(name: "Nature", entries: [
            Entry(emoji: "🌿", keywords: ["leaf", "nature", "plant"]),
            Entry(emoji: "🌱", keywords: ["seedling", "plant", "grow"]),
            Entry(emoji: "🌳", keywords: ["tree", "nature"]),
            Entry(emoji: "🌸", keywords: ["flower", "blossom"]),
            Entry(emoji: "🌻", keywords: ["sunflower", "flower"]),
            Entry(emoji: "🌊", keywords: ["wave", "ocean", "water"]),
            Entry(emoji: "🔥", keywords: ["fire", "hot"]),
            Entry(emoji: "❄️", keywords: ["snow", "cold", "winter"]),
            Entry(emoji: "⭐️", keywords: ["star"]),
            Entry(emoji: "🌙", keywords: ["moon", "night"]),
            Entry(emoji: "☀️", keywords: ["sun", "sunny"]),
            Entry(emoji: "🐶", keywords: ["dog", "puppy", "pet", "animal"]),
            Entry(emoji: "🐱", keywords: ["cat", "kitten", "pet", "animal"]),
            Entry(emoji: "🦊", keywords: ["fox", "animal"]),
            Entry(emoji: "🦁", keywords: ["lion", "animal"]),
            Entry(emoji: "🐢", keywords: ["turtle", "animal"]),
        ]),
        Category(name: "Food", entries: [
            Entry(emoji: "🍕", keywords: ["pizza", "food"]),
            Entry(emoji: "🍔", keywords: ["burger", "food"]),
            Entry(emoji: "🍣", keywords: ["sushi", "food"]),
            Entry(emoji: "🍜", keywords: ["noodles", "ramen", "food"]),
            Entry(emoji: "☕️", keywords: ["coffee", "drink"]),
            Entry(emoji: "🍵", keywords: ["tea", "drink"]),
            Entry(emoji: "🍰", keywords: ["cake", "dessert"]),
            Entry(emoji: "🍎", keywords: ["apple", "fruit"]),
            Entry(emoji: "🥑", keywords: ["avocado", "food"]),
            Entry(emoji: "🍷", keywords: ["wine", "drink"]),
            Entry(emoji: "🍺", keywords: ["beer", "drink"]),
            Entry(emoji: "🍩", keywords: ["donut", "dessert"]),
        ]),
        Category(name: "Travel", entries: [
            Entry(emoji: "✈️", keywords: ["plane", "travel", "flight"]),
            Entry(emoji: "🚗", keywords: ["car", "travel", "drive"]),
            Entry(emoji: "🚀", keywords: ["rocket", "space", "launch"]),
            Entry(emoji: "🏔️", keywords: ["mountain", "travel", "hike"]),
            Entry(emoji: "🏖️", keywords: ["beach", "travel", "vacation"]),
            Entry(emoji: "🗺️", keywords: ["map", "travel"]),
            Entry(emoji: "🧳", keywords: ["luggage", "travel", "suitcase"]),
            Entry(emoji: "🚢", keywords: ["ship", "boat", "travel"]),
            Entry(emoji: "🏠", keywords: ["house", "home"]),
            Entry(emoji: "🏙️", keywords: ["city", "skyline"]),
            Entry(emoji: "🚲", keywords: ["bike", "cycle", "travel"]),
        ]),
        Category(name: "Objects", entries: [
            Entry(emoji: "🎮", keywords: ["game", "controller", "play"]),
            Entry(emoji: "🎧", keywords: ["headphones", "music"]),
            Entry(emoji: "🎨", keywords: ["art", "paint", "design"]),
            Entry(emoji: "📷", keywords: ["camera", "photo"]),
            Entry(emoji: "🎬", keywords: ["movie", "film"]),
            Entry(emoji: "📖", keywords: ["book", "read"]),
            Entry(emoji: "🛒", keywords: ["cart", "shopping"]),
            Entry(emoji: "💰", keywords: ["money", "finance"]),
            Entry(emoji: "🎵", keywords: ["music", "note"]),
            Entry(emoji: "🧩", keywords: ["puzzle", "piece"]),
            Entry(emoji: "🔒", keywords: ["lock", "secure", "private"]),
            Entry(emoji: "🗝️", keywords: ["key", "unlock"]),
            Entry(emoji: "⚡️", keywords: ["bolt", "fast", "energy"]),
            Entry(emoji: "✨", keywords: ["sparkles", "magic", "new"]),
        ]),
        Category(name: "Symbols", entries: [
            Entry(emoji: "❤️", keywords: ["heart", "love"]),
            Entry(emoji: "💙", keywords: ["heart", "blue"]),
            Entry(emoji: "💚", keywords: ["heart", "green"]),
            Entry(emoji: "💛", keywords: ["heart", "yellow"]),
            Entry(emoji: "🧡", keywords: ["heart", "orange"]),
            Entry(emoji: "💜", keywords: ["heart", "purple"]),
            Entry(emoji: "🔵", keywords: ["circle", "blue"]),
            Entry(emoji: "🟢", keywords: ["circle", "green"]),
            Entry(emoji: "🟡", keywords: ["circle", "yellow"]),
            Entry(emoji: "🟣", keywords: ["circle", "purple"]),
            Entry(emoji: "⚪️", keywords: ["circle", "white"]),
            Entry(emoji: "⚫️", keywords: ["circle", "black"]),
        ]),
    ]
}
