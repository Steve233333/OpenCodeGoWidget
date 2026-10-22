import Foundation

var keyDirectoryFailures: [String] = []

func keyDirectoryCheck(_ condition: Bool, _ name: String) {
    if condition {
        print("  ✅ \(name)")
    } else {
        print("  ❌ \(name)")
        keyDirectoryFailures.append(name)
    }
}

func directoryKey(_ id: String, _ name: String) -> ApiKeyInfo {
    ApiKeyInfo(id: id, displayName: name)
}

func testKeyDirectoryReducer() {
    print("— Key 目录状态机 —")
    let now = Date(timeIntervalSince1970: 1_792_666_000)
    let old = KeyDirectoryState(
        status: .live,
        keys: [directoryKey("legacy-temp", "Legacy - 临时")],
        checkedAt: now.addingTimeInterval(-300),
        sessionFingerprint: "same-session",
        detail: nil
    )
    let fresh = ConsoleKeyList(
        keys: [directoryKey("new-fang", "方泽恩 - 方泽恩"),
               directoryKey("new-ding", "方泽恩 - 丁雁")],
        skipped: 7
    )

    let live = KeyDirectoryReducer.reduce(
        .fetched(fresh), previous: old, sessionFingerprint: "same-session", now: now
    )
    keyDirectoryCheck(live.status == .live, "200 + 2 把 active → live")
    keyDirectoryCheck(live.usableKeys.map(\.id) == ["new-fang", "new-ding"],
                      "新列表整体替换旧缓存，不追加 Legacy")
    keyDirectoryCheck(live.detail?.contains("7") == true, "记录跳过 7 把吊销/过期 Key")

    let expired = KeyDirectoryReducer.reduce(
        .loginRequired("401"), previous: live, sessionFingerprint: "same-session", now: now
    )
    keyDirectoryCheck(expired.status == .loginRequired, "401/403 → loginRequired")
    keyDirectoryCheck(expired.usableKeys.isEmpty, "登录失效立即撤下全部旧 Key")

    let noKeys = KeyDirectoryReducer.reduce(
        .fetched(ConsoleKeyList(keys: [], skipped: 0)),
        previous: live,
        sessionFingerprint: "same-session",
        now: now
    )
    keyDirectoryCheck(noKeys.status == .noActiveKeys, "200 但零 active → noActiveKeys")
    keyDirectoryCheck(noKeys.usableKeys.isEmpty, "零 active 不沿用旧列表")

    let transientSameSession = KeyDirectoryReducer.reduce(
        .temporaryFailure("503"), previous: live, sessionFingerprint: "same-session", now: now
    )
    keyDirectoryCheck(transientSameSession.status == .temporaryFailure,
                      "503/超时 → temporaryFailure")
    keyDirectoryCheck(transientSameSession.usableKeys.count == 2,
                      "同会话临时故障保留上次已验证列表")

    let transientChangedSession = KeyDirectoryReducer.reduce(
        .temporaryFailure("timeout"), previous: live, sessionFingerprint: "new-session", now: now
    )
    keyDirectoryCheck(transientChangedSession.usableKeys.isEmpty,
                      "会话变化后的临时故障不得显示旧账号 Key")

    keyDirectoryCheck(KeyDirectoryStore.selectedKeyIsAvailable("new-fang", in: live),
                      "仍有效的已选 Key 保留")
    keyDirectoryCheck(!KeyDirectoryStore.selectedKeyIsAvailable("legacy-temp", in: live),
                      "已吊销/已移除的已选 Key 会被清除")
}

func testKeyDirectoryEncodingAndFingerprint() {
    print("— Key 目录持久化 —")
    let state = KeyDirectoryState(
        status: .temporaryFailure,
        keys: [directoryKey("k1", "方泽恩 - 测试")],
        checkedAt: Date(timeIntervalSince1970: 1_792_666_000),
        sessionFingerprint: KeyDirectoryStore.fingerprint(
            workspaceID: "wrk_1", auth: "", session: "st_1"
        ),
        detail: "timeout"
    )
    let decoded = (try? JSONDecoder().decode(
        KeyDirectoryState.self,
        from: JSONEncoder().encode(state)
    ))
    keyDirectoryCheck(decoded == state, "状态可无损编码/解码")

    let a = KeyDirectoryStore.fingerprint(workspaceID: "wrk_1", auth: "a", session: "st_1")
    let same = KeyDirectoryStore.fingerprint(workspaceID: "wrk_1", auth: "a", session: "st_1")
    let changed = KeyDirectoryStore.fingerprint(workspaceID: "wrk_1", auth: "a", session: "st_2")
    keyDirectoryCheck(a == same && a != changed, "会话指纹稳定且能识别变化")
    keyDirectoryCheck(a.count == 64, "指纹是 SHA256，不包含原始凭据")
}

@main
struct KeyDirectoryStateTestRunner {
    static func main() {
        testKeyDirectoryReducer()
        testKeyDirectoryEncodingAndFingerprint()
        print("")
        if keyDirectoryFailures.isEmpty {
            print("✅ Key 目录状态机全部通过")
        } else {
            print("❌ 失败 \(keyDirectoryFailures.count) 项：")
            for failure in keyDirectoryFailures { print("   - \(failure)") }
            exit(1)
        }
    }
}
