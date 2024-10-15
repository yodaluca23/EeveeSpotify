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

    private func fetchNewTrackId(query: LyricsSearchQuery, token: String) -> String? {
        let artist = query.primaryArtist
        let song = query.title
        let queryArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let querySong = song.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let searchUrlString = "https://api.spotify.com/v1/search?query=artist%3A+\(queryArtist)+track%3A+\(querySong)&type=track&offset=0&limit=1"
        
        guard let searchUrl = URL(string: searchUrlString) else {
            NSLog("[EeveeSpotify] Invalid search URL")
            return nil
        }
        
        var request = URLRequest(url: searchUrl)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let semaphore = DispatchSemaphore(value: 0)
        var trackId: String?
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            guard error == nil else {
                NSLog("[EeveeSpotify] Error during Spotify search request: \(error!.localizedDescription)")
                return
            }
            
            guard let data = data else {
                NSLog("[EeveeSpotify] No data received from Spotify search")
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let tracks = json["tracks"] as? [String: Any],
                   let items = tracks["items"] as? [[String: Any]],
                   let href = items.first?["href"] as? String {
                    if let match = href.range(of: "(?<=tracks/)[a-zA-Z0-9]+", options: .regularExpression) {
                        trackId = String(href[match])
                    }
                }
            } catch {
                NSLog("[EeveeSpotify] Failed to parse Spotify search response: \(error.localizedDescription)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return trackId
    }

    private func perform(_ query: LyricsSearchQuery) throws -> Data {
        var trackId = query.spotifyTrackId
        var token: String?
        let tokenSemaphore = DispatchSemaphore(value: 0)
        
        getSpotifyClientToken { fetchedToken in
            token = fetchedToken
            tokenSemaphore.signal()
        }
        tokenSemaphore.wait()
        if trackId.count < 4 {
            NSLog("[EeveeSpotify] Spotify TrackID is less than 4. Assuming this is a local track. Fetching TrackID from Spotify.")
            if let fetchedTrackId = fetchNewTrackId(query: query, token: token ?? "") {
                trackId = fetchedTrackId
                NSLog("[EeveeSpotify] New TrackID fetched: \(trackId)")
            } else {
                throw LyricsError.NoSuchSong
            }
        }

        let stringUrl = "\(apiUrl)/\(trackId)"
        var request = URLRequest(url: URL(string: stringUrl)!)
        
        if let token = token {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        } else {
            NSLog("[EeveeSpotify] Failed to retrieve Spotify client token, proceeding with default authorization.")
            request.addValue("Bearer failedToFetchSpotifyToken", forHTTPHeaderField: "authorization")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        let task = URLSession.shared.dataTask(with: request) { responseData, _, taskError in
            if let taskError = taskError {
                error = taskError
            } else {
                data = responseData
            }
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
        let data = try perform(query)
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
