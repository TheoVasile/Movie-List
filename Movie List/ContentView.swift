//
//  ContentView.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-07.
//

import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var network: Network
    @EnvironmentObject var db: DataAccess
    @State var showingPopup = false
    
    var body: some View {
        Home()
            .environmentObject(network)
            .environmentObject(db)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(Network())
            .environmentObject(DataAccess())
    }
}
