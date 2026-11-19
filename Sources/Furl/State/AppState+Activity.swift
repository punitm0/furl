import Foundation

extension AppState {
    /// After items come back from the Trash, bring the sections they came from back in sync.
    func rescanAfterRestore(sections: [SidebarSection]) async {
        var seen = Set<SidebarSection>()
        for section in sections where seen.insert(section).inserted {
            switch section {
            case .junk: await scanJunk()
            case .apps: await scanApps()
            case .largeFiles: await scanLargeFiles()
            case .duplicates: await scanDuplicates()
            case .smartReview: await scanSmartReview()
            case .spaceMap: markSpaceMapStale()
            case .dashboard, .worktrees, .processes, .compress, .snapshots, .activity, .find: break
            }
        }
    }
}
