//
//  Extensions.swift
//  Movie List
//
//  Created by Theo Vasile on 2023-01-12.
//

import Foundation
import SwiftUI

extension View{
    func popupNavigationView<Content: View>(horizontalPadding: CGFloat = 40, show: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View{
        return self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay{
                if show.wrappedValue{
                    GeometryReader{proxy in
                        Color.primary
                            .opacity(0.15)
                            .ignoresSafeArea()
                        
                        NavigationView{
                            content()
                        }
                        .frame(height: 175, alignment: .center)
                        .cornerRadius(15)
                        .padding(horizontalPadding)
                    }
                }
            }
    }
}
