//
//  ProcessMetrics.swift
//  SpeechCleanser
//
//  Created by Vasil Botsev on 10.10.25.
//

import MachO

struct ProcessMetrics {
    static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &infoCount)
            }
        }
        
        guard result == KERN_SUCCESS else {
            print("[ProcessMetrics][ERROR] memoryFootprint: task_info failed with code \(result)")
            return nil
        }
        
        return UInt64(info.phys_footprint)
    }
    
    static func formatted(bytes value: UInt64) -> String {
        let mbValue = Double(value) / 1024.0 / 1024.0
        return String(format: "%.1f MB", mbValue)
    }
}
