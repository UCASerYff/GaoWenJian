// Organizer module port; source application is not a runtime dependency.
import Foundation
import CoreServices

/// FSEvents is a coalesced hint, never the source of truth. Every hint requests a safe metadata rescan.
/// The owner schedules scans on its worker task and may leave slow/removable/network roots paused.
final class OFIndexMonitor: @unchecked Sendable {
    private let store: OFIndexStore
    private let queue = DispatchQueue(label:"com.gaoseries.GaoWenJian.organizer.fsevents",qos:.utility)
    private let lock = NSRecursiveLock()
    private var watchers: [UUID:OFRootEventWatcher] = [:]
    private let onChange: @Sendable (UUID) -> Void
    init(store:OFIndexStore,onChange:@escaping @Sendable (UUID)->Void) {self.store = store; self.onChange = onChange}
    /// Rebuild watchers after roots or pause state change. Existing checkpoints are persisted in SQLite.
    func start() throws {
        stop()
        var failures: [String] = []
        for root in try store.roots() where !root.isPaused && root.status != "needsAuthorization" {
            do {
                let lease = try store.accessLease(rootID:root.id)
                let watcher = OFRootEventWatcher(root:root,lease:lease,store:store,queue:queue,onChange:onChange)
                try watcher.start()
                lock.lock(); watchers[root.id] = watcher; lock.unlock()
            } catch { failures.append("\(root.displayName)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw OFIndexError.unavailable(failures.joined(separator:"\n")) }
    }
    func stop() {
        lock.lock(); let previous = watchers; watchers = [:]; lock.unlock()
        previous.values.forEach {$0.stop()}
    }
    deinit {stop()}
}

private final class OFRootEventWatcher: @unchecked Sendable {
    private let root:OFIndexRoot
    private let lease:OFIndexAccessLease
    private let store:OFIndexStore
    private let queue:DispatchQueue
    private let onChange:@Sendable (UUID)->Void
    private var stream:FSEventStreamRef?
    private let lock = NSRecursiveLock()
    private var pending:DispatchWorkItem?
    private var newestID:UInt64 = 0
    private var fullScan = false
    private var diagnostics:Set<String> = []
    private var stopped = false
    init(root:OFIndexRoot,lease:OFIndexAccessLease,store:OFIndexStore,queue:DispatchQueue,onChange:@escaping @Sendable (UUID)->Void) {
        self.root = root; self.lease = lease; self.store = store; self.queue = queue; self.onChange = onChange
    }
    func start() throws {
        var context = FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:{ pointer in
            guard let pointer else {return nil}
            _ = Unmanaged<OFRootEventWatcher>.fromOpaque(pointer).retain()
            return UnsafeRawPointer(pointer)
        },release:{ pointer in
            if let pointer {Unmanaged<OFRootEventWatcher>.fromOpaque(pointer).release()}
        },copyDescription:nil)
        let since = root.lastEventID == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow):root.lastEventID
        let callback:FSEventStreamCallback = { _,context,count,_,flags,ids in
            guard let context else {return}
            let watcher = Unmanaged<OFRootEventWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.receive(count:count,flags:flags,ids:ids)
        }
        guard let created = FSEventStreamCreate(kCFAllocatorDefault,callback,&context,[lease.url.path] as CFArray,since,1.0,FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)) else {
            throw OFIndexError.unavailable("无法创建文件变更监听")
        }
        lock.lock(); stream = created; lock.unlock()
        FSEventStreamSetDispatchQueue(created,queue)
        guard FSEventStreamStart(created) else {stop(); throw OFIndexError.permission("文件变更监听未启动，可手动扫描")}
    }
    private func receive(count:Int,flags:UnsafePointer<FSEventStreamEventFlags>,ids:UnsafePointer<FSEventStreamEventId>) {
        lock.lock(); defer {lock.unlock()}
        guard !stopped else {return}
        for i in 0..<count {
            newestID = max(newestID,ids[i])
            let flag = flags[i]
            let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
            if flag & lost != 0 {fullScan = true; diagnostics.insert("事件丢失或合并，需要完整补扫")}
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {fullScan = true; diagnostics.insert("根目录已移动或失效，先核对书签身份")}
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount) != 0 {fullScan = true; diagnostics.insert("卷已卸载；等待重新连接并核对身份")}
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMount) != 0 {fullScan = true; diagnostics.insert("卷连接发生变化，需要完整补扫")}
        }
        pending?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.deliver() }
        pending = job
        queue.asyncAfter(deadline:.now()+1.2,execute:job)
    }
    private func deliver() {
        lock.lock()
        guard !stopped else {lock.unlock(); return}
        let id = newestID, full = fullScan, message = diagnostics.sorted().joined(separator:"；")
        pending = nil; fullScan = false; diagnostics = []
        lock.unlock()
        do {
            try store.updateEvent(rootID:root.id,eventID:id,requiresFullScan:full,diagnostic:message.isEmpty ? nil:message)
            onChange(root.id)
        } catch {
            // The authoritative database remains intact; surface the root to let the UI refresh its error state.
            onChange(root.id)
        }
    }
    func stop() {
        lock.lock()
        guard !stopped else {lock.unlock();return}
        stopped = true; pending?.cancel(); pending = nil
        let old = stream; stream = nil
        lock.unlock()
        if let old {FSEventStreamStop(old);FSEventStreamInvalidate(old);FSEventStreamRelease(old)}
        lease.release()
    }
    deinit {stop()}
}
