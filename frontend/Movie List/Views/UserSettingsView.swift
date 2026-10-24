//
//  UserSettingsView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-12.
//

import Foundation
import SwiftUI
import CoreLocation

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
    @State private var confirmDelete = false
    // Accounts with a password confirm deleting with it; Google accounts sign in to Google again instead
    @State private var askDeletePassword = false
    @State private var deletePassword = ""
    @State private var deletingAccount = false
    @State private var deleteError: String? = nil
    @ObservedObject private var appearance = AppearanceSettings.shared
    @AppStorage(Personalization.aiAllowedKey) private var aiAllowed = false
    @ObservedObject private var notifications = NotificationManager.shared
    @State private var notifyRequests = true
    @State private var notifyActivity = true
    @AppStorage(NotificationManager.suggestionsKey) private var notifySuggestions = true
    // Off until chosen, since it needs location access all the time
    @AppStorage(TheatreCheckIns.enabledKey) private var theatreCheckIns = false
    @ObservedObject private var checkIns = TheatreCheckIns.shared
    // Streaming alerts and how many services the user has picked for them, as last loaded from the server
    @State private var notifyStreaming = true
    @State private var savedNotifyStreaming = true
    @State private var streamingServiceCount: Int? = nil
    @AppStorage(Personalization.useAIKey) private var discoverUsesAI = false
    @AppStorage(Personalization.aiConsentAskedKey) private var aiConsentAsked = false
    @AppStorage(Personalization.ageRangeKey) private var ageRange = Personalization.notShared
    @AppStorage(Personalization.birthdayKey) private var birthday = ""
    // The birthday being picked, until it's saved; nil while not changing it
    @State private var birthdayDraft: Date? = nil
    @State private var birthdayTooYoung = false
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
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("\(appearanceFooter) Changing the color theme closes Settings to redraw the app.")
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
                        Toggle(isOn: $theatreCheckIns) {
                            Label("Theatre Check-ins", systemImage: "ticket")
                        }
                        .tint(Theme.accent)
                        .onChange(of: theatreCheckIns) { wanted in checkIns.setEnabled(wanted) }
                        if theatreCheckIns {
                            theatreLocationWarning
                        }
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
                         : "Follow Requests: when someone asks to follow you, or accepts your request. Friend Activity: at most one summary a day of what the people you follow watched and ranked. Film Suggestions: an unwatched film from your watchlist on Tuesday, Friday and Sunday evenings. Now Streaming: when a film on your watchlist starts streaming on one of your services, or comes out. Theatre Check-ins: when you leave a movie theatre after a film, CineList asks what you saw so you can add it to a list. Works at any theatre; your location stays on this iPhone.")
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
                        // Optional. Saved with Save, so scrolling through years doesn't save each one on the way
                        HStack {
                            Text("Birthday")
                            Spacer()
                            if let shown = birthdayDraft ?? Personalization.birthdayDate(birthday) {
                                DatePicker("Birthday", selection: Binding(get: { shown }, set: { birthdayDraft = $0 }),
                                           in: ...Date(), displayedComponents: .date)
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                                if birthdayChanged {
                                    Button("Save", action: saveBirthday)
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(Theme.accent)
                                        .buttonStyle(.borderless)
                                }
                            } else {
                                // An age range chosen in earlier builds shows until a birthday replaces it
                                Button(ageRange == Personalization.notShared ? "Not shared" : ageRange) {
                                    birthdayDraft = Calendar.current.date(byAdding: .year, value: -18, to: Date())
                                }
                                .foregroundColor(Theme.textSecondary)
                                .buttonStyle(.borderless)
                            }
                            if birthdayDraft != nil || !birthday.isEmpty || ageRange != Personalization.notShared {
                                Button(action: removeBirthday) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(Theme.textSecondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Don't share birthday")
                            }
                        }
                        .alert("You must be 13 or older", isPresented: $birthdayTooYoung) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text("The minimum age for CineList is 13, per the Terms of Service. Your birthday wasn't changed.")
                        }
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text(isUnder18
                         ? "AI features aren't available under 18. Discover uses TMDb's recommendations for films in your lists."
                         : aiAllowed
                         ? "AI Picks in Discover and Movie Night with friends send the titles in your lists, your Discover swipes and genre leanings, and your iPhone's country and language to a third-party AI provider. Your birthday and pronouns are optional. Your birthday stays on this iPhone: only the age range it falls in goes with Discover requests, along with your pronouns. Your name and email are never sent. Movie Night only works when both of you allow AI. Choose AI Picks or Classic recommendations from Discover's ⋯ menu."
                         : "Nothing is sent to an AI. Discover uses TMDb's recommendations for films in your lists, and friends can't plan a Movie Night with you.")
                }
                .listRowBackground(Theme.surface)

                Section("Legal") {
                    NavigationLink {
                        LegalDocumentView(document: .terms)
                    } label: {
                        Label {
                            Text("Terms of Service")
                                .foregroundColor(Theme.textPrimary)
                        } icon: {
                            Image(systemName: "doc.text")
                                .foregroundStyle(Theme.accentGradient)
                        }
                    }
                    NavigationLink {
                        LegalDocumentView(document: .privacy)
                    } label: {
                        Label {
                            Text("Privacy Policy")
                                .foregroundColor(Theme.textPrimary)
                        } icon: {
                            Image(systemName: "hand.raised")
                                .foregroundStyle(Theme.accentGradient)
                        }
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label {
                            Text("About & Credits")
                                .foregroundColor(Theme.textPrimary)
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(Theme.accentGradient)
                        }
                    }
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
                        confirmDelete = true
                    } label: {
                        Label("Delete Account", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .disabled(deletingAccount)
            .overlay {
                if deletingAccount {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Deleting your account…")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(24)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .interactiveDismissDisabled(deletingAccount)
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
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) {
                    if authenticationViewModel.signsInWithPassword {
                        deletePassword = ""
                        askDeletePassword = true
                    } else {
                        deleteAccount(password: nil)
                    }
                }
            } message: {
                Text("This permanently deletes your CineList account and everything in it: your lists and rankings, diary and watched films, notes, followers and people you follow, film recommendations, and movie night groups. It can't be undone.")
            }
            .alert("Enter your password", isPresented: $askDeletePassword) {
                SecureField("Password", text: $deletePassword)
                Button("Delete Account", role: .destructive) {
                    deleteAccount(password: deletePassword)
                }
                Button("Cancel", role: .cancel) { deletePassword = "" }
            } message: {
                Text("Confirm it's you to permanently delete your account.")
            }
            .alert("Couldn't delete your account", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(deleteError ?? "")
            }
        }
    }
}

