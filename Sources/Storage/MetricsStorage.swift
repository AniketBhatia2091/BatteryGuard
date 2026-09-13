import Foundation
import SQLite3

// MARK: - Stored Charge Session Model

/// Represents a charge session stored in SQLite.
public struct StoredChargeSession: Identifiable, Codable, Sendable {
    public var id: String { sessionId }
    public let sessionId: String
    public let startTime: Date
    public var endTime: Date?
    public var lastUpdated: Date
    public var maxPercentReached: Int
    public let chargeLimitSettingAtTime: Int?
    public var secondsSpentAtOrAboveLimit: Double
    public var secondsSpentAt100Percent: Double

    public init(
        sessionId: String = UUID().uuidString,
        startTime: Date = Date(),
        endTime: Date? = nil,
        lastUpdated: Date = Date(),
        maxPercentReached: Int,
        chargeLimitSettingAtTime: Int? = nil,
        secondsSpentAtOrAboveLimit: Double = 0,
        secondsSpentAt100Percent: Double = 0
    ) {
        self.sessionId = sessionId
        self.startTime = startTime
        self.endTime = endTime
        self.lastUpdated = lastUpdated
        self.maxPercentReached = maxPercentReached
        self.chargeLimitSettingAtTime = chargeLimitSettingAtTime
        self.secondsSpentAtOrAboveLimit = secondsSpentAtOrAboveLimit
        self.secondsSpentAt100Percent = secondsSpentAt100Percent
    }
}

// MARK: - Storage Protocols

/// Base protocol for volatile / live metric sample storage.
public protocol MetricsStorageProtocol: AnyObject, Sendable {
    func append(sample: MetricSample) async
    func getRecentSamples(limit: Int) async -> [MetricSample]
    func getSamples(for collectorId: String, limit: Int) async -> [MetricSample]
    func clear() async
}

/// Durable storage interface for charge sessions that survive app restarts.
public protocol PersistentStorageProtocol: AnyObject, Sendable {
    func startChargeSession(session: StoredChargeSession) async throws
    func updateOngoingSession(session: StoredChargeSession) async throws
    func closeChargeSession(
        sessionId: String,
        endTime: Date,
        maxPercentReached: Int,
        secondsSpentAtOrAboveLimit: Double,
        secondsSpentAt100Percent: Double
    ) async throws
    func getOngoingSession() async throws -> StoredChargeSession?
    func fetchRecentSessions(limit: Int) async throws -> [StoredChargeSession]
    func getTotalOvercharge(from startDate: Date, to endDate: Date) async throws -> Double
    func closeDatabase() async
}

// MARK: - In-Memory Storage Buffer

