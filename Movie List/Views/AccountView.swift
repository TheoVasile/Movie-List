//
//  AccountView.swift
//  Movie List
//
//  Created by Theo Vasile on 2025-02-06.
//

import Foundation
import SwiftUI

struct AccountView: View {
    var body: some View {
        SignInView()
            .environmentObject(AuthenticationViewModel())
    }
}

struct AccountView_Previews: PreviewProvider {
    static var previews: some View {
        AccountView()
    }
}
