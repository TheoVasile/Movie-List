//
//  NSPredicate+helper.swift
//  Movie List
//
//  Created by Theo Vasile on 2024-04-28.
//

import Foundation

extension NSPredicate {
    
    static let all = NSPredicate(format: "TRUEPREDICATE")
    static let none = NSPredicate(format: "FALSEPREDICATE")
}
