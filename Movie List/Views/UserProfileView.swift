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
    var body: some View {
        Text("Profile")
    }
}

struct UserProfileView_Previews: PreviewProvider {
    static var previews: some View {
        UserProfileView()
            .environmentObject(AuthenticationViewModel())
    }
}
