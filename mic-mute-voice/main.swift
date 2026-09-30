// MicMuteVoice：用麦克风自带的静音键开关语音输入法（默认按豆包输入法的右 Option 设计）。
// 原理：很多 USB 麦克风静音时传给电脑的是纯 0 数据；检测到"静音 ↔ 取消静音"的切换，就替用户按一下快捷键。
import Foundation
import AVFoundation
import CoreAudio
import CoreGraphics
import ApplicationServices
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configPath = "\(home)/.config/mic-mute-voice/config.json"
let logPath = "\(home)/Library/Logs/MicMuteVoice.log"

// ---------- 日志 ----------
let logHandle: FileHandle = {
  if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
  let h = FileHandle(forWritingAtPath: logPath)!; h.seekToEndOfFile(); return h
}()
let tsFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
func log(_ s: String) { logHandle.write("\(tsFmt.string(from: Date())) \(s)\n".data(using: .utf8)!) }

// ---------- 配置（改配置不用重新编译，重启程序即可） ----------
struct Config {
  var devicePrefix = "UGREEN MIC-CM770"
  var zeroRunSeconds = 0.3          // 连续多久全是 0 才算"静音"
  var unmuteMinNonzero = 20         // 一段音频里至少多少个非 0 采样才算"取消静音"
  var warmupSeconds = 1.0           // 刚开始采集时忽略的时长（启动时常有一段 0）
  var tapEnabled = false            // false = 只记录不按键
  var toggleKey = "right_option"    // 语音输入法的开关键：right_option / right_command / right_control / right_shift
  var imeBundleIDs = ["com.bytedance.inputmethod.doubaoime"]  // 语音输入法的进程，用来判断它是不是正在听
  var meetingBundleIDs = ["com.tencent.meeting", "com.electron.lark", "5ZSL2CJU2T.com.dingtalk.mac", "com.tencent.WeWorkMac", "com.tencent.xinWeChat"]
}
func loadConfig() -> Config {
  var c = Config()
  guard let d = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
        let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { log("未读到 \(configPath)，用默认配置"); return c }
  if let v = j["devicePrefix"] as? String { c.devicePrefix = v }
  if let v = j["zeroRunSeconds"] as? Double { c.zeroRunSeconds = v }
  if let v = j["unmuteMinNonzero"] as? Int { c.unmuteMinNonzero = v }
  if let v = j["warmupSeconds"] as? Double { c.warmupSeconds = v }
  if let v = j["tapEnabled"] as? Bool { c.tapEnabled = v }
  if let v = j["toggleKey"] as? String { c.toggleKey = v }
  if let v = j["imeBundleIDs"] as? [String] { c.imeBundleIDs = v }
  if let v = j["meetingBundleIDs"] as? [String] { c.meetingBundleIDs = v }
  return c
}
let cfg = loadConfig()

// ---------- 谁在用麦克风（CoreAudio 进程列表） ----------
func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
  var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var v = initial; var size = UInt32(MemoryLayout<T>.size)
  return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
}
func appsCapturingInput() -> [String] {
  var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
  var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
  let myPID = ProcessInfo.processInfo.processIdentifier
  var out: [String] = []
  for id in ids {
    guard let running: UInt32 = prop(id, kAudioProcessPropertyIsRunningInput, 0), running != 0 else { continue }
    let pid: pid_t = prop(id, kAudioProcessPropertyPID, 0) ?? 0
    if pid == myPID { continue }
    var bundle = ""
    if let cf: Unmanaged<CFString>? = prop(id, kAudioProcessPropertyBundleID, nil), let s = cf?.takeRetainedValue() { bundle = s as String }
    if bundle.isEmpty { bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid:\(pid)" }
    out.append(bundle)
  }
  return out
}

// ---------- 模拟按一下开关键（只按一下修饰键，不带其他键） ----------
// 键码 + 左右区分标志位（IOKit NX_DEVICE*KEYMASK）+ 通用修饰键标志
let modifierKeys: [String: (code: CGKeyCode, device: UInt64, flag: CGEventFlags)] = [
  "right_option":  (61, 0x40,   .maskAlternate),
  "right_command": (54, 0x10,   .maskCommand),
  "right_control": (62, 0x2000, .maskControl),
  "right_shift":   (60, 0x04,   .maskShift),
]
func tapToggleKey() {
  guard let k = modifierKeys[cfg.toggleKey] else { log("不支持的 toggleKey：\(cfg.toggleKey)"); return }
  let src = CGEventSource(stateID: .hidSystemState)
  guard let down = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: true),
        let up = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: false) else { return }
  down.type = .flagsChanged; down.flags = CGEventFlags(rawValue: k.flag.rawValue | k.device | 0x100)
  up.type = .flagsChanged;   up.flags = CGEventFlags(rawValue: 0x100)
  down.post(tap: .cghidEventTap); usleep(60_000); up.post(tap: .cghidEventTap)
}

