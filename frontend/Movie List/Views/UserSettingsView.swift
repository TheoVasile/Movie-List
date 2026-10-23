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
    // Shown straight away while it saves; nil means whatever the server last said
    @State private var pendingPrivate: Bool? = nil
    @State private var savingPrivacy = false
    @State private var confirmPublic = false
    @State private var showUsernameSetup = false
    @State private var confirmDeactivate = false
    @ObservedObject private var appearance = AppearanceSettings.shared
    @AppStorage(Personalization.aiAllowedKey) private var aiAllowed = false
    @ObservedObject private var notifications = NotificationManager.shared
    @State private var notifyRequests = true
    @State private var notifyActivity = true
    @AppStorage(NotificationManager.suggestionsKey) private var notifySuggestions = true
    // Streaming alerts and how many services the user has picked for them, as last loaded from the server
    @State private var notifyStreaming = true
    @State private var savedNotifyStreaming = true
    @State private var streamingServiceCount: Int? = nil
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

                // Optional: lets friends who have the number in their contacts find this account
                Section {
                    PhoneNumberField()
                } header: {
                    Text("Phone Number")
                } footer: {
                    Text("Friends who sync their contacts can find you by this number. You'll get a text with a code to confirm it's yours. Only you can see it.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Private Profile", isOn: Binding(get: { isPrivate }, set: setPrivate))
                        .tint(Theme.accent)
                        .disabled(savingPrivacy || social.profile == nil)
                        .confirmationDialog("Make your profile public?", isPresented: $confirmPublic, titleVisibility: .visible) {
                            Button("Make Public") { savePrivacy(false) }
                        } message: {
                            let waiting = social.profile?.requests ?? 0
                            Text("The \(waiting) \(waiting == 1 ? "person" : "people") waiting to follow you will be accepted.")
                        }
                    NavigationLink {
                        BlockedAccountsView()
                    } label: {
                        Label {
                            Text("Blocked Accounts")
                                .foregroundColor(Theme.textPrimary)
                        } icon: {
                            Image(systemName: "hand.raised")
                                .foregroundStyle(Theme.accentGradient)
                        }
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(isPrivate
                         ? "You approve each follower. Lists can be seen by your followers or only you."
                         : "Anyone can follow you without asking. Each list can still be seen by everyone, your followers or only you.")
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
                    // Only a couple of accounts get the pink theme (ColorTheme.pinkHandles)
                    if ColorTheme.isAvailable(.pink, to: social.profile?.handle) {
                        Picker(selection: Binding(get: { appearance.colorTheme }, set: { theme in
                            Haptics.select()
                            appearance.colorTheme = theme
                        })) {
                            ForEach(ColorTheme.allCases) { theme in
                                Text(theme.title).tag(theme)
                            }
                        } label: {
                            Label("Color Theme", systemImage: "paintpalette.fill")
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text(ColorTheme.isAvailable(.pink, to: social.profile?.handle)
                         ? "\(appearanceFooter) Changing the color theme closes Settings to redraw the app."
                         : appearanceFooter)
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
                        Toggle(isOn: $notifyActivity) {
                            Label("Friend Activity", systemImage: "person.2.fill")
                        }
                        .tint(Theme.accent)
                        .onChange(of: notifyActivity) { wanted in
                            guard wanted != (social.profile?.notify_activity ?? true) else { return }
                            APIService.shared.setNotificationPreferences(activity: wanted) { saved in
                                if saved { social.load() } else { notifyActivity = !wanted }
                            }
                        }
                        Toggle(isOn: $notifySuggestions) {
                            Label("Film Suggestions", systemImage: "film")
                        }
                        .tint(Theme.accent)
                        .onChange(of: notifySuggestions) { _ in notifications.scheduleSuggestions() }
                        Toggle(isOn: $notifyStreaming) {
                            Label("Now Streaming", systemImage: "play.tv")
                        }
                        .tint(Theme.accent)
                        .onChange(of: notifyStreaming) { wanted in
                            guard wanted != savedNotifyStreaming else { return }
                            APIService.shared.saveStreamingPreferences(notify: wanted) { result in
                                if case .success(let saved) = result { savedNotifyStreaming = saved.notify } else { notifyStreaming = !wanted }
                            }
                        }
                        NavigationLink {
                            StreamingServicesView { count in streamingServiceCount = count }
                        } label: {
                            HStack {
                                Label("My Streaming Services", systemImage: "tv")
                                Spacer()
                                if let streamingServiceCount {
                                    Text(streamingServiceCount == 0 ? "None" : "\(streamingServiceCount)")
                                        .foregroundColor(Theme.textSecondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text(notifications.authorization == .denied
                         ? "Notifications for CineList are turned off in your iPhone's Settings."
                         : "Follow Requests: when someone asks to follow you, or accepts your request. Friend Activity: at most one summary a day of what the people you follow watched and ranked. Film Suggestions: an unwatched film from your watchlist on Tuesday, Friday and Sunday evenings. Now Streaming: when a film on your watchlist starts streaming on one of your services, or comes out.")
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
                         ? "AI Picks in Discover and Movie Night with friends send the titles in your lists, your Discover swipes and genre leanings, and your iPhone's country and language to a third-party AI provider. Your age range and pronouns are optional and only go with Discover requests. Your name and email are never sent. Movie Night only works when both of you allow AI. Choose AI Picks or Classic recommendations from Discover's ⋯ menu."
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
                notifyActivity = social.profile?.notify_activity ?? true
                APIService.shared.fetchStreamingPreferences { result in
                    guard case .success(let saved) = result else { return }
                    savedNotifyStreaming = saved.notify
                    notifyStreaming = saved.notify
                    streamingServiceCount = saved.services.count
                }
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

    private var isPrivate: Bool { pendingPrivate ?? social.profile?.is_private ?? false }

    private func setPrivate(_ wanted: Bool) {
        // Going public lets in everyone waiting, so that's checked first
        if !wanted, (social.profile?.requests ?? 0) > 0 {
            confirmPublic = true
        } else {
            savePrivacy(wanted)
        }
    }

    private func savePrivacy(_ wanted: Bool) {
        pendingPrivate = wanted
        savingPrivacy = true
        APIService.shared.setProfilePrivate(wanted) { saved in
            savingPrivacy = false
            if saved { Haptics.success() }
            // Lists made followers-only and requests accepted show once these reload
            social.load()
            ListSharing.shared.refresh()
            pendingPrivate = saved ? wanted : nil
        }
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
