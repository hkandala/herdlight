import JavaScriptCore
import Foundation
func rss() -> Double { var i = task_vm_info_data_t(); var c = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / 4)
  _ = withUnsafeMutablePointer(to: &i) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(c)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &c) } }
  return Double(i.phys_footprint) / 1_048_576 }
let src = try! String(contentsOfFile: "poly.js") + (try! String(contentsOfFile: "out.js"))
var keep: [JSContext] = []
print(String(format: "base footprint %.1f MB", rss()))
for n in 1...10 {
  let ctx = JSContext(virtualMachine: JSVirtualMachine())!
  ctx.exceptionHandler = { _, e in print("JS error", e!) }
  let print_: @convention(block) (String) -> Void = { print($0) }
  ctx.setObject(print_, forKeyedSubscript: "print" as NSString)
  ctx.evaluateScript(src)
  let commit: @convention(block) (Int, Int, Int) -> Void = { _, _, _ in }
  let host = JSValue(newObjectIn: ctx)!; host.setObject(commit, forKeyedSubscript: "commit" as NSString)
  ctx.objectForKeyedSubscript("__start").call(withArguments: [host]); ctx.evaluateScript("__drain()")
  keep.append(ctx)
  if n == 1 || n == 10 { print(String(format: "%d contexts (500-row list each): %.1f MB", n, rss())) }
}
