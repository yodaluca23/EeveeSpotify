import Foundation

struct PetitLyricsRepository: LyricsRepository {
    private let apiUrl = "https://p1.petitlyrics.com/api/GetPetitLyricsData.php"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify"
        ]
        
        session = URLSession(configuration: configuration)
    }
    
    private func perform(
        _ query: [String: Any]
    ) throws -> Data {
        var request = URLRequest(url: URL(string: apiUrl)!)
        request.httpMethod = "POST"
        
        let queryString = query.queryString
        request.httpBody = queryString.data(using: .utf8)
        
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        let task = session.dataTask(with: request) { response, _, err in
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
    
    private func parseXML(_ data: Data) throws -> [String: Any] {
        let parser = XMLParser(data: data)
        let delegate = XMLParserDelegateImpl()
        parser.delegate = delegate
        
        if parser.parse() {
            return delegate.result
        } else {
            throw LyricsError.DecodingError
        }
    }
    
    private func decodeBase64(_ base64String: String) throws -> Data {
        guard let data = Data(base64Encoded: base64String) else {
            throw LyricsError.DecodingError
        }
        return data
    }
    
    private func mapTimeSyncedLyrics(_ xmlData: Data) throws -> [LyricsLineDto] {
        let parser = XMLParser(data: xmlData)
        let delegate = TimeSyncedLyricsParserDelegate()
        parser.delegate = delegate
        
        if parser.parse() {
            return delegate.lines
        } else {
            throw LyricsError.DecodingError
        }
    }
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        var petitLyricsQuery = [
            "maxCount": "1",
            "key_title": query.title,
            "key_artist": query.primaryArtist,
            "terminalType": "10",
            "clientAppId": "p1232089",
            "lyricsType": "3"
        ]
        
        let data = try perform(petitLyricsQuery)
        let xmlResponse = try parseXML(data)
        
        guard let returnedCount = xmlResponse["returnedCount"] as? Int, returnedCount > 0 else {
            throw LyricsError.NoSuchSong
        }
        
        guard let songs = xmlResponse["songs"] as? [String: Any],
              let song = songs["song"] as? [String: Any],
              let lyricsDataBase64 = song["lyricsData"] as? String,
              let availableLyricsType = song["availableLyricsType"] as? Int else {
            throw LyricsError.DecodingError
        }
        
        let lyricsData = try decodeBase64(lyricsDataBase64)
        
        if availableLyricsType == 2 {
            petitLyricsQuery["lyricsType"] = "1"
            let data = try perform(petitLyricsQuery)
            let xmlResponse = try parseXML(data)
            
            guard let songs = xmlResponse["songs"] as? [String: Any],
                  let song = songs["song"] as? [String: Any],
                  let lyricsDataBase64 = song["lyricsData"] as? String else {
                throw LyricsError.DecodingError
            }
            
            let lyricsData = try decodeBase64(lyricsDataBase64)
            let lines = String(data: lyricsData, encoding: .utf8)?.components(separatedBy: "\n").map { LyricsLineDto(content: $0) } ?? []
            
            return LyricsDto(lines: lines, timeSynced: false)
        }
        
        if availableLyricsType == 1 {
            let lines = String(data: lyricsData, encoding: .utf8)?.components(separatedBy: "\n").map { LyricsLineDto(content: $0) } ?? []
            return LyricsDto(lines: lines, timeSynced: false)
        }
        
        if availableLyricsType == 3 {
            let lines = try mapTimeSyncedLyrics(lyricsData)
            return LyricsDto(lines: lines, timeSynced: true)
        }
        
        throw LyricsError.DecodingError
    }
}

private class XMLParserDelegateImpl: NSObject, XMLParserDelegate {
    var result: [String: Any] = [:]
    private var currentElement: String = ""
    private var currentSong: [String: Any] = [:]
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "returnedCount" || currentElement == "availableLyricsType" {
            result[currentElement] = Int(string)
        } else if currentElement == "lyricsData" {
            currentSong[currentElement] = string
        } else {
            currentSong[currentElement] = string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "song" {
            result["song"] = currentSong
            currentSong = [:]
        }
    }
}

private class TimeSyncedLyricsParserDelegate: NSObject, XMLParserDelegate {
    var lines: [LyricsLineDto] = []
    private var currentElement: String = ""
    private var currentLine: LyricsLineDto?
    private var currentStartTime: Int?
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "linestring" {
            currentLine = LyricsLineDto(content: string)
        } else if currentElement == "starttime" {
            currentStartTime = Int(string)
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "line" {
            if let line = currentLine, let startTime = currentStartTime {
                lines.append(LyricsLineDto(content: line.content, offsetMs: startTime))
            }
            currentLine = nil
            currentStartTime = nil
        }
    }
}
