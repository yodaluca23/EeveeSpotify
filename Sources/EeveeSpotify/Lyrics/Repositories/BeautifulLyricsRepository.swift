import Foundation

class BeautifulLyricsRepository: LyricsRepository {
    
    private let apiUrl = "https://beautiful-lyrics.socalifornian.live/lyrics"
    
    init() {}
    
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
        
        guard let responseData = data, !responseData.isEmpty else {
            throw LyricsError.NoSuchSong
        }
        
        return responseData
    }
    
    private func parseLyrics(_ data: Data) throws -> [LyricsLineDto] {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let type = json["Type"] as? String,
              let content = json["Content"] as? [[String: Any]] else {
            throw LyricsError.DecodingError
        }
        
        var lyrics: [LyricsLineDto] = []
        var prevEndTime: Double = 0
        
        func addEmptyTimestampIfGap(startTime: Double) {
            let gap = UserDefaults.instrumentalgap
            if startTime - prevEndTime > gap {
                lyrics.append(LyricsLineDto(content: "♪", offsetMs: Int(prevEndTime * 1000)))
            }
        }
        
        if type == "Line" {
            for line in content {
                guard let startTime = line["StartTime"] as? Double,
                      let text = line["Text"] as? String,
                      let endTime = line["EndTime"] as? Double else {
                    continue
                }
                addEmptyTimestampIfGap(startTime: startTime)
                let startTimeMs = Int(startTime * 1000)
                lyrics.append(LyricsLineDto(content: text, offsetMs: startTimeMs))
                prevEndTime = endTime
            }
        } else if type == "Syllable" {
            for item in content {
                guard let lead = item["Lead"] as? [String: Any],
                      let syllables = lead["Syllables"] as? [[String: Any]],
                      let startTime = lead["StartTime"] as? Double,
                      let endTime = lead["EndTime"] as? Double else {
                    continue
                }
                addEmptyTimestampIfGap(startTime: startTime)
                let line = syllables.map { syllable -> String in
                    let text = syllable["Text"] as! String
                    let isPartOfWord = syllable["IsPartOfWord"] as! Bool
                    return text + (isPartOfWord ? "" : " ")
                }.joined().trimmingCharacters(in: .whitespaces)
                let startTimeMs = Int(startTime * 1000)
                lyrics.append(LyricsLineDto(content: line, offsetMs: startTimeMs))
                prevEndTime = endTime
                
                if let backgrounds = item["Background"] as? [[String: Any]] {
                    for bg in backgrounds {
                        guard let bgSyllables = bg["Syllables"] as? [[String: Any]],
                              let bgStartTime = bg["StartTime"] as? Double,
                              let bgEndTime = bg["EndTime"] as? Double else {
                            continue
                        }
                        addEmptyTimestampIfGap(startTime: bgStartTime)
                        let bgLine = bgSyllables.map { syllable -> String in
                            let text = syllable["Text"] as! String
                            let isPartOfWord = syllable["IsPartOfWord"] as! Bool
                            return text + (isPartOfWord ? "" : " ")
                        }.joined().trimmingCharacters(in: .whitespaces)
                        let bgStartTimeMs = Int(bgStartTime * 1000)
                        lyrics.append(LyricsLineDto(content: "(\(bgLine))", offsetMs: bgStartTimeMs))
                        prevEndTime = bgEndTime
                    }
                }
            }
        } else {
            throw LyricsError.DecodingError
        }
        
        return lyrics
    }
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let data = try perform(query.spotifyTrackId)
        let lyricsLines = try parseLyrics(data)
        
        // Check for romanizationStatus
        let lyricsContent = lyricsLines.map { $0.content }
        let romanizationStatus: LyricsRomanizationStatus = lyricsContent.canBeRomanized ? .canBeRomanized : .original
        
        return LyricsDto(
            lines: lyricsLines,
            timeSynced: true,
            romanization: romanizationStatus
        )
    }
}