public actor InMemoryMetricsStorage: MetricsStorageProtocol {
    private var samples: [MetricSample] = []
    private let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public func append(sample: MetricSample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public func getRecentSamples(limit: Int = 50) -> [MetricSample] {
        return Array(samples.suffix(limit))
    }

    public func getSamples(for collectorId: String, limit: Int = 50) -> [MetricSample] {
        return Array(samples.filter { $0.collectorId == collectorId }.suffix(limit))
    }

    public func clear() {
        samples.removeAll()
    }
}

// MARK: - SQLite Persistent Store

public actor SQLiteMetricsStore: PersistentStorageProtocol {
    private var db: OpaquePointer?
    public let databasePath: String

    public init(customPath: String? = nil) {
        let resolvedPath: String
        if let path = customPath {
            resolvedPath = path
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let appDir = appSupport.appendingPathComponent("BatteryGuard", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
                resolvedPath = appDir.appendingPathComponent("batteryguard.sqlite").path
            } catch {
                // Fallback to Application Support inside container or temporary directory
                let fallbackDir = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryGuard", isDirectory: true)
                try? FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
                resolvedPath = fallbackDir.appendingPathComponent("batteryguard.sqlite").path
            }
        }
        self.databasePath = resolvedPath

        var tempDb: OpaquePointer?
        if sqlite3_open_v2(
            resolvedPath,
            &tempDb,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK {
            // Enable Write-Ahead Logging (WAL) and synchronous = NORMAL for safety and concurrency
            sqlite3_exec(tempDb, "PRAGMA journal_mode = WAL;", nil, nil, nil)
            sqlite3_exec(tempDb, "PRAGMA synchronous = NORMAL;", nil, nil, nil)

            let createTableSQL = """
            CREATE TABLE IF NOT EXISTS charge_sessions (
                session_id TEXT PRIMARY KEY,
                start_time REAL NOT NULL,
                end_time REAL,
                last_updated REAL NOT NULL,
                max_percent_reached INTEGER NOT NULL,
                charge_limit_setting_at_time INTEGER,
                seconds_spent_at_or_above_limit REAL NOT NULL DEFAULT 0,
                seconds_spent_at_100_percent REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_charge_sessions_start_time ON charge_sessions(start_time);
            CREATE INDEX IF NOT EXISTS idx_charge_sessions_end_time ON charge_sessions(end_time);
            """
            sqlite3_exec(tempDb, createTableSQL, nil, nil, nil)
        } else {
            print("[SQLiteMetricsStore] Failed to open database at \(resolvedPath)")
        }
        self.db = tempDb
    }

    public func closeDatabase() {
        guard let db = db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Session Operations

    public func startChargeSession(session: StoredChargeSession) throws {
        guard let db = db else { throw SQLiteError.databaseClosed }
        let sql = """
        INSERT INTO charge_sessions (
            session_id, start_time, end_time, last_updated,
            max_percent_reached, charge_limit_setting_at_time,
            seconds_spent_at_or_above_limit, seconds_spent_at_100_percent
        ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (session.sessionId as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, session.startTime.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, session.lastUpdated.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 4, Int32(session.maxPercentReached))
        if let limit = session.chargeLimitSettingAtTime {
            sqlite3_bind_int(stmt, 5, Int32(limit))
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_bind_double(stmt, 6, session.secondsSpentAtOrAboveLimit)
        sqlite3_bind_double(stmt, 7, session.secondsSpentAt100Percent)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError.executionFailed(lastErrorMessage())
        }
    }

    public func updateOngoingSession(session: StoredChargeSession) throws {
        guard let db = db else { throw SQLiteError.databaseClosed }
        let sql = """
        UPDATE charge_sessions SET
            last_updated = ?,
            max_percent_reached = ?,
            seconds_spent_at_or_above_limit = ?,
            seconds_spent_at_100_percent = ?
        WHERE session_id = ? AND end_time IS NULL;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, session.lastUpdated.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 2, Int32(session.maxPercentReached))
        sqlite3_bind_double(stmt, 3, session.secondsSpentAtOrAboveLimit)
        sqlite3_bind_double(stmt, 4, session.secondsSpentAt100Percent)
        sqlite3_bind_text(stmt, 5, (session.sessionId as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError.executionFailed(lastErrorMessage())
        }
    }

    public func closeChargeSession(
        sessionId: String,
        endTime: Date,
        maxPercentReached: Int,
        secondsSpentAtOrAboveLimit: Double,
        secondsSpentAt100Percent: Double
    ) throws {
        guard let db = db else { throw SQLiteError.databaseClosed }
        let sql = """
        UPDATE charge_sessions SET
            end_time = ?,
            last_updated = ?,
            max_percent_reached = ?,
            seconds_spent_at_or_above_limit = ?,
            seconds_spent_at_100_percent = ?
        WHERE session_id = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970
        sqlite3_bind_double(stmt, 1, endTime.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, now)
        sqlite3_bind_int(stmt, 3, Int32(maxPercentReached))
        sqlite3_bind_double(stmt, 4, secondsSpentAtOrAboveLimit)
        sqlite3_bind_double(stmt, 5, secondsSpentAt100Percent)
        sqlite3_bind_text(stmt, 6, (sessionId as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError.executionFailed(lastErrorMessage())
        }
    }

    public func getOngoingSession() throws -> StoredChargeSession? {
        guard let db = db else { throw SQLiteError.databaseClosed }
        let sql = """
        SELECT
            session_id, start_time, end_time, last_updated,
            max_percent_reached, charge_limit_setting_at_time,
            seconds_spent_at_or_above_limit, seconds_spent_at_100_percent
        FROM charge_sessions
        WHERE end_time IS NULL
        ORDER BY start_time DESC
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return parseSessionRow(stmt: stmt)
        }
        return nil
    }

    public func fetchRecentSessions(limit: Int = 20) throws -> [StoredChargeSession] {
        guard let db = db else { throw SQLiteError.databaseClosed }
        let sql = """
        SELECT
            session_id, start_time, end_time, last_updated,
            max_percent_reached, charge_limit_setting_at_time,
            seconds_spent_at_or_above_limit, seconds_spent_at_100_percent
        FROM charge_sessions
        ORDER BY start_time DESC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [StoredChargeSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(parseSessionRow(stmt: stmt))
        }
        return results
    }

    /// Aggregate total overcharge time (seconds_spent_at_or_above_limit) between two dates.
    /// MVP boundary: Bucketed by session start_time.
    public func getTotalOvercharge(from startDate: Date, to endDate: Date) throws -> Double {
        guard let db = db else { throw SQLiteError.databaseClosed }
        let sql = """
        SELECT COALESCE(SUM(seconds_spent_at_or_above_limit), 0.0)
        FROM charge_sessions
        WHERE start_time >= ? AND start_time < ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, startDate.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, endDate.timeIntervalSince1970)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return 0.0
    }

    private func parseSessionRow(stmt: OpaquePointer?) -> StoredChargeSession {
        let sid = String(cString: sqlite3_column_text(stmt, 0))
        let startTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))

        var endTime: Date? = nil
        if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
            endTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        }

        let lastUpdated = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let maxPercent = Int(sqlite3_column_int(stmt, 4))

        var limit: Int? = nil
        if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
            limit = Int(sqlite3_column_int(stmt, 5))
        }

        let overcharge = sqlite3_column_double(stmt, 6)
        let full = sqlite3_column_double(stmt, 7)

        return StoredChargeSession(
            sessionId: sid,
            startTime: startTime,
            endTime: endTime,
            lastUpdated: lastUpdated,
            maxPercentReached: maxPercent,
            chargeLimitSettingAtTime: limit,
            secondsSpentAtOrAboveLimit: overcharge,
            secondsSpentAt100Percent: full
        )
    }

    private func lastErrorMessage() -> String {
        guard let db = db else { return "Database closed" }
        return String(cString: sqlite3_errmsg(db))
    }
}

public enum SQLiteError: LocalizedError {
    case databaseClosed
    case prepareFailed(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseClosed: return "Database is closed"
        case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
        case .executionFailed(let msg): return "SQLite execution failed: \(msg)"
        }
    }
}
