//
//  Home.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import SwiftUI

struct Home: View {
    
    @FetchRequest(fetchRequest: CDMovieList.fetch()) var movieLists: FetchedResults<CDMovieList>
    @Environment(\.managedObjectContext) var context
    @EnvironmentObject var viewModel: AuthenticationViewModel
    @EnvironmentObject var network: NetworkService
    @ObservedObject private var sync = SyncStatus.shared
    @Environment(\.scenePhase) private var scenePhase
    // The export ZIP waiting to go to the share sheet
    @State private var exportItem: ShareItem? = nil
    @State var showPopup: Bool = false
    @State var listName = ""
    @State var showExcelImport: Bool = false
    @State var showLetterboxdImport: Bool = false
    // The list whose name and description are being edited
    @State private var editingList: CDMovieList? = nil
    // The list whose contributors are being changed
    @State private var sharingList: CDMovieList? = nil
    // A list deleted or left from Edit List, taken off the phone once that sheet has closed
    @State private var removedList: CDMovieList? = nil
    // The list opened by Reorder in a card's menu, which starts out reordering
    @State private var reorderingList: CDMovieList? = nil
    // A new list's visibility and the people (by @handle) who'll edit it with the user
    @State private var newListVisibility = ListVisibility.public
    @State private var newListRanked = true
    @State private var newListEditors: Set<String> = []
    @ObservedObject private var social = SocialStore.shared
    
    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View{
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        movieListsView
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .refreshable {
                    await refresh()
                }
            }
            .navigationTitle("Your Lists")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            Haptics.tap()
                            showPopup = true
                        } label: {
                            Label("New List", systemImage: "plus.rectangle.on.rectangle")
                        }
                        Button {
                            Haptics.tap()
                            showExcelImport = true
                        } label: {
                            Label("Import from Excel", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            Haptics.tap()
                            showLetterboxdImport = true
                        } label: {
                            Label("Import from Letterboxd", systemImage: "film.stack")
                        }
                        if !movieLists.isEmpty {
                            Divider()
                            Button {
                                exportAllLists()
                            } label: {
                                Label("Export All Lists (ZIP)", systemImage: "doc.zipper")
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accentGradient)
                    }
                }
            }
        }
        .task {
            // Signed in from an earlier launch: the lists on this phone may be out of date
            if sync.lastSynced == nil {
                startSync()
            }
        }
        .onChange(of: scenePhase) { phase in
            // Films added or reranked since the last sync show on the widgets once the user leaves the app
            if phase == .background {
                PersistenceController.shared.updateWidgets()
            }
            if phase == .active, let last = sync.lastSynced, Date().timeIntervalSince(last) > 10 * 60 {
                startSync()
            }
        }
        .sheet(isPresented: $showPopup, onDismiss: resetNewList) {
            newListSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLetterboxdImport) {
            LetterboxdImportView()
                .environmentObject(viewModel)
                .environment(\.managedObjectContext, context)
        }
        .sheet(isPresented: $showExcelImport) {
            ExcelImportView()
                .environmentObject(viewModel)
                .environment(\.managedObjectContext, context)
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(items: item.items)
                .presentationDetents([.medium, .large])
        }
    }
}

private extension Home {
    func startSync(completion: (() -> Void)? = nil) {
        guard let uid = viewModel.user?.uid else {
            completion?()
            return
        }
        sync.sync(firebaseID: uid, completion: completion)
    }

