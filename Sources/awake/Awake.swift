import Foundation

@main
enum Awake {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            // From a terminal, explain; from launchd or Finder, run the menu bar app.
            if isatty(STDIN_FILENO) != 0 {
                print(Commands.usage)
                exit(0)
            }
            MainActor.assumeIsolated { MenuApp.start() }
        }
        switch command {
        case "hook":
            Hook.run(agent: args.count > 1 ? args[1] : "")
            exit(0)
        case "run":
            exit(Commands.run(Array(args.dropFirst())))
        case "for":
            exit(Commands.hold(args.count > 1 ? args[1] : nil))
        case "stop":
            exit(Commands.stop())
        case "set":
            exit(Commands.set(args.count > 1 ? args[1] : nil))
        case "status":
            exit(Commands.status())
        case "reconcile":
            Reconcile.run()
            exit(0)
        case "help", "-h", "--help":
            print(Commands.usage)
            exit(0)
        default:
            FileHandle.standardError.write(Data((Commands.usage + "\n").utf8))
            exit(64)
        }
    }
}