extension UserSettingsView {
    private func deleteAccount(password: String?) {
        deletingAccount = true
        Task {
            let result = await authenticationViewModel.deleteAccount(password: password)
            deletePassword = ""
            deletingAccount = false
            switch result {
            case .deleted:
                Haptics.success()
                // Like Sign Out: close Settings first, then sign out once it has slid away
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    authenticationViewModel.signOutDeletedAccount()
                }
            case .cancelled:
                break
            case .failed(let message):
                deleteError = message
            }
        }
    }
}

extension UserSettingsView {
    /// Check-ins only work with location set to Always and Precise Location on, since they notice leaving a
    /// theatre in the background. Shown under the switch while either is missing, with a way to Settings.
    /// Nothing shows while iOS is still asking
    @ViewBuilder
    private var theatreLocationWarning: some View {
        let needsAlways = checkIns.authorization != .authorizedAlways && checkIns.authorization != .notDetermined
        let needsPrecise = !needsAlways && checkIns.authorization == .authorizedAlways && !checkIns.preciseLocation
        if needsAlways || needsPrecise {
            VStack(alignment: .leading, spacing: 8) {
                Text(needsAlways
                     ? "Theatre check-ins need CineList's location access set to \"Always\"."
                     : "Theatre check-ins need Precise Location turned on for CineList.")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "location")
                        .foregroundColor(Theme.accent)
                }
            }
        }
    }

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
        Personalization.ageRange(birthday: birthday, legacy: ageRange) == Personalization.under18
    }

    private var birthdayChanged: Bool {
        guard let birthdayDraft else { return false }
        return Personalization.birthdayString(birthdayDraft) != birthday
    }

    /// Saves the picked birthday, unless it makes the user younger than the Terms allow, which keeps the
    /// one before. A birthday replaces an age range chosen in earlier builds
    private func saveBirthday() {
        guard let birthdayDraft else { return }
        self.birthdayDraft = nil
        guard Personalization.age(on: Date(), bornOn: birthdayDraft) >= Personalization.minimumAge else {
            birthdayTooYoung = true
            return
        }
        Haptics.success()
        birthday = Personalization.birthdayString(birthdayDraft)
        UserDefaults.standard.removeObject(forKey: Personalization.ageRangeKey)
    }

    /// Stops sharing an age: forgets the birthday, and any age range from earlier builds
    private func removeBirthday() {
        Haptics.tap()
        birthdayDraft = nil
        birthday = ""
        UserDefaults.standard.removeObject(forKey: Personalization.ageRangeKey)
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
