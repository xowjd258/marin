import Foundation
import os

private let memLog = Logger(subsystem: "marin", category: "ConversationMemory")

/// Manages conversation history for the Realtime API by tracking items,
/// pruning old ones, and maintaining a structured rolling summary.
/// This prevents context bloat that causes the AI to loop and degrade.
@MainActor
final class ConversationMemory {
    /// Maximum conversation items to keep in the server's history
    private let maxItems = 16
    /// Items to keep untouched (most recent)
    private let keepRecentItems = 10
    /// Minimum items before triggering a prune
    private let pruneThreshold = 18

    // MARK: - Item tracking

    struct TrackedItem {
        let id: String
        let serverID: String?  // server-assigned ID if different
        let type: ItemType
        let timestamp: Date
        let summary: String  // short description for memory

        enum ItemType {
            case userAudio
            case userText
            case userImage
            case assistantAudio(transcript: String)
            case functionCall(name: String, args: String)
            case functionResult(name: String, output: String)
            case systemMessage
        }
    }

    private(set) var trackedItems: [TrackedItem] = []
    /// IDs that have already been deleted from the server (e.g., old images replaced by sendImageItem)
    private var deletedFromServer: Set<String> = []

    // MARK: - Structured memory (deterministic, no LLM needed)

    /// Directions explored (degrees)
    private var directionsExplored: [String] = []
    /// Objects/things seen during the session
    private var objectsSeen: Set<String> = []
    /// Obstacles encountered
    private var obstaclesEncountered: [String] = []
    /// Key user requests
    private var userRequests: [String] = []
    /// Assistant's key statements (deduplicated)
    private var keyStatements: [String] = []
    /// Exploration actions taken
    private var actionsTaken: [String] = []
    /// Current exploration summary
    private var explorationSummary: String = ""

    // MARK: - Public API

    /// Track a new conversation item
    func trackItem(id: String, serverID: String? = nil, type: TrackedItem.ItemType, summary: String) {
        let item = TrackedItem(id: id, serverID: serverID, type: type, timestamp: Date(), summary: summary)
        trackedItems.append(item)

        // Update structured memory based on item type
        switch type {
        case .functionCall(let name, let args):
            updateMemoryFromFunctionCall(name: name, args: args)
        case .functionResult(_, let output):
            updateMemoryFromResult(output: output)
        case .assistantAudio(let transcript):
            updateMemoryFromTranscript(transcript)
        case .userText:
            if !summary.hasPrefix("[") {  // skip system labels
                userRequests.append(summary.prefix(80).description)
                if userRequests.count > 5 {
                    userRequests.removeFirst()
                }
            }
        default:
            break
        }
    }

    /// Mark an item ID as already deleted from the server, so pruning won't try to delete it again
    func markDeletedFromServer(_ id: String) {
        deletedFromServer.insert(id)
    }

    /// Check if pruning is needed and return item IDs to delete + summary to inject.
    /// Returns nil if no pruning needed.
    func pruneIfNeeded() -> PruneResult? {
        guard trackedItems.count >= pruneThreshold else { return nil }

        let itemsToRemove = trackedItems.count - keepRecentItems
        guard itemsToRemove > 0 else { return nil }

        let removedItems = Array(trackedItems.prefix(itemsToRemove))
        trackedItems.removeFirst(itemsToRemove)

        // Build the IDs to delete from server (skip already-deleted and system messages)
        let idsToDelete = removedItems.compactMap { item -> String? in
            if case .systemMessage = item.type { return nil }
            if deletedFromServer.contains(item.id) {
                deletedFromServer.remove(item.id)
                return nil
            }
            return item.id
        }

        let summary = buildMemorySummary()
        memLog.info("Pruning \(idsToDelete.count) items, keeping \(self.trackedItems.count). Memory: \(summary.prefix(200))")

        return PruneResult(itemIDsToDelete: idsToDelete, memorySummary: summary)
    }

    struct PruneResult {
        let itemIDsToDelete: [String]
        let memorySummary: String
    }

