//
//  Movie_ListApp.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-07.
//

import Foundation
import SwiftUI

@main
struct Movie_ListApp: App {
    @StateObject private var network = Network()
    @StateObject private var db = DataAccess()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(network)
                .environmentObject(db)
        }
    }
}
