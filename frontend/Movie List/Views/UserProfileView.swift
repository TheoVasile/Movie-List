//
//  UserProfileView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import SwiftUI

struct UserProfileView: View {
    @Environment(\.managedObjectContext) var context
    @EnvironmentObject var viewModel: AuthenticationViewModel
    @FetchRequest(fetchRequest: CDMovieList.fetch()) var movieLists: FetchedResults<CDMovieList>
    @State var showSettings: Bool = false
    var body: some View {
        NavigationStack {
            ZStack{
                Color(UIColor.systemGray6)
                    .edgesIgnoringSafeArea(.all)
                VStack{
                    Spacer()
                    img
                    Text(viewModel.user?.displayName ?? "No Name")
                        .padding()
                    Text(viewModel.user?.email ?? "No Email")
                        .padding()
                    Text("Your Lists:")
                    Group {
                        if movieLists.isEmpty {
                            List{
                                Text("No Lists, Add one Now!")
                            }
                        } else {
                            List {
                                ForEach(movieLists, id: \.self) { movieList in
                                    NavigationLink(movieList.name ?? "No Name", destination:
                                                    ListView(movieList: movieList, context: context)
                                        .environmentObject(NetworkService())
                                        .environmentObject(DatabaseService())
                                    )
                                }
                                .padding(10)
                            }
                        }
                    }
                    Spacer()
                    
                }
                .frame(maxWidth: .infinity)
                .background(.white)
                .cornerRadius(20)
                .padding(20)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            showSettings = true // Replace with actual navigation
                        }) {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.gray)
                        }
                    }
                }
                .sheet(isPresented: $showSettings, content: {
                    UserSettingsView()
                })
            }
        }
    }
    
    var img: some View {
        Group {
            if let photoURL = viewModel.user?.photoURL {
                AsyncImage(url: photoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .shadow(radius: 3)

                    case .failure(_):
                        placeholderImage

                    case .empty:
                        placeholderImage
                    }
                }
            } else {
                placeholderImage
            }
        }
    }

    private var placeholderImage: some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .scaledToFill()
            .frame(width: 80, height: 80)
            .foregroundColor(.gray)
            .background(Circle().fill(Color(.systemGray5)))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(radius: 3)
    }
}

struct UserProfileView_Previews: PreviewProvider {
    static var previews: some View {
        UserProfileView()
            .environmentObject(AuthenticationViewModel())
    }
}