    /// Build a compact memory summary from accumulated structured data
    func buildMemorySummary() -> String {
        var parts: [String] = []

        if !userRequests.isEmpty {
            parts.append("User asked: \(userRequests.suffix(3).joined(separator: "; "))")
        }

        if !actionsTaken.isEmpty {
            // Deduplicate and keep recent
            let recent = actionsTaken.suffix(8)
            parts.append("Actions: \(recent.joined(separator: " → "))")
        }

        if !objectsSeen.isEmpty {
            let sorted = objectsSeen.sorted()
            parts.append("Seen: \(sorted.joined(separator: ", "))")
        }

        if !obstaclesEncountered.isEmpty {
            // Count by type
            var counts: [String: Int] = [:]
            for obs in obstaclesEncountered {
                counts[obs, default: 0] += 1
            }
            let obsSummary = counts.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
            parts.append("Obstacles: \(obsSummary)")
        }

        if !directionsExplored.isEmpty {
            parts.append("Explored directions: \(directionsExplored.suffix(6).joined(separator: ", "))")
        }

        if !explorationSummary.isEmpty {
            parts.append(explorationSummary)
        }

        if parts.isEmpty {
            return "[Session memory] No significant events yet."
        }

        return "[Session memory — compressed context from earlier conversation]\n\(parts.joined(separator: "\n"))"
    }

    /// Reset all memory (on disconnect/reconnect)
    func reset() {
        trackedItems.removeAll()
        deletedFromServer.removeAll()
        directionsExplored.removeAll()
        objectsSeen.removeAll()
        obstaclesEncountered.removeAll()
        userRequests.removeAll()
        keyStatements.removeAll()
        actionsTaken.removeAll()
        explorationSummary = ""
    }

    // MARK: - Private: Extract structured data from events

    private func updateMemoryFromFunctionCall(name: String, args: String) {
        let parsed = parseJSON(args)

        switch name {
        case "move":
            let angle = parsed["angle"] as? Double ?? 0
            let dist = parsed["distance"] as? Double ?? 0
            let dirName = directionName(angle)
            actionsTaken.append("move \(dirName) \(Int(dist))cm")
            directionsExplored.append(dirName)

        case "turn":
            let degrees = parsed["degrees"] as? Double ?? 0
            let dir = degrees >= 0 ? "right" : "left"
            actionsTaken.append("turn \(dir) \(Int(abs(degrees)))°")
            directionsExplored.append("turn \(dir) \(Int(abs(degrees)))°")

        case "look":
            actionsTaken.append("look")

        case "head":
            let angle = parsed["angle"] as? Double ?? 0
            let repeats = parsed["repeat"] as? Int ?? 1
            if repeats > 1 {
                actionsTaken.append("nod")
            } else {
                actionsTaken.append("head \(Int(angle))°")
            }

        case "explore":
            let goal = parsed["goal"] as? String ?? "general"
            explorationSummary = "Exploring: \(goal)"

        case "stop_explore":
            let summary = parsed["summary"] as? String ?? ""
            if !summary.isEmpty {
                explorationSummary = "Exploration done: \(summary.prefix(100))"
            }

        default:
            break
        }

        // Cap action history
        if actionsTaken.count > 20 {
            actionsTaken = Array(actionsTaken.suffix(15))
        }
        if directionsExplored.count > 10 {
            directionsExplored = Array(directionsExplored.suffix(8))
        }
    }

    private func updateMemoryFromResult(output: String) {
        // Extract obstacle/sensor info
        let lower = output.lowercased()
        if lower.contains("cliff") {
            obstaclesEncountered.append("cliff")
        }
        if lower.contains("obstacle") && lower.contains("mm") {
            if let range = lower.range(of: #"obstacle.*?(\d+)mm"#, options: .regularExpression) {
                obstaclesEncountered.append(String(lower[range]))
            }
        }
    }

    private func updateMemoryFromTranscript(_ transcript: String) {
        // Extract objects mentioned by the AI from its visual descriptions
        let keywords = [
            "벽", "선반", "책", "사진", "액자", "문", "창문", "천장", "조명",
            "사람", "컵", "헤드셋", "의자", "책상", "침대", "소파", "TV",
            "커피", "식물", "시계", "컴퓨터", "모니터", "키보드",
            "wall", "shelf", "book", "photo", "frame", "door", "window",
            "person", "cup", "chair", "desk", "bed", "sofa", "plant"
        ]
        for keyword in keywords {
            if transcript.contains(keyword) {
                objectsSeen.insert(keyword)
            }
        }

        // Keep very short key statements (avoid storing full transcripts)
        if transcript.count > 10 {
            let short = String(transcript.prefix(60))
            // Only keep unique-ish statements
            if !keyStatements.contains(where: { $0.hasPrefix(String(short.prefix(20))) }) {
                keyStatements.append(short)
                if keyStatements.count > 5 {
                    keyStatements.removeFirst()
                }
            }
        }
    }

    private func directionName(_ angle: Double) -> String {
        let normalized = ((angle.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        switch normalized {
        case 0..<45, 315..<360: return "forward"
        case 45..<135: return "right"
        case 135..<225: return "backward"
        case 225..<315: return "left"
        default: return "\(Int(normalized))°"
        }
    }

    private func parseJSON(_ str: String) -> [String: Any] {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}
