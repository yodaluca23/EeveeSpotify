import Foundation

class BeautifulLyricsRepository: LyricsRepository {
    
    private let apiUrl = "https://beautiful-lyrics.socalifornian.live/lyrics"
    
    static let shared = BeautifulLyricsRepository()
    
    private init() {}
    
    private func perform(_ trackId: String) throws -> Data {
        let stringUrl = "\(apiUrl)/\(trackId)"
        var request = URLRequest(url: URL(string: stringUrl)!)
        request.addValue("Bearer litterallyAnythingCanGoHereItJustTakesItLOL", forHTTPHeaderField: "authorization")
        
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?
        
        let task = URLSession.shared.dataTask(with: request) { response, _, err in
            error = err
            data = response
            semaphore.signal()
        }
        
        task.resume()
        semaphore.wait()
        
        if let error = error {
            throw error
        }
        
        return data!
    }
    
    private func parseLyrics(_ data: Data) throws -> [LyricsLineDto] {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let type = json["Type"] as? String,
              let content = json["Content"] as? [[String: Any]] else {
            throw LyricsError.DecodingError
        }
        
        var lyrics: [LyricsLineDto] = []
        
        if type == "Line" {
            for line in content {
                guard let startTime = line["StartTime"] as? Double,
                      let text = line["Text"] as? String else {
                    continue
                }
                let startTimeMs = Int(startTime * 1000)
                lyrics.append(LyricsLineDto(content: text, offsetMs: startTimeMs))
            }
        } else if type == "Syllable" {
            for item in content {
                guard let lead = item["Lead"] as? [String: Any],
                      let syllables = lead["Syllables"] as? [[String: Any]],
                      let startTime = lead["StartTime"] as? Double else {
                    continue
                }
                let line = syllables.map { syllable -> String in
                    let text = syllable["Text"] as! String
                    let isPartOfWord = syllable["IsPartOfWord"] as! Bool
                    return text + (isPartOfWord ? "" : " ")
                }.joined()
                let startTimeMs = Int(startTime * 1000)
                lyrics.append(LyricsLineDto(content: line, offsetMs: startTimeMs))
            }
        }
        
        return lyrics
    }
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let data = try perform(query.spotifyTrackId)
        let lyricsLines = try parseLyrics(data)
        
        return LyricsDto(
            lines: lyricsLines,
            timeSynced: true
        )
    }
}
