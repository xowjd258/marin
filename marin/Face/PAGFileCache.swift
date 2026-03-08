import Foundation
import os

private let pagLog = Logger(subsystem: "marin", category: "PAGFileCache")

/// Downloads and caches PAG animation files from the LOOI resource server.
final class PAGFileCache {
    static let shared = PAGFileCache()

    private let baseURL = "https://looi-resouce.tangiblefuturelab.com/pag/"
    private let cacheDir: URL
    private let session: URLSession
    private var inFlightTasks: [String: Task<URL?, Never>] = [:]

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheDir = docs.appendingPathComponent("PAGCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        session = URLSession(configuration: .default)
    }

    /// Returns local file URL if cached, nil otherwise.
    func cachedFileURL(for code: String) -> URL? {
        let fileURL = cacheDir.appendingPathComponent("\(code).pag")
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Returns local file URL, downloading if needed.
    func fileURL(for code: String) async -> URL? {
        if let cached = cachedFileURL(for: code) {
            return cached
        }

        // Deduplicate in-flight downloads
        if let existing = inFlightTasks[code] {
            return await existing.value
        }

        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.download(code: code)
        }
        inFlightTasks[code] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: code)
        return result
    }

    private func download(code: String) async -> URL? {
        let urlString = "\(baseURL)\(code).pag"
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  !data.isEmpty else {
                pagLog.warning("PAG download failed for \(code): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            let fileURL = cacheDir.appendingPathComponent("\(code).pag")
            try data.write(to: fileURL, options: .atomic)
            pagLog.info("PAG cached: \(code) (\(data.count) bytes)")
            return fileURL
        } catch {
            pagLog.error("PAG download error for \(code): \(error.localizedDescription)")
            return nil
        }
    }

    /// Preload a set of PAG codes.
    func preload(codes: [String]) {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for code in codes {
                    group.addTask { [weak self] in
                        _ = await self?.fileURL(for: code)
                    }
                }
            }
        }
    }
}
