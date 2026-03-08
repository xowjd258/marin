import Foundation

enum RealtimeParsedEvent {
    case sessionCreated(model: String?)
    case sessionUpdated
    case textDelta(String)
    case textDone(String)
    case transcriptDelta(String)
    case transcriptDone(String)
    case audioDelta(Data, responseID: String?)
    case audioDone(responseID: String?)
    case outputItemAdded(itemID: String, type: String, name: String?, callID: String?)
    case functionCallDelta(callID: String, name: String?, delta: String)
    case functionCallDone(callID: String, name: String?, arguments: String)
    case speechStarted
    case speechStopped
    case responseCreated
    case responseDone
    case error(String)
    case responseFailed(String)
    case unknown(String)
}

enum RealtimeEventParser {
    static func parse(text: String) -> RealtimeParsedEvent {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return .unknown("invalid_json")
        }

        if type == "session.created" {
            let session = obj["session"] as? [String: Any]
            let model = session?["model"] as? String
            return .sessionCreated(model: model)
        }

        if type == "session.updated" {
            return .sessionUpdated
        }

        if type == "response.output_text.delta" {
            return .textDelta((obj["delta"] as? String) ?? "")
        }

        if type == "response.output_text.done" {
            return .textDone((obj["text"] as? String) ?? "")
        }

        if type == "response.audio.delta" || type == "response.output_audio.delta" {
            let encoded = (obj["delta"] as? String) ?? ""
            let data = Data(base64Encoded: encoded) ?? Data()
            return .audioDelta(data, responseID: obj["response_id"] as? String)
        }

        if type == "response.audio.done" || type == "response.output_audio.done" {
            return .audioDone(responseID: obj["response_id"] as? String)
        }

        if type == "response.output_audio_transcript.delta" {
            return .transcriptDelta((obj["delta"] as? String) ?? "")
        }

        if type == "response.output_audio_transcript.done" {
            return .transcriptDone((obj["transcript"] as? String) ?? "")
        }

        if type == "input_audio_buffer.speech_started" {
            return .speechStarted
        }

        if type == "input_audio_buffer.speech_stopped" {
            return .speechStopped
        }

        if type == "response.output_item.added" {
            let item = obj["item"] as? [String: Any]
            let itemID = item?["id"] as? String ?? ""
            let itemType = item?["type"] as? String ?? ""
            let name = item?["name"] as? String
            let callID = item?["call_id"] as? String
            return .outputItemAdded(itemID: itemID, type: itemType, name: name, callID: callID)
        }

        if type == "response.function_call_arguments.delta" {
            let callID = obj["call_id"] as? String ?? ""
            let name = obj["name"] as? String
            let delta = obj["delta"] as? String ?? ""
            return .functionCallDelta(callID: callID, name: name, delta: delta)
        }

        if type == "response.function_call_arguments.done" {
            let callID = obj["call_id"] as? String ?? ""
            let name = obj["name"] as? String
            let arguments = obj["arguments"] as? String ?? "{}"
            return .functionCallDone(callID: callID, name: name, arguments: arguments)
        }

        if type == "response.created" {
            return .responseCreated
        }

        if type == "response.done" {
            if let response = obj["response"] as? [String: Any],
               let status = response["status"] as? String,
               status == "failed" {
                if let details = response["status_details"] as? [String: Any],
                   let error = details["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return .responseFailed(message)
                }
                return .responseFailed("response failed")
            }
            return .responseDone
        }

        if type == "error" {
            if let error = obj["error"] as? [String: Any],
               let message = error["message"] as? String {
                let code = error["code"] as? String
                if let code, !code.isEmpty {
                    return .error("\(code): \(message)")
                }
                return .error(message)
            }
            return .error("unknown realtime error")
        }

        return .unknown(type)
    }
}
