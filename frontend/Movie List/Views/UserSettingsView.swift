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
    // The account's name, as typed in the field below; saved when the user taps Save
    @State private var name: String = ""
    @State private var savingName = false
    @State private var nameMessage: String? = nil
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var social = SocialStore.shared
    @State private var showUsernameSetup = false
    @State private var confirmDeactivate = false
    @ObservedObject private var appearance = AppearanceSettings.shared
    @AppStorage(Personalization.aiAllowedKey) private var aiAllowed = false
    @ObservedObject private var notifications = NotificationManager.shared
    @State private var notifyRequests = true
    @AppStorage(Personalization.useAIKey) private var discoverUsesAI = false
    @AppStorage(Personalization.aiConsentAskedKey) private var aiConsentAsked = false
    @AppStorage(Personalization.ageRangeKey) private var ageRange = Personalization.notShared
    @AppStorage(Personalization.pronounsKey) private var pronouns = Personalization.notShared

    var body : some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    Button {
                        showUsernameSetup = true
                    } label: {
                        HStack {
                            Text("Username")
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text(social.profile?.handle.map { "@\($0)" } ?? "Choose one")
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Your name", text: $name)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(Theme.textSecondary)
                            .textContentType(.name)
                            .submitLabel(.done)
                            .onSubmit(saveName)
                        if nameChanged {
                            Button(savingName ? "Saving…" : "Save", action: saveName)
                                .font(.body.weight(.semibold))
                                .foregroundColor(Theme.accent)
                                .disabled(savingName)
                                .buttonStyle(.borderless)
                        }
                    }
                    if let nameMessage {
                        Text(nameMessage)
                            .font(.footnote)
                            .foregroundColor(Theme.accentSecondary)
                    }
                    Picker("Pronouns", selection: $pronouns) {
                        ForEach(Personalization.pronouns, id: \.self) { option in
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
                    switch notifications.authorization {
                    case .notDetermined:
                        Button {
                            notifications.requestPermission()
                        } label: {
                            Label("Turn On Notifications", systemImage: "bell.badge")
                                .foregroundColor(Theme.accent)
                        }
                    case .denied:
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Notifications Are Off · Open Settings", systemImage: "bell.slash")
                                .foregroundColor(Theme.accent)
                        }
                    default:
                        Toggle(isOn: $notifyRequests) {
                            Label("Follow Requests", systemImage: "person.badge.plus")
                        }
                        .tint(Theme.accent)
                        .onChange(of: notifyRequests) { wanted in
                            guard wanted != (social.profile?.notify_requests ?? true) else { return }
                            APIService.shared.setNotificationPreferences(requests: wanted) { saved in
                                if saved { social.load() } else { notifyRequests = !wanted }
                            }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text(notifications.authorization == .denied
                         ? "Notifications for CineList are turned off in your iPhone's Settings."
                         : "Get a notification when someone asks to follow you, or accepts your request.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle(isOn: $aiAllowed) {
                        Label("Allow AI Features", systemImage: "brain")
                    }
                    .tint(Theme.accent)
                    .disabled(isUnder18)
                    .onChange(of: aiAllowed) { allowed in
                        aiConsentAsked = true
                        // Turning AI on is a request to use it, so Discover switches to AI Picks
                        if allowed {
                            discoverUsesAI = true
                        }
                    }
                    if aiAllowed || isUnder18 {
                        Picker("Age Range", selection: $ageRange) {
                            ForEach(Personalization.ageRanges, id: \.self) { Text($0).tag($0) }
                        }
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text(isUnder18
                         ? "AI features aren't available under 18. Discover uses TMDb's recommendations for films in your lists."
                         : aiAllowed
                         ? "AI Picks in Discover and Movie Night with friends send the titles in your lists, your Discover swipes and genre leanings, and your iPhone's country and language to Claude, Anthropic's AI. Your age range and pronouns are optional and only go with Discover requests. Your name and email are never sent. Movie Night only works when both of you allow AI. Choose AI Picks or Classic recommendations from Discover's ⋯ menu."
                         : "Nothing is sent to an AI. Discover uses TMDb's recommendations for films in your lists, and friends can't plan a Movie Night with you.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Button {
                        Haptics.tap()
                        // Close Settings first, then sign out once it has slid away, so it can't be
                        // left showing over the sign-in screen
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            authenticationViewModel.signOut()
                        }
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
            .onAppear {
                name = savedName
                notifyRequests = social.profile?.notify_requests ?? true
                notifications.refreshAuthorization()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .bold()
                }
            }
            .sheet(isPresented: $showUsernameSetup) {
                UsernameSetupView()
            }
            .confirmationDialog("Deactivate your account?", isPresented: $confirmDeactivate, titleVisibility: .visible) {
                Button("Deactivate Account", role: .destructive) {
                    APIService.shared.deleteUser(firebase_id: authenticationViewModel.user!.uid) { result in
                        switch result {
                        case .success:
                            Task {
                                if await authenticationViewModel.deleteAccount() {
                                    dismiss()
                                }
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
    private var savedName: String {
        authenticationViewModel.user?.displayName ?? ""
    }

    private var nameChanged: Bool {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !typed.isEmpty && typed != savedName
    }

    private func saveName() {
        guard nameChanged else { return }
        Haptics.tap()
        savingName = true
        nameMessage = nil
        Task {
            nameMessage = await authenticationViewModel.updateName(name)
            savingName = false
            name = savedName
        }
    }

    private var isUnder18: Bool {
        ageRange == Personalization.under18
    }

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