// ---------- 静音检测 ----------
enum MicState: String { case muted = "静音", live = "未静音" }

final class Detector: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  let queue = DispatchQueue(label: "mic-mute-voice.audio")
  var session: AVCaptureSession?
  var deviceName = ""
  var startedAt = Date()
  var lastBufferAt = Date.distantPast
  var zeroRun = 0
  var state: MicState?
  var lastActionAt = Date.distantPast

  func findDevice() -> AVCaptureDevice? {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
      .devices.first { $0.localizedName.hasPrefix(cfg.devicePrefix) }
  }

  func start() {
    guard session == nil, let dev = findDevice() else { return }
    let s = AVCaptureSession()
    guard let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input) else { log("打不开设备 \(dev.localizedName)"); return }
    s.addInput(input)
    let out = AVCaptureAudioDataOutput()
    out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                         AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1]
    out.setSampleBufferDelegate(self, queue: queue)
    guard s.canAddOutput(out) else { log("无法添加音频输出"); return }
    s.addOutput(out)
    queue.sync { zeroRun = 0; state = nil; startedAt = Date(); lastBufferAt = Date() }
    s.startRunning()
    session = s; deviceName = dev.localizedName
    log("开始监听：\(dev.localizedName)")
  }

  func stop(_ why: String) {
    guard let s = session else { return }
    s.stopRunning(); session = nil
    queue.sync { state = nil }
    log("停止监听（\(why)）")
  }

  // 每 2 秒检查：设备没在听就尝试接上；在听但 2 秒没收到音频（接收器拔了/断连）就重启
  func watchdog() {
    if session == nil { start(); return }
    let silentFor = queue.sync { Date().timeIntervalSince(lastBufferAt) }
    if silentFor > 2 || findDevice() == nil { stop("设备断开或没有音频数据"); start() }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
    lastBufferAt = Date()
    guard let fmt = CMSampleBufferGetFormatDescription(sb),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
    var abl = AudioBufferList(); var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &block) == noErr, let data = abl.mBuffers.mData else { return }
    let n = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
    let p = data.bindMemory(to: Float.self, capacity: n)
    var nonzero = 0
    for i in 0..<n { if p[i] == 0 { zeroRun += 1 } else { zeroRun = 0; nonzero += 1 } }

    if Date().timeIntervalSince(startedAt) < cfg.warmupSeconds { zeroRun = 0; return }
    var observed: MicState?
    if zeroRun >= Int(cfg.zeroRunSeconds * asbd.mSampleRate) { observed = .muted }
    else if nonzero >= cfg.unmuteMinNonzero { observed = .live }
    guard let obs = observed, obs != state else { return }
    let prev = state; state = obs
    if prev == nil { log("初始状态：\(obs.rawValue)（不触发）"); return }
    DispatchQueue.main.async { self.onTransition(to: obs) }
  }

  func onTransition(to s: MicState) {
    let users = appsCapturingInput()
    let imeOn = users.contains { cfg.imeBundleIDs.contains($0) }
    let meeting = users.first { cfg.meetingBundleIDs.contains($0) }
    var decision: String
    if let m = meeting { decision = "跳过（\(m) 正在用麦克风，视为开会中）" }
    else if Date().timeIntervalSince(lastActionAt) < 0.5 { decision = "跳过（距上次操作不到 0.5 秒）" }
    else if s == .live && imeOn { decision = "跳过（输入法已经在听）" }
    else if s == .muted && !imeOn { decision = "跳过（输入法本来就没在听）" }
    else { decision = s == .live ? "按 \(cfg.toggleKey) → 开始语音" : "按 \(cfg.toggleKey) → 停止语音" }
    let willTap = decision.hasPrefix("按")
    if willTap && !cfg.tapEnabled { decision = "【只记录模式】本应" + decision }
    log("麦克风 → \(s.rawValue)｜正在用麦克风的程序：\(users.isEmpty ? "无" : users.joined(separator: ", "))｜\(decision)")
    if willTap && cfg.tapEnabled { lastActionAt = Date(); tapToggleKey() }
  }
}

// ---------- 启动 ----------
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
log("===== MicMuteVoice 启动，按键模式：\(cfg.tapEnabled ? "开" : "关（只记录）") =====")
if cfg.tapEnabled && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
  log("还没有辅助功能权限：请在 系统设置 → 隐私与安全性 → 辅助功能 里打开 MicMuteVoice，然后重启它")
}
let det = Detector()
AVCaptureDevice.requestAccess(for: .audio) { ok in
  log(ok ? "麦克风权限：有" : "麦克风权限：被拒绝，请在 系统设置 → 隐私与安全性 → 麦克风 里打开 MicMuteVoice")
  guard ok else { return }
  DispatchQueue.main.async {
    det.start()
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in det.watchdog() }
  }
}
app.run()
