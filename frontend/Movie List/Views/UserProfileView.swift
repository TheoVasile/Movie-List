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
    // The chosen photo, waiting to be moved and scaled into the circle
    @State private var cropping: CroppablePhoto? = nil
    @State private var uploadingPhoto = false
    @State private var photoError: String? = nil
    @ObservedObject private var social = SocialStore.shared
    @ObservedObject private var sync = SyncStatus.shared
    @State private var shareItem: ShareItem? = nil
    var body: some View {
        NavigationStack {
            ZStack{
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        profileHeader
                        stats
                        links
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
                // The user's own link: their profile page, or their invite link if their profile is private
                ToolbarItem(placement: .navigationBarLeading) {
                    if let link = ShareLinks.myLink {
                        Button {
                            Haptics.tap()
                            shareItem = ShareItem(items: ["My films on Marquee", link], kind: .profile)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(Theme.textSecondary)
                        }
                        .accessibilityLabel("Share Profile")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Haptics.tap()
                        showSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(Theme.textSecondary)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings, content: {
                UserSettingsView()
                    .environmentObject(viewModel)
            })
            .sheet(item: $shareItem) { item in
                ShareSheet(item: item)
                    .presentationDetents([.medium, .large])
            }
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
            // Whether there's a picture to remove isn't known until the profile loads
            .disabled(uploadingPhoto || !social.hasLoaded)
            .appearAnimation()
            .confirmationDialog("Profile Picture", isPresented: $showPhotoOptions) {
                Button("Choose a New Photo") { showPhotoPicker = true }
                Button("Remove Photo", role: .destructive, action: removePhoto)
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
            .onChange(of: pickedPhoto) { item in
                guard let item else { return }
                open(item)
            }
            .fullScreenCover(item: $cropping) { photo in
                AvatarCropView(image: photo.image, onCancel: { cropping = nil }) { cropped in
                    cropping = nil
                    upload(cropped)
                }
            }
            if let photoError {
                Text(photoError)
                    .font(.footnote)
                    .foregroundColor(Theme.accentSecondary)
            }
            if let profile = social.profile {
                VStack(spacing: 4) {
                    // Known by their @username, with their name below
                    Text(profile.handle.map { "@\($0)" } ?? viewModel.user?.displayName ?? "No Name")
                        .font(.title2.weight(.heavy))
                        .foregroundColor(Theme.textPrimary)
                    // An Apple Hide My Email address isn't shown, since it means nothing to them
                    Text(profile.handle == nil ? viewModel.shownEmail ?? "" : viewModel.user?.displayName ?? "")
                        .font(.subheadline)
                        .foregroundColor(Theme.textSecondary)
                    if profile.handle != nil {
                        ConnectionCounts(handle: nil, followers: profile.followers, following: profile.following)
                    }
                }
                .appearAnimation(delay: 0.08)
            } else {
                // Placeholders the size of the @username and name, until the profile loads
                VStack(spacing: 4) {
                    Text("@username")
                        .font(.title2.weight(.heavy))
                    Text("Your Name")
                        .font(.subheadline)
                }
                .foregroundColor(Theme.textSecondary)
                .loading(true, spinner: .center)
            }
        }
        .padding(.top, 24)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            statTile(value: "\(movieLists.count)", label: "Lists", icon: "film.stack")
            statTile(value: uniqueTitles.formatted(), label: hasShows ? "Films & Shows" : "Films", icon: "film")
            statTile(value: topLanguage, label: "Top Language", icon: "globe")
        }
        // Not 0 lists and 0 films while the lists are still on their way
        .redacted(reason: movieLists.isEmpty && sync.isFirstSync ? .placeholder : [])
        .appearAnimation(delay: 0.14)
    }

    // Friend Activity, Stats, Directors & Franchises, Diary, Recommended to You and Liked & Not for Me as rows of one
    // card, like a Settings group
    private var links: some View {
        VStack(spacing: 0) {
            activityLink
            Divider().padding(.leading, 56)
            statsLink
            Divider().padding(.leading, 56)
            collectionsLink
            Divider().padding(.leading, 56)
            diaryLink
            Divider().padding(.leading, 56)
            recommendationsLink
            Divider().padding(.leading, 56)
            likedLink
        }
        .cardStyle(cornerRadius: 18)
        .appearAnimation(delay: 0.16)
    }

    private var activityLink: some View {
        NavigationLink {
            FriendActivityView()
                .environment(\.managedObjectContext, context)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accentGradient)
                    // Same width for every icon, so the titles line up
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Friend Activity")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Text("What the people you follow are watching and ranking")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var collectionsLink: some View {
        NavigationLink {
            CollectionsView()
                .environment(\.managedObjectContext, context)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundStyle(Theme.accentGradient)
                    // Same width for every icon, so the titles line up
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Directors & Franchises")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Text("How many you've seen, and what's left")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
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
                    // Same width for every icon, so the titles line up
                    .frame(width: 28)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var diaryLink: some View {
        NavigationLink {
            DiaryView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accentGradient)
                    // Same width for every icon, so the titles line up
                    .frame(width: 28)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var recommendationsLink: some View {
        let unseen = social.profile?.recommendations_unseen ?? 0
        return NavigationLink {
            RecommendationsView()
                .environment(\.managedObjectContext, context)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accentGradient)
                    // Same width for every icon, so the titles line up
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recommended to You")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Text(unseen > 0 ? "\(unseen) new from friends" : "Films friends think you should see")
                        .font(.caption)
                        .foregroundColor(unseen > 0 ? Theme.accent : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if unseen > 0 {
                    Text("\(unseen)")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accentGradient, in: Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(unseen > 0 ? "Recommended to You, \(unseen) new" : "Recommended to You")
    }

    private var likedLink: some View {
        NavigationLink {
            DiscoverReactionsView()
                .environment(\.managedObjectContext, context)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accentGradient)
                    // Same width for every icon, so the titles line up
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Liked & Not for Me")
                        .font(.headline)
                        .foregroundColor(Theme.textPrimary)
                    Text("Films you liked or passed on for good in Discover")
                        .font(.caption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
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

    // Each film or show once, however many lists it's in
    private var uniqueTitles: Int {
        Set(movieLists.flatMap { $0.movies.map(\.tmdb_id) }).count
    }

    private var hasShows: Bool {
        movieLists.contains { $0.movies.contains(where: \.isTV) }
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
            if movieLists.isEmpty && sync.isFirstSync {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .cardStyle()
            } else if movieLists.isEmpty {
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

    // Loads the photo from the library, then asks where to crop it
    private func open(_ item: PhotosPickerItem) {
        photoError = nil
        Task {
            defer { pickedPhoto = nil }
            guard let data = try? await item.loadTransferable(type: Data.self), let photo = UIImage(data: data) else {
                photoError = "Couldn't open that photo."
                return
            }
            cropping = CroppablePhoto(image: photo)
        }
    }

    private func upload(_ photo: UIImage) {
        guard let jpeg = AvatarStore.profileJPEG(from: photo) else {
            photoError = "Couldn't open that photo."
            return
        }
        uploadingPhoto = true
        photoError = nil
        Task {
            defer { uploadingPhoto = false }
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
