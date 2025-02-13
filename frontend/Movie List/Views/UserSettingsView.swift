//
//  UserSettingsView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-12.
//

import Foundation
import SwiftUI

struct UserSettingsView : View {
    var body : some View {
        VStack {
            Button("Sign Out") { print("sign out") }
            Divider()
            Text("First Name")
            Divider()
            Text("Last Name")
            Divider()
            Menu {
                Text("They/Them")
                Text("He/Him")
                Text("He/Them")
                Text("She/Her")
                Text("She/Them")
                Text("Xe/")
                Text("Ze/")
                Text("It/")
            } label: {
                Text("Pronouns")
            }
            Divider()
            Button("Deactivate Account") { print("deactivate") }
                .foregroundStyle(.red)
            Spacer()
        }
    }
}

struct UserSettingsView_Previews : PreviewProvider {
    static var previews: some View {
        UserSettingsView()
    }
}
