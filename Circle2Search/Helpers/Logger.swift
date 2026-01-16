// Logger.swift
// Simple structured logging utility for Circle2Search

import Foundation
import os.log

/// Logging levels for controlling verbosity
enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// Simple structured logger with level-based filtering
final class Logger {
    static let shared = Logger()
    
    /// Current minimum log level. Messages below this level are ignored.
    #if DEBUG
    var minimumLevel: LogLevel = .debug
    #else
    var minimumLevel: LogLevel = .info
    #endif
    
    private let osLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "Circle2Search", category: "app")
    
    private init() {}
    
    // MARK: - Logging Methods
    
    func debug(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .debug, message: message(), file: file, function: function, line: line)
    }
    
    func info(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .info, message: message(), file: file, function: function, line: line)
    }
    
    func warning(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .warning, message: message(), file: file, function: function, line: line)
    }
    
    func error(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .error, message: message(), file: file, function: function, line: line)
    }
    
    // MARK: - Private
    
    private func log(level: LogLevel, message: String, file: String, function: String, line: Int) {
        guard level >= minimumLevel else { return }
        
        let fileName = (file as NSString).lastPathComponent
        let prefix: String
        switch level {
        case .debug:   prefix = "🔍"
        case .info:    prefix = "ℹ️"
        case .warning: prefix = "⚠️"
        case .error:   prefix = "❌"
        }
        
        let formattedMessage = "\(prefix) [\(fileName):\(line)] \(function) - \(message)"
        
        #if DEBUG
        print(formattedMessage)
        #endif
        
        // Also log to unified logging system
        let osLogType: OSLogType
        switch level {
        case .debug:   osLogType = .debug
        case .info:    osLogType = .info
        case .warning: osLogType = .default
        case .error:   osLogType = .error
        }
        os_log("%{public}@", log: osLog, type: osLogType, formattedMessage)
    }
}

// MARK: - Convenience Global Functions

/// Global logger instance for convenience
let log = Logger.shared
