//
//  UserProfileView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import SwiftUI

struct UserProfileView: View {
    @EnvironmentObject var viewModel: AuthenticationViewModel
    @FetchRequest(fetchRequest: CDMovieList.fetch()) var movieLists: FetchedResults<CDMovieList>
    var body: some View {
        ZStack{
            Color(UIColor.systemGray6)
                .edgesIgnoringSafeArea(.all)
            VStack{
                Spacer()
                if let photoURL = viewModel.user?.photoURL {
                    AsyncImage(url: photoURL) { image in
                        image
                            .resizable().scaledToFill()
                            .frame(width: 80, height: 80) // Adjust size as needed
                            .foregroundColor(.gray) // Default color, change if needed
                            .background(Circle().fill(Color(.systemGray5))) // Light gray background
                            .clipShape(Circle()) // Ensures it's circular
                            .shadow(radius: 3) // Optional shadow
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80) // Adjust size as needed
                            .foregroundColor(.gray) // Default color, change if needed
                            .background(Circle().fill(Color(.systemGray5))) // Light gray background
                            .clipShape(Circle()) // Ensures it's circular
                            .shadow(radius: 3) // Optional shadow
                    }
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80) // Adjust size as needed
                        .foregroundColor(.gray) // Default color, change if needed
                        .background(Circle().fill(Color(.systemGray5))) // Light gray background
                        .clipShape(Circle()) // Ensures it's circular
                        .shadow(radius: 3) // Optional shadow
                }
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
                                                ListView(movieList: movieList)
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
        }
    }
}

struct UserProfileView_Previews: PreviewProvider {
    static var previews: some View {
        UserProfileView()
            .environmentObject(AuthenticationViewModel())
    }
}
