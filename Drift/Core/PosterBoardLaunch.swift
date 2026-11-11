import Foundation
import UIKit

/// Best-effort launch of PosterBoard by bundle id, used to give the user
/// something to close from the app switcher after a local write or delete.
/// Returns true when the launch call was accepted.
enum PosterBoardLaunch {
    @MainActor
    static func open() -> Bool {
        guard let cls = NSClassFromString("LSApplicationWorkspace") else { return false }
        let selDefault = NSSelectorFromString("defaultWorkspace")
        guard cls.responds(to: selDefault) else { return false }
        // `perform` on an AnyClass does not type-check; fetch the workspace
        // through its IMP, the same pattern as the open call below.
        typealias DefaultWorkspaceFn = @convention(c) (AnyObject, Selector) -> AnyObject
        let workspaceImp = (cls as AnyObject).method(for: selDefault)
        let workspaceFn = unsafeBitCast(workspaceImp, to: DefaultWorkspaceFn.self)
        let workspace = workspaceFn(cls as AnyObject, selDefault)
        let selOpen = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: selOpen) else { return false }
        typealias OpenFn = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let imp = workspace.method(for: selOpen)
        let fn = unsafeBitCast(imp, to: OpenFn.self)
        return fn(workspace, selOpen, "com.apple.PosterBoard" as NSString)
    }
}