//
//  UserProfileView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import SwiftUI
import PhotosUI

struct UserProfileView: View {
    @Environment(\.managedObjectContext) var context
    @EnvironmentObject var viewModel: AuthenticationViewModel
    @FetchRequest(fetchRequest: CDMovieList.fetch()) var movieLists: FetchedResults<CDMovieList>
    @State var showSettings: Bool = false
    // Changing the profile picture
    @State private var showPhotoOptions = false
    @State private var showPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem? = nil
    @State private var uploadingPhoto = false
    @State private var photoError: String? = nil
    @ObservedObject private var social = SocialStore.shared
    var body: some View {
        NavigationStack {
            ZStack{
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        profileHeader
                        stats
                        statsLink
                        diaryLink
                        FollowingSection()
                        FollowedListsSection()
                        MovieNightGroupsSection()
                            .appearAnimation(delay: 0.18)
                        listsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Haptics.tap()
                        showSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .sheet(isPresented: $showSettings, content: {
                UserSettingsView()
                    .environmentObject(viewModel)
            })
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 12) {
            Button {
                Haptics.tap()
                if social.profile?.avatar_version != nil {
                    showPhotoOptions = true
                } else {
                    showPhotoPicker = true
                }
            } label: {
                img
                    .padding(4)
                    .overlay(Circle().stroke(Theme.accentGradient, lineWidth: 3))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 20)
                    .overlay(alignment: .bottomTrailing) {
                        Group {
                            if uploadingPhoto {
                                ProgressView().tint(Theme.onAccent)
                            } else {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Theme.onAccent)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .background(Theme.accentGradient, in: Circle())
                        .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                    }
            }
            .buttonStyle(PressableButtonStyle(scale: 0.96))
            .accessibilityLabel("Change profile picture")
            .disabled(uploadingPhoto)
            .appearAnimation()
            .confirmationDialog("Profile Picture", isPresented: $showPhotoOptions) {
                Button("Choose a New Photo") { showPhotoPicker = true }
                Button("Remove Photo", role: .destructive, action: removePhoto)
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
            .onChange(of: pickedPhoto) { item in
                guard let item else { return }
                upload(item)
            }
            if let photoError {
                Text(photoError)
                    .font(.footnote)
                    .foregroundColor(Theme.accentSecondary)
            }
            VStack(spacing: 4) {
                // Known by their @username, with their name below
                Text(social.profile?.handle.map { "@\($0)" } ?? viewModel.user?.displayName ?? "No Name")
                    .font(.title2.weight(.heavy))
                    .foregroundColor(Theme.textPrimary)
                Text(social.profile?.handle == nil ? viewModel.user?.email ?? "" : viewModel.user?.displayName ?? "")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                if let profile = social.profile, profile.handle != nil {
                    ConnectionCounts(handle: nil, followers: profile.followers, following: profile.following)
                }
            }
            .appearAnimation(delay: 0.08)
        }
        .padding(.top, 24)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            statTile(value: "\(movieLists.count)", label: "Lists", icon: "film.stack")
            statTile(value: "\(totalMovies)", label: "Films", icon: "film")
            statTile(value: topLanguage, label: "Top Language", icon: "globe")
        }
        .appearAnimation(delay: 0.14)
    }

    private var statsLink: some View {
        NavigationLink {
            StatsView()
                .environment(\.managedObjectContext, context)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title3)
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Stats")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Text("Decades, genres, languages and your most underrated pick")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(16)
            .cardStyle(cornerRadius: 18)
        }
        .buttonStyle(PressableButtonStyle())
        .appearAnimation(delay: 0.16)
    }

    private var diaryLink: some View {
        NavigationLink {
            DiaryView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diary")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Text("Every film you've watched, by month, with rewatches")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(16)
            .cardStyle(cornerRadius: 18)
        }
        .buttonStyle(PressableButtonStyle())
        .appearAnimation(delay: 0.17)
    }

    private func statTile(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Theme.accentGradient)
            Text(value)
                .font(.title3.weight(.heavy))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .cardStyle(cornerRadius: 18)
    }

    private var totalMovies: Int {
        movieLists.reduce(0) { $0 + $1.movies.count }
    }

    private var topLanguage: String {
        let languages = movieLists.flatMap { $0.movies.compactMap { $0.original_language } }
        let counts = Dictionary(grouping: languages, by: { $0 }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key.uppercased() ?? "—"
    }

    private var listsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Lists")
                .font(.headline)
                .foregroundColor(Theme.textPrimary)
            if movieLists.isEmpty {
                Text("No lists yet. Create one from the Lists tab.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .cardStyle()
            } else {
                ForEach(Array(movieLists.enumerated()), id: \.element) { index, movieList in
                    NavigationLink {
                        ListView(movieList: movieList, context: context)
                            .environmentObject(NetworkService())
                            .environmentObject(DatabaseService())
                    } label: {
                        listRow(movieList)
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.98))
                    .appearAnimation(delay: 0.2 + Double(min(index, 8)) * 0.05)
                }
            }
        }
    }

    private func listRow(_ movieList: CDMovieList) -> some View {
        let top = movieList.movies.sorted { $0.rank < $1.rank }.first
        return HStack(spacing: 14) {
            PosterImage(path: top?.poster_path, cornerRadius: 8, size: .small)
                .frame(width: 44, height: 66)
            VStack(alignment: .leading, spacing: 3) {
                Text(movieList.name ?? "No Name")
                    .font(.headline)
                    .foregroundColor(Theme.textPrimary)
                Text(top.map { "#1 · \($0.title ?? "")" } ?? "No films yet")
                    .font(.caption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(movieList.movies.count)")
                .font(.subheadline.weight(.bold))
                .foregroundColor(Theme.textSecondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(12)
        .cardStyle(cornerRadius: 16)
    }
    
    // The picture the user chose here; otherwise their Google account's picture; otherwise a placeholder
    var img: some View {
        Group {
            if let version = social.profile?.avatar_version {
                Avatar(name: viewModel.user?.displayName ?? "?", size: 96, handle: nil, version: version)
            } else if let photoURL = viewModel.user?.photoURL {
                AsyncImage(url: photoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())

                    case .failure(_):
                        placeholderImage

                    default:
                        placeholderImage
                    }
                }
            } else {
                placeholderImage
            }
        }
    }

    private func upload(_ item: PhotosPickerItem) {
        uploadingPhoto = true
        photoError = nil
        Task {
            defer {
                uploadingPhoto = false
                pickedPhoto = nil
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let photo = UIImage(data: data),
                  let jpeg = AvatarStore.profileJPEG(from: photo) else {
                photoError = "Couldn't open that photo."
                return
            }
            let version = await withCheckedContinuation { continuation in
                APIService.shared.uploadAvatar(jpeg) { continuation.resume(returning: $0) }
            }
            if version == nil {
                photoError = "Couldn't upload your photo. Try again."
            } else {
                social.load()
            }
        }
    }

    private func removePhoto() {
        APIService.shared.deleteAvatar { removed in
            if removed {
                social.load()
            } else {
                photoError = "Couldn't remove your photo. Try again."
            }
        }
    }

    private var placeholderImage: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .scaledToFill()
            .frame(width: 96, height: 96)
            .foregroundColor(Theme.textTertiary)
            .background(Circle().fill(Theme.surfaceRaised))
            .clipShape(Circle())
    }
}

struct UserProfileView_Previews: PreviewProvider {
    static var previews: some View {
        UserProfileView()
            .environmentObject(AuthenticationViewModel())
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