    func refresh() async {
        await withCheckedContinuation { continuation in
            startSync { continuation.resume() }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(Theme.accentGradient)
            Text(movieLists.isEmpty
                 ? sync.isFirstSync ? "Loading your lists…" : "Start your first collection"
                 : "\(movieLists.count) \(movieLists.count == 1 ? "list" : "lists") · \(totalTitles)")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
            if let error = sync.lastError, !movieLists.isEmpty, !sync.isSyncing {
                // Cached lists are still usable, so this stays small
                Button {
                    Haptics.tap()
                    startSync()
                } label: {
                    Label("\(error) Showing saved lists · Retry", systemImage: "wifi.exclamationmark")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.surfaceRaised, in: Capsule())
                        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .padding(.top, 4)
        .animation(Theme.spring, value: sync.lastError)
        .appearAnimation()
    }

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        // displayName falls back to the email address, which reads badly in a greeting
        let name = viewModel.user?.displayName ?? ""
        let firstName = name.contains("@") ? "" : name.split(separator: " ").first.map(String.init) ?? ""
        let timeOfDay = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return firstName.isEmpty ? timeOfDay : "\(timeOfDay), \(firstName)"
    }

    // Each film or show once, however many lists it's in, e.g. "984 films · 32 shows"
    var totalTitles: String {
        let ids = Set(movieLists.flatMap { $0.movies.map(\.tmdb_id) })
        let shows = ids.filter { $0 < 0 }.count
        return Self.countLabel(films: ids.count - shows, shows: shows)
    }

    /// "5 films", "32 shows", or "12 films · 3 shows" when there are both
    static func countLabel(films: Int, shows: Int) -> String {
        let filmText = "\(films.formatted()) \(films == 1 ? "film" : "films")"
        let showText = "\(shows.formatted()) \(shows == 1 ? "show" : "shows")"
        if shows == 0 { return filmText }
        return films == 0 ? showText : "\(filmText) · \(showText)"
    }

    var movieListsView: some View {
        Group {
            if movieLists.isEmpty && (sync.isSyncing || sync.isFirstSync) {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(Theme.accent)
                    Text("Loading your lists…")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)
            } else if movieLists.isEmpty, let error = sync.lastError {
                EmptyStateView(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't load your lists",
                    message: "\(error) Your lists are safe on the server.",
                    actionTitle: "Retry"
                ) {
                    startSync()
                }
                .padding(.top, 60)
            } else if movieLists.isEmpty {
                EmptyStateView(
                    icon: "film.stack",
                    title: "No lists yet",
                    message: "Create a list and start ranking the films you love.",
                    actionTitle: "Create a List"
                ) {
                    showPopup = true
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(movieLists.enumerated()), id: \.element) { index, movieList in
                        NavigationLink {
                            ListView(movieList: movieList, context: context)
                                .environmentObject(NetworkService())
                                .environmentObject(DatabaseService())
                        } label: {
                            ListCard(movieList: movieList)
                        }
                        .buttonStyle(PressableButtonStyle())
                        // Touch and hold is a shortcut for the ••• on the card
                        .contextMenu { listMenuItems(movieList) }
                        .overlay(alignment: .topTrailing) {
                            Menu {
                                listMenuItems(movieList)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundColor(Theme.textPrimary)
                                    .frame(width: 30, height: 30)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                                    .padding(8)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("\(movieList.name ?? "List") Options")
                        }
                        .appearAnimation(delay: Double(min(index, 8)) * 0.06)
                    }
                }
            }
        }
        // Reorder in a card's menu opens the list ready to drag its films
        .navigationDestination(isPresented: Binding(get: { reorderingList != nil }, set: { if !$0 { reorderingList = nil } })) {
            if let reorderingList {
                ListView(movieList: reorderingList, context: context, startsReordering: true)
                    .environmentObject(NetworkService())
                    .environmentObject(DatabaseService())
            }
        }
        .sheet(item: $editingList, onDismiss: removeDeletedList) { movieList in
            EditListSheet(movieList: movieList) { removedList = movieList }
        }
        .sheet(item: $sharingList) { movieList in
            ShareListSheet(listID: movieList.id, listName: movieList.name ?? "List") {
                removedList = movieList
                removeDeletedList()
            }
            .presentationDetents([.medium, .large])
        }
    }

    // A list card's actions, from its ••• or a long press: the same three as the ••• inside the list
    func listMenuItems(_ movieList: CDMovieList) -> some View {
        ListMenuItems(
            listID: movieList.id,
            canReorder: movieList.movies.count > 1,
            onEdit: { editingList = movieList },
            onAddContributor: { sharingList = movieList },
            onReorder: { reorderingList = movieList }
        )
    }

    /// Takes a list that was just deleted or left off the phone
    func removeDeletedList() {
        guard let list = removedList else { return }
        removedList = nil
        withAnimation(Theme.spring) {
            CDMovieList.delete(movieList: list)
        }
        // Everyone else's view of who's on it is now out of date
        if ListSharing.shared.isShared(list.id) {
            ListSharing.shared.refresh()
        }
    }


