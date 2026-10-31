import Foundation

// What a fragmented MP4 says of itself in its first few kilobytes, to tell
// which of the files a page has been loading is the one of the video on
// screen: whether it holds a picture or sound, how long it runs, and how big
// the picture is. Sites that stream (Instagram, Facebook) keep a video as a
// picture file and a sound file, and a page holds several videos at once, each
// with its own, loaded ahead; the first bytes of each file (ftyp, moov, and
// the sidx that lists the fragments) are enough to match one to a <video>.
enum MP4Probe {
    struct Info {
        enum Kind { case video, audio, other }
        /// What the file holds first of all: a picture (with its sound, if it has any) or sound alone.
        var kind: Kind = .other
        var hasAudio = false
        /// Seconds; nil when the start of the file doesn't say.
        var duration: Double?
        var width = 0
        var height = 0
    }

    /// How many bytes the start of the file needs to hold all of moov, when the
    /// bytes given hold its start but not its end (a long movie's tables make
    /// it big, and its second track comes after them).
    static func bytesWanted(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        var at = 0
        while at + 8 <= bytes.count {
            let size = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            let type = String(bytes: bytes[at + 4..<at + 8], encoding: .isoLatin1)
            if type == "moov" { return size > 8 ? at + size : nil }
            guard size >= 8 else { return nil }
            at += size
        }
        return nil
    }

    /// The first bytes of an mp4 (as many as there are), read for what it says.
    static func read(_ data: Data) -> Info? {
        let bytes = [UInt8](data)
        var info = Info()
        var movieScale = 0.0, movieDuration = 0.0, fragmentDuration = 0.0, sidxDuration = 0.0
        var sawFtyp = false
        var hasVideo = false

        func u32(_ at: Int) -> Int? { at >= 0 && at + 4 <= bytes.count ? Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) : nil }
        func u64(_ at: Int) -> Double? {
            guard at >= 0, at + 8 <= bytes.count else { return nil }
            var n: UInt64 = 0
            for i in 0..<8 { n = n << 8 | UInt64(bytes[at + i]) }
            return Double(n)
        }
        func kind(_ at: Int) -> String? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return String(bytes: bytes[at..<at + 4], encoding: .isoLatin1)
        }

        /// Boxes between `start` and `end`, each looked into as far as it matters.
        func walk(_ start: Int, _ end: Int, track: Bool) {
            var at = start
            while at + 8 <= end, let size32 = u32(at), let type = kind(at + 4) {
                var size = size32, header = 8
                if size == 1, let big = u64(at + 8) { size = Int(big); header = 16 }
                else if size == 0 { size = end - at }
                guard size >= header else { return }
                let body = at + header
                let stop = min(at + size, end)
                switch type {
                case "ftyp": sawFtyp = true
                case "moov", "mdia", "minf": walk(body, stop, track: track)
                case "trak": walk(body, stop, track: true)
                case "mvex": walk(body, stop, track: track)
                case "mvhd":
                    if let version = bytes[safe: body] {
                        if version == 1 { movieScale = Double(u32(body + 20) ?? 0); movieDuration = u64(body + 24) ?? 0 }
                        else { movieScale = Double(u32(body + 12) ?? 0); movieDuration = Double(u32(body + 16) ?? 0) }
                    }
                case "mehd":
                    if let version = bytes[safe: body] {
                        fragmentDuration = version == 1 ? (u64(body + 4) ?? 0) : Double(u32(body + 4) ?? 0)
                    }
                case "tkhd":
                    // Width and height are the last two 16.16 numbers of the box.
                    if track, stop - 8 >= body, let w = u32(stop - 8), let h = u32(stop - 4), w > 0 || h > 0 {
                        info.width = w >> 16
                        info.height = h >> 16
                    }
                case "hdlr":
                    // Every track says what it is: a file that holds both (a
                    // picture with its sound) has the sound's first on some sites.
                    if track, let handler = kind(body + 8) {
                        if handler == "vide" { hasVideo = true } else if handler == "soun" { info.hasAudio = true }
                    }
                case "sidx":
                    // version/flags, reference_ID, timescale, then the first
                    // presentation time and offset (32 or 64 bits each), a
                    // reserved word and the count of references of 12 bytes.
                    if let version = bytes[safe: body], let scale = u32(body + 8), scale > 0 {
                        let after = body + 12 + (version == 0 ? 8 : 16)
                        if let count = u32(after).map({ $0 & 0xFFFF }) {
                            var total = 0.0
                            for i in 0..<count {
                                guard let duration = u32(after + 4 + i * 12 + 4) else { break }
                                total += Double(duration)
                            }
                            sidxDuration = total / Double(scale)
                        }
                    }
                default: break
                }
                at += size
            }
        }
        walk(0, bytes.count, track: false)
        guard sawFtyp else { return nil }
        info.kind = hasVideo ? .video : info.hasAudio ? .audio : .other
        // The list of fragments is the surest; then the fragments' total in
        // moov; then a movie that is not in fragments.
        if sidxDuration > 0 { info.duration = sidxDuration }
        else if fragmentDuration > 0, movieScale > 0 { info.duration = fragmentDuration / movieScale }
        else if movieDuration > 0, movieScale > 0 { info.duration = movieDuration / movieScale }
        return info
    }
}

private extension Array where Element == UInt8 {
    subscript(safe index: Int) -> UInt8? { index >= 0 && index < count ? self[index] : nil }
}
