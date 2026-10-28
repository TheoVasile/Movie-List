//
//  LetterboxdImportView.swift
//  Movie List
//
//  Created by Theo Vasile on 2026-10-17.
//

import SwiftUI
import UniformTypeIdentifiers
import StoreKit

struct LetterboxdImportView: View {
    @FetchRequest(fetchRequest: CDMovieList.fetch()) var existingLists: FetchedResults<CDMovieList>
    @Environment(\.managedObjectContext) var context
    @Environment(\.dismiss) var dismiss
    @Environment(\.requestReview) private var requestReview
    @EnvironmentObject var viewModel: AuthenticationViewModel

    private enum Step {
        case chooseFile
        case selectLists([LetterboxdList])
        case importing
        case finished([ListDetailsResponse])
    }

    @State private var step: Step = .chooseFile
    @State private var selected: Set<String> = []
    @State private var showFileImporter = false
    @State private var errorMessage: String?

    private static let exportURL = URL(string: "https://letterboxd.com/settings/data/")!

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
                    .padding(.horizontal, 16)
            }
            .navigationTitle("Import from Letterboxd")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isImporting {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isImporting)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.zip, .commaSeparatedText],
            allowsMultipleSelection: true
        ) { result in
            handleFileSelection(result)
        }
        .alert("Import Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var isImporting: Bool {
        if case .importing = step { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .chooseFile:
            chooseFileView
        case .selectLists(let lists):
            selectListsView(lists)
        case .importing:
            importingView
        case .finished(let imported):
            finishedView(imported)
        }
    }
}

// MARK: - Steps

private extension LetterboxdImportView {
    var chooseFileView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Letterboxd doesn't let apps sign in to your account, but you can bring all your lists over, private ones included, using its data export.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 16) {
                instruction(1, "Open your Letterboxd data settings and tap **Export Your Data**.")
                instruction(2, "Save the ZIP it downloads to Files.")
                instruction(3, "Choose that ZIP below. You'll pick which lists to import next.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()

            Spacer()

            VStack(spacing: 12) {
                Link(destination: Self.exportURL) {
                    Label("Open Letterboxd Settings", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    Haptics.tap()
                    showFileImporter = true
                } label: {
                    Label("Choose Export File", systemImage: "doc.zipper")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.bottom, 16)
        }
        .padding(.top, 16)
        .appearAnimation()
    }

    func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundColor(Theme.onAccent)
                .frame(width: 26, height: 26)
                .background(Theme.accentGradient)
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func selectListsView(_ lists: [LetterboxdList]) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(lists.count) \(lists.count == 1 ? "list" : "lists") found")
                            .font(.subheadline)
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                        Button(selected.count == lists.count ? "Deselect All" : "Select All") {
                            Haptics.tap()
                            selected = selected.count == lists.count ? [] : Set(lists.map(\.id))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentGradient)
                    }
                    .padding(.vertical, 12)

                    ForEach(lists) { list in
                        listRow(list)
                    }
                }
                .padding(.bottom, 16)
            }

            Button("Import \(selected.count) \(selected.count == 1 ? "List" : "Lists")") {
                startImport(lists.filter { selected.contains($0.id) })
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selected.isEmpty)
            .opacity(selected.isEmpty ? 0.5 : 1)
            .padding(.vertical, 16)
        }
    }

    func listRow(_ list: LetterboxdList) -> some View {
        let isSelected = selected.contains(list.id)
        return Button {
            Haptics.tap()
            if isSelected { selected.remove(list.id) } else { selected.insert(list.id) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textTertiary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(list.name)
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(list.films.count) \(list.films.count == 1 ? "film" : "films")")
                        if alreadyImported(list) {
                            Text("· Already in your lists")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(14)
            .cardStyle(cornerRadius: 16)
        }
        .buttonStyle(PressableButtonStyle())
    }

    var importingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text("Matching your films")
                .font(.title3.weight(.bold))
                .foregroundColor(Theme.textPrimary)
            Text("Each film is looked up on TMDb. Long lists can take a minute, so keep the app open.")
                .font(.subheadline)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    func finishedView(_ imported: [ListDetailsResponse]) -> some View {
        let filmCount = imported.reduce(0) { $0 + $1.movies.count }
        let skipped = imported.flatMap { list in (list.skipped ?? []).map { (list: list.name, film: $0) } }
        var message = "Added \(imported.count) \(imported.count == 1 ? "list" : "lists") with \(filmCount) \(filmCount == 1 ? "film" : "films")."
        // Lists whose Letterboxd name moderation didn't allow
        let renamed = imported.filter { $0.renamed_from_blocked == true }.count
        if renamed > 0 {
            message += " \(renamed) list \(renamed == 1 ? "name isn't" : "names aren't") allowed, so \(renamed == 1 ? "it's" : "they're") called \"Imported list\". You can rename \(renamed == 1 ? "it" : "them") from the list's ••• menu."
        }

        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    EmptyStateView(
                        icon: "checkmark.seal.fill",
                        title: "Import complete",
                        message: message
                    )

                    if !skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(skipped.count) \(skipped.count == 1 ? "film" : "films") couldn't be matched")
                                .font(.headline)
                                .foregroundColor(Theme.textPrimary)
                            Text("Add these yourself from the list if you'd like them.")
                                .font(.caption)
                                .foregroundColor(Theme.textSecondary)
                            ForEach(Array(skipped.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.film)
                                        .foregroundColor(Theme.textPrimary)
                                    Spacer()
                                    Text(item.list)
                                        .foregroundColor(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                    }
                }
            }

            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.vertical, 16)
        }
    }
}

// MARK: - Actions

private extension LetterboxdImportView {
    func alreadyImported(_ list: LetterboxdList) -> Bool {
        existingLists.contains { $0.name == list.name }
    }

    func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            do {
                let lists = try LetterboxdExport.lists(from: urls)
                // Skip lists that look like they came over in an earlier import
                selected = Set(lists.filter { !alreadyImported($0) }.map(\.id))
                withAnimation(Theme.spring) {
                    step = .selectLists(lists)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func startImport(_ lists: [LetterboxdList]) {
        guard let userID = viewModel.user?.uid else {
            errorMessage = "You need to be signed in to import lists."
            return
        }
        let previousStep = step
        withAnimation(Theme.spring) {
            step = .importing
        }

        APIService.shared.importLetterboxdLists(userID: userID, lists: lists) { result in
            switch result {
            case .success(let imported):
                for listResponse in imported {
                    PersistenceController.insert(listResponse, into: context)
                }
                do {
                    try context.save()
                } catch {
                    print("Failed to save imported lists", error)
                }
                Haptics.success()
                // A big import can pass several milestones at once; only the highest is celebrated
                Milestones.shared.check()
                AppAnalytics.log(.importCompleted(.letterboxd, films: imported.reduce(0) { $0 + $1.movies.count }))
                withAnimation(Theme.spring) {
                    step = .finished(imported)
                }
                ReviewPrompter.ask(requestReview, after: .importCompleted)
            case .failure(let error):
                print("Letterboxd import failed:", error.localizedDescription)
                errorMessage = "Something went wrong while importing. Check your connection and try again."
                withAnimation(Theme.spring) {
                    step = previousStep
                }
            }
        }
    }
}

struct LetterboxdImportView_Previews: PreviewProvider {
    static var previews: some View {
        LetterboxdImportView()
            .environmentObject(AuthenticationViewModel())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