    func addNewList() {
        let name = listName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let userID = viewModel.user?.uid else { return }
        let visibility = newListVisibility
        let editors = Array(newListEditors)
        let newList = CDMovieList(id: Int64(1), name: name, overview: "", context: context)

        let ranked = newListRanked
        APIService.shared.createList(userID: userID, name: name, overview: "", isRanked: ranked, visibility: visibility) { result in
            switch result {
            case .success(let serverList):
                newList.id = serverList.id
                ListVisibility.remember(visibility, for: serverList.id)
                ListRanking.remember(ranked, for: serverList.id)
                try? context.save()
                AppAnalytics.log(.listCreated(ranked: ranked))
                inviteEditors(editors, to: serverList.id)
            case .failure(let error):
                print("Backend request failed, deleting from Core Data:", error.localizedDescription)
                // The list only exists on the phone, so it goes
                withAnimation(Theme.spring) {
                    context.delete(newList)
                    try? context.save()
                }
            }
        }

        Haptics.success()
        showPopup = false
    }

    /// Invites people to edit a list that was just made, one after another, then shows them on it
    func inviteEditors(_ handles: [String], to listID: Int64) {
        guard let handle = handles.first else {
            ListSharing.shared.refresh()
            return
        }
        APIService.shared.addListEditor(listID: listID, handle: handle) { message in
            if let message { print("Couldn't invite @\(handle):", message) }
            inviteEditors(Array(handles.dropFirst()), to: listID)
        }
    }

    var isPrivateProfile: Bool { social.profile?.is_private == true }

    func resetNewList() {
        listName = ""
        newListVisibility = .public
        newListRanked = true
        newListEditors = []
    }

    /// Every list in one ZIP, laid out like Letterboxd's data export
    func exportAllLists() {
        Haptics.tap()
        do {
            exportItem = ShareItem(items: [try ListExport.makeZip(lists: Array(movieLists))])
        } catch {
            print("Error exporting lists:", error)
        }
    }

