//
//  GwaTopSignedInUser.swift
//  GwaTop
//
//  Created by hyunwoo on 5/19/26.
//

import Foundation

struct GwaTopSignedInUser: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let email: String
    let givenName: String?
    let familyName: String?
    let profileImageURL: String?
    let loginProvider: String

    var firstDisplayName: String {
        if let givenName, !givenName.isEmpty {
            return givenName
        }
        return displayName.components(separatedBy: " ").first ?? displayName
    }

    var initials: String {
        let source = displayName.isEmpty ? email : displayName
        let parts = source
            .split(separator: " ")
            .map { String($0.prefix(1)) }

        if parts.isEmpty {
            return "GT"
        }

        return parts.prefix(2).joined().uppercased()
    }

    static let guest = GwaTopSignedInUser(
        id: "guest-user",
        displayName: "현우",
        email: "guest@gwatop.app",
        givenName: "현우",
        familyName: nil,
        profileImageURL: nil,
        loginProvider: "mock"
    )
}
