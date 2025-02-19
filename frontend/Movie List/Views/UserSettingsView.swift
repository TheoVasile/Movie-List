//
//  UserSettingsView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-12.
//

import Foundation
import SwiftUI

struct UserSettingsView : View {
    @EnvironmentObject var authenticationViewModel: AuthenticationViewModel
    @State var firstName: String = "Theo"
    @State var lastName: String = "Vasile"
    @State var pronouns: String = "He/Him"
    var body : some View {
        VStack {
            HStack{
                Text("First Name")
                    .padding()
                Spacer()
                TextField("type here", text: $firstName)
                    .padding()
                    .frame(width: 200, height: 30)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(10)
                    .padding(.horizontal)
            }
            .padding(.vertical)
            Divider()
            HStack{
                Text("Last Name")
                    .padding(.horizontal)
                Spacer()
                TextField("type here", text: $lastName)
                    .padding()
                    .frame(width: 200, height: 30)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(10)
                    .padding(.horizontal)
            }
            .padding(.vertical)
            Divider()
            HStack{
                Text("Pronouns")
                    .padding(.horizontal)
                Spacer()
                Menu {
                    Button("They/Them") {
                        pronouns = "They/Them"
                    }
                    Button("He/Him") {
                        pronouns = "He/Him"
                    }
                    Button("He/Them") {
                        pronouns = "He/Them"
                    }
                    Button("She/Her") {
                        pronouns = "She/Her"
                    }
                    Button("She/Them") {
                        pronouns = "She/Them"
                    }
                    Button("Xe/Xem") {
                        pronouns = "Xe/Xem"
                    }
                    Button("Ze/Hir") {
                        pronouns = "Ze/Hir"
                    }
                    Button("It/Its") {
                        pronouns = "It/Its"
                    }
                } label: {
                    Text(pronouns)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
            Divider()
            Button("Sign Out") { authenticationViewModel.signOut() }
                .padding(.vertical)
            Divider()
            Button("Deactivate Account") {
                APIService.shared.deleteUser(firebase_id: authenticationViewModel.user!.uid) { result in
                    switch result {
                    case .success:
                        Task {
                            await authenticationViewModel.deleteAccount()
                        }
                    case .failure(let error):
                        print(error)
                    }
                }
            }
                .foregroundStyle(.red)
                .padding(.vertical)
            Spacer()
        }
    }
}

struct UserSettingsView_Previews : PreviewProvider {
    static var previews: some View {
        UserSettingsView()
            .environmentObject(AuthenticationViewModel())
    }
}