    var newListSheet: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Christmas Classics", text: $listName)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                }
                .listRowBackground(Theme.surface)
                Section {
                    Toggle("Ranked", isOn: $newListRanked)
                        .tint(Theme.accent)
                } footer: {
                    Text(newListRanked
                         ? "Films are ranked best first, and you'll compare each new one to find its place."
                         : "Films just go on the end, in no particular order, like a watchlist. Their order isn't treated as a ranking.")
                }
                .listRowBackground(Theme.surface)
                Section {
                    Picker("Who Can See It", selection: $newListVisibility) {
                        ForEach(ListVisibility.options(isPrivate: isPrivateProfile)) { option in
                            Label(option.title(isPrivate: isPrivateProfile), systemImage: option.icon).tag(option)
                        }
                    }
                } header: {
                    Text("Visibility")
                } footer: {
                    Text(newListVisibility.explanation(isPrivate: isPrivateProfile))
                }
                .listRowBackground(Theme.surface)
                Section {
                    if social.following.isEmpty {
                        Text("Follow some friends to make lists together.")
                            .foregroundColor(Theme.textSecondary)
                    }
                    ForEach(social.following) { person in
                        Button {
                            Haptics.tap()
                            if newListEditors.contains(person.handle) {
                                newListEditors.remove(person.handle)
                            } else {
                                newListEditors.insert(person.handle)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Avatar(name: person.display_name, size: 32, handle: person.handle, version: person.avatar_version)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("@\(person.handle)")
                                        .foregroundColor(Theme.textPrimary)
                                    Text(person.display_name)
                                        .font(.caption)
                                        .foregroundColor(Theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: newListEditors.contains(person.handle) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(newListEditors.contains(person.handle) ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                            }
                        }
                        .accessibilityAddTraits(newListEditors.contains(person.handle) ? .isSelected : [])
                    }
                } header: {
                    Text("Contributors (Optional)")
                } footer: {
                    Text("Contributors can add, rank and remove films with you. You can add more later from the list's ••• menu.")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(newListEditors.isEmpty ? "New List" : "New Shared List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPopup = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { addNewList() }
                        .bold()
                        .disabled(listName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if social.following.isEmpty { social.load() }
                // A private profile's lists can't be seen by everyone, so they start as Friends
                if isPrivateProfile && newListVisibility == .public { newListVisibility = .followers }
            }
        }
    }
}

// MARK: - List card

private struct ListCard: View {
    @ObservedObject var movieList: CDMovieList

    private var topPosters: [String?] {
        movieList.movies
            .sorted { $0.rank < $1.rank }
            .prefix(3)
            .map { $0.poster_path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            posterFan
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    // Opposite the card's •••, so it's clear at a glance which lists have contributors
                    if ListSharing.shared.isShared(movieList.id) {
                        Label("Shared", systemImage: "person.2.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                            .offset(x: -6, y: -6)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(movieList.name ?? "No Name")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    let shows = movieList.movies.filter(\.isTV).count
                    Text(Home.countLabel(films: movieList.movies.count - shows, shows: shows))
                    if !ListRanking.isRanked(movieList.id) {
                        Text("· unranked")
                    }
                    // Followers is the usual case, so only the other two get a quiet marker. Shared lists have a badge instead
                    let visibility = ListVisibility.of(movieList.id)
                    if !ListSharing.shared.isShared(movieList.id) && visibility != .followers {
                        Image(systemName: visibility.icon)
                            .imageScale(.small)
                            .accessibilityLabel(visibility == .public ? "Public" : "Private")
                    }
                }
                .font(.caption)
                .foregroundColor(Theme.textSecondary)
            }
        }
        .padding(14)
        .background(
            ZStack {
                Theme.surface
                PosterBackdrop(path: topPosters.first ?? nil)
                    .opacity(0.6)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
        .shadow(color: Theme.shadow.opacity(0.35), radius: 12, y: 8)
    }

    // Top three films fanned out like a hand of cards, #1 in front
    private var posterFan: some View {
        ZStack {
            if topPosters.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .frame(width: 90, height: 135)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(Theme.textTertiary)
                    )
            } else {
                ForEach(Array(topPosters.enumerated().reversed()), id: \.offset) { index, path in
                    PosterImage(path: path, cornerRadius: 10, size: .medium)
                        .frame(width: 90, height: 135)
                        .shadow(color: Theme.shadow.opacity(0.5), radius: 8, y: 4)
                        .rotationEffect(.degrees(Double(index) * (index.isMultiple(of: 2) ? 9 : -9)))
                        .offset(x: CGFloat(index) * (index.isMultiple(of: 2) ? 22 : -22), y: CGFloat(index) * 4)
                        .scaleEffect(1 - CGFloat(index) * 0.08)
                }
            }
        }
    }
}

// MARK: - Edit list

/// Renames a list and edits its description, saving to the server first so the two never disagree. Deleting the list
/// is at the bottom. Someone else's list the user was invited to edit is read-only here, with a way to leave it
struct EditListSheet: View {
    @ObservedObject var movieList: CDMovieList
    // Called once the list has been deleted or left, as this sheet closes
    var onRemoved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @ObservedObject private var sharing = ListSharing.shared
    @State private var name: String
    @State private var overview: String
    @State private var visibility: ListVisibility
    @State private var ranked: Bool
    @State private var isSaving = false
    @State private var saveFailed = false
    // Deleting the list (the owner) or leaving it (a contributor): asking first, the request, and why it failed
    @State private var confirmingRemove = false
    @State private var isRemoving = false
    @State private var removeFailed: String? = nil

    init(movieList: CDMovieList, onRemoved: @escaping () -> Void = {}) {
        self.movieList = movieList
        self.onRemoved = onRemoved
        _name = State(initialValue: movieList.name ?? "")
        _overview = State(initialValue: movieList.overview ?? "")
        _visibility = State(initialValue: ListVisibility.of(movieList.id))
        _ranked = State(initialValue: ListRanking.isRanked(movieList.id))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isPrivateProfile: Bool { SocialStore.shared.profile?.is_private == true }

    // Only the owner can rename a shared list, change who can see it or delete it
    private var isOwner: Bool { sharing.isOwner(movieList.id) }

    private var listTitle: String { movieList.name ?? "List" }

    private var hasChanges: Bool {
        trimmedName != (movieList.name ?? "") || overview != (movieList.overview ?? "") || visibility != ListVisibility.of(movieList.id)
            || ranked != ListRanking.isRanked(movieList.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isOwner {
                    ownerSections
                } else {
                    memberSections
                }
                Section {
                    Button(role: .destructive) {
                        confirmingRemove = true
                    } label: {
                        HStack {
                            Text(isOwner ? "Delete List" : "Leave List")
                            Spacer()
                            if isRemoving {
                                ProgressView()
                            }
                        }
                    }
                } footer: {
                    Text(isOwner
                         ? (sharing.isShared(movieList.id) ? "It's deleted for everyone on it, along with its films and ranks." : "Its films and ranks are deleted too.")
                         : "You'll stop seeing this list. The films you added stay in it.")
                }
                .listRowBackground(Theme.surface)
            }
            .disabled(isSaving || isRemoving)
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(isOwner ? "Edit List" : "List Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isOwner {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isRemoving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Button("Save") { save() }
                                .bold()
                                .disabled(trimmedName.isEmpty || trimmedName.count > 100 || !hasChanges || isRemoving)
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .bold()
                            .disabled(isRemoving)
                    }
                }
            }
            .alert("Couldn't save changes", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Check your connection and try again.")
            }
            .alert("Couldn't do that", isPresented: Binding(get: { removeFailed != nil }, set: { if !$0 { removeFailed = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(removeFailed ?? "")
            }
            .confirmationDialog(isOwner ? "Delete \(listTitle)?" : "Leave \(listTitle)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button(isOwner ? "Delete List" : "Leave List", role: .destructive, action: remove)
            } message: {
                Text(isOwner
                     ? (sharing.isShared(movieList.id) ? "It's deleted for everyone on it, along with its films and ranks." : "Its films and ranks are deleted too.")
                     : "You'll stop seeing this list. The films you added stay in it.")
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSaving || isRemoving)
    }

    @ViewBuilder
    private var ownerSections: some View {
        Section("Name") {
            TextField("List name", text: $name)
                .disableAutocorrection(true)
        }
        .listRowBackground(Theme.surface)
        Section {
            TextField("What's this list about?", text: $overview, axis: .vertical)
                .lineLimit(3...8)
        } header: {
            Text("Description")
        } footer: {
            Text("Optional. Shown at the top of the list.")
        }
        .listRowBackground(Theme.surface)
        Section {
            Toggle("Ranked", isOn: $ranked)
                .tint(Theme.accent)
        } footer: {
            Text(ranked
                 ? "Films are ranked best first."
                 : "Films are in no particular order. New ones go on the end, and the order isn't treated as a ranking.")
        }
        .listRowBackground(Theme.surface)
        Section {
            Picker("Who Can See It", selection: $visibility) {
                ForEach(ListVisibility.options(isPrivate: isPrivateProfile)) { option in
                    Label(option.title(isPrivate: isPrivateProfile), systemImage: option.icon).tag(option)
                }
            }
        } header: {
            Text("Visibility")
        } footer: {
            Text(visibility.explanation(isPrivate: isPrivateProfile))
        }
        .listRowBackground(Theme.surface)
    }

    // What a contributor sees: the list's details, which only the owner can change
    @ViewBuilder
    private var memberSections: some View {
        Section {
            LabeledContent("Name", value: listTitle)
            if let owner = sharing.members(of: movieList.id).first(where: \.is_owner) {
                LabeledContent("Owner", value: "@\(owner.handle)")
            }
            LabeledContent("Order", value: ranked ? "Ranked" : "Unranked")
        } footer: {
            Text("Only the owner can rename the list, change who can see it or delete it. You can add, rank and remove films.")
        }
        .listRowBackground(Theme.surface)
        if let description = movieList.overview, !description.isEmpty {
            Section("Description") {
                Text(description)
                    .foregroundColor(Theme.textSecondary)
            }
            .listRowBackground(Theme.surface)
        }
    }

    private func save() {
        isSaving = true
        APIService.shared.updateList(listID: movieList.id, name: trimmedName, overview: overview, visibility: visibility, isRanked: ranked) { result in
            isSaving = false
            switch result {
            case .success:
                Haptics.success()
                ListVisibility.remember(visibility, for: movieList.id)
                ListRanking.remember(ranked, for: movieList.id)
                movieList.name = trimmedName
                movieList.overview = overview
                try? context.save()
                dismiss()
            case .failure(let error):
                print("Error updating list:", error)
                saveFailed = true
            }
        }
    }

    // Deletes the list for everyone (the owner) or takes the user off it (a contributor). The caller removes it from
    // the phone once this sheet has closed, so nothing is left showing a deleted list
    private func remove() {
        isRemoving = true
        let finish = {
            isRemoving = false
            Haptics.success()
            onRemoved()
            dismiss()
        }
        if isOwner {
            APIService.shared.deleteList(listID: movieList.id) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success: finish()
                    case .failure(let error):
                        print("Error deleting list:", error)
                        isRemoving = false
                        removeFailed = "Couldn't delete the list. Check your connection and try again."
                    }
                }
            }
        } else {
            APIService.shared.removeListEditor(listID: movieList.id) { ok in
                guard ok else {
                    isRemoving = false
                    removeFailed = "Couldn't leave the list. Check your connection and try again."
                    return
                }
                finish()
            }
        }
    }
}

struct Home_Previews: PreviewProvider{
    static var previews: some View{
        Home()
            .environmentObject(AuthenticationViewModel())
            .environmentObject(NetworkService())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
