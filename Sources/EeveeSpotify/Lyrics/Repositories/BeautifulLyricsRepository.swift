import Foundation

class BeautifulLyricsRepository: LyricsRepository {
    
    private let apiUrl = "https://beautiful-lyrics.socalifornian.live/lyrics"
    
    init() {}
    
    func getSpotifyClientToken(completion: @escaping (String?) -> Void) {
        let url = URL(string: "https://open.spotify.com")!
        
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                NSLog("[EeveeSpotify] Spotfiy Token Request error: \(error)")
                completion(nil)
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                NSLog("[EeveeSpotify] Spotify Token Request Invalid response or status code")
                completion(nil)
                return
            }
            
            guard let data = data, let htmlContent = String(data: data, encoding: .utf8) else {
                NSLog("[EeveeSpotify] Spotify Token Request No data received or data decoding failed")
                completion(nil)
                return
            }
            
            do {
                let regexPattern = "\"accessToken\":\"([^\"]+)\""
                let regex = try NSRegularExpression(pattern: regexPattern, options: [])
                let nsRange = NSRange(htmlContent.startIndex..<htmlContent.endIndex, in: htmlContent)
                
                if let match = regex.firstMatch(in: htmlContent, options: [], range: nsRange) {
                    if let tokenRange = Range(match.range(at: 1), in: htmlContent) {
                        let accessToken = String(htmlContent[tokenRange])
                        completion(accessToken)
                        return
                    }
                }
                
                NSLog("[EeveeSpotify] Spotify Token Request Failed to find access token in HTML")
                completion(nil)
            } catch {
                NSLog("[EeveeSpotify] Spotify Token Request Regex error: \(error)")
                completion(nil)
            }
        }
        
        task.resume()
    }

    
    private func perform(_ trackId: String) throws -> Data {
        let stringUrl = "\(apiUrl)/\(trackId)"
        var request = URLRequest(url: URL(string: stringUrl)!)
        
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?
        
        getSpotifyClientToken { token in
            if let token = token {
                request.addValue("Bearer \(token)", forHTTPHeaderField: "authorization")
            } else {
                NSLog("[EeveeSpotify] Failed to retrieve Spotify client token, proceeding with default authorization.")
                request.addValue("Bearer failedToFetchSpotifyToken", forHTTPHeaderField: "authorization")
            }
            
            let task = URLSession.shared.dataTask(with: request) { responseData, _, taskError in
                if let taskError = taskError {
                    error = taskError
                } else {
                    data = responseData
                }
                semaphore.signal()
            }
            
            task.resume()
        }
        
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
        var prevStartTime: Double = 0
        
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
                prevStartTime = startTime
                
                if let backgrounds = item["Background"] as? [[String: Any]] {
                    for bg in backgrounds {
                        guard let bgSyllables = bg["Syllables"] as? [[String: Any]],
                              let bgStartTime = bg["StartTime"] as? Double,
                              let bgEndTime = bg["EndTime"] as? Double else {
                            continue
                        }
                        let bgLine = bgSyllables.map { syllable -> String in
                            let text = syllable["Text"] as! String
                            let isPartOfWord = syllable["IsPartOfWord"] as! Bool
                            return text + (isPartOfWord ? "" : " ")
                        }.joined().trimmingCharacters(in: .whitespaces)
                        
                        let isOverlaped = (bgStartTime < prevEndTime && bgEndTime > prevStartTime)
                        if isOverlaped {
                            if bgStartTime < prevStartTime {
                                if let lastLyric = lyrics.last {
                                    lyrics[lyrics.count - 1] = LyricsLineDto(
                                        content: "(\(bgLine))\n\(lastLyric.content)",
                                        offsetMs: Int(bgStartTime * 1000)
                                    )
                                }
                            } else {
                                if let lastLyric = lyrics.last {
                                    lyrics[lyrics.count - 1] = LyricsLineDto(
                                        content: "\(lastLyric.content)\n(\(bgLine))",
                                        offsetMs: lastLyric.offsetMs
                                    )
                                }
                            }
                        } else {
                            addEmptyTimestampIfGap(startTime: bgStartTime)
                            let bgStartTimeMs = Int(bgStartTime * 1000)
                            lyrics.append(LyricsLineDto(content: "(\(bgLine))", offsetMs: bgStartTimeMs))
                            prevEndTime = bgEndTime
                            prevStartTime = bgStartTime
                        }
                    }
                }
            }
        } else {
            throw LyricsError.DecodingError
        }
        
        lyrics = lyrics.compactMap { line in
            guard let offset = line.offsetMs else {
                NSLog("[EeveeSpotify] Skipping line with nil offsetMs")
                return nil
            }
            return line
        }
        
        lyrics.sort { $0.offsetMs! < $1.offsetMs! }
        
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
