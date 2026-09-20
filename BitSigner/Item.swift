//
//  Item.swift
//  BitSigner
//
//  Created by 谈国鹏 on 2026/9/20.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
