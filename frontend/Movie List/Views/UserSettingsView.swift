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
    @Environment(\.managedObjectContext) var context
    @State var firstName: String = "Theo"
    @State var lastName: String = "Vasile"
    @State var pronouns: String = "He/Him"
    @Environment(\.dismiss) var dismiss
    @State private var confirmDeactivate = false
    @ObservedObject private var appearance = AppearanceSettings.shared

    private let pronounOptions = ["They/Them", "He/Him", "He/Them", "She/Her", "She/Them", "Xe/Xem", "Ze/Hir", "It/Its"]

    var body : some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    HStack {
                        Text("First Name")
                        Spacer()
                        TextField("type here", text: $firstName)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(Theme.textSecondary)
                    }
                    HStack {
                        Text("Last Name")
                        Spacer()
                        TextField("type here", text: $lastName)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(Theme.textSecondary)
                    }
                    Picker("Pronouns", selection: $pronouns) {
                        ForEach(pronounOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                }
                .listRowBackground(Theme.surface)

                Section {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button {
                            Haptics.select()
                            appearance.mode = mode
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: mode.icon)
                                    .foregroundStyle(Theme.accentGradient)
                                    .frame(width: 24)
                                Text(mode.title)
                                    .foregroundColor(Theme.textPrimary)
                                Spacer()
                                if appearance.mode == mode {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text(appearanceFooter)
                }
                .listRowBackground(Theme.surface)

                Section {
                    Button {
                        Haptics.tap()
                        authenticationViewModel.signOut()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundColor(Theme.textPrimary)
                    }
                    Button(role: .destructive) {
                        confirmDeactivate = true
                    } label: {
                        Label("Deactivate Account", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .bold()
                }
            }
            .confirmationDialog("Deactivate your account?", isPresented: $confirmDeactivate, titleVisibility: .visible) {
                Button("Deactivate Account", role: .destructive) {
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
            } message: {
                Text("This permanently deletes your account and all of your lists.")
            }
        }
    }
}

extension UserSettingsView {
    private var appearanceFooter: String {
        switch appearance.mode {
        case .dark, .light:
            return "Always use the \(appearance.mode.title.lowercased()) theme."
        case .system:
            return "Follows your iPhone's Light or Dark setting, including its automatic schedule."
        case .daylight:
            let times = "\(appearance.sunTimes.sunrise.formatted(date: .omitted, time: .shortened)) – \(appearance.sunTimes.sunset.formatted(date: .omitted, time: .shortened))"
            let source = appearance.usesLocation
                ? "Sunrise to sunset where you are"
                : "Allow location access for real sunrise and sunset times; until then it's"
            return "Light during the day, dark at night. \(source): \(times) today."
        }
    }
}

struct UserSettingsView_Previews : PreviewProvider {
    static var previews: some View {
        UserSettingsView()
            .environmentObject(AuthenticationViewModel())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
