//
//  RadioProfile.swift
//  PommeCore
//
//  A saved snapshot of radio config + channels for quick switching between regions.
//
//  Created by Michael P. Bedworth on 04/27/26.
//  Copyright © 2026 Michael P. Bedworth. All rights reserved.
//

import Foundation

struct RadioProfile: Codable, Identifiable {
    let id: UUID
    var name: String
    var regionTag: String?
    let savedAt: Date
    let config: MeshProfileExport

    init(name: String, regionTag: String? = nil, config: MeshProfileExport) {
        self.id = UUID()
        self.name = name
        self.regionTag = regionTag
        self.savedAt = Date()
        self.config = config
    }
}
