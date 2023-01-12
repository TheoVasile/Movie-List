//
//  ContentView.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-07.
//

import SwiftUI


struct ContentView: View {
    var body: some View {
        VStack {
            Text("Movies List")
            Button("View List"){}
                .buttonStyle(.bordered)
            Button("Add Movie"){}
                .buttonStyle(.bordered)
            Button("Compare Movies"){}
                .buttonStyle(.bordered)
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
