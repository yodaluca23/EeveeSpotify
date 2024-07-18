import Foundation

enum LyricsSource: Int, CaseIterable, CustomStringConvertible {
    case genius
    case lrclib
    case musixmatch
    case petit
    case beautiful
    case notReplaced
    
    static var allCases: [LyricsSource] {
        return [.genius, .lrclib, .musixmatch, .petit, .beautiful]
    }

    var description: String {
        switch self {
        case .genius: "Genius"
        case .lrclib: "LRCLIB"
        case .musixmatch: "Musixmatch"
        case .petit: "PetitLyrics"
        case .beautiful: "BeautifulLyrics"
        case .notReplaced: "Spotify"
        }
    }
    
    var isReplacing: Bool { self != .notReplaced }
    
    static var defaultSource: LyricsSource {
        Locale.isInRegion("JP", orHasLanguage: "ja")
            ? .petit
            : .beautiful
    }
}
