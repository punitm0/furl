import Foundation

/// Kinds of leftover processes that auto-stop (and Auto-Sweep) never touch, however long they've
/// been orphaned. Stopping them can lose data or cut a connection someone relies on. The user can
/// still stop them by hand from Processes & Sessions.
enum AutoStopExemption: String, Sendable, Hashable {
    case database
    case multiplexer
    case tunnel
}

enum AutoStopPolicy {
    /// Database and data-store servers, by executable name (lowercased).
    static let databaseExecutables: Set<String> = [
        "postgres", "postmaster", "pg_ctl", "mysqld", "mysqld_safe", "mariadbd", "mariadbd-safe",
        "mongod", "mongos", "redis-server", "redis-sentinel", "valkey-server", "keydb-server",
        "dragonfly", "memcached", "cockroach", "etcd", "clickhouse", "clickhouse-server", "influxd",
        "couchdb", "rethinkdb", "arangod", "surreal", "minio", "meilisearch", "typesense-server",
        "qdrant", "neo4j", "cassandra", "elasticsearch", "opensearch", "nats-server", "rabbitmq-server",
        "kafka-server-start", "zookeeper-server-start", "foundationdb", "fdbserver", "tidb-server",
        "dynamodb-local", "sqld", "turso"
    ]

    /// JVM / BEAM / script-hosted data stores, matched in the arguments (lowercased).
    static let databaseArgumentMarkers: [String] = [
        "org.elasticsearch.", "org.opensearch.", "org.apache.cassandra.", "kafka.kafka",
        "org.apache.zookeeper.", "org.neo4j.", "dynamodblocal", "rabbit_", "couchdb", "-s rabbit"
    ]

    /// Terminal multiplexers and detachers: killing one kills every shell inside it.
    static let multiplexerExecutables: Set<String> = [
        "tmux", "screen", "zellij", "abduco", "dtach", "byobu", "mosh-server"
    ]

    /// Tunnels and VPN-like connectors, by executable name (lowercased).
    static let tunnelExecutables: Set<String> = [
        "ngrok", "cloudflared", "tailscale", "tailscaled", "autossh", "sshuttle", "frpc", "bore",
        "chisel", "wstunnel", "inlets", "zrok", "localtunnel", "lt", "pinggy", "expose", "telebit"
    ]

    /// Tunnels started through another tool (lowercased argument fragments).
    static let tunnelArgumentMarkers: [String] = [
        "port-forward", "fly proxy", "flyctl proxy", "localtunnel", "ssm start-session",
        "iap-tunnel", "start-iap-tunnel"
    ]

    /// Why this process tree must not be auto-stopped, or nil when auto-stop may stop it.
    /// Any member of the tree counts: a dev script that started postgres keeps postgres safe.
    static func exemption(for processes: [ProcInfo]) -> AutoStopExemption? {
        for process in processes {
            if let reason = exemption(executable: process.executableName, name: process.name, args: process.args) {
                return reason
            }
        }
        return nil
    }

    static func exemption(executable: String, name: String, args: [String]) -> AutoStopExemption? {
        let exe = executable.lowercased()
        let kernelName = name.lowercased()
        let joined = args.joined(separator: " ").lowercased()

        if databaseExecutables.contains(exe) || databaseExecutables.contains(kernelName)
            || databaseArgumentMarkers.contains(where: { joined.contains($0) }) {
            return .database
        }
        if multiplexerExecutables.contains(exe) || multiplexerExecutables.contains(kernelName) {
            return .multiplexer
        }
        if tunnelExecutables.contains(exe) || tunnelExecutables.contains(kernelName)
            || tunnelArgumentMarkers.contains(where: { joined.contains($0) }) {
            return .tunnel
        }
        if (exe == "ssh" || kernelName == "ssh"), isForwardingSSH(Array(args.dropFirst())) {
            return .tunnel
        }
        return nil
    }

    /// ssh with -L, -R, -D or -w (also bundled like `-fNL`, or as `-o LocalForward=…`).
    /// Case matters: `-l` is the login name, not a forward.
    static func isForwardingSSH(_ args: [String]) -> Bool {
        // ssh options that take a value; the rest of a bundle after one of these is that value.
        let takesValue = Set("BbcDEeFIiJLlmOoPpQRSWw")
        let forwards = Set("LRDw")
        var expectValueFor: Character?
        for arg in args {
            if let option = expectValueFor {
                expectValueFor = nil
                if option == "o", isForwardOption(arg) { return true }
                continue
            }
            if arg == "--" { break }
            guard arg.hasPrefix("-"), arg.count > 1 else { continue }
            var rest = Substring(arg.dropFirst())
            while let flag = rest.first {
                rest = rest.dropFirst()
                if forwards.contains(flag) { return true }
                if takesValue.contains(flag) {
                    if rest.isEmpty {
                        expectValueFor = flag
                    } else if flag == "o", isForwardOption(String(rest)) {
                        return true
                    }
                    break
                }
            }
        }
        return false
    }

    private static func isForwardOption(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("localforward") || lower.hasPrefix("remoteforward")
            || lower.hasPrefix("dynamicforward") || lower.hasPrefix("tunnel")
    }
}
