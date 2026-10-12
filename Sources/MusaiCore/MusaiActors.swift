import NorvoLite

/// The actors Musai writes as. History records these names, so they are stable strings.
public enum MusaiActors {
    public static let user = Actor(kind: .user, name: "user")
    public static let curator = Actor(kind: .agent, name: "curator")
    public static func migrator(_ name: String) -> Actor {
        Actor(kind: .system, name: "migration:\(name)")
    }
}
